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
