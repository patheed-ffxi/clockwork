-- cw/ui/panel.lua - the windows: the compact strip, the full panel with its
-- header and tab dispatch, the Status, Tuning and Settings tab bodies, the Spell
-- line, and the what-if window's frame. Publishes tm.railColour, tm.drawCompact,
-- tm.settingsTab and tm.spellLine; returns { draw }, run once a frame when
-- frame.tick says the HUD should show.
local imgui = require('imgui')
local chat  = require('chat')
local config = require('cw.config')
local D  = require('cw.data')
local ELEMENTS, MANEUVER_STAT = D.ELEMENTS, D.MANEUVER_STAT
local tm = require('cw.state')
local A  = require('cw.attachments')
local fmtMod, buffSummary = A.fmtMod, A.buffSummary
local R  = require('cw.reading')
local petInfo, hasAttachment, oilCounts, equippedAttachments = R.petInfo, R.hasAttachment, R.oilCounts, R.equippedAttachments
local B  = require('cw.burden')
local computeCost, predict, overloadDuration, meanAbsError = B.computeCost, B.predict, B.overloadDuration, B.meanAbsError
local activeManeuvers, maneuverCounts, decayRate, predictWS = B.activeManeuvers, B.maneuverCounts, B.decayRate, B.predictWS
local P  = require('cw.pet')
local resetModel = P.resetModel
local SF = require('cw.ui.surface')
local EL_COLOR, COL_GOOD, COL_WARN, COL_BAD = SF.EL_COLOR, SF.COL_GOOD, SF.COL_WARN, SF.COL_BAD
local COL_DIM, COL_TEXT, COL_MP, COL_TP = SF.COL_DIM, SF.COL_TEXT, SF.COL_MP, SF.COL_TP
local COL_TPUP, COL_MOB, HUD_FLAGS = SF.COL_TPUP, SF.COL_MOB, SF.HUD_FLAGS
local hudPad, hudInner, hudText = SF.hudPad, SF.hudInner, SF.hudText
local tip, vitals = SF.tip, SF.vitals
local abilityCell, cellW, abilityArt = SF.abilityCell, SF.cellW, SF.abilityArt
local petStatusStrip = SF.petStatusStrip
local LO = require('cw.ui.loadout')
local NO_DATA, drawLoadoutTab = LO.NO_DATA, LO.drawLoadoutTab
-- The shared tables, never reassigned after cw/state.lua creates them.
local burden, cost, samples, snap = tm.burden, tm.cost, tm.samples, tm.snap
local costSource, castStat = tm.costSource, tm.castStat

-- ------------------------------------------------------------- compact --
-- The one-line layout. Its own window, so ImGui keeps its position apart from
-- the panel's. Everything the fight needs and nothing it does not; Loadout,
-- Tuning and Settings are reached by switching back. Every x is absolute -
-- the window is AlwaysAutoResize and nothing may size itself from it.

-- At 100%. rescaleCompact rewrites them from tm.s once a frame, in draw(),
-- so every use site below stays a plain number - the same 'resolve once, read
-- many' shape XIUI's settings updater uses for its own global scale.
local GEM, STEP, TEXT_W, BAR_W = 20, 24, 120, 44
-- One vitals cell: its label, a gap, then the bar. Four of them share a line.
local VIT_GAP = 10
local function rescaleCompact()
    GEM, STEP, TEXT_W, BAR_W = tm.s(20), tm.s(24), tm.s(120), tm.s(44)
    VIT_GAP = tm.s(10)
end
local function vsep(x)
    imgui.SameLine(x, 0)
    local px, py = imgui.GetCursorScreenPos()
    imgui.GetWindowDrawList():AddRectFilled({ px, py + tm.s(2) }, { px + tm.s(1), py + tm.s(24) },
                                            tm.u32(tm.col.edge))
    imgui.Dummy({ tm.s(1), tm.s(26) })
end

-- The worst live condition, as one colour on the strip's left edge.
tm.railColour = function(pet, maneuvers, overload)
    local o = oilCounts()
    local noOil = (o['Automaton Oil'] + o['Automaton Oil +1']
                 + o['Automaton Oil +2'] + o['Automaton Oil +3']) == 0
    if overload ~= nil or (pet.hpp or 0) < 40 or noOil then return COL_BAD end
    if (pet.hpp or 0) < 75 then return COL_WARN end
    for _, m in ipairs(maneuvers) do
        if (m.remaining or 0) <= 10 then return COL_WARN end
    end
    return COL_DIM
end

