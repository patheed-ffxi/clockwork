-- ------------------------------------------------------- burden catch-up --
-- A zone line is not a despawn: LSB keeps a non-charmed pet (PPet stays
-- non-null, status DISAPPEAR) and burdenTick is gated on PPet, so the server
-- decays while the client cannot see the automaton and decay() is frozen.
-- Uncorrected, a DEA seed reads far above the real value after a trip through town.
do
    local m = api.model()
    local SELF = 0x01000001
    petOut(PET + 20, MOB + 20)
    send028({ actor = SELF, category = 6, param = 136,
              targets = { { id = SELF, actions = { { message = 0 } } } } })
    local cfg = api.config
    check('catchup seeded', m.burden.Fire, cfg.activate_burden)
    check('catchup seeded unverified', m.verified.Fire, false)
    -- gone from the client, then back with NO Activate: a zone
    petIn()
    advance(60)                       -- 20 ticks at 3s, all frozen
    check('catchup frozen while gone', m.burden.Fire, cfg.activate_burden)
    petOut(PET + 20, MOB + 20)
    check('catchup applied', m.burden.Fire, cfg.activate_burden - 20)   -- 20 ticks x 1
    check('catchup unverified', m.verified.Fire, false)
    check('catchup logged', CLOCKWORK_TEST.last.kind, 'burden_catchup')
    -- and not a second time: decay() runs right after resolveIds on the same
    -- frame, and a loading screen means its lastTick is just as far behind
    frame('catchup once')
    check('catchup not doubled', m.burden.Fire, cfg.activate_burden - 20)
    -- a resummon DOES seed, and must not also catch up
    petIn()
    advance(30)
    send028({ actor = SELF, category = 6, param = 136,
              targets = { { id = SELF, actions = { { message = 0 } } } } })
    petOut(PET + 21, MOB + 20)
    check('catchup skipped after activate', m.burden.Fire, cfg.activate_burden)
end

-- ------------------------------------------------------ shock absorber cell --
-- The cell is labelled by what the ability DOES on the automaton, a Stoneskin,
-- not by the ability's name. The name itself stays 'Shock Absorber' - the log
-- records and the recast model key off it - so assert both halves.
do
    world.buffer = { 2, 33, 209, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }
    advance(2.5)
    petOut(PET + 22, MOB + 22)
    send044({ head = 2, frame = 33 })
    frame('absorber cell')
    check('absorber cell label', sawExact('Stoneskin'), true)
    check('absorber cell not the ability name', sawExact('Absorber'), false)
    check('absorber row keeps the real name', timerRow(1946).name, 'Shock Absorber')
    check('absorber row model', timerRow(1946).model, 180)
end

-- ------------------------------------------------ deus ex back-solve --
-- A Deus Ex seeds like an Activate and must be timed like one. Before 1.6.6
-- its back-solve lived inside the reseed branch alone, so a CORRECT seed
-- logged no implied_seed at all and emitted no reading. Both summons now get
-- the same seed-agnostic reading on
-- the first cast of each element, whether the seed was right or wrong.
do
    local m, cfg = api.model(), api.config
    local SELF = 0x01000001
    petOut(PET + 30, MOB + 30)
    world.icons, world.timers = nil, nil
    -- Deus Ex, then a cast one tick later that AGREES with the seed
    send028({ actor = SELF, category = 6, param = 310,
              targets = { { id = SELF, actions = { { message = 0 } } } } })
    check('dea seeds', m.burden.Fire, cfg.dea_burden)
    advance(3) handlers['d3d_present']()
    -- burden is now seed-1; a cast of cost 20 at threshold 30 shows
    -- (seed-1) + 20 - 30 + 5, and the back-solve returns the seed
    local before = cfg.dea_burden - 1
    api.reconcile('Fire', before + 20 - 30 + 5, false)
    local last = CLOCKWORK_TEST.last
    check('dea first cast is a plain maneuver', last.kind, 'maneuver')
    check('dea first cast timed', last.rec.since_activate, 3)
    check('dea first cast pre-cast', last.rec.pre_cast, before)
    check('dea back-solves the seed', last.rec.implied_seed, cfg.dea_burden)
    -- and a WRONG seed still reads, as a reseed rather than an anomaly
    advance(6)
    send028({ actor = SELF, category = 6, param = 310,
              targets = { { id = SELF, actions = { { message = 0 } } } } })
    api.reconcile('Fire', 8, false)
    last = CLOCKWORK_TEST.last
    check('dea wrong seed is a reseed', last.kind, 'burden_reseed')
    check('dea wrong seed still back-solves', last.rec.implied_seed, 33 - 20)
end

-- ------------------------------------------- deus ex stamps the recast edge --
-- Activate calls timersClear(true); the Deus Ex branch did not, and no
-- lifecycle edge covers for it (pet_respawn needs lastPetId ~= 0, and after a
-- death that is already 0). So the cells stayed 'unknown' after a summon that
-- clears every recast, and since_edge on the first use was measured from the
-- previous automaton's death instead of from this summon.
do
    local SELF = 0x01000001
    local function dea()
        send028({ actor = SELF, category = 6, param = 310,
                  targets = { { id = SELF, actions = { { message = 0 } } } } })
    end
    world.buffer = { 2, 33, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }   -- Valoredge, Strobe
    advance(6)   -- clear of the block above's dedupe window: the same summon
                 -- packet twice inside 5 s is one packet to isDuplicate
    petIn()                                   -- no automaton, lastPetId back to 0
    send044({ head = 2, frame = 33, attachments = { 1 } })
    api.timersClear(false)                    -- the state after a reload: nothing known
    check('dea edge starts unknown', timerRow(1945).state, 'unknown')
    dea()
    petOut(PET + 40, MOB + 40)
    check('dea clears the recast cells', timerRow(1945).state, 'ready')
    check('dea clears the bash cell too', timerRow(1944).state, 'ready')
    send028(act(11, 1945, MOB + 40))
    check('first use after a dea logs the edge', CLOCKWORK_TEST.last.kind, 'recast_edge')

    -- ...and the edge is THIS summon, not the last automaton's death
    petIn()                                   -- the automaton dies: despawn edge
    advance(90)
    dea()
    petOut(PET + 41, MOB + 41)
    advance(4)
    send028(act(11, 1945, MOB + 41))
    check('dea edge kind', CLOCKWORK_TEST.last.kind, 'recast_edge')
    check('dea edge measured from the summon', CLOCKWORK_TEST.last.rec.since_edge, 4)
    world.buffer = { 2, 33, 5, 4, 1, 2, 3, 0, 0, 0, 0, 0, 0, 0 }
    advance(2.5)
