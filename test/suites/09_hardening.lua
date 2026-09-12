-- ------------------------------------------------- the record is real JSON --
do
    -- 29. the encoder replaced `"` with `'` and left everything else, so any
    -- string field carrying a backslash, a newline or a control character
    -- wrote a line no parser could read.
    local dir = SCRATCH .. '/json/'
    api.config.logging, api.config.log_dir = true, dir
    handlers['command']({ command = '/cw sync' })          -- one model_reset line
    local f = io.open(('%s%s_%s.jsonl'):format(dir, 'Harness', os.date('%Y.%m.%d')), 'r')
    check('the log went to the directory', f ~= nil, true)
    if f ~= nil then f:close() end
    -- 30. ...and it does so with no trailing slash on log_dir, which used to
    -- glue the directory onto the filename
    api.config.log_dir = SCRATCH .. '/json2'
    handlers['command']({ command = '/cw sync' })
    local g = io.open(('%s/%s_%s.jsonl'):format(SCRATCH .. '/json2', 'Harness',
                                                os.date('%Y.%m.%d')), 'r')
    check('a log_dir without a slash still lands in it', g ~= nil, true)
    if g ~= nil then g:close() end
    api.config.log_dir = nil
end

-- ------------------------------------------- set names, and what a set costs --
do
    -- 19. Windows keeps a handful of reserved device names, with or without an
    -- extension. `nul` passed validation, io.open succeeded, and the bytes
    -- went to the null device - saveSet returned true and no file existed.
    for _, bad in ipairs({ 'nul', 'CON', 'aux', 'Prn', 'com1', 'LPT9', 'nul.txt' }) do
        check('reserved device name ' .. bad .. ' refused', api.validSetName(bad), false)
    end
    -- ...and names that merely contain one are fine
    for _, ok in ipairs({ 'console', 'nulled', 'com', 'lpt', 'aux tank' }) do
        check('ordinary name ' .. ok .. ' allowed', api.validSetName(ok), true)
    end

    -- ...and the guard belongs in the WRITING code, not only in the UI gate
    -- that calls it: saveSet reported success, wrote to the null device and
    -- left no set behind, which is how the reproduction was made.
    local aSet = { head = 'Valoredge Head', frame = 'Valoredge Frame', attachments = { 'Strobe' } }
    check('saveSet refuses a device name', (api.saveSet('NUL', aSet)), false)
    check('...and nothing was written', api.loadSet('NUL'), nil)
    check('saveSet still writes a real one', (api.saveSet('device test', aSet)), true)
    check('renameSet refuses a device name', api.renameSet('device test', 'com1'), false)
    check('...and leaves the original alone', api.loadSet('device test') ~= nil, true)

    -- 21. a write that failed AFTER the open - disk full - reported success,
    -- over the set it had already truncated. The bytes go to a temp file now
    -- and only a written and closed one replaces the target.
    -- The stub opens (and so truncates) whatever path it is handed, as the
    -- real io.open does, and then refuses the bytes: on the old code that
    -- path was the set itself.
    local realOpen = io.open
    io.open = function(p, m)
        if m == 'w' and tostring(p):find('device test', 1, true) then
            local h = realOpen(p, m)
            return { write = function() return nil, 'disk full' end,
                     close = function() if h then h:close() end return true end }
        end
        return realOpen(p, m)
    end
    local bigger = { head = 'Valoredge Head', frame = 'Valoredge Frame', attachments = { 'Strobe', 'Armor Plate' } }
    local ok, why = api.saveSet('device test', bigger)
    io.open = realOpen
    check('a write that fails after the open is a failed save', ok, false)
    check('...with a reason', type(why), 'string')
    local kept = api.loadSet('device test')
    check('...and the set it was replacing is intact', kept ~= nil and #kept.attachments or 'gone', 1)

    -- 22. ...and a REPLACE that fails leaves both files: the set being
    -- replaced untouched, and the new bytes in the temp the reason names.
    -- The shape before this removed the target first and, when the rename
    -- then failed, the temp as well - the one path that lost both copies.
    -- Both ways of replacing are refused, so the old shape shows it too.
    local realRename = os.rename
    os.rename = function(a, b)
        if world.replaceFails then return nil, 'replace refused (harness)' end
        return realRename(a, b)
    end
    world.replaceFails = true
    local ok2, why2 = api.saveSet('device test', bigger)
    world.replaceFails = nil
    os.rename = realRename
    check('a failed replace is a failed save', ok2, false)
    local kept2 = api.loadSet('device test')
    check('...the set being replaced is untouched', kept2 ~= nil and #kept2.attachments or 'gone', 1)
    local tmpPath = why2 and why2:match('the new contents are in (.+)$') or nil
    check('...and the reason names the temp', tmpPath ~= nil, true)
    local th = tmpPath and io.open(tmpPath, 'r') or nil
    check('...which holds the new bytes',
          th ~= nil and (th:read('*a') or ''):find('Armor Plate', 1, true) ~= nil, true)
    if th then th:close() end
    if tmpPath then os.remove(tmpPath) end
    api.deleteSet('device test')

    -- 20. capacityOf summed a repeated attachment line twice while planApply
    -- and the server count it once, so a set with a duplicate looked
    -- over-capacity and the Apply button was refused on a set that fits.
    local dup = { head = 'Valoredge Head', frame = 'Valoredge Frame',
                  attachments = { 'Strobe', 'Strobe' } }
    local used = api.capacityOf(dup)
    local one = api.capacityOf({ head = 'Valoredge Head', frame = 'Valoredge Frame',
                                 attachments = { 'Strobe' } })
    check('a duplicated line costs what one costs', used.Fire, one.Fire)
    check('...and the set still fits', select(3, api.capacityOf(dup)), true)
end

-- ------------------------------------------- settings that cannot be poisoned --
-- Four small hardening cases, in one place: a NaN through the
-- clamp, a save whose failure nobody reads, a confirm that never disarms, and
-- a slider that writes the file on every frame of a drag.
do
    local cfg = api.config
    local scale0 = cfg.ui_scale
    -- 15. The `/cw width` command went with the other setting-setters in
    -- 1.15.2 - the Settings tab owns what it sets - and its NaN and clamp
    -- guards went with it; the width itself became a scale in 1.17.0. The
    -- guard that matters is the one on the way IN, below: a hand-edited or
    -- self-poisoned file must not be able to set a NaN, which is how it
    -- persisted (tostring(NaN) is 'nan' and tonumber('nan') is a number
    -- again). The slider cannot produce one.

    -- 16. a failed write said 'saved' anyway
    local realOpen = io.open
    io.open = function(p, m)
        if m == 'w' and tostring(p):find('settings.txt', 1, true) then return nil end
        return realOpen(p, m)
    end
    printed = {}
    cfg.ui_scale = 140
    -- the report lives in saveSettings now, not in the command that went
    api.saveSettings()
    io.open = realOpen
    local saidSaved, saidFailed = false, false
    for _, s in ipairs(printed) do
        if s:find('- saved', 1, true) then saidSaved = true end
        if s:find('could not be saved', 1, true) then saidFailed = true end
    end
    check('a failed save does not claim to have saved', saidSaved, false)
    check('...and says so', saidFailed, true)
    check('the value still applies to this session', cfg.ui_scale, 140)
    cfg.ui_scale = scale0
    api.saveSettings()

    -- ...and a write that failed AFTER the open - disk full - said 'saved'
    -- too, over the file it had already truncated. The bytes go to a temp
    -- file now and only a written and closed one replaces the target.
    local spath = api.settingsPath()
    local function fileText(p)
        local h = realOpen(p, 'r')
        if h == nil then return nil end
        local t = h:read('*a')
        h:close()
        return t
    end
    local good = fileText(spath)
    check('a good settings file is on disk to protect', good ~= nil and good:find('ui_scale = ', 1, true) ~= nil, true)
    -- opens (and so truncates) the path it is handed, as the real one does,
    -- then refuses the bytes: on the old code that path was settings.txt
    io.open = function(p, m)
        if m == 'w' and tostring(p):find('settings.txt', 1, true) then
            local h = realOpen(p, m)
            return { write = function() return nil, 'disk full' end,
                     close = function() if h then h:close() end return true end }
        end
        return realOpen(p, m)
    end
    cfg.ui_scale = 140
    check('a write that fails after the open is a failed save', api.saveSettings(), false)
    io.open = realOpen
    check('...and the file it was replacing is intact', fileText(spath), good)
    -- ...and a replace that fails leaves it just as intact (the set-file
    -- block above proves the temp survives; this is the settings path)
    local realRename = os.rename
    os.rename = function(a, b)
        if world.replaceFails then return nil, 'replace refused (harness)' end
        return realRename(a, b)
    end
    world.replaceFails = true
    check('a failed replace is a failed settings save', api.saveSettings(), false)
    world.replaceFails = nil
    os.rename = realRename
    check('...and the settings file is untouched', fileText(spath), good)
    os.remove(spath .. '.tmp')
    cfg.ui_scale = scale0
    api.saveSettings()

    -- ...and the same guard on the way IN. A hand-edited or self-poisoned
    -- file must not be able to set a NaN either, which is how it persisted:
    -- tostring(NaN) is 'nan' and tonumber('nan') is a number again.
    local sp = api.settingsPath()
    local before = cfg.ui_scale
    local sf = io.open(sp, 'w')
    sf:write('ui_scale = nan\nwarn_at = inf\n')
    sf:close()
    api.loadSettings()
    check('a NaN in the file is refused', cfg.ui_scale, before)
    check('an infinity in the file is refused', cfg.warn_at == cfg.warn_at, true)
    check('...and stays in range', cfg.warn_at <= 100, true)
    api.saveSettings()

    -- 18. the confirm's LABEL followed only the armed name while its guard
    -- followed the clock, so a lapsed arm still invited a click that re-armed
    clicks['Zero burden##cw_set_sync'] = true
    frame('arm the zero')
    frame('armed')
    check('an armed confirm asks', saw('BTN:Really zero?##cw_set_sync'), true)
    advance(5)                                   -- past the 4 s guard
    frame('the arm has lapsed')
    check('a lapsed confirm stops asking', saw('BTN:Really zero?##cw_set_sync'), false)
    check('...and offers the plain action again', saw('BTN:Zero burden##cw_set_sync'), true)

    -- 26. the slider wrote the file on every frame of a drag
    local n0 = api.saveCount()
    for _ = 1, 5 do frame('slider idle') end
    check('an idle settings tab writes nothing', api.saveCount(), n0)
end

-- ---------------------------- a frame that swallows nothing, and a culled pet --
-- safe() exists so a native read cannot kill the render thread, which also
-- means a real bug inside one returns the fallback and looks like data. The
-- counter makes that visible: a full frame on every tab must swallow nothing.
do
    world.buffer = { 5, 35, 1, 207, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }
    world.icons, world.timers = nil, nil
    advance(30)
    petOut(PET + 66, MOB + 66)
    send044({ head = 5, frame = 35, magic = 250, hp = 600, maxhp = 600, mp = 300, maxmp = 300,
              attachments = { 1, 207 }, owned = { 1, 207 } })
    -- One frame to warm up: tm.spellName uses safe() as control flow on
    -- purpose - it probes GetSpellById and falls back to 'spell <id>' for an
    -- era-locked resource - and the name fill runs once per session. After
    -- that a frame that swallows anything is a real failure.
    frame('warm-up')
    api.resetSwallowed()
    frame('a clean frame')
    check('a warmed frame swallows no native error', api.swallowed(), 0)

    -- Draw distance culls the automaton: the client keeps PetTargetIndex set
    -- while the entity slot empties, so GetEntity answers nothing. The addon
    -- must keep the id for packet attribution and drop the index, not treat it
    -- as a despawn - and it must not throw on the empty slot.
    local realGetEntity = GetEntity
    GetEntity = function() return nil end
    api.resetSwallowed()
    CLOCKWORK_TEST.last = nil
    handlers['d3d_present']()
    frame('a culled automaton')
    check('a culled automaton does not read as a despawn',
          CLOCKWORK_TEST.last ~= nil and CLOCKWORK_TEST.last.kind == 'pet_despawn', false)
    check('and the frame still swallows nothing', api.swallowed(), 0)
    GetEntity = realGetEntity
    handlers['d3d_present']()
end

-- ------------------------ the packet gates the whole model rests on --
-- Three mutants survived every check in 1.8.1 and still survived at 1.9.0:
-- the maneuver element index shifted by one, so every Fire
-- maneuver reconciled as Ice; the injected-packet gate removed; and the 0x044
-- PUP-job gate removed. All three survived because nothing drove those code
-- paths - every burden test called api.reconcile() directly, and every 0x044
-- came from a builder that always sets job 18. These fixtures drive the
-- PACKET.
do
    local m, cfg = api.model(), api.config
    local SELF = 0x01000001
    world.buffer = { 2, 33, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }
    world.icons, world.timers = nil, nil
    advance(30)
    petOut(PET + 65, MOB + 65)
    handlers['command']({ command = '/cw sync' })          -- every element at 0

    -- one maneuver per element, through the 0x028 handler. 141..148 are
    -- Fire..Dark (abilities.sql), and each must move ITS OWN element and no
    -- other: a table read shifted by one puts every reading on the neighbour.
    for i, el in ipairs({ 'Fire', 'Ice', 'Wind', 'Earth', 'Thunder', 'Water', 'Light', 'Dark' }) do
        advance(6)
        -- an overload-chance line carries the server's own percent, which is
        -- what reconcile() back-solves the burden from
        send028({ actor = SELF, category = 6, param = 140 + i,
                  targets = { { id = SELF, actions = { { message = 798, param = 40 + i } } } } })
        check('maneuver ' .. el .. ' reconciles its own element',
              m.verified[el], true)
        check('maneuver ' .. el .. ' is the only one verified',
              (i > 1) and m.verified[({ 'Fire', 'Ice', 'Wind', 'Earth', 'Thunder',
                                        'Water', 'Light', 'Dark' })[i - 1]] or true, true)
    end
    -- ...and the eight readings are distinct, so no two elements share a slot
    local seen = {}
    for _, el in ipairs({ 'Fire', 'Ice', 'Wind', 'Earth', 'Thunder', 'Water', 'Light', 'Dark' }) do
        seen[m.burden[el]] = (seen[m.burden[el]] or 0) + 1
    end
    local distinct = 0
    for _ in pairs(seen) do distinct = distinct + 1 end
    check('each element took a different reading', distinct, 8)

    -- an INJECTED packet is another addon's, not the server's, and must be
    -- ignored outright: acting on one double-counts whatever sent it
    handlers['command']({ command = '/cw sync' })
    advance(6)
    handlers['packet_in']({ id = 0x028, injected = true,
                            data = build028({ actor = SELF, category = 6, param = 141,
                                              targets = { { id = SELF, actions = {
                                                  { message = 798, param = 41 } } } } }) })
    check('an injected 0x028 is ignored', m.verified.Fire, false)
    check('...and moves nothing', m.burden.Fire, 0)

    -- The AF gloves' Maneuver Bonus is read off the hands as the maneuver
    -- resolves and kept for that element, so the +1 outlasts the swap back
    -- to other gloves - until the next Fire resolves bare-handed.
    local function fireSTR()
        for _, r in ipairs(api.buffSummary({}, { Fire = 1 }, {})) do
            if r[1] == 'STR' then return r[3] end
        end
    end
    world.gear = { [6] = 14930 }   -- Puppetry Dastanas in the hands slot
    advance(6)
    send028({ actor = SELF, category = 6, param = 141,
              targets = { { id = SELF, actions = { { message = 798, param = 41 } } } } })
    world.gear = nil
    advance(1)
    check('a Fire resolved in the AF gloves states STR +7', fireSTR(), 7)
    advance(6)
    send028({ actor = SELF, category = 6, param = 141,
              targets = { { id = SELF, actions = { { message = 798, param = 42 } } } } })
    check('...and +6 once one resolves bare-handed', fireSTR(), 6)

    -- the 0x044 job gate: the packet carries the job it describes, and only
    -- PUP's variant has this layout. Another job's would be read as an
    -- automaton loadout made of whatever those bytes happen to hold.
    local seq = api.state().seq
    handlers['packet_in']({ id = 0x044, injected = false,
                            data = build044({ head = 2, frame = 33, job = 1 }) })
    check('a non-PUP 0x044 is ignored', api.state().seq, seq)
    send044({ head = 2, frame = 33 })
    check('...and a PUP one is not', api.state().seq, seq + 1)

    -- the dedupe window: FFXI resends a chunk, and running reconcile twice on
    -- one maneuver doubles its cost. 5 s, and the BOUNDARY is what is tested -
    -- 4.5 s in, so a window shortened to 4 fails here where a repeat at 4 s
    -- flat would still look deduped under either value.
    handlers['command']({ command = '/cw sync' })
    advance(6)
    local function fire(seq) send028({ actor = SELF, category = 6, param = 141, seq = seq,
                                       targets = { { id = SELF, actions = {
                                           { message = 798, param = 45 } } } } }) end
    fire(7)
    CLOCKWORK_TEST.last = nil
    advance(4.5)
    fire(7)
    check('a resend inside the window is dropped', CLOCKWORK_TEST.last, nil)
    -- the same action in a new chunk carries a new sequence: a real second cast
    fire(8)
    check('a new sequence inside the window is a new reading', CLOCKWORK_TEST.last ~= nil, true)
    CLOCKWORK_TEST.last = nil
    advance(1)                                    -- 5.5 s from the first: the same bytes, past the window
    fire(7)
    check('and past it is a new reading', CLOCKWORK_TEST.last ~= nil, true)
end