-- One element: the gem (dimmed when nothing is up), its stack count in the
-- corner, a 3 px time bar and a 2 px burden bar. An InvisibleButton owns
-- the cell, so the tooltip works on a drawn thing.
local function gemCell(el, count, rem)
    local h = GEM + tm.s(8)
    local x, y = imgui.GetCursorScreenPos()
    imgui.InvisibleButton(el .. '##cw_gem', { GEM, h })
    local chance = predict(el)
    local up = count > 0
    tip(('%s: %s\nburden %d - use now: %d%% overload'):format(
        el, up and ('%d up, %ds on the oldest'):format(count, rem or 0) or 'nothing up',
        burden[el], chance))
    local dl = imgui.GetWindowDrawList()
    local icon = tm.elementIcon(el)
    if icon then
        dl:AddImage(icon, { x, y }, { x + GEM, y + GEM }, { 0, 0 }, { 1, 1 },
                    up and 0xFFFFFFFF or 0x50FFFFFF)
    else
        imgui.PushFont(tm.font, tm.px('label'))
        dl:AddText({ x + tm.s(3), y + tm.s(4) },
                   tm.u32(up and (EL_COLOR[el] or COL_TEXT) or COL_DIM), el:sub(1, 2))
        imgui.PopFont()
    end
    if up then
        imgui.PushFont(tm.fontBold, tm.px('label'))
        local c = tostring(count)
        local w = imgui.CalcTextSize(c)
        local o = tm.s(1)
        dl:AddText({ x + GEM - w, y - o }, tm.SHADOW, c)
        dl:AddText({ x + GEM - w - o, y - o * 2 }, tm.u32(COL_TEXT), c)
        imgui.PopFont()
    end
    local tH, bH = tm.s(3), tm.s(2)          -- the time bar's height, then the burden's
    local ty = y + GEM + tm.s(1)
    dl:AddRectFilled({ x, ty }, { x + GEM, ty + tH }, tm.u32(tm.col.track), tm.s(1))
    if up and rem ~= nil then
        dl:AddRectFilled({ x, ty }, { x + GEM * math.min(1, rem / 60), ty + tH },
                         tm.u32((rem <= 10) and COL_WARN or (EL_COLOR[el] or COL_TEXT)), tm.s(1))
    end
    local by = ty + tm.s(4)
    dl:AddRectFilled({ x, by }, { x + GEM, by + bH }, tm.u32(tm.col.track), tm.s(1))
    local bf = math.min(1, burden[el] / math.max(1, snap.thresh))
    if bf > 0 then
        local c2 = (chance >= config.warn_at) and COL_BAD or (chance > 0) and COL_WARN or COL_GOOD
        dl:AddRectFilled({ x, by }, { x + GEM * bf, by + bH }, tm.u32(c2), tm.s(1))
    end
end

-- The weaponskill over its reason and the next spell, cut to TEXT_W; the
-- group is the hover target and the tooltip carries both in full. The
-- frame comes from tm.frameNow, as the Status tab's WS line's does.
local function answers()
    local frame = tm.frameNow()
    local ws, why, mode = nil, nil, nil
    if frame ~= nil and config.show_ws then ws, why, mode = predictWS(frame) end
    local sp = tm.spell
    -- Which of the two gets the big line. On a caster frame it is the spell: the
    -- ladder fires over and over through a fight and the weaponskill fires once,
    -- on whatever the TP happened to land on. Stormwaker collapses onto
    -- Harlequin in tm.frameNow, so this covers both casting frames. The Status
    -- tab keeps WS first - it has room for both at full size. With the
    -- weaponskill hidden (show_ws) the spell has the big line on any frame.
    local spellName = (sp ~= nil and sp.mode ~= 'none') and sp.name or nil
    local spellFirst = (frame == 'Harlequin' or not config.show_ws) and spellName ~= nil
    local second = (config.show_reasoning and why) or ''
    if spellFirst then
        second = (ws ~= nil)
                 and ((second ~= '') and (second .. ' - WS ' .. ws) or ('WS ' .. ws))
                 or second
    elseif spellName ~= nil then
        second = ((second ~= '') and (second .. ' - ') or '') .. spellName .. ' next'
    end
    imgui.BeginGroup()
    if spellFirst then
        -- the Spell line's own colours: green when a maneuver chose it, amber
        -- when an unreadable input did
        tm.head((sp.mode == 'maneuver') and COL_GOOD
                or (sp.mode == 'uncertain') and COL_WARN or COL_TEXT,
                tm.fit(spellName .. ((sp.mode == 'uncertain') and '?' or ''), TEXT_W, 'head'))
    elseif ws ~= nil then
        tm.head((mode == 'chain') and COL_GOOD or COL_TEXT, tm.fit(ws, TEXT_W, 'head'))
    elseif config.show_ws then
        tm.text('text', (mode == 'hold') and COL_WARN or COL_DIM, tm.fit(why or 'no frame', TEXT_W))
    else
        -- No weaponskill shown and no spell to name: the spell's own reason
        -- ('nothing to cast'), or blank on a frame that never casts.
        tm.text('text', COL_DIM, tm.fit((sp ~= nil and sp.mode ~= 'none' and sp.why) or '', TEXT_W))
    end
    if second ~= '' then
        tm.text('label', COL_DIM, tm.fit(second, TEXT_W, 'label'))
    else
        imgui.Dummy({ TEXT_W, tm.px('label') })
    end
    imgui.EndGroup()
    tip((config.show_ws and ('WS %s\n%s\n'):format(ws or '-', why or '') or '')
        .. ('Spell %s\n%s'):format((sp and sp.name) or '-', (sp and sp.why) or ''))
end

