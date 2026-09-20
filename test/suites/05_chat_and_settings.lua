-- --------------------------------------------------- prediction debug line --
-- A correct prediction is otherwise silent in game - it writes pet_spell and
-- nothing else - while a miss prints through flagAnomaly, so the feature looks
-- like it only ever fails. debug_predictions is the symmetric line: off as
-- shipped (checked at load), on for this suite. NB saw() searches imgui
-- draws; chat goes to `printed`.
do
    local cfg = api.config
    local function said(text)
        for _, p in ipairs(printed) do if p:find(text, 1, true) then return true end end
        return false
    end
    check('debug_predictions on for the suite', cfg.debug_predictions, true)
    world.buffer = { 5, 35, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }
    advance(2.5)
    petOut(PET + 10, MOB + 10)
    send044({ head = 5, frame = 35, magic = 120, hp = 600, maxhp = 600, mp = 300, maxmp = 300 })
    world.hp, world.maxhp, world.petHpp, world.petMpp = 1000, 1000, 100, 100
    world.icons, world.timers = nil, nil
    frame('debug pred snapshot')
    -- assert the snapshot first: if the ladder ever changes, this fixture fails
    -- loudly instead of quietly testing a mispredict
    check('debug pred snapshot', (api.predictSpell()), 'Regen')
    printed = {}
    send028(act(8, 108))                  -- cast what the snapshot named
    check('debug pred logged', CLOCKWORK_TEST.last.kind, 'pet_spell')
    check('debug pred announced', said('as predicted'), true)
    -- off: the record still lands, the chat line does not
    advance(20)                           -- every window this head has reopens
    cfg.debug_predictions = false
    printed = {}
    check('debug pred snapshot again', (api.predictSpell()), 'Regen')
    send028(act(8, 108, MOB + 11))        -- a different target dodges isDuplicate
    check('debug pred off still logs', CLOCKWORK_TEST.last.kind, 'pet_spell')
    check('debug pred off is silent', said('as predicted'), false)
    cfg.debug_predictions = true

    -- ---- show_reasoning: the NAME survives, the reason goes -------------
    -- The log keeps expected_why either way: it is the dataset a mispredict is
    -- diagnosed from, not a display.
    advance(20)
    cfg.show_reasoning = false
    printed = {}
    check('reason off snapshot', (api.predictSpell()), 'Regen')
    -- the HUD is the other half of what this switch governs, and it has to be
    -- read while the prediction is still live: the cast below closes the
    -- enhance window the Regen came from.
    frame('reason off hud')
    check('hud drops the spell reason', saw('no Regen on you or automaton'), false)
    check('hud keeps the spell name', saw('Regen'), true)
    send028(act(8, 108, MOB + 12))
    check('reason off keeps the name', said('Regen as predicted'), true)
    check('reason off drops the why', said('no Regen on you or automaton'), false)
    check('reason off keeps the record', CLOCKWORK_TEST.last.rec.expected_why,
          'enhance · no Regen on you or automaton (hate picks which)')
    advance(20)
    cfg.show_reasoning = true
    printed = {}
    check('reason on snapshot', (api.predictSpell()), 'Regen')
    frame('reason on hud')
    check('hud says the spell reason', saw('no Regen on you or automaton'), true)
    send028(act(8, 108, MOB + 13))
    check('reason on says why', said('no Regen on you or automaton'), true)

    -- ---- the two anomaly channels --------------------------------------
    -- A mispredict: the snapshot says Regen, the automaton casts Protect.
    -- flagAnomaly is the only thing that fires, so each channel reads on its own.
    local function anomaly(target)
        advance(20)
        printed = {}
        CLOCKWORK_TEST.last = nil
        check('anomaly fixture snapshot', (api.predictSpell()), 'Regen')
        send028(act(8, 43, target))       -- Protect, not the Regen predicted
    end
    anomaly(MOB + 14)
    check('anomaly reaches chat when on', said('ANOMALY spell_mispredicted'), true)
    check('anomaly reaches the file when on', CLOCKWORK_TEST.last.kind, 'spell_mispredicted')
    check('anomaly chat carries the reason', said('no Regen on you or automaton'), true)

    -- chat off: the record still lands
    cfg.anomaly_chat = false
    anomaly(MOB + 15)
    check('anomaly chat off is silent', said('ANOMALY'), false)
    check('anomaly chat off still records', CLOCKWORK_TEST.last.kind, 'spell_mispredicted')
    cfg.anomaly_chat = true

    -- show_reasoning also governs the anomaly line's tail
    cfg.show_reasoning = false
    anomaly(MOB + 16)
    check('anomaly line without the reason', said('ANOMALY spell_mispredicted'), true)
    check('anomaly reason suppressed', said('no Regen on you or automaton'), false)
    check('anomaly expected survives', said('expected Regen'), true)
    cfg.show_reasoning = true

    -- the quiet-disk mode: routine records stop, anomalies do not
    cfg.logging = false
    advance(20)
    CLOCKWORK_TEST.last = nil
    check('quiet snapshot', (api.predictSpell()), 'Regen')
    send028(act(8, 108, MOB + 17))        -- a HIT: routine, so nothing written
    check('quiet disk drops a routine record', CLOCKWORK_TEST.last, nil)
    anomaly(MOB + 18)
    check('quiet disk keeps the anomaly', CLOCKWORK_TEST.last.kind, 'spell_mispredicted')
    -- ...and with both off, nothing reaches the file at all
    cfg.anomaly_file = false
    anomaly(MOB + 19)
    check('both off writes nothing', CLOCKWORK_TEST.last, nil)
    cfg.logging, cfg.anomaly_file = true, true
    -- The handle is opened once and kept. log.lua read an undeclared global
    -- `ids` where every other module localises tm.ids, so the first open
    -- errored inside safe() before tm.logDay was set, the 'logging to' line
    -- never printed, and every record after that closed and reopened the
    -- file behind another swallowed error.
    api.resetSwallowed()
    send028(act(8, 108, MOB + 20))
    check('a routine record is written', CLOCKWORK_TEST.last ~= nil, true)
    check('...and swallows no error on the way', api.swallowed(), 0)
