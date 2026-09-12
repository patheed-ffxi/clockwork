-- ------------------- a prediction that said it was unsure is not a hard miss --
-- Only the spell NAME was compared and only the Regen hedge was exempt, so a
-- pick the model had already flagged `uncertain` - an MP cost inside the
-- interval, a tier the two ends of it disagree about, a party heal whose
-- target enmity picks - was shouted about exactly as loudly as a confident
-- wrong answer. 1.11.1 made that worse by raising `uncertain` far more often.
-- Same treatment the hedge gets: the record is kept and marked, the alarm
-- stays quiet, and the counter measures what the model claimed CONFIDENTLY.
do
    world.hp, world.maxhp = 1000, 1000
    world.petHpp, world.petMpp = 100, 29          -- 87..89: the tier straddles 88
    world.icons, world.timers = nil, nil
    world.buffer = { 4, 35, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }
    advance(30)
    petOut(PET + 64, MOB + 64)
    send044({ head = 4, frame = 35, magic = 300, hp = 600, maxhp = 600, mp = 300, maxmp = 300 })
    api.setPetTarget(MOB + 64)
    handlers['d3d_present']()                     -- publish the snapshot
    check('the published pick is uncertain', api.spellSnapshot().mode, 'uncertain')
    check('...and names the tier it reached', api.spellSnapshot().name, 'Stone IV')
    api.spellCountersReset()
    CLOCKWORK_TEST.last = nil
    send028(act(8, 151, MOB + 64))                -- it casts the other candidate
    check('an uncertain miss is not an anomaly', CLOCKWORK_TEST.last.kind, 'pet_spell')
    check('...and the record still names what was expected',
          CLOCKWORK_TEST.last.rec.expected, 'Stone IV')
    check('...and marks it a miss', CLOCKWORK_TEST.last.rec.missed_uncertain, true)
    frame('uncertain counters')
    check('it is not counted against the model', saw('spells 1, mispredicted 0'), true)
    -- a CONFIDENT wrong answer is still an anomaly
    world.petMpp = 100
    handlers['d3d_present']()
    check('the published pick is certain now', api.spellSnapshot().mode == 'uncertain', false)
    api.spellCountersReset()
    advance(6)
    send028(act(8, 159, MOB + 64))                -- a tier nobody predicted
    check('a confident miss still is an anomaly', CLOCKWORK_TEST.last.kind, 'spell_mispredicted')
    frame('confident counters')
    check('and it counts', saw('spells 1, mispredicted 1'), true)
end

-- ------------------------ an inferred status is bounded, never open-ended --
-- A status inferred from a damage-only mob skill cannot be confirmed: the
-- packet says nothing about whether it landed, and a resisted one never sends
-- a wear-off. Sixty entries in the table carried duration 0 because the
-- generator could not evaluate the script's expression, and 0 fell to the
-- 1800 s backstop - so a Silence Gas the automaton RESISTED shut the spell
-- line for half an hour, against a real maximum of 60 s. Every duration is
-- resolved to the upper bound its script can pass now (math.random's high end,
-- calculateDuration at 3000 TP, and so on), and anything still unresolved is
-- bounded rather than left open.
do
    world.buffer = { 5, 35, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }
    world.hp, world.maxhp, world.petHpp, world.petMpp = 1000, 1000, 100, 100
    world.icons, world.timers = nil, nil
    advance(30)
    petOut(PET + 63, MOB + 63)
    send044({ head = 5, frame = 35, magic = 250, hp = 600, maxhp = 600, mp = 300, maxmp = 300 })
    api.forgetPet()
    -- silence_gas passes math.random(15, 60), so 60 is the most it can be
    check('silence gas is bounded in the table', api.mobskillEffect(314)[1][2], 60)
    send028({ actor = MOB + 63, category = 11, param = 314,
              targets = { { id = PET + 63, actions = { { message = 185, param = 120 } } } } })
    check('the silence is recorded', api.petLive(6), true)
    check('...with a clock', api.petUntil()[6] ~= nil and
          math.floor(api.petUntil()[6] - fakeClock) or nil, 60)
    local _, why = api.predictSpell()
    check('and the ladder holds while it stands', why, 'the automaton is silenced')
    advance(61)                                  -- past the script's maximum
    check('it clears itself on time', api.petLive(6), false)
    local _, why2 = api.predictSpell()
    check('and the ladder reopens', why2 == 'the automaton is silenced', false)

    -- no HELD effect anywhere in the table is open-ended any more
    local held, open = { [6]=1, [29]=1, [2]=1, [19]=1, [193]=1, [10]=1, [7]=1, [28]=1 }, 0
    for id = 1, 4000 do
        for _, se in ipairs(api.mobskillEffect(id) or {}) do
            if held[se[1]] and (se[2] == nil or se[2] == 0) then open = open + 1 end
        end
    end
    check('no HELD entry is left unbounded', open, 0)

    -- ...and a landing with no duration at all - a spikes proc - is bounded
    -- rather than parked on the 30-minute backstop
    api.forgetPet()
    send028({ actor = PET + 63, category = 1, param = 0,
              targets = { { id = MOB + 63, actions = { { message = 1, param = 12,
                                                         spike = { message = 374, param = 4 } } } } } })
    check('a spikes landing is recorded', api.petLive(4), true)
    check('...and bounded', api.petUntil()[4] ~= nil, true)
    advance(400)
    check('...and clears well before the backstop', api.petLive(4), false)
    api.forgetPet()
