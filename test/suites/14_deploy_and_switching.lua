-- ------------------- a Deploy onto an untouched mob has no Regen target --
-- TryEnhance picks its Regen target by walking the mob's ENMITY LIST - the
-- master, then the automaton, then the party - and a mob nobody has touched
-- has an empty one. PRegenTarget stays null, so no Regen is cast at all,
-- whoever is or is not carrying one, and the rung starts at Protect.
-- isEngaged is a different test (a mob target, the master within 20 yalms)
-- and is still true, so the buffs themselves are unaffected.
-- The case: a Soulsoother head Deployed onto an unengaged mob. The rung must
-- start at Protect, not Regen.
do
    local SELF = 0x01000001
    world.hp, world.maxhp, world.petHpp, world.petMpp = 1000, 1000, 100, 100
    world.buffer = { 5, 35, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }
    world.icons, world.timers = nil, nil          -- the master carries nothing
    advance(10)
    petOut(PET + 20, MOB + 20)
    send044({ head = 5, frame = 35, magic = 250, hp = 600, maxhp = 600, mp = 300, maxmp = 300 })
    send028({ actor = SELF, category = 6, param = 136,
              targets = { { id = SELF, actions = { { message = 0 } } } } })   -- a fresh automaton
    api.setPetTarget(MOB + 19)                    -- ...still on the LAST mob
    advance(25)
    check('deploy nothing pending', api.deployTo(), nil)
    check('deploy regen before', (api.predictSpell()), 'Regen III')
    -- sent at a mob nobody has touched
    send028({ actor = SELF, category = 6, param = 138,
              targets = { { id = MOB + 20, actions = { { message = 0 } } } } })
    check('deploy noted', api.deployTo(), MOB + 20)
    local name, why = api.predictSpell()
    check('deploy suppresses the regen', name, 'Protect IV')
    check('deploy still engages', why, 'enhance · no Protect on you')
    -- ...and OUR first landing on it puts us on the list, so the Regen is back
    send028(act(4, 56, MOB + 20, 236, 13))
    check('deploy cleared by our action', api.deployTo(), nil)
    advance(25)
    check('deploy regen returns', (api.predictSpell()), 'Regen III')
    -- a STRANGER acting on it does not: the list TryEnhance reads is only
    -- ever searched for the master, the automaton and the party
    send028({ actor = SELF, category = 6, param = 138,
              targets = { { id = MOB + 21, actions = { { message = 0 } } } } })
    send028({ actor = MOB + 30, category = 4, param = 56,
              targets = { { id = MOB + 21, actions = { { message = 236, param = 13 } } } } })
    check('deploy survives a stranger', api.deployTo(), MOB + 21)
    -- and it belongs to this fight: timersClear takes it, which is what a
    -- zone, a despawn and a death all go through
    handlers['packet_in']({ id = 0x00A, injected = false, data = '' })
    check('deploy cleared with the fight', api.deployTo(), nil)
    -- with NO petTarget at all - the first Deploy after an Activate - the
    -- Deploy is still an engagement, so the master's arm of the ladder runs.
    -- LSB's isEngaged only asks for a mob target and the master in range.
    api.setPetTarget(0)
    send028({ actor = SELF, category = 6, param = 138,
              targets = { { id = MOB + 22, actions = { { message = 0 } } } } })
    advance(25)
    local n2, w2 = api.predictSpell()
    check('deploy alone is engagement', n2, 'Protect IV')
    check('deploy alone buffs the master', w2, 'enhance · no Protect on you')
    -- a Deploy that somehow named us or the automaton would never be cleared:
    -- the clear above skips both ids, so it would suppress the Regen for the
    -- rest of the fight. Only a mob is taken.
    handlers['packet_in']({ id = 0x00A, injected = false, data = '' })
    send028({ actor = SELF, category = 6, param = 138,
              targets = { { id = PET + 20, actions = { { message = 0 } } } } })
    check('deploy ignores a non-mob target', api.deployTo(), nil)
end

