-- cw/inbound.lua - the packet thread: the 0x044 (automaton stats and loadout),
-- 0x00A (zone), 0x029 (battle message) and 0x028 (action) handlers, which
-- onPacket dispatches to by packet id. Writes tm.auto044, tm.resonance,
-- tm.petTarget, tm.deployTo, the summon seeds and the effect tables; returns
-- unpackAction and onPacket.

-- THIS FILE MUST NOT REQUIRE cw.reading. It runs on the packet thread and may
-- read only what d3d_present published into tm.snap and the model tables; a
-- native read here is the SEH fault described in cw/state.lua. The harness
-- checks the require list.
local chat = require('chat')
local config = require('cw.config')
local D  = require('cw.data')
local ELEMENTS, MSG_OVERLOAD_CHANCE, MSG_OVERLOADED, ABIL_MANEUVER_FIRST = D.ELEMENTS, D.MSG_OVERLOAD_CHANCE, D.MSG_OVERLOADED, D.ABIL_MANEUVER_FIRST
local ABIL_DEA, ABIL_ACTIVATE, CAT_ABILITY, CAT_MOBSKILL = D.ABIL_DEA, D.ABIL_ACTIVATE, D.CAT_ABILITY, D.CAT_MOBSKILL
local CAT_WS, CAT_AVATAR, CAT_MAGIC, CAT_MAGIC_START = D.CAT_WS, D.CAT_AVATAR, D.CAT_MAGIC, D.CAT_MAGIC_START
local PET_MOBSKILL, MOBSKILL_RANGED, SC_NAME, MOBSKILL_SC = D.PET_MOBSKILL, D.MOBSKILL_RANGED, D.SC_NAME, D.MOBSKILL_SC
local WS_SC, AVATAR_SC = D.WS_SC, D.AVATAR_SC
local tm = require('cw.state')
local U  = require('cw.util')
local safe = U.safe
local L  = require('cw.log')
local logEvent, flagAnomaly = L.logEvent, L.flagAnomaly
local B  = require('cw.burden')
local reconcile, formSkillchain, rawResonance, liveResonance = B.reconcile, B.formSkillchain, B.rawResonance, B.liveResonance
local T  = require('cw.timers')
local noteUse, timersClear = T.noteUse, T.timersClear
local P  = require('cw.pet')
local MSG_STATUS_OFF, MSG_DEATH, petEffects, clearPetEffects = P.MSG_STATUS_OFF, P.MSG_DEATH, P.petEffects, P.clearPetEffects
local notePetStatus = P.notePetStatus
-- Tables with a stable identity (see cw/state.lua), so safe to alias here.
local burden, cost, ids, snap = tm.burden, tm.cost, tm.ids, tm.snap
local burdenVerified, seededBy = tm.burdenVerified, tm.seededBy
require('cw.spell')   -- tm.spellObserve and tm.noteMob are bound through tm
                      -- and must be loaded before the first packet arrives

-- 0x028 bit layout: fancychat/lib/combat_packets.lua
local function unpackAction(data)
    local t = {}
    local bytes = data:totable()
    t.actor_id     = ashita.bits.unpack_be(bytes, 40,  32)
    t.target_count = ashita.bits.unpack_be(bytes, 72,  10)
    t.category     = ashita.bits.unpack_be(bytes, 82,   4)
    t.param        = ashita.bits.unpack_be(bytes, 86,  16)
    -- Magic Finish: the recast the server applied, in seconds
    -- (0x028_battle2.cpp, timer::count_seconds(action.recast)).
    t.recast       = ashita.bits.unpack_be(bytes, 118, 32)
    t.targets      = {}

    local offset = 150
    for i = 1, t.target_count do
        local tgt = {
            server_id    = ashita.bits.unpack_be(bytes, offset, 32),
            action_count = ashita.bits.unpack_be(bytes, offset + 32, 4),
            actions      = {},
        }
        offset = offset + 36
        for n = 1, tgt.action_count do
            local a = {
                reaction  = ashita.bits.unpack_be(bytes, offset, 5),
                animation = ashita.bits.unpack_be(bytes, offset + 5, 12),
                effect    = ashita.bits.unpack_be(bytes, offset + 17, 4),
                param     = ashita.bits.unpack_be(bytes, offset + 27, 17),
                message   = ashita.bits.unpack_be(bytes, offset + 44, 10),
            }
            offset = offset + 86
            -- The two variable tails, fancychat's layout. The additional
            -- effect - "Additional effect: Poison" on a hit - carries a status
            -- on the TARGET; the spikes reaction - "Striking X's armor causes
            -- Y to become paralyzed" - carries one on the ACTOR. Each is a
            -- message/param pair like the main line, and the recorders read
            -- both; the animation and effect fields are skipped.
            if ashita.bits.unpack_be(bytes, offset - 1, 1) == 1 then
                a.add_param   = ashita.bits.unpack_be(bytes, offset + 10, 17)
                a.add_message = ashita.bits.unpack_be(bytes, offset + 27, 10)
                offset = offset + 37
            end
            if ashita.bits.unpack_be(bytes, offset, 1) == 1 then
                a.spike_param   = ashita.bits.unpack_be(bytes, offset + 11, 14)
                a.spike_message = ashita.bits.unpack_be(bytes, offset + 25, 10)
                offset = offset + 35
            else offset = offset + 1 end
            tgt.actions[n] = a
        end
        t.targets[i] = tgt
    end
    return t
end

