-- cw/burden.lua - the overload model: the stat check and the cost of a maneuver,
-- burden and its decay, the live maneuvers, and the weaponskill predictor.
-- Exports those functions (return table at the end); publishes
-- tm.dropLearnedCosts, tm.refreshStatChecks (cw/settings.lua calls it when a
-- saved stat lands), tm.frameNow and tm.scMiss, and writes the weaponskill
-- snapshot the packet thread reads (tm.predSnapshot, tm.predWhy, tm.predMode).
local config = require('cw.config')
local D  = require('cw.data')
local ELEMENTS, EFFECT_OVERLOAD, EFFECT_MANEUVER_1, SC_NAME = D.ELEMENTS, D.EFFECT_OVERLOAD, D.EFFECT_MANEUVER_1, D.SC_NAME
local SC_PAIRS, MOBSKILL_SC, MANEUVER_STAT, PLAYER_STAT_INDEX = D.SC_PAIRS, D.MOBSKILL_SC, D.MANEUVER_STAT, D.PLAYER_STAT_INDEX
local SLOT_HANDS, WS_LISTS = D.SLOT_HANDS, D.WS_LISTS
local tm = require('cw.state')
local U  = require('cw.util')
local safe, player, equippedItemId, itemName = U.safe, U.player, U.equippedItemId, U.itemName
local equippedThreshold, equippedManeuverBonus = U.equippedThreshold, U.equippedManeuverBonus
local L  = require('cw.log')
local logEvent, flagAnomaly = L.logEvent, L.flagAnomaly
local R  = require('cw.reading')
local equippedNames, hasAttachment = R.equippedNames, R.hasAttachment
local A  = require('cw.attachments')
local maneuverStep = A.maneuverStep
-- The shared tables, never reassigned after cw/state.lua creates them.
local burden, cost, samples, ids = tm.burden, tm.cost, tm.samples, tm.ids
local snap, costSource, costDispute, burdenVerified = tm.snap, tm.costSource, tm.costDispute, tm.burdenVerified
local castThresh, castStat, seededBy, lastReconcile = tm.castThresh, tm.castStat, tm.seededBy, tm.lastReconcile
local waterSince = tm.waterSince
local castBonus = tm.castBonus

-- Your side of the stat check, read from memory now.
local function myStat(el)
    local statName = MANEUVER_STAT[el]
    if statName == 'MP' then
        -- Current MP is a party-slot read; IPlayer only has GetMPMax.
        return safe(function() return AshitaCore:GetMemoryManager():GetParty():GetMemberMP(0) end, nil)
    end
    local idx = PLAYER_STAT_INDEX[statName]
    return safe(function()
        local p = player()
        return p:GetStat(idx) + (p:GetStatModifier(idx) or 0)
    end, nil)
end

-- The stat you have on when this element's maneuver goes off, when you have
-- told the addon what it is (config.stat_check as a number). It outranks the
-- live read because the live read cannot see a gear-swap set: no 0x061 follows
-- an equip, so IPlayer still holds the stats of whatever was worn at the last
-- refresh. Dark is excluded - it compares MP, which is read live and current.
local function statOverride(el)
    if el == 'Dark' then return nil end
    local v = config.stat_check and config.stat_check[el] or nil
    return (type(v) == 'number') and v or nil
end

-- The server's rule, evaluated directly:
--   non-Dark: your effective stat <  automaton's -> 20, else 15
--   Dark:     your MP             <  automaton's -> 15, else 10
-- `mine` overrides the live read (the stat you had on when the element last
-- resolved). Returns cost, playerValue, petValue - cost is nil without data.
local function computeCost(el, mine)
    local statName = MANEUVER_STAT[el]
    local theirs = nil
    if tm.auto044 ~= nil then
        theirs = (statName == 'MP') and tm.auto044.mp or tm.auto044[statName]
    end
    mine = statOverride(el) or mine or myStat(el)
    -- A zero stat means the 0x044 has not populated - except MP, where 0 is
    -- the real value for Valoredge and Sharpshot (and 0 < 0 is false: cost 10).
    if mine == nil or theirs == nil or (theirs == 0 and statName ~= 'MP') then
        return nil, mine, theirs
    end
    local hi = (el == 'Dark') and config.dark_cost or config.default_cost
    local lo = hi - 5
    return (mine < theirs) and hi or lo, mine, theirs