end

-- ------------------------------------------ Dia and Bio displace by TIER --
-- Both spell families check the OTHER one's tier before touching it: Dia is
-- tier 1, Bio 2, Dia II 3, Bio II 4, Dia III 5, Bio III 6, and each script
-- replaces the opposite effect only when its tier is strictly lower. Otherwise
-- it deals its damage and changes nothing at all - no delete, no add. clockwork
-- deleted the opposite unconditionally, on the mob and on the automaton, so a
-- Dia I into a standing Bio II wiped a debuff the mob still had and recorded
-- one it never got. XIUI, HXUI and kazenoeye all have the same bug; the server
-- scripts do not.
do
    advance(30)
    petOut(PET + 62, MOB + 62)
    api.setPetTarget(MOB + 62)
    -- Bio II lands, then a plain Dia is cast into it
    send028(act(4, 231, MOB + 62, 2, 40))
    check('Bio II is on the mob', api.mobs()[MOB + 62].fx[135] ~= nil, true)
    send028(act(4, 23, MOB + 62, 2, 27))
    check('a weaker Dia leaves Bio II alone', api.mobs()[MOB + 62].fx[135] ~= nil, true)
    check('...and records no Dia', api.mobs()[MOB + 62].fx[134], nil)
    -- Dia III outranks Bio II, so it does displace it
    send028(act(4, 25, MOB + 62, 2, 27))
    check('a stronger Dia displaces Bio II', api.mobs()[MOB + 62].fx[135], nil)
    check('...and is recorded', api.mobs()[MOB + 62].fx[134] ~= nil, true)
    check('under the spell that landed it', api.mobs()[MOB + 62].fx[134].spell, 25)
    -- and Bio II cannot take it back from Dia III (tier 4 against 5)
    send028(act(4, 231, MOB + 62, 2, 40))
    check('a weaker Bio leaves Dia III alone', api.mobs()[MOB + 62].fx[134] ~= nil, true)
    check('...and records no Bio', api.mobs()[MOB + 62].fx[135], nil)

    -- The SAME family, weaker or equal: status_effects.sql gives Dia and Bio
    -- overwrite HIGHER and the container takes only a strictly higher tier,
    -- so a Dia into a live Dia II changes nothing but its damage. The tracker
    -- used to take it - Dia I, a fresh 60 s - and a Bio I after that then
    -- displaced the 'Dia I' where the server still held Dia II over it.
    local function fx(m, e) return api.mobs()[MOB + m].fx[e] end
    send028(act(4, 24, MOB + 220, 2, 60))                   -- Dia II
    check('Dia II is on the mob', fx(220, 134) ~= nil and fx(220, 134).spell, 24)
    local ends0 = fx(220, 134).ends
    send028(act(4, 23, MOB + 220, 2, 20))                   -- a plain Dia into it
    check('a weaker Dia leaves Dia II in place', fx(220, 134).spell, 24)
    check('...with its own clock', fx(220, 134).ends, ends0)
    send028(act(4, 230, MOB + 220, 2, 20))                  -- Bio I: tier 2 against 3
    check('a Bio I cannot take it from Dia II', fx(220, 134) ~= nil and fx(220, 134).spell, 24)
    check('...and records no Bio', fx(220, 135), nil)
    send028(act(4, 24, MOB + 220, 2, 60))                   -- equal: HIGHER, not EQUAL_HIGHER
    check('a Dia II into a live Dia II keeps the first clock', fx(220, 134).ends, ends0)
    -- the Bio family's counterpart
    send028(act(4, 231, MOB + 221, 2, 60))                  -- Bio II
    local ends1 = fx(221, 135).ends
    send028(act(4, 230, MOB + 221, 2, 20))                  -- Bio I into it
    check('a weaker Bio leaves Bio II in place', fx(221, 135).spell, 231)
    check('...with its own clock', fx(221, 135).ends, ends1)
    send028(act(4, 23, MOB + 221, 2, 20))                   -- Dia I: tier 1 against 4
    check('a Dia I cannot take it from Bio II', fx(221, 135) ~= nil and fx(221, 135).spell, 231)
    check('...and records no Dia', fx(221, 134), nil)
    -- ...and once the standing one has run out, the weaker cast lands afresh:
    -- an expired same-family tier must not refuse the way the opposite one did
    advance(121)
    send028(act(4, 23, MOB + 220, 2, 20))
    check('a Dia after Dia II expired is recorded', fx(220, 134) ~= nil and fx(220, 134).spell, 23)

    -- the same ladder on the AUTOMATON, where the cast is the only signal
    api.forgetPet()
    send028({ actor = MOB + 62, category = 4, param = 231,
              targets = { { id = PET + 62, actions = { { message = 2, param = 40 } } } } })
    check('Bio II is on the automaton', api.petLive(135), true)
    send028({ actor = MOB + 62, category = 4, param = 23,
              targets = { { id = PET + 62, actions = { { message = 2, param = 27 } } } } })
    check('a weaker Dia leaves it alone there too', api.petLive(135), true)
    check('...and records no Dia there', api.petLive(134), false)
    send028({ actor = MOB + 62, category = 4, param = 25,
              targets = { { id = PET + 62, actions = { { message = 2, param = 27 } } } } })
    check('a stronger Dia displaces it', api.petLive(135), false)
    check('...and is recorded', api.petLive(134), true)
    api.forgetPet()
end

