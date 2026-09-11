-- ------------------------------------------ dia and bio land in silence --
-- Their spell scripts return damage from onSpellCast and add the DoT quietly,
-- so the 0x028 carries a damage message and no status line - the wear-off is
-- announced, the landing never is. The chat window shows only the damage
-- line where Blind shows '(blinded)', and without the cast as the signal the
-- ladder would offer Bio II again seconds later. The cast is the only signal
-- there is.
do
    local function n()
        local c = 0
        for _ in pairs(api.targetEffects()) do c = c + 1 end
        return c
    end
    petOut(PET + 60, MOB + 60)
    -- an enemy-aimed spell establishes the target and clears what we knew
    send028(act(8, 56, MOB + 60))
    check('dot target established', api.petTarget(), MOB + 60)
    -- an ordinary enfeeble still comes in on its own status message
    send028(act(4, 56, MOB + 60, 236, 13))
    check('dot slow by status message', api.targetEffects()[13] ~= nil, true)
    check('dot bio not yet', api.targetEffects()[135], nil)
    -- Bio II: damage only, no status line anywhere in the packet
    send028(act(4, 231, MOB + 60, 2, 34))
    check('dot bio from the cast', api.targetEffects()[135] ~= nil, true)
    -- Dia displaces Bio and Bio displaces Dia, but only up the shared tier
    -- ladder. Dia III (5) outranks the standing Bio II (4); Dia II (3) would
    -- not, and the server would leave Bio II alone.
    send028(act(4, 25, MOB + 60, 2, 41))
    check('dot dia recorded', api.targetEffects()[134] ~= nil, true)
    check('dot bio dropped by dia', api.targetEffects()[135], nil)
    -- a full resist STILL applies it: onSpellCast adds the effect whatever
    -- message useDamageSpell settled on. Bio III (6) to outrank Dia III (5).
    send028(act(4, 232, MOB + 60, 85, 0))
    check('dot bio survives a resist', api.targetEffects()[135] ~= nil, true)
    check('dot dia dropped by bio', api.targetEffects()[134], nil)
    -- and a nuke's damage records nothing: only the Dia and Bio families carry
    -- 134 or 135 in the enfeeble column
    local before = n()
    send028(act(4, 144, MOB + 60, 2, 120))
    check('dot nuke records nothing', n(), before)
end

-- ------------------------------------- what an enhance cast proves is on --
-- TryEnhance is a total order and the AUTOMATON's arm of each buff is ungated,
-- so a Shell cast at anyone proves the automaton already holds Protect and a
-- Haste proves Protect and Shell. It is the only way to learn about a buff
-- applied before the automaton came into view - nothing announces its own
-- effects, so petEffects starts empty on every load. With the doll's Shell
-- invisible a model that infers nothing would offer Protect III on every
-- window after the server has already cast it.
do
    local SELF = 0x01000001
    world.hp, world.maxhp, world.petHpp, world.petMpp = 1000, 1000, 100, 100
    world.buffer = { 5, 35, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }
    -- the master holds Protect, Shell and Regen; the automaton holds nothing
    -- the client can see
    world.icons, world.timers = { 40, 41, 42 }, { 0, 0, 0 }
    advance(2.5)
    petOut(PET + 61, MOB + 61)
    api.setPetTarget(MOB + 61)
    send044({ head = 5, frame = 35, magic = 200, hp = 600, maxhp = 600, mp = 300, maxmp = 300 })
    -- give the AUTOMATON a Regen too, so both hold one and the Regen question
    -- is settled outright - what is left to predict is the buff ladder, which
    -- is what this block is about. (With only the master holding one the rung
    -- would correctly hedge every line below, which is a different test.)
    send028({ actor = MOB + 61, category = 4, param = 110,
              targets = { { id = PET + 61, actions = { { message = 230, param = 42 } } } } })
    advance(20)
    -- neither side is owed a Regen; the master has Protect, so the Protect on
    -- offer is for the automaton
    local name, why = api.predictSpell()
    check('ladder protect for the doll', name, 'Protect III')
    check('ladder protect why', why, 'enhance · no Protect on automaton')
    -- the server casts a SHELL instead: Protect was already satisfied
    send028(act(4, 50, SELF))
    advance(20)
    name, why = api.predictSpell()
    check('ladder shell after a shell', name, 'Shell III')
    check('ladder shell why', why, 'enhance · no Shell on automaton')
    -- and a Haste proves the Shell landed on the automaton too
    send028(act(4, 57, SELF))
    advance(25)
    name, why = api.predictSpell()
    check('ladder haste after a haste', name, 'Haste')
    check('ladder haste for the master', why, 'enhance · no Haste on you')
    -- a Regen proves NOTHING - it may have gone to the master - so with the
    -- master's own Haste up the automaton's is still the open question. Were a
    -- Regen ranked with the buffs this would read Stoneskin instead.
    world.icons, world.timers = { 40, 41, 42, 33 }, { 0, 0, 0, 0 }
    send028(act(4, 110, SELF))
    advance(25)
    name, why = api.predictSpell()
    check('ladder regen proves nothing', why, 'enhance · no Haste on automaton')
    world.icons, world.timers = nil, nil