end


local function threshFor(el)
    return castThresh[el] or snap.thresh
end

local function applyStatCheck(el)
    local want = config.stat_check and config.stat_check[el] or nil
    local hi = (el == 'Dark') and config.dark_cost or config.default_cost
    local lo = hi - 5
    if want == 'lose' then
        cost[el], costSource[el] = hi, 'set'
        return
    elseif want == 'win' then
        cost[el], costSource[el] = lo, 'set'
        return
    end
    -- A cost the server taught us outranks one we computed: the computation
    -- is the thing under suspicion. /cw reset clears it, and so does a frame
    -- change - see tm.dropLearnedCosts.
    if costSource[el] == 'observed' then return end
    -- Your side of the check is the number you set for this element, and
    -- failing that the stat read when the element last resolved - neither of
    -- which is what you idle in. The automaton's side is always the freshest
    -- 0x044.
    local computed = computeCost(el, castStat[el])
    if computed ~= nil then
        cost[el], costSource[el] = computed,
            (statOverride(el) ~= nil) and 'yours'
            or (castStat[el] and 'cast' or 'computed')
    else
        cost[el], costSource[el] = hi, 'assumed'
    end
end

-- Drop what the session LEARNED about cost and let the computation have
-- another go. costSource 'observed' is a freeze - applyStatCheck returns early
-- on it - so nothing else can ever unstick it, and the run of disputes behind
-- it was measured against one automaton's stats and one set of gear.
-- `hard` also drops the per-maneuver observations the panel predicts with, which
-- only a reset should do.
tm.dropLearnedCosts = function(hard)
    for _, el in ipairs(ELEMENTS) do
        if costSource[el] == 'observed' then costSource[el] = nil end
        costDispute[el] = nil
        if hard then castStat[el], castThresh[el], castBonus[el] = nil, nil, nil end
    end
end

-- Recompute every element whenever fresh automaton data arrives. Maneuvers
-- raise the automaton's stats, so a check can genuinely flip mid-fight.
local function refreshStatChecks()
    for _, el in ipairs(ELEMENTS) do applyStatCheck(el) end
end

for _, el in ipairs(ELEMENTS) do
    burden[el] = 0
    burdenVerified[el] = false
    waterSince[el] = { ticks = 0, extra = 0 }
    applyStatCheck(el)
end

-- =========================================================== burden math =
-- LSB getOverloadChance has NO threshold gate: clamp(burden - thresh + 5, 0, 255).
-- The *roll* is gated on burden > thresh, but the reported chance is not, so the
-- server reports 1-5% in the (thresh-5, thresh] band. Gating here would produce
-- deterministic false anomalies on perfectly-modelled maneuvers.
local function predict(el)
    local b = burden[el] + cost[el]
    return math.max(0, math.min(100, b - threshFor(el) + 5)), b
end

local function overloadDuration(el)
    local _, b = predict(el)
    return math.max(0, b - threshFor(el))
end

-- decay() sits after maneuverCounts(), below: the Heatsink term needs the
-- live Water count.

local function meanAbsError()
    if #samples == 0 then return nil end
    local s = 0
    for _, x in ipairs(samples) do s = s + math.abs(x.err) end
    return s / #samples
end