-- ---------------------------- a weaponskill that did not land opens nothing --
-- The resonance write checked the skill's PROPERTIES and its target and never
-- what the action did, so a miss opened a chain the mob does not carry and the
-- prediction spent the next ten seconds promising a closer for it. LSB applies
-- the skillchain only when the resolution is neither Miss nor Parry AND the
-- target is still alive (battleentity.cpp:2698).
do
    world.buffer = { 2, 33, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }
    world.icons, world.timers = nil, nil
    advance(30)
    petOut(PET + 70, MOB + 70)
    send044({ head = 2, frame = 33, melee = 200 })
    api.setPetTarget(MOB + 70)
    -- 188 SKILL_MISS: "<user> uses <skill>, but misses <target>."
    send028({ actor = PET + 71, category = 11, param = 1940,
              targets = { { id = MOB + 70, actions = { { message = 188, param = 0 } } } } })
    advance(4)
    local ws, why, mode = api.predictWS('Valoredge')
    check('a missed weaponskill opens no chain', mode == 'chain', false)
    check('...and nothing claims to close one', (why or ''):find('closes', 1, true), nil)
    -- 189 SKILL_NO_EFFECT, and 31 SHADOW_ABSORB, are Miss resolutions too
    advance(20)
    send028({ actor = PET + 72, category = 11, param = 1940,
              targets = { { id = MOB + 70, actions = { { message = 189, param = 0 } } } } })
    advance(4)
    check('a no-effect weaponskill opens no chain', select(3, api.predictWS('Valoredge')) == 'chain', false)
    advance(20)
    send028({ actor = PET + 73, category = 11, param = 1940,
              targets = { { id = MOB + 70, actions = { { message = 31, param = 1 } } } } })
    advance(4)
    check('shadows eating it opens no chain', select(3, api.predictWS('Valoredge')) == 'chain', false)
    -- ...and one that connects still does
    advance(20)
    send028({ actor = PET + 74, category = 11, param = 1940,
              targets = { { id = MOB + 70, actions = { { message = 185, param = 300 } } } } })
    advance(4)
    ws, why, mode = api.predictWS('Valoredge')
    check('a landed weaponskill still opens one', mode, 'chain')
    check('...and names what closes it', ws, 'Cannibal Blade')
    advance(30)
end

-- ------------------------------------ a resonance belongs to the mob it is on --
-- The skillchain is a status effect on the MOB, but clockwork kept one global
-- slot with no target on it: a chain opened on mob A still promised a closer
-- while the automaton was fighting mob B, and it outlived a resummon and a
-- zone as well. It is the last piece of per-mob state that 1.9.0's rewrite
-- left behind.
do
    world.buffer = { 2, 33, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }   -- Valoredge, no Inhibitor
    world.icons, world.timers = nil, nil
    advance(20)                                   -- any earlier resonance is long dead
    petOut(PET + 55, MOB + 55)
    send044({ head = 2, frame = 33, melee = 200 })
    send028(act(11, 1940, MOB + 55))              -- the automaton's Chimera Ripper on A
    advance(4)                                    -- inside the 3..10 s window
    local ws, why, mode = api.predictWS('Valoredge')
    check('a chain on this mob names a closer', ws, 'Cannibal Blade')
    check('and says so', mode, 'chain')
    check('naming what it closes', (why or ''):find('Compression', 1, true) ~= nil, true)
    -- the automaton is put on an unrelated mob and swings at it
    send028({ actor = PET + 55, category = 1, param = 0,
              targets = { { id = MOB + 56, actions = { { message = 1, param = 12 } } } } })
    check('the target moved', api.petTarget(), MOB + 56)
    local why2
    ws, why2, mode = api.predictWS('Valoredge')
    check('the other mob carries no chain', mode == 'chain', false)
    -- the maneuver branch still names a skill, as it should; what must not
    -- survive is the CLAIM that the skill closes something
    check('and nothing claims to close', (why2 or ''):find('closes', 1, true), nil)
    -- back on the original mob inside the window, the chain is still there:
    -- the effect is on the server's copy of that mob, not on the addon
    send028({ actor = PET + 55, category = 1, param = 0,
              targets = { { id = MOB + 55, actions = { { message = 1, param = 12 } } } } })
    ws, _, mode = api.predictWS('Valoredge')
    check('back on the first mob it is live again', ws, 'Cannibal Blade')
    check('...and still a chain', mode, 'chain')
    -- a lifecycle edge and a zone both drop the target, so both drop the chain
    petIn()
    petOut(PET + 56, MOB + 55)
    ws, _, mode = api.predictWS('Valoredge')
    check('a resummon drops it', mode == 'chain', false)
    advance(20)
end