-- 0x044 GP_SERV_COMMAND_EXTENDED_JOB, PUP variant. LSB deliberately blanks
-- the master's skill slots 22-24 in the 0x062 skills packet ("they are in
-- another packet" - 0x062_clistatus2.cpp), so THIS packet is the only source
-- of automaton skills. It also carries the skill caps and the real unlocked-
-- attachment bitmask (UnlockedAttachments[8] = 256 bits). Layout:
-- 0x044_extended_job_pup.h.
local function u16le(d, o)  -- o is the absolute 0-based byte offset
    local a, b = d:byte(o + 1, o + 2)
    return (a or 0) + ((b or 0) * 256)
end
local function u32le(d, o)
    local a, b, c, e = d:byte(o + 1, o + 4)
    return (a or 0) + ((b or 0) * 0x100) + ((c or 0) * 0x10000) + ((e or 0) * 0x1000000)
end

-- Offsets verified against LSB's own builder + struct,
-- 0x044_extended_job_pup.{h,cpp}. PacketData begins at raw 0x04. Note char Name[16] sits between
-- UnlockedAttachments and HP - miss it and everything after shifts by 16.
--   0x38 UnlockedAttachments[8] (32B)   0x58 Name[16]
--   0x68 HP  0x6A MaxHP  0x6C MP  0x6E MaxMP
--   0x70 MeleeSkill/Cap  0x74 RangedSkill/Cap  0x78 MagicSkill/Cap
--   0x80 STR/Bonus  0x84 DEX  0x88 VIT  0x8C AGI  0x90 INT  0x94 MND  0x98 CHR
local function parseJobExtra(data)
    if #data < 0xA0 then return end   -- must reach the stat block, not just skills
    if data:byte(0x04 + 1) ~= 18 then return end  -- PUP variant only (BST shares the opcode)
    -- Bonus is a signed int16: a STR-down on the automaton read as 65586.
    local function stat(off)
        local bonus = u16le(data, off + 2)
        if bonus >= 0x8000 then bonus = bonus - 0x10000 end
        return u16le(data, off) + bonus
    end
    local wasFrame = tm.auto044 and tm.auto044.frame or nil
    tm.auto044 = {
        head      = data:byte(0x08 + 1),
        frame     = data:byte(0x09 + 1),
        hp        = u16le(data, 0x68), maxhp = u16le(data, 0x6A),
        mp        = u16le(data, 0x6C), maxmp = u16le(data, 0x6E),
        melee     = u16le(data, 0x70), meleeCap  = u16le(data, 0x72),
        ranged    = u16le(data, 0x74), rangedCap = u16le(data, 0x76),
        magic     = u16le(data, 0x78), magicCap  = u16le(data, 0x7A),
        owned     = data:sub(0x38 + 1, 0x38 + 0x20),  -- UnlockedAttachments[8]
        -- What the server says is on the automaton right now, slot order -
        -- the reference Apply verifies against. And which heads and frames
        -- are unlocked: bit (id & 0x0F) each, puppetutils.cpp.
        attachments = { data:byte(0x0A + 1, 0x0A + 12) },
        heads       = u32le(data, 0x18),
        frames      = u32le(data, 0x1C),
        -- effective = base + bonus, matching CBattleEntity::getStat which is
        -- what getAddBurdenValue actually compares.
        STR = stat(0x80), DEX = stat(0x84), VIT = stat(0x88), AGI = stat(0x8C),
        INT = stat(0x90), MND = stat(0x94), CHR = stat(0x98),
        -- Base and Bonus kept apart as well. Which of the two the server
        -- compares against is still unresolved, and the sum is what currently
        -- loses the check that observation says we win.
        base = { STR = u16le(data, 0x80), DEX = u16le(data, 0x84),
                 VIT = u16le(data, 0x88), AGI = u16le(data, 0x8C),
                 INT = u16le(data, 0x90), MND = u16le(data, 0x94),
                 CHR = u16le(data, 0x98) },
    }
    -- A different frame is a different automaton, so an 'observed' cost
    -- override and the run of disputes behind it stop describing anything
    -- that is on the field: they were learned by comparing the master's stat
    -- against the stats this packet has just replaced. Dropped here so the
    -- refreshStatChecks that statsDirty triggers can recompute; castStat is
    -- the MASTER's own stat and is left alone.
    if wasFrame ~= nil and wasFrame ~= tm.auto044.frame then tm.dropLearnedCosts(false) end
    tm.statsDirty = true   -- recomputed on the render thread, not here
    tm.auto044Seq = tm.auto044Seq + 1
end

-- FFXI chunk resends deliver the same 0x028 more than once. Running
-- reconcile() twice yields err ~= +cost and a guaranteed false anomaly.
local seenActions = {}
local function isDuplicate(data)
    local key = data:sub(1, 24)
    local now = os.clock()
    for k, t in pairs(seenActions) do
        if now - t > 5.0 then seenActions[k] = nil end
    end
    if seenActions[key] ~= nil then return true end
    seenActions[key] = now
    return false
end

-- 0x00A (zone): forgets the automaton's effects, its recasts and the mobs
-- of the zone just left.
local function onZone()
    -- Zoning: the automaton keeps its buffs and we merely lose sight of
    -- them, so everything we knew about them goes back to unknown.
    clearPetEffects()
    tm.petKnown = {}
    -- ...but the RECASTS do clear: this model treats a zone on Horizon as
    -- resetting them exactly as a Deactivate/Activate does. So the
    -- edge is `ready`, the same answer the despawn edge in onPetLifecycle
    -- gives - whether a frame sees PetTargetIndex == 0 before or after
    -- this packet, the cells and the recast_edge readings come out the same.
    timersClear(true, 'zone')
    tm.mobs = {}         -- the mobs stayed behind
    tm.touched = {}      -- ...and their enmity lists with them
    tm.zoneSeq = tm.zoneSeq + 1
end

