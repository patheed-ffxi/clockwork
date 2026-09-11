-- ------------------------ the automaton's buffs after a reload are UNKNOWN --
-- Nothing announces them, so petEffects starts empty on every load - and an
-- empty table there means "no idea", not "none". Offering a buff anyway bets
-- the automaton is unbuffed, which after a reload with an automaton out is
-- exactly backwards: Protect and Shell run thirty minutes and are almost
-- certainly already up. The case: a reload with a buffed automaton out. The
-- ladder must not call Protect or Shell for the automaton while the server
-- is casting the master's own; it waits for a reading instead.
do
    local SELF = 0x01000001
    world.hp, world.maxhp, world.petHpp, world.petMpp = 1000, 1000, 100, 100
    world.buffer = { 5, 35, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }
    world.icons, world.timers = { 42 }, { 0 }     -- the master: Regen, nothing else
    advance(2.5)
    petOut(PET + 80, MOB + 80)
    api.setPetTarget(MOB + 80)
    send044({ head = 5, frame = 35, magic = 250, hp = 600, maxhp = 600, mp = 300, maxmp = 300 })
    -- the SUMMON is what says the automaton carries nothing. Nothing else
    -- does: a despawn is a dismiss or a zone and cannot be told apart, and no
    -- packet ever lists the automaton's effects.
    api.forgetPet()
    check('known a bare pet alone says nothing', api.petKnown()[40], nil)
    send028({ actor = SELF, category = 6, param = 136,
              targets = { { id = SELF, actions = { { message = 0 } } } } })
    check('known the summon is the reading', api.petKnown()[40], true)
    check('known the summon covers every buff', api.petKnown()[116], true)
    -- a summon also ends the automaton's engagement, so put it back on a mob
    api.setPetTarget(MOB + 80)
    advance(25)
    -- ...and now the addon reloads with that automaton already out
    api.forgetPet()
    check('known nothing after a reload', next(api.petKnown()), nil)
    -- the master lacks Protect, so the Protect on offer is his - which the
    -- old model also got right
    local name = api.predictSpell()
    check('known reload protects the master', name, 'Protect IV')
    -- the server buffs the MASTER. A Protect proves nothing about the doll,
    -- so the doll is still unread - and the rung must move on to Shell for the
    -- master rather than claim the doll needs a Protect.
    send028(act(4, 46, SELF))
    world.icons, world.timers = { 42, 40 }, { 0, 0 }
    advance(25)
    name = api.predictSpell()
    check('known reload will not guess the doll', name, 'Shell IV')
    -- the Shell DOES prove the doll holds Protect - it sits above Shell on an
    -- ungated arm - so that one becomes a reading, and the rung moves to Haste
    -- for the master rather than a Shell for the doll.
    send028(act(4, 51, SELF))
    check('known a shell reads the doll protect', api.petKnown()[40], true)
    check('known the doll shell is still unread', api.petKnown()[41], nil)
    world.icons, world.timers = { 42, 40, 41 }, { 0, 0, 0 }
    advance(25)
    name = api.predictSpell()
    check('known reload hastes the master', name, 'Haste')
    -- a buff LANDING on the automaton is a reading too, and so is watching one
    -- wear off - after which the arm is live again, because now we know
    send028({ actor = MOB + 80, category = 4, param = 57,
              targets = { { id = PET + 80, actions = { { message = 230, param = 33 } } } } })
    check('known a landing reads it', api.petKnown()[33], true)
    world.icons, world.timers = { 42, 40, 41, 33 }, { 0, 0, 0, 0 }
    advance(25)
    check('known doll haste held', api.predictSpell() ~= 'Haste', true)
    send029(PET + 80, PET + 80, 33, 206)
    check('known a wear-off is a reading', api.petKnown()[33], true)
    advance(25)
    check('known doll haste offered once read', api.predictSpell(), 'Haste')
    -- a wear-off can be the FIRST reading of an effect. After a reload we have
    -- never seen the doll's Shell at all; watching it go says it is gone, and
    -- the arm comes back on the strength of that alone.
    api.forgetPet()
    world.icons, world.timers = { 42, 40, 41, 33 }, { 0, 0, 0, 0 }
    check('known shell unread again', api.petKnown()[41], nil)
    send029(PET + 80, PET + 80, 41, 206)
    check('known a wear-off alone is a reading', api.petKnown()[41], true)
    advance(25)
    check('known doll shell offered once read', api.predictSpell(), 'Shell IV')
    -- and a ZONE is not a summon: the automaton keeps everything and we merely
    -- lose sight of it, so everything goes back to unknown
    handlers['packet_in']({ id = 0x00A, injected = false, data = '' })
    check('known nothing after a zone', next(api.petKnown()), nil)
    -- nor does a DESPAWN say anything either way - it is a dismiss or a zone
    -- and the two want opposite answers, so only the next summon speaks
    send028({ actor = SELF, category = 6, param = 136,
              targets = { { id = SELF, actions = { { message = 0 } } } } })
    check('known summon speaks again', api.petKnown()[40], true)
    handlers['packet_in']({ id = 0x00A, injected = false, data = '' })
    petIn()
    check('known a despawn says nothing', next(api.petKnown()), nil)
    -- and a Deus Ex Automata is a summon too: it builds the same bare
    -- automaton, however loudly it arrives
    advance(10)
    send028({ actor = SELF, category = 6, param = 310,
              targets = { { id = SELF, actions = { { message = 0 } } } } })
    check('known a deus ex is a summon too', api.petKnown()[41], true)
    world.icons, world.timers = nil, nil
