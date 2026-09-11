-- ------------------------------------------------ the log rolls at midnight --
-- logOpen returns early once logFile is non-nil and bakes the date into the
-- filename, while logEvent stamps only %H:%M:%S. Without a rollover, records
-- written after midnight land in the previous day's file, where they sort
-- before the evening's, and nothing rotates on a character switch either.
-- The checks: a new day opens a new file, and so does a new character.
do
    local dir = SCRATCH .. '/rot/'
    local function linesIn(name, day)
        local f = io.open(('%s%s_%s.jsonl'):format(dir, name, day), 'r')
        if f == nil then return nil end
        local n = 0
        for _ in f:lines() do n = n + 1 end
        f:close()
        return n
    end
    -- /cw sync writes exactly one model_reset record, which is the whole of
    -- what this block needs out of the log.
    api.config.logging, api.config.log_dir = true, dir
    world.dayShift = 24 * 3600           -- tomorrow: rotates out of today's file
    local d1 = os.date('%Y.%m.%d')
    handlers['command']({ command = '/cw sync' })
    check('the first day has a file', linesIn('Harness', d1), 1)
    world.dayShift = 48 * 3600           -- ...and again at the next midnight
    local d2 = os.date('%Y.%m.%d')
    handlers['command']({ command = '/cw sync' })
    check('the second day has its own file', linesIn('Harness', d2), 1)
    check('and the first day did not grow', linesIn('Harness', d1), 1)
    -- a character switch inside one session rotates too - the name is in the
    -- filename and nothing ever re-read it
    world.charName, world.selfId = 'Other', 0x01000002
    handlers['d3d_present']()            -- ids.self_id follows the new character
    handlers['command']({ command = '/cw sync' })
    check('the other character gets its own file', linesIn('Other', d2), 1)
    check('and did not grow the first character', linesIn('Harness', d2), 1)
    world.charName, world.selfId, world.dayShift = nil, nil, 0
    handlers['d3d_present']()
    api.config.log_dir = nil
end

-- --------------------------------- a learned cost override is not permanent --
-- Three observations that contradict the computed cost freeze cost[el] with
-- costSource[el] = 'observed', and applyStatCheck returns early on it forever
-- after. Its own comment said /cw reset clears it; /cw reset touched neither
-- costSource nor costDispute, so the frozen value outlived every gear change,
-- every automaton and the reset that was supposed to drop it.
do
    local m = api.model()
    m.cost.Fire, m.costSource.Fire = 15, 'observed'
    m.costDispute.Fire = { value = 15, count = 2 }
    handlers['command']({ command = '/cw reset' })
    check('reset drops the observed source', m.costSource.Fire == 'observed', false)
    check('reset drops the dispute', m.costDispute.Fire, nil)
    check('reset recomputes a cost', m.cost.Fire ~= nil, true)
    -- ...and so does a new automaton. The override was learned by comparing
    -- the master's stat against THAT automaton's, so a frame swap invalidates
    -- it as surely as a reset does.
    petOut(PET + 99, MOB + 99)
    send044({ head = 5, frame = 35, magic = 120, hp = 600, maxhp = 600, mp = 300, maxmp = 300 })
    handlers['d3d_present']()
    m.cost.Ice, m.costSource.Ice = 15, 'observed'
    m.costDispute.Ice = { value = 15, count = 2 }
    send044({ head = 5, frame = 35, magic = 120, hp = 600, maxhp = 600, mp = 300, maxmp = 300 })
    handlers['d3d_present']()
    check('the same frame keeps the override', m.costSource.Ice, 'observed')
    send044({ head = 2, frame = 33, magic = 120, hp = 600, maxhp = 600, mp = 300, maxmp = 300 })
    handlers['d3d_present']()
    check('a new frame drops the override', m.costSource.Ice == 'observed', false)
    check('a new frame drops the dispute', m.costDispute.Ice, nil)
end

-- ------------------------------------------------------- the hard ceilings --
-- LuaJIT allows 60 upvalues per closure, and the two registered handlers are
-- the closures that keep approaching it: every chunk-level name they touch is
-- one. The syntax checker counts the OTHER ceiling (200 top-level locals); this
-- one was only ever a comment in the file, updated by hand and already stale
-- twice. A build that crosses it fails to load in game and passes here.
do
    check('d3d_present is under the upvalue ceiling',
          debug.getinfo(handlers['d3d_present'], 'u').nups < 60, true)
    check('packet_in is under the upvalue ceiling',
          debug.getinfo(handlers['packet_in'], 'u').nups < 60, true)

    -- The packet thread reads only what the render thread published, which is
    -- a statement about one file's require list.
    local f = assert(io.open(ADDON_DIR .. '/cw/inbound.lua', 'r'))
    local inbound = f:read('*a')
    f:close()
    check('inbound never requires reading', inbound:find("require('cw.reading')", 1, true), nil)
    check('inbound is the packet handler', debug.getinfo(handlers['packet_in'], 'u').nups < 60, true)

    -- The registered handlers are one-line wrappers, so the ceiling that
    -- matters is on the module functions they call.
    local nups = api.nups()
    check('panel.draw is under the upvalue ceiling', nups.draw < 60, true)
    check('inbound.onPacket is under the upvalue ceiling', nups.onPacket < 60, true)
end