-- 0x029 (battle message): deaths and wear-offs, on any mob we know and on
-- our automaton.
local function onBattleMessage(data)
    -- GP_SERV_BATTLE_MESSAGE - XiPackets world/server/0x0029:
    --   0x04 UniqueNoCas   0x08 UniqueNoTar   0x0C Data   0x18 MessageNum
    -- A plain "<status> wears off" arrives here rather than in 0x028, and
    -- it names the owner of the effect as the ACTOR, not the target.
    local msg = u16le(data, 0x18)
    local cas = u32le(data, 0x04)
    local tgt = u32le(data, 0x08)
    -- Any mob we know: its death drops everything we held on it - the
    -- server kills every effect (mobentity.cpp DistributeRewards) and the
    -- respawn REUSES the id, so an entry that outlived the death would
    -- describe the next incarnation. A wear-off names the mob as the
    -- ACTOR and the effect as the param.
    if MSG_DEATH[msg] then
        tm.mobs[tgt] = nil
        tm.touched[tgt] = nil   -- the respawn reuses the id with an empty list
        -- ...and the automaton is not fighting it any more. petTarget is
        -- only ever ASSIGNED, by an action the automaton takes, so without
        -- this it would keep naming the corpse: the target row would sit on
        -- '<mob> - out of sight' once the body despawned, and ctx.engaged
        -- would stay true with nothing to fight.
        -- Keyed on the TARGET of the death message, so a party member's
        -- killing blow ends the row just as our own does.
        if tgt == tm.petTarget then tm.petTarget = 0 end
        -- ...nor is a Deploy onto it still pending. Without this a mob
        -- killed by somebody else before the automaton reached it would
        -- leave deployTo naming the corpse, and gather() would read the
        -- automaton as engaged - the enhance rung would then withhold Regen
        -- and offer the combat buffs for a fight that had ended.
        if tgt == tm.deployTo then tm.deployTo = nil end
    elseif MSG_STATUS_OFF[msg] and tm.mobs[cas] ~= nil then
        tm.mobWearOff(cas, u32le(data, 0x0C))
    end
    if snap.pet_id == 0 then return end
    if tgt == snap.pet_id or (cas == snap.pet_id and MSG_STATUS_OFF[msg]) then
        if MSG_DEATH[msg] then
            clearPetEffects()   -- it fell over
        else
            notePetStatus(msg, u32le(data, 0x0C))
        end
    end
end

-- 0x028, the automaton's target: an action the automaton aims at an enemy
-- makes that enemy tm.petTarget.
local function followPetTarget(act, isMine)
    -- Swings, shots and skills name the mob; the automaton's spells and some
    -- of its abilities name itself or the master. Gate on the TARGET, not the
    -- category: the automaton never emits CAT_ABILITY - all thirteen modelled
    -- abilities are mob skills, category 11 - and seven of them are
    -- self-targeted (mob_valid_targets 16: Shock Absorber, Mana Converter,
    -- Eraser, Reactive Shield, Economizer, Replicator, Heat Capacitor).
    -- Letting those move petTarget would put it on the automaton,
    -- and the automaton is never filed as a mob, so the ladder would read its
    -- target as bare - or record the automaton's own Stoneskin (37,
    -- which is in DISPELABLE) as an effect on the mob - a confident, wrong
    -- Dispel prediction for the next 120 s, and gather's mobHpp reading the
    -- automaton's own HP until the next melee swing.
    -- A SPELL moves it only when the spell is aimed at an enemy - its rung is
    -- enfeeble or elemental. Excluding all magic is too broad: a pure caster
    -- automaton never melees and never uses a mob skill, so nothing else would
    -- ever set petTarget, the mob-effect block below would never match, and
    -- not one target effect would be recorded for the whole fight - the ladder
    -- would re-offer Paralyze, Blind and Bio II that the mob already had
    -- (a Soulsoother head would record no target effect all fight).
    local moves = true
    if act.category == CAT_MAGIC or act.category == CAT_MAGIC_START then
        local sid = act.param
        if act.category == CAT_MAGIC_START then
            local t1 = act.targets[1]
            local a1 = (t1 ~= nil) and t1.actions[1] or nil
            sid = (act.param == 24931 and a1 ~= nil) and a1.param or nil
        end
        local row = (sid ~= nil) and tm.fn.row(sid) or nil
        moves = row ~= nil and (row.rung == 'enfeeble' or row.rung == 'elemental')
    end
    if isMine and moves and act.targets[1] ~= nil
       and act.targets[1].server_id ~= snap.pet_id
       and act.targets[1].server_id ~= snap.self_id then
        -- Nothing to hand over: whatever anyone has landed on the new mob is
        -- already in tm.mobs under its own id, and the previous mob's entry stays
        -- for a Deploy back.
        tm.petTarget = act.targets[1].server_id
    end
end

