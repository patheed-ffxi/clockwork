-- -------------------------------------------------------------- live set --
-- Before any 0x044: the equipped row falls back to the client buffer (the
-- harness's world.buffer), flagged. After one it is equippedSet(), unflagged
-- - checked in the capture block below.
do
    local s = api.liveSet()
    check('live from buffer head', s and s.head, 'Valoredge Head')
    check('live from buffer count', s and #s.attachments, 5)
    check('live from buffer flag', s and s.fromBuffer, true)
end

-- ------------------------------------------------------- 0x044 parsing --
do
    local before = api.state().seq
    send044({ head = 2, frame = 33, attachments = { 5, 4, 1, 2, 3 },
              heads = 2 ^ 2 + 2 ^ 1, frames = 2 ^ 1 + 2 ^ 0, owned = { 1, 2, 3, 4, 5, 98 } })
    local st = api.state()
    check('044 head', st.auto044.head, 2)
    check('044 frame', st.auto044.frame, 33)
    check('044 slot 1', st.auto044.attachments[1], 5)
    check('044 slot 5', st.auto044.attachments[5], 3)
    check('044 slot 6 empty', st.auto044.attachments[6], 0)
    check('044 twelve slots', #st.auto044.attachments, 12)
    check('044 heads mask', st.auto044.heads, 6)
    check('044 frames mask', st.auto044.frames, 3)
    check('044 seq bumps', st.seq, before + 1)
    send044({ head = 2, frame = 33 })
    check('044 seq bumps again', api.state().seq, before + 2)
end

-- ------------------------------------------------------- set file format --
do
    local set = { head = 'Valoredge Head', frame = 'Valoredge Frame',
                  attachments = { 'Attuner', 'Strobe', 'Armor Plate' } }
    local text = api.serializeSet(set)
    check('serialize head first', text:match('^Valoredge Head\n') ~= nil, true)
    check('serialize lines', select(2, text:gsub('\n', '')), 5)
    local back = api.parseSetFile(text)
    check('roundtrip head', back.head, 'Valoredge Head')
    check('roundtrip frame', back.frame, 'Valoredge Frame')
    check('roundtrip count', #back.attachments, 3)
    check('roundtrip order', back.attachments[3], 'Armor Plate')

    -- pupsets writes a line per slot, blanks for empty ones, CRLF or LF
    local pup = 'Valoredge Head\r\nValoredge Frame\r\nArmor Plate\r\n\r\nHeatsink\r\n\r\n\r\n'
    local p = api.parseSetFile(pup)
    check('pupsets blanks skipped', #p.attachments, 2)
    check('pupsets crlf trimmed', p.attachments[2], 'Heatsink')

    local bad, err = api.parseSetFile('Valoredge Head\n')
    check('missing frame rejected', bad, nil)
    check('missing frame reason', err ~= nil, true)
    local many = { 'Valoredge Head', 'Valoredge Frame' }
    for i = 1, 13 do many[#many + 1] = 'Strobe' end
    check('13 attachments rejected', (api.parseSetFile(table.concat(many, '\n'))), nil)

    check('name ok', api.validSetName('VE tank-2_b'), true)
    check('name trims', api.validSetName('  tank  '), true)
    check('name empty', api.validSetName(''), false)
    check('name spaces only', api.validSetName('   '), false)
    check('name slash', api.validSetName('a/b'), false)
    check('name dot', api.validSetName('a.txt'), false)
    check('name long', api.validSetName(string.rep('a', 41)), false)
end

-- ------------------------------------------------------------- set store --
do
    handlers['load']()   -- creates the sets folder
    check('store empty', #api.listSets(), 0)
    local set = { head = 'Valoredge Head', frame = 'Valoredge Frame', attachments = { 'Attuner', 'Strobe' } }
    check('save', (api.saveSet('VE tank', set)), true)
    check('save second', (api.saveSet('alpha', set)), true)
    local names = api.listSets()
    check('list count', #names, 2)
    check('list sorted', names[1], 'alpha')
    check('list name stripped', names[2], 'VE tank')
    check('exists', api.setExists('VE tank'), true)
    check('exists ci', api.setExists('ve TANK'), true)
    check('exists no', api.setExists('nope'), false)
    local back = api.loadSet('VE tank')
    check('load head', back.head, 'Valoredge Head')
    check('load attachments', #back.attachments, 2)
    check('rename', api.renameSet('alpha', 'beta'), true)
    check('rename listed', api.listSets()[1], 'beta')
    check('delete', api.deleteSet('beta'), true)
    check('delete listed', #api.listSets(), 1)
    check('load missing', (api.loadSet('beta')), nil)
end

-- -------------------------------------------------------------- capacity --
do
    local h = api.elementCaps(33)              -- Valoredge Frame, item_puppet 590562084
    check('VE frame Fire', h.Fire, 4)
    check('VE frame Dark', h.Dark, 2)
    local hq = api.elementCaps(32)             -- Harlequin Frame, 0x33333333
    check('HQ frame all 3', hq.Fire + hq.Ice + hq.Wind + hq.Earth + hq.Thunder + hq.Water + hq.Light + hq.Dark, 24)
    check('unknown id zero', api.elementCaps(99).Fire, 0)

    -- A Valoredge tank build that fills Fire exactly: 2+2+1+1+1 against 3+4.
    local set = { head = 'Valoredge Head', frame = 'Valoredge Frame',
                  attachments = { 'Attuner', 'Tension Spring II', 'Strobe', 'Tension Spring', 'Inhibitor' } }
    local used, caps, fits = api.capacityOf(set)
    check('tank Fire cap', caps.Fire, 7)
    check('tank Fire used', used.Fire, 7)
    check('tank fits', fits, true)
    check('tank Ice unused', used.Ice, 0)
    set.attachments[#set.attachments + 1] = 'Flame Holder'   -- one more Fire
    local used2, _, fits2 = api.capacityOf(set)
    check('over Fire used', used2.Fire, 8)
    check('over does not fit', fits2, false)

    -- item_puppet.sql costs, at the two rows a name-keyed transcription got
    -- wrong: 8556 is armor_plate_iv but is labelled 'barrier_module' there,
    -- which used to cost Barrier Module Earth 5 and lose Armor Plate IV.
    local function cost(name, el)
        local u = api.capacityOf({ head = 'Valoredge Head', frame = 'Valoredge Frame',
                                   attachments = { name } })
        return u[el]
    end
    check('Barrier Module Earth 1', cost('Barrier Module', 'Earth'), 1)
    check('Armor Plate IV Earth 5', cost('Armor Plate IV', 'Earth'), 5)
    check('Tension Spring V Fire 5', cost('Tension Spring V', 'Fire'), 5)
    -- a head or frame is not an attachment: it gives capacity, never spends it
    check('head costs nothing', cost('Valoredge Head', 'Light'), 0)
    check('frame costs nothing', cost('Harlequin Frame', 'Dark'), 0)

    -- both tables are keyed by the client's resource name, and they must
    -- agree with each other: ATTACH_ELEM once said 'Ten. Spring V' while
    -- ATTACH_MODS said 'Tension Spring V', so the cost lookup missed and the
    -- attachment spent no Fire at all. The client's own resource data writes
    -- the name out in full.
    local el, _, eff = api.attachEffect('Tension Spring V', { Fire = 3 })
    check('Tension Spring V element', el, 'Fire')
    check('Tension Spring V effect', eff, 'ATT +27%  R.ATT +27%')
    local el4, _, eff4 = api.attachEffect('Armor Plate IV', { Earth = 3 })
    check('Armor Plate IV element', el4, 'Earth')
    check('Armor Plate IV effect', eff4, 'PDT -40%')

    local ids = api.itemIds()
    check('id head', ids.head['Valoredge Head'], 2)
    check('id frame', ids.frame['Harlequin Frame'], 32)
    check('id attachment', ids.attachment['Armor Plate'], 98)
    check('id unknown', ids.attachment['Nope'], nil)
end

-- ------------------------------------------------------------- ownership --
do
    local set = { head = 'Valoredge Head', frame = 'Valoredge Frame',
                  attachments = { 'Attuner', 'Strobe', 'Armor Plate' } }
    -- own head 2, frame 33 (bit 1), attachments 5 and 1 - not 98
    send044({ head = 2, frame = 33, heads = 2 ^ 2, frames = 2 ^ 1, owned = { 5, 1 } })
    local un = api.unownedIn(set)
    check('unowned count', #un, 1)
    check('unowned which', un[1], 'Armor Plate')

    send044({ head = 2, frame = 33, heads = 0, frames = 0, owned = { 5, 1, 98 } })
    un = api.unownedIn(set)
    check('unowned head+frame', #un, 2)
    check('unowned head', un[1], 'Valoredge Head')
    check('unowned frame', un[2], 'Valoredge Frame')

    -- Harlequin needs no bit (puppetutils setHead/setFrame exempt it)
    local hq = { head = 'Harlequin Head', frame = 'Harlequin Frame', attachments = {} }
    check('harlequin free', #api.unownedIn(hq), 0)

    -- an unknown name is reported as unowned rather than silently allowed
    local odd = { head = 'Valoredge Head', frame = 'Valoredge Frame', attachments = { 'Nope' } }
    send044({ head = 2, frame = 33, heads = 2 ^ 2, frames = 2 ^ 1, owned = {} })
    check('unknown name unowned', api.unownedIn(odd)[1], 'Nope')
end

-- ------------------------------------------------------ capture + effects --
do
    send044({ head = 2, frame = 33, attachments = { 5, 1, 98 }, heads = 2 ^ 2, frames = 2 ^ 1, owned = { 1, 5, 98 } })
    local set = api.equippedSet()
    check('capture head', set.head, 'Valoredge Head')
    check('capture frame', set.frame, 'Valoredge Frame')
    check('capture count', #set.attachments, 3)
    check('capture third', set.attachments[3], 'Armor Plate')
    check('live is the 0x044', api.liveSet().fromBuffer, nil)
    check('live head from 0x044', api.liveSet().head, 'Valoredge Head')
    send044({ head = 0, frame = 0 })   -- no automaton configured: nothing to capture
    check('capture nothing', api.equippedSet(), nil)

    -- effects come from the same summing the Status tab uses, on any list
    local zero = api.buffSummary({ 'Armor Plate', 'Armor Plate II' }, {}, nil)
    check('effects nonempty', #zero > 0, true)
    -- Strobe's enmity climbs with Fire maneuvers (10 at none, 40 at two).
    -- Not Armor Plate: its PDT is negative and falls, so > would fail.
    local live = api.buffSummary({ 'Strobe' }, { Fire = 2 }, nil)
    local base = api.buffSummary({ 'Strobe' }, {}, nil)
    check('effects scale with maneuvers', live[1][3] > base[1][3], true)
    check('effects empty list', #api.buffSummary({}, {}, nil), 0)
end

-- ------------ Optic Fiber's boost, and the stat a maneuver grants itself --
-- With Stabilizer II and one Optic Fiber on a level 75 PUP, each Thunder
-- maneuver is worth the BOOSTED attachment value, 6, plus the DEX the maneuver
-- grants on its own, +6, worth 3 more accuracy again (R.ACC steps with ACC:
-- the automaton's ranged branch reads Mod::ACC, not Mod::RACC); the addon
-- used to quote the raw table step of 5 and call that the whole answer. The
-- two are SEPARATE rows - one row, one source - so what is checked here is
-- the 6 and the 6, not a 9.
do
    local FIT = { 'Stabilizer II', 'Optic Fiber' }
    local function rowOf(rows, label)
        for _, m in ipairs(rows) do if m[1] == label then return m[3] end end
        return nil
    end
    -- Light alone moves no accuracy attachment, but it takes the boost from
    -- 10% to 20% and Stabilizer II's flat 10 with it: 11 -> 12.
    local light = api.buffSummary(FIT, { Light = 1 }, {})
    check('a Light maneuver is worth a point of ACC', rowOf(light, 'ACC'), 1)
    check('and states the CHR it grants', rowOf(light, 'CHR'), 6)
    -- The first Thunder over that Light: 15 boosted is 18, up from 12.
    local t1 = api.buffSummary(FIT, { Light = 1, Thunder = 1 }, { Light = 1 })
    check('the first Thunder is worth 6 ACC, not 5', rowOf(t1, 'ACC'), 6)
    check('and states its DEX beside it', rowOf(t1, 'DEX'), 6)
    -- The DEX is NOT added into the accuracy: two sources, two rows. Folding
    -- them (1.14.0) printed ACC +9 next to DEX +6, which reads as the DEX being
    -- three more accuracy still to come.
    check('the DEX is not folded into the ACC', rowOf(t1, 'ACC') ~= 9, true)
    -- The second: 18 -> 24.
    check('the second Thunder is another 6',
          rowOf(api.buffSummary(FIT, { Light = 1, Thunder = 2 }, { Light = 1, Thunder = 1 }), 'ACC'), 6)
    -- Same maneuver with no Optic Fiber on: the raw table step.
    check('unboosted it is the table 5',
          rowOf(api.buffSummary({ 'Stabilizer II' }, { Thunder = 1 }, {}), 'ACC'), 5)
    -- The maneuvers' own stats do not need an attachment to show up at all,
    -- and they arrive as the stat alone.
    local wind = api.buffSummary({}, { Wind = 1 }, {})
    check('Wind states its AGI', rowOf(wind, 'AGI'), 6)
    check('and derives no ranged accuracy from it', rowOf(wind, 'R.ACC'), nil)
    check('and no evasion', rowOf(wind, 'EVA'), nil)
    local fire = api.buffSummary({}, { Fire = 2 }, {})
    check('Fire states its STR', rowOf(fire, 'STR'), 12)
    check('and derives no attack', rowOf(fire, 'ATT'), nil)
    local earth = api.buffSummary({}, { Earth = 2 }, { Earth = 1 })
    check('Earth states its VIT', rowOf(earth, 'VIT'), 6)
    check('and derives no defence', rowOf(earth, 'DEF'), nil)
    -- Dark's effect script is empty - MANEUVER_STAT's Dark = MP is the burden
    -- check's stat, not something the automaton is given.
    check('a Dark maneuver grants nothing', #api.buffSummary({}, { Dark = 2 }, {}), 0)
    -- A row LSB does not flag stays raw: Tactical Processor is Ice, 70 at one
    -- Ice maneuver, and 84 if the boost had been let near it.
    local _, _, flat = api.attachEffect('Tactical Processor', { Ice = 1, Light = 1 },
                                        { 'Tactical Processor', 'Optic Fiber' })
    check('the boost leaves an unflagged row alone', flat, 'Decision delay -0.70s')
    local _, _, lifted = api.attachEffect('Stabilizer II', { Thunder = 1, Light = 1 }, FIT)
    check('and lifts a flagged one', lifted, 'ACC +18')
end

-- --------------------------------------------------------------- planner --
do
    -- server: VE head/frame, slots: Attuner(5) Strobe(1) Armor Plate(98)
    local cur = { head = 2, frame = 33, attachments = { 5, 1, 98, 0, 0, 0, 0, 0, 0, 0, 0, 0 } }
    local function ops(steps) local o = {} for i, s in ipairs(steps) do o[i] = s.op end return table.concat(o, ' ') end

    -- same items, different order: nothing to do
    local same = { head = 'Valoredge Head', frame = 'Valoredge Frame', attachments = { 'Armor Plate', 'Attuner', 'Strobe' } }
    check('plan same empty', #api.planApply(cur, same, {}), 0)

    -- swap Armor Plate for Inhibitor: one removal then one add into the freed slot
    local swap = { head = 'Valoredge Head', frame = 'Valoredge Frame', attachments = { 'Attuner', 'Strobe', 'Inhibitor' } }
    local steps = api.planApply(cur, swap, {})
    check('plan swap ops', ops(steps), 'remove add')
    check('plan swap remove slot', steps[1].slot, 3)
    check('plan swap add slot', steps[2].slot, 3)
    check('plan swap add id', steps[2].id, 3)

    -- frame change + a removal: removal first, then frame, then add
    local hq = { head = 'Valoredge Head', frame = 'Harlequin Frame', attachments = { 'Attuner', 'Coiler' } }
    steps = api.planApply(cur, hq, {})
    check('plan order', ops(steps), 'remove remove frame add')
    check('plan frame id', steps[3].id, 32)
    check('plan add lowest free', steps[4].slot, 2)

    -- head change alone
    local head = { head = 'Sharpshot Head', frame = 'Valoredge Frame', attachments = { 'Attuner', 'Strobe', 'Armor Plate' } }
    steps = api.planApply(cur, head, {})
    check('plan head only', ops(steps), 'head')
    check('plan head id', steps[1].id, 3)

    -- skipped names are neither added nor counted, and each is named once;
    -- duplicates add once
    local skip = { head = 'Valoredge Head', frame = 'Valoredge Frame', attachments = { 'Attuner', 'Strobe', 'Armor Plate', 'Coiler', 'Coiler', 'Nope' } }
    local st, skipped = api.planApply(cur, skip, { Coiler = true })
    check('plan skip none added', #st, 0)
    check('plan skipped list', #skipped, 2)
    st = api.planApply(cur, skip, {})
    check('plan dup once', ops(st), 'add')

    -- empty automaton: everything is an add, slots 1..n
    local empty = { head = 2, frame = 33, attachments = { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 } }
    steps = api.planApply(empty, same, {})
    check('plan fill ops', ops(steps), 'add add add')
    check('plan fill slots', steps[1].slot * 100 + steps[2].slot * 10 + steps[3].slot, 123)
end

-- ----------------------------------------------------------------- apply --
-- The harness plays the server: after each equip call it updates its own
-- copy of the automaton (or refuses to), sends a 0x044, and resumes the task.
-- world.answered counts the equip calls answered so far, so each is answered
-- exactly once. (Comparing the call count with the step index cannot do
-- that: the two move in lockstep, so a pending call looks answered.)
do
    local server
    local function reset()
        server = { head = 2, frame = 33, attachments = { 5, 1, 98, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
                   heads = 2 ^ 2 + 2 ^ 3, frames = 2 ^ 1 + 2 ^ 0, owned = { 1, 2, 3, 4, 5, 7, 98, 204 } }
        world.equipCalls, world.task, world.answered, world.sleeps = {}, nil, 0, {}
        world.petIndex, world.petId, world.equipRc, world.refuseFirst = 0, 0, nil, nil
        world.equipThrow = nil
        send044(server)
    end
    -- answer the latest equip call: apply it to the server copy unless
    -- refuse is set, then send the 0x044 either way
    local function serverStep(refuse)
        local c = world.equipCalls[#world.equipCalls]
        if c ~= nil and not refuse then
            local index, id = c[3], c[4]
            if index == 0 then server.head = id
            elseif index == 1 then server.frame = id
            else server.attachments[index - 1] = id end
        end
        world.answered = #world.equipCalls
        send044(server)
    end
    local function pump(refuseAt, silentAt)
        -- resume until the task finishes, answering each new equip call once
        local n = 0
        while world.task ~= nil and coroutine.status(world.task) ~= 'dead' do
            assert(coroutine.resume(world.task))
            n = n + 1
            if n > 500 then error('apply did not finish') end
            local pending = #world.equipCalls
            if pending > world.answered then
                if world.equipCalls[pending].rc == 0 then
                    world.answered = pending           -- refused by the client: nothing reached the server
                elseif silentAt == pending then
                    world.answered = pending
                    advance(3.5)                       -- no 0x044 at all
                else
                    serverStep(refuseAt == pending)
                end
            end
            advance(0.1)
        end
    end

    local swap = { head = 'Valoredge Head', frame = 'Valoredge Frame', attachments = { 'Attuner', 'Strobe', 'Inhibitor' } }

    -- First of all, before anything binds the equip function: a client whose
    -- code the scan cannot find fails cleanly, and just as cleanly on the
    -- next Apply. The typedef was declared before the scan, so a failed scan
    -- left it declared with nothing bound, and the next attempt re-declared
    -- it - which LuaJIT refuses - and failed with a redefinition error.
    reset()
    world.signatureMissing = true
    api.startApply('swap', swap)
    pump()
    local a = api.state().apply
    check('a missing signature fails cleanly', a.failed ~= nil and a.failed:find('not found', 1, true) ~= nil, true)
    reset()
    api.startApply('swap', swap)
    pump()
    a = api.state().apply
    check('...and just as cleanly on the next Apply', a.failed ~= nil and a.failed:find('not found', 1, true) ~= nil, true)
    world.signatureMissing = nil

    -- success: Armor Plate -> Inhibitor, two steps, both confirmed
    reset()
    api.startApply('swap', swap)
    pump()
    local a = api.state().apply
    check('apply done', a.done, true)
    check('apply not failed', a.failed, nil)
    check('apply calls', #world.equipCalls, 2)
    check('apply call job', world.equipCalls[1][2], 0x1200)
    check('apply call main job flag', world.equipCalls[1][1], 0)
    check('apply remove index', world.equipCalls[1][3] * 100 + world.equipCalls[1][4], 400)   -- slot 3 -> index 4, id 0
    check('apply add index', world.equipCalls[2][3] * 100 + world.equipCalls[2][4], 403)      -- index 4, id 3
    check('apply status', a.status, 'done - 2 changes')
    check('apply no recast note', a.recast, false)
    check('server now has Inhibitor', server.attachments[3], 3)
    -- one second from a landed step to the next send, the pace Horizon's
    -- pupsets runs at - and nothing after the last step
    local gaps = 0
    for _, s in ipairs(world.sleeps) do if s == 1.0 then gaps = gaps + 1 end end
    check('apply paces a second between steps', gaps, 1)
    check('apply does not pause after the last step', world.sleeps[#world.sleeps], 0.1)

    -- nothing to do
    reset()
    api.startApply('same', { head = 'Valoredge Head', frame = 'Valoredge Frame', attachments = { 'Strobe', 'Attuner', 'Armor Plate' } })
    check('apply nothing status', api.state().apply.status, 'already equipped')
    check('apply nothing calls', #world.equipCalls, 0)

    -- refusal at step 2 stops there and reports
    reset()
    api.startApply('swap', swap)
    pump(2)
    a = api.state().apply
    check('refused done', a.done, true)
    check('refused failed', a.failed ~= nil, true)
    check('refused mentions step', a.failed:match('step 2') ~= nil, true)
    check('refused stopped', #world.equipCalls, 2)

    -- silence at step 1 times out and reports
    reset()
    api.startApply('swap', swap)
    pump(nil, 1)
    a = api.state().apply
    check('timeout failed', a.failed ~= nil, true)
    check('timeout mentions reply', a.failed:match('no reply') ~= nil, true)
    check('timeout stopped', #world.equipCalls, 1)

    -- an automaton appearing mid-sequence aborts before the next call
    reset()
    api.startApply('swap', swap)
    assert(coroutine.resume(world.task))          -- step 1 sent, waiting
    world.petIndex, world.petId = 5, 0x01000200
    serverStep()                                   -- step 1 confirmed
    pump()
    a = api.state().apply
    check('abort failed', a.failed ~= nil, true)
    check('abort mentions automaton', a.failed:match('automaton') ~= nil, true)
    check('abort stopped', #world.equipCalls, 1)

    -- zoning mid-sequence aborts before the next call
    reset()
    api.startApply('swap', swap)
    assert(coroutine.resume(world.task))          -- step 1 sent, waiting
    handlers['packet_in']({ id = 0x00A, injected = false, data = '' })
    serverStep()                                   -- step 1 confirmed
    pump()
    a = api.state().apply
    check('zone failed', a.failed ~= nil, true)
    check('zone mentions zoning', a.failed:match('zoned') ~= nil, true)
    check('zone stopped', #world.equipCalls, 1)

    -- the client's own function refusing (it returns 0) fails at once, no wait
    reset()
    world.equipRc = 0
    api.startApply('swap', swap)
    pump()
    a = api.state().apply
    check('client refused failed', a.failed ~= nil, true)
    check('client refused named', a.failed:match('client refused') ~= nil, true)
    check('client refused retried', #world.equipCalls, 8)

    -- a refusal that clears after two tries goes through
    reset()
    world.refuseFirst = 2
    api.startApply('swap', swap)
    pump()
    a = api.state().apply
    check('transient refusal done', a.done and a.failed == nil, true)
    check('transient refusal calls', #world.equipCalls, 4)
    check('transient refusal status', a.status, 'done - 2 changes')

    -- head change sets the recast note; sub-job flag follows the live job
    reset()
    world.mainjob, world.subjob = 1, 18
    api.startApply('head', { head = 'Sharpshot Head', frame = 'Valoredge Frame', attachments = { 'Attuner', 'Strobe', 'Armor Plate' } })
    pump()
    a = api.state().apply
    check('head done', a.done and a.failed == nil, true)
    check('head recast note', a.recast, true)
    check('head sub flag', world.equipCalls[1][1], 1)
    check('head index', world.equipCalls[1][3], 0)
    world.mainjob, world.subjob = 18, 0

    -- An unrelated 0x044 between the send and its reply is not a refusal.
    -- LSB's PostTick sends one on every master effect change
    -- (charentity.cpp:1110), so a buff wearing off mid-apply used to exit the
    -- wait loop on a pre-equip snapshot and report "server refused step 1" -
    -- and then the equip landed anyway. The wait is for the step to LAND now,
    -- not for the next packet of any kind.
    reset()
    api.startApply('swap', swap)
    assert(coroutine.resume(world.task))          -- step 1 sent, waiting
    send044(server)                               -- the server copy, unchanged
    advance(0.2)
    assert(coroutine.resume(world.task))
    check('an unrelated 044 is not a refusal', api.state().apply.failed, nil)
    serverStep()                                  -- ...and now the real reply
    pump()
    a = api.state().apply
    check('the step lands after an unrelated 044', a.done and a.failed == nil, true)
    check('and the sequence finishes', #world.equipCalls, 2)

    -- The pet / job / zone guards run between STEPS, but the client-refusal
    -- retry loop can hold one step for two seconds - long enough to zone in.
    reset()
    world.equipRc = 0                             -- the client refuses every time
    api.startApply('swap', swap)
    assert(coroutine.resume(world.task))          -- attempt 1 refused, sleeping
    handlers['packet_in']({ id = 0x00A, injected = false, data = '' })
    pump()
    a = api.state().apply
    check('zoning inside the retry loop stops it', a.failed ~= nil, true)
    check('zoning inside the retry loop is named', a.failed:match('zoned') ~= nil, true)
    check('zoning inside the retry loop stops retrying', #world.equipCalls, 1)
    world.equipRc = nil

    -- Any Lua error inside the task body still finishes it. Without a
    -- finaliser st.done stayed false and `busy` disabled Apply for the rest
    -- of the session.
    reset()
    world.equipThrow = true
    api.startApply('swap', swap)
    pump()
    a = api.state().apply
    check('a crashed apply is done', a.done, true)
    check('a crashed apply failed', a.failed ~= nil, true)
    check('a crashed apply says what happened', a.failed:match('equipex blew up') ~= nil, true)
    check('a crashed apply sent nothing', #world.equipCalls, 0)

    -- unowned attachment is skipped and named
    reset()
    api.startApply('unowned', { head = 'Valoredge Head', frame = 'Valoredge Frame', attachments = { 'Attuner', 'Strobe', 'Armor Plate', 'Amplifier' } })
    a = api.state().apply
    check('skipped status', a.status, 'already equipped, 1 skipped')
    check('skipped named', a.skipped[1], 'Amplifier')
end