-- --------------------------------- a zone clears the recasts, in either order --
-- The 0x00A handler called timersClear(false) and the despawn edge
-- timersClear(true), so the state after a zone depended on whether the frame
-- that saw PetTargetIndex == 0 ran before or after the packet: the same zone
-- could leave the cells `ready` one time and `unknown` the next. The model
-- treats a zone as clearing the recasts, exactly as a Deactivate/Activate
-- does. Both paths say `ready` now, and the
-- record says which edge it was so the two populations stay separable.
do
    local function zone() handlers['packet_in']({ id = 0x00A, injected = false, data = '' }) end
    world.buffer = { 2, 33, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }   -- Valoredge, Strobe
    world.icons, world.timers = nil, nil
    advance(6)
    petOut(PET + 50, MOB + 50)
    send044({ head = 2, frame = 33, attachments = { 1 } })
    send028(act(11, 1945, MOB + 50))              -- Provoke: 30 s on the clock
    check('the cell is counting before the zone', timerRow(1945).state, 'counting')

    -- order one: the packet lands first, then the frame notices the automaton
    zone()
    check('a zone clears the recasts', timerRow(1945).state, 'ready')
    petIn()                                       -- the despawn edge, after
    check('...and the despawn edge agrees', timerRow(1945).state, 'ready')
    petOut(PET + 51, MOB + 51)
    advance(7)
    send028(act(11, 1945, MOB + 51))
    check('the first use logs an edge', CLOCKWORK_TEST.last.kind, 'recast_edge')
    -- the despawn belongs to the zone that caused it, so the zone keeps the name
    check('the edge is named', CLOCKWORK_TEST.last.rec.edge, 'zone')

    -- ...and the zone keeps its provenance whichever side of it the frame
    -- notices on. The despawn a zone causes is not a despawn - the automaton
    -- comes back - so it must not relabel the edge or move its timestamp.
    send028(act(11, 1945, MOB + 51))              -- Provoke counting again
    handlers['packet_in']({ id = 0x00A, injected = false, data = '' })
    advance(3)                                    -- the loading screen
    petIn()                                       -- the frame notices only now
    petOut(PET + 60, MOB + 60)
    advance(5)
    send028(act(11, 1945, MOB + 60))
    check('a late despawn does not steal the zone', CLOCKWORK_TEST.last.rec.edge, 'zone')
    check('and does not move its clock', CLOCKWORK_TEST.last.rec.since_edge, 8)
    -- a REAL dismissal well after the zone is still its own edge
    advance(60)
    petIn()
    petOut(PET + 61, MOB + 61)
    advance(4)
    send028(act(11, 1945, MOB + 61))
    check('a later dismissal is its own edge', CLOCKWORK_TEST.last.rec.edge, 'pet_despawn')

    -- order two: the frame notices first, then the packet lands
    send028(act(11, 1944, MOB + 51))              -- Shield Bash: 180 s on the clock
    check('bash counting before the zone', timerRow(1944).state, 'counting')
    petIn()
    zone()
    check('the other order clears them too', timerRow(1944).state, 'ready')
    petOut(PET + 52, MOB + 52)
    advance(9)
    send028(act(11, 1944, MOB + 52))
    check('the second use logs an edge too', CLOCKWORK_TEST.last.kind, 'recast_edge')
    check('measured from the zone', CLOCKWORK_TEST.last.rec.since_edge, 9)
    check('and the zone is named', CLOCKWORK_TEST.last.rec.edge, 'zone')

    -- a summon names itself, so a zone reading and a fresh-automaton reading
    -- are never mixed in the calibration set
    petIn()
    advance(6)
    send028({ actor = 0x01000001, category = 6, param = 136,
              targets = { { id = 0x01000001, actions = { { message = 0 } } } } })
    petOut(PET + 53, MOB + 53)
    send028(act(11, 1945, MOB + 53))
    check('an Activate edge is named', CLOCKWORK_TEST.last.rec.edge, 'activate')
    petIn()
    advance(6)
    send028({ actor = 0x01000001, category = 6, param = 310,
              targets = { { id = 0x01000001, actions = { { message = 0 } } } } })
    petOut(PET + 54, MOB + 54)
    send028(act(11, 1945, MOB + 54))
    check('a Deus Ex edge is named', CLOCKWORK_TEST.last.rec.edge, 'dea')
    world.buffer = { 2, 33, 5, 4, 1, 2, 3, 0, 0, 0, 0, 0, 0, 0 }
    advance(2.5)
end