-- 0x028, the resonance: a weaponskill or mob skill that connects with
-- tm.petTarget opens a skillchain on it, or closes the one it carries.
local function noteResonance(act)
    -- The skillchain the automaton chains off is left on the MOB by whoever
    -- weaponskilled last - a party member as readily as us. So this is
    -- gated on the TARGET id, not the actor: it still cannot confuse another
    -- player's puppet with ours, because nothing here touches pet state.
    if tm.petTarget ~= 0 then
        local props = nil
        if     act.category == CAT_WS       then props = WS_SC[act.param]
        elseif act.category == CAT_AVATAR   then props = AVATAR_SC[act.param]
        elseif act.category == CAT_MOBSKILL then
            props = MOBSKILL_SC[act.param] or AVATAR_SC[act.param]
        end
        if props ~= nil and act.actor_id ~= tm.petTarget then  -- a mob's self-buff never opens
            for _, tgt in ipairs(act.targets) do
                if tgt.server_id == tm.petTarget then
                    -- ...and only if it CONNECTED. The properties of a
                    -- weaponskill say what it WOULD leave; whether it left
                    -- anything is in the result. Counting a miss would open a
                    -- chain the mob does not carry, and the prediction would
                    -- promise a closer for it for the whole ten-second window - on a Valoredge
                    -- frame that is a confident wrong answer every frame of it.
                    -- battleentity.cpp:2698 is the server's own gate.
                    local landed = false
                    for _, a in ipairs(tgt.actions) do
                        if not tm.scMiss[a.message] then landed = true break end
                    end
                    if landed then
                        -- If this weaponskill closed a chain, the resonance left
                        -- behind is the RESULTING element, not the skill's own
                        -- properties - same substitution the server makes.
                        local cur  = liveResonance()
                        local made = cur and formSkillchain(props, cur.props) or nil
                        local step = made and ((cur.step or 1) + 1) or 1
                        tm.resonance = { mob = tm.petTarget,
                                      props = made and { made } or props,
                                      at = os.clock(), sc = made, step = step,
                                      dur = (step == 1) and 10 or (11 - step) }
                    end
                    break
                end
            end
        end
    end
end

-- 0x028, statuses landing on our automaton - from anyone's action - and the
-- spikes it takes when it strikes a mob.
local function notePetEffects(act, isMine)
    if snap.pet_id ~= 0 then
        for _, tgt in ipairs(act.targets) do
            if tgt.server_id == snap.pet_id then
                for _, a in ipairs(tgt.actions) do
                    notePetStatus(a.message, a.param)
                    notePetStatus(a.add_message, a.add_param)   -- "Additional effect: Poison"
                    -- The two silent channels, gated on the packet's own
                    -- verdict where it has one: a Dia/Bio that "has no
                    -- effect" (75), a mob skill that missed (188) or had no
                    -- effect (189) put nothing on the automaton. A resisted
                    -- status inside a skill that still did damage cannot be
                    -- told apart, which is what the duration is for.
                    if act.category == CAT_MAGIC and a.message ~= 75 then
                        local row = tm.fn.row(act.param)
                        local e = (row ~= nil and row.enfeeble ~= 0) and row.enfeeble
                                  or tm.spellEffect[act.param]
                        if e == 134 or e == 135 then
                            -- Tier first: a weaker Dia into a standing Bio II
                            -- does its damage and leaves everything as it was.
                            local other = (e == 134) and 135 or 134
                            -- The tier behind the opposite effect counts only
                            -- while that effect is still believed on the
                            -- automaton: otherwise a Bio II that had run out
                            -- would go on refusing every plain Dia after it,
                            -- and the Dia the automaton really carries would
                            -- never be recorded. The mob side asks the same.
                            local now = os.clock()
                            if not tm.petLive(other, now) then tm.petDiaBio[other] = nil end
                            -- ...and the same family's standing tier, while
                            -- it is live: a Dia into a live Dia II is refused
                            -- by the server and must not overwrite the entry
                            -- with a weaker tier and a fresh clock.
                            if not tm.petLive(e, now) then tm.petDiaBio[e] = nil end
                            local lands = tm.diaBioLands(act.param, tm.petDiaBio[other], tm.petDiaBio[e])
                            if lands ~= false then
                                if lands == true then
                                    petEffects[other], tm.petUntil[other] = nil, nil
                                    tm.petDiaBio[other] = nil
                                end
                                tm.petDiaBio[e] = act.param
                                tm.notePetSilent(e, tm.spellDur[act.param])
                            end
                        end
                    elseif act.category == CAT_MOBSKILL and a.message ~= 188 and a.message ~= 189 then
                        for _, se in ipairs(tm.mobskillEffect[act.param] or {}) do
                            tm.notePetSilent(se[1], se[2])
                        end
                    end
                end
            elseif isMine then
                -- Spikes land on the ACTOR: the automaton striking a mob's Ice
                -- Spikes is paralyzed by them, reported in its own action's
                -- spike tail with the mob as the target (STATUS_SPIKES, param
                -- = the effect - battleutils.cpp).
                for _, a in ipairs(tgt.actions) do
                    if a.spike_message == 374 then tm.notePetSilent(a.spike_param, nil) end
                end
            end
        end
    end
end

-- 0x028, statuses landing on every mob in the packet, and whether the action
-- puts one of us on that mob's enmity list.
local function noteMobEffects(act, isSelf, isMine)
    -- 'party' is a member's action (the render snapshot carries their
    -- ids): on the enmity list TryEnhance walks, as ours are.
    local who = (isMine and 'pet') or (isSelf and 'you')
                or (snap.party[act.actor_id] and 'party') or 'other'
    -- A Deploy is an action at the mob but not a blow on it: it sends the
    -- automaton, and puts nobody on the list. Nor is a cast that has only
    -- STARTED, or one that was interrupted - both arrive as Magic Start
    -- (the interrupt with header 0x7073), and neither has landed anything.
    -- Every action that lands is a blow - a swing
    -- that misses claims the mob just the same.
    local blow = act.category ~= CAT_MAGIC_START
                 and not (act.category == CAT_ABILITY and act.param == 138)
    local spell = (act.category == CAT_MAGIC) and act.param or nil
    for _, tgt in ipairs(act.targets) do
        local id = tgt.server_id
        if id ~= 0 and id ~= snap.self_id and id ~= snap.pet_id then
            -- Anything OURS landing on it puts us on its enmity list, and
            -- from there the Regen target exists again. A stranger's does
            -- not: the list TryEnhance reads is only ever searched for the
            -- master, the automaton and the party. Remembered per mob as
            -- well: a Deploy onto a mob one of us has already hit is not
            -- a Deploy onto an empty list - the master hits it, deploys,
            -- and the server still casts Regen.
            if who ~= 'other' and blow then
                tm.touched[id] = os.clock()
                if tm.deployTo == id then tm.deployTo = nil end
            end
            for _, a in ipairs(tgt.actions) do
                tm.noteMob(id, a.message, a.param, who, spell)
                -- a weapon's or a bolt's "Additional effect: Poison" on
                -- the mob; no spell behind it, so the backstop clock
                if a.add_message ~= nil then
                    tm.noteMob(id, a.add_message, a.add_param, who, nil)
                end
            end
        end
    end