-- ------------------------------------- the compact strip's labels and icons --
-- The four bars are labelled - four unlabelled stripes meant the tooltip was
-- the only way to tell HP from MP - and each recast cell is the icon of the
-- item that grants the ability, not a coloured box in an order to memorise.
do
    world.buffer = { 2, 33, 1, 208, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }   -- Strobe, Flashbulb
    send044({ head = 2, frame = 33, attachments = { 1, 208 },
              heads = 2 ^ 1, frames = 2 ^ 1, owned = { 1, 208 } })
    api.config.compact = true
    world.iconsAvailable, world.pngAvailable = true, true
    api.resetIcons()   -- an earlier frame cached the misses from before the flags
    -- past the 2 s TTL on the equipped-name cache, so hasAttachment reads
    -- the buffer this block just set rather than the previous one
    advance(3)
    frame('compact labelled')
    check('the compact bars are labelled', saw('HP') and saw('MP') and saw('TP'), true)
    check('...including the target bar', saw('TGT'), true)
    -- The vitals are two columns of two - HP over MP, TP over TGT. Four
    -- stacked made a one-line strip four rows tall and four in a row made it
    -- half as wide again as everything else. The offsets are
    -- GROUP-relative, which is the part that broke twice: lblW is 20 from the
    -- stub, so the first column's bar is at 24, the second column starts at
    -- 20 + 4 + BAR_W(44) + gap(10) = 78, and its bar at 102. Two rows means
    -- each of those offsets is emitted exactly twice.
    check('column one, both rows', countExact('X:24'), 2)
    check('column two, both rows', countExact('X:78'), 2)
    check('...and its bars', countExact('X:102'), 2)
    check('the recast cells are icons', saw('IMG:'), true)
    -- and the row says what granted it, which is what the icon is of
    local seen = {}
    for _, r in ipairs(api.timerRows()) do seen[r.name] = r.grant end
    check('Provoke is granted by the Strobe', seen['Provoke'], 'Strobe')
    check('Flashbulb by its own attachment', seen['Flashbulb'], 'Flashbulb')
    check('Shield Bash by the frame', seen['Shield Bash'], 'Valoredge Frame')
    -- ...but the icon is of what the ability DOES, where the client has art for
    -- it. Shield Bash lands Stun, so the cell is the Stun icon rather than the
    -- frame's; Provoke lands nothing drawable and keeps its attachment.
    local art = {}
    for _, r in ipairs(api.timerRows()) do art[r.name] = api.abilityArt(r) end
    check('Shield Bash shows the Stun it lands', art['Shield Bash'], 'effect 10')
    check('Flashbulb shows Flash', art['Flashbulb'], 'effect 156')
    -- Provoke lands no effect and is a mobskill, so the client has no art for
    -- it at all; assets/abilities/provoke.png is shipped instead, and the
    -- attachment is only the fallback for when the file will not load.
    check('Provoke uses its shipped art', art['Provoke'], nil)
    -- ...and the file is the one shipped under assets/abilities
    check('...from assets/abilities', (world.lastPng or ''):find('abilities/provoke.png', 1, true) ~= nil, true)
    -- with the granting attachment as the fallback when it will not load
    world.pngAvailable = nil
    api.resetIcons()
    local art2 = {}
    for _, r in ipairs(api.timerRows()) do art2[r.name] = api.abilityArt(r) end
    check('no file: Provoke falls back to its attachment', art2['Provoke'], 'Strobe')
    world.pngAvailable = true
    api.resetIcons()
    -- no icon from the client: the cell falls back to the box rather than
    -- drawing nothing, so the strip still reads
    world.iconsAvailable, world.pngAvailable = nil, nil
    api.resetIcons()
    frame('compact without icons')
    check('no icon falls back to the box', saw('IMG:'), false)
    api.config.compact = false
    world.iconsAvailable, world.pngAvailable = true, true
    api.resetIcons()
    -- the Status page draws the same cell. There the seconds are printed
    -- BESIDE it, so the icon carries no overlay and the label stays.
    frame('status icons')
    check('the status recast cells are icons too', saw('IMG:'), true)
    check('...and keep their label', saw('Provoke'), true)
