-- ------------------------------------------------------------ burden decay --
-- The model's Heatsink: nothing passive, +1 per tick per Water maneuver up, on
-- every element - and a Water window inside a gap must not teach the cost
-- learner. Entering: no maneuver icons, world.buffer without Heatsink.
do
    local m = api.model()
    local cfg = api.config
    world.petIndex, world.petId = 5, 0x01000200
    world.icons, world.timers = nil, nil
    -- a STR block so Fire's cost computes as 20 (the stub's 0 is below 70)
    send044({ head = 2, frame = 33, attachments = { 5, 1, 98 }, heads = 2 ^ 2, frames = 2 ^ 1,
              owned = { 1, 5, 98 }, stats = { STR = 70 } })
    handlers['d3d_present']()          -- resolveIds picks the pet up; stat checks refresh
    check('decay cost computed', m.cost.Fire, 20)
    -- the first reading seeds Fire: 18% at threshold 30 -> burden 43
    api.reconcile('Fire', 18, false)
    check('decay reconciled burden', m.burden.Fire, 43)
    check('decay reseed logged', CLOCKWORK_TEST.last.kind, 'burden_reseed')
    local function ticks(n) for _ = 1, n do advance(3) handlers['d3d_present']() end end
    -- ten ticks, no Water: one per tick
    ticks(10)
    check('decay base rate', m.burden.Fire, 33)
    check('decay no water ticks', m.waterSince.Fire.ticks, 0)
    -- one Water up, no Heatsink on the automaton: still one per tick
    world.icons, world.timers = { 305 }, { 0 }
    ticks(5)
    check('decay water without heatsink', m.burden.Fire, 28)
    check('decay water ticks counted', m.waterSince.Fire.ticks, 5)
    check('decay no extra without heatsink', m.waterSince.Fire.extra, 0)
    -- Heatsink on: two per tick with one Water up, three with two
    world.buffer = { 2, 33, 5, 1, 98, 206, 0, 0, 0, 0, 0, 0, 0, 0 }
    ticks(5)
    check('decay heatsink one water', m.burden.Fire, 18)
    check('decay extra counted', m.waterSince.Fire.extra, 5)
    world.icons, world.timers = { 305, 305 }, { 0, 0 }
    ticks(2)
    check('decay heatsink two water', m.burden.Fire, 12)
    check('decay rate reported', (api.decayRate()), 3)
    -- a 5-point shortfall against the live cost inside a Water window is
    -- logged, carries the window, and is NOT a stat-check dispute
    api.reconcile('Fire', 2, false)                   -- model said 7%
    check('water window logged as mismatch', CLOCKWORK_TEST.last.kind, 'burden_mismatch')
    check('water window in the record', CLOCKWORK_TEST.last.rec.water_ticks, 12)
    check('extra decay in the record', CLOCKWORK_TEST.last.rec.extra_decay, 9)
    check('water window teaches nothing', m.costDispute.Fire, nil)
    check('water window keeps the live cost', m.cost.Fire, 20)
    check('water counters reset', m.waterSince.Fire.ticks + m.waterSince.Fire.extra, 0)
    -- the control: the same shortfall with no Water window opens a dispute
    world.icons, world.timers = nil, nil
    ticks(5)                                          -- 27 -> 22
    api.reconcile('Fire', 12, false)                  -- model said 17%
    check('control opens a dispute', m.costDispute.Fire and m.costDispute.Fire.value, 15)
    check('control record has no window', CLOCKWORK_TEST.last.rec.water_ticks, 0)
    -- heatsink_required off: the Water maneuver alone speeds decay
    world.buffer = { 2, 33, 5, 4, 1, 2, 3, 0, 0, 0, 0, 0, 0, 0 }   -- no Heatsink
    cfg.heatsink_required = false
    world.icons, world.timers = { 305 }, { 0 }
    local before = m.burden.Fire
    ticks(1)
    check('water alone when not required', before - m.burden.Fire, 2)
    cfg.heatsink_required = true
    world.icons, world.timers = nil, nil
    world.petIndex, world.petId = 0, 0