end

-- --------------------------------------- one side with Regen holds hate --
-- The automaton's own Regen went to the hate holder, so the side that HAS one
-- is the side that holds hate and no Regen is coming; when NEITHER side
-- holds one, the ladder predicts one.
do
    world.hp, world.maxhp, world.petHpp, world.petMpp = 1000, 1000, 100, 100
    world.buffer = { 5, 35, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }
    world.icons, world.timers = nil, nil
    advance(2.5)
    petOut(PET + 62, MOB + 62)
    api.setPetTarget(MOB + 62)
    send044({ head = 5, frame = 35, magic = 200, hp = 600, maxhp = 600, mp = 300, maxmp = 300 })
    advance(25)
    -- NEITHER has one: a Regen is coming, only the target is unknown
    local name, why, mode = api.predictSpell()
    check('regen neither', name, 'Regen II')
    check('regen neither why', why, 'enhance · no Regen on you or automaton (hate picks which)')
    check('regen neither uncertain', mode, 'uncertain')
    -- the MASTER has one, so the master holds hate: fall through, and do not
    -- hedge the way 1.7.1 did
    world.icons, world.timers = { 42 }, { 0 }
    name, why = api.predictSpell()
    check('regen one side falls through', name, 'Protect III')
    check('regen one side does not hedge', (why or ''):find('else', 1, true), nil)
    -- and the same the other way round: the automaton's Regen, the master's not
    world.icons, world.timers = nil, nil
    send028({ actor = MOB + 62, category = 4, param = 108,
              targets = { { id = PET + 62, actions = { { message = 230, param = 42 } } } } })
    name = api.predictSpell()
    check('regen other side falls through', name, 'Protect III')
    -- and with BOTH holding one there was never a Regen to cast
    world.icons, world.timers = { 42 }, { 0 }
    name = api.predictSpell()
    check('regen both skipped', name, 'Protect III')
end

