-- cw/state.lua - `tm`, the one table every module shares; returns it. Written on
-- the packet thread and read on the render thread. Fields are documented where
-- they are set; the modules that own them also publish their functions onto it
-- (tm.timerRows, tm.petLive, tm.noteMob, ...). Defines tm.clear.
local config = require('cw.config')

-- Aliasing. Only these tables keep one identity for the life of the addon -
-- created here, never reassigned, and reset in place (tm.clear, or key by key) -
-- so only these may be aliased at module scope:
--   burden, cost, samples, ids, snap, costSource, costDispute, burdenVerified,
--   castThresh, castStat, castBonus, seededBy, lastReconcile, waterSince.
-- Everything else is read as tm.x at every use: every value; every table a
-- reset REPLACES with a fresh one (petKnown, mobs, touched, petUntil, petDiaBio,
-- regenAt, usedAt, gaps, windowAt, spellRecast, rows); and every record replaced
-- whole on each update (auto044, resonance, fhPending, applyState, spell, demo,
-- partyBuffs, partyNow).
-- An alias of one of those goes stale at its first replacement.
local tm = { usedAt = {}, gaps = {}, model = {}, modelKnown = {}, rows = {}, edgeAt = nil,
             windowAt = {}, spellRecast = {},
             -- Effects on every mob the battle traffic has named, keyed by the
             -- mob's ServerId and then by effect id:
             --   { at, ends, spell, who, src }
             -- at = when it last landed (whoever landed it); ends = when we
             -- stop believing it, nil = the flat backstop; spell = the spell
             -- that set it, nil for a TP move; who = 'pet' | 'you' | 'other';
             -- src = 'landed' | 'cast' (Dia/Bio, which land in silence) |
             -- 'refused' (someone's cast came back "has no effect").
             -- The shape XIUI, HXUI and kazenoeye all use (xitools'
             -- debuffhandler: enemies[serverId][effect]), because the server's
             -- own test - CanUseEnfeeble - is whether the mob carries the
             -- effect FROM ANYONE. `who` is the one addition: the duration
             -- learner must tell the automaton's landings from a party
             -- member's. The ladder reads tm.mobs[petTarget]; an entry lives
             -- until the mob dies, the zone changes or it is pruned, so a
             -- Deploy back to a mob fought before finds it still known.
             mobs = {},
             -- The mob the automaton has been Deployed onto and has not yet
             -- touched. Nothing of ours is on that mob's enmity list while
             -- this is set, and TryEnhance picks its Regen target from that
             -- list alone - so there is no Regen target at all.
             deployTo = nil,
             -- [side] = os.clock() when the server last chose that side for a
             -- Regen. The only reading of enmity the client can get.
             regenAt = {},
             -- [spell id] = the last few realised durations of the automaton's
             -- OWN enfeebles, each measured landing -> wear-off on one mob.
             -- What the clock is actually set from.
             seenDur = {},
             -- [effect] = true once we have had ANY reading of that effect on
             -- this automaton - it landed, it wore off, or a cast proved it.
             -- Empty at load, because nothing announces the automaton's buffs
             -- and an empty petEffects then means "no idea", not "none".
             petKnown = {},
             -- [effect] = os.clock() when a landing that CAME WITH a duration
             -- (a Dia/Bio cast, a silent mob skill) stops being believed;
             -- nil = the flat MAX_EFFECT_AGE backstop, as for a bare message.
             petUntil = {},
             -- which spell put Dia (134) / Bio (135) on the automaton, so the
             -- next cast of either family can compare tiers
             petDiaBio = {},
             -- the entity slot petTarget was last found in, and the id it was
             -- found for. Listed here as DOCUMENTATION: a nil value in a table
             -- constructor creates no key, so these are still grown on first
             -- assignment - as edgeAt and spell are. Deliberately NOT reset by
             -- timersClear either: the id is the
             -- cache key, so a new automaton or a new mob invalidates it on its
             -- own, and gather re-checks the slot every frame anyway. mobScanAt
             -- throttles the rescan while the target's slot is empty.
             mobIndexFor = nil, mobIndex = nil, mobScanAt = nil,
             spell = nil, windows = '', names = {}, casts = 0, missed = 0,
             -- auto044Seq as it stood at the last Activate; flushLoadout waits
             -- for the server to move past it and then writes the record.
             logLoadoutAt = nil }

-- Empty a shared table without replacing it: every alias of it stays valid.
tm.clear = function(t) for k in pairs(t) do t[k] = nil end return t end
tm.burden, tm.cost, tm.samples = {}, {}, {}

-- Resonance currently on the automaton's target, replaced whole by each
-- weaponskill that lands. Written on the packet thread, read on the render
-- thread; both only ever touch these fields:
--   { mob = <server id>, props = {..}, at = os.clock(), sc = <element|nil>,
--     step = <1 opened, n = the nth step>, dur = <seconds after `at` it can be closed> }
tm.resonance = nil
tm.petTarget = 0        -- server id of whatever our automaton last acted on
-- The grace clocks frame.lua's backstop runs: when petTarget (and separately
-- deployTo) stopped being readable in the entity table, WHICH id that was for,
-- and when it was last checked. `at` and `id` are nil while the entity
-- resolves; the backstop clears the field once the clock has stood for
-- TARGET_GRACE on the same id. Render thread only.
tm.targetGone = { at = nil, id = nil, checkAt = nil }
tm.deployGone = { at = nil, id = nil, checkAt = nil }