end

-- ----------------- the automaton half of every buff pair, after a summon --
-- The server buffs the master and then the automaton with each of Protect,
-- Shell and Haste, one per enhance window. With an automaton Activated
-- minutes earlier, a summon that leaves no mark makes the automaton's empty
-- effect table read as ignorance rather than as bare, and the ladder names
-- only the master's half of each pair. The summon must count as a reading.
do
    local SELF = 0x01000001
    local function summon()
        send028({ actor = SELF, category = 6, param = 136,
                  targets = { { id = SELF, actions = { { message = 0 } } } } })
    end
    local function onPet(spell, effect)
        send028({ actor = MOB + 91, category = 4, param = spell,
                  targets = { { id = PET + 91, actions = { { message = 230, param = effect } } } } })
    end
    world.hp, world.maxhp, world.petHpp, world.petMpp = 1000, 1000, 100, 100
    world.buffer = { 5, 35, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }
    world.icons, world.timers = { 42 }, { 0 }        -- the master holds a Regen
    -- clear of the previous block's identical Activate, which isDuplicate
    -- would otherwise swallow: same bytes inside five seconds
    advance(10)
    petOut(PET + 91, MOB + 91)
    send044({ head = 5, frame = 35, magic = 250, hp = 600, maxhp = 600, mp = 300, maxmp = 300 })
    api.forgetPet()                                   -- as a reload leaves it
    summon()
    api.setPetTarget(MOB + 91)
    advance(25)
    check('pair protect for the master', (api.predictSpell()), 'Protect IV')
    world.icons, world.timers = { 42, 40 }, { 0, 0 }  -- it lands on him
    check('pair protect for the automaton', (api.predictSpell()), 'Protect IV')
    onPet(46, 40)                                     -- and on it
    check('pair shell for the master', (api.predictSpell()), 'Shell IV')
    world.icons, world.timers = { 42, 40, 41 }, { 0, 0, 0 }
    check('pair shell for the automaton', (api.predictSpell()), 'Shell IV')
    onPet(51, 41)
    check('pair haste for the master', (api.predictSpell()), 'Haste')
    world.icons, world.timers = { 42, 40, 41, 33 }, { 0, 0, 0, 0 }
    check('pair haste for the automaton', (api.predictSpell()), 'Haste')
    world.icons, world.timers = nil, nil
end

