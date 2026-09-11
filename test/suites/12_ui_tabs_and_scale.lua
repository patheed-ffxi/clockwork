-- ---------------------------------------------------------------- tabs --
-- Four buttons on the name line drive tm.tab; the ImGui tab bar is gone.
-- 'all' is the harness's own value so every tab still draws each frame.
do
    -- one Fire maneuver up, or the maneuver table has no row to head
    petOut()
    world.icons, world.timers = { 300 }, { 0 }
    api.selectTab('status')
    frame('status tab')
    check('status draws the table header', sawExact('OL%'), true)
    check('status does not draw the loadout', saw('BTN:Save...##cw_savebtn'), false)
    check('the tab buttons are on the header', saw('BTN:LO##cw_tab') and saw('BTN:SE##cw_tab'), true)
    -- The Settings tab is a drawn cog: six teeth, a body and a punched hub.
    -- ImGui's default glyph range is ASCII, so no typeface could have
    -- supplied one - a U+2699 would draw as a box.
    drawn = {}
    api.cog(10, 10, 6, { 1, 1, 1, 1 })
    check('the cog has a body and a hub', countExact('CIRC'), 2)
    check('the cog has six teeth', countExact('RECT'), 6)
    clicks['LO##cw_tab'] = true
    frame('tab click')
    check('the button switched the tab', api.tab(), 'loadout')
    frame('loadout tab')
    check('loadout draws its dropdown', saw('WINDOW:##cw_set'), true)
    check('loadout does not draw the table', sawExact('OL%'), false)
    api.selectTab('all')
    world.icons, world.timers = nil, nil
end

-- ------------------------------------------------------------- surface --
-- The typeface: loaded once on the load event, three sizes off the base,
-- the default font when a file is missing - said once, never fatal.
do
    check('font loaded on load', api.font() ~= nil, true)
    check('label size from the base', api.px('label'), 14)
    check('text size from the base', api.px('text'), 18)
    check('head size from the base', api.px('head'), 20)
    RETURNS.AddFontFromFileTTF = function() error('no such file') end
    while #printed > 0 do table.remove(printed) end
    check('missing font reports false', api.fontLoad(), false)
    check('missing font falls back to the default', api.font(), nil)
    local said = false
    for _, p in ipairs(printed) do if p:find('font not found', 1, true) then said = true end end
    check('missing font says so', said, true)
    RETURNS.AddFontFromFileTTF = function() return { font = true } end
    api.fontLoad()
    -- every string on the draw list has a Dummy behind it, or the
    -- auto-resizing window does not know it is there
    frame('surface smoke')
    check('draw-list strings drawn', addTexts > 0, true)
    check('every drawn string is reserved', dummies >= addTexts, true)
    check('DAD is gone', sawExact('DAD'), false)
end