-- --------------------------------------- an anomaly says what it expected --
-- The record always held it; the line that INTERRUPTS you did not, so
-- 'ANOMALY spell_mispredicted logged' sent you to the JSONL to find out what
-- the model had in mind. And the weaponskill record never held the reasoning
-- at all - the render thread computed predictWS's why every frame and dropped
-- it on the floor, so a WS anomaly said which skill was wrong but never which
-- of the three branches decided it.
do
    local function clearPrinted() while #printed > 0 do table.remove(printed) end end
    local function said(text)
        for _, p in ipairs(printed) do if p:find(text, 1, true) then return true end end
        return false
    end

    -- ---- a weaponskill anomaly ----
    clearPrinted()
    world.buffer = { 2, 33, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }
    world.tp = 1000
    advance(2.5)
    petOut(PET + 80, MOB + 80)
    send044({ head = 2, frame = 33, melee = 120 })
    advance(1)
    handlers['d3d_present']()
    local want, wantWhy, wantMode = api.predictWS('Valoredge')
    check('ws anomaly has something to expect', want ~= nil, true)
    check('ws anomaly has a reason to expect it', (wantWhy or '') ~= '', true)
    -- whichever of the two it named, send the OTHER one
    send028(act(11, (want == 'Chimera Ripper') and 1941 or 1940))
    local last = CLOCKWORK_TEST.last
    check('ws anomaly kind', last.kind, 'ws_mispredicted')
    check('ws anomaly is a real disagreement', last.rec.ws ~= last.rec.expected, true)
    check('ws anomaly names the expectation', last.rec.expected, want)
    -- the WHY, not the mode: the refresher keeps three values now, and
    -- taking two of them would quietly file 'chain' as the reasoning
    check('ws anomaly carries its reasoning', last.rec.expected_why, wantWhy)
    check('ws anomaly still carries its mode', last.rec.mode, wantMode)
    check('ws anomaly says the expectation in chat', said('expected ' .. want), true)
    check('ws anomaly says the reasoning in chat', said(last.rec.expected_why or '(none)'), true)

    -- ---- a spell anomaly ----
    clearPrinted()
    world.hp, world.maxhp, world.petHpp, world.petMpp = 1000, 1000, 100, 100
    world.buffer = { 5, 35, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }
    world.icons, world.timers = nil, nil
    advance(2.5)
    petOut(PET + 81, MOB + 81)
    api.setPetTarget(MOB + 81)
    send044({ head = 5, frame = 35, magic = 200, hp = 600, maxhp = 600, mp = 300, maxmp = 300 })
    advance(25)
    handlers['d3d_present']()
    local spell, why = api.predictSpell()
    check('spell anomaly has something to expect', spell, 'Regen II')
    send028(act(8, 59))                                  -- Silence instead
    last = CLOCKWORK_TEST.last
    check('spell anomaly kind', last.kind, 'spell_mispredicted')
    check('spell anomaly names the expectation', last.rec.expected, spell)
    check('spell anomaly says what happened', said('got Silence'), true)
    check('spell anomaly says the expectation in chat', said('expected ' .. spell), true)
    check('spell anomaly says the reasoning in chat', said(why), true)

    -- ---- an anomaly with no prediction keeps the bare form ----
    clearPrinted()
    send028(act(4, 59, MOB + 81, 236, 6, 9999))       -- a 32-bit recast read gone wrong
    check('bare anomaly still names its kind', said('ANOMALY spell_recast_implausible'), true)
    check('bare anomaly invents no expectation', said('expected'), false)
end

