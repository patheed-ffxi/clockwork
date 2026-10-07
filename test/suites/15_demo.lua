-- ------------------------------------------------------------ demo mode --
-- /cw demo makes up an automaton so the HUD can be looked at without being on
-- PUP with a pet out. It is not a second model: the made-up inputs go in at the
-- same seam this harness stubs, and everything above - burden, the ladder, the
-- recast rows, the sidebar - is the real code. These checks are that the panel
-- draws from it, and that turning it off gives the client back.
do
    -- A real automaton is out at this point in the suite, and demo REFUSES
    -- while one is: enable() overwrites its burden, recasts, target and
    -- effects with the scenario's and disable() zeroes them, and nothing
    -- would give back what the server still holds. Checked with an id other
    -- than demo's own constant (which the suite's PET happens to share) and
    -- outside the zone window, so the lifecycle edges are live.
    petOut(PET + 70, MOB + 70)
    api.timersClear(false)
    local burden0 = api.model().burden.Fire
    printed = {}
    handlers['command']({ command = '/cw demo' })
    check('demo refuses while a pet is out', api.demoOn(), false)
    local refused = false
    for _, p in ipairs(printed) do if p:find('pet', 1, true) then refused = true end end
    check('...and says so', refused, true)
    check('...and leaves the model alone', api.model().burden.Fire, burden0)
    -- The documented use: no automaton at all. resolveIds() used to keep
    -- running under demo and, seeing no real pet against the non-zero
    -- lastPetId enable() had just set, fired pet_despawn one frame in: every
    -- demo recast read 'ready', the target row went blank and a false edge
    -- went to the log. (With a real pet of a different id it was pet_respawn,
    -- on the player's live state.) The suite never saw it because its PET is
    -- demo's constant and the block used to run inside a zone window.
    petIn()
    api.timersClear(false)
    CLOCKWORK_TEST.last = nil
    handlers['command']({ command = '/cw demo' })
    check('demo is on', api.demoOn(), true)
    frame('demo')
    check('no lifecycle edge fires on the made-up automaton',
          CLOCKWORK_TEST.last == nil or (CLOCKWORK_TEST.last.kind ~= 'pet_despawn'
                                         and CLOCKWORK_TEST.last.kind ~= 'pet_respawn'), true)
    check('the made-up automaton is drawn', saw('Alpha'), true)
    check('...with its target', saw('Steelshell Crab'), true)
    -- the model ran on the made-up inputs rather than being printed from them
    local counts = api.maneuverCounts()
    check('the maneuver census is computed', counts.Fire, 1)
    check('...for both elements', counts.Earth, 1)
    check('burden is seeded so the bars have something to show', api.model().burden.Earth, 31)
    -- and the recast rows come from the made-up attachments
    local rows = {}
    for _, r in ipairs(api.timerRows()) do rows[r.name] = r.state end
    check('a counting recast', rows['Provoke'], 'counting')
    check('and a ready one', rows['Shield Bash'], 'ready')

    -- A buff on the strip has to trace to an ability this automaton can
    -- actually use, and that ability's recast has to be running behind it.
    -- Refresh (43) was on this melee scenario, and Refresh comes from Mana
    -- Converter alone (ABILITY_ICON 1948) - a Dark attachment no Valoredge in
    -- the list wears - so the strip showed a buff with no source and no recast
    -- behind it. Stoneskin is the one that belongs: Shock Absorber is worn,
    -- and enable() lands every effect 20 s ago, so 1946 is 20 s into its 180.
    local onPet = {}
    for _, b in ipairs(api.petStrip()) do onPet[b.id] = true end
    check('the demo automaton has Stoneskin', onPet[37], true)
    check('...and no sourceless Refresh', onPet[43], nil)
    check('and the stoneskin recast runs behind the buff', rows['Shock Absorber'], 'counting')
    check('with no Mana Converter row at all', rows['Mana Converter'], nil)

    -- Your own recasts come from the made-up master too. Demo is for looking
    -- at the HUD off PUP, where the client's recast table holds nothing of a
    -- Puppetmaster's and HasAbility knows none of it - so both are emptied
    -- here, and the group still lists the master's five, at LSB's lengths
    -- (sql/abilities.sql recastTime).
    world.abilities, world.recast = {}, {}
    frame('demo: your recasts')
    local function jaByKey()
        local out = {}
        for _, r in ipairs(api.jaRefresh()) do out[r.key] = r end
        return out
    end
    local ja = jaByKey()
    check('the demo master has Activate on recast', (ja.activate or {}).state, 'counting')
    check('...with 13:40 of it left', (ja.activate or {}).remaining, 820)
    check('...out of 20:00, so its dial is not full', (ja.activate or {}).total, 1200)
    check('Repair is counting too', (ja.repair or {}).remaining, 52)
    check('...out of 1:30', (ja.repair or {}).total, 90)
    check('a maneuver has just gone up, so its recast is full', (ja.maneuver or {}).remaining, 10)
    check('...out of 10 s', (ja.maneuver or {}).total, 10)
    check('Deus Ex is ready', (ja.dea or {}).state, 'ready')
    check('...and so is Overdrive', (ja.overdrive or {}).state, 'ready')
    check('an ability switched on that the master lacks is not listed', ja.maintenance, nil)
    local nJa = 0
    for _ in pairs(ja) do nJa = nJa + 1 end
    check('five in all', nJa, 5)
    check('the group is drawn', saw('13:40'), true)
    api.config.cd_hide_ready = true
    check('hide when ready leaves the three counting', #api.jaRefresh(), 3)
    api.config.cd_hide_ready = false

    -- The made-up world MOVES. The recast rows always did, because they are
    -- read against the clock, but the maneuvers, the overload, the TP and the
    -- target's HP were constants and most of the panel sat still. They are
    -- inputs, so animating them is the automaton doing things and the real
    -- model still does all the computing.
    local man0 = api.activeManeuvers()[1].remaining
    local tp0 = api.petInfo().tp
    local mob0 = api.demoMob().hpp
    advance(6)
    frame('demo six seconds later')
    check('a maneuver is six seconds shorter', api.activeManeuvers()[1].remaining, man0 - 6)
    check('TP has moved', api.petInfo().tp ~= tp0, true)
    check('the target has lost health', api.demoMob().hpp < mob0, true)
    ja = jaByKey()
    check('your recasts run down with it', (ja.activate or {}).remaining, 814)
    check('...the maneuver one too', (ja.maneuver or {}).remaining, 4)

    -- ...and keep moving however long demo stays on. A maneuver coming back
    -- up is one being used, so the maneuver recast restarts with it (Fire's,
    -- at 42 s); Repair, ready at 52 s, is used again 30 s after that.
    advance(36)
    frame('demo 42 s in')
    check('the maneuver recast restarts as Fire comes back up', (jaByKey().maneuver or {}).remaining, 10)
    -- 52 s in: Repair's 1:30 is up, and Fire went up 10 s ago. A recast at
    -- 0 s is ready, as the client's slot at 0 ticks is.
    advance(10)
    frame('demo 52 s in')
    ja = jaByKey()
    check('Repair is ready the moment its recast is up', (ja.repair or {}).state, 'ready')
    check('...with no length', (ja.repair or {}).total, nil)
    check('the maneuver recast is ready 10 s after the maneuver', (ja.maneuver or {}).state, 'ready')
    advance(30)
    frame('demo 82 s in')
    check('Repair is used again', (jaByKey().repair or {}).remaining, 90)

    -- the next one is a different frame, which is the point of having more
    -- than one: a melee frame never reaches the spell ladder and only
    -- Sharpshot has a shot whose recast the head and Drum Magazine move.
    handlers['command']({ command = '/cw demo' })
    frame('demo 2')
    check('the second automaton is drawn', saw('Bravo'), true)
    check('...and it is the Sharpshot frame', api.currentFrame(), 'Sharpshot')
    local rows2 = {}
    for _, r in ipairs(api.timerRows()) do rows2[r.name] = r.state end
    check('the shot is a row on this frame', rows2['Ranged Attack'] ~= nil, true)
    check('...and Shield Bash is not', rows2['Shield Bash'], nil)
    -- On a melee frame the weaponskill line is the strip's big line - the
    -- weaponskill, or why there is none, since demo TP moves. show_ws off takes
    -- it off, and puts no 'no frame' in its place.
    api.config.compact = true
    local ws2, why2 = api.predictWS(api.currentFrame())
    local head2 = ws2 or why2
    frame('melee compact')
    check('the melee strip has a weaponskill line', head2 ~= nil, true)
    check('...drawn as its big line', saw(head2 or ''), true)
    api.config.show_ws = false
    frame('melee compact, no weaponskill')
    check('show_ws off takes it off the melee strip', saw(head2 or ''), false)
    check('...and says no frame in its place', saw('no frame'), false)
    api.config.show_ws, api.config.compact = true, false

    -- ...and the rest of the list, then off. The cycle always ends somewhere
    -- you can get back out of.
    handlers['command']({ command = '/cw demo' })
    check('the third is the healer', api.demoName(), 'Soulsoother, healer')
    -- On a caster frame the compact bar's big line is the SPELL and the
    -- weaponskill drops to the footnote, which is the only place the string
    -- 'WS ' is ever drawn. On a melee frame it is the other way round.
    api.config.compact = true
    frame('caster compact')
    check('the caster strip leads with the spell', saw('WS '), true)
    -- show_ws off: the footnote's weaponskill goes
    api.config.show_ws = false
    frame('caster compact, no weaponskill')
    check('show_ws off takes the weaponskill off the caster strip', saw('WS '), false)
    api.config.show_ws = true
    handlers['command']({ command = '/cw demo' })   -- 4: Spiritreaver
    check('the fourth is overloaded', api.demoName(), 'Spiritreaver, overloaded')
    api.config.compact = false
    local _, ol = api.activeManeuvers()
    check('...and says so', ol, 14)
    frame('demo 4')
    check('with no maneuver up, the maneuver recast is ready', (jaByKey().maneuver or {}).state, 'ready')
    -- The Loadout tab reads the scenario's loadout as the equipped set, which
    -- is right while demo is on. Read it HERE, on the last scenario: every
    -- scenario switch moves auto044Seq, so a set cached on an earlier one was
    -- already stale by the exit and could not show the bug.
    check('the equipped set is the made-up one',
          ((api.equippedSet() or {}).head or ''):find('Spiritreaver', 1, true) ~= nil, true)
    handlers['command']({ command = '/cw demo' })
    check('demo is off at the end of the list', api.demoOn(), false)
    check('the automaton went with it', api.model().burden.Earth, 0)
    -- ...and so did its loadout. disable() cleared tm.auto044 without moving
    -- auto044Seq, so equippedSet() went on answering from its cache: the tab
    -- showed the scenario's set as current and Save current wrote it to disk.
    check('the made-up loadout is not saveable afterwards', api.equippedSet(), nil)
    frame('after demo')
    check('and the made-up name is gone', saw('Alpha'), false)
    -- ...and your recasts are the client's again: its 30 s Repair, at the
    -- length the client shows rather than the demo's 1:30
    world.abilities = { [0x200 + 137] = true }
    world.recast = { [3] = { 206, 30 * 60 } }
    ja = jaByKey()
    check('off, your recasts are read off the client again', (ja.repair or {}).remaining, 30)
    check('...at the client\'s length', (ja.repair or {}).total, 30)
    check('...and nothing of the demo master\'s is left', ja.activate, nil)
    world.abilities, world.recast = {}, {}
    api.jaRefresh()
    -- it is runtime only: nothing about it reaches the settings file
    api.loadSettings()
    check('demo never persists', api.demoOn(), false)
end