end

-- 0x028, our own job abilities: Activate and Deus Ex Automata seed the
-- burden, Deploy and Retrieve move the automaton, a maneuver reconciles.
local function onOurAbility(act)
    local abil = act.param
    if abil == ABIL_ACTIVATE then
        -- A plain Activate: seed every element with config.activate_burden
        -- (nil keeps whatever was carried), unverified, and time it - the
        -- first maneuver of each element after this logs since_activate and
        -- the seed that would have predicted it.
        tm.activateAt = os.clock()
        -- pet_respawn does not fire on a first summon (lastPetId is 0, so
        -- onPetLifecycle is skipped), so the fresh automaton's recast edge
        -- is stamped where the Activate is actually observed. timersClear
        -- is idempotent, so a resummon firing both costs nothing.
        timersClear(true, 'activate')
        for _, el in ipairs(ELEMENTS) do
            if config.activate_burden ~= nil then burden[el] = config.activate_burden end
            burdenVerified[el] = false
            seededBy[el] = 'activate'
            -- the first cast's back-solve counts the Water ticks since
            -- the summon, not since this element last resolved
            tm.waterSince[el] = { ticks = 0, extra = 0 }
        end
        -- A seed says burden IS this, now - so any decay banked while no
        -- frames ran (a loading screen) is irrelevant and must not be
        -- applied on top of it. Take the clock as well as the gap.
        ids.goneAt, tm.lastTick = nil, os.clock()
        -- A SUMMON is the one unambiguous statement that the automaton
        -- carries nothing: it has just been built. Nothing else says so -
        -- a despawn is a dismiss or a zone and cannot be told apart, and no
        -- packet ever lists the automaton's effects - so without this the
        -- ladder treats a fresh automaton's empty table as ignorance and
        -- declines to buff it at all (the server buffs the master and
        -- then the automaton with each of Protect, Shell and Haste; without
        -- this the model skips every automaton half).
        -- Set here rather than on a lifecycle edge because the order of the
        -- two is not guaranteed and this one cannot be misread.
        tm.petKnown = { [40] = true, [41] = true, [33] = true, [37] = true, [116] = true }
        logEvent('activate', { seeded = config.activate_burden or 'carried' })
        -- ...and note where the 0x044 stream stood, so the loadout record
        -- describes the automaton that is arriving, not the one that left.
        tm.logLoadoutAt = tm.auto044Seq
    elseif abil == ABIL_DEA then
        -- "Calls forth your automaton in an unsound state" - this model
        -- takes that as heavy burden on arrival; seed every element and let
        -- the next maneuvers reconcile the exact values.
        for _, el in ipairs(ELEMENTS) do
            burden[el] = config.dea_burden
            burdenVerified[el] = false   -- seeded value, do not learn from it
            seededBy[el] = 'dea'
            tm.waterSince[el] = { ticks = 0, extra = 0 }   -- as on Activate
        end
        -- Stamped for a Deus Ex as well as a plain Activate: the timed
        -- back-solve is seed-agnostic, so both summons get a reading on
        -- the first maneuver of each element after them. (The variable and
        -- the since_activate log field are named for Activate but cover
        -- both, so every analysis of the log reads one field.)
        tm.activateAt = os.clock()
        -- ...and the recast edge, for the same reason Activate stamps one:
        -- this is a fresh automaton with every recast clear, and no
        -- lifecycle edge will say so. pet_respawn needs lastPetId ~= 0,
        -- and after the previous automaton died it is already 0 - so
        -- without this tm.edgeAt is still that death and since_edge on the
        -- first ability is measured from it.
        timersClear(true, 'dea')
        ids.goneAt, tm.lastTick = nil, os.clock()
        -- ...and the summon says the automaton is bare: see the note in
        -- the Activate branch above.
        tm.petKnown = { [40] = true, [41] = true, [33] = true, [37] = true, [116] = true }
        logEvent('dea_summon', { seeded = config.dea_burden })
        tm.logLoadoutAt = tm.auto044Seq
    elseif abil == 138 then   -- Deploy, LSB abilities.sql
        -- Sent at a mob the automaton has not touched. noteMobEffects has
        -- already run for this very packet, so a Deploy cannot clear the
        -- flag it is about to set.
        local t1 = act.targets[1]
        local id = (t1 ~= nil) and t1.server_id or 0
        if id ~= 0 and id ~= snap.self_id and id ~= snap.pet_id then
            tm.deployTo = id
        end
    elseif abil == 140 then   -- Retrieve, LSB abilities.sql
        -- An explicit disengage: the job script's petRetreat() sends the
        -- automaton back to the master, so neither the mob it was on nor
        -- a Deploy still pending on one describes anything now - and the
        -- mob stays alive and in sight, so the grace could not have
        -- ended either. The client refuses a Retrieve with nothing to
        -- retrieve before any action packet exists (onAbilityCheck), so
        -- one that arrives was carried out. Burden, the recasts and the
        -- mob's own effects are not Retrieve's to touch: it builds no new
        -- automaton and cures nothing.
        tm.petTarget, tm.deployTo = 0, nil
    elseif abil >= ABIL_MANEUVER_FIRST and abil <= ABIL_MANEUVER_FIRST + 7 then
        local el = ELEMENTS[abil - ABIL_MANEUVER_FIRST + 1]
        local pct, overloaded = nil, false
        for _, tgt in ipairs(act.targets) do
            for _, a in ipairs(tgt.actions) do
                if a.message == MSG_OVERLOAD_CHANCE or a.message == MSG_OVERLOADED then
                    pct = a.param
                    overloaded = (a.message == MSG_OVERLOADED)
                end
            end
        end
        if pct ~= nil then
            reconcile(el, pct, overloaded)
        else
            burden[el] = burden[el] + cost[el]
            logEvent('maneuver_no_msg', { element = el, note = 'no overload message in packet' })
        end
    end
