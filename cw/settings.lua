-- cw/settings.lua - the Settings tab's toggles, kept across a reload. Owns the
-- whitelist of saved keys and their defaults. Returns nothing; publishes
-- tm.settingsPath, tm.saveSettings, tm.loadSettings, tm.restoreDefaults and
-- tm.saveCount. tm.installRoot (cw/log.lua) and tm.sidebarInvalidate are reached
-- through tm at call time, so neither module is required here.
local chat = require('chat')
local config = require('cw.config')
local tm = require('cw.state')
local U  = require('cw.util')
local safe = U.safe

-- ======================================================== settings file ==
-- The Settings tab's toggles, kept across a reload.
--
-- A WHITELIST, not a dump of `config`. The inline table stays the defaults and
-- stays the only place the model constants are edited - activate_burden,
-- dea_burden, heatsink_decay, the stat-check verdicts and the tolerances - so a
-- settings file left over from an older build can never resurrect a
-- value that has since been corrected. Only the display and
-- reporting keys the UI can actually reach are written, and anything else in
-- the file is ignored. The one exception is not a model constant at all: the
-- stat you wear for each maneuver is YOURS, and is saved - see STAT_KEYS.
--
-- Format is the sets store's: plain text, one `key = value` a line, parsed by
-- hand. Not JSON - the addon has no json dependency and writes its own JSONL by
-- hand - and not Ashita's `settings` library, which would mean restructuring
-- `config` and re-pointing every read of it.

-- kind, and the bounds an int is clamped to. A line naming any key not listed
-- here is ignored.
local PERSIST = {
    logging           = { 'bool' },
    anomaly_file      = { 'bool' },
    anomaly_chat      = { 'bool' },
    debug_predictions = { 'bool' },
    log_all_casts     = { 'bool' },
    show_reasoning    = { 'bool' },
    show_window       = { 'bool' },
    show_target       = { 'bool' },
    show_ws           = { 'bool' },
    show_gives        = { 'bool' },
    show_oils         = { 'bool' },
    sidebar           = { 'bool' },
    compact           = { 'bool' },
    ui_scale          = { 'int', 75, 200 },
    warn_at           = { 'int', 1, 100 },
}
-- The stat you have on when each element's maneuver goes off, as a number
-- (cw/config.lua's stat_check). Saved as `stat_Wind = 83`, because it is your
-- own gear rather than one of the model's constants, and retyping it after
-- every reload is not a thing anyone would do. NUMBERS ONLY: a 'win' / 'lose'
-- verdict stays an inline edit, so an old file still cannot resurrect one. A
-- value cleared in game writes no line at all, so what comes back is the inline
-- value - normally nil, meaning work it out. Dark is not here: it compares MP,
-- which is read live and needs no help.
local STAT_KEYS = { 'Fire', 'Ice', 'Wind', 'Earth', 'Thunder', 'Water', 'Light' }
local IS_STAT   = {}
for _, el in ipairs(STAT_KEYS) do IS_STAT[el] = true end

-- Snapshot of the inline values, taken as this module loads and therefore
-- before any file is read. This is what Restore defaults puts back.
local DEFAULTS = {}
for k in pairs(PERSIST) do DEFAULTS[k] = config[k] end
local STAT_DEFAULTS = {}
for _, el in ipairs(STAT_KEYS) do STAT_DEFAULTS[el] = config.stat_check[el] end

local ORDER = {}
for k in pairs(PERSIST) do ORDER[#ORDER + 1] = k end
table.sort(ORDER)   -- a stable file, so a diff of one means something

tm.settingsPath = function()
    return ('%s/config/addons/clockwork/settings.txt'):format(tm.installRoot())
end

tm.saveCount = 0
-- A write that fails is said out loud, once, here rather than at each caller,
-- so no way of changing a setting can fail in silence and then quietly revert
-- after a reload.
tm.saveSettings = function()
    tm.saveCount = tm.saveCount + 1
    local ok = safe(function()
        safe(function() ashita.fs.create_directory(
            (tm.settingsPath():gsub('/settings%.txt$', '/'))) end)
        local lines = { '# clockwork settings, saved whenever one is changed in game.\n',
                        '# Delete this file to go back to the defaults in cw/config.lua.\n' }
        for _, k in ipairs(ORDER) do
            lines[#lines + 1] = ('%s = %s\n'):format(k, tostring(config[k]))
        end
        for _, el in ipairs(STAT_KEYS) do
            local v = config.stat_check[el]
            if type(v) == 'number' then
                lines[#lines + 1] = ('stat_%s = %d\n'):format(el, v)
            end
        end
        -- Through writeFile's temp file, with the write and the close both
        -- checked: a write that fails after the open reports failure and
        -- leaves the existing file whole rather than truncated.
        return (U.writeFile(tm.settingsPath(), table.concat(lines)))
    end, false)
    if not ok then
        print(chat.header('clockwork'):append(chat.error(
            'settings could not be saved to ' .. tm.settingsPath()
            .. ' - the change applies to this session only')))
    end
    return ok
end

-- Anything missing, unknown or the wrong type keeps the inline default, so
-- a partial or hand-edited file is harmless and a key added in a later
-- version arrives with its default rather than nil.
tm.loadSettings = function()
    return safe(function()
        local f = io.open(tm.settingsPath(), 'r')
        if f == nil then return false end
        for line in f:lines() do
            local k, v = line:match('^%s*([%w_]+)%s*=%s*(.-)%s*$')
            local spec = k and PERSIST[k] or nil
            local el   = k and k:match('^stat_(%a+)$') or nil
            if el ~= nil and IS_STAT[el] then
                -- A stat, not a verdict: anything that is not a plausible stat
                -- leaves that element working it out, which is the safe half.
                local n = tonumber(v)
                if n ~= nil and n == n and n >= 1 and n <= 999 then
                    config.stat_check[el] = math.floor(n)
                end
            elseif spec ~= nil then
                if spec[1] == 'bool' then
                    if v == 'true' or v == 'false' then config[k] = (v == 'true') end
                else
                    local n = tonumber(v)
                    -- n == n is false for NaN, and the infinities survive
                    -- math.floor. Either would poison every layout number
                    -- and then write itself back as 'nan' / 'inf'.
                    if n ~= nil and n == n and n > -math.huge and n < math.huge then
                        config[k] = math.max(spec[2], math.min(spec[3], math.floor(n)))
                    end
                end
            end
        end
        f:close()
        -- Those stats decide each element's cost, and nothing else would
        -- recompute them until the next 0x044 arrived.
        tm.refreshStatChecks()
        return true
    end, false)
end

tm.restoreDefaults = function()
    for k, v in pairs(DEFAULTS) do config[k] = v end
    for _, el in ipairs(STAT_KEYS) do config.stat_check[el] = STAT_DEFAULTS[el] end
    tm.refreshStatChecks()
    tm.sidebarInvalidate()
    tm.saveSettings()
end

return {}