-- ------------------------------------------------------------- the scale --
-- One number magnifies the whole HUD (1.17.0). Two factors, and the point of
-- the block is that they are NOT the same factor: tm.px hands ImGui a base
-- size and ImGui applies its own FontScaleMain/FontScaleDpi on top, so tm.px
-- may only apply ours - while the LAYOUT has to agree with the size the text
-- is actually drawn at, which is both.
do
    local cfg = api.config
    -- the primitive: rounds, and never rounds a real number away
    cfg.ui_scale = 150
    frame('scale 150')
    check('tm.s rounds rather than truncates', api.s(3), 5)     -- 4.5, not 4
    check('tm.s keeps a hairline visible', api.s(1), 2)
    check('tm.s leaves a zero alone', api.s(0), 0)
    -- ...and the font base follows OUR scale
    check('the base size scales', api.px('text'), 26)           -- 14 * 1.5 * 1.25
    -- the panel and everything measured off it
    check('the panel is 570 wide', sawExact('WSIZE:570'), true)
    check('text wraps at the scaled panel', saw('WRAP:558'), true)  -- pad 12 + inner 546
    -- the tuning tab's cost columns, the tightest absolute offsets in the addon
    api.selectTuneTab('cost')
    frame('scale 150 cost')
    check('cost columns scale', saw('X:132') and saw('X:252') and saw('X:342'), true)

    -- 200%: the top of the slider's range, and the width a player actually
    -- reaches on a 4K screen.
    cfg.ui_scale = 200
    frame('scale 200')
    check('the panel is 760 at 200%', sawExact('WSIZE:760'), true)
    check('the base size doubles', api.px('label'), 28)

    -- The player's OWN ImGui scale. ui_scale back to 100, FontScaleMain at
    -- 1.5: ImGui multiplies that onto every size we push, so tm.px must NOT
    -- and the layout MUST. Before 1.17.0 the strings knew about it and the
    -- offsets did not, which drew a bigger clockwork over an unchanged layout.
    cfg.ui_scale = 100
    world.fontScaleMain = 1.5
    frame('global font scale')
    check('the base size ignores the global scale', api.px('text'), 18)
    check('...and the layout does not', saw('WRAP:558'), true)
    check('...so the panel is 570 here too', sawExact('WSIZE:570'), true)
    api.selectTuneTab('cost')
    frame('global font scale cost')
    check('cost columns follow the drawn size', saw('X:132'), true)
    -- and the two stack: 100% * 1.5 is the same as 150% * 1.0, so 150% * 1.5
    -- is 225% - past the slider, but the arithmetic is the arithmetic.
    cfg.ui_scale = 150
    frame('both scales')
    check('the two scales multiply', api.s(100), 225)
    world.fontScaleMain = nil
    cfg.ui_scale = 100
    api.selectTuneTab('model')

    -- Text measured at the size it is pushed at, which is the only way a
    -- scaled column can be checked against the string it has to hold.
    world.fontAware, world.textWidth = true, true
    frame('font aware at 100')
    -- 'burden' is 6 characters and the stub bills 7 each, at the text voice's
    -- 18 over the base 14: 42 * 18/14 = 54.
    check('a string measures at the size it is pushed at', api.fit('burden', 54), 'burden')
    cfg.ui_scale = 200
    frame('font aware at 200')
    -- ...and at 200% the same string is pushed at 35, so it bills 42 * 2.5 = 105
    -- and no longer fits in the room it had.
    check('the same string needs more room when it is bigger', api.fit('burden', 54), 'bur..')
    check('...105 of it', api.fit('burden', 105), 'burden')
    world.fontAware, world.textWidth = nil, nil
    cfg.ui_scale = 100
    frame('back to 100')
    check('the panel is 380 again', sawExact('WSIZE:380'), true)
end