-- ----------------------------------- who the server picks for its Regen --
-- The Regen goes to ONE entity - the highest-enmity one - and is skipped if
-- that one already has it: the master can go without a Regen while the
-- automaton is re-Regened again and again, and take a Haste from the same
-- ladder in the meantime - engaged, in range and eligible, simply not the
-- target. So with exactly one side lacking one, a Regen comes only if hate
-- MOVED: not while one side holds it throughout, only when the two trade
-- it. Modelled, not readable: enmity is in no packet.
-- Which of those two worlds you are in is not readable from who holds what -
-- but it IS readable from the sides the server has lately chosen.
do
    local SELF = 0x01000001
    world.hp, world.maxhp, world.petHpp, world.petMpp = 1000, 1000, 100, 100
    world.buffer = { 5, 35, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }
    world.icons, world.timers = { 42 }, { 0 }          -- the master holds a Regen
    advance(2.5)
    petOut(PET + 63, MOB + 63)
    api.setPetTarget(MOB + 63)
    send044({ head = 5, frame = 35, magic = 200, hp = 600, maxhp = 600, mp = 300, maxmp = 300 })
    advance(25)
    check('regen nothing read yet', next(api.regenAt()), nil)
    -- the automaton lacks one and we have watched no Regen at all, so we do
    -- not know that it ISN'T the target: silence is not evidence
    local name, why, mode = api.predictSpell()
    check('regen unread pick', name, 'Protect III')
    check('regen unread hedges', why,
          'enhance · no Protect on you · or a Regen, if hate has moved back to the automaton')
    check('regen unread is uncertain', mode, 'uncertain')
    -- now the server Regens the AUTOMATON. That Regen has since worn off -
    -- no status message here - but hate was demonstrably there a moment ago.
    send028(act(4, 110, PET + 63))
    check('regen side read from the cast', api.regenAt()['automaton'] ~= nil, true)
    check('regen other side still unread', api.regenAt()['you'], nil)
    advance(25)
    name, why, mode = api.predictSpell()
    check('regen contested pick unchanged', name, 'Protect III')
    check('regen contested says a Regen may take it', why,
          'enhance · no Protect on you · or a Regen, if hate has moved back to the automaton')
    check('regen contested is uncertain', mode, 'uncertain')
    -- five minutes later that reading is STALE, and a stale one IS evidence:
    -- we have been watching and the server has not chosen the automaton since
    advance(300)
    name, why, mode = api.predictSpell()
    check('regen stale pick', name, 'Protect III')
    check('regen stale drops the hedge', why, 'enhance · no Protect on you')
    check('regen stale is certain again', mode, 'default')
    -- and the other side reads 'back to you', not 'back to the you'
    world.icons, world.timers = nil, nil                  -- the master without one
    send028({ actor = MOB + 63, category = 4, param = 108,
              targets = { { id = PET + 63, actions = { { message = 230, param = 42 } } } } })
    advance(25)
    name, why = api.predictSpell()
    check('regen hedge names the master plainly', why,
          'enhance · no Protect on you · or a Regen, if hate has moved back to you')
    world.icons, world.timers = { 42 }, { 0 }
    -- a Regen aimed at neither of ours says nothing about either side
    send028(act(4, 111, MOB + 63))
    check('regen party target records neither', api.regenAt()['you'], nil)
    -- both sides holding one is still a certain skip, hedge or no hedge
    send028({ actor = MOB + 63, category = 4, param = 108,
              targets = { { id = PET + 63, actions = { { message = 230, param = 42 } } } } })
    advance(25)
    name, why, mode = api.predictSpell()
    check('regen both held is certain again', mode, 'default')
    check('regen both held drops the hedge', (why or ''):find('hate has moved', 1, true), nil)
    -- and the automaton going away takes the reading with it
    petIn()
    check('regen reading cleared with the automaton', next(api.regenAt()), nil)
    world.icons, world.timers = nil, nil
end