-- ---------------------------------- pet MP is an interval, not a point --
-- The client reports the automaton's MP as an integer PERCENT, so
-- floor(maxmp * mpp / 100) under-reads by up to maxmp/100 - 1: 88 of 300 MP
-- reads as 29%, rebuilds as 87, and Cure IV at 88 was called unaffordable and
-- Cure III predicted while the server cast Cure IV. LSB's GetMPP
-- (battleentity.cpp:298) also reports at least 1% for any positive MP, so
-- below 1% of max the same arithmetic OVER-reads.
do
    world.hp, world.maxhp = 300, 1000        -- the master at 30%: the heal rung opens
    world.petHpp, world.petMpp = 100, 29
    world.icons, world.timers = nil, nil
    world.buffer = { 5, 35, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }
    advance(2.5)
    petOut(PET + 68, MOB + 68)
    send044({ head = 5, frame = 35, magic = 250, hp = 600, maxhp = 600, mp = 300, maxmp = 300 })
    local name, _, mode = api.predictSpell()
    local lo, hi = api.petMp()
    check('29% of 300 starts at 87', lo, 87)
    check('...and reaches 89', hi, 89)
    check('a cost inside the interval is still predicted', name, 'Cure IV')
    check('...and flagged uncertain', mode, 'uncertain')
    -- clear of the interval it is a hard answer, either way
    world.petMpp = 40                         -- 120..122
    handlers['d3d_present']()
    name, _, mode = api.predictSpell()
    check('above the interval it is certain', name, 'Cure IV')
    check('above the interval it is not flagged', mode == 'uncertain', false)
    world.petMpp = 20                         -- 60..62, Cure IV out of reach
    handlers['d3d_present']()
    name, _, mode = api.predictSpell()
    check('below the interval it drops a tier', name, 'Cure III')
    check('below the interval it is not flagged', mode == 'uncertain', false)
    -- A maxmp that is not a multiple of 100. GetMPP is
    -- floor(100 * mp / maxmp), so mp >= maxmp*mpp/100 and mp < maxmp*(mpp+1)/100
    -- - which inverts to CEILING at both ends, not floor. 1.10.0 used floor for
    -- both and every fixture used maxmp 300, where 300*mpp/100 is always a whole
    -- number and the two agree: a fixture that could not fail. At 315 they do
    -- not agree, and the true value falls outside the interval: 88 of 315 reads
    -- as 27%, floor rebuilds [85,87] and Cure IV at 88 is called unaffordable.
    world.petMpp = 27
    handlers['d3d_present']()
    send044({ head = 5, frame = 35, magic = 250, hp = 600, maxhp = 600, mp = 315, maxmp = 315 })
    -- gather() rebuilds the interval, so read it AFTER a prediction, not before
    name, _, mode = api.predictSpell()
    lo, hi = api.petMp()
    check('27% of 315 starts at 86', lo, 86)
    check('...and reaches 88', hi, 88)
    check('the server would report 88/315 as 27%', math.floor(100 * 88 / 315), 27)
    check('so Cure IV is back in reach', name, 'Cure IV')
    check('...and flagged, since 88 is only the top of the range', mode, 'uncertain')
    send044({ head = 5, frame = 35, magic = 250, hp = 600, maxhp = 600, mp = 300, maxmp = 300 })
    -- the two ends. 1% is the server's floor for ANY positive MP, so it spans
    -- from 1 rather than from 3; 0% is exactly empty; 100% cannot exceed max.
    world.petMpp = 1
    handlers['d3d_present']()
    api.predictSpell()
    lo, hi = api.petMp()
    check('the 1% floor starts at 1', lo, 1)
    check('the 1% floor reaches 5', hi, 5)
    world.petMpp = 0
    handlers['d3d_present']()
    api.predictSpell()
    lo, hi = api.petMp()
    check('0% is exactly empty', lo, 0)
    check('0% has no width', hi, 0)
    world.petMpp = 100
    handlers['d3d_present']()
    api.predictSpell()
    lo, hi = api.petMp()
    check('full MP is the maximum', lo, 300)
    check('full MP does not exceed it', hi, 300)
    world.hp, world.maxhp, world.petMpp = 1000, 1000, 100
end

-- ------------------------- a hedge does not outlive the line it was said on --
-- tm.regenHedge was reset BELOW three early returns, and the sidebar's eight
-- hypothetical ladders run after the live publish each frame - so the last
-- hypothetical's hedge was still standing on the next frame, and a live pass
-- that early-returned never reached the reset. The published snapshot then
-- claimed to have warned about a Regen on a line that never mentioned one,
-- and the Regen that followed was excused instead of logged.
do
    local SELF = 0x01000001
    world.hp, world.maxhp, world.petHpp, world.petMpp = 1000, 1000, 100, 100
    world.buffer = { 5, 35, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }
    world.icons, world.timers = { 40, 41, 42, 33, 37, 116 }, { 0, 0, 0, 0, 0, 0 }
    advance(2.5)
    petOut(PET + 67, MOB + 67)
    send028(act(8, 56, MOB + 67))                  -- establish the target
    send044({ head = 5, frame = 35, magic = 200, hp = 600, maxhp = 600, mp = 300, maxmp = 300 })
    send028(act(4, 54, SELF))                      -- Stoneskin: the automaton is buffed
    advance(25)
    handlers['d3d_present']()
    check('the live line hedges', api.spellSnapshot().hedge, 'regen')
    api.sidebarRows()                              -- eight hypothetical ladders, all hedging
    -- ...and now the automaton is silenced, so the live pass returns above
    -- where the reset used to sit
    send028({ actor = MOB + 67, category = 4, param = 59,
              targets = { { id = PET + 67, actions = { { message = 230, param = 6 } } } } })
    handlers['d3d_present']()
    check('a silenced line says so',
          (api.spellSnapshot().why or ''):find('silenced', 1, true) ~= nil, true)
    check('and carries no hedge', api.spellSnapshot().hedge, nil)
    world.icons, world.timers = nil, nil
end