end
-- --------------------------------- reconcile grades the cost the panel shows --
-- config.stat_check pins a cost, and three contradictions freeze an observed
-- one; the panel predicts with that. reconcile() took its cost from the raw
-- stat comparison regardless, so a reading that agreed with the pin exactly
-- was graded +5 and logged burden_mismatch, every cast, with err_shown 0. Now
-- the pinned or taught cost is the model's; the raw comparison rides on the
-- record as raw_cost.
do
    local m, cfg = api.model(), api.config
    local was = cfg.stat_check
    petOut(PET + 300, MOB + 300)
    api.timersClear(false)
    send044({ head = 2, frame = 33, stats = { STR = 70 } })    -- the automaton's STR above the master's
    handlers['d3d_present']()
    cfg.stat_check = { Fire = 'win' }                           -- the player pins it: cost 15
    handlers['command']({ command = '/cw reset' })
    check('the pin is the stored cost', m.cost.Fire, 15)
    check('...as a set cost', m.costSource.Fire, 'set')
    api.reconcile('Fire', 35, false)                            -- a reading: burden 60, verified
    check('burden observed at 60', m.burden.Fire, 60)
    CLOCKWORK_TEST.last = nil
    api.reconcile('Fire', 60 + 15 - 30 + 5, false)              -- the server agrees with the pin
    local r = CLOCKWORK_TEST.last
    check('a reading that agrees with the pin is a plain maneuver', r.kind, 'maneuver')
    check('...graded at the pinned cost', r.rec.err, 0)
    check('...and the record carries the pinned cost', r.rec.cost, 15)
    check('...and the raw comparison beside it', r.rec.raw_cost, 20)
    -- the same for a cost the server taught: three contradictions froze it
    cfg.stat_check = {}
    m.cost.Fire, m.costSource.Fire = 15, 'observed'
    CLOCKWORK_TEST.last = nil
    api.reconcile('Fire', m.burden.Fire + 15 - 30 + 5, false)
    r = CLOCKWORK_TEST.last
    check('a reading that agrees with the taught cost is a plain maneuver', r.kind, 'maneuver')
    check('...graded at the taught cost', r.rec.err, 0)
    check('...which stays taught', m.costSource.Fire, 'observed')
    cfg.stat_check = was
    handlers['command']({ command = '/cw reset' })
end

-- --------------------------------- a stat you set outranks what is read --
-- No stat packet follows a gear swap, so a maneuver set's stats never reach the
-- client: the read is whatever was worn at the last refresh - the equipment
-- menu, a level, a kill - and the model called checks lost that the server
-- scored won, +5 burden a time (B13 in the findings). A NUMBER in
-- config.stat_check is what you really wear. It is compared against the
-- automaton's LIVE stat, so it wins the check bare and still loses once that
-- element is stacked, which 'win' and 'lose' cannot say.
do
    local m, cfg = api.model(), api.config
    local was, wasStats, wasTune = cfg.stat_check, world.stats, api.tuneTab()
    local function said(text)
        for _, p in ipairs(printed) do if p:find(text, 1, true) then return true end end
        return false
    end
    petOut(PET + 310, MOB + 310)
    api.timersClear(false)
    cfg.stat_check = {}
    world.stats = { [3] = 73 }            -- AGI as memory holds it: no set in it
    send044({ head = 2, frame = 33, stats = { AGI = 80 } })
    handlers['d3d_present']()
    handlers['command']({ command = '/cw reset' })
    check('the stale read loses the check', (api.computeCost('Wind')), 20)

    -- the Wind set is worth +10 AGI, and the client cannot see it
    handlers['command']({ command = '/cw stat wind 83' })
    check('the command stores the stat', cfg.stat_check.Wind, 83)
    check('...so the check is won', (api.computeCost('Wind')), 15)
    check('...the model holds that cost', m.cost.Wind, 15)
    check('...and says where it came from', m.costSource.Wind, 'yours')
    api.selectTuneTab('cost')
    frame('cost view with a set stat')
    check('the cost column says whose it is', saw('your setting'), true)
    check('...against the stat you set', saw('AGI 83 v 80'), true)

    -- stacked: the automaton's AGI climbs past the number and it loses again,
    -- which is the whole reason this is a number and not a verdict
    send044({ head = 2, frame = 33, stats = { AGI = 87 } })
    handlers['d3d_present']()
    check('a stacked element loses again', m.cost.Wind, 20)
    check('...still from your setting', m.costSource.Wind, 'yours')

    -- `now` takes the LIVE read, not the setting: the one call that has to see
    -- what memory holds
    handlers['command']({ command = '/cw stat wind now' })
    check('now takes the live read', cfg.stat_check.Wind, 73)

    handlers['command']({ command = '/cw stat wind off' })
    check('off clears the setting', cfg.stat_check.Wind, nil)
    check('...and the source with it', m.costSource.Wind ~= 'yours', true)

    -- what it refuses: Dark reads MP live, and neither a non-element nor an
    -- impossible stat may land
    handlers['command']({ command = '/cw stat dark 50' })
    check('Dark is refused - it compares MP', cfg.stat_check.Dark, nil)
    handlers['command']({ command = '/cw stat banana 50' })
    handlers['command']({ command = '/cw stat wind 0' })
    handlers['command']({ command = '/cw stat wind 1000' })
    check('an impossible stat is refused', cfg.stat_check.Wind, nil)
    printed = {}
    handlers['command']({ command = '/cw stat' })
    check('the list names the stat each element checks', said('AGI'), true)

    -- ...and a setting that has gone stale - food worn off, gear changed - is
    -- the likeliest thing to be wrong here, so the drift record and the chat
    -- line both name it rather than blaming the model
    local wasChat = cfg.anomaly_chat
    cfg.anomaly_chat = true
    send044({ head = 2, frame = 33, stats = { AGI = 80 } })   -- bare again: 83 wins
    handlers['d3d_present']()
    handlers['command']({ command = '/cw stat wind 83' })
    api.reconcile('Wind', 35, false)                  -- burden 60, verified
    printed = {}
    api.reconcile('Wind', 60 + 20 - 30 + 5, false)    -- the server charged 20, not 15
    local line = lastLog('stat_check_drift')
    check('the drift record names your setting',
          line ~= nil and line:find('may be out of date', 1, true) ~= nil, true)
    check('...and the chat line says it too', said('may be out of date'), true)

    cfg.anomaly_chat = wasChat
    cfg.stat_check, world.stats = was, wasStats
    api.selectTuneTab(wasTune)
    handlers['command']({ command = '/cw reset' })