tm.ids       = { self_id = 0, pet_id = 0, pet_index = 0 }
tm.lastPetId = 0      -- last known automaton ServerId; survives client-side culling
tm.lastTick  = os.clock()
tm.anomalies = 0
tm.logFile   = nil

-- Flame Holder: LSB removes EVERY Fire maneuver on weaponskill exit
-- (flame_holder.lua: `for i = 1, toremove do delStatusEffectSilent(FIRE_MANEUVER)`),
-- but Horizon players report only one being eaten, and that this is
-- intended. The addon checks: snapshot Fire before a pet WS, re-read after
-- it resolves, logged with the attachment equipped true/false so the
-- not-equipped case is a built-in control.
tm.fhPending = nil
tm.predSnapshot = nil -- WS prediction, refreshed on the render thread each frame
tm.predManeuvers = nil -- maneuver census matching predSnapshot, for the log
tm.predMode      = nil -- 'chain' | 'hold' | 'maneuver' - which branch decided it
tm.predWhy       = nil -- the reason behind predSnapshot, for the record
-- Everything the packet thread is allowed to read. Refreshed once per frame on
-- d3d_present. fancychat (this parser's source) reads from snapshots for
-- exactly this reason: a native read racing zone-in entity churn is an SEH
-- fault, which pcall cannot catch, and it surfaces as an unattributed crash.
tm.snap = { self_id = 0, pet_id = 0, is_pup = false, thresh = config.threshold,
            bonus = 0, party = {} }   -- the party's ServerIds as a set: a member's blow counts as ours
-- [mob server id] = os.clock() of the last blow the master, the automaton or
-- the party landed on it: evidence that the mob's enmity list is not empty,
-- which a Deploy alone is not. Dropped with the mob's death and on zone.
tm.touched = {}
-- [member ServerId] = { [effect id] = true }: the party's buffs, off the last
-- 0x076 (the master's own never ride in it). Replaced whole by each one.
tm.partyBuffs = {}
-- The party as the last prediction read it - { sid, name, hpp, hp, fx } per
-- member in the zone - and the master's HP%. gather() publishes both for the
-- cast record, which the packet thread writes and which cannot read memory.
tm.partyNow, tm.youHpp = {}, nil
-- The character this state describes (its ServerId), and the 0x044 sequence
-- the last frame saw. A frame that finds a different character forgets the
-- old one; a 0x044 that arrived while no frame ran is the new character's.
tm.owner = nil
tm.auto044SeqSeen = 0

tm.auto044 = nil      -- last PUP extended-job packet (0x044): skills, stats, owned attachments
tm.auto044Seq = 0     -- bumped per 0x044, so an apply step can wait for the reply to ITS packet
tm.zoneSeq = 0        -- bumped per 0x00A, so an apply can notice it zoned
tm.statsDirty = false -- set by the packet thread, consumed on d3d_present
tm.eqCache, tm.eqCacheAt   = nil, 0
tm.eqCacheSeq = -1      -- the 0x044 sequence the cache was built against
tm.oilCache, tm.oilCacheAt = nil, 0

-- How cost[el] was arrived at, as burden.lua writes it: 'set' (pinned by
-- config.stat_check); 'computed' (your stat now against the automaton's 0x044);
-- 'cast' (the same comparison, with your stat as worn when the element last
-- resolved); 'learned' (inferred from a verified burden reading while no 0x044
-- has arrived); 'observed' (a run of readings overruled the comparison - frozen
-- until /cw reset or a frame change); 'assumed' (no comparison possible, so the
-- losing cost). nil reads as 'assumed'.
tm.costSource = {}
-- Consecutive observations that contradict a COMPUTED cost, per element.
-- One is noise; a run of them means the stat comparison is wrong.
tm.costDispute = {}
-- burden[el] is only trustworthy after a real reconcile; a summon seed, a zone
-- catch-up or a manual sync makes it a guess, and nothing learns from a guess.
tm.burdenVerified = {}
-- What the server actually evaluated the last time each element resolved:
-- the threshold under the gear worn at that instant, your stat with the
-- maneuver set on, and the Maneuver Bonus the worn hands added to the stat the
-- maneuver grants. All three persist between maneuvers; the panel predicts
-- with them.
tm.castThresh, tm.castStat, tm.castBonus = {}, {}, {}
tm.seededBy = {}       -- 'activate' | 'dea' until the element next reconciles
tm.lastReconcile = {}  -- os.clock() per element, for the ticks field in the log
-- Since each element last resolved: ticks that had a Water maneuver up, and
-- the extra decay Heatsink took over them (decay() counts, reconcile() logs
-- and resets). While the first is non-zero a delta measures decay as much
-- as cost, so the cost learner stands down for that sample.
tm.waterSince = {}     -- per element: { ticks = n, extra = n }
tm.activateAt = nil    -- os.clock() of the last Activate seen in the 0x028 stream

-- the running or finished apply, for the Loadout tab and the hook
tm.applyState = nil

return tm