-- ------------------------------------ an effect expires on its own clock --
-- The server re-casts at its first window AFTER an enfeeble ends, and the
-- wear-off message reaches the client in the same breath as that cast: the
-- 'poison effect wears off' line and the Poison II that replaces it land in
-- the SAME SECOND, cast after cast. Waiting for the message therefore cannot
-- predict the cast - every such Poison II is a mispredict the model had no
-- reason to expect yet. Base durations are exact (Poison II 120, Blind 180,
-- Slow 180, Paralyze 120, Silence 120) and resistance only ever shortens
-- them, which still arrives as a wear-off - so the clock is safe in one
-- direction and exact in the other.
do
    petOut(PET + 64, MOB + 64)
    send028(act(8, 56, MOB + 64))              -- an enemy-aimed spell sets the target
    check('expiry starts clean', next(api.targetUntil()), nil)
    -- Poison II: the status message says WHAT landed, the cast says HOW LONG
    send028(act(4, 221, MOB + 64, 236, 3))
    check('expiry poison recorded', api.targetHas(3), true)
    check('expiry poison has a clock', api.targetUntil()[3] ~= nil, true)
    advance(100)
    check('expiry poison still on at 100s', api.targetHas(3), true)
    advance(18)                                -- 118s: inside the two-second lead
    check('expiry poison gone before any message', api.targetHas(3), false)
    check('expiry poison entry dropped', api.targetEffects()[3], nil)
    -- Poison I is 90s, not 120: the clock is the spell's, not the effect's
    send028(act(4, 220, MOB + 64, 236, 3))
    advance(89)
    check('expiry poison i is the shorter clock', api.targetHas(3), false)
    -- an effect whose cast we never saw keeps the flat backstop
    send028({ actor = MOB + 64, category = 4, param = 43,
              targets = { { id = MOB + 64, actions = { { message = 230, param = 40 } } } } })
    check('expiry unsourced effect has no clock', api.targetUntil()[40], nil)
    advance(150)
    check('expiry unsourced effect still on at 150s', api.targetHas(40), true)
    advance(40)
    check('expiry unsourced effect falls to the backstop', api.targetHas(40), false)
    -- Bio lands in silence and still gets a clock, from the cast alone
    send028(act(4, 231, MOB + 64, 2, 34))
    check('expiry bio has a clock', api.targetUntil()[135] ~= nil, true)
    advance(119)
    check('expiry bio gone at its own duration', api.targetHas(135), false)
    -- a full resist on an effect the target does not have records nothing:
    -- there is no live effect to put a clock on
    send028(act(4, 58, MOB + 64, 85, 0))
    check('expiry resist records nothing', api.targetEffects()[4], nil)
    check('expiry resist sets no clock', api.targetUntil()[4], nil)
    -- and a wear-off still clears both halves, which is what covers a resisted
    -- enfeeble running short of its base duration
    send028(act(4, 254, MOB + 64, 236, 5))
    check('expiry blind on', api.targetHas(5), true)
    send029(MOB + 64, MOB + 64, 5, 206)
    check('expiry wear-off clears the effect', api.targetEffects()[5], nil)
    check('expiry wear-off clears the clock', api.targetUntil()[5], nil)
    -- a new target throws the clocks away with the effects. (A second Blind
    -- here would be dropped as a duplicate - identical bytes inside five
    -- seconds - so this uses a different spell rather than a sleep.)
    send028(act(4, 56, MOB + 64, 236, 13))
    check('expiry slow has a clock', api.targetUntil()[13] ~= nil, true)
    send028(act(8, 56, MOB + 65))
    check('expiry new target clears the clocks', next(api.targetUntil()), nil)
end