end


-- ------------------------------------------- a pending Deploy ends with its mob --
-- Deploy sets deployTo for the mob the automaton has not touched yet, and
-- gather() reads that as engaged. A death message ended petTarget but not
-- deployTo, so a mob somebody else killed first left the Deploy pending:
-- the enhance rung withheld Regen and offered the combat buffs for a fight
-- that had ended, and nothing but another action or a reset cleared it. Now
-- the death clears it, and a Deploy whose mob simply vanishes expires on the
-- same ten-second grace petTarget has - on its own clock, which petTarget
-- keeps to itself.
do
    local SELF = 0x01000001
    local function deploy(id) send028({ actor = SELF, category = 6, param = 138,
        targets = { { id = id, actions = { { message = 0 } } } } }) end
    petOut(PET + 300, MOB + 300)
    world.mobHpp = 62                                           -- the mob at slot 9 is alive and readable
    api.timersClear(true, 'activate')
    deploy(MOB + 301)
    check('a Deploy is pending on its mob', api.deployTo(), MOB + 301)
    send029(MOB + 5, MOB + 301, 0, 6)                           -- somebody else kills it first
    check('its death ends the pending Deploy', api.deployTo(), nil)
    -- ...and the enhance rung is idle again: Regen, not the combat buffs
    world.buffer = { 5, 35, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }
    send044({ head = 5, frame = 35, magic = 200, hp = 600, maxhp = 600, mp = 300, maxmp = 300 })
    world.hp, world.maxhp, world.petHpp, world.petMpp = 1000, 1000, 100, 100
    world.icons, world.timers = nil, nil
    advance(20)
    local name = api.predictSpell()
    check('an idle automaton is offered a Regen, not a combat buff', name:sub(1, 5), 'Regen')
    -- a mob that vanishes without a death message: the grace, on its own clock
    deploy(MOB + 302)                                           -- never in the entity table
    advance(1) handlers['d3d_present']()
    advance(1) handlers['d3d_present']()
    check('a Deploy on a mob out of sight is still pending at two seconds', api.deployTo(), MOB + 302)
    advance(9) handlers['d3d_present']()
    check('...and expires at ten', api.deployTo(), nil)
    -- one that stays readable stays pending past it
    deploy(MOB + 300)                                           -- the mob in the table, at slot 9
    advance(12) handlers['d3d_present']()
    check('a Deploy on a mob in sight does not expire', api.deployTo(), MOB + 300)
    -- and petTarget is not the Deploy's business: engaged with one mob in
    -- sight while a Deploy on another runs out, the engagement stands
    api.setPetTarget(MOB + 300)
    deploy(MOB + 303)
    advance(1) handlers['d3d_present']()
    advance(10) handlers['d3d_present']()
    check('the Deploy on the vanished mob expired', api.deployTo(), nil)
    check('...and the engagement with the visible one stands', api.petTarget(), MOB + 300)
    api.timersClear(true, 'activate')
