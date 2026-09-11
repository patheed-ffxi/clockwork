-- ------------------------------------------------------- what-if sidebar --
-- tm.whatIf is the whole hypothesis: LSB onUseManeuver adds the maneuver and,
-- at three already up, calls removeOldestManeuver() first. Pure arithmetic, so
-- it is tested without a world.
do
    local function counts(t)
        local c = {}
        for _, e in ipairs({ 'Fire', 'Ice', 'Wind', 'Earth',
                             'Thunder', 'Water', 'Light', 'Dark' }) do
            c[e] = t[e] or 0
        end
        return c
    end
    local c, ev = api.whatIf(counts({}), {}, 'Fire')
    check('whatIf empty adds one', c.Fire, 1)
    check('whatIf empty evicts nothing', ev, nil)

    c, ev = api.whatIf(counts({ Fire = 1 }), { { element = 'Fire' } }, 'Fire')
    check('whatIf stacks the same element', c.Fire, 2)
    check('whatIf one up evicts nothing', ev, nil)

    c, ev = api.whatIf(counts({ Fire = 1, Ice = 1 }),
                       { { element = 'Fire' }, { element = 'Ice' } }, 'Wind')
    check('whatIf two up evicts nothing', ev, nil)
    check('whatIf two up adds the third', c.Wind, 1)

    -- activeManeuvers sorts by remaining ASCENDING, so entry 1 is the oldest -
    -- the one the server drops.
    local three = { { element = 'Thunder' }, { element = 'Fire' }, { element = 'Ice' } }
    c, ev = api.whatIf(counts({ Thunder = 1, Fire = 1, Ice = 1 }), three, 'Water')
    check('whatIf three up evicts the oldest', ev, 'Thunder')
    check('whatIf the evicted count drops', c.Thunder, 0)
    check('whatIf the cast element is added', c.Water, 1)
    check('whatIf the untouched are kept', c.Fire, 1)

    -- recasting the element that is about to be evicted is a net no-op on the
    -- count, and the panel still has to say it evicts
    c, ev = api.whatIf(counts({ Thunder = 1, Fire = 1, Ice = 1 }), three, 'Thunder')
    check('whatIf recasting the oldest nets zero', c.Thunder, 1)
    check('whatIf recasting the oldest still evicts', ev, 'Thunder')
end

-- The optional `counts` argument, and the tm.windows side effect. The
-- omitted-argument path is the one the LOGGER rides, so it has to be proved
-- unchanged, not assumed.
do
    world.buffer = { 2, 33, 206, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }   -- VE + Heatsink
    advance(2.5)
    petOut()
    world.icons, world.timers = { 305 }, { 0 }                        -- one Water up
    handlers['d3d_present']()
    check('decayRate live reads the live counts', (api.decayRate()), 2)
    check('decayRate with a counts argument', (api.decayRate({ Water = 0 })), 1)
    check('decayRate hypothetical two Water', (api.decayRate({ Water = 2 })), 3)

    -- predictWS: no argument is the live call, and passing the live counts
    -- explicitly must answer identically. melee 120 puts Chimera Ripper and
    -- String Clipper inside the gate and leaves Cannibal Blade (150) and Bone
    -- Crusher (245) outside it, so the pick is decided by maneuvers alone.
    send044({ head = 2, frame = 33, melee = 120 })
    world.icons, world.timers = { 300 }, { 0 }                        -- one Fire up
    handlers['d3d_present']()
    check('predictWS omitted argument is the live call',
          (api.predictWS('Valoredge')), (api.predictWS('Valoredge', { Fire = 1 })))
    check('predictWS follows a hypothetical vector',
          (api.predictWS('Valoredge', { Thunder = 2 })), 'String Clipper')
    world.icons, world.timers = nil, nil
end

