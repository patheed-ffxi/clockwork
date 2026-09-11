-- cw/pet.lua - what is on the automaton and who it is: the effect table the
-- battle traffic builds, and the lifecycle (despawn, respawn, a new character)
-- that resets the model. Publishes tm.diaBioTier, tm.diaBioLands,
-- tm.notePetSilent, tm.mobskillEffect, tm.heldCap and tm.petLive; returns the
-- message sets, petEffects and the lifecycle functions.
local config = require('cw.config')
local D  = require('cw.data')
local ELEMENTS = D.ELEMENTS
local tm = require('cw.state')
local U  = require('cw.util')
local safe = U.safe
local L  = require('cw.log')
local logEvent = L.logEvent
local T  = require('cw.timers')
local timersClear = T.timersClear
-- Tables with a stable identity (see cw/state.lua), so safe to alias here.
local burden, ids, burdenVerified, seededBy = tm.burden, tm.ids, tm.burdenVerified, tm.seededBy
local waterSince = tm.waterSince

-- ----------------------------------------------------------- pet status --
-- Nothing tells the client what is on the automaton. No packet carries a pet
-- effect list and none sits in memory: IPlayer:GetStatusIcons is the PLAYER's.
-- That is why maneuvers and Overload read cleanly - automaton.lua onUseManeuver
-- puts both on the master - while the automaton's own buffs and debuffs never
-- appear there at all.
--
-- So the table below is INFERRED from the battle traffic aimed at it, the same
-- way XIUI's pet bar does it (XIUI/handlers/petbuffhandler.lua): a status
-- lands when a message meaning "gains / receives / is <status>" names the
-- automaton as its target, and drops on a wear-off. The cost of that: anything
-- applied before the automaton came into view is invisible, and a wear-off we
-- never received leaves an icon up. Bounded by the clears on despawn, respawn,
-- zone and death, plus MAX_EFFECT_AGE.
--
-- The ids, and the promise that param carries the effect id, are the server's
-- own: LSB msg.lua and msg_basic.h. Only ids
-- confirmed there are listed. Deliberately absent are the Corsair roll
-- messages (420/421/426/427) that XIUI treats as status carriers -
-- OnMobSkillFinished puts the Lua return value in result.param and
-- corsair.lua returns the roll TOTAL, so a roll of 11 would land
-- here as effect 11. A missing icon beats a wrong one.
local MSG_STATUS_ON = {
    [127] = true,  -- JA_ENFEEB_IS
    [160] = true,  -- ADD_EFFECT_STATUS        "Additional effect: Poison" - the add-effect
    [164] = true,  -- ADD_EFFECT_STATUS_2      tail of a hit, param = the effect (additional_effects.lua)
    [186] = true,  -- SKILL_GAIN_EFFECT
    [203] = true,  -- IS_STATUS
    [205] = true,  -- GAINS_EFFECT_OF_STATUS
    [230] = true,  -- MAGIC_GAIN_EFFECT        the automaton's own Protect / Regen
    [236] = true,  -- MAGIC_ENFEEB_IS
    [237] = true,  -- MAGIC_ENFEEB
    [242] = true,  -- SKILL_ENFEEB_IS          mob TP move debuffs land here
    [243] = true,  -- SKILL_ENFEEB
    [266] = true,  -- JA_GAIN_EFFECT
    [267] = true,  -- JA_RECEIVES_EFFECT
    [268] = true,  -- MAGIC_BURST_ENFEEB
    [271] = true,  -- MAGIC_BURST_ENFEEB_IS
    [277] = true,  -- IS_EFFECT
    [278] = true,  -- TARGET_RECEIVES_EFFECT
    [319] = true,  -- SKILL_GAIN_EFFECT_2
    [320] = true,  -- JA_RECEIVES_EFFECT_2
    [375] = true,  -- ITEM_RECEIVES_EFFECT
}
local MSG_STATUS_OFF = {
    [159] = true,  -- SKILL_ERASE
    [168] = true,  -- ADD_EFFECT_DISPEL        "Additional effect: X's Y effect disappears!"
    [204] = true,  -- IS_NO_LONGER_STATUS
    [206] = true,  -- STATUS_WEARS_OFF         how almost everything ends
    [321] = true,  -- JA_REMOVE_EFFECT_2
    [341] = true,  -- MAGIC_ERASE
    [343] = true,  -- TARGET_EFFECT_DISAPPEARS
    [378] = true,  -- ITEM_EFFECT_DISAPPEARS
}
-- The automaton falling over. A real despawn clears through onPetLifecycle as
-- well; this catches the beat before the server drops PetTargetIndex.
local MSG_DEATH = {
    [6]  = true,   -- DEFEATS_TARG
    [20] = true,   -- FALLS_TO_GROUND
    [97] = true,   -- PLAYER_DEFEATED_BY
}
-- Backstop for a wear-off that never arrived. 30 min is the longest era buff
-- (Protect / Shell), so nothing legitimate gets cut short by it.
local MAX_EFFECT_AGE = 1800