tm.drawCompact = function()
    local pet = petInfo()
    local maneuvers, overload = activeManeuvers()
    tm.panelPush()
    local wx, wy = nil, nil
    if imgui.Begin('clockwork compact', nil, HUD_FLAGS) then
        if pet == nil then
            tm.text('text', COL_DIM, 'no automaton out')
            imgui.SameLine(0, tm.s(12))
        else
            -- the rail
            local px, py = imgui.GetCursorScreenPos()
            local railW, railH = tm.s(3), tm.s(28)
            imgui.GetWindowDrawList():AddRectFilled({ px, py }, { px + railW, py + railH },
                                                    tm.u32(tm.railColour(pet, maneuvers, overload)), tm.s(1.5))
            imgui.Dummy({ railW, railH })
            -- the gems: count and the oldest maneuver's seconds per element
            local cnt, rem = {}, {}
            for _, m in ipairs(maneuvers) do
                cnt[m.element] = (cnt[m.element] or 0) + 1
                if rem[m.element] == nil then rem[m.element] = m.remaining end   -- oldest first
            end
            local x0 = hudPad() + tm.s(3) + tm.s(6)
            for i, el in ipairs(ELEMENTS) do
                imgui.SameLine(x0 + (i - 1) * STEP, 0)
                gemCell(el, cnt[el] or 0, rem[el])
            end
            local xs = x0 + 8 * STEP - tm.s(4) + tm.s(8)
            vsep(xs)
            imgui.SameLine(xs + tm.s(9), 0)
            answers()
            vsep(xs + tm.s(9) + TEXT_W + tm.s(8))
            -- HP, MP, TP and the target's HP as four thin bars
            local xb = xs + tm.s(9) + TEXT_W + tm.s(8) + tm.s(9)
            local hpp = pet.hpp or 0
            local hpCol = COL_GOOD
            if hpp < 40 then hpCol = COL_BAD elseif hpp < 75 then hpCol = COL_WARN end
            local tp = pet.tp or 0
            local mob = (config.show_target and tm.petTarget ~= 0) and tm.mobSlot() or nil
            local mobHpp = mob and tm.mobHpp(mob) or 0
            -- Two columns of two: HP over MP, TP over TGT. Four stacked made a
            -- one-line strip four rows tall; four in a row made it half as wide
            -- again as the rest of the strip put together.
            --
            -- These DO sit in a group, and the offsets below are therefore
            -- measured from the group's own x rather than the window's -
            -- BeginGroup sets ImGui's indent to where the group started, so a
            -- window-absolute offset would be applied twice and put the bars
            -- against the right edge.
            local lblW = 0
            for _, t in ipairs({ 'HP', 'MP', 'TP', 'TGT' }) do
                local w = tm.width('label', t)
                if w > lblW then lblW = w end
            end
            local vitW = lblW + tm.s(4) + BAR_W + VIT_GAP
            imgui.SameLine(xb, 0)
            imgui.BeginGroup()
            -- col 0 opens a row and col 1 joins it; tm.bar ends with a Dummy, so
            -- the widget after a col-1 bar starts the next row on its own.
            local function cell(col, lbl, frac, c)
                local x = col * vitW
                if col > 0 then imgui.SameLine(x, 0) end
                tm.text('label', COL_DIM, lbl)
                imgui.SameLine(x + lblW + tm.s(4), 0)
                tm.bar(nil, frac, nil, c, BAR_W)
            end
            cell(0, 'HP', hpp / 100, hpCol)
            cell(1, 'TP', math.min(tp, 1000) / 1000, (tp >= 1000) and COL_TPUP or COL_TP)
            -- an MP read that failed on its own is nil: an empty, dim bar and
            -- '?' in the tooltip, not the 0% of an empty pool
            cell(0, 'MP', (pet.mpp or 0) / 100, pet.mpp and COL_MP or COL_DIM)
            cell(1, 'TGT', mobHpp / 100, COL_MOB)
            imgui.EndGroup()
            -- Engaged with a target the client cannot see this frame is not
            -- 'no target': the full panel's row says 'out of sight', so this does.
            tip(('HP %d%%  MP %s  TP %d\n%s'):format(hpp, pet.mpp and (pet.mpp .. '%') or '?', tp,
                mob and ('%s %d%%'):format(tm.targetName(), mobHpp)
                or (config.show_target and tm.petTarget ~= 0) and (tm.targetName() .. ' - out of sight')
                or 'no target'))
            -- the recast squares
            local xr = xb + 2 * (tm.width('label', 'TGT') + tm.s(4) + BAR_W + VIT_GAP) + tm.s(8)
            vsep(xr)
            xr = xr + tm.s(9)
            -- pitch from the cell itself: it is sized to hold the countdown
            local step = cellW() + tm.s(3)
            for i, r in ipairs(tm.rows) do
                imgui.SameLine(xr + (i - 1) * step, 0)
                abilityCell(r, true)
                local _, of = abilityArt(r)
                tip(('%s%s: %s'):format(r.name, of and (' (' .. of .. ')') or '',
                                        (r.state == 'counting' and tm.fmtLeft(r.remaining))
                                          or (r.state == 'ready' and 'ready') or 'not used since load'))
            end
            imgui.SameLine(xr + #tm.rows * step + 8, 0)
        end
        -- the two buttons: the what-if window, and the way back
        imgui.PushFont(tm.font, tm.px('label'))
        if imgui.SmallButton('?##cw_side2') then
            config.sidebar = not config.sidebar
            tm.sidebarInvalidate()
            tm.saveSettings()
        end
        tip('What each maneuver would change if you use it now.')
        imgui.SameLine(0, tm.s(3))
        if imgui.SmallButton('full##cw_layout') then
            config.compact = false
            tm.saveSettings()
        end
        tip('Back to the full panel. Same as /cw compact.')
        imgui.SameLine(0, tm.s(3))
        if imgui.SmallButton('x##cw_close') then
            config.show_window = false
            tm.saveSettings()
        end
        tip('Hide the strip. /cw show brings it back.')
        imgui.PopFont()
        wx, wy = imgui.GetWindowPos()
    end
    imgui.End()
    tm.panelPop()
    return wx, wy
end

-- ========================================================= settings tab ==
-- The knobs a player is meant to reach, in one place. Everything here writes
-- through to config AND to the settings file, so a reload keeps it.
--
-- What is deliberately NOT here: the burden model's constants. activate_burden,
-- dea_burden, heatsink_decay, the stat checks and the tolerances are model
-- values, each documented in cw/config.lua with the reasoning behind it. A knob
-- on those would silently invalidate the model and every log it then produced,
-- and the reader would have no way to tell which. They stay in cw/config.lua
-- rather than pretending to be preferences.

-- One stable { text } buffer per key. ImGui writes into these in place - each
-- keystroke lands here - so they cannot be rebuilt per frame; percentBox
-- reformats one from config only while nobody is typing in it.
local buf = {}

-- Second-click confirmation, the Loadout tab's pattern: the first click
-- arms, a second within four seconds acts. These three throw away state
-- that cannot be got back.
local armed = nil
local function arm(name)
    if armed ~= nil and armed.name == name and os.clock() - armed.at <= 4.0 then
        armed = nil
        return true
    end
    armed = { name = name, at = os.clock() }
    return false
end
local function label(name, asked, idle)
    -- Same 4 s the guard uses. Reading only the name would leave the
    -- button asking long after the arm had lapsed, so the click it invited
    -- would re-arm instead of confirming.
    local live = armed ~= nil and armed.name == name and os.clock() - armed.at <= 4.0
    return (live and asked or idle) .. '##cw_set_' .. name
end

-- A switch drawn as a pill: an InvisibleButton owns the click and the
-- hover, the rest is the draw list. The id is the label plus the key, which
-- is the id the harness clicks.
local function toggle(text, key, hint, after)
    local w, h = tm.s(22), tm.s(12)
    local x, y = imgui.GetCursorScreenPos()
    local on = config[key] and true or false
    if imgui.InvisibleButton(text .. '##cw_set_' .. key, { w, h }) then
        on = not on
        config[key] = on
        if after ~= nil then after() end
        tm.saveSettings()
    end
    if hint ~= nil then tip(hint) end
    local dl = imgui.GetWindowDrawList()
    dl:AddRectFilled({ x, y }, { x + w, y + h }, tm.u32(on and tm.col.on or tm.col.off), h / 2)
    dl:AddCircleFilled({ x + (on and (w - h / 2) or (h / 2)), y + h / 2 }, h / 2 - tm.s(2),
                       tm.u32(on and tm.col.knob or COL_DIM))
    imgui.SameLine(0, tm.s(6))
    tm.text('text', COL_TEXT, text)
end

-- A percentage TYPED, not dragged. The buffer holds what is DISPLAYED - `100%`
-- - so the box reads as the thing it sets rather than as a bare number, and the
-- value lands on Enter: a drag would make every number between here and there
-- the setting for a frame, and write the file for each.
--
-- InputText, not InputInt or InputScalar: this is the only one of the three
-- that shows a unit, and it is the widget the Save popup already proves in
-- game.
--
-- The buffer IS the edit here, so it may only be re-formatted from config when
-- the box is NOT being typed in - `editing` is that. Leaving it alone the rest
-- of the time is also what puts an abandoned edit back: click away and the next
-- frame reformats from the value actually in force.
local editing = {}
local function percentBox(text, key, lo, hi, hint)
    local b = buf[key]
    if b == nil then b = { '' } buf[key] = b end
    if not editing[key] then b[1] = ('%d%%'):format(config[key]) end
    -- Wide enough for the widest value it can hold and no wider. An ABSOLUTE
    -- width, like every other number here: the panel is AlwaysAutoResize and a
    -- widget sized from the available width ratchets it wider every frame.
    imgui.PushItemWidth(tm.width('text', '000%') + tm.s(10))
    imgui.PushFont(tm.font, tm.px('text'))
    local entered = imgui.InputText(text .. '##cw_set_' .. key, b, 8,
                                    ImGuiInputTextFlags_EnterReturnsTrue)
    editing[key] = imgui.IsItemActive()
    if entered then
        -- Lenient on the way in: `150`, `150%` and ` 150 % ` are the same
        -- thing typed three ways. Anything with no number in it at all leaves
        -- the setting alone rather than zeroing it.
        local n = tonumber(tostring(b[1]):match('%d+') or '')
        config[key] = math.max(lo, math.min(hi, n or config[key]))
        -- Written here, once: Enter answers true once per edit, so the file
        -- is written once per change.
        tm.saveSettings()
        editing[key] = false          -- reformat next frame, at what took
    end
    imgui.PopFont()
    imgui.PopItemWidth()
    if hint ~= nil then tip(hint) end
end

tm.settingsTab = function()
    -- two columns: logging, then display, each 172 px of the panel's 364
    imgui.BeginGroup()
    tm.text('label', COL_DIM, 'logging')
    toggle('write a log file', 'logging',
           'One file per character per day, one JSON object a line: every\nmaneuver, cast, ability and loadout as it happens.')
    toggle('anomalies to the file', 'anomaly_file',
           'Separate from the log above. Turn that off and this on to record\nonly the cases where the prediction was wrong.')
    toggle('anomalies to chat', 'anomaly_chat',
           'The red line when the automaton does something that was not\npredicted. The Tuning tab counts them either way.')
    toggle('predictions to chat', 'debug_predictions',
           'Print each weaponskill and spell prediction to chat as it is made.')
    imgui.EndGroup()
    imgui.SameLine(hudPad() + tm.s(180), 0)
    imgui.BeginGroup()
    tm.text('label', COL_DIM, 'display')
    toggle('the automaton\'s target', 'show_target',
           'Show the target\'s name and HP under the vitals while it fights.')
    toggle('weaponskill prediction', 'show_ws',
           'The WS line on the Status tab, and the weaponskill on the compact\nstrip. Off hides it only: it is still predicted and logged.')
    toggle('what maneuvers give', 'show_gives',
           'The gives list on the Status tab: what your maneuvers are adding\nright now.')
    toggle('oil counts', 'show_oils',
           'The oils line on the Status tab, and its warning when you have none.')
    toggle('what-if sidebar', 'sidebar',
           'A second window: what using each maneuver now would change.',
           function() tm.sidebarInvalidate() end)
    toggle('prediction reasoning', 'show_reasoning',
           'The dim text after the predicted weaponskill and spell saying why.\nOff keeps the names and their colours.')
    percentBox('scale', 'ui_scale', 75, 200,
               'How big the whole HUD draws. 75 to 200%, on top of Ashita\'s own\nfont scale. Type a number and press Enter.')
    percentBox('warn at', 'warn_at', 1, 100,
               'Overload chance at which the OL% column turns red. Type a number\nand press Enter.')
    imgui.EndGroup()

    imgui.Separator()
    tm.text('label', COL_DIM, 'model')
    imgui.PushFont(tm.font, tm.px('text'))
    -- No `Reset model` here: `/cw reset` runs the identical code, and every
    -- figure either of them clears is in-memory, so a plain
    -- `/addon reload clockwork` does it as well. Two destructive buttons
    -- side by side, one of them redundant twice over, is a mis-click
    -- waiting to happen.
    if imgui.Button(label('sync', 'Really zero?', 'Zero burden')) then
        if arm('sync') then
            resetModel('manual')
            print(chat.header('clockwork'):append(chat.message(
                'burden zeroed - manual resync only')))
        end
    end
    tip('Set the burden on every element to zero, for when the model has\ndrifted. Stat checks and counters are untouched. Click twice.')

    imgui.Separator()
    imgui.PopFont()
    tm.text('label', COL_DIM, tm.fit('saved to ' .. tm.settingsPath(), hudInner(), 'label'))
    tip(tm.settingsPath())
    imgui.PushFont(tm.font, tm.px('text'))
    if imgui.Button(label('defaults', 'Really restore?', 'Restore defaults')) then
        if arm('defaults') then
            tm.restoreDefaults()
            print(chat.header('clockwork'):append(chat.message(
                'settings back to the defaults in cw/config.lua')))
        end
    end
    tip('Put every switch on this tab back to its default. Nothing else is\ntouched. Click twice.')
    imgui.PopFont()
end

-- The Spell line, in the WS line's shape: the caster head's next cast and
-- why. Absent on a frame that never casts. Reads the frame's snapshot.
tm.spellLine = function()
    local s = tm.spell
    if s == nil or s.mode == 'none' then return end
    tm.text('label', COL_DIM, 'Spell')
    imgui.SameLine()
    if s.name == nil then
        -- No spell: the why is a complete statement on its own ('nothing to
        -- cast', 'none ready - heal 12s', 'the automaton is silenced'), so draw
        -- it alone. A 'none ready' placeholder as well would read
        -- 'Spell none ready nothing to cast'.
        -- WRAPPED, like the WS line's reason. These two reasons are the longest
        -- strings on the tab; unwrapped, with AlwaysAutoResize, they - not the
        -- panel's own width - would decide how wide it gets.
        hudText(COL_DIM, (s.why ~= nil and s.why ~= '') and s.why or 'none ready')
    else
        local col = (s.mode == 'maneuver') and COL_GOOD or (s.mode == 'uncertain') and COL_WARN or COL_TEXT
        tm.head(col, s.name .. ((s.mode == 'uncertain') and '?' or ''))
        -- The reason only when it is wanted; the name and its colour always.
        -- Green still says a maneuver chose this and ? still says an unreadable
        -- input decided it, so the line keeps its meaning without the text.
        if config.show_reasoning then
            imgui.SameLine()
            hudText(COL_DIM, s.why or '')
        end
    end
    tip(('What this head casts next. Green: a maneuver chose it. ?: it turns on\nsomething the client cannot read, like enmity or the target\'s HP.\nrung %s · windows %s\n%d casts seen, %d not as predicted.')
        :format(s.rung or 'none', (s.windows ~= '' and s.windows) or 'none open',
                tm.casts, tm.missed))
end

-- =========================================================== status tab ==
-- The WS line: the weaponskill the frame would pick now, and why, with a
-- tooltip naming the frame and whether Inhibitor is on.
local function drawWSLine()
    local frame = tm.frameNow()
    tm.text('label', COL_DIM, 'WS')
    imgui.SameLine()
    if frame == nil then
        -- only when the SERVER has not named one either: tm.frameNow
        -- prefers the 0x044, so this is a genuine cold start
        tm.text('text', COL_DIM, 'no frame - open the attachments window once')
    else
        local ws, why, mode = predictWS(frame)
        if ws == nil then
            hudText((mode == 'hold') and COL_WARN or COL_DIM, why)
        else
            tm.head((mode == 'chain') and COL_GOOD or COL_TEXT, ws)
            if config.show_reasoning then
                imgui.SameLine()
                -- wrapped: see the note in tm.spellLine
                hudText(COL_DIM, why)
            end
        end
        local inhib = hasAttachment('Inhibitor') or hasAttachment('Inhibitor II')
        if inhib then
            tip(('%s frame. A chain open on the target picks the weaponskill - the\none that closes it - whatever your maneuvers. Inhibitor is on: with no\nchain open and you at 900 TP or more, it holds its TP.'):format(frame))
        else
            tip(('%s frame. A chain open on the target picks the weaponskill - the\none that closes it. Otherwise your maneuvers do.'):format(frame))
        end
    end
end

-- The maneuver table's rows, and whether a Fire maneuver is among them.
local function maneuverRows(maneuvers)
    local hasFire, seen, rows = false, {}, {}
    for i, m in ipairs(maneuvers) do
        if m.element == 'Fire' then hasFire = true end
        seen[m.element] = true
        rows[#rows + 1] = { slot = i, el = m.element, rem = m.remaining or 0 }
    end
    for _, el in ipairs(ELEMENTS) do
        if burden[el] > 0 and not seen[el] then
            rows[#rows + 1] = { el = el }
        end
    end
    return hasFire, rows
end

-- One row of the maneuver table: the slot, the gem, the seconds left, the
-- burden and the overload chance of using another, at the columns `cx`.
local function drawManeuverRow(r, cx)
    local p, after = predict(r.el)
    if r.slot ~= nil then
        tm.text('text', (r.slot == 1) and COL_WARN or COL_DIM,
                ('%d'):format(r.slot))
        if r.slot == 1 then tip('Oldest. A 4th maneuver drops this one.') end
    else
        tm.text('text', COL_DIM, '-')
    end
    imgui.SameLine(cx[2], 0)
    tm.gem(r.el, tm.dpx('text'))
    tip(r.rem ~= nil and ('%s - %ds left'):format(r.el, r.rem) or r.el)
    imgui.SameLine(cx[3], 0)
    if r.rem ~= nil then
        -- The number, not a bar: a bar is no faster to read at
        -- a glance than `41s`, and it loses the one figure the
        -- column exists to carry.
        tm.text('text', (r.rem <= 10) and COL_WARN or COL_TEXT,
                ('%ds'):format(r.rem))
    else
        tm.text('text', COL_DIM, '-')
    end
    imgui.SameLine(cx[4], 0)
    tm.text('text', (burden[r.el] > 0) and COL_TEXT or COL_DIM,
            ('%d'):format(burden[r.el]))
    imgui.SameLine(cx[5], 0)
    local col = COL_GOOD
    if p >= config.warn_at then col = COL_BAD
    elseif p > 0 then col = COL_WARN end
    tm.text('text', col, ('%d%%'):format(p))
    tip(('A %s maneuver now: %d%% overload chance, burden %d -> %d.\nAn overload at that burden lasts %ds.')
        :format(r.el, p, burden[r.el], after, overloadDuration(r.el)))
end

-- The maneuver table as one group: its header and a row each, or a dim
-- line when there is nothing to show.
local function drawManeuverTable(rows, cx)
    imgui.BeginGroup()
    if #rows == 0 then
        tm.text('text', COL_DIM, 'no maneuvers, no burden')
    else
        -- 'OL%' rather than 'if cast': the row already says which element,
        -- so the header names the NUMBER. An element has two overload
        -- chances - the one its burden carries now, and the one after
        -- another maneuver of it is used - and this is the second; the cell
        -- tooltip says so outright, since a three-letter header cannot.
        tm.text('label', COL_DIM, '#')
        imgui.SameLine(cx[3], 0) tm.text('label', COL_DIM, 'left')
        imgui.SameLine(cx[4], 0) tm.text('label', COL_DIM, 'burden')
        imgui.SameLine(cx[5], 0) tm.text('label', COL_DIM, 'OL%')
        for _, r in ipairs(rows) do
            drawManeuverRow(r, cx)
        end
    end
    imgui.EndGroup()
end

-- The recast column beside the table, `lines` lines tall. Answers the buff
-- mods it spilled, for the 'gives' line.
local function drawRecastColumn(cx, lines, buffs)
    -- The column, at the same x whether or not the table drew a row:
    -- the recasts belong to the right of the maneuvers, not to
    -- whatever is left over after them.
    imgui.SameLine(cx[6] + 14, 0)
    imgui.BeginGroup()
    local spill = tm.sideColumn(lines, buffs)
    imgui.EndGroup()

    -- what the column could not hold, on the lines under the table. The
    -- column draws every recast cell itself and spills only the buffs.
    local mods = {}
    for _, sp in ipairs(spill) do
        if sp.kind == 'buff' then mods[#mods + 1] = sp.mod end
    end
    return mods
end

-- The 'gives' line: the spilled mods, wrapped to the panel's width. Draws
-- nothing when the column held them all.
local function drawGives(mods)
    if #mods == 0 then return end
    local cond = false
    local avail, pad = hudInner(), tm.s(12)
    local caption = 'gives'
    tm.text('label', COL_DIM, caption)
    tip('What your maneuvers are adding right now. Let them drop and you\nlose this much. The stat beside each one (+6 at 75) is on top of\nthis, not counted in it.')
    local x = tm.width('label', caption) + pad
    for _, b in ipairs(mods) do
        local txt = fmtMod(b) .. (b[4] and '*' or '')
        if b[4] then cond = true end
        local w = tm.width('text', txt) + pad
        if x + w <= avail then
            imgui.SameLine(0, pad); x = x + w
        else
            x = w
        end
        tm.text('text', COL_GOOD, txt)
    end
    if cond then
        tip('* Attuner: only while the target out-levels your automaton.')
    end
end

-- The oils line under its separator, or a red line when there are none.
local function drawOils()
    -- oils sit with the automaton's vitals, not its gear
    imgui.Separator()
    local o = oilCounts()
    local total = o['Automaton Oil'] + o['Automaton Oil +1']
                + o['Automaton Oil +2'] + o['Automaton Oil +3']
    if total == 0 then
        tm.text('text', COL_BAD, 'no oils - Repair and Maintenance unusable')
    else
        tm.text('label', COL_DIM, 'oils')
        imgui.SameLine(tm.s(48), 0)
        tm.text('text', COL_TEXT, ('NQ %d   +1 %d   +2 %d   +3 %d')
            :format(o['Automaton Oil'], o['Automaton Oil +1'],
                    o['Automaton Oil +2'], o['Automaton Oil +3']))
        tip('Repair takes any grade. Maintenance needs +2 or better, and the\ngrade sets how many status effects it removes.')
    end
end

-- The Status tab body. `pet`, `maneuvers` and `overload` are the frame's
-- reads, taken once by drawFull().
local function drawStatus(pet, maneuvers, overload)
    -- 1. what the automaton is about to do
    if config.show_ws then drawWSLine() end
    tm.spellLine()

    -- 2. Maneuvers and burden describe the same eight elements, so
    --    they share one table: a row per live maneuver, oldest first
    --    (the next to drop), then a dim row for any element still
    --    carrying burden with nothing up.
    local hasFire, rows = maneuverRows(maneuvers)

    -- 3. what the maneuvers are buying - the DELTA over the same
    --    attachments with nothing up, not the total. An attachment
    --    that does not scale (flat Max HP) contributes nothing here.
    --    Hidden (show_gives) is an empty list: the column and the line
    --    under the table both draw nothing from it.
    local buffs = config.show_gives and buffSummary(equippedAttachments(), maneuverCounts(), {}) or {}
    local cx = tm.elCols()
    drawManeuverTable(rows, cx)
    local mods = drawRecastColumn(cx, #rows + 1, buffs)

    if hasFire and hasAttachment('Flame Holder') then
        tm.text('text', COL_WARN, 'Flame Holder: the weaponskill will eat your Fire maneuvers')
        tip('+25% weaponskill damage per Fire maneuver consumed.')
    end

    drawGives(mods)
    if config.show_oils then drawOils() end
end

-- =========================================================== tuning tab ==
-- The Tuning tab's model view: the prediction error and counters, the decay
-- rate, every recast timer against its model, and the spell windows.
local function drawTuningModel()
    local mae = meanAbsError()
    if mae ~= nil then
        tm.text('text', COL_TEXT, ('  error %.1f pp over %d casts'):format(mae, #samples))
    else
        tm.text('text', COL_DIM, '  no reconciled casts yet')
    end
    tm.text('text', COL_TEXT, ('  anomalies %d'):format(tm.anomalies))
    tm.text('text', COL_TEXT, ('  spells %d, mispredicted %d'):format(tm.casts, tm.missed))
    do
        local rate, water, extra = decayRate()
        if extra > 0 then
            tm.text('text', COL_TEXT, ('  decay %d/tick - Heatsink with %d Water up'):format(rate, water))
        elseif water > 0 then
            tm.text('text', COL_TEXT, ('  decay %d/tick - %d Water up, no Heatsink'):format(rate, water))
        else
            tm.text('text', COL_TEXT, ('  decay %d/tick'):format(rate))
        end
        tip('Burden comes off every element at this rate each 3s tick. Each\nWater maneuver up adds +1; Heatsink alone adds nothing.')
    end
    -- every recast timer seen since the last lifecycle edge, against
    -- its model. Iterates tm.order, NOT tm.rows: tm.rows holds only what
    -- is equipped this frame, so swapping an attachment out would erase
    -- its history from the panel while tm.gaps still holds it - and this
    -- panel is where a recast is checked after a fight.
    for _, id in ipairs(tm.order) do
        local g = tm.gaps[id]
        if g ~= nil and #g > 0 then
            local row = tm.ability[id]
            local t = 0
            for _, v in ipairs(g) do t = t + v end
            tm.text('text', COL_TEXT, ('  %-14s model %3ds  last %5.1fs  mean %5.1fs over %d')
                :format(row.name, tm.model[id] or row.secs, g[#g], t / #g, #g))
        end
    end
    -- the spell windows: modelled length, and seconds until it reopens
    local wHead = tm.currentHead()
    local wSet  = wHead and tm.fn.windows[wHead] or nil
    if wSet ~= nil then
        local wCounts = maneuverCounts()
        for _, rung in ipairs({ 'magic', 'heal', 'enfeeble', 'elemental', 'enhance', 'status' }) do
            if wSet[rung] ~= nil then
                local left = tm.fn.windowLeft(rung, wHead, wCounts)
                tm.text('text', COL_TEXT, ('  window %-10s model %3ds  %s')
                    :format(rung, wSet[rung],
                            (left > 0) and ('%.1fs left'):format(left) or 'open'))
            end
        end
    end
end

-- The Tuning tab's cost view: each element's stat check, the burden a
-- maneuver of it costs, and where that cost came from.
local function drawTuningCost()
    -- Every element, whether or not one is up. The check you are about
    -- to lose is worth more before the maneuver is used than after it,
    -- and a list of only the elements in play would show nothing at all
    -- at rest.
    for _, el in ipairs(ELEMENTS) do
        local lo = (el == 'Dark') and 10 or 15
        local _, mine, theirs = computeCost(el, castStat[el])
        tm.text('text', EL_COLOR[el] or COL_DIM, ('  %s'):format(el))
        imgui.SameLine(tm.s(88), 0)
        tm.text('text', COL_DIM, ('%s %s'):format(
            MANEUVER_STAT[el] or '?',
            (mine and theirs) and ('%d v %d'):format(mine, theirs) or '?'))
        imgui.SameLine(tm.s(168), 0)
        tm.text('text', (cost[el] ~= lo) and COL_BAD or COL_GOOD, ('cost %d'):format(cost[el]))
        imgui.SameLine(tm.s(228), 0)
        -- The stored source token, in words (tm.costWord); the
        -- tooltip below spells all five out.
        tm.text('text', COL_DIM, tm.costWord(costSource[el]))
    end
    tip('Beat the automaton\'s stat and the maneuver costs 15 burden; lose and\nit costs 20. Dark compares MP, at 10 and 15. Green is the low cost.\nYour side is the stat you wore when that element last resolved, so a\n? means you have not used it yet. A gear-swap set\'s stats never reach the\nclient at all: /cw stat wind 83 tells it what you really wear.\n\nWhere the cost came from: from the server (what it charged), learned\n(inferred over several uses), your setting (/cw stat), from your last\nuse (your stats then), from your gear now (a guess off what you are\nwearing), assumed (stats unreadable), forced (set in the config).')
end

-- The Tuning tab body. Everything it reads is module scope or on tm.
local function drawTuning()
    tm.text('label', COL_DIM, 'automaton skill')
    if tm.auto044 == nil then
        hudText(COL_DIM, '  ' .. NO_DATA)
    else
        tm.text('text', COL_TEXT, ('  melee %d/%d   ranged %d/%d   magic %d/%d')
            :format(tm.auto044.melee, tm.auto044.meleeCap, tm.auto044.ranged,
                    tm.auto044.rangedCap, tm.auto044.magic, tm.auto044.magicCap))
        tip('Cannibal Blade needs melee above 150.')
    end
    imgui.Separator()
    tm.text('text', COL_DIM, ('overload threshold %d with what is worn now'):format(snap.thresh))
    tip('Burden above this can overload. Each element uses the threshold it\nwas last used under.')
    imgui.Separator()
    -- The two views. The skills and the threshold above stay put: they
    -- are the automaton itself, and both views are read against them.
    imgui.PushFont(tm.font, tm.px('label'))
    for i, t in ipairs({ { 'model', 'model' }, { 'cost', 'maneuver cost' } }) do
        if i > 1 then imgui.SameLine(0, tm.s(6)) end
        imgui.PushStyleColor(ImGuiCol_Text, (tm.tuneTab == t[1]) and COL_TEXT or COL_DIM)
        if imgui.SmallButton(t[2] .. '##cw_tune') then tm.tuneTab = t[1] end
        imgui.PopStyleColor()
    end
    imgui.PopFont()
    if tm.tuneTab == 'model' then
        drawTuningModel()
    end
    if tm.tuneTab == 'cost' then
        drawTuningCost()
    end
end

-- ================================================================ panel ==
-- The header: the automaton's name, distance and any overload, the tab
-- buttons, then its vitals, status strip and target row.
local function drawHeader(pet, overload)
    if pet ~= nil then
        local hpp = pet.hpp or 0
        tm.head(COL_TEXT, pet.name or 'automaton')
        -- How far the automaton is, against its NAME rather than at the far end
        -- of the line: it is a fact about the automaton, and read as one. No
        -- colour thresholds - nothing on the server despawns or disengages an
        -- automaton on distance, so there is no number to warn at.
        if pet.dist ~= nil then
            imgui.SameLine(0, tm.s(6))
            -- 'y' for yalms: a bare number reads as anything
            tm.text('label', COL_DIM, ('%.1fy'):format(pet.dist))
            tip('Yalms between you and the automaton.')
        end
        -- Only an actionable tag earns a place on this line: an overload, which
        -- lives on the MASTER. Full HP needs no tag: the bar underneath
        -- already says it.
        if overload ~= nil then
            imgui.SameLine()
            tm.text('text', COL_BAD, ('OVERLOAD %ds'):format(overload))
            tip('You cannot use maneuvers until this expires.')
        end
        tm.tabButtons()
        local hpCol = COL_GOOD
        if hpp < 40 then hpCol = COL_BAD elseif hpp < 75 then hpCol = COL_WARN end
        vitals(hpp, hpCol, pet.mpp, pet.tp or 0)   -- mpp nil = unknown, drawn as such
        petStatusStrip()
        tm.targetRow()
    else
        tm.text('text', COL_DIM, 'no automaton out')
        tm.tabButtons()
    end
    imgui.Separator()
end

-- The bodies the selected tab asks for, in tab order; 'all' draws every one.
local function drawTabs(pet, maneuvers, overload)
    local tab = tm.tab
    -- ------------------------------------------------------------ status --
    if tab == 'status' or tab == 'all' then
        drawStatus(pet, maneuvers, overload)
    end

    -- ----------------------------------------------------------- loadout --
    if tab == 'loadout' or tab == 'all' then
        drawLoadoutTab()
    end

    -- ------------------------------------------------------------ tuning --
    -- Everything here is for checking the addon, not for playing it, so
    -- it stays off the Status tab, where none of it is actionable.
    if tab == 'tuning' or tab == 'all' then
        drawTuning()
    end

    -- ---------------------------------------------------------- settings --
    if tab == 'settings' or tab == 'all' then
        tm.settingsTab()
    end
end

-- The full panel in its own window. Answers false when Begin does - draw()
-- then stops, what-if window included - else true and the window's position.
local function drawFull()
    -- The panel: XIUI's rounding and padding, a flat translucent background so
    -- the text reads over a busy zone. Six vars and two colours, popped after End.
    tm.panelPush()
    imgui.SetNextWindowSize({ tm.s(config.base_width), 0 }, ImGuiCond_FirstUseEver)
    if not imgui.Begin('clockwork', nil, HUD_FLAGS) then
        imgui.End()
        tm.panelPop()
        return false
    end

    local maneuvers, overload = activeManeuvers()
    local pet = petInfo()
    drawHeader(pet, overload)
    drawTabs(pet, maneuvers, overload)
    local x, y = imgui.GetWindowPos()
    imgui.End()
    tm.panelPop()
    return true, x, y
end

-- The what-if panel is its OWN window: moved and closed on its own, and
-- not computed at all while it is shut. It shares the panel's visibility
-- gates, which frame.tick applies before draw() runs - logged in, on PUP,
-- /cw show, the game's interface not hidden - because those are about the
-- addon rather than about this panel.
local function drawSidebar(mainX, mainY)
    tm.panelPush()
    imgui.SetNextWindowSize({ tm.SIDE_W, 0 }, ImGuiCond_FirstUseEver)
    -- First use only: beside the main panel rather than on top of it.
    -- After that ImGui remembers wherever it was dragged.
    if mainX ~= nil then
        imgui.SetNextWindowPos({ mainX + tm.s(config.base_width) + tm.s(12), mainY },
                               ImGuiCond_FirstUseEver)
    end
    if imgui.Begin('clockwork if you use', nil, HUD_FLAGS) then
        tm.sidebarCells()
    end
    imgui.End()
    tm.panelPop()
end

local function draw()
    -- The scale, read once for the frame: tm.s and tm.px are called a few
    -- hundred times a frame and each would otherwise hit GetStyle() again.
    tm.rescale()
    rescaleCompact()
    tm.rescaleSide()
    local mainX, mainY = nil, nil
    if config.compact then
        mainX, mainY = tm.drawCompact()
    else
        local open
        open, mainX, mainY = drawFull()
        if not open then return end
    end
    if config.sidebar then
        drawSidebar(mainX, mainY)
    end
end

return { draw = draw }