end

-- --------------------------------------------------- the spell line, empty --
-- The no-spell case was never rendered by a test, which is how "Spell none
-- ready nothing to cast" shipped: 'none ready' filled the NAME slot and the why
-- was drawn after it. A Valoredge HEAD on a Harlequin frame has only a heal
-- rung, so with nobody hurt the ladder finds nothing and no window is shut.
do
    world.buffer = { 2, 32, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }
    advance(2.5)
    petOut(PET + 23, MOB + 23)
    send044({ head = 2, frame = 32, magic = 120, hp = 600, maxhp = 600, mp = 300, maxmp = 300 })
    world.hp, world.maxhp, world.petHpp, world.petMpp = 1000, 1000, 100, 100
    world.icons, world.timers = nil, nil
    local name, why = api.predictSpell()
    check('empty line no spell', name, nil)
    check('empty line why', why, 'nothing to cast')
    frame('spell line empty')
    check('empty line drawn', sawExact('nothing to cast'), true)
    check('empty line no placeholder', sawExact('none ready'), false)
    -- a shut window reads on its own too, rather than as a bare fragment
    send028(act(8, 1))
    local _, waitWhy = api.predictSpell()
    check('empty line wait why', waitWhy, 'none ready - magic window 20s')
end

-- ------------------------------------ the frame with an empty client buffer --
-- currentFrame() reads only the client's PUP memory buffer, which stays empty
-- until the attachments window has been opened once in the session. timerRows
-- was given the 0x044 fallback for exactly that; predictSpell and the
-- sidebar's heal column were not, so a fresh client session answered 'this
-- frame never casts' and made a spell_mispredicted out of every cast.
do
    world.hp, world.maxhp, world.petHpp, world.petMpp = 1000, 1000, 100, 100
    world.icons, world.timers = nil, nil
    petOut(PET + 45, MOB + 45)
    send044({ head = 5, frame = 35, magic = 120, hp = 600, maxhp = 600, mp = 300, maxmp = 300 })
    world.buffer = { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }   -- nothing readable yet
    advance(2.5)
    check('the head still reads from the packet', api.currentHead(), 5)
    local name, why = api.predictSpell()
    check('an empty buffer does not shut the ladder', why == 'this frame never casts', false)
    check('and the ladder answers', name ~= nil or why ~= nil, true)
    -- the sidebar's heal column hangs off the same frame
    local healSig = false
    for _, r in ipairs(api.sidebarRows()) do
        if r.el == 'Light' then
            for _, g in ipairs(r.sig) do
                if g[2]:sub(1, 8) == 'heal at ' then healSig = true end
            end
        end
    end
    check('the heal column reads too', healSig, true)
    -- and the buffer still wins when there is no packet at all
    api.clear044()
    world.buffer = { 5, 33, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }   -- Valoredge frame
    advance(2.5)
    local _, why2 = api.predictSpell()
    check('a melee frame still never casts', why2, 'this frame never casts')
    world.buffer = { 5, 35, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }
    advance(2.5)
    send044({ head = 5, frame = 35, magic = 120, hp = 600, maxhp = 600, mp = 300, maxmp = 300 })
end

-- ------------------------------------------- caster automaton petTarget --
-- A pure caster never melees and never uses a mob skill, so before 1.6.8
-- nothing set petTarget for it and NO target effect was ever recorded - the
-- ladder then re-offered enfeebles the mob already had. An enemy-aimed
-- spell now moves it; an ally-aimed one does not.
do
    local SELF = 0x01000001
    petOut(PET + 40, MOB + 40)
    world.buffer = { 5, 35, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }
    advance(2.5)
    send044({ head = 5, frame = 35, magic = 120, hp = 600, maxhp = 600, mp = 300, maxmp = 300 })
    -- nothing has aimed at the mob yet
    api.setPetTarget(0)
    -- an ENFEEBLE start at the mob: rung 'enfeeble', so it establishes the target
    send028(act(8, 56, MOB + 40))
    check('caster petTarget from enfeeble', api.petTarget(), MOB + 40)
    -- ...and the finish landing Slow is recorded against it
    send028(act(4, 56, MOB + 40, 236, 13))
    check('caster mob effect recorded', api.targetEffects()[13] ~= nil, true)
    -- a HEAL at the master must NOT move it
    send028(act(8, 1, SELF))
    check('caster petTarget unmoved by a cure', api.petTarget(), MOB + 40)
    -- nor an ENHANCE on the automaton itself
    send028(act(8, 43, PET + 40))
    check('caster petTarget unmoved by a buff', api.petTarget(), MOB + 40)
    check('caster mob effect survives', api.targetEffects()[13] ~= nil, true)
end