-- ---------------------------------------------------------- settings tab --
-- Last block in the file on purpose: it clicks Reset model, which throws away
-- the burden and the counters every other block was building on.
do
    local cfg = api.config
    frame('settings tab')
    check('settings tab drawn', saw('BTN:SE##cw_tab'), true)
    check('settings has the log switch', saw('BTN:write a log file'), true)
    check('settings has both anomaly channels',
          saw('BTN:anomalies to the file') and saw('BTN:anomalies to chat'), true)
    check('settings has the reasoning switch', saw('BTN:prediction reasoning'), true)
    check('settings has the target switch', saw('BTN:the automaton'), true)
    -- Both numbers are TYPED, not dragged (1.17.1), and both read as the
    -- percentages they are (1.17.2): the box shows '100%', and the change
    -- lands on Enter.
    check('settings has the scale box', saw('TXT:scale##cw_set_ui_scale:100%'), true)
    check('the overload chance is a box too', saw('TXT:warn at##cw_set_warn_at:25%'), true)
    check('neither is a slider now', saw('SLIDER:scale') or saw('SLIDER:warn at'), false)
    check('the width slider is gone', saw('SLIDER:panel width'), false)
    -- EnterReturnsTrue is the only part of 'on Enter' a stub can see: without
    -- it InputText answers true on every keystroke, and a 1 typed on the way
    -- to 150 would be the scale for a frame.
    check('the box applies on Enter', saw('TXTFLAGS:64'), true)

    local scale0 = cfg.ui_scale
    local saves = api.saveCount()
    typedBox['scale##cw_set_ui_scale'] = '150'
    frame('scale typed')
    check('a typed scale applies', cfg.ui_scale, 150)
    check('...and is written once', api.saveCount(), saves + 1)
    frame('after the type')
    check('the box shows what took, with its unit', saw('TXT:scale##cw_set_ui_scale:150%'), true)
    -- the unit comes back in, since that is what the box hands the player to edit
    typedBox['scale##cw_set_ui_scale'] = '120%'
    frame('scale typed with a unit')
    check('a percent sign is not junk', cfg.ui_scale, 120)
    -- out of range is clamped, and the box says so rather than going on
    -- claiming the number that never applied
    typedBox['scale##cw_set_ui_scale'] = '900'
    frame('scale typed high')
    check('a typed scale is clamped', cfg.ui_scale, 200)
    frame('after the clamp')
    check('the box shows the clamp', saw('TXT:scale##cw_set_ui_scale:200%'), true)
    typedBox['scale##cw_set_ui_scale'] = '3'
    frame('scale typed low')
    check('...at both ends', cfg.ui_scale, 75)
    -- a box with no number in it leaves the setting alone rather than zeroing
    -- it, which at a scale of 0 is a HUD with no pixels
    typedBox['scale##cw_set_ui_scale'] = 'banana'
    frame('scale typed junk')
    check('junk leaves the scale alone', cfg.ui_scale, 75)
    -- the overload chance is the same widget
    typedBox['warn at##cw_set_warn_at'] = '40%'
    frame('warn typed')
    check('a typed overload chance applies', cfg.warn_at, 40)
    typedBox['warn at##cw_set_warn_at'] = '500'
    frame('warn typed high')
    check('...and is clamped to a percentage', cfg.warn_at, 100)
    cfg.warn_at = 25
    -- a frame that types nothing changes nothing and writes nothing
    saves = api.saveCount()
    frame('scale untouched')
    check('an untouched box changes nothing', cfg.ui_scale, 75)
    check('...and writes nothing', api.saveCount(), saves)
    cfg.ui_scale = scale0
    check('settings names the log path', saw('config/addons/clockwork'), true)
    -- One path on the tab, not two: the logging column named the log directory
    -- and the foot of the tab named the settings file, both in the same folder.
    local paths = 0
    for _, d in ipairs(drawn) do
        if tostring(d):find('config/addons/clockwork', 1, true) then paths = paths + 1 end
    end
    check('settings names it once, not twice', paths, 1)
    -- and it is drawn at label size rather than wrapped, so it stays one line
    check('the settings path is not wrapped', saw('WRAPPED:saved to'), false)
    check('the settings path is still there', saw('saved to '), true)
    -- /cw verbose still reaches log_all_casts; the switch left the tab
    check('settings drops the verbose switch', saw('BTN:log unrecognised pet skills'), false)
    -- GetInstallPath comes back with a trailing separator and the builders added
    -- their own: `.../Game//config/...` on screen.
    check('no doubled separator in the settings path',
          api.settingsPath():find('//', 1, true), nil)
    check('no doubled separator in the log path',
          api.logPath():find('//', 1, true), nil)
    check('no doubled separator in the sets path',
          api.setsDir():find('//', 1, true), nil)
    check('the prediction switch is plainer', saw('predictions to chat'), true)
    -- Tuning is two views behind two buttons, not one long tab: the error and
    -- the anomaly count are what it is opened for, so `model` is the default
    -- and the per-element stat checks wait behind their own button.
    check('tuning defaults to the model', api.tuneTab(), 'model')
    check('tuning offers both views',
          saw('BTN:model##cw_tune') and saw('BTN:maneuver cost##cw_tune'), true)
    check('tuning shows the model', saw('  anomalies'), true)
    check('tuning holds back the cost', saw('cost 1'), false)
    clicks['maneuver cost##cw_tune'] = true
    frame('tuning cost clicked')
    check('the button switched the view', api.tuneTab(), 'cost')
    frame('tuning cost')
    check('tuning shows the cost', saw('cost 1'), true)
    -- every element, whether or not one is up: a stat check you are losing is
    -- worth knowing BEFORE you cast it
    check('tuning states every stat check', sawExact('  Fire') and sawExact('  Dark'), true)
    check('tuning no longer waits for a maneuver', sawExact('  no maneuvers up'), false)
    check('and holds back the model', saw('  anomalies'), false)
    api.selectTuneTab('model')
    -- the model constants are NOT knobs here, and the tab says where they are
    check('settings offers no burden knob', saw('activate_burden'), false)
    check('settings drops the model paragraph', saw('measured values'), false)
    check('settings drops the reset button', saw('BTN:Reset model##cw_set_reset'), false)
    check('the burden button says what it does', saw('BTN:Zero burden##cw_set_sync'), true)
    check('and neither carries a caption', saw('zeroes burden only'), false)

    -- a click writes through to config AND to the file
    os.remove(api.settingsPath())
    check('reasoning starts on', cfg.show_reasoning, true)
    clicks['prediction reasoning##cw_set_show_reasoning'] = true
    frame('settings toggle')
    check('click flipped the setting', cfg.show_reasoning, false)
    cfg.show_reasoning = true
    check('click wrote the file', api.loadSettings(), true)
    check('file held the flipped value', cfg.show_reasoning, false)
    cfg.show_reasoning = true

    -- the sidebar toggle has a side effect beyond the value
    clicks['what-if sidebar##cw_set_sidebar'] = true
    frame('settings sidebar')
    check('sidebar toggled from the tab', cfg.sidebar, true)
    clicks['what-if sidebar##cw_set_sidebar'] = true
    frame('settings sidebar back')
    check('sidebar toggled back', cfg.sidebar, false)

    -- Restore defaults, twice - the second click is the one that acts
    cfg.ui_scale = 160
    clicks['Restore defaults##cw_set_defaults'] = true
    frame('restore armed')
    check('restore asks first', cfg.ui_scale, 160)
    -- the relabel lands on the NEXT frame: the label is chosen before ImGui
    -- reports the click that arms it. Same shape as the delete test above.
    frame('restore label')
    check('restore relabels while armed', saw('BTN:Really restore?##cw_set_defaults'), true)
    clicks['Really restore?##cw_set_defaults'] = true
    frame('restore confirmed')
    check('restore acted on the second click', cfg.ui_scale, 100)
    suiteLogging()

    -- ...and the model reset, which is why this block is last. Its button left
    -- the tab in 1.12.18 - `/cw reset` was always the same code path, and a
    -- reload clears the lot anyway, none of it being persisted.
    while #printed > 0 do table.remove(printed) end
    handlers['command']({ command = '/cw reset' })
    frame('after the reset')
    local function said(text)
        for _, p in ipairs(printed) do if p:find(text, 1, true) then return true end end
        return false
    end
    check('reset said so', said('anomaly count cleared'), true)
    check('reset zeroed the burden', api.model().burden.Fire, 0)
    check('reset unverified the burden', api.model().verified.Fire, false)