-- The cost learner: what one reading says about the cost of this element's
-- maneuver. `implied` is the burden the server added and `sound` whether it
-- is a genuine measurement (see reconcile). A cost pinned by config or by a
-- run of contradictions is left alone; with no automaton stat block yet the
-- reading is all there is; otherwise the live comparison stands unless a run
-- of sound readings agrees on another legal cost. Returns whether a learned
-- cost changed.
local function learnCost(el, implied, castCost, sound, mine, theirs, statName, thresh, hands)
    local hi = (el == 'Dark') and config.dark_cost or config.default_cost
    local lo = hi - 5
    local near = nil
    if     math.abs(implied - lo) <= 3 then near = lo
    elseif math.abs(implied - hi) <= 3 then near = hi end

    local learned = false
    if costSource[el] == 'set' or costSource[el] == 'observed' then
        -- pinned by config, or by a run of contradictions: nothing to learn
    elseif theirs == nil then
        -- No automaton stat block yet, so inference is all there is. Nearest-
        -- value rounding of anything in [5,25] would tell a 40 STR master it
        -- was beating a 66 STR automaton, hence the +-3 window.
        if sound and near ~= nil then
            learned = (near ~= cost[el])
            cost[el], costSource[el] = near, 'learned'
        elseif sound and implied > 0 then
            logEvent('cost_unlearnable', { element = el, implied = implied })
        end
    elseif sound and math.abs(implied - castCost) > 3 then
        -- The server charged something other than the live comparison says.
        -- One sample is noise - the automaton's stat moves with every maneuver
        -- of that element and the 0x044 may lag it. A RUN of them all pointing
        -- at the same legal cost means the comparison itself is wrong, and the
        -- observation is the better authority.
        local d = costDispute[el]
        if near == nil then
            costDispute[el] = nil
        elseif d ~= nil and d.value == near then
            d.count = d.count + 1
        else
            costDispute[el] = { value = near, count = 1 }
        end
        local rec = { element = el, live_cost = castCost, implied = implied,
                      stat = statName, my_stat = mine or -1, pet_stat = theirs or -1,
                      pet_base = (tm.auto044 and tm.auto044.base and statName ~= 'MP')
                                 and tm.auto044.base[statName] or -1,
                      thresh = thresh, hands = hands, man = tm.predManeuvers or '?' }
        -- A stat you set yourself is the likeliest thing to be wrong here:
        -- food, a debuff, a sub job or new gear all move it and nothing tells
        -- the addon. Say so on the record, and in the chat line.
        if statOverride(el) ~= nil then
            rec.note = ('your %s setting (%d) may be out of date'):format(statName, mine or -1)
        end
        if costDispute[el] ~= nil and costDispute[el].count >= 3 and near ~= castCost then
            rec.was, rec.now = castCost, near
            cost[el], costSource[el] = near, 'observed'
            costDispute[el] = nil
            logEvent('cost_override', rec)
        else
            rec.run = costDispute[el] and costDispute[el].count or 0
            flagAnomaly('stat_check_drift', rec)
        end
    else
        -- The live comparison stands (or nothing sound contradicts it): that
        -- is the cost, and with castStat remembered the panel predicts with it.
        if sound then costDispute[el] = nil end
        cost[el], costSource[el] = castCost,
            (statOverride(el) ~= nil) and 'yours' or 'cast'
    end
    return learned
end

