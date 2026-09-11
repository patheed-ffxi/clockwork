-- ----------------------------------------------------- timer cells, tuning --
-- One line of cells on Status for the equipped abilities; Tuning lists each
-- timer seen against its model. Entering: Valoredge, Strobe, Tactical
-- Processor worn; Provoke used 12 s ago.
do
    world.buffer = { 2, 33, 1, 213, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }
    advance(2.5)
    petOut(PET + 2)
    -- the buffer alone does not make the frame Valoredge: timerRows prefers the
    -- server's answer, and the block above leaves auto044 on Sharpshot, where
    -- Shield Bash has no cell at all. Say it on the packet the addon trusts.
    send044({ head = 2, frame = 33 })
    send028(act(11, 1945))
    advance(12)
    frame('timer cells')
    check('cell provoke label', sawExact('Provoke'), true)
    check('cell provoke left', sawExact('18s'), true)
    check('cell bash ready after edge', sawExact('ready'), true)
    check('cell flash absent', sawExact('Flash'), false)
    -- the column beside the table holds as many cells as it has lines and
    -- hands the rest to the footer, in order
    -- The recast cells sit right of the maneuver table WHATEVER its height.
    -- Capped to the table's rows they moved between the column and the footer
    -- as maneuvers came and went, which is the shifting 1.12.6 had.
    -- Only the deltas spill.
    local rows = api.timerRows()
    check('the column keeps every recast', #api.sideColumn(1, {}), 0)
    check('the column spills only the deltas',
          #api.sideColumn(1, { { 'ATT', '%', 16 } }), 2)
    -- All the deltas or none: room for the label but not for what it labels is
    -- not room, and splitting them drew `gives` twice (1.12.7).
    check('the column takes the deltas when it has the room for all of them',
          #api.sideColumn(#rows + 2, { { 'ATT', '%', 16 } }), 0)
    check('and hands back the label with them when it has not',
          #api.sideColumn(#rows + 1, { { 'ATT', '%', 16 } }), 2)
    -- Every recast value at one x, whatever the ability is called: the labels
    -- differ in width (Provoke, Stoneskin, Bash) and a fixed SameLine after each
    -- one left the column ragged. At 7px a character the pad after a
    -- label is 4 + (the widest label - this one), so every cell ends level.
    world.textWidth = true
    drawn = {}
    api.sideColumn(#rows + 1, {})
    local widest, aligned = 0, (#rows > 1)
    for _, r in ipairs(rows) do
        local w = #r.label * 7
        if w > widest then widest = w end
    end
    for _, r in ipairs(rows) do
        local want = 'SP:' .. tostring(4 + widest - #r.label * 7)
        local seen = false
        for _, d in ipairs(drawn) do if d == want then seen = true end end
        if not seen then aligned = false end
    end
    check('the recast values share one column', aligned, true)
    world.textWidth = nil
    -- fmtLeft's %d:%02d branch renders nowhere else in the suite, and '3:00' is
    -- exactly what a fresh Shield Bash recast reads
    send028(act(11, 1944))
    frame('timer cells minutes')
    check('cell bash minutes', sawExact('3:00'), true)
    -- the Tuning row needs a GAP, and noteUse records one only from the second
    -- use onward: the resummon above cleared the first
    advance(20)
    send028(act(11, 1945))
    frame('timer cells second')
    check('tuning provoke row', saw('model  30s'), true)
    advance(200)
    frame('timer cells long')
    -- the Bash cell already reads 'ready' in this frame, so sawExact('ready')
    -- could not fail here; assert Provoke's countdown is gone instead
    check('cell provoke ready', sawExact('30s'), false)
    api.timersClear(false)
    frame('timer cells unknown')
    -- petEffects is empty here, so petStatusStrip's own '?' fallback cannot
    -- satisfy this one
    check('cell unknown', sawExact('?'), true)
    -- the Tactical Processor's delay is in 10 ms units, and 'maneuvers give' is a
    -- DELTA over zero maneuvers: 115 - 50 = 65 -> -0.65 s (the per-attachment line
    -- shows the absolute -1.15 s)
    world.icons, world.timers = { 301, 301, 301 }, { 0, 0, 0 }
    frame('tactical processor')
    check('decision delay in seconds', saw('Decision delay -0.65s'), true)
    check('decision delay not raw', saw('-65s'), false)
    world.icons, world.timers = nil, nil
    send044({ head = 3, frame = 34 })   -- back to the state the block above left
    world.buffer = { 2, 33, 5, 4, 1, 2, 3, 0, 0, 0, 0, 0, 0, 0 }
    advance(2.5)
end

-- -------------------------------------------------------------- spell data --
-- CanUseSpell: the head bit and the magic skill, both off the 0x044; the
-- head falls back to the client buffer when no 0x044 has named one.
do
    send044({ head = 4, frame = 35, magic = 120 })   -- Stormwaker head and frame, skill 120
    check('head from 044', api.currentHead(), 4)
    check('spell name', api.spellName(59), 'Silence')
    check('spell unknown name', api.spellName(9999), 'spell 9999')
    check('cast silence', api.canCast(59), true)            -- skill 57, every caster head
    check('cast stoneskin', api.canCast(54), true)          -- skill 105, Stormwaker only
    check('cast cure iv skill short', api.canCast(4), false) -- skill 147
    send044({ head = 5, frame = 35, magic = 120 })
    check('cast stoneskin wrong head', api.canCast(54), false)
    check('cast erase soulsoother', api.canCast(143), true) -- skill 99, Soulsoother only
    send044({ head = 0, frame = 0, magic = 120 })             -- the server names no head: the buffer decides
    world.buffer = { 6, 35, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }
    advance(2.5)
    check('head from buffer', api.currentHead(), 6)
    check('cast on the buffer head', api.canCast(247), true)     -- Aspir, skill 78, Spiritreaver
    -- a 0x044 HAS been seen, so the skill still gates: parseJobExtra builds
    -- auto044 whatever the head byte says. The optimistic path is only for a
    -- session that has had no 0x044 at all.
    check('skill still gates', api.canCast(277), false)          -- Dread Spikes needs 256
    check('window spiritreaver enhance', api.spellWindows()[6].enhance, 135)
    check('window valoredge no enfeeble', api.spellWindows()[2].enfeeble, nil)
    check('erasable dia', api.erasable(134), true)
    check('erasable poison not', api.erasable(3), false)
    check('dispelable protect', api.dispelable(40), true)
    check('rung cure', api.spellRow(1).rung, 'heal')
    check('rung bio ii', api.spellRow(231).rung, 'enfeeble')
    check('rung poisona', api.spellRow(14).rung, 'status')
    check('removes poisona', api.spellRow(14).removes[1], 3)
    check('removes cure sleep', api.spellRow(1).removes[3], 2)
    world.buffer = { 2, 33, 5, 4, 1, 2, 3, 0, 0, 0, 0, 0, 0, 0 }
    advance(2.5)
end

-- ---------------------------------------------- windows and mob effects --
-- A cast start closes the global window and its rung's; a finish carries
-- the recast the server applied. What lands on the automaton's target is
-- kept, whoever cast it; resists leave nothing; a wear-off, a dispel, a new
-- target or the mob's death clears.
do
    world.buffer = { 4, 35, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }   -- Stormwaker head and frame
    advance(2.5)
    send044({ head = 4, frame = 35, magic = 120, hp = 500, maxhp = 500, mp = 300, maxmp = 300 })
    petOut(PET + 3)
    send028({ actor = PET + 3, category = 1, param = 0, targets = { { id = MOB, actions = { { message = 1, param = 12 } } } } })
    check('window open fresh', api.windowLeft('enfeeble'), 0)
    check('window never for this head', api.windowLeft('status'), nil)
    send028(act(8, 59))                                   -- Silence starts
    check('window enfeeble closed', math.floor(api.windowLeft('enfeeble')), 12)
    check('window magic closed', math.floor(api.windowLeft('magic')), 10)
    check('window heal untouched', api.windowLeft('heal'), 0)
    advance(4)
    send028(act(4, 59, MOB, 236, 6, 10))                  -- lands: the mob is silenced, recast 10 from the packet
    check('mob silenced', api.targetEffects()[6] ~= nil, true)
    check('spell recast from packet', api.spellRecastLeft(59), 10)
    advance(6)
    check('spell recast counting', api.spellRecastLeft(59), 4)
    send028(act(4, 58, MOB, 85, 0, 10))                   -- a resist leaves nothing
    check('mob not paralyzed', api.targetEffects()[4], nil)
    -- a buff landing on the mob from anyone is noted; a dispel clears it
    send028({ actor = MOB, category = 4, param = 43, targets = { { id = MOB, actions = { { message = 230, param = 40 } } } } })
    check('mob protect noted', api.targetEffects()[40] ~= nil, true)
    send028({ actor = PET + 3, category = 4, param = 260, targets = { { id = MOB, actions = { { message = 341, param = 40 } } } } })
    check('mob protect dispelled', api.targetEffects()[40], nil)
    -- a wear-off names the mob as the actor
    send029(MOB, MOB, 6, 206)
    check('mob silence wore off', api.targetEffects()[6], nil)
    -- a new target has unknown effects; the mob's death clears
    send028(act(4, 23, MOB, 2, 27))   -- a DoT reports DAMAGE, never a status
    check('mob dia noted', api.targetEffects()[134] ~= nil, true)
    send028({ actor = PET + 3, category = 1, param = 0, targets = { { id = MOB + 1, actions = { { message = 1, param = 12 } } } } })
    check('new target clears', api.targetEffects()[134], nil)
    send028(act(4, 23, MOB + 1, 2, 27))
    send029(PET + 3, MOB + 1, 0, 6)
    check('death clears', api.targetEffects()[134], nil)
    -- a Mana Booster at one Ice takes 4 off the magic window: attachMods indexes
    -- [n + 1], so one maneuver reads the table's SECOND value ({2,4,6,8} -> 4)
    world.buffer = { 4, 35, 212, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }
    world.icons, world.timers = { 301 }, { 0 }
    advance(2.5)
    send028(act(8, 23, MOB + 1))
    check('window magic less booster', math.floor(api.windowLeft('magic')), 6)
    world.icons, world.timers = nil, nil
end

-- ----------------------------------------------------------- the ladder --
-- TrySpellcast per head over what the client sees. Entering: Stormwaker
-- frame, Soulsoother head, magic 120, the automaton out and fighting
-- MOB + 2, the master at full HP with no effects, no maneuvers.
do
    local function predict() return api.predictSpell() end
    world.hp, world.maxhp, world.petHpp, world.petMpp = 1000, 1000, 100, 100
    world.icons, world.timers = nil, nil
    world.buffer = { 5, 35, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }
    advance(2.5)
    send044({ head = 5, frame = 35, magic = 120, hp = 600, maxhp = 600, mp = 300, maxmp = 300 })
    petOut(PET + 4, MOB + 2)   -- the entity table must carry THIS mob: the Stormwaker
                               -- low-HP branch below reads its HP% through it
    send028({ actor = PET + 4, category = 1, param = 0, targets = { { id = MOB + 2, actions = { { message = 1, param = 12 } } } } })
    -- nothing amiss: enhance, Regen on the master (hate decides who)
    local name, why, mode, rung = predict()
    check('ss regen', name, 'Regen')
    check('ss regen rung', rung, 'enhance')
    check('ss regen uncertain', mode, 'uncertain')
    -- the master has Regen: the automaton lacks it
    world.icons, world.timers = { 42 }, { 0 }
    name, why = predict()
    -- the master has Regen and the automaton does not, and this block has
    -- watched no Regen cast at all - so nothing says the automaton is not the
    -- target. The rung moves on to Protect, and says so, but flags that a
    -- Regen may take the window instead.
    check('ss regen automaton', why,
          'enhance · no Protect on you · or a Regen, if hate has moved back to the automaton')
    -- both have Regen: Protect on the master, the tier the skill allows
    send028({ actor = MOB + 2, category = 4, param = 108, targets = { { id = PET + 4, actions = { { message = 230, param = 42 } } } } })
    name, why = predict()
    check('ss protect', name, 'Protect II')
    check('ss protect why', why, 'enhance · no Protect on you')
    -- the master poisoned: status removal first
    world.icons, world.timers = { 42, 3 }, { 0, 0 }
    name, why, mode, rung = predict()
    check('ss poisona', name, 'Poisona')
    check('ss poisona rung', rung, 'status')
    -- Light up and the master at 35%: heal first; Cure IV needs 147
    world.icons, world.timers = { 42, 3, 306 }, { 0, 0, 0 }
    world.hp = 350
    name, why, mode = predict()
    check('ss cure', name, 'Cure III')
    check('ss cure why', why, 'heal · you at 35%')
    check('ss cure maneuver', mode, 'maneuver')
    -- the cure starts: the heal window shuts, status is next. The start also shuts
    -- the 4s magic window, so let that reopen before asking again.
    send028(act(8, 3))
    advance(4)
    name = predict()
    check('ss heal window shut', name, 'Poisona')
    -- both fully buffed, nothing to remove: enfeeble, Slow leads the list;
    -- Earth promotes it; the mob slowed and Wind up: Silence
    world.hp = 1000
    world.icons, world.timers = { 42, 40, 41, 33 }, { 0, 0, 0, 0 }
    for i, e in ipairs({ 40, 41, 33 }) do
        send028({ actor = MOB + 2, category = 4, param = 40 + i, targets = { { id = PET + 4, actions = { { message = 230, param = e } } } } })
    end
    advance(5)
    name, why, mode = predict()
    check('ss slow', name, 'Slow')
    check('ss slow default', mode, 'default')
    world.icons, world.timers = { 42, 40, 41, 33, 303 }, { 0, 0, 0, 0, 0 }
    name, why, mode = predict()
    check('ss slow promoted', mode, 'maneuver')
    send028(act(4, 56, MOB + 2, 236, 13))
    world.icons, world.timers = { 42, 40, 41, 33, 302 }, { 0, 0, 0, 0, 0 }
    name, why = predict()
    check('ss silence', name, 'Silence')
    check('ss silence why', why, 'enfeeble · Wind x1')
    -- the per-spell recast as the SOLE reason a spell is skipped. Message 85 is
    -- a resist, so nothing new lands on the mob and only the recast changes.
    -- Without this, deleting the spellRecastLeft term from usable() passes.
    send028(act(4, 59, MOB + 2, 85, 0, 30))
    name, why = predict()
    check('ss silence on recast', name, 'Poison')
    check('ss silence on recast why', why, 'enfeeble · list order')
    -- the Dia/Bio mutual block, which the design names and nothing exercised:
    -- LSB drops every Bio entry while the mob carries Dia and every Dia entry
    -- while it carries Bio. Blind the mob first so the Dark list's own Blind is
    -- skipped and the promotion reaches Bio II. These are explicit-actor
    -- packets, not act(), so no spell recast is stamped as a side effect, and
    -- each carries a distinct param so isDuplicate cannot swallow it.
    send028({ actor = MOB + 2, category = 4, param = 254,
              targets = { { id = MOB + 2, actions = { { message = 236, param = 5 } } } } })
    world.icons, world.timers = { 42, 40, 41, 33, 307 }, { 0, 0, 0, 0, 0 }
    name = predict()
    check('ss dark bio', name, 'Bio II')
    world.icons, world.timers = { 42, 40, 41, 33, 306 }, { 0, 0, 0, 0, 0 }
    name = predict()
    check('ss light dia', name, 'Dia II')
    -- Dia lands: every Bio entry goes, and the list falls through to Poison
    send028({ actor = MOB + 2, category = 4, param = 23,
              targets = { { id = MOB + 2, actions = { { message = 236, param = 134 } } } } })
    world.icons, world.timers = { 42, 40, 41, 33, 307 }, { 0, 0, 0, 0, 0 }
    name = predict()
    check('ss dia blocks bio', name, 'Poison')
    -- Dia wears off and Bio lands: now the Dia entries go instead. Both
    -- directions matter, because the row.enfeeble guard alone would explain a
    -- spell being skipped when the mob carries that spell's OWN effect.
    send028({ actor = MOB + 2, category = 4, param = 24,
              targets = { { id = MOB + 2, actions = { { message = 206, param = 134 } } } } })
    send028({ actor = MOB + 2, category = 4, param = 230,
              targets = { { id = MOB + 2, actions = { { message = 236, param = 135 } } } } })
    world.icons, world.timers = { 42, 40, 41, 33, 306 }, { 0, 0, 0, 0, 0 }
    name = predict()
    check('ss bio blocks dia', name, 'Poison')
    send028({ actor = MOB + 2, category = 4, param = 231,
              targets = { { id = MOB + 2, actions = { { message = 206, param = 135 } } } } })
    -- tryHeal's other two targets. world.petHpp is 100 everywhere else in the
    -- suite, so the automaton branch, ctx.petMissing and the heal rung's
    -- uncertain flag are otherwise never executed.
    advance(20)
    world.icons, world.timers = { 42, 40, 41, 33, 306 }, { 0, 0, 0, 0, 0 }
    world.hp, world.petHpp = 1000, 40
    name, why = predict()
    check('ss heal automaton', why, 'heal · automaton at 40%')
    check('ss heal automaton tier', name, 'Cure III')   -- 360 missing of 600
    world.hp = 350
    name, why, mode = predict()
    check('ss heal both', why, 'heal · you or automaton at 35%')
    check('ss heal both uncertain', mode, 'uncertain')
    -- the Cure tier edges the design names. maxhp is lowered so a small deficit
    -- is still under the threshold: at one Light that is 40%, and only a small
    -- maxhp puts 120 and 190 missing HP on the right side of it.
    world.maxhp, world.hp = 200, 80
    name = predict()
    check('ss cure tier 120', name, 'Cure')
    world.hp = 70
    name = predict()
    check('ss cure tier 130', name, 'Cure II')
    world.maxhp, world.hp = 300, 110
    name = predict()
    check('ss cure tier 190', name, 'Cure II')
    world.hp = 105
    name = predict()
    check('ss cure tier 195', name, 'Cure III')
    world.maxhp = 1000
    world.hp, world.petHpp = 1000, 100
    -- LSB's third heal target: Soulsoother + Light + a party (509-543). Enmity
    -- picks the member and a member's maximum HP is unreadable, so the pick is
    -- flagged; without the branch the ladder falls through and names Regen in
    -- plain text.
    world.party = { [2] = 40 }
    name, why, mode = predict()
    check('ss party heal', name, 'Cure')
    check('ss party uncertain', mode, 'uncertain')
    check('ss party why', why, 'heal · a party member at 40% (enmity picks who, and the tier)')
    world.party = nil
    -- tryStatus' automaton side and naFor's Erase fallback: nothing else routes
    -- an erasable effect to spell 143, and only the master side was reached.
    send028({ actor = MOB + 2, category = 4, param = 56, targets = { { id = PET + 4, actions = { { message = 236, param = 13 } } } } })
    name, why = predict()
    check('ss erase automaton', name, 'Erase')
    check('ss erase why', why, 'status · effect 13 on automaton')
    -- Damage Gauge feeds two DIFFERENT indices of one attachment's mod list -
    -- mods[1][3] is the heal threshold in gather, mods[2][3] the heal window in
    -- windowLeft - and neither was executed. At one Light: 40 + 40 = 80, so a
    -- master at 75% now heals where the bare 40 would not, and the window is
    -- 15 - 6 = 9.
    advance(20)
    world.buffer = { 5, 35, 211, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }
    advance(2.5)   -- equippedNames caches for 2s
    world.hp = 750
    name, why = predict()
    check('ss gauge threshold', why, 'heal · you at 75%')
    check('ss gauge tier', name, 'Cure III')
    send028(act(8, 1))   -- a Cure start: stamps the heal window, gauge applied
    check('ss gauge window', api.windowLeft('heal'), 9)
    world.buffer = { 5, 35, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }
    advance(2.5)
    world.hp = 1000
    advance(12)   -- every window this section stamped reopens before the next head
    -- Stormwaker: nukes, and Dispel alone in its enfeeble rung. Its magic window is
    -- 10s where Soulsoother's was 4, so the last cast start has to age out before
    -- the head changes or every prediction below reads 'closed'.
    advance(10)
    world.icons, world.timers = { 42, 40, 41, 33 }, { 0, 0, 0, 0 }
    send044({ head = 4, frame = 35, magic = 120, hp = 600, maxhp = 600, mp = 300, maxmp = 300 })
    name, why, mode, rung = predict()
    -- NOT Thunder: the tier walks down from 4 and takes the first CASTABLE spell in
    -- list order, and at magic 120 nothing above Stone II (skill 108) is castable -
    -- Water II is 123, Aero II 138, Thunder II 203. Thunder I only wins at tier 0,
    -- which needs the automaton under 16 MP.
    check('sw thunder', name, 'Stone II')
    check('sw thunder rung', rung, 'elemental')
    send028({ actor = MOB + 2, category = 4, param = 43, targets = { { id = MOB + 2, actions = { { message = 230, param = 40 } } } } })
    name = predict()
    check('sw dispel', name, 'Dispel')
    world.icons, world.timers = { 42, 40, 41, 33, 301 }, { 0, 0, 0, 0, 0 }   -- Ice: the nuke rung before enfeeble
    name = predict()
    check('sw ice nuke first', name, 'Stone II')
    -- the target at 25%: the low-HP nuke, both branches said
    world.mobHpp = 25
    world.icons, world.timers = { 42, 40, 41, 33 }, { 0, 0, 0, 0 }
    name, why, mode = predict()
    check('sw low nuke', name, 'Stone II')
    check('sw low uncertain', mode, 'uncertain')
    check('sw low why', why, 'nuke if the target is under 300 HP, else Dispel')
    -- The alternative is named by a second ladder walk, whose usable() calls
    -- reset the shared mpEdge flag: the real pick's reading has to survive it.
    -- Stone II is 16 MP and Dispel 25; at 8% of 300 the interval is [24, 26],
    -- so the nuke is plainly affordable and only Dispel sits on the edge -
    -- and the row used to come back mpUnsure from Dispel's answer.
    world.petMpp = 8
    local _, _, _, _, _, mpu = predict()
    check('sw low nuke keeps its own MP reading', mpu, nil)
    world.petMpp = 100
    world.mobHpp = nil
    -- Spiritreaver under 75% MP: Aspir
    send044({ head = 6, frame = 35, magic = 120, hp = 600, maxhp = 600, mp = 300, maxmp = 300 })
    world.petMpp = 50
    name, why, mode = predict()
    check('sr aspir', name, 'Aspir')
    check('sr aspir uncertain', mode, 'uncertain')
    world.petMpp = 100
    -- head 6's Dark arm - eleven spells and six promotions - was unreachable:
    -- no world.icons anywhere in the suite carried 307.
    world.icons, world.timers = { 307 }, { 0 }
    name = predict()
    check('sr dark list', name, 'Absorb-INT')
    -- with INT_BOOST already on the automaton the list walks on. The Blindness
    -- put on the mob back in the Dia/Bio section is only 67s old here and
    -- TARGET_EFFECT_AGE is 120, so it would still skip the Dark list's own
    -- Blind and hand back Bio II - wear it off first. (Param 255 rather than
    -- 254 so isDuplicate, which keys on the first 24 bytes, cannot swallow it
    -- as a resend of the packet that landed the effect.)
    send028({ actor = MOB + 2, category = 4, param = 255,
              targets = { { id = MOB + 2, actions = { { message = 206, param = 5 } } } } })
    send028({ actor = MOB + 2, category = 4, param = 270, targets = { { id = PET + 4, actions = { { message = 230, param = 84 } } } } })
    name = predict()
    check('sr dark int boost', name, 'Blind')
    -- two of an element promotes its spell over the list order
    world.icons, world.timers = { 307, 302, 302 }, { 0, 0, 0 }
    name, why = predict()
    check('sr dark promoted', name, 'Silence')
    check('sr dark promoted why', why, 'enfeeble · Wind x2')
    -- Dread Spikes needs magic 256; every other fixture sends 120, so head 6's
    -- whole enhance arm was dead
    world.icons, world.timers = { 307 }, { 0 }
    send044({ head = 6, frame = 35, magic = 260, hp = 600, maxhp = 600, mp = 300, maxmp = 300 })
    name, why, mode, rung = predict()
    check('sr dread spikes', name, 'Dread Spikes')
    check('sr dread spikes rung', rung, 'enhance')
    -- Scanner: LSB's resistance sort is unreadable AND exclusive with the
    -- Spiritreaver maneuver promotion, a branch no other assertion touches.
    send044({ head = 6, frame = 35, magic = 120, hp = 600, maxhp = 600, mp = 300, maxmp = 300 })
    world.buffer = { 6, 35, 210, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }
    advance(2.5)
    world.icons, world.timers = { 301 }, { 0 }   -- Ice: the nuke rung, and Scanner's element
    name, why, mode = predict()
    check('sr scanner why', why, 'nuke · Scanner picks by resistance')
    check('sr scanner uncertain', mode, 'uncertain')
    world.buffer = { 6, 35, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }
    advance(2.5)
    -- The Protect that 'sw dispel' put on the mob is still inside its 120s life,
    -- so head 4's enfeeble rung would keep offering Dispel ahead of the nuke
    -- the next fixture is about. Wear it off. (Param 44, not 43, for the
    -- isDuplicate reason above.)
    send028({ actor = MOB + 2, category = 4, param = 44,
              targets = { { id = MOB + 2, actions = { { message = 206, param = 40 } } } } })
    -- No 0x044 at all - a reload with the automaton already out. gather's MP
    -- is a placeholder then, and the nuke
    -- tier is built on it; without the flag the line names a top-tier nuke in
    -- plain text. The head still comes from the client buffer.
    api.clear044()
    world.buffer = { 4, 35, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }
    advance(2.5)
    world.icons, world.timers = nil, nil
    name, why, mode, rung = predict()
    check('no 044 nuke rung', rung, 'elemental')
    check('no 044 nuke uncertain', mode, 'uncertain')
    send044({ head = 4, frame = 35, magic = 120, hp = 600, maxhp = 600, mp = 300, maxmp = 300 })
    -- a Valoredge frame never casts; a closed magic window says how long.
    -- Said on the 0x044 as well as in the buffer: since 1.10.0 the ladder
    -- takes the frame from the server's packet first, the way timerRows and
    -- currentHead() already did, so the buffer alone no longer moves it.
    world.buffer = { 5, 33, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }
    advance(2.5)
    send044({ head = 5, frame = 33, magic = 120, hp = 600, maxhp = 600, mp = 300, maxmp = 300 })
    name, why, mode = predict()
    check('ve frame none', name, nil)
    check('ve frame mode', mode, 'none')
    world.buffer = { 5, 35, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }
    advance(2.5)
    send044({ head = 5, frame = 35, magic = 120, hp = 600, maxhp = 600, mp = 300, maxmp = 300 })
    send028(act(8, 56))
    name, why, mode = predict()
    check('window closed mode', mode, 'closed')
    -- prefixed since 1.6.7: spellLine draws this alone when there is no
    -- spell name, so it has to read as a statement rather than a fragment.
    -- Since 1.8.1 it also names what the wait is FOR - the ladder run again
    -- with the windows ignored - so the line answers when AND what.
    check('window closed why', why, 'none ready - magic window 4s -> then Erase')
    check('window closed names no spell', name, nil)
    world.icons, world.timers = nil, nil
    world.buffer = { 2, 33, 5, 4, 1, 2, 3, 0, 0, 0, 0, 0, 0, 0 }
    advance(2.5)
end

-- ----------------------------------------------- the spell line, logged --
-- The snapshot the last frame took is what a cast start is compared with:
-- a match logs pet_spell, anything else spell_mispredicted with both rungs.
do
    world.hp, world.maxhp, world.petHpp, world.petMpp = 1000, 1000, 100, 100
    world.icons, world.timers = nil, nil
    world.buffer = { 5, 35, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }
    advance(2.5)
    send044({ head = 5, frame = 35, magic = 120, hp = 600, maxhp = 600, mp = 300, maxmp = 300 })
    petOut(PET + 5, MOB + 3)
    send028({ actor = PET + 5, category = 1, param = 0, targets = { { id = MOB + 3, actions = { { message = 1, param = 12 } } } } })
    -- tm.casts / tm.missed are session-global and nothing else clears them:
    -- the blocks above started four casts of their own, so count
    -- only this block's two
    api.spellCountersReset()
    frame('spell line')
    check('spell line label', sawExact('Spell'), true)
    check('spell line uncertain regen', sawExact('Regen?'), true)
    check('spell line why', saw('no Regen on you'), true)
    -- the predicted cast: pet_spell
    send028(act(8, 108))
    check('pet_spell logged', (lastLog('pet_spell') or ''):find('"expected":"Regen"', 1, true) ~= nil, true)
    -- the enhance window shut by that cast, the snapshot moves to Slow; a
    -- Protect II instead is a mispredict, both rungs on record
    advance(5)
    frame('spell line after')
    check('spell line moved on', sawExact('Slow'), true)
    -- a different target, not because the target matters (category 8 is
    -- excluded from the petTarget update) but because isDuplicate keys on the
    -- first 24 bytes - actor / category / the 24931 FourCC / recast / target
    -- id / result count, every one of them shared with the act(8, 108) above -
    -- and its purge is `now - t > 5.0`, which the advance(5) meets exactly and
    -- so does not clear
    send028(act(8, 44, MOB + 4))
    local miss = lastLog('spell_mispredicted') or ''
    check('mispredict logged', miss:find('"name":"Protect II"', 1, true) ~= nil, true)
    check('mispredict rung', miss:find('"rung":"enhance"', 1, true) ~= nil, true)
    check('mispredict expected rung', miss:find('"expected_rung":"enfeeble"', 1, true) ~= nil, true)
    frame('spell counters')
    check('tuning spell counters', saw('spells 2, mispredicted 1'), true)
    -- a frame that never casts has no Spell line (on the packet, which is
    -- what the ladder reads first)
    world.buffer = { 5, 33, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }
    advance(2.5)
    send044({ head = 5, frame = 33, magic = 120, hp = 600, maxhp = 600, mp = 300, maxmp = 300 })
    frame('spell line valoredge')
    check('spell line absent', sawExact('Spell'), false)
    world.buffer = { 2, 33, 5, 4, 1, 2, 3, 0, 0, 0, 0, 0, 0, 0 }
    advance(2.5)
end

-- ---------------------------------------------------------- loadout log --
-- One `loadout` record per Activate, written on the render thread once the
-- server's 0x044 for the NEW automaton has arrived. Nothing else in the log
-- carries the head, the frame or the attachments, and the shot's recast model
-- and the whole spell ladder are derived from them.
do
    local SELF = 0x01000001               -- the harness's GetPlayerEntity ServerId
    world.buffer = { 5, 35, 1, 207, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }
    advance(2.5)
    petOut(PET + 9, MOB + 9)
    -- Activate. The arm only records where the 0x044 stream stood: auto044
    -- still describes the previous automaton, so nothing may be written yet.
    send028({ actor = SELF, category = 6, param = 136,
              targets = { { id = SELF, actions = { { message = 0 } } } } })
    CLOCKWORK_TEST.last = nil
    frame('loadout pending')
    check('loadout waits for 044', CLOCKWORK_TEST.last, nil)
    -- the server names the new automaton: now it writes
    send044({ head = 5, frame = 35, magic = 120, attachments = { 1, 207 } })
    frame('loadout written')
    check('loadout logged', CLOCKWORK_TEST.last.kind, 'loadout')
    check('loadout head', CLOCKWORK_TEST.last.rec.head, 'Soulsoother Head')
    check('loadout frame', CLOCKWORK_TEST.last.rec.frame, 'Stormwaker Frame')
    check('loadout attachments', CLOCKWORK_TEST.last.rec.attachments, 'Strobe, Drum Magazine')
    check('loadout count', CLOCKWORK_TEST.last.rec.count, 2)
    -- and only once per Activate, not once per frame
    CLOCKWORK_TEST.last = nil
    frame('loadout once')
    check('loadout not repeated', CLOCKWORK_TEST.last, nil)
end