end

-- --------------------------------------------------------------- activate --
-- A plain Activate through the real packet path seeds every element with
-- activate_burden, unverified, and the first cast of each element after it
-- is timed. Entering: the automaton out, no maneuver icons.
do
    local m = api.model()
    local cfg = api.config
    local SELF = 0x01000001               -- the harness's GetPlayerEntity ServerId
    local function activate()
        send028({ actor = SELF, category = 6, param = 136,
                  targets = { { id = SELF, actions = { { message = 0 } } } } })
    end
    world.petIndex, world.petId = 0, 0
    world.icons, world.timers = nil, nil
    handlers['d3d_present']()             -- snapshot: self id, is_pup
    api.reconcile('Fire', 35, false)      -- 60 at threshold 30, observed
    check('activate entering burden', m.burden.Fire, 60)
    check('activate entering verified', m.verified.Fire, true)
    activate()
    check('activate logged', CLOCKWORK_TEST.last.kind, 'activate')
    check('activate logged seed', CLOCKWORK_TEST.last.rec.seeded, cfg.activate_burden)
    check('activate seeds fire', m.burden.Fire, cfg.activate_burden)
    check('activate seeds thunder', m.burden.Thunder, cfg.activate_burden)
    check('activate unverified', m.verified.Fire, false)
    check('activate marks the seed', m.seededBy.Fire, 'activate')
    -- the automaton is up; two ticks later the seed has decayed to 27 and the
    -- server agrees: 47 after the cast reads 22% at threshold 30. Expressed off
    -- cfg.activate_burden so a recalibration moves the fixture with it - the
    -- claim under test is "the seed decays and the first cast back-solves to
    -- it", not the value of the constant.
    world.petIndex, world.petId = 5, 0x01000200
    advance(3) handlers['d3d_present']()
    advance(3) handlers['d3d_present']()
    check('activate seed decays', m.burden.Fire, cfg.activate_burden - 2)
    api.reconcile('Fire', cfg.activate_burden - 2 + 20 - 30 + 5, false)
    local last = CLOCKWORK_TEST.last
    check('activate first cast is a plain maneuver', last.kind, 'maneuver')
    check('activate first cast timed', last.rec.since_activate, 6)
    check('activate first cast pre-cast', last.rec.pre_cast, cfg.activate_burden - 2)
    check('activate first cast implied seed', last.rec.implied_seed, cfg.activate_burden)
    check('activate seed consumed', m.seededBy.Fire, nil)
    api.reconcile('Fire', 18, false)
    check('activate second cast not timed', CLOCKWORK_TEST.last.rec.since_activate, nil)
    -- a wrong seed is a reseed, not an anomaly, and still carries the timing:
    -- 8% right after the Activate means 33 after the cast, 13 before it
    advance(6)
    activate()
    check('activate again seeds', m.burden.Fire, cfg.activate_burden)
    api.reconcile('Fire', 8, false)
    last = CLOCKWORK_TEST.last
    check('activate wrong seed is a reseed', last.kind, 'burden_reseed')
    check('activate wrong seed implied', last.rec.implied_seed, 13)
    check('activate wrong seed timed', last.rec.since_activate, 0)
    check('activate wrong seed resyncs', m.burden.Fire, 33)
    -- activate_burden = nil keeps the carried values and still times the cast
    cfg.activate_burden = nil
    advance(6)
    activate()
    check('activate carry keeps burden', m.burden.Fire, 33)
    check('activate carry logged', CLOCKWORK_TEST.last.rec.seeded, 'carried')
    check('activate carry unverified', m.verified.Fire, false)
    check('activate carry marks the seed', m.seededBy.Fire, 'activate')
    cfg.activate_burden = 25
    -- With Heatsink on and a Water maneuver up from the summon, the boosted
    -- ticks count too: 2/tick over two ticks is 4 off the seed, and the
    -- back-solve has to put all 4 back. It used to add the base rate alone,
    -- so this read 2 under the seed with nothing on the record to say why.
    local buf0 = world.buffer
    world.buffer = { 2, 33, 206, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }   -- Heatsink
    world.icons, world.timers = { 305 }, { 0 }                       -- one Water up
    advance(6)
    activate()
    world.petIndex, world.petId = 5, 0x01000200
    advance(3) handlers['d3d_present']()
    advance(3) handlers['d3d_present']()
    check('activate seed decays at the Heatsink rate', m.burden.Fire, cfg.activate_burden - 4)
    api.reconcile('Fire', cfg.activate_burden - 4 + 20 - 30 + 5, false)
    last = CLOCKWORK_TEST.last
    check('activate first cast under Water counts the extra decay', last.rec.implied_seed, cfg.activate_burden)
    check('...and records the Water ticks', last.rec.water_ticks, 2)
    world.icons, world.timers = nil, nil
    world.buffer = buf0
    world.petIndex, world.petId = 0, 0