end

-- --------------------------------------------------------- settings file --
-- The Settings tab's toggles across a reload. A WHITELIST: the inline table
-- stays the defaults and stays the only place the model constants are edited,
-- so a stale file can never resurrect a calibration value.
do
    local cfg = api.config
    local path = api.settingsPath()

    -- round trip
    cfg.anomaly_chat, cfg.show_reasoning, cfg.ui_scale = false, false, 120
    check('settings saved', api.saveSettings(), true)
    cfg.anomaly_chat, cfg.show_reasoning, cfg.ui_scale = true, true, 100
    check('settings read back', api.loadSettings(), true)
    check('settings restored a bool', cfg.anomaly_chat, false)
    check('settings restored another bool', cfg.show_reasoning, false)
    check('settings restored an int', cfg.ui_scale, 120)
    -- the four line switches are on the whitelist too
    cfg.show_ws, cfg.show_gives, cfg.show_oils, cfg.hide_zero_ol_rows = false, false, false, true
    api.saveSettings()
    cfg.show_ws, cfg.show_gives, cfg.show_oils, cfg.hide_zero_ol_rows = true, true, true, false
    api.loadSettings()
    check('settings restored show_ws', cfg.show_ws, false)
    check('settings restored show_gives', cfg.show_gives, false)
    check('settings restored show_oils', cfg.show_oils, false)
    check('settings restored hide_zero_ol_rows', cfg.hide_zero_ol_rows, true)
    cfg.show_ws, cfg.show_gives, cfg.show_oils, cfg.hide_zero_ol_rows = true, true, true, false

    -- what the file actually holds: stable order, one key a line, and NOTHING
    -- from the model. A calibration constant in here is the bug this guards.
    local f = assert(io.open(path, 'r'))
    local text = f:read('*a')
    f:close()
    check('file has the toggle', text:find('anomaly_chat = false', 1, true) ~= nil, true)
    check('file has the scale', text:find('ui_scale = 120', 1, true) ~= nil, true)
    check('file carries no model constant', text:find('activate_burden', 1, true), nil)
    check('file carries no seed', text:find('dea_burden', 1, true), nil)
    check('file carries no tolerance', text:find('burden_tolerance', 1, true), nil)

    -- junk is ignored, and every key it does not mention keeps its live value
    f = assert(io.open(path, 'w'))
    f:write('# a comment\n\nanomaly_chat = true\n')
    f:write('activate_burden = 999\n')       -- not on the whitelist
    f:write('show_reasoning = banana\n')     -- not a bool
    f:write('ui_scale = notanumber\n')       -- not a number
    f:write('nonsense\n')                    -- not a pair at all
    f:close()
    -- true, deliberately: a mutant that coerces 'banana' to false would be
    -- invisible against a value that was already false.
    cfg.show_reasoning, cfg.ui_scale = true, 120
    local seed = cfg.activate_burden
    check('junk file still loads', api.loadSettings(), true)
    check('junk file applies what it can', cfg.anomaly_chat, true)
    check('junk file cannot touch the model', cfg.activate_burden, seed)
    check('junk value keeps the live bool', cfg.show_reasoning, true)
    check('junk value keeps the live int', cfg.ui_scale, 120)

    -- ints are clamped, not trusted
    f = assert(io.open(path, 'w'))
    f:write('ui_scale = 12\nwarn_at = 5000\n')
    f:close()
    api.loadSettings()
    check('scale clamped up to the floor', cfg.ui_scale, 75)
    check('warn clamped down to the ceiling', cfg.warn_at, 100)

    -- The stat you wear for each maneuver IS saved - it is your own gear, not
    -- one of the model's constants, and retyping it after every reload is not a
    -- thing anyone would do. Numbers only, so a stale file cannot pin a verdict.
    cfg.stat_check.Wind, cfg.stat_check.Water = 83, 90
    api.saveSettings()
    cfg.stat_check.Wind, cfg.stat_check.Water = nil, nil
    api.loadSettings()
    check('settings restored a stat', cfg.stat_check.Wind, 83)
    check('...and another', cfg.stat_check.Water, 90)
    f = assert(io.open(path, 'r'))
    text = f:read('*a')
    f:close()
    check('the file holds the stat', text:find('stat_Wind = 83', 1, true) ~= nil, true)
    check('...and no Dark one', text:find('stat_Dark', 1, true), nil)

    f = assert(io.open(path, 'w'))
    f:write('stat_Wind = win\n')        -- a verdict: an inline edit only
    f:write('stat_Fire = 0\n')          -- not a plausible stat
    f:write('stat_Ice = 1000\n')        -- nor is that
    f:write('stat_Dark = 50\n')         -- Dark compares MP, read live
    f:close()
    cfg.stat_check.Wind, cfg.stat_check.Water = 83, nil
    api.loadSettings()
    check('a verdict in the file is ignored', cfg.stat_check.Wind, 83)
    check('...and a stat out of range', cfg.stat_check.Fire, nil)
    check('...at either end', cfg.stat_check.Ice, nil)
    check('...and Dark is not a stat key', cfg.stat_check.Dark, nil)
    cfg.stat_check.Wind = nil

    -- Restore defaults puts the INLINE values back and writes them out
    api.restoreDefaults()
    check('restore brings back the scale', cfg.ui_scale, 100)
    check('restore brings back the warn', cfg.warn_at, 25)
    check('restore brings back a bool', cfg.show_reasoning, true)
    cfg.ui_scale = 999
    api.loadSettings()
    check('restore was written, not just applied', cfg.ui_scale, 100)
    check('restore turns logging back off', cfg.logging, false)
    check('restore turns the prediction lines back off', cfg.debug_predictions, false)
    check('restore clears the stat you set', cfg.stat_check.Wind, nil)
    suiteLogging()

    -- a missing file is not an error: the inline defaults simply stand
    os.remove(path)
    check('no file is not a failure', api.loadSettings(), false)
    check('no file keeps the defaults', cfg.ui_scale, 100)
end