end

-- 0x028, our automaton's mob skills: a weaponskill is logged against the
-- prediction, an ability or ranged attack starts its recast clock.
-- priorRes and priorAge are the resonance as it stood before this packet.
local function onPetMobskill(act, priorRes, priorAge)
    -- The known-id allowlist below doubles as the automaton check: a charmed
    -- pet, wyvern or avatar under sub-PUP uses its own family's mobskill ids,
    -- never these, so foreign pets can't pollute the dataset.
    local skillId = act.param

    if skillId == MOBSKILL_RANGED then
        noteUse(skillId, os.clock())
    elseif PET_MOBSKILL[skillId] ~= nil then
        local name = PET_MOBSKILL[skillId]
        tm.fhPending = { ws = name, at = os.clock() }  -- resolved on d3d_present
        -- Prediction comes from the render-thread snapshot - no native
        -- reads on the packet thread for it.
        local expected = tm.predSnapshot
        local rec = { skill_id = skillId, ws = name, expected = expected or 'none',
                      -- WHY it expected that, the same field the spell
                      -- record carries: without it a WS anomaly says which
                      -- skill was wrong but never which of the three
                      -- branches decided it.
                      expected_why = tm.predWhy or '',
                      -- maneuver census at snapshot time; without it a real
                      -- mispredict is indistinguishable from a stale snapshot
                      man = tm.predManeuvers or '?', mode = tm.predMode or '?' }
        -- Resonance as the automaton saw it (priorRes: before this very
        -- packet replaced it), its age, and whether this skill closes it.
        -- Logged even outside the 3-10s window so near-misses show up.
        if priorRes ~= nil then
            local names = {}
            for _, p in ipairs(priorRes.props) do names[#names + 1] = SC_NAME[p] or p end
            rec.resonance = table.concat(names, '+')
            rec.res_age   = math.floor(priorAge * 10) / 10
            rec.res_step  = priorRes.step or 1
            local made = formSkillchain(MOBSKILL_SC[skillId], priorRes.props)
            rec.closed = made and (SC_NAME[made] or made) or false
        end
        if expected ~= nil and expected ~= name then
            flagAnomaly('ws_mispredicted', rec)
        else
            logEvent('pet_ws', rec)
            if config.debug_predictions and expected ~= nil then
                local line = chat.header('clockwork')
                    :append(chat.success(('%s as predicted'):format(name)))
                if config.show_reasoning then
                    line = line:append(chat.message(('- %s'):format(
                        rec.expected_why ~= '' and rec.expected_why or rec.mode)))
                end
                print(line:append(chat.message('- WS')))
            end
        end
    elseif tm.ability[skillId] ~= nil then
        -- Attachment and frame abilities, never weaponskills: each starts
        -- its recast clock and is logged against the model. Deliberately
        -- NOT gated on config.log_all_casts: the model is only worth
        -- having if every use is on record. Roughly a line a minute per
        -- equipped ability.
        noteUse(skillId, os.clock())
    elseif config.log_all_casts then
        -- Unmapped id: an era-specific automaton skill, or a foreign pet
        -- while subbing PUP. Opt-in only, so default logs stay clean.
        logEvent('pet_skill_unknown', { skill_id = skillId })
    end
end

-- 0x028, our automaton's spells, Magic Start and Magic Finish: the windows
-- and recasts, the buffs a finished enhance proves, and each start logged
-- against the prediction.
local function onPetSpell(act)
    -- The start stamps the windows the server stamps (m_Last*Time when
    -- Cast() succeeds); the finish carries the recast it applied.
    -- A Magic Start's action id is the spell's FourCC, NOT the spell id:
    -- every *Cast FourCC ends 0x6163, so unpackAction's 16-bit read at 86 is
    -- 24931 for every cast of every group (an interrupt is 0x7073 = 28787),
    -- and the spell id is the first result's param. A Magic Finish's action
    -- id IS the spell. Reading act.param on a start would look up
    -- SPELL[24931] = nil, so no window would ever close, every record would
    -- name 'spell 24931', and every cast would log as a mispredict.
    local id, start = act.param, (act.category == CAT_MAGIC_START)
    if start then
        local t1 = act.targets[1]
        local a1 = (t1 ~= nil) and t1.actions[1] or nil
        id = (act.param == 24931 and a1 ~= nil) and a1.param or nil
    end
    local row = (id ~= nil) and tm.spellObserve(act.category, id, act.recast, os.clock()) or nil
    -- TryEnhance is a total order - Regen, Protect, Shell, Haste,
    -- Stoneskin, Phalanx - and the AUTOMATON's arm of each buff is
    -- ungated, with no engagement test and no distance test. So a Shell
    -- cast at anyone proves the automaton already holds Protect, a Haste
    -- proves Protect and Shell, and a Stoneskin or Phalanx proves all
    -- three. (A missing lower tier cannot explain the fall-through: every
    -- Protect costs less MP than the Shell beside it and both sit on a 5 s
    -- recast under a 15 s window.)
    -- This is the ONLY way to learn about a buff applied before the
    -- automaton came into view. Nothing announces its own effects, so
    -- petEffects starts empty on every load, and without this the ladder
    -- keeps offering a Protect the automaton already has, prediction after
    -- prediction, against a server that casts it once. A Regen proves
    -- nothing: it may have gone to the master.
    if not start and row ~= nil and row.rung == 'enhance' then
        -- WHICH side gets the Regen is enmity, and the client cannot read
        -- enmity - but the server names its choice every time it casts
        -- one. Keep the last time each side was chosen. A Regen aimed at
        -- a party member is recorded as neither, which is also an answer.
        if id >= 108 and id <= 111 then
            local t1 = act.targets[1]
            local tid = (t1 ~= nil) and t1.server_id or nil
            local who = (tid == snap.pet_id and 'automaton')
                     or (tid == snap.self_id and 'you') or nil
            if who ~= nil then tm.regenAt[who] = os.clock() end
        end
        local rank = ((id >= 43 and id <= 47) and 1) or ((id >= 48 and id <= 52) and 2)
                  or ((id == 57 or id == 511) and 3) or ((id == 54) and 4)
                  or ((id == 106) and 5) or nil
        if rank ~= nil then
            local at = os.clock()
            -- Fresh evidence. A live entry keeps its clock rather than
            -- restarting on every later cast; one that has run out - on
            -- its own clock or the backstop - is revived, clock and all,
            -- so a Protect older than the backstop can still be proved
            -- again by a later Shell.
            local function infer(e)
                if not tm.petLive(e, at) then petEffects[e], tm.petUntil[e] = at, nil end
                tm.petKnown[e] = true
            end
            if rank > 1 then infer(40) end
            if rank > 2 then infer(41) end
            if rank > 3 then infer(33) end
            if rank > 4 then infer(37) end
        end
    end
    if start and id ~= nil then
        -- Against the last frame's snapshot - the state before this
        -- cast, which is what the server chose from. A cast the snapshot
        -- did not name is a mispredict, including one it said would not
        -- come; the two rungs on the record tell a wrong rung from a
        -- wrong pick within the rung, and `windows` tells either of those
        -- from a window that was simply shut. Stamped BEFORE
        -- spellObserve closed them would be wrong, so read the summary
        -- off the snapshot the prediction was made from.
        local s = tm.spell or {}
        local rec = { spell_id = id, name = tm.names[id] or ('spell ' .. id),
                      rung = row and row.rung or '?', windows = s.windows or '',
                      expected = s.name or 'none', expected_rung = s.rung or 'none',
                      expected_why = s.why or '', mode = s.mode or '?', man = tm.predManeuvers or '?',
                      -- What the automaton could afford when the snapshot
                      -- was taken. -1 for both when no 0x044 has arrived
                      -- since the last reload: there is no MP reading then
                      -- and usable() skips the affordability test outright,
                      -- so a mispredict from that stretch cannot be blamed
                      -- on a cost the model got wrong.
                      -- both ends of the interval: mp alone cannot be
                      -- checked afterwards against a cost that fell inside it
                      mp = tm.mp or -1, mp_hi = tm.mpHi or -1,
                      maxmp = tm.maxmp or -1 }
        -- Who it is aimed at, and the HP picture it was chosen from. The heal
        -- and enhance rungs' party arms rest on assumptions (the assumptions
        -- doc, section 3) and these fields are what test them. The party list
        -- is gather()'s, published on the render thread: `name hp% hp` per
        -- member, hp 0 where it was unread.
        do
            local t1 = act.targets[1]
            local tid = (t1 ~= nil) and t1.server_id or 0
            local target = (tid == snap.self_id and 'you') or (tid == snap.pet_id and 'automaton') or nil
            local members = {}
            for _, mem in ipairs(tm.partyNow or {}) do
                if tid == mem.sid then target = mem.name end
                members[#members + 1] = ('%s %d%% %d'):format(mem.name, mem.hpp, mem.hp)
            end
            rec.target = target or ((tid == tm.petTarget) and 'mob') or 'other'
            rec.you_hpp = tm.youHpp
            if #members > 0 then rec.party = table.concat(members, ', ') end
        end
        -- A prediction that HEDGED and then lost to the very thing it
        -- hedged against was not wrong - it said the window might go to a
        -- Regen, and it did. Counting that as a mispredict overstates the
        -- error and buries the real ones in noise: the Regen coin-flip
        -- would be most of what the anomaly line shouts about.
        -- The record keeps `expected` and gains `hedged`, so the rate is
        -- still measurable either way - only the alarm goes quiet.
        local hedged = (s.hedge == 'regen') and id >= 108 and id <= 111
                       and s.name ~= rec.name
        -- ...and the same argument for a pick the model had already
        -- flagged. `uncertain` means it named one of two things it could
        -- not tell apart - an MP cost inside the interval, a tier the two
        -- ends of it disagree about, a party heal whose target is decided
        -- by enmity the client cannot read. Shouting at that as loudly as
        -- at a confident wrong answer overstates the error and buries the
        -- real ones - the same reasoning the hedge gets. The record
        -- keeps `expected` and gains `missed_uncertain`, so the rate stays
        -- measurable; only the alarm and the counter go quiet.
        -- Not every one. `uncertain` alone is too broad: a Regen
        -- pick is uncertain about WHOSE it is, not about being a Regen, so
        -- exempting it would answer for a Protect the model got wrong by
        -- pointing at a target question nobody asked. The exempt cases are
        -- the ones where the alternative is known exactly. An MP-derived
        -- one: the tier the interval's low end would have chosen.
        local unsure = (s.mpUnsure == true) and s.name ~= rec.name and not hedged
        -- ...and a flagged heal. Every doubt a heal pick carries is about its
        -- TARGET - which party member, you or a member, you or the automaton -
        -- and the tier follows the target's missing HP, so the alternative is
        -- some other Cure. A different Cure is excused; anything else is not.
        local cureUnsure = (s.rung == 'heal') and (s.mode == 'uncertain') and (rec.rung == 'heal')
                           and s.name ~= rec.name and not hedged and not unsure
        tm.casts = tm.casts + 1
        if s.name ~= rec.name and not hedged and not unsure and not cureUnsure then
            tm.missed = tm.missed + 1
            flagAnomaly('spell_mispredicted', rec)
        else
            rec.hedged = hedged or nil
            rec.missed_uncertain = (unsure or cureUnsure) or nil
            logEvent('pet_spell', rec)
            if config.debug_predictions then
                local line = chat.header('clockwork')
                    :append(chat.success(('%s as %s'):format(rec.name,
                                         hedged and 'hedged'
                                         or unsure and 'one of two'
                                         or cureUnsure and 'a Cure (tier in doubt)'
                                         or 'predicted')))
                if config.show_reasoning then
                    line = line:append(chat.message(('- %s'):format(
                        rec.expected_why ~= '' and rec.expected_why or rec.rung)))
                end
                print(line)
            end
        end
    end
end

-- 0x028 (action): the parts about anybody's action run first, then the gate
-- to our own character and automaton, then the parts about us.
local function onAction(data)
    if isDuplicate(data) then return end
    -- Snapshot only. Native calls past this point are the exception, not the
    -- rule, and each one is deliberate: reconcile() reads inventory, stats and
    -- resources (its own comment accepts the risk) and logOpen resolves the
    -- character's name. Everything else reads the snapshot.
    if not snap.is_pup then return end

    local act = safe(function() return unpackAction(data) end, nil)
    if act == nil then return end

    local isSelf = (snap.self_id ~= 0 and act.actor_id == snap.self_id)
    local isMine = (snap.pet_id  ~= 0 and act.actor_id == snap.pet_id)

    -- ---- resonance tracking (deliberately ahead of the actor gate) -------
    followPetTarget(act, isMine)
    -- The resonance as it stood BEFORE this packet. The automaton's own
    -- weaponskill replaces it below, so the logger further down must read
    -- this copy - read afterwards, the resonance is always 0s old and the log
    -- would never record what the pet chained off.
    local priorRes, priorAge = rawResonance()
    noteResonance(act)

    -- ---- status landing on our automaton --------------------------------
    -- Also deliberately ahead of the actor gate, and for the same reason: the
    -- actor here is the mob doing the debuffing, not us and not the puppet.
    notePetEffects(act, isMine)

    -- ---- status landing on any mob --------------------------------------
    -- Ahead of the actor gate, and for EVERY target in the packet: the
    -- server's own test, CanUseEnfeeble, is whether the mob carries the
    -- effect from ANYONE, so a party RDM's Paralyze blocks the automaton's
    -- Paralyze just the same - on the mob it is fighting now, or the one it
    -- will be Deployed onto in a moment. Self and the automaton are not mobs;
    -- petEffects and the master's own icons hold those.
    noteMobEffects(act, isSelf, isMine)

    -- ---- HARD ACTOR GATE ------------------------------------------------
    -- Only our own character or our own automaton, matched on ServerId.
    -- This is what stops another player's identically-named puppet from
    -- being counted as ours.
    if not (isSelf or isMine) then return end

    -- ---- our maneuvers --------------------------------------------------
    if isSelf and act.category == CAT_ABILITY then
        onOurAbility(act)
        return
    end

    -- ---- our automaton --------------------------------------------------
    if isMine and act.category == CAT_MOBSKILL then
        onPetMobskill(act, priorRes, priorAge)
    end

    -- ---- our automaton's spells ----------------------------------------
    if isMine and (act.category == CAT_MAGIC_START or act.category == CAT_MAGIC) then
        onPetSpell(act)
    end
end

-- 0x076, the party's buffs - XiPackets world/server/0x0076, the parse HXUI
-- and XIUI use: five 0x30-byte entries from 0x04, each the member's ServerId,
-- then at +0x08 a 64-bit field holding two high bits per buff, then at +0x10
-- the 32 low bytes. The client rebuilds an id as (high << 8) | low and skips
-- 0xFF with no high bits. The master's own buffs never ride in it. Pure string
-- ops: safe on the packet thread.
local function onPartyBuffs(data)
    local out = {}
    for i = 0, 4 do
        local base = 0x04 + 0x30 * i
        local sid = u32le(data, base)
        if sid ~= 0 then
            local fx = {}
            for j = 0, 31 do
                local lo = data:byte(base + 0x10 + j + 1)
                local bits = data:byte(base + 0x08 + math.floor(j / 4) + 1)
                if lo == nil or bits == nil then break end
                local hi = math.floor(bits / 4 ^ (j % 4)) % 4
                if not (lo == 0xFF and hi == 0) then fx[hi * 256 + lo] = true end
            end
            out[sid] = fx
        end
    end
    tm.partyBuffs = out
end

-- packet_in: drops injected packets, then hands each packet we read to its
-- handler by id.
local function onPacket(e)
    if e.injected then return end
    if e.id == 0x044 then
        parseJobExtra(e.data)  -- pure string ops: safe on the packet thread
    elseif e.id == 0x00A then
        onZone()
    elseif e.id == 0x029 then
        onBattleMessage(e.data)
    elseif e.id == 0x028 then
        onAction(e.data)
    elseif e.id == 0x076 then
        onPartyBuffs(e.data)
    end
end

return { unpackAction = unpackAction, onPacket = onPacket }