-- [effect id] = os.clock() when it last landed. Written on the packet thread,
-- read on the render thread - same arrangement as burden.
local petEffects = {}

local function clearPetEffects()
    tm.clear(petEffects)
    tm.petUntil = {}
    tm.petDiaBio = {}   -- the tiers went with the effects they dated
    -- petKnown is deliberately NOT touched here. A despawn cannot tell a
    -- dismiss from a zone - the entity leaves the table either way - and the
    -- two want opposite answers. The summon itself is the unambiguous signal,
    -- and it is handled where the ability is seen; a zone clears petKnown at
    -- its own site.
    -- The Regen reading below is about THIS automaton's standing with the
    -- mob: a despawn, a death or a zone ends it along with everything else
    -- we knew.
    tm.regenAt = {}
end

-- Effect ids are 10 bits, which is also the range the resource manager has
-- icons for; anything outside it means the field was not an effect id.
local function notePetStatus(message, param)
    if param == nil or param <= 0 or param >= 0x400 then return end
    if MSG_STATUS_ON[message] then
        petEffects[param], tm.petKnown[param] = os.clock(), true
        tm.petUntil[param] = nil   -- a message says nothing about how long
    elseif MSG_STATUS_OFF[message] then
        -- Watching one go is as much a reading as watching one land.
        petEffects[param], tm.petKnown[param] = nil, true
        tm.petUntil[param] = nil
        tm.petDiaBio[param] = nil   -- a Dia/Bio that wore off dates nothing now
    end
end

-- The channels that say NOTHING when they land on the automaton - the mirror
-- of the mob side's silent Dia and Bio. A Dia or Bio cast at it reports only its damage;
-- and 168 of LSB's mob skills add their status from a separate call and
-- return the damage message (Poison Sting: mobPhysicalMove, then
-- mobPhysicalStatusEffectMove, `return dmg`). The client shows nothing for a
-- pet, so the cast and the skill id are the only signals. Each comes with the
-- duration its script passes, so a resisted one clears itself on time rather
-- than sitting on the strip for the 30-minute backstop.
-- The Dia and Bio families share ONE tier ladder, and each spell script checks
-- the other family's tier before touching it: Dia 1, Bio 2, Dia II 3, Bio II 4,
-- Dia III 5, Bio III 6 (the `local tier` in each of the six scripts). A cast
-- replaces the opposite effect only when what is standing there is strictly
-- weaker; otherwise it deals its damage and changes nothing at all - no delete,
-- and no effect of its own added. Deleting unconditionally would wipe a debuff
-- the mob still carries and record one it never got, blocking the ladder's own
-- enfeeble for the life of the wrong entry. XIUI, HXUI and kazenoeye all
-- replace unconditionally; the server does not.
-- The SAME family is gated too: status_effects.sql gives Dia and Bio overwrite
-- mode 1, HIGHER, and the container (status_effect_container.cpp, CanGainStatus
-- Effect) takes a new tier only when it is strictly above the standing one. A
-- Dia into a live Dia II - or a Dia II into a Dia II - does its damage and
-- leaves the effect and its clock alone. Replacing the entry with the weaker
-- tier and a fresh clock would let a Bio I after it displace 'Dia I' where the
-- server still holds Dia II over it.
tm.diaBioTier = { [23] = 1, [230] = 2, [24] = 3, [231] = 4, [25] = 5, [232] = 6,
                  [33] = 1 }   -- Diaga shares Dia's tier (diaga.lua)