-- The hazard: tm.predictSpell publishes tm.windows for the packet thread's cast
-- record. Eight hypothetical calls a frame must not touch it.
do
    -- Mana Booster is Ice and takes 2s more off the MAGIC window per step, so
    -- an Ice hypothetical genuinely changes the summary. Without an attachment
    -- like it the hypothetical and the live string are identical and this test
    -- cannot fail however broken the guard is - the 'would differ' check below
    -- is what keeps it honest.
    world.buffer = { 5, 35, 212, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }    -- Soulsoother + Mana Booster
    advance(2.5)
    petOut(PET + 60, MOB + 60)
    send044({ head = 5, frame = 35, magic = 200, hp = 600, maxhp = 600, mp = 300, maxmp = 300 })
    send028(act(8, 108, PET + 60))            -- a cast start stamps windowAt.magic
    handlers['d3d_present']()
    local before = api.spellWindowsNow()
    check('spell windows published by the live call', before:find('mag') ~= nil, true)
    check('an ice maneuver would move the windows',
          api.spellWindowsSim({ Ice = 1 }) ~= before, true)
    -- the hazard itself: a hypothetical prediction must not publish
    api.predictSpellSim({ Ice = 1 })
    check('a hypothetical prediction leaves tm.windows alone', api.spellWindowsNow(), before)
    api.sidebarRows()
    check('a sidebar pass leaves tm.windows alone', api.spellWindowsNow(), before)
end