end

-- ------------------------------------------------ Retrieve is a disengage --
-- Retrieve (140) sends the automaton back to the master: an explicit end to
-- the engagement and to any Deploy still pending, which the dispatch had no
-- branch for. The mob stays alive and in sight, so the grace could not help.
-- Burden, the recasts and the mob's effects are not Retrieve's to touch, and
-- somebody else's Retrieve is not ours.
do
    local m = api.model()
    local SELF, OTHER = 0x01000001, 0x01000009
    local function ja(actor, abil) send028({ actor = actor, category = 6, param = abil,
        targets = { { id = actor, actions = { { message = 0 } } } } }) end
    local function deploy(id) send028({ actor = SELF, category = 6, param = 138,
        targets = { { id = id, actions = { { message = 0 } } } } }) end
    world.buffer = { 2, 33, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }   -- Valoredge with Strobe: a Provoke row
    advance(2.5)
    petOut(PET + 300, MOB + 300)
    world.mobHpp = 62
    api.timersClear(true, 'activate')
    api.reconcile('Fire', 35, false)                            -- burden 60, verified
    send028(act(4, 24, MOB + 300, 2, 60))                       -- a Dia II on the mob
    -- Deploy, then Retrieve before the automaton acts
    deploy(MOB + 300)
    check('a Deploy is pending on the visible mob', api.deployTo(), MOB + 300)
    ja(SELF, 140)
    check('Retrieve ends the pending Deploy', api.deployTo(), nil)
    advance(12) handlers['d3d_present']()
    check('...and it stays ended with the mob in sight', api.deployTo(), nil)
    -- engaged with a recast running, then retrieved
    send028(act(11, 1945, MOB + 300, 100, 7, 0))                -- Provoke on it
    check('the automaton is engaged', api.petTarget(), MOB + 300)
    local rows = {}
    for _, r in ipairs(api.timerRows()) do rows[r.name] = r.state end
    check('...with a recast running', rows['Provoke'], 'counting')
    local burden0 = m.burden.Fire                               -- decay runs on regardless: compare across the packet
    ja(SELF, 140)
    check('Retrieve ends the engagement', api.petTarget(), 0)
    check('burden is not touched', m.burden.Fire, burden0)
    rows = {}
    for _, r in ipairs(api.timerRows()) do rows[r.name] = r.state end
    check('nor the recasts', rows['Provoke'], 'counting')
    check('nor the effects on the mob', api.mobs()[MOB + 300].fx[134] ~= nil, true)
    advance(12) handlers['d3d_present']()
    check('...and that stays ended with the mob in sight too', api.petTarget(), 0)
    -- somebody else's Retrieve leaves ours alone
    api.setPetTarget(MOB + 300)
    deploy(MOB + 300)
    ja(OTHER, 140)
    check('another master retrieving leaves our engagement', api.petTarget(), MOB + 300)
    check('...and our pending Deploy', api.deployTo(), MOB + 300)
    api.timersClear(true, 'activate')
    world.buffer = { 5, 35, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }   -- back to the caster the next block reads
    advance(2.5)
end

