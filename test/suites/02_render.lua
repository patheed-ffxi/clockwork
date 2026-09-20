-- ------------------------------------------------------------ render smoke --
-- The whole window draws with the equipped row selected, then with a saved
-- set selected. Errors here are nil calls on the imgui stub - add the
-- missing name to RETURNS, do not loosen the addon.
do
    send044({ head = 2, frame = 33, attachments = { 5, 1, 98 }, heads = 2 ^ 2, frames = 2 ^ 1, owned = { 1, 5, 98 } })
    api.saveSet('VE tank', api.equippedSet())
    api.refreshSets()
    api.selectSet(nil)
    frame('smoke equipped')
    check('render loadout tab', saw('BTN:LO##cw_tab'), true)
    check('render no list box', saw('WINDOW:cw_sets'), false)
    check('render dropdown', saw('WINDOW:##cw_set'), true)
    check('render equipped item', saw('BTN:equipped'), true)
    check('render set item', saw('BTN:VE tank'), true)
    check('render set marked equipped', sawExact('equipped'), true)
    check('render save button', saw('BTN:Save...##cw_savebtn'), true)
    check('render attuner cost', sawExact('Fi2'), true)
    check('render armor plate cost', sawExact('Ea2'), true)
    -- one line of eight cells: Attuner 2 + Strobe 1 against head 3 + frame 4
    check('render capacity cell', sawExact('Fi3/7'), true)
    check('render no apply for equipped', saw('BTN:Apply##cw_apply'), false)
    check('render oils', saw('no oils'), true)
    -- columns start at the padding origin: left name at 8+20, right at 186+20,
    -- second capacity cell at 8 + 364/8 (SameLine offsets are from the window edge)
    check('render left name column', sawExact('X:28'), true)
    check('render capacity second cell', sawExact('X:53.5'), true)
    -- nothing may size itself from the window: with AlwaysAutoResize that
    -- ratchets the width up every frame (the Status table did)
    check('render no window-relative sizing', availCalls, 0)
    -- the Status table only draws with a maneuver up: one Fire maneuver
    world.icons, world.timers = { 300 }, { 0 }
    frame('smoke maneuver')
    check('render no window-relative sizing with a maneuver', availCalls, 0)
    -- the vitals are drawn shapes now: a track and a fill per bar, three bars
    check('vitals drawn as rects', countExact('RECT') >= 6, true)
    -- the element is its gem. No texture is loadable in this frame, so the
    -- gem falls back to its two-letter token - which is still not the word.
    check('table draws the element as a token', sawExact('Fi'), true)
    check('one gives, never two', countExact('gives') <= 1, true)
    -- The WS, gives and oils lines each have a switch, and off draws none of
    -- it: gives neither in the recast column nor on the line under the table.
    check('the WS line is drawn', sawExact('WS'), true)
    check('the gives list is drawn', countExact('gives'), 1)
    check('the oils line is drawn', saw('no oils'), true)
    api.config.show_ws, api.config.show_gives, api.config.show_oils = false, false, false
    frame('smoke lines hidden')
    check('show_ws off drops the WS line', sawExact('WS'), false)
    check('show_gives off drops the gives list', countExact('gives'), 0)
    check('show_oils off drops the oils line', saw('no oils'), false)
    api.config.show_ws, api.config.show_gives, api.config.show_oils = true, true, true
    frame('smoke maneuver')
    -- 1.7.0: the maneuver list is laid out with explicit column offsets, not an
    -- ImGui table - that squeezed its LAST column to a single character,
    -- and BeginTable's width negotiation is the one thing a stubbed ImGui cannot
    -- reproduce. These offsets it can.
    check('list draws the overload header', sawExact('OL%'), true)
    check('list old overload header is gone', sawExact('if cast'), false)
    check('list draws no element word', sawExact('element'), false)
    -- origins are cumulative: HUD_PAD 8, then the widest cell (a constant 20 in
    -- the stub) plus EL_GAP 10 for each column before it - except the gem
    -- column, which is one glyph wide (tm.px('text'), 18 at the stub's base 14)
    -- because the element is drawn, not spelled.
    -- one maneuver up, so one row: the header positions each column once and
    -- the row once. Counting, because dropping either SameLine leaves the other
    -- behind and a bare 'was it called' is satisfied by that. The gem column is
    -- the exception: it has no heading, so only the row places it.
    check('list column 2 origin, the row alone', countExact('X:38'), 1)
    check('list column 3 origin, header and row', countExact('X:66'), 2)
    check('list column 4 origin, header and row', countExact('X:96'), 2)
    check('list column 5 origin, header and row', countExact('X:126'), 2)
    check('list draws the slot header', sawExact('#'), true)
    -- ...and again at real text widths, where the columns are no longer all the
    -- same size. 8, +7+10, +18+10 (the gem), +28+10, +42+10: 'burden' is the
    -- one column whose HEADER is wider than any cell it holds, so this is also
    -- what proves the origins take the wider of the two rather than the narrower.
    world.textWidth = true
    frame('list at real text widths')
    check('list origins follow the font', countExact('X:143'), 2)
    check('list origins take the wider of header and cell', countExact('X:122'), 0)
    world.textWidth = nil
    -- Every offset scales together since 1.17.0: the panel's own width is
    -- tm.s(config.base_width), so the SCALE is the only thing that can move
    -- either of these, and it moves both. At 120% hudPad is 10 and hudInner
    -- 436, so the grid's cost column sits at 10 + 436/2 - tm.s(34) = 187.
    api.config.ui_scale = 120
    frame('scale 120')
    check('the grid cost column at 120%', sawExact('X:187'), true)
    -- The list's origins are cumulative off the text (20 a string in this stub)
    -- and tm.s(10) of gap, so its fifth column lands at 139 rather than 126.
    -- Before 1.7.0 the table stretched across the panel and gave every column
    -- ~73px; it still sizes to its own contents, they are just bigger now.
    check('list columns scale with the HUD', countExact('X:139'), 2)
    -- ...and nothing is drawn at the old maneuver-count origin, half - tm.s(24)
    -- past the row start (the count left the grid for the Status tab)
    check('no maneuver count beside an attachment', sawExact('X:199'), false)
    api.config.ui_scale = 80
    frame('scale 80')
    -- and down: hudPad 6, hudInner 292, so 6 + 146 - tm.s(34) = 125. Fixed
    -- (through 1.12.8) the second column's rightmost cell fell past the content
    -- edge of any panel narrower than the 380 default and never drew.
    check('the grid cost column follows the scale down', sawExact('X:125'), true)
    check('list columns follow it down', countExact('X:112'), 2)
    api.config.ui_scale = 100
    world.icons, world.timers = nil, nil

    -- --------------------------------------------------- idle burden rows --
    -- A row with no maneuver up and a 0% chance on the next one is in the
    -- table only to carry its burden number. hide_zero_ol_rows drops it.
    -- A maneuver that IS up keeps its burden whatever the chance reads, and a
    -- row that can still overload is never hidden.
    local model, was = api.model(), {}
    for _, el in ipairs({ 'Fire', 'Ice', 'Earth' }) do was[el] = model.burden[el] end
    world.icons, world.timers = { 300 }, { 0 }      -- one Fire maneuver, nothing else
    model.burden.Fire, model.burden.Ice, model.burden.Earth = 40, 1, 30
    frame('idle burden shown')
    check('the idle 0% row draws by default', sawExact('Ic'), true)
    check('the idle row that can overload draws', sawExact('Ea'), true)
    api.config.hide_zero_ol_rows = true
    frame('idle burden hidden')
    check('hide_zero_ol_rows drops the 0% row', sawExact('Ic'), false)
    check('hide_zero_ol_rows keeps a row that can overload', sawExact('Ea'), true)
    check('hide_zero_ol_rows keeps the maneuver that is up', sawExact('Fi'), true)
    -- the same element at 0%, but its maneuver is up: the row stays
    model.burden.Fire, model.burden.Earth = 1, 1
    frame('idle burden hidden, nothing left to show')
    check('hide_zero_ol_rows keeps a live maneuver at 0%', sawExact('Fi'), true)
    check('hide_zero_ol_rows drops the last idle row', sawExact('Ea'), false)
    -- nothing up and every idle row hidden: the empty line may not claim
    -- there is no burden, because there is - it is just harmless.
    world.icons, world.timers = nil, nil
    frame('idle burden hidden, nothing up')
    check('the hidden-row empty line says no risk', sawExact('no maneuvers, no risk'), true)
    check('the hidden-row empty line does not deny the burden', sawExact('no maneuvers, no burden'), false)
    -- ...and with no burden at all it is the original line again
    model.burden.Fire, model.burden.Ice, model.burden.Earth = 0, 0, 0
    frame('idle burden hidden, nothing at all')
    check('a truly empty table keeps its own line', sawExact('no maneuvers, no burden'), true)
    api.config.hide_zero_ol_rows = false
    for el, v in pairs(was) do model.burden[el] = v end

    api.selectSet('VE tank')
    frame('smoke saved')
    check('render saved cost', sawExact('Fi2'), true)
    check('render apply button', saw('BTN:Apply##cw_apply'), true)
    check('render no not-owned', saw('not owned'), false)
end

-- ----------------------------------------------------- render: target row --
-- The automaton's target and its HP, under the vitals. petTarget is the gate:
-- an automaton that has acted on nothing draws no row at all.
do
    petOut()
    api.setPetTarget(0)
    frame('target none')
    check('no target row at rest', saw('Steelshell Crab'), false)
    -- An automaton that is fighting nothing says so. It used to draw no row at
    -- all, which left the panel changing height; worse, a target that had died
    -- but was still in the entity table read as a live one at 0%.
    check('idle says so outright', saw('NOT ENGAGED'), true)

    -- engaged: the mob's name and its HP percent, off the entity table
    api.setPetTarget(MOB)
    world.mobHpp = 62
    frame('target engaged')
    check('target row names the mob', saw('Steelshell Crab'), true)
    check('target row draws the percent', sawExact('62%'), true)
    -- the automaton's own name is still on the line above it: the per-index
    -- GetName stub is what lets these two be told apart at all
    check('target row keeps the automaton name', saw('Bobeche'), true)
    -- the name column is a third of the content width, and the bar starts there
    check('target row bar origin', sawExact('X:129.33333333333'), true)
    -- Still in the entity table at zero: dead, not on 0% of its health - the
    -- server never reports a living mob below 1, so a bar there is a live-
    -- looking readout for something that is not there.
    world.mobHpp = 0
    frame('target dead')
    check('a dead target is not engaged', saw('NOT ENGAGED'), true)
    check('and draws no bar for it', saw('Steelshell Crab'), false)
    world.mobHpp = 62

    -- out of the entity table - too far to render, or dead. The last name is
    -- kept rather than blanking the row on a one-frame flap.
    world.mobIndex = nil
    frame('target out of sight')
    check('target row survives a lost slot', saw('Steelshell Crab - out of sight'), true)
    check('target row drops the bar when unreadable', sawExact('62%'), false)
    -- The rescan covers the dynamic band too. Static mobs sit in 0-0x3FF,
    -- players in 0x400-0x6FF, and 0x700-0x8FF holds pets and the mobs the
    -- server builds at runtime - battlefields, script pops - which the old
    -- 0-1023 walk never reached, so a fight there read 'out of sight' until
    -- expireTarget gave up on it. Once a second, hence the advances.
    world.mobIndex = 0x750
    advance(1)
    frame('target in the dynamic band')
    check('target row reads a mob in the dynamic band', sawExact('62%'), true)
    world.mobIndex = 0x500
    advance(1)
    frame('target in the player band')
    check('the player band is not walked', sawExact('62%'), false)
    world.mobIndex = 9
    advance(1)
    frame('target back in the static band')
    check('target row reads it again', sawExact('62%'), true)

    -- A new target that never resolves must not wear the old one's name. The
    -- cached name is stamped with the id it was read for, so this reads '?'
    -- rather than the mob before it - which is what made a moved-on target
    -- look stuck.
    api.setPetTarget(MOB)
    world.mobHpp = 62
    frame('name cached')
    check('the resolved name is cached', saw('Steelshell Crab'), true)
    api.setPetTarget(MOB + 77)   -- not in the entity table
    frame('new target unresolved')
    check('an unresolved new target is not the old one', saw('Steelshell Crab'), false)
    check('it draws as unknown instead', saw('? - out of sight'), true)

    -- The target dies. petTarget is only ever ASSIGNED - by an action the
    -- automaton takes - so a death has to take it away, or the row names the
    -- corpse until the automaton is dismissed. Keyed on the death message's
    -- TARGET, so a party member's killing blow ends it just as ours does.
    api.setPetTarget(MOB)
    world.mobHpp = 62
    frame('target before death')
    check('engaged before the kill', api.petTarget(), MOB)
    send029(PET, MOB, 0, 6)   -- DEFEATS_TARG, our automaton kills it
    frame('target died')
    check('a killed target ends the engagement', api.petTarget(), 0)
    check('and the row says NOT ENGAGED', saw('NOT ENGAGED'), true)
    -- somebody else's kill, on a target we never see die ourselves
    api.setPetTarget(MOB)
    frame('target re-engaged')
    send029(MOB + 5, MOB, 0, 6)
    frame('someone else killed it')
    check('a party kill ends it too', api.petTarget(), 0)
    -- ...and a death that names a DIFFERENT mob leaves ours alone
    api.setPetTarget(MOB)
    frame('target re-engaged again')
    send029(PET, MOB + 5, 0, 6)
    frame('a different mob died')
    check('another mobs death leaves the target', api.petTarget(), MOB)

    -- Not every target ends in a death message we see: a depop, a deaggro, or
    -- a kill out of range leaves the id naming an entity that is gone. The
    -- backstop is time - unreadable for TARGET_GRACE and the fight is over -
    -- and the grace is what keeps a one-frame slot flap from ending it.
    world.mobIndex = nil
    advance(2) frame('gone briefly')
    check('a brief flap does not end the fight', api.petTarget(), MOB)
    check('and the row still names the mob', saw('Steelshell Crab - out of sight'), true)
    -- the grace runs from when the loss was first NOTICED, not from the frame
    -- the slot went: the check is throttled to once a second.
    advance(11) frame('gone for good')
    check('an unreadable target expires', api.petTarget(), 0)
    check('and the stuck out-of-sight row is gone', saw('out of sight'), false)
    world.mobIndex = 9
    -- ...and coming back inside the grace resets the clock rather than
    -- spending it: a target that flaps every few seconds is still a fight.
    api.setPetTarget(MOB)
    frame('target re-engaged once more')
    world.mobIndex = nil
    advance(6) frame('gone once')
    world.mobIndex = 9
    advance(1) frame('back')
    world.mobIndex = nil
    advance(6) frame('gone twice')
    check('the grace restarts when the target comes back', api.petTarget(), MOB)
    world.mobIndex = 9
    advance(1) frame('back for good')

    -- The grace belongs to ONE target. A new target that is itself unreadable
    -- on first sight used to inherit the clock the last one had nearly run
    -- down, and expired on its second check - the row blanked and the ladder
    -- read the automaton as disengaged in the middle of a fight.
    world.mobIndex = nil
    advance(1) frame('gone, noticed')
    advance(8) frame('gone for nine seconds')
    check('the first target is still inside its grace', api.petTarget(), MOB)
    api.setPetTarget(MOB + 9)              -- a new target, not in the entity table
    advance(1) frame('new target, unreadable')
    advance(1) frame('new target, two seconds in')
    check('a new target does not inherit the old clock', api.petTarget(), MOB + 9)
    check('and the row says it is out of sight', saw('? - out of sight'), true)
    advance(9) frame('new target gone for good')
    check('...and it expires on its own clock', api.petTarget(), 0)
    -- ...and the other way a target can change under a running clock: a
    -- death clears it on the packet thread and an action names a new one
    -- before the next frame. The new id gets its own clock just the same.
    api.setPetTarget(MOB)
    advance(1) frame('engaged again')
    world.mobIndex = nil
    advance(1) frame('gone, noticed again')
    advance(8) frame('gone for nine seconds again')
    send029(PET, MOB, 0, 6)                -- it dies out of sight...
    api.setPetTarget(MOB + 10)             -- ...and the automaton is on another at once
    advance(1) frame('new target after a death')
    advance(1) frame('new target after a death, two seconds in')
    check('a target named right after a death has its own clock', api.petTarget(), MOB + 10)
    advance(9) frame('and it too expires in its own time')
    check('...which runs out on its own', api.petTarget(), 0)
    world.mobIndex = 9

    -- and the setting turns the whole row off
    api.config.show_target = false
    frame('target row off')
    check('target row off draws nothing', saw('Steelshell Crab'), false)
    api.config.show_target = true

    -- ...and at rest again, now that a name HAS been cached: without the
    -- petTarget guard the row falls through to its out-of-sight arm and draws
    -- the last mob it saw, which is the failure the first check above is too
    -- early to see.
    api.setPetTarget(0)
    frame('target none again')
    check('no row at rest once a name is known', saw('Steelshell Crab'), false)
    check('no out-of-sight row at rest', saw('out of sight'), false)
    check('and it says NOT ENGAGED instead', saw('NOT ENGAGED'), true)
    world.mobHpp = nil
    petIn()   -- the Loadout preview reasons below need no automaton out
end

-- ------------------------------------------------------------- compact --
-- One line: its own window, so its position is its own; the switch is a
-- button on either layout, a command, and a Settings pill, all of which
-- write the same file. Its own automaton and target, since the block above
-- puts both away when it is done.
do
    local cfg = api.config
    petOut()
    api.setPetTarget(MOB)
    world.mobHpp = 62
    world.pngAvailable = true   -- or every gem falls back to its token
    api.resetIcons()
    cfg.compact = true
    frame('compact')
    check('compact draws its own window', saw('WINDOW:clockwork compact'), true)
    check('compact does not draw the panel', sawExact('WINDOW:clockwork'), false)
    check('compact draws the gems', saw('IMG:'), true)
    check('compact draws a gem cell', saw('BTN:Fire##cw_gem'), true)
    check('compact offers the way back', saw('BTN:full##cw_layout'), true)
    check('compact no window-relative sizing', availCalls, 0)
    world.hover = 'Fire##cw_gem'
    frame('compact hover')
    check('a gem carries its facts on hover', saw('TIP:Fire'), true)
    -- ImGui's SetTooltip is printf: a bare % in the text is a conversion, not a
    -- character. `cast now: 10% overload` came out as
    -- `cast now: 46756014verload` - the `% o` eaten as an octal, the number
    -- whatever was next on the stack. tip() doubles them on the way in; nothing
    -- may reach ImGui with a single one.
    local tips = 0
    for _, d in ipairs(drawn) do
        if tostring(d):sub(1, 4) == 'TIP:' then
            tips = tips + 1
            check('the tooltip escapes its percent signs',
                  (tostring(d):gsub('%%%%', '')):find('%%'), nil)
        end
    end
    check('a tooltip was recorded at all', tips > 0, true)
    world.hover = nil
    clicks['full##cw_layout'] = true
    frame('compact switch')
    check('the button returns to the panel', cfg.compact, false)
    check('and wrote the file', api.loadSettings() and cfg.compact, false)
    handlers['command']({ command = '/cw compact' })
    check('/cw compact flips it', cfg.compact, true)
    cfg.compact = false
    check('/cw compact wrote the file', api.loadSettings() and cfg.compact, true)
    cfg.compact = false
    api.saveSettings()
    frame('full again')
    check('the panel offers the strip', saw('BTN:C##cw_layout'), true)
    check('settings drops the compact pill', saw('BTN:compact layout##cw_set_compact'), false)
    world.pngAvailable = nil
    api.resetIcons()
    world.mobHpp = nil
    api.setPetTarget(0)
    petIn()
end

-- ------------------- the header's close, /cw show, and Tuning's stat checks --
-- Six details of the header and the Tuning tab: the panel closes from its own
-- corner rather than a switch buried in Settings, /cw show is that switch, the
-- ids row goes, Tuning states every element's stat check rather than only the
-- ones with a maneuver up, and two tooltips say how the model picks the weaponskill.
do
    local cfg = api.config
    petOut()
    api.selectTab('all')
    frame('the asks')
    check('the panel closes from its own corner', saw('BTN:x##cw_close'), true)
    check('settings drops the panel switch', saw('BTN:show the panel'), false)
    check('tuning drops the ids row', saw('ids   self'), false)
    local src = (function()
        local f = assert(io.open(ADDON_DIR .. '/cw/ui/panel.lua', 'r'))
        local t = f:read('*a')
        f:close()
        return t
    end)()
    check('oils name the Maintenance grade',
          src:find('Maintenance needs +2 or better', 1, true) ~= nil, true)
    check('the oils tooltip drops the ammo sentence',
          src:find('AMMO slot', 1, true), nil)
    local loadoutSrc = (function()
        local f = assert(io.open(ADDON_DIR .. '/cw/ui/loadout.lua', 'r'))
        local t = f:read('*a')
        f:close()
        return t
    end)()
    check('the loadout offers the gear route',
          loadoutSrc:find('equip or unequip any piece of gear or an attachment', 1, true) ~= nil, true)

    -- /cw show is the switch; the burden dump keeps the bare command and gains
    -- its own name
    check('the panel starts shown', cfg.show_window, true)
    handlers['command']({ command = '/cw show' })
    check('/cw show hides the panel', cfg.show_window, false)
    frame('hidden')
    check('and nothing draws', saw('WINDOW:clockwork'), false)
    handlers['command']({ command = '/cw show' })
    check('/cw show brings it back', cfg.show_window, true)
    check('/cw show wrote the file', api.loadSettings() and cfg.show_window, true)
    while #printed > 0 do table.remove(printed) end
    handlers['command']({ command = '/cw' })
    local dumped = false
    for _, p in ipairs(printed) do if p:find('burden', 1, true) then dumped = true end end
    check('the bare command still dumps the burden', dumped, true)
    check('and the panel is untouched by it', cfg.show_window, true)
    -- the close button is the same switch
    clicks['x##cw_close'] = true
    frame('closed from the corner')
    check('the corner closes the panel', cfg.show_window, false)
    cfg.show_window = true
    api.saveSettings()
    petIn()
    -- ...and so is the sidebar's own x: the ? button saves the sidebar, so a
    -- sidebar closed from its x must not come back on the next load
    cfg.sidebar = true
    api.saveSettings()
    frame('sidebar open')
    clicks['x##cw_sideclose'] = true
    frame('sidebar closed from its x')
    check('the sidebar x closes it', cfg.sidebar, false)
    check('the sidebar x wrote the file', api.loadSettings() and cfg.sidebar, false)
end

-- --------------------------------------------------- render: not logged in --
-- The character screen keeps the last character's job, party slot and entity
-- table, so every gate the HUD used to consult still said "PUP, in a party, in
-- the world" and it drew on top of the character list. GetLoginStatus is the
-- one read that says otherwise: 0 at title/character select, 1 while loading.
do
    api.resetSwallowed()
    for _, status in ipairs({ 0, 1 }) do
        world.login = status
        frame('login status ' .. status)
        check('nothing draws at login status ' .. status, saw('WINDOW:clockwork'), false)
    end
    world.login = 2
    frame('logged back in')
    check('and it comes back in game', saw('WINDOW:clockwork'), true)
    check('no native read was swallowed getting there', api.swallowed(), 0)
end

-- ------------------------------------------------------ render: bad file --
-- A file that does not parse caches as false; the preview must say so rather
-- than fall through to "select a set" - `selected and cache[selected] or nil`
-- turns false into nil.
do
    local f = assert(io.open(SCRATCH .. '/config/addons/clockwork/sets/bad.txt', 'w'))
    f:write('Valoredge Head\n')
    f:close()
    api.refreshSets()
    api.selectSet('bad')
    drawn = {}
    handlers['d3d_present']()
    check('render bad file message', saw('did not parse'), true)
end

-- ------------------------------------------------------------ render paths --
-- Every click handler and preview state the smoke test does not reach, with
-- Begin/End balance checked on every frame. Entering: 'VE tank' and 'bad'
-- saved, 'bad' selected, the 0x044 with the VE set.
do
    local function writeSet(name, text)
        local f = assert(io.open(SCRATCH .. '/config/addons/clockwork/sets/' .. name .. '.txt', 'w'))
        f:write(text)
        f:close()
        api.refreshSets()
        api.selectSet(name)
    end

    -- BeginChild and Begin answering false still get their End
    answerFalse.BeginChild = true
    frame('child answers false')
    answerFalse.BeginChild = nil
    answerFalse.Begin = true
    frame('window answers false')
    answerFalse.Begin = nil

    -- no saved sets: the equipped row alone, previewed live, name hint shown
    api.deleteSet('VE tank')
    api.deleteSet('bad')
    api.refreshSets()
    typed = ''
    frame('no sets')
    check('no sets equipped row', saw('BTN:equipped'), true)
    check('no sets live preview', sawExact('Ea2'), true)
    check('no sets name hint', saw('type a name'), true)

    -- Save current with a typed name
    typed = 'new set'
    frame('typed name')
    clicks['Save current##cw_save'] = true
    frame('save click')
    check('saved exists', api.setExists('new set'), true)
    check('saved printed', (printed[#printed] or ''):find('saved set new set', 1, true) ~= nil, true)
    frame('after save')
    check('saved listed', saw('BTN:new set'), true)
    check('saved marked equipped', sawExact('equipped'), true)

    -- overwrite takes a second click
    local before = #printed
    clicks['Save current##cw_save'] = true
    frame('overwrite first click')
    frame('overwrite label')
    check('overwrite asks', saw('BTN:Overwrite?##cw_save'), true)
    clicks['Overwrite?##cw_save'] = true
    frame('overwrite second click')
    check('overwrite saved once', #printed, before + 1)

    -- rename
    typed = 'renamed'
    frame('typed rename')
    clicks['Rename##cw_rename'] = true
    frame('rename click')
    check('renamed exists', api.setExists('renamed'), true)
    check('old name gone', api.setExists('new set'), false)

    -- delete takes a second click, then the equipped row is back
    clicks['Delete##cw_delete'] = true
    frame('delete first click')
    frame('delete label')
    check('delete asks', saw('BTN:Really delete?##cw_delete'), true)
    clicks['Really delete?##cw_delete'] = true
    frame('delete second click')
    check('deleted', api.setExists('renamed'), false)
    frame('after delete')
    check('after delete live preview', sawExact('Ea2'), true)
    check('after delete no apply', saw('BTN:Apply##cw_apply'), false)

    -- unknown names: red names, the not-owned line, the unknown-head reason
    writeSet('odd', 'Nope Head\nValoredge Frame\nNope\nStrobe\n')
    frame('odd file')
    check('odd not owned line', saw('not owned: Nope Head, Nope'), true)
    check('odd reason', saw('unknown head or frame'), true)

    -- over capacity: Fire 8 against Valoredge's 7
    writeSet('hot', 'Valoredge Head\nValoredge Frame\nAttuner\nTension Spring II\nStrobe\nTension Spring\nInhibitor\nFlame Holder\n')
    frame('hot file')
    check('hot over capacity', saw('over capacity'), true)
    check('hot fire cell', sawExact('Fi8/7'), true)

    -- eight attachments fill the right column: its names start at 186+20
    writeSet('full', 'Valoredge Head\nValoredge Frame\nArmor Plate\nStrobe\nAttuner\nInhibitor\nTension Spring\nTension Spring II\nFlame Holder\nArmor Plate II\n')
    frame('full file')
    -- HUD_PAD + hudInner()/2 + the index gutter: 8 + 182 + 20
    check('render right name column', sawExact('X:210'), true)
    check('full slot twelve absent', sawExact('12'), false)

    -- a good set, then the automaton out
    typed = 'good'
    frame('typed good')
    clicks['Save current##cw_save'] = true
    frame('save good')
    check('good saved', api.setExists('good'), true)
    world.petIndex, world.petId = 5, 0x01000200
    frame('pet out')
    check('pet reason', saw('deactivate first'), true)
    world.petIndex, world.petId = 0, 0

    -- a 0x044 naming no head: nothing to save; the equipped row from the buffer
    send044({ head = 0, frame = 0 })
    api.selectSet(nil)
    frame('no head')
    check('no head save hint', saw('no automaton data'), true)
    check('no head buffer fallback', saw('showing the client copy'), true)
    check('no head note wraps at the panel', sawExact('WRAP:372'), true)
    api.selectSet('good')
    frame('no head saved set')
    check('no head reason', saw('head or frame not owned'), true)

    -- Apply through the button; the status line through its states
    send044({ head = 2, frame = 33, attachments = { 5, 1, 98 }, heads = 2 ^ 2 + 2 ^ 3, frames = 2 ^ 1, owned = { 1, 3, 5, 98 } })
    writeSet('swap', 'Sharpshot Head\nValoredge Frame\nAttuner\nStrobe\nInhibitor\n')
    world.equipCalls, world.task = {}, nil
    frame('swap ready')
    check('swap apply button', saw('BTN:Apply##cw_apply'), true)
    clicks['Apply##cw_apply'] = true
    frame('apply click')
    check('apply task started', world.task ~= nil, true)
    frame('apply running')
    check('apply status starting', saw('starting'), true)
    local server = { head = 2, frame = 33, attachments = { 5, 1, 98, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
                     heads = 2 ^ 2 + 2 ^ 3, frames = 2 ^ 1, owned = { 1, 3, 5, 98 } }
    local answered = 0
    for _ = 1, 60 do
        if coroutine.status(world.task) == 'dead' then break end
        assert(coroutine.resume(world.task))
        if #world.equipCalls > answered then
            local c = world.equipCalls[#world.equipCalls]
            answered = #world.equipCalls
            local index, id = c[3], c[4]
            if index == 0 then server.head = id
            elseif index == 1 then server.frame = id
            else server.attachments[index - 1] = id end
            send044(server)
        end
        advance(0.1)
        frame('apply mid ' .. answered)
    end
    check('apply finished', coroutine.status(world.task), 'dead')
    frame('apply done')
    check('apply done status', saw('done - 3 changes'), true)
    check('apply recast note', saw('Activate is on its 60s swap recast'), true)
    check('apply calls', #world.equipCalls, 3)

    -- not PUP: the window is not drawn at all
    world.mainjob, world.subjob = 1, 0
    frame('not pup')
    check('not pup draws nothing', saw('WINDOW:clockwork'), false)
    world.mainjob = 18
end

-- ---------------------------------------------------------- element icons --
-- With the maneuver status icons loadable, the grid's cost cells and the
-- capacity line draw them and keep only the numbers; without them (every
-- frame above) the two-letter tokens stand in. Entering: the equipped row
-- is Sharpshot head, Valoredge frame, Attuner, Strobe, Inhibitor - Fire 4/7.
do
    -- the PNG files first
    world.pngAvailable = true
    api.resetIcons()
    api.selectSet(nil)
    frame('element icons from files')
    check('icons drawn', saw('IMG:'), true)
    check('icons asked for the addon file', (world.lastPng or ''):find('/assets/elements/', 1, true) ~= nil, true)
    check('icons replace the cost token', sawExact('Fi2'), false)
    check('icons keep the cost digit', sawExact('2'), true)
    check('icons replace the capacity token', sawExact('Fi4/7'), false)
    check('icons keep the capacity numbers', sawExact('4/7'), true)
    check('icons replace the table element token', sawExact('Fi'), false)
    -- no files: the maneuver status icons
    world.pngAvailable, world.iconsAvailable = nil, true
    api.resetIcons()
    frame('element icons from status icons')
    check('fallback icons drawn', saw('IMG:'), true)
    check('fallback icons replace the token', sawExact('Fi2'), false)
    -- neither: the tokens
    world.iconsAvailable = nil
    api.resetIcons()
    frame('element tokens')
    check('tokens without icons', sawExact('Fi2'), true)
end

-- ---------------------------------------------------------- inhibitor hold --
-- With Inhibitor on (world.buffer's default set has it) and the master at or
-- above 900 TP, the prediction is the TP hold. It never was before 1.5.1:
-- hasAttachment_fwd was assigned before the function existed.
do
    api.selectSet(nil)
    world.tp = 1000
    frame('inhibitor hold')
    check('inhibitor hold predicted', saw('holding TP'), true)
    world.tp = 0
    frame('inhibitor no hold')
    check('inhibitor no hold below 900', saw('holding TP'), false)
end