-- The server told us the true chance. Back-solve burden, learn the cost,
-- resync so drift cannot accumulate, and log any disagreement.
local function reconcile(el, actualPct, overloaded)
    local wasVerified = burdenVerified[el]
    local before      = burden[el]
    local shown       = select(1, predict(el))   -- what the panel was showing
    -- The server's inputs, read NOW. The threshold and your stat are those of
    -- the gear worn when the maneuver resolves, and the 0x028 lands while that
    -- gear is still on - including a gear-swap addon's maneuver set, if one is
    -- used (LuaShitaCast, for one, holds it for AbilityDelay, 2.5s) - so the
    -- stats and the hands/neck in memory are what the server just compared.
    -- Read at idle instead, they would charge 20 on every check the set wins.
    -- These are IPlayer / IInventory struct reads - the same ones luashitacast
    -- makes in its own packet handlers; the SEH hazard is entity-slot churn.
    local thresh = equippedThreshold()
    local castCost, mine, theirs = computeCost(el)
    -- The raw comparison is what the record keeps for diagnosis (raw_cost).
    -- The MODEL's cost is the stored one whenever it was pinned by config or
    -- taught by a run of contradictions - applyStatCheck says the computation
    -- is the thing under suspicion then - so the prediction graded here is the
    -- one the panel showed. Predicting with the raw comparison regardless
    -- would cry burden_mismatch on every maneuver whose reading agrees with
    -- the pin exactly: +5 with err_shown 0.
    local rawCost = castCost
    if costSource[el] == 'set' or costSource[el] == 'observed' then castCost = cost[el] end
    if castCost == nil then castCost = cost[el] end
    local predicted = math.max(0, math.min(100, before + castCost - thresh + 5))

    local censored = (actualPct == 0)
    local trueBurden
    if censored then
        -- 0% is clamped: it only tells us burden <= thresh - 5, not the value.
        trueBurden = math.min(before + castCost, thresh - 5)
    else
        trueBurden = actualPct + thresh - 5
    end

    local implied = trueBurden - before
    -- implied is a genuine cost measurement only when the burden before the
    -- maneuver was itself observed, this reading is not clamped, and no Water
    -- maneuver ran during the gap: with Heatsink a Water tick takes extra
    -- burden off, so a 15 read against a live 20 is as likely faster decay as
    -- a won check. The burden itself still resyncs from the reading.
    local wsince   = waterSince[el]
    local waterT, extraD = wsince.ticks, wsince.extra
    wsince.ticks, wsince.extra = 0, 0
    local sound    = wasVerified and not censored and waterT == 0
    local statName = MANEUVER_STAT[el]
    local hands    = itemName(equippedItemId(SLOT_HANDS))
    if mine ~= nil then castStat[el] = mine end
    local learned = learnCost(el, implied, castCost, sound, mine, theirs, statName, thresh, hands)

    local err = predicted - actualPct
    burden[el] = trueBurden
    burdenVerified[el] = not censored
    castThresh[el] = thresh
    castBonus[el]  = equippedManeuverBonus()   -- the hands the server just read, like thresh
    samples[#samples + 1] = { element = el, predicted = predicted, actual = actualPct, err = err }
    while #samples > config.max_samples do table.remove(samples, 1) end

    local now = os.clock()
    local rec = { element = el, predicted = predicted, shown = shown, actual = actualPct,
                  err = err, err_shown = shown - actualPct,
                  burden_before = before, burden = trueBurden, thresh = thresh,
                  cost = castCost, raw_cost = rawCost or -1, implied = implied, censored = censored,
                  overloaded = overloaded and true or false, verified = wasVerified,
                  stat = statName, my_stat = mine or -1, pet_stat = theirs or -1,
                  hands = hands, man = tm.predManeuvers or '?',
                  ticks = lastReconcile[el]
                          and math.floor((now - lastReconcile[el]) / config.tick_seconds) or -1,
                  -- ticks with a Water maneuver up since this element last
                  -- resolved, and the extra decay Heatsink took over them
                  water_ticks = waterT, extra_decay = extraD }
    lastReconcile[el] = now
    if seededBy[el] ~= nil and tm.activateAt ~= nil then
        -- The first maneuver of this element since the summon - EITHER kind:
        -- seconds after it, the burden before it that the server implies (an
        -- upper bound when censored), and the seed that would have predicted
        -- it: the base rate over every tick since the summon, plus the extra a
        -- Water maneuver and Heatsink took off over that window (extraD;
        -- waterSince is reset at the summon so it covers exactly this gap).
        -- The base rate alone would under-read the seed by the boost whenever
        -- Water went up before this element's first maneuver.
        -- Logged whichever branch below takes the record, so a seed that is
        -- RIGHT still produces a reading. Logged on a reseed alone, a correct
        -- dea_burden would log nothing at all and look, to anyone grepping
        -- implied_seed, like it had never been tested.
        -- Leans on the decay assumption in proportion to `since`, so a
        -- maneuver soon after the summon is worth much more than a late one.
        local since = now - tm.activateAt
        rec.since_activate = math.floor(since)
        rec.pre_cast       = trueBurden - castCost
        rec.implied_seed   = rec.pre_cast
                             + math.floor(since / config.tick_seconds) * config.decay_per_tick
                             + extraD
    end

    -- err is exact in chance space even for a censored reading (a correct
    -- model predicts 0 there), so flag regardless of censoring; censoring
    -- only blurs the burden back-solve and the cost learner above.
    -- wasVerified is false right after a Deus Ex seed, a manual sync or a
    -- (re)load: the model was knowingly on a guess, so a disagreement is
    -- expected rather than anomalous. Record it as a reseed, not an alarm -
    -- otherwise every first maneuver after a DEA cries wolf. It has to be the
    -- flag from BEFORE this reading: burdenVerified after the assignment above
    -- would make every non-zero reading a "mismatch" and every 0% reading a
    -- "reseed".
    if math.abs(err) > config.burden_tolerance and not wasVerified then
        rec.note = 'model was on a seeded guess, not an observation'
        -- The seed reading is implied_seed above, seed-agnostic and the same
        -- for both summons. A Deus Ex back-solve from the configured seed
        -- (`dea_burden + implied - castCost`) would fold that seed back into
        -- its own answer, so a wrong model would contaminate it twice over.
        logEvent('burden_reseed', rec)
    elseif math.abs(err) > config.burden_tolerance then
        flagAnomaly('burden_mismatch', rec)
    else
        -- Every maneuver is logged: anomalies alone cannot show decay, the
        -- stat check flipping with stacks, or what a DEA really seeded.
        rec.learned = learned or nil
        logEvent('maneuver', rec)
    end
    seededBy[el] = nil
end

-- ----------------------------------------------------- maneuver state ---
-- GetStatusTimers returns ABSOLUTE expiry stamps in 1/60s since the Vana'diel
-- epoch, not seconds remaining. Conversion per statustimers/party.lua.
-- The stamps come from the SERVER clock, so read the game's server-synced UTC
-- stamp from memory (statustimers/party.lua); the PC clock can be
-- skewed against it. Falls back to os.time() if the read fails.
local VANA_EPOCH = 0x3C307D70
local utcStampPtr = nil
local function gameUtcStamp()
    if utcStampPtr == nil then
        utcStampPtr = ashita.memory.find('FFXiMain.dll', 0,
            '8B0D????????8B410C8B49108D04808D04808D04808D04C1C3', 2, 0)
    end
    if utcStampPtr == nil or utcStampPtr == 0 then return os.time() end
    local p = ashita.memory.read_uint32(utcStampPtr)
    if p == nil or p == 0 then return os.time() end
    p = ashita.memory.read_uint32(p)
    if p == nil or p == 0 then return os.time() end
    local stamp = ashita.memory.read_uint32(p + 0x0C)
    if stamp == nil or stamp == 0 then return os.time() end
    return stamp
end
local function timerToSeconds(raw)
    if raw == nil then return 0 end
    local offset = (safe(gameUtcStamp, os.time()) - VANA_EPOCH) * 60
    local rem = raw - offset
    while rem < -2147483648 do rem = rem + 0xFFFFFFFF end
    if rem < 1 then return 0 end
    return math.ceil(rem / 60)
end

local function activeManeuvers()
    if tm.demo ~= nil then return tm.demo.maneuvers, tm.demo.overload end
    local out, overload = {}, nil
    safe(function()
        local p      = player()
        local icons  = p:GetStatusIcons()
        local timers = p:GetStatusTimers()
        if icons == nil then return end
        for i = 0, 31 do
            local id = icons[i + 1]
            if id ~= nil then
                if id == EFFECT_OVERLOAD then
                    overload = timerToSeconds(timers and timers[i + 1])
                end
                if id >= EFFECT_MANEUVER_1 and id <= EFFECT_MANEUVER_1 + 7 then
                    out[#out + 1] = { element = ELEMENTS[id - EFFECT_MANEUVER_1 + 1],
                                      remaining = timerToSeconds(timers and timers[i + 1]) }
                end
            end
        end
    end)
    table.sort(out, function(a, b) return (a.remaining or 0) < (b.remaining or 0) end)
    return out, overload
end

-- ------------------------------------------------ weaponskill prediction -
local function maneuverCounts()
    local c = {}
    for _, el in ipairs(ELEMENTS) do c[el] = 0 end
    local total = 0
    for _, m in ipairs(activeManeuvers()) do
        c[m.element] = c[m.element] + 1
        total = total + 1
    end
    return c, total
end

-- What the 1st, 2nd and 3rd maneuver of an element costs, as three values.
-- Here rather than up with the cost math because it needs maneuverCounts(),
-- as decay() does.
--
-- Every maneuver raises the automaton's own matching stat, so a check won bare
-- can be lost by the third - which is worth knowing BEFORE the first is used.
-- The automaton's stat is read with whatever is already up, so the ladder is
-- taken off its bare value. The step you are ON is the model's live cost,
-- whatever its source, so this can never contradict the chance the rest of the
-- HUD predicts with; a step with nothing to compare is nil.
local function costLadder(el)
    local hi = (el == 'Dark') and config.dark_cost or config.default_cost
    local lo = hi - 5
    local _, mine, theirs = computeCost(el, castStat[el])
    local step = maneuverStep(el)
    local n    = math.min(maneuverCounts()[el] or 0, 3)
    local bare = (theirs ~= nil) and (theirs - n * step) or nil
    local out  = {}
    for k = 0, 2 do
        if k == n then
            out[k + 1] = cost[el]
        elseif mine ~= nil and bare ~= nil then
            out[k + 1] = (mine < bare + k * step) and hi or lo
        end
    end
    return out
end

-- The per-tick decay rate right now, with its inputs: Water maneuvers up and
-- the Heatsink extra. Nothing passive in this model - see config.heatsink_decay.
-- `counts` is the sidebar's hypothetical vector; omitted - as every other
-- caller does - it reads the live one.
local function decayRate(counts)
    local water = (counts or maneuverCounts()).Water or 0
    local extra = 0
    if water > 0 and (not config.heatsink_required or
                      hasAttachment('Heatsink')) then
        extra = config.heatsink_decay[math.min(water, 3)] or 0
    end
    return config.decay_per_tick + extra, water, extra
end

-- Burden decay, once per tick. Here rather than under burden math because
-- the Heatsink term needs maneuverCounts().
local function decay()
    local now   = os.clock()
    local ticks = math.floor((now - tm.lastTick) / config.tick_seconds)
    if ticks < 1 then return end
    -- Advance the clock even when nothing decays, so a long despawn cannot
    -- bank ticks and then dump them all at once on the next resummon.
    tm.lastTick = tm.lastTick + (ticks * config.tick_seconds)
    -- Burden ONLY decays while an automaton exists: status_effect_container
    -- .cpp gates burdenTick on `if (m_POwner->PPet)`. Decaying through a
    -- despawn would read 0 after a death-and-raise while the server still
    -- holds the burden, frozen the whole time the pet is gone.
    if ids.pet_id == 0 then return end
    -- The rate is read NOW, per tick, not per maneuver: a Water maneuver that
    -- starts or ends between two uses of an element is charged for exactly
    -- the ticks it covered. A per-maneuver rate misses that partial window
    -- (4 Water ticks inside a 19-tick gap, say).
    local rate, water, extra = decayRate()
    for _, el in ipairs(ELEMENTS) do
        burden[el] = math.max(0, burden[el] - (ticks * rate))
        local w = waterSince[el]
        if water > 0 then w.ticks = w.ticks + ticks end
        w.extra = w.extra + (ticks * extra)
    end
end

-- Frame is read from the equipped loadout, not from whichever tab is open;
-- equippedNames carries the 2s cache.
local function currentFrame()
    local eq = equippedNames()
    local f = eq and eq[2] or nil
    if f == nil or f == '' then return nil end
    if f:find('Valoredge') then return 'Valoredge' end
    if f:find('Sharpshot') then return 'Sharpshot' end
    return 'Harlequin'   -- Harlequin and Stormwaker share one skill list
end

-- ...and the frame EVERY consumer should ask for. currentFrame() alone reads
-- the client's PUP memory buffer, which is empty until the attachments window
-- has been opened once in the session - a state the addon documents and lives
-- in for the first minutes after a client start. The server names the frame in
-- 0x044, so prefer that and keep the buffer as the fallback, the way
-- currentHead() treats the head.
-- automatonentity.h AUTOFRAMETYPE 0x20-0x23; Stormwaker collapses onto
-- Harlequin because currentFrame() does too, and nothing that reads this
-- needs to tell the two casting frames apart.
do
    local FRAME_NAME = { [32] = 'Harlequin', [33] = 'Valoredge',
                         [34] = 'Sharpshot', [35] = 'Harlequin' }
    tm.frameNow = function()
        return (tm.auto044 ~= nil and FRAME_NAME[tm.auto044.frame]) or currentFrame()
    end
end


-- battleutils::FormSkillchain - the resonance is the OPENER, the skill being
-- considered is the CLOSER. Returns the resulting element, or nil.
-- The nesting is the server's: resonance OUTER, skill INNER (battleutils.cpp
-- :3380, and Horizon's chains.lua:735 the same). It only shows when the opener
-- has two properties and both crossed pairs chain - Seraph Blade closed by
-- Cannibal Blade is Reverberation this way, Compression the other - and the
-- other nesting would write the wrong element into the log's `closed` field
-- and into the resonance a close leaves behind.
local function formSkillchain(closer, opener)
    if closer == nil or opener == nil then return nil end
    for _, o in ipairs(opener) do
        for _, c in ipairs(closer) do
            local r = SC_PAIRS[c * 32 + o]
            if r ~= nil then return r end
        end
    end
    return nil
end

-- Result messages that mean the action did not connect, so it left no
-- skillchain behind: 188 SKILL_MISS, 189 SKILL_NO_EFFECT, 15 HIT_MISS,
-- 31 SHADOW_ABSORB, 158 JA_MISS (scripts/enum/msg.lua). LSB applies the
-- skillchain only when the resolution is neither Miss nor Parry, and shadows
-- eating a hit resolves as a Miss.
tm.scMiss = { [188] = true, [189] = true, [15] = true, [31] = true, [158] = true }

-- LSB gates the chain branch on the effect being at least 3s old, and the
-- EFFECT_SKILLCHAIN status itself lasts 10s (battleutils.cpp).
-- The resonance regardless of whether it is usable yet - for the log.
-- Gated on the MOB it was opened on. EFFECT_SKILLCHAIN is a status effect on
-- the mob, so a chain open on A says nothing about B: one global slot with no
-- target on it would promise a closer the automaton cannot possibly make, for
-- the whole 10 s window, every time it is put on something else. It would also
-- outlive a resummon and a zone, both of which return petTarget to 0 - so
-- this one test covers all three. Going back to the first mob inside the
-- window makes it live again, which is right: the effect is on the server's
-- copy of that mob and nothing here expired it.
local function rawResonance()
    if tm.resonance == nil or tm.resonance.mob ~= tm.petTarget then return nil end
    return tm.resonance, os.clock() - tm.resonance.at
end

-- The Horizon window (chains/chains.lua): 3s before a closer
-- can land, and the resonance lasts 10s after a first step, 9s after a
-- second, 8s after a third. Upstream holds every step at 10s.
local function liveResonance()
    local res, age = rawResonance()
    if res == nil or age < 3 or age > (res.dur or 10) then return nil end
    return res, age
end

-- `counts` is the sidebar's hypothetical vector; omitted it reads the live one.
-- The chain and TP-hold branches ignore it on purpose: neither looks at
-- maneuvers, so a hypothetical maneuver cannot change what they answer, and the
-- sidebar says that once at its head rather than repeating it eight times.
local function predictWS(frame, counts)
    local list = WS_LISTS[frame]
    if list == nil then return nil, 'unknown frame' end
    local gateSkill = nil
    if tm.auto044 ~= nil then
        gateSkill = (frame == 'Sharpshot') and tm.auto044.ranged or tm.auto044.melee
    end
    local function valid(ws) return gateSkill == nil or gateSkill > ws.param end

    -- Chain branch. Whatever resonance is open on the automaton's target
    -- decides the weaponskill: the highest-param skill that closes it.
    -- Upstream only does this with Inhibitor on; this model assumes Horizon
    -- does it regardless (see the note above SC_NAME). Inhibitor's own contribution is the TP
    -- hold below: with nothing to close it SITS ON ITS TP rather than spend
    -- it, whenever the master is at/above the 900 TP efficiency threshold.
    local res, age = liveResonance()
    if res ~= nil then
        local best, bestParam, bestSC = nil, -1, nil
        for _, ws in ipairs(list) do
            -- LSB only considers a skill that outranks the best CHAINING
            -- one so far, so a higher-param dud never blocks a lower one.
            if valid(ws) and ws.param > bestParam then
                local made = formSkillchain(MOBSKILL_SC[ws.id], res.props)
                if made ~= nil then best, bestParam, bestSC = ws, ws.param, made end
            end
        end
        if best ~= nil then
            return best.name,
                   ('closes %s (%ds left)'):format(SC_NAME[bestSC] or '?',
                                                   math.max(0, (res.dur or 10) - math.floor(age))),
                   'chain'
        end
    end
    local inhib = hasAttachment('Inhibitor') or hasAttachment('Inhibitor II')
    if inhib then
        local myTP = safe(function()
            return AshitaCore:GetMemoryManager():GetParty():GetMemberTP(0)
        end, 0) or 0
        if myTP >= 900 then
            return nil, 'holding TP - waiting for you to open a chain', 'hold'
        end
    end

    local c = counts or maneuverCounts()
    local best, bestCount, bestParam = nil, -1, -1
    for _, ws in ipairs(list) do
        -- no 0x044 data yet -> no gate (predict optimistically until it arrives)
        if valid(ws) then
            local n = c[ws.el] or 0
            -- Ties go to the LATER entry: at Fire 1 / Thunder 1 (both param 0)
            -- the model picks String Clipper, and Chimera Ripper only to
            -- close a chain. LSB's strict > would hand every such tie to
            -- Chimera Ripper; Horizon describes its rewrite as having
            -- "properly prioritized" the pair, and this is the model's
            -- reading of that.
            if n > bestCount or (n == bestCount and ws.param >= bestParam) then
                best, bestCount, bestParam = ws, n, ws.param
            end
        end
    end
    if best == nil then return nil, 'no valid weaponskill' end
    if bestCount > 0 then
        return best.name, ('%s x%d'):format(best.el, bestCount), 'maneuver'
    end
    return best.name, 'no maneuvers, highest tier', 'maneuver'
end

-- Comparator for the logger. Refreshed on the render thread (d3d_present)
-- into predSnapshot so the packet handler never does native reads for it.
-- Writes the three snapshot variables rather than returning them.
local function refreshPrediction()
    -- tm.frameNow, not currentFrame: this publishes the snapshot the packet
    -- thread judges a weaponskill against, and with a bare client buffer
    -- currentFrame would hand every pet_ws record `expected: none` and let a
    -- genuine mispredict through as a routine use.
    local f = tm.frameNow()
    if f == nil then
        tm.predSnapshot, tm.predWhy, tm.predMode = nil, nil, nil
        return
    end
    tm.predSnapshot, tm.predWhy, tm.predMode = predictWS(f)
end

tm.refreshStatChecks = refreshStatChecks

return { computeCost = computeCost, myStat = myStat,
         applyStatCheck = applyStatCheck, refreshStatChecks = refreshStatChecks, predict = predict,
         overloadDuration = overloadDuration,
         meanAbsError = meanAbsError, reconcile = reconcile,
         activeManeuvers = activeManeuvers, maneuverCounts = maneuverCounts,
         costLadder = costLadder, decayRate = decayRate,
         decay = decay, currentFrame = currentFrame, formSkillchain = formSkillchain,
         rawResonance = rawResonance, liveResonance = liveResonance, predictWS = predictWS,
         refreshPrediction = refreshPrediction }