end

-- ----------------------------- what the wait is FOR, while a rung is shut --
-- A shut window used to end the line at "none ready - enhance 6s", which says
-- when but never what. The ladder is run once more with the windows ignored
-- and its answer appended. It stays in the REASON and never becomes the
-- predicted name: the packet thread judges a cast against that name, and a
-- preview standing in for it would turn a real miss into a hit.
do
    local SELF = 0x01000001
    world.hp, world.maxhp, world.petHpp, world.petMpp = 1000, 1000, 100, 100
    world.buffer = { 5, 35, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }
    world.icons, world.timers = { 42, 41, 33 }, { 0, 0, 0 }   -- the master wants a Protect
    advance(10)
    petOut(PET + 98, MOB + 98)
    api.setPetTarget(MOB + 98)
    send044({ head = 5, frame = 35, magic = 250, hp = 600, maxhp = 600, mp = 300, maxmp = 300 })
    send028(act(4, 110, PET + 98, 230, 42))       -- both hold a Regen: no hedge
    advance(25)
    check('queued enhance is open now', (api.predictSpell()), 'Protect IV')
    -- put every enfeeble this head can reach on the mob, so the rung BELOW
    -- enhance has nothing to answer with either (Addle needs skill 337)
    for i, eff in ipairs({ 3, 5, 13, 4, 6, 135 }) do
        send028({ actor = MOB + 98, category = 4, param = 42 + i,
                  targets = { { id = MOB + 98, actions = { { message = 236, param = eff } } } } })
    end
    -- shut the enhance rung with a cast of its own, and let magic reopen
    send028(act(8, 45, SELF))
    advance(6)
    local name, why = api.predictSpell()
    check('queued names no spell while shut', name, nil)
    check('queued says how long', (why or ''):find('enhance', 1, true) ~= nil, true)
    check('queued says what for', (why or ''):find('-> then Protect IV', 1, true) ~= nil, true)
    -- and once it opens again the preview becomes the prediction
    advance(20)
    check('queued becomes the pick', (api.predictSpell()), 'Protect IV')
    -- The preview must leave nothing behind. Set up a state where the REAL
    -- pass cannot hedge - the enhance rung is shut, so it never runs - while
    -- the preview, which ignores windows, does. A Regen taking the window
    -- then has to be an anomaly: the line that went out said "none ready" and
    -- warned of nothing.
    send029(PET + 98, PET + 98, 42, 206)              -- the doll's Regen goes
    send028(act(4, 111, PET + 98))                    -- ...and the server last chose it
    send028(act(8, 44, SELF))                         -- shut the enhance rung again
    advance(6)
    handlers['d3d_present']()
    local n2, w2 = api.predictSpell()
    check('queued still silent', n2, nil)
    check('queued preview mentions the regen', (w2 or ''):find('-> then', 1, true) ~= nil, true)
    check('queued real line does not hedge', (w2 or ''):find('or a Regen', 1, true), nil)
    send028(act(8, 110, SELF))
    check('queued preview did not excuse the cast', CLOCKWORK_TEST.last.kind, 'spell_mispredicted')
    world.icons, world.timers = nil, nil
end