-- -------------------------------------- a culled automaton has no MP reading --
-- petInfo() is nil while the automaton is culled (resolveIds keeps its id and
-- drops its entity index) or when the read failed. gather() defaulted the MP
-- percentage to 100 and, with a 0x044 in hand, rebuilt that as [maxmp, maxmp]
-- with mpKnown true - a full pool published as a reading, off which the ladder
-- named a higher tier in plain text. Now the interval is the whole pool and
-- every pick inside it is affordable-but-unproven.
do
    world.hp = 1000
    world.petMpp = 5
    handlers['d3d_present']()
    local lo, hi = api.petMp()
    check('a visible automaton at 5% reads its interval', lo == 15 and hi == 17, true)
    check('...and petInfo answers', api.petInfo() ~= nil, true)
    world.petId = 0                                             -- culled: the index stays, the slot reads empty
    handlers['d3d_present']()
    check('a culled automaton has no petInfo', api.petInfo(), nil)
    lo, hi = api.petMp()
    check('...and its MP interval is the whole pool', lo == 0 and hi == 300, true)
    local _, _, mode, _, _, mpu = api.predictSpell()
    check('...so the pick is unproven on MP', mpu, true)
    check('...and says so', mode, 'uncertain')
    world.petId = PET + 300
    world.petMpp = 100
    handlers['d3d_present']()
    lo, hi = api.petMp()
    check('back in sight the reading returns', lo == 300 and hi == 300, true)
    -- ...and one native read failing on its own - GetPetMPPercent answering
    -- nothing, or raising - while the entity reads around it succeed.
    -- petInfo() turned that into mpp = 0: an empty pool that looked like a
    -- reading and had the ladder refuse every spell. It is nil now, and the
    -- whole-pool branch covers it. A real zero is still a reading.
    -- ...and the panel says so: the value under the MP bar is '?', not the
    -- 0% of an empty pool the ladder is not working from. The value is the
    -- text drawn after the 'MP' label: the next plain string, past the
    -- layout records (TAG:value shapes and bare RECTs) that land between.
    local function valueAfter(label)
        for i, d in ipairs(drawn) do
            if d == label then
                for j = i + 1, #drawn do
                    local s = tostring(drawn[j])
                    if not s:match('^%u+:') and s ~= 'RECT' then return drawn[j] end
                end
            end
        end
        return nil
    end
    api.config.compact = false
    world.petMppRead = 'nil'
    frame('MP read answering nothing')
    check('an MP read answering nothing is no reading', api.petInfo().mpp, nil)
    lo, hi = api.petMp()
    check('...so the interval is the whole pool', lo == 0 and hi == 300, true)
    check('...and the panel shows it as unknown', valueAfter('MP'), '?')
    world.petMppRead = 'error'
    frame('MP read raising')
    check('an MP read that raises is no reading either', api.petInfo().mpp, nil)
    lo, hi = api.petMp()
    check('...and the whole pool again', lo == 0 and hi == 300, true)
    check('...shown as unknown again', valueAfter('MP'), '?')
    api.resetSwallowed()
    world.petMppRead = nil
    world.petMpp = 0                                            -- a real empty pool
    frame('MP really empty')
    check('a real zero is a reading', api.petInfo().mpp, 0)
    lo, hi = api.petMp()
    check('...of an empty pool', lo == 0 and hi == 0, true)
    check('...and the panel prints the zero', valueAfter('MP'), '0%')
    world.petMpp = 100
    handlers['d3d_present']()
end