-- ------------------- how long an enfeeble ACTUALLY lasts on these mobs --
-- The book duration is an upper bound: a resisted enfeeble runs at half, and
-- how often that happens belongs to the mobs being fought, not to the spell.
-- A resisted Silence can expire before its base duration, and a model that
-- trusts the book then keeps it for up to a minute after it has gone and
-- offers the next rung while the server re-casts the Silence, with the
-- wear-off arriving too late to help. So the learner clocks an effect from
-- what it has seen on these mobs.
do
    petOut(PET + 95, MOB + 95)
    send028(act(8, 56, MOB + 95))                    -- establish the target
    send044({ head = 5, frame = 35, magic = 250, hp = 600, maxhp = 600, mp = 300, maxmp = 300 })
    -- an effect nobody has measured keeps its book value: Blind runs 180
    send028(act(4, 254, MOB + 95, 236, 5))
    advance(100)
    check('dur unmeasured effect keeps the book', api.targetHas(5), true)
    -- five Silences that each ran 61 seconds, not the book 120. Five, because
    -- that is the window the model keeps - it flushes anything an earlier
    -- block left behind, so the median below is these and only these.
    for _ = 1, 5 do
        send028(act(4, 59, MOB + 95, 236, 6))
        advance(61)
        send029(MOB + 95, MOB + 95, 6, 206)
        advance(3)
    end
    check('dur window is five deep', #api.seenDur()[59], 5)
    check('dur reading is what it ran', math.floor(api.seenDur()[59][5]), 61)
    -- so the next one is clocked from what was SEEN, not from the book
    send028(act(4, 59, MOB + 95, 236, 6))
    advance(45)
    check('dur learned clock still on at 45s', api.targetHas(6), true)
    advance(15)
    check('dur learned clock gone at 60s', api.targetHas(6), false)
    -- a reading is still taken when the effect OUTLIVES what we expected -
    -- measured against the landing, not against an entry the clock has
    -- already written off. That is what lets the window climb back when the
    -- mob stops resisting, instead of locking the short value in forever.
    send028(act(4, 59, MOB + 95, 236, 6))
    advance(70)
    check('dur written off early', api.targetHas(6), false)
    advance(50)
    send029(MOB + 95, MOB + 95, 6, 206)
    check('dur late wear-off still measured', math.floor(api.seenDur()[59][5]), 120)
end

-- ------------------ what lands on the automaton without a status line --
-- A Dia or Bio cast at it reports only its damage; a hit's "Additional
-- effect: Poison" rides in the packet's add-effect tail, which the parser
-- used to skip over; 168 of LSB's mob skills add their status from a separate
-- call and return the damage message (Poison Sting); and a mob's spikes land
-- on the automaton in its own action's spike tail. XIUI's pet bar reads the
-- tail; none of the installed trackers read the silent skills, so those come
-- with the duration the script passes and clear themselves.
do
    local SELF, OTHER = 0x01000001, 0x01000009
    petOut(PET + 110, MOB + 110)
    send044({ head = 5, frame = 35, magic = 250, hp = 600, maxhp = 600, mp = 300, maxmp = 300 })
    api.forgetPet()
    -- Bio II from the mob: a damage line and nothing else
    send028({ actor = MOB + 110, category = 4, param = 231,
              targets = { { id = PET + 110, actions = { { message = 2, param = 34 } } } } })
    check('pet bio from the cast', api.petLive(135), true)
    check('pet bio has a clock', api.petUntil()[135] ~= nil, true)
    -- Dia III replaces it: the tier check in the spell script, and only Dia III
    -- (tier 5) outranks a standing Bio II (tier 4)
    send028({ actor = MOB + 110, category = 4, param = 25,
              targets = { { id = PET + 110, actions = { { message = 2, param = 41 } } } } })
    check('pet dia from the cast', api.petLive(134), true)
    check('pet dia deletes bio', api.petLive(135), false)
    advance(151)
    check('pet dia gone at its own duration', api.petLive(134), false)
    -- "has no effect" puts nothing on it
    send028({ actor = MOB + 110, category = 4, param = 231,
              targets = { { id = PET + 110, actions = { { message = 75, param = 0 } } } } })
    check('pet refused dot records nothing', api.petLive(135), false)

    -- An expired tier must not go on refusing. Bio II lands and runs out on
    -- its own clock; a plain Dia after that meets a bare automaton, not a
    -- standing Bio II. The tier behind the opposite effect used to be read
    -- whatever that effect's clock said, so every Dia after an expired Bio II
    -- was refused and the Dia the automaton really carried went unrecorded.
    -- The same after an explicit wear-off, and after a lifecycle clear.
    local function bio2(pet) send028({ actor = MOB + 110, category = 4, param = 231,
        targets = { { id = pet, actions = { { message = 2, param = 34 } } } } }) end
    local function dia1(pet) send028({ actor = MOB + 110, category = 4, param = 23,
        targets = { { id = pet, actions = { { message = 2, param = 27 } } } } }) end
    bio2(PET + 110)
    check('bio ii lands again', api.petLive(135), true)
    advance(151)
    check('...and runs out on its clock', api.petLive(135), false)
    dia1(PET + 110)
    check('a Dia after the Bio expired is recorded', api.petLive(134), true)
    -- explicit wear-off: Bio II displaces that Dia, is announced gone, and
    -- the next Dia lands
    bio2(PET + 110)
    check('bio ii displaces the dia', api.petLive(134), false)
    send029(PET + 110, PET + 110, 135, 206)
    check('bio ii wears off', api.petLive(135), false)
    dia1(PET + 110)
    check('a Dia after the wear-off is recorded', api.petLive(134), true)
    -- lifecycle clear: the automaton is dismissed and another comes out (the
    -- same id, as the game reuses it), carrying nothing
    bio2(PET + 110)
    check('bio ii on the old automaton', api.petLive(135), true)
    petIn()
    check('the dismissal clears it', api.petLive(135), false)
    petOut(PET + 110, MOB + 110)
    dia1(PET + 110)
    check('a Dia on the new automaton is recorded', api.petLive(134), true)

    -- The same family on the automaton: a stronger tier replaces, a weaker or
    -- equal one is refused and leaves the clock alone (overwrite HIGHER), and
    -- once the standing one has run out a weaker cast lands afresh.
    local function dia2(pet) send028({ actor = MOB + 110, category = 4, param = 24,
        targets = { { id = pet, actions = { { message = 2, param = 60 } } } } }) end
    local function bio1(pet) send028({ actor = MOB + 110, category = 4, param = 230,
        targets = { { id = pet, actions = { { message = 2, param = 20 } } } } }) end
    dia2(PET + 110)                        -- over the live Dia I: stronger, replaces
    local until0 = api.petUntil()[134]
    check('Dia II replaces the Dia I', until0 ~= nil and until0 > fakeClock + 100, true)
    dia1(PET + 110)                        -- weaker into Dia II: refused
    check('a weaker Dia leaves Dia II its clock', api.petUntil()[134], until0)
    bio1(PET + 110)                        -- Bio I against the standing Dia II
    check('a Bio I cannot take the automaton from Dia II', api.petLive(134), true)
    check('...and records no Bio', api.petLive(135), false)
    dia2(PET + 110)                        -- equal: refused, no fresh clock
    check('a Dia II into a live Dia II keeps the first clock', api.petUntil()[134], until0)
    advance(121)
    check('Dia II runs out', api.petLive(134), false)
    dia1(PET + 110)
    check('a Dia after it is recorded afresh', api.petLive(134), true)
    -- a hit with "Additional effect: Poison" in the tail
    send028({ actor = MOB + 110, category = 1, param = 0,
              targets = { { id = PET + 110, actions = { { message = 1, param = 12,
                                                          add = { message = 160, param = 3 } } } } } })
    check('pet add-effect poison', api.petLive(3), true)
    check('pet add-effect has no clock', api.petUntil()[3], nil)
    send029(PET + 110, PET + 110, 3, 206)
    check('pet add-effect wears off', api.petLive(3), false)
    -- Poison Sting, mob skill 351: the damage message, the status from a
    -- separate call in the script, 60 s
    check('pet skill table knows poison sting', api.mobskillEffect(351)[1][1], 3)
    send028({ actor = MOB + 110, category = 11, param = 351,
              targets = { { id = PET + 110, actions = { { message = 185, param = 40 } } } } })
    check('pet silent skill poison', api.petLive(3), true)
    check('pet silent skill clock is the script duration', math.floor(api.petUntil()[3] - fakeClock), 60)
    advance(61)
    check('pet silent skill clears itself', api.petLive(3), false)
    -- a miss puts nothing on it
    send028({ actor = MOB + 110, category = 11, param = 351,
              targets = { { id = PET + 110, actions = { { message = 188, param = 0 } } } } })
    check('pet missed skill records nothing', api.petLive(3), false)
    -- the automaton strikes a mob's paralysis spikes: its own action's tail
    send028({ actor = PET + 110, category = 1, param = 0,
              targets = { { id = MOB + 110, actions = { { message = 1, param = 20,
                                                          spike = { message = 374, param = 4 } } } } } })
    check('pet spikes land on the actor', api.petLive(4), true)
    -- ...and a player's hit with an additional effect lands it on the MOB
    send028({ actor = OTHER, category = 1, param = 0,
              targets = { { id = MOB + 110, actions = { { message = 1, param = 20,
                                                          add = { message = 160, param = 3 } } } } } })
    check('mob add-effect poison', api.mobs()[MOB + 110].fx[3] ~= nil, true)
    check('mob add-effect has no spell', api.mobs()[MOB + 110].fx[3].spell, nil)
    -- the strip: buffs on the left, debuffs on the right, each oldest first
    api.forgetPet()
    send028({ actor = PET + 110, category = 4, param = 47,
              targets = { { id = PET + 110, actions = { { message = 230, param = 40 } } } } })
    advance(1)
    send028({ actor = MOB + 110, category = 4, param = 220,
              targets = { { id = PET + 110, actions = { { message = 236, param = 3 } } } } })
    advance(1)
    send028({ actor = PET + 110, category = 4, param = 52,
              targets = { { id = PET + 110, actions = { { message = 230, param = 41 } } } } })
    local buffs, debuffs = api.petStrip()
    check('strip two buffs', #buffs, 2)
    check('strip buffs oldest first', buffs[1].id * 1000 + buffs[2].id, 40041)
    check('strip one debuff', #debuffs, 1)
    check('strip the debuff is the poison', debuffs[1].id, 3)
    frame('strip draws both halves')
    -- the stub has no icon textures, so each effect draws the '?' fallback
    check('strip drew three effects', (function()
        local n = 0
        for _, d in ipairs(drawn) do if d:sub(1, 4) == 'IMG:' or d == '?' then n = n + 1 end end
        return n
    end)() >= 3, true)
    api.forgetPet()
    api.setPetTarget(0)
end

-- ------------- ...and only from the automaton's OWN landings, on ONE mob --
-- The reading is landing -> wear-off on the same mob, and the landing has to
-- be the automaton's. A dead mob's timestamp used to outlive it (keyed by the
-- effect alone), so the next mob's wear-off was measured from the wrong
-- landing; and any caster's wear-off trained the automaton's clock.
do
    local OTHER = 0x01000009
    petOut(PET + 96, MOB + 96)
    send044({ head = 5, frame = 35, magic = 250, hp = 600, maxhp = 600, mp = 300, maxmp = 300 })
    send028(act(8, 56, MOB + 96))                    -- establish the target
    local before = #(api.seenDur()[59] or {})
    -- 1. the automaton silences A; A dies with it up; a stranger silences B;
    --    the automaton is Deployed onto B; B's Silence wears off: NO reading
    send028(act(4, 59, MOB + 96, 236, 6))
    advance(30)
    send029(OTHER, MOB + 96, 0, 6)                   -- A dies
    send028({ actor = OTHER, category = 4, param = 59,
              targets = { { id = MOB + 97, actions = { { message = 236, param = 6 } } } } })
    send028(act(8, 56, MOB + 97))                    -- Deployed onto B
    advance(40)
    send029(MOB + 97, MOB + 97, 6, 206)
    check('learn no reading off a stranger', #(api.seenDur()[59] or {}), before)
    check('learn wear-off still clears', api.targetHas(6), false)
    -- 2. the automaton's Paralyze, then a stronger caster's on top: the
    --    wear-off that follows is theirs
    send028(act(4, 58, MOB + 97, 236, 4))
    advance(10)
    send028({ actor = OTHER, category = 4, param = 58,
              targets = { { id = MOB + 97, actions = { { message = 236, param = 4 } } } } })
    check('learn replacement takes the provenance', api.mobs()[MOB + 97].fx[4].who, 'other')
    advance(100)
    send029(MOB + 97, MOB + 97, 4, 206)
    check('learn no reading after a replacement', api.seenDur()[58], nil)
    -- 3. the automaton's own Blind on its own mob IS a reading, from THAT landing
    send028(act(4, 254, MOB + 97, 236, 5))
    advance(91)
    send029(MOB + 97, MOB + 97, 5, 206)
    local s = api.seenDur()[254]
    check('learn own landing is a reading', s ~= nil and #s or 0, 1)
    check('learn reading is this mob\'s run', s and math.floor(s[1]) or -1, 91)
    -- 4. a Dia/Bio cast never saw a landing, so its wear-off is no reading
    send028(act(4, 231, MOB + 97, 2, 34))
    advance(60)
    send029(MOB + 97, MOB + 97, 135, 206)
    check('learn no reading off a dot', api.seenDur()[231], nil)
    check('learn dot wear-off still clears', api.targetHas(135), false)
end

-- --------------- a hedge that loses to the thing it hedged against is a HIT --
-- The line said the window might go to a Regen instead, and it did. Counting
-- that as a mispredict overstates the error and buries the real ones: the
-- Regen coin-flip is most of what the anomaly line would otherwise shout about,
-- and it is the one part of the ladder the client can never resolve - enmity
-- is not readable. The record keeps `expected` and gains `hedged`, so the rate
-- is still measurable either way; only the alarm goes quiet.
do
    local SELF = 0x01000001
    local function said(text)
        for _, p in ipairs(printed) do if p:find(text, 1, true) then return true end end
        return false
    end
    world.hp, world.maxhp, world.petHpp, world.petMpp = 1000, 1000, 100, 100
    world.buffer = { 5, 35, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }
    world.icons, world.timers = { 42 }, { 0 }        -- the master holds a Regen
    advance(10)
    petOut(PET + 97, MOB + 97)
    api.setPetTarget(MOB + 97)
    send044({ head = 5, frame = 35, magic = 250, hp = 600, maxhp = 600, mp = 300, maxmp = 300 })
    -- the server last chose the automaton for a Regen, so hate is contested
    send028(act(4, 110, PET + 97))
    advance(25)
    handlers['d3d_present']()
    local name, why = api.predictSpell()
    check('hedged pick is the buff', name, 'Protect IV')
    check('hedged pick says a Regen may take it', (why or ''):find('or a Regen', 1, true) ~= nil, true)
    -- ...and a Regen takes it, exactly as the line warned
    while #printed > 0 do table.remove(printed) end
    send028(act(8, 110, SELF))
    local last = CLOCKWORK_TEST.last
    check('hedged loss is not an anomaly', last.kind, 'pet_spell')
    check('hedged loss is marked in the record', last.rec.hedged, true)
    check('hedged loss keeps what was expected', last.rec.expected, 'Protect IV')
    check('hedged loss says hedged in chat', said('Regen II as hedged'), true)
    check('hedged loss raises no alarm', said('ANOMALY'), false)
    -- but the hedge excuses ONLY a Regen: anything else is still an anomaly
    advance(25)
    handlers['d3d_present']()
    send028(act(8, 45, SELF))
    check('hedged excuses only the Regen', CLOCKWORK_TEST.last.kind, 'spell_mispredicted')
    -- and with NOTHING hedged - both sides holding a Regen, so the rung never
    -- raised the question - a Regen taking the window is a plain miss again
    send028({ actor = MOB + 97, category = 4, param = 110,
              targets = { { id = PET + 97, actions = { { message = 230, param = 42 } } } } })
    advance(25)
    handlers['d3d_present']()
    local _, w2 = api.predictSpell()
    check('unhedged pick is silent about a Regen', (w2 or ''):find('or a Regen', 1, true), nil)
    send028(act(8, 111, SELF))
    check('unhedged loss is still an anomaly', CLOCKWORK_TEST.last.kind, 'spell_mispredicted')
end