-- --------------------------- a Regen preempts whatever is said below it --
-- The Regen is the FIRST thing the enhance rung tries, so a hate move takes
-- the window from anything the server would otherwise reach below it - the
-- enfeeble the model named, or the silence when it named nothing at all.
-- 1.7.8 decorated only the pick tryEnhance made itself, so a miss could go
-- out as a flat 'nothing to cast' that a Regen then took, carrying no
-- warning whatever.
do
    local SELF = 0x01000001
    world.hp, world.maxhp, world.petHpp, world.petMpp = 1000, 1000, 100, 100
    world.buffer = { 5, 35, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }
    -- the master wants for nothing and holds a Regen; the automaton has none
    world.icons, world.timers = { 40, 41, 42, 33, 37, 116 }, { 0, 0, 0, 0, 0, 0 }
    advance(2.5)
    petOut(PET + 66, MOB + 66)
    send028(act(8, 56, MOB + 66))                  -- establish the target
    send044({ head = 5, frame = 35, magic = 200, hp = 600, maxhp = 600, mp = 300, maxmp = 300 })
    -- a Stoneskin proves Protect, Shell and Haste are already on the automaton
    send028(act(4, 54, SELF))
    advance(25)
    -- so the enhance rung has nothing of its own to say and the answer comes
    -- from the enfeeble rung BELOW it - which a Regen would still preempt
    local name, why, mode = api.predictSpell()
    check('hedge below the rung has an enfeeble', name ~= nil, true)
    check('hedge reaches the enfeeble pick',
          (why or ''):find('or a Regen, if hate has moved back to the automaton', 1, true) ~= nil, true)
    check('hedge below the rung is uncertain', mode, 'uncertain')
    -- now put every enfeeble this head can reach on the mob. Addle is the one
    -- left out and it needs skill 337, well past this automaton, so there is
    -- nothing left to say at all.
    for i, eff in ipairs({ 3, 5, 13, 4, 6, 135 }) do
        send028({ actor = MOB + 66, category = 4, param = 42 + i,
                  targets = { { id = MOB + 66, actions = { { message = 236, param = eff } } } } })
    end
    advance(25)
    name, why = api.predictSpell()
    check('hedge with nothing to cast at all', name, nil)
    check('hedge reaches the silence', why,
          'nothing to cast · or a Regen, if hate has moved back to the automaton')
    -- and a SHUT enhance window carries no hedge: nothing can come from a
    -- rung that is closed, so the silence there is honestly silent
    send028(act(8, 45, SELF))                      -- a Protect start shuts it for 15 s
    advance(6)                                     -- magic (4 s) back, enhance still shut
    name, why = api.predictSpell()
    check('hedge gone with the window', (why or ''):find('or a Regen', 1, true), nil)
    check('hedge shut window still says why', (why or ''):find('enhance', 1, true) ~= nil, true)
    -- a HEAL sits above the enhance rung, so a Regen cannot preempt it and the
    -- line must not pretend otherwise
    advance(20)                                    -- the enhance rung is open again
    world.hp, world.maxhp = 200, 1000              -- the master at 20%
    name, why = api.predictSpell()
    check('hedge heal is a heal', (why or ''):find('heal', 1, true) ~= nil, true)
    check('hedge not on a heal', (why or ''):find('or a Regen', 1, true), nil)
    world.hp, world.maxhp = 1000, 1000
    -- and a WAIT LIST is hedged like any other silence, because the enhance
    -- rung is open and a Regen can still take the window from it
    send028(act(8, 143, SELF))                     -- a status start shuts that rung 15 s
    advance(6)                                     -- magic (4 s) back, status still shut
    name, why = api.predictSpell()
    check('hedge wait list names the rung', (why or ''):find('status', 1, true) ~= nil, true)
    check('hedge on the wait list', (why or ''):find('or a Regen', 1, true) ~= nil, true)
    world.icons, world.timers = nil, nil
end

-- --------------------- the weaponskill line reads the frame off the packet --
-- 1.10.0 gave predictSpell, the sidebar and timerRows the 0x044 frame
-- fallback but left the two WEAPONSKILL consumers on bare currentFrame():
-- refreshPrediction, which publishes the snapshot the packet thread judges a
-- weaponskill against, and the HUD's own WS line. With a valid 0x044 and an
-- empty client buffer both went blank - the HUD said "open the attachments
-- window once" about a frame the server had already named, and every
-- pet_ws record in that stretch logged `expected: none`.
do
    world.buffer = { 2, 33, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }   -- Valoredge
    world.icons, world.timers = nil, nil
    advance(30)
    petOut(PET + 58, MOB + 58)
    send044({ head = 2, frame = 33, melee = 200 })
    send028(act(11, 1940, MOB + 58))              -- open a chain to predict off
    advance(4)
    world.buffer = { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }   -- the buffer empties
    advance(2.5)
    drawn = {}
    frame('ws line with an empty client buffer')
    check('the HUD does not ask for the attachments window',
          saw('no frame - open the attachments window once'), false)
    check('it names the weaponskill instead', saw('Cannibal Blade'), true)
    -- ...and the published snapshot, which is what a weaponskill is judged against
    CLOCKWORK_TEST.last = nil
    send028(act(11, 1941, MOB + 58))              -- String Clipper: not what the chain picked
    check('the record carries the prediction', CLOCKWORK_TEST.last.rec.expected, 'Cannibal Blade')
    check('so a real miss is judged as one', CLOCKWORK_TEST.last.kind, 'ws_mispredicted')
    world.buffer = { 2, 33, 5, 4, 1, 2, 3, 0, 0, 0, 0, 0, 0, 0 }
    advance(20)
end