-- Does `spell` land, given what the target already carries? Returns the effect
-- it displaces (nil when there is nothing to displace), or false when the cast
-- changes nothing. `heldSpell` is the spell behind the opposite effect and
-- `sameSpell` the one behind the same family's effect, each nil when nothing
-- LIVE is there - the callers ask liveness first.
tm.diaBioLands = function(spell, heldSpell, sameSpell)
    local mine = tm.diaBioTier[spell]
    if mine == nil then return false end
    if sameSpell ~= nil then
        local standing = tm.diaBioTier[sameSpell]
        if standing ~= nil and standing >= mine then return false end
    end
    if heldSpell == nil then return nil end
    local theirs = tm.diaBioTier[heldSpell]
    -- An opposite effect we cannot date (no spell recorded) is treated as
    -- weaker - the unconditional replace other trackers use, kept for the one
    -- case where we genuinely do not know what put it there.
    if theirs == nil or theirs < mine then return true end
    return false
end

-- 300 s: what XIUI gives an enemy status it cannot name, and the same
-- reasoning applies here for the opposite reason. An INFERRED landing is not
-- confirmed by anything - the packet carries only damage, and a resisted one
-- never sends a wear-off - so it must not inherit the flat backstop that a
-- status MESSAGE earns by having actually been announced. Bounded low: the
-- cost of expiring one early is that the ladder offers a spell the automaton
-- cannot cast and learns from the miss; the cost of never expiring it is a
-- rung shut for half an hour with nothing to reopen it.
tm.notePetSilent = function(effect, secs)
    if effect == nil or effect <= 0 or effect >= 0x400 then return end
    local now = os.clock()
    petEffects[effect], tm.petKnown[effect] = now, true
    tm.petUntil[effect] = now + ((secs ~= nil and secs > 0) and secs or 300)
end

