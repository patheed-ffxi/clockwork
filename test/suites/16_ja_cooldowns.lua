-- ------------------------------------------------ your own job abilities --
-- cw/cooldowns.lua: the master's PUP job abilities, read off the client's
-- recast table rather than modelled. A fixture sets world.abilities (what
-- HasAbility answers, by resource id = 0x200 + LSB's abilityId) and
-- world.recast (slot -> { timer id, ticks in 1/60 s }), then refreshes.
local JA = 0x200
local function learnAll()
    world.abilities = {}
    for _, ja in ipairs(api.jaList()) do world.abilities[JA + ja.ability] = true end
end
local function jaRow(rows, key)
    for _, r in ipairs(rows) do if r.key == key then return r end end
    return nil
end

do
    local c = api.config
    check('eleven abilities', #api.jaList(), 11)
    check('hide when ready ships on', c.cd_hide_ready, true)
    local off = nil
    for _, ja in ipairs(api.jaList()) do
        if c['cd_' .. ja.key] ~= true then off = ja.key end
    end
    check('every ability ships switched on', off, nil)

    learnAll()
    c.cd_hide_ready = false
    world.recast = { [3] = { 206, 2820 } }        -- Repair, 47 s left
    local rows = api.jaRefresh()
    check('every learned ability is listed with hide when ready off', #rows, 11)
    check('a counting ability counts', (jaRow(rows, 'repair') or {}).state, 'counting')
    check('...at the seconds the client holds', (jaRow(rows, 'repair') or {}).remaining, 47)
    check('an ability in no slot is ready', (jaRow(rows, 'activate') or {}).state, 'ready')
    check('...with nothing left on it', (jaRow(rows, 'activate') or {}).remaining, nil)
    check('the rows keep the table order', rows[1] and rows[1].key, 'activate')
    check('...to the end', rows[11] and rows[11].key, 'overdrive')

    c.cd_hide_ready = true
    rows = api.jaRefresh()
    check('hide when ready keeps only what counts', #rows, 1)
    check('...which is Repair', rows[1] and rows[1].key, 'repair')

    c.cd_repair = false
    check('a switched-off ability is dropped while it counts', #api.jaRefresh(), 0)
    c.cd_repair = true

    c.cd_hide_ready = false
    world.abilities[JA + 137] = nil               -- Repair not learned
    check('an ability you do not have is never listed', jaRow(api.jaRefresh(), 'repair'), nil)
    learnAll()

    -- Slot 0 is the two-hour, and its timer id is 0. Anywhere else, id 0 is
    -- an empty slot.
    c.cd_hide_ready = true
    world.recast = { [0] = { 0, 60 * 600 } }
    rows = api.jaRefresh()
    check('slot 0 is the two-hour', rows[1] and rows[1].key, 'overdrive')
    check('...at its seconds', rows[1] and rows[1].remaining, 600)
    world.recast = { [5] = { 0, 60 * 600 } }
    check('an id-0 slot past slot 0 is empty', #api.jaRefresh(), 0)

    -- all eight maneuvers share timer 210: one row
    world.recast = { [2] = { 210, 60 * 8 } }
    rows = api.jaRefresh()
    check('the shared maneuver timer is one row', #rows, 1)
    check('...labelled Maneuver', rows[1] and rows[1].label, 'Maneuver')

    -- a slot at zero ticks has finished, not started
    world.recast = { [2] = { 210, 0 } }
    check('a slot at 0 ticks is ready', #api.jaRefresh(), 0)

    -- a failed read is an empty group and one swallowed count, never a crash
    api.resetSwallowed()
    local known = world.abilities
    world.abilities = nil                         -- HasAbility now raises
    check('a failed read lists nothing', #api.jaRefresh(), 0)
    check('...and counts what it swallowed', api.swallowed(), 1)
    world.abilities = known
    api.resetSwallowed()
end

-- The `you` group in the recast column: under the automaton's cells, the only
-- group with a heading, sharing their label width, and counted in the spill.
do
    local c = api.config
    local function at(text)
        for i, d in ipairs(drawn) do if d == text then return i end end
        return nil
    end
    learnAll()
    c.cd_hide_ready = true

    world.recast = {}
    frame('ja: nothing counting')
    check('nothing counting draws no you label', at('you'), nil)

    world.recast = { [3] = { 206, 2820 } }        -- Repair, 47 s
    frame('ja: Repair counting')
    local auto = api.timerRows()
    check('precondition: an automaton cell is drawn',
          #auto > 0 and at(auto[1].label) ~= nil, true)
    check('a counting ability brings the you label', at('you') ~= nil, true)
    check('...its label', at('Repair') ~= nil, true)
    check('...and its seconds', at('47s') ~= nil, true)
    local lastAuto = 0
    for _, r in ipairs(auto) do
        local i = at(r.label)
        if i ~= nil and i > lastAuto then lastAuto = i end
    end
    check('every automaton cell comes before the you group', lastAuto < (at('you') or 0), true)
    check('...and the you label before its rows', (at('you') or 1e9) < (at('Repair') or 0), true)

    c.cd_hide_ready = false
    world.recast = {}
    frame('ja: all ready')
    check('with hide when ready off, a ready ability is listed', at('Activate') ~= nil, true)
    c.cd_hide_ready = true

    -- One label width for the whole column: a long label in the you group pads
    -- every automaton value too, so the seconds end level all the way down.
    -- Repair counts beside Deactivate because its label is the shorter: the
    -- widest label's own value sits at s(4) padded or not, so only a shorter
    -- one shows the you cell honouring the width it is handed.
    local tw = world.textWidth
    world.textWidth = true
    world.recast = { [3] = { 208, 600 }, [4] = { 206, 600 } }   -- Deactivate, Repair, 10 s
    api.jaRefresh()
    drawn = {}
    api.sideColumn(#auto + 3, {})
    local widest = #'Deactivate' * 7
    for _, r in ipairs(auto) do
        if #r.label * 7 > widest then widest = #r.label * 7 end
    end
    check('an automaton value is padded to the you group\'s widest label',
          sawExact('SP:' .. tostring(api.s(4) + widest - #auto[1].label * 7)), true)
    check('...and the you value to the same column',
          sawExact('SP:' .. tostring(api.s(4) + widest - #'Repair' * 7)), true)
    world.textWidth = tw

    -- The spill counts the you group: room that held the deltas beside the
    -- automaton's cells alone does not hold them under a you group too.
    local buffs = { { 'ATT', '%', 16 } }
    world.recast = {}
    api.jaRefresh()
    check('the deltas fit beside the automaton cells alone', #api.sideColumn(#auto + 2, buffs), 0)
    world.recast = { [3] = { 206, 2820 } }
    api.jaRefresh()
    check('a you group sends them under the table', #api.sideColumn(#auto + 2, buffs), 2)
    check('...and room for both keeps them', #api.sideColumn(#auto + 4, buffs), 0)

    world.recast = {}
    frame('ja: column done')
end

-- The switches persist like every other Settings-tab switch, and live behind
-- a disclosure row that starts shut.
do
    local c = api.config
    local path = api.settingsPath()

    c.cd_hide_ready, c.cd_repair, c.cd_overdrive = false, false, false
    api.saveSettings()
    c.cd_hide_ready, c.cd_repair, c.cd_overdrive = true, true, true
    api.loadSettings()
    check('hide when ready is saved', c.cd_hide_ready, false)
    check('an ability switch is saved', c.cd_repair, false)
    check('...the last in the list too', c.cd_overdrive, false)
    local f = assert(io.open(path, 'r'))
    local text = f:read('*a')
    f:close()
    check('the file names the switch', text:find('cd_repair = false', 1, true) ~= nil, true)

    -- true beforehand, deliberately: a mutant coercing 'maybe' to false would
    -- be invisible against a switch that was already off
    f = assert(io.open(path, 'w'))
    f:write('cd_repair = maybe\n')
    f:close()
    c.cd_repair = true
    api.loadSettings()
    check('a junk value keeps the live switch', c.cd_repair, true)

    c.cd_hide_ready, c.cd_overdrive = false, false
    api.restoreDefaults()
    check('restore turns hide when ready back on', c.cd_hide_ready, true)
    check('restore switches an ability back on', c.cd_overdrive, true)
    suiteLogging()

    -- the block: shut, then open, then a switch in it, then shut again
    frame('ja: settings shut')
    check('the disclosure row is drawn', saw('BTN:ability cooldowns##cw_cdopen'), true)
    check('...shut, with no ability switch', saw('BTN:Repair##cw_set_cd_repair'), false)
    clicks['ability cooldowns##cw_cdopen'] = true
    frame('ja: settings open')
    check('open, it holds hide when ready', saw('BTN:hide when ready##cw_set_cd_hide_ready'), true)
    check('...the first ability', saw('BTN:Activate##cw_set_cd_activate'), true)
    check('...and the last', saw('BTN:Overdrive##cw_set_cd_overdrive'), true)
    local saves = api.saveCount()
    clicks['Repair##cw_set_cd_repair'] = true
    frame('ja: Repair switched off')
    check('a click switches it off', c.cd_repair, false)
    check('...and writes the file once', api.saveCount(), saves + 1)
    clicks['ability cooldowns##cw_cdopen'] = true
    frame('ja: settings shut again')
    check('a second click shuts it', saw('BTN:Repair##cw_set_cd_repair'), false)

    api.restoreDefaults()
    suiteLogging()
    world.abilities, world.recast = {}, {}
end