-- ------------------------------ Deploy is not evidence of an empty hate list --
-- TryEnhance picks its Regen target off the mob's enmity list - master, then
-- automaton, then the party - and a Deploy onto a mob nobody has touched finds
-- it empty: no Regen, the rung starts at Protect. But a Deploy onto a mob the
-- master (or the automaton, or a party member) has already hit finds them on
-- it, and the Regen is back. The model read every Deploy as the empty case.
-- The evidence dies with the mob and ages out after a minute without a blow;
-- a stranger's blow is on no list the rung searches.
do
    local SELF, MATE, STRANGER = 0x01000001, 0x01000009, 0x0100000A
    local function hit(actor, mob) send028({ actor = actor, category = 1, param = 0,
        targets = { { id = mob, actions = { { message = 1, param = 10 } } } } }) end
    local function deploy(mob) send028({ actor = SELF, category = 6, param = 138,
        targets = { { id = mob, actions = { { message = 0 } } } } }) end
    local function pick() return (api.predictSpell()) end
    world.buffer = { 5, 35, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }
    petOut(PET + 300, MOB + 300)
    world.mobHpp = 62
    send044({ head = 5, frame = 35, magic = 250, hp = 600, maxhp = 600, mp = 300, maxmp = 300 })
    world.hp, world.maxhp, world.petHpp, world.petMpp = 1000, 1000, 100, 100
    world.icons, world.timers, world.partyIds = nil, nil, nil
    api.forgetPet()
    api.timersClear(true, 'activate')
    advance(25)
    -- mobs no earlier fixture has hit: the evidence is per mob and outlives
    -- a fixture, as it outlives a fight until the mob dies or a minute passes
    deploy(MOB + 310)
    check('a Deploy onto an untouched mob withholds the Regen', pick():sub(1, 7), 'Protect')
    api.timersClear(true, 'activate')
    hit(SELF, MOB + 310)
    deploy(MOB + 310)
    check('a Deploy onto a mob the master hit allows the Regen', pick():sub(1, 5), 'Regen')
    api.timersClear(true, 'activate')
    world.partyIds = { [1] = MATE }
    handlers['d3d_present']()                                   -- the snapshot learns the party
    hit(MATE, MOB + 311)
    deploy(MOB + 311)
    check('a party member hitting it first allows the Regen too', pick():sub(1, 5), 'Regen')
    api.timersClear(true, 'activate')
    hit(STRANGER, MOB + 312)
    deploy(MOB + 312)
    check('a stranger hitting it first does not', pick():sub(1, 7), 'Protect')
    api.timersClear(true, 'activate')
    hit(SELF, MOB + 313)
    send029(MOB + 5, MOB + 313, 0, 6)                           -- it dies; the respawn reuses the id
    deploy(MOB + 313)
    check('a death takes the evidence with it', pick():sub(1, 7), 'Protect')
    api.timersClear(true, 'activate')
    hit(SELF, MOB + 314)
    advance(61)
    deploy(MOB + 314)
    check('a minute without a blow ages it out', pick():sub(1, 7), 'Protect')
    api.timersClear(true, 'activate')
    -- a cast that only started, and one that was interrupted, landed nothing:
    -- neither is a blow, and the mob is as untouched as before
    send028({ actor = SELF, category = 8, param = 24931,                     -- Slow starts
        targets = { { id = MOB + 315, actions = { { message = 0, param = 56 } } } } })
    send028({ actor = SELF, category = 8, param = 28787,                     -- ...and is interrupted
        targets = { { id = MOB + 315, actions = { { message = 0, param = 56 } } } } })
    deploy(MOB + 315)
    check('a started and interrupted cast is not a blow', pick():sub(1, 7), 'Protect')
    api.timersClear(true, 'activate')
    world.partyIds = nil
    handlers['d3d_present']()
end

-- --------------------------- fresh evidence revives an expired inferred buff --
-- The automaton casting Shell proves it has Protect (the enhance ladder's
-- order), and so on up the chain. The inference kept `petEffects[e] or at`,
-- so an entry that had run past the backstop kept its stale timestamp and no
-- later cast could ever prove the buff again: the strip lost it for good and
-- the ladder went on offering it. A live entry keeps its clock; a dead one
-- is revived.
do
    local SELF = 0x01000001
    local pet, st = require('cw.pet'), require('cw.state')
    petOut(PET + 300, MOB + 300)
    api.forgetPet()
    api.timersClear(true, 'activate')
    pet.notePetStatus(230, 40)                                  -- Protect announced on the automaton
    check('protect is on the automaton', api.petLive(40), true)
    advance(1801)
    check('...and has run past the backstop', api.petLive(40), false)
    send028(act(4, 51, SELF, 230, 41))                          -- it casts Shell IV: it has Protect
    check('a later Shell revives the Protect it proves', api.petLive(40), true)
    st.notePetSilent(40, 100)                                   -- a Protect with a clock of its own
    local until0 = api.petUntil()[40]
    send028(act(4, 51, SELF, 230, 41))
    check('...while a live entry keeps its clock', api.petUntil()[40], until0)
    advance(101)
    check('a clock that ran out is dead', api.petLive(40), false)
    send028(act(4, 51, SELF, 230, 41))
    check('...and revived, clock and all', api.petLive(40), true)
end

