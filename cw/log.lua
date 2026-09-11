-- cw/log.lua - the JSONL session log and the anomaly channel. Owns the file
-- handle, kept on tm.logFile (with the tm.logDay/logId/logDir its name was built
-- from), and publishes tm.installRoot. Exports logPath, logOpen, logEvent,
-- flagAnomaly and close, which the entry file calls on unload.
local chat = require('chat')
local config = require('cw.config')
local tm = require('cw.state')
local U  = require('cw.util')
local safe = U.safe
local ids = tm.ids

-- ------------------------------------------------------------- logging --
-- GetInstallPath answers with a trailing separator on some Ashita builds and
-- without one on others, so every builder below strips it before adding its own;
-- skip that and the Settings tab shows a doubled slash, `.../Game//config/...`.
tm.installRoot = function()
    local base = safe(function() return AshitaCore:GetInstallPath() end, '.')
    return (base:gsub('\\', '/'):gsub('/+$', ''))
end
local function logPath()
    if config.log_dir ~= nil then
        -- An inline-config edit may leave the trailing slash off; without one
        -- the directory would glue onto the filename: '...\logsName_YYYY.MM.DD.jsonl'.
        local d = config.log_dir:gsub('\\', '/')
        return (d:sub(-1) == '/') and d or (d .. '/')
    end
    return ('%s/config/addons/clockwork/'):format(tm.installRoot())
end

-- Is the JSONL wanted at all? Routine records need `logging`; anomalies need
-- only `anomaly_file`, so the quiet-disk mode still opens a file.
local function logWanted(anomaly)
    return config.logging or (anomaly and config.anomaly_file)
end

local function logOpen()
    if not logWanted(true) or tm.logFile ~= nil then return end
    safe(function()
        local dir = logPath()
        ashita.fs.create_directory(dir)
        -- IPlayer has no GetName; ecosystem pattern is party slot 0.
        local name = safe(function()
            return AshitaCore:GetMemoryManager():GetParty():GetMemberName(0)
        end, nil)
        if name == nil or name == '' then
            local pe = GetPlayerEntity()
            name = pe and pe.Name or nil
        end
        -- Not logged in yet (e.g. loaded from the boot script): opening now
        -- would pin a wrong filename for the whole session. Leave logFile
        -- nil; the next logEvent retries.
        if name == nil or name == '' then return end
        local day  = os.date('%Y.%m.%d')
        local path = ('%s%s_%s.jsonl'):format(dir, name, day)
        tm.logFile = io.open(path, 'a')
        if tm.logFile ~= nil then
            -- What this handle's filename says, so logEvent can tell when the
            -- name has stopped being true.
            tm.logDay, tm.logId, tm.logDir = day, ids.self_id, dir
            print(chat.header('clockwork'):append(chat.message('logging to ' .. path)))
        end
    end)
end

-- one JSON object per line; flat, so it greps and parses trivially
local function logEvent(kind, tbl)
    -- flagAnomaly stamps tbl.anomaly before it calls in, so the two channels
    -- need no separate entry point.
    if not logWanted(tbl.anomaly) then return end
    if type(CLOCKWORK_TEST) == 'table' then CLOCKWORK_TEST.last = { kind = kind, rec = tbl } end
    -- The filename bakes in a date and a character name, so both are checked
    -- per record: otherwise a session that crosses midnight would append its
    -- after-midnight records to yesterday's file, where they sort before the
    -- evening's, and a character switch without a reload would write one
    -- character's records into the other's. Close and let logOpen build the
    -- new name. The identity check is on
    -- ServerId because it is free - the name behind it costs a native read,
    -- and this runs on the packet thread once per record.
    if tm.logFile ~= nil then
        -- opened before the first render frame resolved anyone: adopt the id
        -- rather than reading it as a switch
        if tm.logId == 0 then tm.logId = ids.self_id end
        -- ...and the directory, which is an inline-config edit: a changed
        -- log_dir moves the log at the next record rather than leaving the
        -- handle in the previous folder for the rest of the session.
        if tm.logDay ~= os.date('%Y.%m.%d') or tm.logDir ~= logPath()
           or (ids.self_id ~= 0 and ids.self_id ~= tm.logId) then
            tm.logFile:close()
            tm.logFile = nil
        end
    end
    logOpen()
    if tm.logFile == nil then return end
    local parts = { ('"t":"%s"'):format(os.date('%H:%M:%S')), ('"kind":"%s"'):format(kind) }
    for k, v in pairs(tbl) do
        if type(v) == 'number' then
            parts[#parts + 1] = ('"%s":%s'):format(k, tostring(v))
        elseif type(v) == 'boolean' then
            parts[#parts + 1] = ('"%s":%s'):format(k, v and 'true' or 'false')
        else
            -- Proper JSON string escaping: an unescaped backslash, newline
            -- or control character writes a line no parser can read, and
            -- the fields most likely to carry one are the free text: a set
            -- name, a prediction's reason, a mob's name.
            local s = tostring(v):gsub('[%c"\\]', function(c)
                if c == '"'  then return '\\"'  end
                if c == '\\' then return '\\\\' end
                if c == '\n' then return '\\n'  end
                if c == '\r' then return '\\r'  end
                if c == '\t' then return '\\t'  end
                return ('\\u%04x'):format(c:byte())
            end)
            parts[#parts + 1] = ('"%s":"%s"'):format(k, s)
        end
    end
    tm.logFile:write('{' .. table.concat(parts, ',') .. '}\n')
    tm.logFile:flush()
end

-- The chat line says what the model expected, not only that something was
-- logged, so an anomaly does not send you to the JSONL to find out. It is
-- built off the record's own fields: the two prediction anomalies carry
-- `expected` (and the `expected_why` behind it), a burden mismatch carries
-- predicted against actual. Anything else keeps the bare form rather than
-- inventing a shape.
local function flagAnomaly(kind, tbl)
    tm.anomalies = tm.anomalies + 1
    tbl.anomaly = true
    logEvent(kind, tbl)
    local said = ''
    if tbl.expected ~= nil then
        said = (' - got %s, expected %s'):format(tostring(tbl.name or tbl.ws or '?'),
                                                 tostring(tbl.expected))
        if config.show_reasoning and tbl.expected_why ~= nil and tbl.expected_why ~= '' then
            said = said .. (' (%s)'):format(tostring(tbl.expected_why))
        end
    elseif tbl.predicted ~= nil and tbl.actual ~= nil then
        said = (' - predicted %s%%, read %s%%'):format(tostring(tbl.predicted), tostring(tbl.actual))
    end
    if config.anomaly_chat then
        print(chat.header('clockwork'):append(chat.error(('ANOMALY %s'):format(kind)))
            :append(chat.message(said)))
    end
end

-- On unload: the file handle is tm.logFile so the entry file need not know it.
local function close()
    if tm.logFile ~= nil then tm.logFile:close() tm.logFile = nil end
end

return { logPath = logPath, logOpen = logOpen, logEvent = logEvent,
         flagAnomaly = flagAnomaly, close = close }