-- [mob skill id] = { { effect, seconds }, ... } for the skills whose status
-- lands WITHOUT a status line: LSB scripts/actions/mobskills/*.lua that call
-- a damage move and then mobStatusEffectMove and return the damage message,
-- read with the effect and the UPPER BOUND its duration can reach: a literal
-- where the script passes one, the high end of math.random, calculateDuration
-- evaluated at a mob's 3000 TP cap, and the coefficient of a resist-scaled
-- expression. An upper bound is the right direction - a status that was in
-- fact resisted clears itself no later than a real one would, and a real one
-- that outlives the bound is corrected by its own wear-off message.
-- Four entries are 0, and none of them is a HELD effect, so none can shut the
-- spell line. Ids from sql/mob_skills.sql. Built from upstream LSB - Horizon's
-- scripts may differ, so a status that outlives its bound here is the reading
-- that says so.
tm.mobskillEffect = {}
for id, e, d in ((
    '18:11:15 35:10:4 52:2:180 102:6:120 165:140:120 170:148:60 241:11:30 243:149:120 ' ..
    '245:146:180 247:10:15 258:5:120 289:4:60 291:3:60 294:5:60 299:11:60 302:138:120 ' ..
    '305:3:90 310:3:60 311:4:180 312:8:720 314:6:60 315:5:90 319:3:60 319:4:60 319:5:60 ' ..
    '319:6:60 319:11:60 319:12:60 319:13:60 320:2:60 328:5:45 329:2:60 345:3:0 348:4:180 ' ..
    '349:11:60 351:3:60 354:3:60 355:137:120 361:10:4 366:10:4 369:6:30 371:3:60 376:8:180 ' ..
    '377:4:180 378:10:7 379:13:60 385:31:60 399:5:120 401:10:4 407:3:60 414:10:4 ' ..
    '415:147:120 416:5:120 423:140:120 425:147:180 426:146:120 427:137:120 442:136:180 ' ..
    '450:136:0 457:12:120 458:5:120 462:136:120 463:138:120 466:3:300 469:5:30 474:13:300 ' ..
    '475:147:90 477:5:300 484:5:420 486:10:4 488:136:180 490:8:660 492:5:120 493:4:120 ' ..
    '498:137:90 500:3:30 506:4:120 514:10:4 515:3:120 523:12:120 532:9:420 534:2:90 ' ..
    '535:10:4 540:10:3 548:5:30 560:5:120 570:12:120 581:10:4 583:11:60 605:10:4 606:10:4 ' ..
    '607:11:60 609:137:180 612:10:4 613:10:4 617:3:45 618:10:4 620:10:4 629:10:14 ' ..
    '630:5:120 638:11:90 643:3:180 646:4:960 647:9:420 660:3:60 661:4:120 675:13:120 ' ..
    '676:11:180 677:10:20 687:13:90 720:3:30 721:4:20 723:10:10 771:136:120 777:291:120 ' ..
    '780:10:4 786:149:30 787:146:30 789:3:60 791:12:60 795:7:15 798:11:90 799:11:90 ' ..
    '802:5:180 803:130:90 805:146:180 806:149:180 811:3:120 818:3:0 821:6:120 821:13:120 ' ..
    '831:5:30 832:4:90 852:13:120 855:11:60 856:10:6 860:12:120 888:4:60 891:10:10 ' ..
    '907:3:60 927:5:45 930:3:180 930:11:60 931:10:4 932:2:60 933:6:60 934:10:6 935:3:60 ' ..
    '935:4:60 935:7:60 937:11:30 946:5:60 947:6:60 948:4:60 951:5:30 956:5:30 971:10:4 ' ..
    '983:10:15 985:6:30 986:11:30 986:28:9 991:11:10 995:11:10 997:10:15 999:11:10 ' ..
    '1001:10:15 1001:11:30 1006:7:45 1028:10:4 1036:10:4 1074:12:10 1081:10:4 1110:10:4 ' ..
    '1127:10:7 1131:136:120 1133:5:120 1133:6:120 1133:11:120 1133:12:120 1148:10:6 ' ..
    '1159:136:120 1159:138:120 1160:140:120 1160:141:120 1161:10:15 1172:4:360 1173:9:60 ' ..
    '1192:146:60 1193:149:60 1196:4:60 1199:147:60 1218:3:60 1218:31:30 1229:4:90 1231:3:180 ' ..
    '1237:11:15 1243:13:60 1253:10:4 1258:134:30 1262:31:120 1263:4:120 1264:6:30 ' ..
    '1265:7:45 1266:10:4 1267:3:120 1279:31:120 1284:31:120 1289:4:120 1294:4:120 ' ..
    '1299:5:30 1304:13:120 1309:2:60 1326:10:4 1328:5:120 1335:3:180 1335:12:120 ' ..
    '1335:31:60 1338:31:780 1347:10:4 1349:12:45 1353:149:75 1355:31:120 1356:6:120 ' ..
    '1357:11:60 1357:12:120 1365:4:60 1371:11:90 1372:12:120 1373:10:5 1378:13:60 1379:6:120 ' ..
    '1380:10:4 1380:149:60 1383:4:60 1384:3:180 1385:31:60 1386:7:60 1392:5:60 1393:6:60 ' ..
    '1394:4:60 1431:10:7 1449:2:60 1465:7:60 1466:10:4 1467:3:180 1468:31:60 1469:6:60 ' ..
    '1496:9:45 1497:31:120 1499:10:10 1521:12:45 1527:149:60 1528:5:120 1528:6:60 ' ..
    '1528:156:20 1530:4:120 1542:11:30 1580:10:15 1604:3:180 1612:5:45 1620:3:180 ' ..
    '1697:13:60 1714:10:4 1743:7:40 1758:10:4 1780:10:45 1790:128:60 1800:3:60 1800:13:120 ' ..
    '1800:31:60 1802:7:60 1804:16:60 1807:3:120 1807:4:120 1807:5:120 1807:6:120 ' ..
    '1807:11:120 1807:13:120 1807:31:120 1812:11:30 1813:7:30 1816:128:3 1817:5:150 ' ..
    '1820:128:3 1828:31:60 1830:4:60 1832:12:60 1936:10:4 1954:134:50 1959:6:60 1963:4:180 ' ..
    '1998:3:120 1999:10:4 2001:10:4 2003:16:60 2004:6:60 2024:149:0 2027:31:60 ' ..
    '2027:135:60 2028:4:60 2028:10:4 2032:6:60 2032:11:30 2032:16:30 2033:11:30 ' ..
    '2038:12:60 2040:11:30 2043:12:60 2045:11:30 2046:12:60 2048:11:30 2049:12:60 ' ..
    '2051:11:30 2055:11:30 2056:4:180 2083:11:60 2104:4:90 2110:10:4 2114:12:60 2116:9:60 ' ..
    '2117:9:60 2118:146:60 2118:147:60 2118:149:60 2119:28:15 2128:11:30 2129:10:4 ' ..
    '2141:167:60 2153:11:30 2154:31:60 2163:149:120 2170:10:4 2170:149:120 2178:10:4 ' ..
    '2181:146:60 2183:12:45 2183:177:45 2184:135:120 2184:144:120 2185:147:120 2185:149:120 ' ..
    '2188:13:60 2188:31:60 2189:5:60 2189:6:60 2193:11:120 2194:11:120 2194:16:120 ' ..
    '2200:29:60 2219:135:60 2360:12:120 2411:11:30 2413:16:60 2413:135:60 2422:12:60 ' ..
    '2427:16:60 2430:144:60 2430:145:60 2432:6:60 2435:149:60 2436:4:100 2438:28:30 ' ..
    '2439:177:30 2549:3:6 2562:167:120 2563:129:120 2563:136:60 2563:137:60 2563:138:60 ' ..
    '2563:139:60 2563:140:60 2563:141:60 2563:142:60 2578:20:30 2629:149:60 2629:167:60 ' ..
    '2891:10:10 2892:128:20 2893:149:60 2893:167:60 2894:11:20 2922:28:30 2923:7:30 ' ..
    '2924:149:60 2924:167:60 2925:12:30 2925:144:60 2953:128:90 3189:10:4 3215:167:60 ' ..
    '3243:10:10 3466:4:60 3467:6:60 3468:11:60 3506:128:60 3968:31:60 3968:128:60 ' ..
    '3969:4:60 3969:129:60 3970:10:15 3970:132:60 3971:7:60 3971:131:60 3972:3:60 ' ..
    '3972:133:60 3973:6:60 3973:130:60 3974:10:15 3974:93:60 3975:144:60 3975:189:60'
)):gmatch('(%d+):(%d+):(%d+)') do
    local list = tm.mobskillEffect[tonumber(id)] or {}
    list[#list + 1] = { tonumber(e), tonumber(d) }
    tm.mobskillEffect[tonumber(id)] = list
end

-- The longest each casting-blocker can run, across every source that applies
-- it: Silence and Mute cap at the 120 s spells plus a margin, Sleep at
-- Sleep II's 90 and Lullaby's 120, Stun at the longest mob-skill 20 s, Petrify
-- and Terror at 60. These are the effects HELD reads, and HELD shuts the spell
-- line outright - so a wear-off message that never arrives (out of range, a
-- dropped packet) would otherwise shut it for the buff backstop's THIRTY MINUTES.
-- Aging them on their own scale bounds that to something the effect could
-- plausibly still be, and the ladder simply reopens and learns from the miss.
tm.heldCap = { [6] = 180, [29] = 180, [2] = 120, [19] = 120, [193] = 120,
               [10] = 30, [7] = 60, [28] = 60 }

-- Is an effect still believed on the automaton? Its own clock when the
-- landing came with one, otherwise its own cap if it has one, else the flat
-- backstop.
tm.petLive = function(id, now)
    local at = petEffects[id]
    if at == nil then return false end
    local ends = tm.petUntil[id]
    if ends ~= nil then return now < ends end
    return now - at <= (tm.heldCap[id] or MAX_EFFECT_AGE)
end

-- ---------------------------------------------------------------- ident --
-- ServerId based. Never match on name: automaton names come from a fixed
-- list and collide between players.
-- Zeroes the model: /cw reset, /cw sync and forgetCharacter (a different
-- character in the world). NOT called on despawn - see
-- onPetLifecycle: in this model a lifecycle edge is not what changes
-- burden, the Activate is, and the 0x028 handler seeds on that.
local function resetModel(reason)
    for _, el in ipairs(ELEMENTS) do
        burden[el] = 0
        burdenVerified[el] = false
        seededBy[el] = nil
        waterSince[el] = { ticks = 0, extra = 0 }
    end
    timersClear(false)
    tm.eqCache = nil
    ids.goneAt = nil
    if reason ~= nil then logEvent('model_reset', { reason = reason }) end
end

-- A different character is in the world. Everything this state says about
-- the automaton, its loadout, the mobs and the costs the session learned is
-- the last character's; left alone, the Loadout tab would go on offering that
-- loadout as current until the new character's first 0x044. A 0x044
-- that arrived while no frame ran - the zone-in of the new character comes
-- with one, during the loading screen - is the new character's and is kept.
local function forgetCharacter(keep044)
    -- resetModel without a reason: the record it would write belongs to
    -- neither character, and the log opens the new one's file on the same
    -- identity change anyway
    resetModel(nil)               -- burden, the timers (petTarget, deployTo), eqCache
    tm.dropLearnedCosts(true)
    clearPetEffects()
    tm.petKnown = {}
    tm.mobs, tm.touched = {}, {}
    tm.lastPetId = 0
    tm.logLoadoutAt = nil
    if not keep044 then
        tm.auto044 = nil
        tm.auto044Seq = tm.auto044Seq + 1   -- equippedSet() and equippedNames() cache per sequence
    end
end

-- Upstream LSB builds a fresh zero-burden CAutomatonEntity on every summon
-- (petutils.cpp). This model assumes a Horizon automaton does not arrive at
-- zero: about 105 on every element after a Deus Ex Automata (dea_burden) and
-- 29 after a plain Activate (activate_burden) - a seed, not a carry-over of
-- the previous automaton's values. The seeding happens
-- where the ability is seen, in the 0x028 handler; these edges only clear
-- per-incarnation state and log.
-- How long after a zone a lifecycle edge is still PART of that zone rather
-- than a new event. The client loses the automaton's entity across the loading
-- screen and finds it again on the far side, which reads here as a despawn and
-- a respawn - but the automaton never left, so relabelling the edge would
-- blame the recast clear on the wrong thing and measure since_edge from the
-- wrong moment. Whether the frame that sees PetTargetIndex == 0 runs before or
-- after the 0x00A is a race; this keeps the edge's provenance independent of
-- it. A real dismissal made within the window is
-- mislabelled `zone`, which costs a log label on a rare case. Ten seconds,
-- inline rather than named.
local function onPetLifecycle(edge)
    -- The zone already stamped this edge and said what made it.
    if tm.edgeSrc == 'zone' and tm.edgeAt ~= nil and os.clock() - tm.edgeAt <= 10 then
        tm.eqCache = nil
        clearPetEffects()
        logEvent(edge, { in_zone = true })
        return
    end
    timersClear(true, edge)   -- a fresh automaton: every recast clear
    tm.eqCache = nil  -- frame may differ on the next automaton
    -- Burden survives a resummon in this model; an inferred effect list cannot -
    -- it belonged to the automaton that just left. The new one starts bare,
    -- and that IS knowledge.
    clearPetEffects()
    logEvent(edge, {})
end

local function resolveIds()
    safe(function()
        local pe = GetPlayerEntity()
        ids.self_id = (pe and pe.ServerId) or 0
        -- Upstream LSB zero-initialises burden on Activate (petutils.cpp);
        -- this model assumes Horizon does NOT follow upstream here: a summon
        -- seeds (Deus Ex Automata about 105, a plain Activate about 29 -
        -- config.dea_burden, config.activate_burden), and the 0x028 handler
        -- does that seeding as the ability is seen. These edges only clear the
        -- timing state.
        -- Separately: distinguish a real despawn (the server clears
        -- PetTargetIndex) from draw-distance culling (PetTargetIndex stays set
        -- while the entity slot empties) - a culled automaton is alive with its
        -- burden intact.
        if pe and pe.PetTargetIndex and pe.PetTargetIndex ~= 0 then
            local pet = GetEntity(pe.PetTargetIndex)
            if pet and pet.ServerId and pet.ServerId ~= 0 then
                ids.pet_id, ids.pet_index = pet.ServerId, pe.PetTargetIndex
                -- Back with no Activate in between: the automaton was carried
                -- ACROSS A ZONE, not resummoned. LSB keeps a non-charmed pet
                -- through CZoneEntities::DecreaseZoneCounter - status goes
                -- DISAPPEAR but PPet stays non-null - and burdenTick is gated on
                -- PPet (status_effect_container.cpp), so the server decays the
                -- whole time the client cannot see the pet, while decay() below
                -- is frozen on ids.pet_id == 0. Uncorrected, a DEA seed of 105,
                -- a warp to town and a zone back leave the model far above the
                -- real value, and the reseed that follows back-solves a false
                -- implied_seed - poisoning the very reading dea_burden is
                -- calibrated from.
                -- The catch-up is at the BASE rate: Water maneuvers during the
                -- gap are not observable, so this is an estimate and the values
                -- go UNVERIFIED to say so. The next maneuver reseeds off a real
                -- observation, which is the same path a DEA seed takes.
                if tm.lastPetId == 0 and ids.goneAt ~= nil then
                    local gap   = math.max(0, os.clock() - ids.goneAt)
                    local ticks = math.floor(gap / config.tick_seconds)
                    if ticks > 0 then
                        for _, el in ipairs(ELEMENTS) do
                            burden[el] = math.max(0, burden[el] - (ticks * config.decay_per_tick))
                            burdenVerified[el] = false
                        end
                        -- decay() runs immediately after resolveIds on this same
                        -- frame. A zone is a loading screen, so no frames ran
                        -- during the gap and ITS lastTick is just as far behind -
                        -- without this it would apply the same gap a second time.
                        tm.lastTick = os.clock()
                        logEvent('burden_catchup', { gone = math.floor(gap), ticks = ticks,
                                                     per_tick = config.decay_per_tick })
                    end
                end
                ids.goneAt = nil
                if tm.lastPetId ~= 0 and pet.ServerId ~= tm.lastPetId then
                    onPetLifecycle('pet_respawn')
                end
                tm.lastPetId = pet.ServerId
            else
                -- culled: keep the id for packet attribution, drop the index
                -- so petInfo() doesn't read an empty entity slot
                ids.pet_id, ids.pet_index = tm.lastPetId, 0
            end
        else
            ids.pet_id, ids.pet_index = 0, 0
            if tm.lastPetId ~= 0 then
                tm.lastPetId = 0
                ids.goneAt = os.clock()   -- when decay() stopped; the catch-up needs it
                onPetLifecycle('pet_despawn')
            end
        end
    end)
end

return { MSG_STATUS_ON = MSG_STATUS_ON, MSG_STATUS_OFF = MSG_STATUS_OFF, MSG_DEATH = MSG_DEATH,
         MAX_EFFECT_AGE = MAX_EFFECT_AGE, petEffects = petEffects, clearPetEffects = clearPetEffects,
         notePetStatus = notePetStatus, resetModel = resetModel,
         resolveIds = resolveIds, forgetCharacter = forgetCharacter }