-- ---------------------- effects on a mob are kept PER MOB, from anyone --
-- The server's own test, CanUseEnfeeble, is whether the target carries the
-- effect from ANY source. So the table is the one XIUI, HXUI and kazenoeye
-- keep - enemies[serverId][effect] - fed by every target of every 0x028
-- whatever the actor, cleared per effect on a wear-off, per mob on a death,
-- wholesale on a zone. The master-silences-first slot this replaces assumed
-- the master was the only other caster and that the next mob was whatever he
-- touched last; a party breaks both, and a dead mob's timestamp outlived it.
do
    local SELF, OTHER = 0x01000001, 0x01000009
    world.buffer = { 5, 35, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }
    advance(2.5)
    petOut(PET + 70, MOB + 70)
    send044({ head = 5, frame = 35, magic = 200, hp = 600, maxhp = 600, mp = 300, maxmp = 300 })
    api.setPetTarget(0)
    -- a PARTY MEMBER paralyzes the mob the automaton has not reached yet
    send028({ actor = OTHER, category = 4, param = 58,
              targets = { { id = MOB + 70, actions = { { message = 236, param = 4 } } } } })
    check('mob entry opened by a stranger', api.mobs()[MOB + 70] ~= nil, true)
    check('mob entry is not the live view yet', api.targetEffects()[4], nil)
    -- a Cure on another party member in between changes nothing on the mob
    -- (this was the pre-slot's undoing: any third entity replaced it)
    send028({ actor = SELF, category = 4, param = 2,
              targets = { { id = OTHER, actions = { { message = 7, param = 120 } } } } })
    check('mob a cured party member is not a mob', api.mobs()[OTHER], nil)
    check('mob the paralysis is still held', api.mobs()[MOB + 70].fx[4] ~= nil, true)
    -- ...and the automaton engages that mob: the paralysis is known, whoever landed it
    send028(act(8, 56, MOB + 70))
    check('mob target adopted', api.petTarget(), MOB + 70)
    check('mob paralysis known on engage', api.targetHas(4), true)
    check('mob provenance is the stranger', api.mobs()[MOB + 70].fx[4].who, 'other')
    advance(25)
    local name = api.predictSpell()
    check('mob ladder skips the held paralyze', name ~= 'Paralyze', true)
    -- an AoE lands on every target in the packet, not the last one
    send028({ actor = OTHER, category = 4, param = 357,
              targets = { { id = MOB + 71, actions = { { message = 236, param = 13 } } },
                          { id = MOB + 72, actions = { { message = 236, param = 13 } } } } })
    check('mob aoe first target', api.mobs()[MOB + 71].fx[13] ~= nil, true)
    check('mob aoe second target', api.mobs()[MOB + 72].fx[13] ~= nil, true)
    check('mob aoe clock is the spell', api.mobs()[MOB + 72].fx[13].ends ~= nil, true)
    -- a switch keeps the old mob, and a Deploy back finds it still known
    send028(act(8, 254, MOB + 71))
    check('mob switched', api.petTarget(), MOB + 71)
    check('mob new target reads its own entry', api.targetHas(13), true)
    check('mob old entry survives the switch', api.mobs()[MOB + 70].fx[4] ~= nil, true)
    send028(act(8, 59, MOB + 70))
    check('mob deploy back finds the paralysis', api.targetHas(4), true)
    -- self and the automaton never become mobs
    send028({ actor = SELF, category = 4, param = 43,
              targets = { { id = SELF, actions = { { message = 230, param = 40 } } } } })
    send028({ actor = SELF, category = 4, param = 44,
              targets = { { id = PET + 70, actions = { { message = 230, param = 40 } } } } })
    check('mob self is not a mob', api.mobs()[SELF], nil)
    check('mob automaton is not a mob', api.mobs()[PET + 70], nil)
    -- the death of ANY known mob drops it, target or not...
    send029(OTHER, MOB + 72, 0, 6)
    check('mob death drops a non-target', api.mobs()[MOB + 72], nil)
    -- ...and the respawn on the same id starts clean
    send028({ actor = OTHER, category = 4, param = 59,
              targets = { { id = MOB + 72, actions = { { message = 236, param = 6 } } } } })
    check('mob respawn carries nothing over', api.mobs()[MOB + 72].fx[13], nil)
    check('mob respawn has the new effect', api.mobs()[MOB + 72].fx[6] ~= nil, true)
    -- "has no effect" from anyone is evidence: the mob has it, or is immune -
    -- the server says no to the automaton either way
    send028({ actor = OTHER, category = 4, param = 59,
              targets = { { id = MOB + 73, actions = { { message = 75, param = 0 } } } } })
    check('mob refusal recorded', api.mobs()[MOB + 73].fx[6] ~= nil, true)
    check('mob refusal marked', api.mobs()[MOB + 73].fx[6].src, 'refused')
    send028(act(8, 56, MOB + 73))
    check('mob refusal read by the ladder', api.targetHas(6), true)
    -- a refusal never shortens a landing already held
    local held = api.mobs()[MOB + 72].fx[6].at
    send028({ actor = SELF, category = 4, param = 59,
              targets = { { id = MOB + 72, actions = { { message = 75, param = 0 } } } } })
    check('mob refusal defers to a live landing', api.mobs()[MOB + 72].fx[6].at, held)
    check('mob refusal keeps the landing source', api.mobs()[MOB + 72].fx[6].src, 'landed')
    -- a plain resist is neither a landing nor a refusal
    send028({ actor = OTHER, category = 4, param = 58,
              targets = { { id = MOB + 73, actions = { { message = 85, param = 0 } } } } })
    check('mob resist records nothing', api.targetHas(4), false)
    -- a stranger's Dia lands in silence too, off its damage line
    send028({ actor = OTHER, category = 4, param = 24,
              targets = { { id = MOB + 73, actions = { { message = 2, param = 41 } } } } })
    check('mob stranger dia from the cast', api.targetHas(134), true)
    -- a summon forgets no mob; a zone forgets every one
    send028({ actor = SELF, category = 6, param = 136,
              targets = { { id = SELF, actions = { { message = 0 } } } } })
    check('mob summon keeps the table', api.mobs()[MOB + 70] ~= nil, true)
    handlers['packet_in']({ id = 0x00A, injected = false, data = '' })
    check('mob zone clears all', next(api.mobs()), nil)
    -- pruning: past 48 mobs, one not named for ten minutes with nothing live
    -- on it goes; a mob with a live effect stays; the current target stays
    petOut(PET + 70, MOB + 70)
    api.setPetTarget(MOB + 300)
    send028({ actor = OTHER, category = 4, param = 58,
              targets = { { id = MOB + 300, actions = { { message = 236, param = 4 } } } } })
    for i = 1, 60 do
        send028({ actor = OTHER, category = 4, param = 58,
                  targets = { { id = MOB + 400 + i, actions = { { message = 236, param = 4 } } } } })
    end
    advance(601)                                   -- every Paralyze is dead
    send028({ actor = OTHER, category = 4, param = 59,
              targets = { { id = MOB + 500, actions = { { message = 236, param = 6 } } } } })
    check('mob prune dropped a stale stranger', api.mobs()[MOB + 401], nil)
    check('mob prune dropped the last stale one', api.mobs()[MOB + 460], nil)
    check('mob prune kept the new mob', api.mobs()[MOB + 500] ~= nil, true)
    check('mob prune kept the target', api.mobs()[MOB + 300] ~= nil, true)
    local n = 0
    for _ in pairs(api.mobs()) do n = n + 1 end
    check('mob prune left the camp', n, 2)
    api.setPetTarget(0)
end
-- ------------------------------ the cast record carries the MP it worked from --
-- Affordability is a real gate - LSB's Cast reaches CanAffordSpell, which
-- IgnoreRecastsAndCosts::Yes does not bypass - and it was the one ladder input
-- no log could be checked against afterwards. The number is a render-thread
-- read, so gather publishes it for the packet thread rather than the record
-- reaching for memory it must not touch.
do
    local SELF = 0x01000001
    world.hp, world.maxhp, world.petHpp, world.petMpp = 1000, 1000, 100, 50
    world.buffer = { 5, 35, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }
    world.icons, world.timers = nil, nil
    advance(2.5)
    petOut(PET + 75, MOB + 75)
    api.setPetTarget(MOB + 75)
    send044({ head = 5, frame = 35, magic = 250, hp = 600, maxhp = 600, mp = 300, maxmp = 300 })
    advance(25)
    handlers['d3d_present']()
    send028(act(8, 59, MOB + 75))
    local last = CLOCKWORK_TEST.last
    check('mp logged on the cast', last.rec.maxmp, 300)
    check('mp is the live half of the pool', last.rec.mp, 150)
    -- ...and it follows the percent, which is the live half of the reading
    world.petMpp = 20
    advance(25)
    handlers['d3d_present']()
    send028(act(8, 56, MOB + 75))
    last = CLOCKWORK_TEST.last
    check('mp follows the percent', last.rec.mp, 60)
    -- and it is a GATE, not decoration. Both sides hold a Regen so the rung
    -- goes straight to Protect, and the master is the one without it: at a
    -- full pool the ladder names the top tier this skill allows, at 60 MP it
    -- names the one the automaton can actually pay for. (Protect IV costs 65
    -- and needs skill 217; Protect III costs 46 and needs 144.)
    world.icons, world.timers = { 42 }, { 0 }
    send028({ actor = MOB + 75, category = 4, param = 110,
              targets = { { id = PET + 75, actions = { { message = 230, param = 42 } } } } })
    world.petMpp = 100
    advance(25)
    check('mp gate at a full pool', (api.predictSpell()), 'Protect IV')
    world.petMpp = 20
    check('mp gate drops a tier when it cannot pay', (api.predictSpell()), 'Protect III')
    world.icons, world.timers = nil, nil
    -- with no 0x044 since the last reload there is no reading at all, and
    -- usable() skips the affordability test - so the record says so rather
    -- than inventing a pool
    api.clear044()
    advance(25)
    handlers['d3d_present']()
    send028(act(8, 254, MOB + 75))
    last = CLOCKWORK_TEST.last
    check('mp unknown says so', last.rec.mp, -1)
    check('mp unknown max says so', last.rec.maxmp, -1)
    world.petMpp = 100
end

-- ---------------------------------------------------- healing a party --
-- The Soulsoother's party arm: a member cured with no Light up, a member
-- lower than a master who also qualifies named first, the tier off the
-- member's own missing HP; and a flagged heal answered by a different Cure
-- logged as a miss the model owned up to, with the target and the party on
-- the record.
do
    local STONEY = 0x01000530
    world.hp, world.maxhp, world.petHpp, world.petMpp = 1000, 1000, 100, 100
    world.icons, world.timers = nil, nil                  -- no maneuvers: no Light
    world.buffer = { 5, 35, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }
    world.party, world.partyHp = { [1] = 25 }, { [1] = 250 }
    world.partyNames, world.partyIds = { [1] = 'Stoney' }, { [1] = STONEY }
    advance(30)
    petOut(PET + 96, MOB + 96)
    send044({ head = 5, frame = 35, magic = 280, hp = 600, maxhp = 600, mp = 600, maxmp = 600 })
    api.setPetTarget(MOB + 96)
    local name, why, mode = api.predictSpell()
    check('party cure with no Light', name, 'Cure V')           -- 250 of 1000: 750 missing
    check('party cure names the member', why, 'heal · Stoney at 25% (enmity picks who)')
    check('party cure is flagged', mode, 'uncertain')
    -- one Light: the threshold is 40, and you at 35% qualify too
    world.icons, world.timers = { 306 }, { 0 }
    world.hp = 350
    name, why = api.predictSpell()
    check('the lower member is named first', why, 'heal · Stoney at 25% · or you at 35%')
    check('...with the member\'s tier', name, 'Cure V')
    world.party, world.partyHp = { [1] = 38 }, { [1] = 380 }
    name, why, mode = api.predictSpell()
    check('a lower master is named first', why, 'heal · you at 35% · or Stoney at 38%')
    check('...with your tier', name, 'Cure V')                  -- 650 missing
    check('...and still flagged', mode, 'uncertain')
    -- the flagged heal published, then answered by another Cure
    world.hp = 1000
    world.party, world.partyHp = { [1] = 25 }, { [1] = 250 }
    handlers['d3d_present']()
    check('the flagged heal is published', api.spellSnapshot().rung, 'heal')
    check('...flagged', api.spellSnapshot().mode, 'uncertain')
    api.spellCountersReset()
    CLOCKWORK_TEST.last = nil
    send028(act(8, 4, STONEY))                                  -- a Cure IV on Stoney
    local last = CLOCKWORK_TEST.last
    check('another Cure for a flagged heal is no anomaly', last.kind, 'pet_spell')
    check('...but is marked a miss', last.rec.missed_uncertain, true)
    check('the record names the target', last.rec.target, 'Stoney')
    check('the record carries the party', last.rec.party, 'Stoney 25% 250')
    check('the record carries your HP%', last.rec.you_hpp, 100)
    frame('party cure counters')
    check('it is not counted against the model', saw('spells 1, mispredicted 0'), true)
    -- a flagged heal answered by something that is not a Cure still is one
    advance(20)
    handlers['d3d_present']()
    check('the flagged heal again', api.spellSnapshot().rung, 'heal')
    send028(act(8, 56, MOB + 96))                               -- Slow instead
    check('a non-Cure for a flagged heal is an anomaly', CLOCKWORK_TEST.last.kind, 'spell_mispredicted')
    check('...aimed at the mob', CLOCKWORK_TEST.last.rec.target, 'mob')
    world.party, world.partyHp, world.partyNames, world.partyIds = nil, nil, nil, nil
    world.icons, world.timers = nil, nil
end

-- ------------------------------------ the party's buffs, and the arm --
-- 0x076 carries every other member's buffs, and the enhance rung's party arm
-- reads them. Regen is certain only at the two ends; Protect, Shell and
-- Haste go to the first member without one once you and the automaton both
-- hold it.
do
    local STONEY, AZURTH = 0x01000531, 0x01000532
    send076({ { id = STONEY, buffs = { 42, 296 } } })
    local fx = api.partyBuffs()[STONEY]
    check('0x076 reads a buff', fx ~= nil and fx[42] == true, true)
    check('0x076 rebuilds the high bits', fx ~= nil and fx[296] == true, true)
    check('0x076 a high id is not its low byte', fx ~= nil and fx[40] == nil, true)
    check('0x076 skips the empty slots', fx ~= nil and fx[255] == nil, true)

    world.hp, world.maxhp, world.petHpp, world.petMpp = 1000, 1000, 100, 100
    world.icons, world.timers = { 42, 40, 41, 33 }, { 0, 0, 0, 0 }   -- you hold all four
    world.buffer = { 5, 35, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }
    world.party, world.partyHp = { [1] = 100, [2] = 100 }, { [1] = 900, [2] = 900 }
    world.partyNames, world.partyIds = { [1] = 'Stoney', [2] = 'Azurth' }, { [1] = STONEY, [2] = AZURTH }
    advance(30)
    petOut(PET + 97, MOB + 97)
    send044({ head = 5, frame = 35, magic = 280, hp = 600, maxhp = 600, mp = 600, maxmp = 600 })
    api.setPetTarget(MOB + 97)
    -- the automaton's own Haste proves it holds Protect and Shell
    send028({ actor = PET + 97, category = 4, param = 57,
              targets = { { id = PET + 97, actions = { { message = 230, param = 33 } } } } })
    advance(30)
    send076({ { id = STONEY, buffs = { 42 } }, { id = AZURTH, buffs = { 42, 40, 41 } } })
    local name, why, mode = api.predictSpell()
    check('party protect names the member', why,
          'enhance · no Protect on Stoney · or a Regen, if hate is on someone without one')
    check('party protect tier', name, 'Protect IV')
    check('party protect is flagged', mode, 'uncertain')
    send076({ { id = STONEY, buffs = { 42, 40 } }, { id = AZURTH, buffs = { 42, 40, 41 } } })
    name, why = api.predictSpell()
    check('party shell next', why,
          'enhance · no Shell on Stoney · or a Regen, if hate is on someone without one')
    -- nobody holds a Regen: one is certain, only its target is not
    world.icons, world.timers = { 40, 41, 33 }, { 0, 0, 0 }
    send076({ { id = STONEY, buffs = { 40, 41 } }, { id = AZURTH, buffs = { 40, 41 } } })
    name, why = api.predictSpell()
    check('party regen when nobody has one', why, 'enhance · no Regen on anyone (hate picks who)')
    check('...names a Regen', (name or ''):sub(1, 5), 'Regen')
    -- a member no 0x076 has named could hold one: hedged, not certain
    world.party[3], world.partyHp[3], world.partyIds[3] = 100, 900, 0x01000533
    name, why = api.predictSpell()
    check('an unread member hedges the Regen',
          (why or ''):find('or a Regen, if hate is on someone without one', 1, true) ~= nil, true)
    world.party, world.partyHp, world.partyNames, world.partyIds = nil, nil, nil, nil
    world.icons, world.timers = nil, nil
    send076({})
end
