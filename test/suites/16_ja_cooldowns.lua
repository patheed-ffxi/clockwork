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
    check('hide when ready ships off', c.cd_hide_ready, false)
    local off = {}
    for _, ja in ipairs(api.jaList()) do
        if c['cd_' .. ja.key] ~= true then off[#off + 1] = ja.key end
    end
    check('every ability ships switched on but Retrieve and Deactivate',
          table.concat(off, ','), 'retrieve,deactivate')
    -- the rest of the suite lists all eleven, up to its restoreDefaults()
    c.cd_retrieve, c.cd_deactivate = true, true

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

-- How long each recast is, which the client never says: the most time left
-- seen on it since it started counting, forgotten once it is ready.
do
    local c = api.config
    learnAll()
    c.cd_hide_ready = true
    world.recast = {}
    api.jaRefresh()
    world.recast = { [3] = { 206, 90 * 60 } }     -- Repair, first seen at 90 s
    local r = api.jaRefresh()[1]
    check('first sight of a recast is its length', r and r.total, 90)
    world.recast = { [3] = { 206, 45 * 60 } }
    r = api.jaRefresh()[1]
    check('...kept as it runs down', r and r.total, 90)
    check('...beside what is left', r and r.remaining, 45)
    world.recast = {}
    api.jaRefresh()
    world.recast = { [3] = { 206, 30 * 60 } }
    r = api.jaRefresh()[1]
    check('once ready it is forgotten: the next recast is its own length', r and r.total, 30)
    c.cd_hide_ready = false
    world.recast = {}
    check('a ready ability has no length', (api.jaRefresh()[1] or {}).total, nil)
end

-- The `you` group: under the maneuver table rather than in the recast column,
-- in equal columns as many to a line as the panel holds, each cell a dial.
-- The Status tab alone: the Settings tab names every ability too, and in the
-- harness's draw-everything mode its names would answer for the group's.
do
    local c = api.config
    local function at(text)
        for i, d in ipairs(drawn) do if d == text then return i end end
        return nil
    end
    api.selectTab('status')
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
    check('...and the you label before its cells', (at('you') or 1e9) < (at('Repair') or 0), true)

    -- The column is the automaton's alone again: none of your cells in it,
    -- and the deltas it holds are the ones it held before the group existed.
    drawn = {}
    local buffs = { { 'ATT', '%', 16 } }
    check('the deltas fit beside the automaton cells with you counting',
          #api.sideColumn(#auto + 2, buffs), 0)
    check('...and the column draws none of your cells', at('Repair'), nil)
    check('...nor the you label', at('you'), nil)

    c.cd_hide_ready = false
    world.recast = {}
    frame('ja: all ready')
    check('with hide when ready off, a ready ability is listed', at('Activate') ~= nil, true)

    -- Equal columns, as many as the panel's inner width holds: each cell is
    -- the dial, the widest label showing, and a value slot for 00:00 or ready.
    local tw = world.textWidth
    world.textWidth = true
    local s, pad, gap = api.s, api.s(8), api.s(12)
    local inner = s(c.base_width) - pad * 2
    local function cellW(widest)
        return (api.dpx('text') - s(2)) + s(3) + widest + s(4) + #'00:00' * 7
    end
    api.jaRefresh()                               -- all eleven, all ready
    drawn = {}
    api.jaGrid()
    local cell = cellW(#'Deactivate' * 7)
    local cols = math.floor((inner + gap) / (cell + gap))
    check('precondition: more than one column and fewer than eleven', cols > 1 and cols < 11, true)
    check('the second cell sits in the second column', sawExact('X:' .. tostring(pad + cell + gap)), true)
    check('...the last column is the one the width holds',
          sawExact('X:' .. tostring(pad + (cols - 1) * (cell + gap))), true)
    check('...and there is none past it', sawExact('X:' .. tostring(pad + cols * (cell + gap))), false)
    local xs = 0
    for _, d in ipairs(drawn) do if d:find('^X:') then xs = xs + 1 end end
    check('the first cell of each line starts it, the rest are placed', xs, 11 - math.ceil(11 / cols))

    -- the widths follow what is showing: two short labels, narrower columns
    c.cd_hide_ready = true
    world.recast = { [3] = { 206, 600 }, [7] = { 207, 600 } }   -- Repair, Deploy
    api.jaRefresh()
    drawn = {}
    api.jaGrid()
    check('shorter labels showing make narrower columns',
          sawExact('X:' .. tostring(pad + cellW(#'Repair' * 7) + gap)), true)
    world.textWidth = tw

    -- The dial: a dark disc, and over it a wedge for the part of the recast
    -- left - two halves past half, so each stays convex. A green disc when ready.
    world.recast = {}
    api.jaRefresh()
    world.recast = { [3] = { 206, 90 * 60 } }
    api.jaRefresh()
    drawn = {}
    api.jaGrid()
    check('a full recast is two half wedges', countExact('WEDGE'), 2)
    world.recast = { [3] = { 206, 30 * 60 } }
    api.jaRefresh()
    drawn = {}
    api.jaGrid()
    check('a third of it left is one wedge', countExact('WEDGE'), 1)
    check('...over the disc', countExact('CIRC'), 1)
    -- a client whose draw list has no path calls: a smaller disc instead
    local pathClear = drawList.PathClear
    drawList.PathClear = nil
    drawn = {}
    api.jaGrid()
    check('without the path calls, no wedge', countExact('WEDGE'), 0)
    check('...but a second disc for what is left', countExact('CIRC'), 2)
    drawList.PathClear = pathClear
    c.cd_hide_ready = false
    world.recast = {}
    api.jaRefresh()
    drawn = {}
    api.jaGrid()
    check('a ready ability is a disc and no wedge', countExact('WEDGE'), 0)
    check('...one disc to each', countExact('CIRC'), 11)
    c.cd_hide_ready = true

    world.recast = {}
    frame('ja: grid done')
    api.selectTab('all')
end

-- The switches persist like every other Settings-tab switch, and sit in the
-- open on its display view.
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

    c.cd_hide_ready, c.cd_overdrive, c.cd_retrieve = true, false, true
    api.restoreDefaults()
    check('restore turns hide when ready back off', c.cd_hide_ready, false)
    check('restore switches an ability back on', c.cd_overdrive, true)
    check('...and Retrieve back off', c.cd_retrieve, false)
    suiteLogging()

    -- Settings is two views, display and logging, and opens on display. The
    -- Settings tab alone: the harness's draw-everything mode draws both.
    api.selectTab('settings')
    frame('ja: settings opens')
    check('Settings opens on display', api.settingsView(), 'display')
    check('...where the ability switches need no click', saw('BTN:Repair##cw_set_cd_repair'), true)
    check('...with hide when ready', saw('BTN:hide when ready##cw_set_cd_hide_ready'), true)
    check('...the first ability', saw('BTN:Activate##cw_set_cd_activate'), true)
    check('...and the last', saw('BTN:Overdrive##cw_set_cd_overdrive'), true)
    check('...beside the display switches', saw('BTN:oil counts##cw_set_show_oils'), true)
    check('...and the scale box', saw('TXT:scale##cw_set_ui_scale'), true)
    check('...but no logging switch', saw('BTN:write a log file##cw_set_logging'), false)
    check('...and no fold-away row', saw('cw_cdopen'), false)
    check('the model button is on display', saw('BTN:Zero burden##cw_set_sync'), true)
    check('...and so is restore', saw('BTN:Restore defaults##cw_set_defaults'), true)
    local saves = api.saveCount()
    clicks['Repair##cw_set_cd_repair'] = true
    frame('ja: Repair switched off')
    check('a click switches it off', c.cd_repair, false)
    check('...and writes the file once', api.saveCount(), saves + 1)

    clicks['logging##cw_settings'] = true
    frame('ja: the logging view')
    check('the logging button shows the logging view', api.settingsView(), 'logging')
    check('...with its switches', saw('BTN:write a log file##cw_set_logging'), true)
    check('...the last of them too', saw('BTN:predictions to chat##cw_set_debug_predictions'), true)
    check('...and no display switch', saw('BTN:oil counts##cw_set_show_oils'), false)
    check('...nor an ability one', saw('BTN:Repair##cw_set_cd_repair'), false)
    check('the model button is on logging too', saw('BTN:Zero burden##cw_set_sync'), true)
    check('...and so is restore', saw('BTN:Restore defaults##cw_set_defaults'), true)
    clicks['display##cw_settings'] = true
    frame('ja: back to display')
    check('the display button shows display again', saw('BTN:Repair##cw_set_cd_repair'), true)
    api.selectTab('all')

    api.restoreDefaults()
    suiteLogging()
    world.abilities, world.recast = {}, {}
end

-- The dials style, the Settings tab's `as dials`: each of your abilities as a
-- dial alone - the time on it while it counts, a short name under it - at the
-- automaton cells' pitch. Off, the default, is the dial, the name and the time.
do
    local c = api.config
    check('dials ship off: names and times', c.cd_dials, false)
    api.selectTab('status')
    learnAll()
    c.cd_hide_ready, c.cd_dials = false, true
    world.recast = { [3] = { 206, 2820 } }        -- Repair, 47 s
    frame('ja dials: Repair counting')
    check('dials keep the you label', sawExact('you'), true)
    check('a dial is named short', sawExact('Rep'), true)
    -- exact: the oils line's 'Repair and Maintenance unusable' is not a cell
    check('...not by its full name', sawExact('Repair'), false)
    check('...with its seconds on it', sawExact('47s'), true)
    check('a ready one is named too', sawExact('Act'), true)
    -- Deus Ex and Deactivate both begin Dea: DEA is the usual shorthand for
    -- Deus Ex Automata, so Deactivate is Dct.
    c.cd_deactivate = true
    frame('ja dials: Deactivate listed')
    check('Deus Ex is DEA', sawExact('DEA'), true)
    check('Deactivate is Dct', sawExact('Dct'), true)
    -- A dial is as wide as an automaton cell - 24 here, 20 for the widest of
    -- 00s and 0:00, plus 4 - with 3 between, so the second sits at 8 + 27 = 35.
    -- Ten listed (Retrieve ships off) fit one line: (364 + 3) / 27 holds 13.
    api.jaRefresh()
    drawn = {}
    api.jaGrid()
    check('the second dial is one cell on', sawExact('X:35'), true)
    check('...the tenth on the same line', sawExact('X:' .. tostring(8 + 9 * 27)), true)
    local xs = 0
    for _, d in ipairs(drawn) do if d:find('^X:') then xs = xs + 1 end end
    check('...every one after the first placed on it', xs, 9)

    api.selectTab('settings')
    frame('ja dials: settings')
    check('the dials switch is on the display view', saw('BTN:as dials##cw_set_cd_dials'), true)
    clicks['as dials##cw_set_cd_dials'] = true
    frame('ja dials: switched off')
    check('a click switches dials off', c.cd_dials, false)
    c.cd_dials = true
    api.saveSettings()
    c.cd_dials = false
    api.loadSettings()
    check('dials are saved', c.cd_dials, true)
    api.restoreDefaults()
    check('restore goes back to names and times', c.cd_dials, false)
    suiteLogging()
    api.selectTab('all')
    world.abilities, world.recast = {}, {}
end

-- On the compact strip: a row of your own under the strip, in either layout,
-- from under the gems (x 17) to the strip's right edge and with no you label,
-- in whichever style the switch picks. Each line of it is begun by the rail's
-- slot - a 3 x 0 Dummy, which only starts the line - so the rail runs down
-- beside it.
do
    local c = api.config
    local function xBefore(text)
        local last = nil
        for _, d in ipairs(drawn) do
            if d:find('^X:') then last = tonumber(d:sub(3))
            elseif d == text then return last end
        end
        return nil
    end
    learnAll()
    petOut()
    c.compact, c.compact_rows, c.cd_hide_ready, c.cd_dials = true, 1, true, false
    world.recast = {}
    frame('ja compact: nothing counting')
    check('nothing counting: no row under the strip', countExact('DUMMY:3:0'), 0)
    world.recast = { [3] = { 206, 2820 } }        -- Repair, 47 s
    frame('ja compact: one row, Repair counting')
    check('a counting ability adds a row under the strip', countExact('DUMMY:3:0'), 1)
    check('...naming it', sawExact('Repair'), true)
    check('...with its seconds', sawExact('47s'), true)
    check('...from under the gems', countExact('X:17'), 2)
    check('...and no you label on the strip', sawExact('you'), false)
    -- dials at the cells' pitch: 17, then 17 + 27 = 44 (nothing else on the
    -- one-row strip sits at 44)
    c.cd_hide_ready, c.cd_dials = false, true
    frame('ja compact: one row, dials')
    check('the strip draws dials when the switch says so', sawExact('Rep'), true)
    check('...one cell apart', sawExact('X:44'), true)
    c.cd_dials = false

    c.compact_rows = 2
    c.cd_hide_ready = true
    frame('ja compact: two rows, Repair counting')
    check('two rows: the row is there too', countExact('DUMMY:3:0'), 1)
    check('...naming it', sawExact('Repair'), true)
    -- Nine listed with hide when ready off. A names cell is 16 + 3 + 20 + 4 +
    -- 20 = 63 wide with 12 between, and the strip's right edge is the bars':
    -- their x plus 2 x (20 + 4 + 44) + 10 = 146.
    c.cd_hide_ready = false
    frame('ja compact: two rows, all nine')
    local xb = xBefore('HP') or 0
    local cols = math.floor((xb + 146 - 17 + 12) / 75)
    check('precondition: the nine take more than one line', cols > 1 and cols < 9, true)
    check('a line holds what the strip is wide enough for',
          sawExact('X:' .. tostring(17 + (cols - 1) * 75)), true)
    check('...and no more', sawExact('X:' .. tostring(17 + cols * 75)), false)
    check('...each line begun by the rail\'s slot', countExact('DUMMY:3:0'), math.ceil(9 / cols))

    c.compact, c.compact_rows, c.cd_hide_ready = false, 1, false
    api.saveSettings()
    petIn()
    world.abilities, world.recast = {}, {}
end