-- ------------------------------ the nuke tier reads the whole MP interval --
-- tryElemental's tier boundaries ARE the cheapest nuke of each tier: the
-- tier-3 gate is mp >= 88 and Stone IV costs exactly 88. So taking the tier
-- from the low end of the interval alone puts every tier-3 nuke out of reach
-- before usable() is ever asked, and 1.10.0's affordability fix cannot recover
-- a spell the loop never visits. At 29% of 300 the automaton holds 87 to 89:
-- the low end says tier 2 and picks Blizzard III with no caveat, while 88 MP
-- would have the server cast Stone IV.
do
    world.hp, world.maxhp = 1000, 1000        -- nobody hurt: the heal rung declines
    world.petHpp, world.petMpp = 100, 29
    world.icons, world.timers = nil, nil
    world.buffer = { 4, 35, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }
    advance(30)
    petOut(PET + 57, MOB + 57)
    send044({ head = 4, frame = 35, magic = 300, hp = 600, maxhp = 600, mp = 300, maxmp = 300 })
    api.setPetTarget(MOB + 57)
    local name, _, mode = api.predictSpell()
    local lo, hi = api.petMp()
    check('the interval straddles the tier-3 boundary at 88', lo, 87)
    check('...on its high end', hi, 89)
    check('the tier is read from the top of the interval', name, 'Stone IV')
    check('and the pick is not stated as certain', mode, 'uncertain')
    -- clear of the boundary the answer is a plain one again
    world.petMpp = 20                         -- 60..62: every tier-3 nuke is out
    handlers['d3d_present']()
    name, _, mode = api.predictSpell()
    -- list order within the tier: Thunder III (91) and Blizzard III (75) are
    -- both out of reach, Aero III (54) is the first that is not
    check('below the boundary it is a tier-2 nuke', name, 'Aero III')
    check('...stated plainly', mode == 'uncertain', false)
    world.petMpp = 100
    handlers['d3d_present']()
end

-- ------------------------- a missed wear-off does not shut the line for ever --
-- HELD shuts the spell prediction outright, and an effect learned from a
-- status MESSAGE carries no clock - so a wear-off that never arrived, because
-- the automaton was out of range or the packet was dropped, held the line shut
-- for the 30-minute buff backstop. Each blocker ages on its own scale now.
do
    world.buffer = { 5, 35, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }
    world.hp, world.maxhp, world.petHpp, world.petMpp = 1000, 1000, 100, 100
    world.icons, world.timers = nil, nil
    advance(30)
    petOut(PET + 67, MOB + 67)
    send044({ head = 5, frame = 35, magic = 250, hp = 600, maxhp = 600, mp = 300, maxmp = 300 })
    api.forgetPet()
    -- a Silence announced by its own status message, and then no wear-off ever
    send028({ actor = MOB + 67, category = 4, param = 59,
              targets = { { id = PET + 67, actions = { { message = 236, param = 6 } } } } })
    check('the silence is believed', api.petLive(6), true)
    check('...with no clock of its own', api.petUntil()[6], nil)
    advance(179)
    check('it is still believed inside its cap', api.petLive(6), true)
    advance(2)
    check('and gone past it', api.petLive(6), false)
    local _, why = api.predictSpell()
    check('so the ladder reopens', why == 'the automaton is silenced', false)
    -- a Stun ages far faster than a Silence: 30 s, not 180
    api.forgetPet()
    send028({ actor = MOB + 67, category = 4, param = 252,
              targets = { { id = PET + 67, actions = { { message = 236, param = 10 } } } } })
    check('the stun is believed', api.petLive(10), true)
    advance(31)
    check('and a stun does not outlive a silence', api.petLive(10), false)
    -- something that is NOT a casting blocker keeps the long backstop
    api.forgetPet()
    send028({ actor = MOB + 67, category = 4, param = 254,
              targets = { { id = PET + 67, actions = { { message = 236, param = 5 } } } } })
    advance(400)
    check('an ordinary debuff keeps the buff backstop', api.petLive(5), true)
    api.forgetPet()
end