-- The signals, each from a set that fires exactly one of them.
do
    local function rowFor(el)
        for _, r in ipairs(api.sidebarRows()) do if r.el == el then return r end end
        return nil
    end
    local function says(el, text)
        local r = rowFor(el)
        if r == nil then return false end
        for _, g in ipairs(r.sig) do if g[2] == text then return true end end
        return false
    end
    -- Scanner (Ice), Shock Absorber (Earth), Heatsink (Water), Flame Holder (Fire)
    world.buffer = { 2, 33, 210, 209, 206, 7, 0, 0, 0, 0, 0, 0, 0, 0 }
    advance(2.5)
    petOut(PET + 61, MOB + 61)
    api.clear044()
    handlers['d3d_present']()
    check('sidebar has one row per element', #api.sidebarRows(), 8)
    check('sidebar stoneskin wakes on earth', says('Earth', 'Stoneskin wakes'), true)
    check('sidebar decay moves on water', says('Water', 'decay 1 -> 2/tick'), true)
    check('sidebar flame holder warns on fire', says('Fire', 'the WS will eat it'), true)
    -- and none of them fires on an element it has nothing to do with
    check('sidebar scanner not on earth', says('Earth', 'Scanner arms'), false)
    check('sidebar decay not on fire', says('Fire', 'decay 1 -> 2/tick'), false)
    -- This is a VALOREDGE frame: it never enters the spell ladder at all, so
    -- neither of the two spell-gated signals may promise anything. The Light one
    -- used to fire here and read 'heal at 40%' on an automaton that cannot cast.
    check('no heal threshold on a frame that never casts', says('Light', 'heal at 40%'), false)
    check('no scanner arming on a frame that never casts', says('Ice', 'Scanner arms'), false)
    -- Heatsink states its effect ONCE, as a rate. The 'Burden decay' delta said
    -- the same thing again in the same row, and said it in upstream's numbers.
    check('no duplicate burden decay delta', says('Water', 'Burden decay +1'), false)
    check('no upstream burden decay delta', says('Water', 'Burden decay +2'), false)

    -- ...and they DO fire on a head and frame that can reach them. Soulsoother
    -- on a Stormwaker frame has a heal rung; Spiritreaver is the only head whose
    -- ladder reads AUTO_SCAN_RESISTS, which is all Scanner arms.
    world.buffer = { 5, 35, 210, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }    -- Soulsoother + Scanner
    advance(2.5)
    petOut(PET + 67, MOB + 67)
    send044({ head = 5, frame = 35, magic = 200, hp = 600, maxhp = 600, mp = 300, maxmp = 300 })
    handlers['d3d_present']()
    check('heal threshold moves on a head with a heal rung', says('Light', 'heal at 40%'), true)
    check('no scanner arming outside Spiritreaver', says('Ice', 'Scanner arms'), false)
    world.buffer = { 6, 35, 210, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }    -- Spiritreaver + Scanner
    advance(2.5)
    petOut(PET + 68, MOB + 68)
    send044({ head = 6, frame = 35, magic = 265, hp = 600, maxhp = 600, mp = 300, maxmp = 300 })
    handlers['d3d_present']()
    check('scanner arms on Spiritreaver', says('Ice', 'Scanner arms'), true)
    -- Spiritreaver's cooldown table has no heal rung, so the threshold is moot
    check('no heal threshold on a head with no heal rung', says('Light', 'heal at 40%'), false)

    -- A weaponskill flip. Back to a VALOREDGE frame first - the two blocks above
    -- left a Stormwaker on, and predictWS reads the frame, not the 0x044.
    -- With melee 120 only Chimera Ripper (Fire) and String Clipper (Thunder)
    -- pass the gate; at zero maneuvers the tie goes to the later entry, so the
    -- baseline is String Clipper and a Fire maneuver moves it. Thunder cannot
    -- move what it already picks.
    world.buffer = { 2, 33, 210, 209, 206, 7, 0, 0, 0, 0, 0, 0, 0, 0 }
    advance(2.5)
    petOut(PET + 69, MOB + 69)
    send044({ head = 2, frame = 33, melee = 120 })
    handlers['d3d_present']()
    check('sidebar ws flips on fire', says('Fire', 'WS -> Chimera Ripper'), true)
    check('sidebar ws unmoved on thunder', says('Thunder', 'WS -> String Clipper'), false)

    -- A SPELL flip, and with it the ctx clone. Soulsoother's ladder puts heal
    -- first only while a Light maneuver is up, and Damage Gauge (Light) raises
    -- tryHeal's threshold as well - so a Light maneuver moves BOTH terms:
    --   Light 0 -> thr max(30, 30 + gauge 30) = 60, master at 75% is no target
    --   Light 1 -> thr max(30, 40 + gauge 40) = 80, master at 75% is
    -- The numbers are chosen so a clone that forgot to recompute `gauge` would
    -- land on thr 70 and predict no cure at all: this fails on that too.
    world.buffer = { 5, 35, 211, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }    -- Soulsoother + Damage Gauge
    world.hp, world.maxhp, world.petHpp, world.petMpp = 750, 1000, 100, 100
    advance(2.5)
    petOut(PET + 62, MOB + 62)
    send044({ head = 5, frame = 35, magic = 200, hp = 600, maxhp = 600, mp = 300, maxmp = 300 })
    handlers['d3d_present']()
    local function saysPrefix(el, prefix)
        local r = rowFor(el)
        if r == nil then return false end
        for _, g in ipairs(r.sig) do if g[2]:sub(1, #prefix) == prefix then return true end end
        return false
    end
    check('sidebar spell flips on light', saysPrefix('Light', 'Spell -> Cure'), true)
    check('sidebar spell unmoved on wind', saysPrefix('Wind', 'Spell ->'), false)
    -- The 'heal at N%' line is the same threshold: the bare ladder plus the
    -- Gauge, clamped to [30, 90]. It printed the bare 40 here, against the 80
    -- the headline above was already predicting with.
    check('heal threshold counts the Damage Gauge', says('Light', 'heal at 80%'), true)
    check('...and not the bare ladder', says('Light', 'heal at 40%'), false)

    -- The other half of the clone: Scanner is Ice, and with it up LSB stops
    -- promoting the matching nuke (AUTO_SCAN_RESISTS). So on a Spiritreaver an
    -- Ice maneuver must NOT be reported as switching the cast to Blizzard - a
    -- clone that left `scanner` at the baseline's false would say exactly that.
    -- magic 265 is chosen so BOTH Thunder III (261) and Blizzard III (256) are
    -- castable and nothing above them is: list order then gives Thunder III,
    -- and a promotion would give Blizzard III. At 250 the promotion was dead
    -- anyway - Blizzard III fails the skill gate - and the test proved nothing.
    world.buffer = { 6, 35, 210, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }    -- Spiritreaver + Scanner
    advance(2.5)
    petOut(PET + 63, MOB + 63)
    send044({ head = 6, frame = 35, magic = 265, hp = 600, maxhp = 600, mp = 300, maxmp = 300 })
    handlers['d3d_present']()
    check('sidebar scanner suppresses the ice promotion',
          saysPrefix('Ice', 'Spell ->'), false)
    check('sidebar still reports scanner arming', says('Ice', 'Scanner arms'), true)

    -- The cost of a miss reaches the row: LSB onUseManeuver strips EVERY
    -- maneuver on an overload, so both numbers are on it.
    world.buffer = { 2, 33, 5, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }
    advance(2.5)
    petOut(PET + 64, MOB + 64)
    handlers['d3d_present']()
    handlers['command']({ command = '/cw sync' })   -- burden carried over from earlier blocks
    local quiet = rowFor('Fire')
    check('sidebar row is quiet at zero burden', quiet.chance, 0)
    check('sidebar row has no overload to serve at zero', quiet.dur, 0)
    api.reconcile('Fire', 40, false)            -- the server reports 40%
    check('sidebar row carries the overload chance', rowFor('Fire').chance > 0, true)
    check('sidebar row carries the overload duration', rowFor('Fire').dur > 0, true)

    -- The decay line is element-attributable. With Water the oldest of three,
    -- EVERY element evicts it and halves the rate - which printed the same
    -- sentence on all eight rows and crowded out what each element actually
    -- does. It belongs to the eviction, so it is said once at the head.
    world.buffer = { 2, 33, 206, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }    -- Heatsink
    advance(2.5)
    world.icons, world.timers = { 305, 300, 304 }, { 0, 60, 120 }     -- Water oldest
    handlers['d3d_present']()
    local decayLines = 0
    for _, r in ipairs(api.sidebarRows()) do
        for _, g in ipairs(r.sig) do
            if g[2]:sub(1, 5) == 'decay' then decayLines = decayLines + 1 end
        end
    end
    check('eviction decay is not repeated on every row', decayLines, 0)
    -- ...but the numbers are still on the row, for the head line and the hover
    check('eviction decay from', rowFor('Fire').decayFrom, 2)
    check('eviction decay to', rowFor('Fire').decayTo, 1)
    world.icons, world.timers = nil, nil

    -- What you LOSE. Three maneuvers up with Fire the oldest, Attuner on: an
    -- Ice maneuver evicts the Fire and Attuner falls 18 -> 5. buffSummary
    -- returns signed differences, so the row carries a negative. Raw timers are
    -- minutes off a fixed epoch, so +60 raw is +1s remaining and Fire sorts oldest.
    world.buffer = { 2, 33, 5, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }      -- Attuner
    advance(2.5)
    world.icons, world.timers = { 300, 304, 301 }, { 0, 60, 120 }
    handlers['d3d_present']()
    local ice = rowFor('Ice')
    check('sidebar reports the eviction', ice.evicted, 'Fire')
    -- The loss belongs to the EVICTION, not to Ice: every element drops the same
    -- Fire, so it was on all eight rows at once. It is stated once now.
    local onRow = false
    for _, g in ipairs(ice.sig) do if g[2]:find('ATT -13', 1, true) then onRow = true end end
    check('the eviction cost is not on the row', onRow, false)
    local shared = false
    for _, g in ipairs(api.sideDrop().lost) do
        if g[2]:find('ATT -13', 1, true) then shared = true end
    end
    check('the eviction cost is in the shared block', shared, true)
    check('the shared block names what is dropped', api.sideDrop().el, 'Fire')
    -- ...and recasting the dropped element is the one row it does not apply to
    local fire = rowFor('Fire')
    check('recasting the oldest is a no-op', fire.sig[1][2], 'refreshes it - no other change')
    world.icons, world.timers = nil, nil
end

-- Render: off by default, on after the command, and never window-relative.
do
    world.buffer = { 2, 33, 5, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }
    advance(2.5)
    frame('sidebar collapsed')
    check('sidebar not drawn when collapsed', saw('if you use'), false)
    check('sidebar toggle button drawn', saw('BTN:?##cw_side'), true)
    check('the WS line no longer carries it', saw('BTN:>>##cw_side'), false)
    api.config.sidebar = not api.config.sidebar api.sidebarRows()
    frame('sidebar expanded')
    check('sidebar drawn when expanded', saw('if you use'), true)
    check('sidebar toggle still there while open', saw('BTN:?##cw_side'), true)
    check('sidebar draws every element', #api.sidebarRows(), 8)
    check('sidebar draws no element name', sawExact('Thunder'), false)
    check('sidebar no window-relative sizing', availCalls, 0)
    check('sidebar no eviction line with room to spare', saw('any maneuver drops'), false)
    -- three up, Water the oldest and Heatsink on: the eviction and its decay
    -- change are one line at the head, not eight identical rows
    world.buffer = { 2, 33, 206, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }
    world.icons, world.timers = { 305, 300, 304 }, { 0, 60, 120 }
    advance(2.5)
    frame('sidebar with an eviction')
    check('sidebar names the eviction once', saw('any maneuver drops your Water'), true)
    -- Recasting the oldest element nets to no change, and its row says so;
    -- it must not ALSO say it drops that element. Every other row does.
    local function evictedOf(el)
        for _, r in ipairs(api.sidebarRows()) do if r.el == el then return r.evicted end end
        return 'no row'
    end
    check('the row for the oldest element does not say it drops itself', evictedOf('Water'), nil)
    check('every other row names the eviction', evictedOf('Fire'), 'Water')
    check('sidebar puts the decay on that line', saw('decay 2 -> 1/tick'), true)
    -- the head line is fitted to the sidebar too, or it runs off the panel
    world.textWidth = true
    advance(1)
    frame('eviction head at real text widths')
    check('the eviction head line keeps its prefix', saw('any maneuver drops your Water'), true)
    check('the eviction head line is truncated', saw('decay 2 -> 1/tick'), false)
    world.textWidth = nil

    world.icons, world.timers = nil, nil

    -- With REAL text widths (7px a character) the headline has 236 - 34 - 62 - 6
    -- = 134px, or 19 characters, before the percentage column. It must be
    -- truncated rather than drawn through it: SameLine(x) sets the cursor
    -- absolutely, so an overrun is not pushed aside, it is overprinted.
    -- Flame Holder gives the Fire row a SECOND signal, so the row carries a
    -- '+1' badge as well - which the headline must also make room for, or it
    -- runs under that instead of under the percentage.
    world.buffer = { 2, 33, 7, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }      -- Valoredge + Flame Holder
    advance(2.5)
    petOut(PET + 65, MOB + 65)
    send044({ head = 2, frame = 33, melee = 120 })   -- Chimera Ripper / String Clipper only
    world.textWidth = true
    -- AFTER the 0x044, or the frame draws sidebar rows still cached from before
    -- it: tm.sidebarRows holds for 0.25s and the harness clock only moves here.
    advance(1)
    frame('sidebar at real text widths')
    -- Rows grow to fit: the headline is shown whole on the element's line, and
    -- everything else goes on continuation lines under it at the full sidebar
    -- width. Nothing is truncated and nothing hides behind a hover.
    check('sidebar shows the headline in full', saw('WS -> Chimera Ripper'), true)
    check('sidebar shows the rest on a continuation line', saw('the WS will eat it'), true)
    check('sidebar no longer hides signals behind a badge', sawExact('+1'), false)
    -- tm.fit itself, since with SIDE_W sized for a full 'Spell -> <name>' the
    -- headline guard does not fire on any real signal. The eviction head line
    -- is where it actually bites, above.
    check('fit leaves a short string alone', api.fit('abc', 100), 'abc')
    check('fit truncates a long one', api.fit('abcdefghij', 35), 'abc..')
    world.textWidth = nil

    -- Both prediction reasons WRAP. Unwrapped they were the longest strings on
    -- the tab, so with AlwaysAutoResize they - not the panel's width - decided
    -- how wide the panel got, and narrowing the maneuver table bought nothing.
    -- A Stormwaker frame draws the Spell line, and melee 120 leaves Slapstick
    -- inside the gate so the WS line has a NAME - the branch that carries the
    -- reason. Both call hudText, so both push a wrap.
    world.buffer = { 5, 35, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }
    advance(2.5)
    petOut(PET + 66, MOB + 66)
    send044({ head = 5, frame = 35, melee = 120, magic = 200,
              hp = 600, maxhp = 600, mp = 300, maxmp = 300 })
    frame('wrapped prediction reasons')
    check('WS names a skill here', saw('Slapstick'), true)
    check('the WS reason is drawn wrapped', saw('WRAPPED:no maneuvers, highest tier'), true)
    check('the Spell reason is drawn wrapped', saw('WRAPPED:enhance'), true)
    check('they wrap at the panel width', saw('WRAP:372'), true)
    -- and the no-spell branch, which draws the reason alone
    send028(act(8, 108, PET + 66))       -- stamps the magic window shut
    frame('wrapped no-spell reason')
    check('the Spell line has no name now', saw('none ready'), true)
    check('the no-spell reason is drawn wrapped', saw('WRAPPED:none ready - magic window'), true)

    -- and the WS line's other branch: with melee 0 nothing passes the gate, so
    -- the reason is drawn alone. A Valoredge frame draws no Spell line, so this
    -- wrap is the only one in the frame.
    world.buffer = { 2, 33, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }
    send044({ head = 2, frame = 33 })                -- melee 0
    advance(1)
    frame('wrapped no-weaponskill reason')
    check('the WS line names no skill now', saw('no valid weaponskill'), true)
    check('that reason is drawn wrapped too', saw('WRAPPED:no valid weaponskill'), true)
    api.config.sidebar = not api.config.sidebar api.sidebarRows()
    frame('sidebar collapsed again')
    check('sidebar hidden again', saw('if you use'), false)
end

-- ------------------------------------------- the panel is its own window --
-- 'if you use' is a separate ImGui window: moved and closed
-- on its own, and not drawn inside the Status tab any more.
do
    world.buffer = { 2, 33, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }
    advance(2.5)
    petOut(PET + 74, MOB + 74)
    frame('panel closed')
    check('the second window is absent while closed', saw('WINDOW:clockwork if you use'), false)
    check('and its content with it', saw('if you use'), false)
    api.config.sidebar = not api.config.sidebar api.sidebarRows()
    frame('panel open')
    check('the second window opens', saw('WINDOW:clockwork if you use'), true)
    check('the main window is still there', saw('WINDOW:clockwork'), true)
    check('it is no longer inside the Status tab', saw('WINDOW:clockwork if you use'), true)
    check('its own close button', saw('BTN:x##cw_sideclose'), true)
    -- closing it from its own button, not from the Status tab
    clicks['x##cw_sideclose'] = true
    frame('panel closes itself')
    check('the close button shuts it', api.config.sidebar, false)
    frame('panel stays closed')
    check('and it stays shut', saw('WINDOW:clockwork if you use'), false)
end

-- ------------------------------------ the WS branch that ignores maneuvers --
-- predictWS has two branches that never look at a maneuver count: an open chain
-- decides the weaponskill, and Inhibitor sits on the TP until you open one. In
-- both, every row is silent about the WS - correctly - and the sidebar has to
-- say why, or the silence reads as 'nothing to say'.
do
    api.config.sidebar = not api.config.sidebar api.sidebarRows()                 -- on
    world.buffer = { 2, 33, 3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }     -- Valoredge + Inhibitor
    advance(2.5)
    petOut(PET + 72, MOB + 72)
    send044({ head = 2, frame = 33, melee = 120 })
    world.tp = 1000                                                  -- at the 900 threshold
    advance(1)
    frame('sidebar while holding TP')
    check('the WS line says it is holding', saw('holding TP'), true)
    check('the sidebar explains the silence', saw('no maneuver moves the WS'), true)
    -- and no row claims a weaponskill change, since none can happen
    local wsRows = 0
    for _, r in ipairs(api.sidebarRows()) do
        for _, g in ipairs(r.sig) do
            if g[2]:sub(1, 6) == 'WS -> ' then wsRows = wsRows + 1 end
        end
    end
    check('no row promises a weaponskill change', wsRows, 0)
    -- below the threshold the hold is off and the maneuvers decide again
    world.tp = 0
    advance(1)
    frame('sidebar with the hold released')
    check('the head line goes away', saw('no maneuver moves the WS'), false)
    local fireWs = false
    for _, r in ipairs(api.sidebarRows()) do
        if r.el == 'Fire' then
            for _, g in ipairs(r.sig) do
                if g[2] == 'WS -> Chimera Ripper' then fireWs = true end
            end
        end
    end
    check('and the rows pick the WS up again', fireWs, true)

    -- The other branch: in this model an OPEN CHAIN decides the weaponskill
    -- regardless of Inhibitor. A Chimera Ripper resonance {7,6} is closed by
    -- String Clipper, and LSB gates the close on the resonance being at least
    -- 3s old, so the frame is taken four seconds later.
    world.buffer = { 2, 33, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }     -- no Inhibitor
    advance(2.5)
    petOut(PET + 73, MOB + 73)
    send044({ head = 2, frame = 33, melee = 120 })
    send028(act(11, 1940, MOB + 73))     -- the automaton's own Chimera Ripper
    advance(4)
    frame('sidebar with a chain open')
    check('the WS line names the close', saw('String Clipper'), true)
    check('the sidebar says the chain decides it', saw('a chain is open'), true)
    local chainWs = 0
    for _, r in ipairs(api.sidebarRows()) do
        for _, g in ipairs(r.sig) do
            if g[2]:sub(1, 6) == 'WS -> ' then chainWs = chainWs + 1 end
        end
    end
    check('no row promises a WS change while a chain is open', chainWs, 0)
    advance(12)                          -- the resonance ages out
    frame('sidebar after the chain expires')
    check('the chain line goes away', saw('a chain is open'), false)
    api.config.sidebar = not api.config.sidebar api.sidebarRows()                 -- off again
end

-- --------------------------------------------------- skillchain forming --
-- battleutils::FormSkillchain iterates the RESONANCE (opener) outer and the
-- SKILL (closer) inner; Horizon's chains addon does the same. The order is
-- visible only when the opener carries two properties and both crossed pairs
-- chain: Seraph Blade {Scission, Transfixion} closed by Cannibal Blade
-- {Compression, Reverberation} is Reverberation on the server (Scission x
-- Reverberation), Compression the other way round (Transfixion x Compression).
do
    local seraph = api.scProps('ws', 37)            -- Seraph Blade
    local cannibal = api.scProps('mobskill', 2065)  -- Cannibal Blade
    check('Seraph Blade is a two-property opener', #seraph, 2)
    check('Seraph Blade props', seraph[1] * 100 + seraph[2], 401)   -- Scission, Transfixion
    check('Cannibal Blade props', cannibal[1] * 100 + cannibal[2], 205)
    check('ambiguous close takes the opener outer',
          api.scName(api.formSkillchain(cannibal, seraph)), 'Reverberation')
    -- the unambiguous ones are unchanged by the swap
    check('Chimera Ripper closes String Clipper',
          api.scName(api.formSkillchain(api.scProps('mobskill', 1941),
                                        api.scProps('mobskill', 1940))), 'Impaction')
    check('no pair chains at all', api.formSkillchain({ 1 }, { 1 }), nil)
    check('a nil side never chains', api.formSkillchain(nil, seraph), nil)
end

-- ------------------------------------- Heatsink numbers, and mod polarity --
-- Two readouts that were quoting the wrong thing at the player.
do
    -- ATTACH_MODS carried upstream LSB's {1,3,4,5} for Heatsink - a passive +1
    -- and a first-Water step of +2 - while the model beside it runs its own
    -- {0,1,2,3}. The Loadout tab, the 'maneuvers give' strip and the
    -- sidebar all quoted the upstream one. It is driven off config now, so this
    -- also fails if the two are ever allowed to drift apart again.
    local d = api.config.heatsink_decay
    local function decayDelta(from, to)
        local out = api.buffSummary({ 'Heatsink' }, { Water = to }, { Water = from })
        for _, m in ipairs(out) do if m[1] == 'Burden decay' then return m[3] end end
        return 0
    end
    check('heatsink has no passive decay', decayDelta(0, 0), 0)
    check('the first Water maneuver is +1', decayDelta(0, 1), d[1] - d[0])
    check('the first Water maneuver is not upstream +2', decayDelta(0, 1), 1)
    check('the second is +1 again', decayDelta(1, 2), d[2] - d[1])
    check('three Water is +3 over none', decayDelta(0, 3), d[3] - d[0])

    -- Polarity. PDT is damage TAKEN: Armor Plate's -10% is a 10% REDUCTION, and
    -- colouring the delta by its sign painted the best attachment on the
    -- automaton red. COL_GOOD's red channel is 0.40, COL_BAD's is 1.00.
    local function colourOf(el, label)
        for _, r in ipairs(api.sidebarRows()) do
            if r.el == el then
                for _, g in ipairs(r.sig) do
                    if g[2]:sub(1, #label) == label then
                        return (g[1][1] < 0.5) and 'good' or 'bad'
                    end
                end
            end
        end
        return nil
    end
    world.buffer = { 2, 33, 98, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }   -- Armor Plate (Earth)
    advance(2.5)
    petOut(PET + 71, MOB + 71)
    handlers['d3d_present']()
    check('an Earth maneuver moves PDT', colourOf('Earth', 'PDT') ~= nil, true)
    check('more PDT reduction reads as good', colourOf('Earth', 'PDT'), 'good')
end

-- --------------------------------------------- sidebar rows grow to fit --
-- Every signal is drawn. The headline shares the element's line with the
-- percentage; the rest go on continuation lines, indented to the signal column
-- and packed across until they run out of width. Nothing truncated, nothing
-- behind a hover - which is what the first version got wrong.
do
    api.config.sidebar = not api.config.sidebar api.sidebarRows()                 -- on
    -- Scanner and Mana Booster are both Ice, so dropping the Ice maneuver costs
    -- two things at once and they will not sit on one line together - that is
    -- the shared block wrapping. Damage Gauge is Light and carries two mods, so
    -- the Light ROW grows a continuation line of its own.
    world.buffer = { 2, 33, 210, 212, 211, 0, 0, 0, 0, 0, 0, 0, 0, 0 }
    world.icons, world.timers = { 301, 300, 304 }, { 0, 60, 120 }    -- Ice the oldest of three
    world.textWidth = true
    advance(2.5)   -- past the 2s equipment cache, or the attachments are stale
    frame('sidebar rows grow to fit')
    -- two lines for the shared block, one for the Light row
    local secs = false
    for i, d in ipairs(drawn) do
        if tostring(d) == 'X:53' and tostring(drawn[i + 1] or ''):match('^%d+s$') then secs = true end
    end
    check('the left column is the seconds, not a bar', secs, true)
    -- 4 rather than the 3 of 1.13.2: every element now also states the stat its
    -- maneuver grants - one row each, nothing derived - so one more row spills
    -- past its headline.
    check('one continuation line per overflow, wrapping when needed', countExact(''), 4)
    -- one SameLine(SIG_X) per headline, one per continuation line - 12 - plus
    -- the Loadout tab's three equipped rows, whose names sit at the same x.
    -- Those three arrived with 1.17.12: the tab reads the 0x044, and the
    -- harness's packet now carries the buffer's attachments as the server's
    -- does, where before the tab listed nothing while the sidebar read the
    -- same three off the buffer - the disagreement itself.
    check('continuation lines are indented like the headlines', countExact('X:28'), 15)
    check('the shared block lists both losses', saw('Scan resists -1'), true)
    -- a NEGATIVE '-s' delta: losing 2s of Mana Booster is the delay going up
    check('a lost delay reduction reads as a gain in delay', saw('Magic delay +2s'), true)
    check('and never as a double minus', saw('Magic delay --2s'), false)
    check('the Light row grows its own continuation', saw('Cure delay -3s'), true)
    world.textWidth = nil
    world.icons, world.timers = nil, nil
    api.config.sidebar = not api.config.sidebar api.sidebarRows()                 -- off again
end

-- ------------------------------------------------- distance to the puppet --
-- On the header line, opposite the automaton's name. GetDistance answers the
-- SQUARE of the distance, so the addon has to root it - a raw reading would
-- show 12.3 yalms as 151.3.
do
    world.buffer = { 2, 33, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }
    advance(2.5)
    petOut(PET + 70, MOB + 70)
    world.petDist = 12.34
    frame('header distance')
    check('header shows the distance in yalms', sawExact('12.3y'), true)
    check('header does not show it squared', sawExact('152.3y'), false)
    -- beside the name, not right-aligned to the content edge: the
    -- gap after the name is a relative SameLine, so no absolute x is recorded
    world.textWidth = true
    frame('header distance beside the name')
    check('distance is not right aligned any more', sawExact('X:318'), false)
    check('distance sits a gap after the name', sawExact('SP:6'), true)
    world.textWidth = nil
    world.petDist = 0
    frame('header distance at zero')
    check('zero distance still draws', sawExact('0.0y'), true)
    -- no automaton: the name line is replaced, so there is nothing to align to
    petIn()
    frame('header distance with no pet')
    check('no distance without an automaton', saw('no automaton out'), true)
    world.petDist = nil
end

-- ------------------------------------------------------ tooltips are text --
-- A source read of the addon, not a render: tooltips only fire on hover and the
-- stub never hovers, so there is no other way to hold this line. Everything
-- else in the file cites LandSandBoat constantly and SHOULD - that is where the
-- model comes from - but a citation in a tooltip is a source reference in a HUD,
-- read by someone deciding which maneuver to cast. The Tuning tab is exempt: it
-- exists to check the addon rather than to play it, and says so.
do
    local f = assert(io.open(ADDON_DIR .. '/clockwork.lua', 'r'))
    local lines = {}
    for line in f:lines() do lines[#lines + 1] = line end
    f:close()
    -- where the Tuning tab starts, so its diagnostics are not flagged
    local tuning = #lines
    for i, line in ipairs(lines) do
        if line:find("BeginTabItem('Tuning')", 1, true) then tuning = i break end
    end
    local leaks = {}
    for i = 1, tuning - 1 do
        if lines[i]:find('tip(', 1, true) then
            -- the call plus one continuation line: a :format() argument list
            local blob = lines[i] .. (lines[i + 1] or '')
            if blob:find('LSB', 1, true) or blob:find('%.cpp') or blob:find('%.sql')
               or blob:find('%.lua:%d') then
                leaks[#leaks + 1] = i
            end
        end
    end
    check('no Status tooltip cites server source', table.concat(leaks, ','), '')
end