end

-- --------------------------------------------------- 0x028 round-trip --
-- The packer against the addon's own parser: what goes in comes out, and the
-- recast field rides along. The packer itself is the `0x028 builder` section
-- of test/fixtures/helpers.lua.
do
    world.petId = PET
    local got = api.unpackAction(build028(act(11, 1945, MOB, 100, 7, 0)))
    check('028 actor', got.actor_id, PET)
    check('028 category', got.category, 11)
    check('028 param', got.param, 1945)
    check('028 recast', got.recast, 0)
    check('028 target', got.targets[1].server_id, MOB)
    check('028 message', got.targets[1].actions[1].message, 100)
    check('028 action param', got.targets[1].actions[1].param, 7)
    local two = build028({ actor = PET, category = 4, param = 23, recast = 12,
                           targets = { { id = MOB, actions = { { message = 236, param = 134 } } },
                                       { id = 7, actions = { { message = 85 } } } } })
    got = api.unpackAction(two)
    check('028 two targets', #got.targets, 2)
    check('028 second target', got.targets[2].server_id, 7)
    check('028 finish recast', got.recast, 12)
    -- A cast start carries the FourCC in the header and the spell in result 1.
    -- Without this the whole cast-start path can be written against a packet
    -- shape the server never sends, and every fixture will still pass.
    local start = api.unpackAction(build028(act(8, 59)))
    check('028 cast start header is a fourcc', start.param, 24931)
    check('028 cast start spell id', start.targets[1].actions[1].param, 59)
    -- a flagged first result must not shift the second: this is the stride
    -- the 0x028 handler's mob-effect loop walks in real play and never walks here
    local var = api.unpackAction(build028({ actor = PET, category = 4, param = 23,
        targets = { { id = MOB, actions = { { message = 236, param = 134, addeff = true, spikes = true },
                                            { message = 230, param = 40 } } } } }))
    check('028 flagged stride param', var.targets[1].actions[2].param, 40)
    check('028 flagged stride message', var.targets[1].actions[2].message, 230)
end

-- --------------------------------------------------------- recast timers --
-- Every use starts the clock; the model is LSB's; a use before the model's
-- ready time is an anomaly; a resummon clears everything to ready. Log
-- lines are read back from the file the addon writes.
do
    world.buffer = { 2, 33, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }   -- Valoredge, Strobe in slot 1
    advance(2.5)
    petOut()
    api.timersClear(false)
    check('timer unseen', timerRow(1945).state, 'unknown')
    check('timer bash on valoredge', timerRow(1944) ~= nil, true)
    check('timer flash not equipped', timerRow(1947), nil)
    send028(act(11, 1945))
    check('timer provoke counting', timerRow(1945).state, 'counting')
    check('timer provoke remaining', math.floor(timerRow(1945).remaining), 30)
    check('timer provoke logged', (lastLog('pet_ability') or ''):find('"name":"Provoke"', 1, true) ~= nil, true)
    advance(10)
    check('timer provoke ten later', math.floor(timerRow(1945).remaining), 20)
    advance(10)
    send028(act(11, 1945))   -- 20 s after the first: ten seconds early
    check('timer early anomaly', (lastLog('recast_early') or ''):find('"early":10', 1, true) ~= nil, true)
    advance(31)
    check('timer provoke ready', timerRow(1945).state, 'ready')
    -- a resummon clears to ready; the first use after it logs the edge.
    -- Bash first: Provoke's 30 s recast has already expired above, so its cell
    -- reads 'ready' with or without the clear and cannot fail. Bash is one
    -- second into 180 when the resummon lands, so it can.
    send028(act(11, 1944))
    petOut(PET + 1)
    check('timer edge ready', timerRow(1945).state, 'ready')
    check('timer edge bash ready', timerRow(1944).state, 'ready')
    send028(act(11, 1945))
    check('timer edge logged', (lastLog('recast_edge') or ''):find('"since_edge"', 1, true) ~= nil, true)
    -- Shield Bash: 180 s, Valoredge frame only
    advance(5)
    send028(act(11, 1944))
    check('timer bash model', timerRow(1944).model, 180)
    check('timer bash counting', math.floor(timerRow(1944).remaining), 180)
    -- the shot: Sharpshot frame and head is 20 s; Drum Magazine at one Wind takes 6
    world.buffer = { 3, 34, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }
    advance(2.5)
    send044({ head = 3, frame = 34 })
    check('timer shot model', timerRow(1949).model, 20)
    check('timer bash not on sharpshot', timerRow(1944), nil)
    world.buffer = { 3, 34, 207, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }
    world.icons, world.timers = { 302 }, { 0 }
    advance(2.5)
    -- one Wind reads the table's SECOND value (attachMods indexes [n+1]): 20 - 6
    check('timer shot with drum magazine', timerRow(1949).model, 14)
    -- the two floors, which nothing reached: three Wind takes 15, so a
    -- Sharpshot head's 20 lands exactly on its 5 s floor and a Harlequin
    -- head's 25 on the 10 s one
    world.icons, world.timers = { 302, 302, 302 }, { 0, 0, 0 }
    check('timer shot floor sharpshot', timerRow(1949).model, 5)
    send044({ head = 1, frame = 34 })
    check('timer shot floor other', timerRow(1949).model, 10)
    send044({ head = 3, frame = 34 })
    world.icons, world.timers = { 302 }, { 0 }
    send028(act(11, 1949))
    -- 6s, not 4: two shots at the same target differ only past byte 24, and
    -- isDuplicate drops a repeat of the first 24 bytes inside 5s
    advance(6)
    send028(act(11, 1949, MOB, 1, 25))
    check('timer shot early', (lastLog('recast_early') or ''):find('"name":"Ranged Attack"', 1, true) ~= nil, true)
    -- no 0x044 and no head in the buffer - the state for the first minutes
    -- after a reload. The shot's model
    -- falls back to 36, and a real 22 s cadence must NOT be flagged against it.
    api.clear044()
    world.buffer = { 0, 34, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }   -- frame known, head not
    world.icons, world.timers = nil, nil
    advance(2.5)
    frame('shot unknown head')
    send028(act(11, 1949, MOB + 7))
    advance(22)
    send028(act(11, 1949, MOB + 8))
    check('shot unknown head not flagged',
          (lastLog('pet_ability') or ''):find('"model_known":false', 1, true) ~= nil, true)
    send044({ head = 3, frame = 34 })
    world.icons, world.timers = nil, nil
    world.buffer = { 2, 33, 5, 4, 1, 2, 3, 0, 0, 0, 0, 0, 0, 0 }
    advance(2.5)
end