-- --------------------------------- a character switch forgets the character --
-- The login gate stopped the frame work but left character-owned state in
-- place, so a second character inherited the first one's loadout (equippedSet
-- kept answering from the last 0x044), burden and learned costs until its own
-- first 0x044. Now a frame that finds a different ServerId forgets them - and
-- keeps a 0x044 that arrived while no frame ran, which is the new character's
-- own zone-in packet. A zone by the same character forgets nothing.
do
    local SELF = 0x01000001
    local m = api.model()
    petOut(PET + 300, MOB + 300)
    send044({ head = 5, frame = 35, attachments = { 206 }, owned = { 206 }, magic = 250, maxmp = 300 })
    check('character A wears its loadout', (api.equippedSet() or {}).head, 'Soulsoother Head')
    api.reconcile('Fire', 35, false)                            -- burden 60 on the model
    m.cost.Fire, m.costSource.Fire = 15, 'observed'
    petIn()
    world.login = 0
    handlers['d3d_present']()                                   -- character select
    handlers['packet_in']({ id = 0x00A, injected = false, data = '' })   -- B zones in, no PUP 0x044
    world.selfId, world.charName, world.login = SELF + 700, 'Second', 2
    handlers['d3d_present']()
    check('character B does not wear the loadout of A', api.equippedSet(), nil)
    check('...nor carry the burden of A', m.burden.Fire, 0)
    check('...nor the cost A learned', m.costSource.Fire ~= 'observed', true)
    -- C's own 0x044, arriving while the world loads, is C's and stays
    world.login = 0
    handlers['d3d_present']()
    send044({ head = 2, frame = 33, attachments = { 1 }, owned = { 1 } })
    world.selfId, world.charName, world.login = SELF + 800, 'Third', 2
    handlers['d3d_present']()
    check('a loadout that arrived while loading belongs to the new character', (api.equippedSet() or {}).head, 'Valoredge Head')
    handlers['packet_in']({ id = 0x00A, injected = false, data = '' })   -- C zones
    handlers['d3d_present']()
    check('a zone by the same character forgets nothing', (api.equippedSet() or {}).head, 'Valoredge Head')
    world.selfId, world.charName, world.login = SELF, 'Harness', 2
    handlers['d3d_present']()                                   -- the harness's own character again
end

-- -------------------------------------------- the 0x044 outranks the buffer --
-- The client's PUP buffer lags: empty until the attachments window has been
-- opened once a session, the OLD loadout after an Apply until an Activate.
-- The server's 0x044 is sent on every equip. So what the automaton is wearing
-- is the packet when one has arrived and the buffer only until then - for
-- every consumer at once, since all of them go through equippedNames(). The
-- Heatsink decay term is the probe: 2/tick with one Water up and Heatsink on,
-- 1/tick without. Buffer changes here do not re-send the packet (none is
-- live at the time), which is what lets the two sources disagree on purpose.
do
    local function rate() return (api.decayRate({ Water = 1 })) end
    api.clear044()
    world.buffer = { 2, 33, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }   -- the buffer: bare
    advance(2.5)
    check('no packet yet: the buffer is read, and it is bare', rate(), 1)
    send044({ head = 2, frame = 33, attachments = { 206 } })       -- the server: Heatsink
    check('a packet naming Heatsink outranks a bare buffer', rate(), 2)
    api.clear044()
    world.buffer = { 2, 33, 206, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 } -- the buffer: Heatsink
    advance(2.5)
    check('no packet: the buffer says Heatsink', rate(), 2)
    send044({ head = 2, frame = 33, attachments = {} })            -- the server: an Apply took it off
    check('a packet without it outranks a stale buffer', rate(), 1)
    -- ...and a packet naming no head or frame is no loadout: the buffer again
    send044({ head = 0, frame = 0, attachments = {} })
    check('an empty packet falls back to the buffer', rate(), 2)
    api.clear044()
end

-- ------------------------------------------------------- the cost knobs --
-- config.default_cost / dark_cost are the knobs for a server whose maneuver
-- costs differ, so all three cost sites in cw/burden.lua must read them rather
-- than hardcode 15/20 (Dark 10/15).
do
    local m, cfg = api.model(), api.config
    local was = cfg.stat_check
    cfg.default_cost, cfg.dark_cost = 25, 12
    cfg.stat_check = { Fire = 'lose', Dark = 'win' }
    handlers['command']({ command = '/cw reset' })   -- applyStatCheck on every element
    check('default_cost is the lost-check cost', m.cost.Fire, 25)
    check('dark_cost is the lost-check cost for Dark, won is 5 under it', m.cost.Dark, 7)
    cfg.default_cost, cfg.dark_cost, cfg.stat_check = 20, 15, was
    handlers['command']({ command = '/cw reset' })
    check('the knobs restore', m.cost.Fire, 20)
end
