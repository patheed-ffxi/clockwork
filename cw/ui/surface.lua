-- cw/ui/surface.lua - how the HUD draws: the palette, the scale, the fonts and
-- shadowed text, bars, squares, gems and the cog, the icon loaders, and the
-- vitals, target, status and recast strips built from them. Nothing here knows
-- what a number means. Publishes the draw primitives and tab state on tm; returns
-- the palette, HUD_FLAGS, the layout and tooltip helpers, icons and strips.
local imgui = require('imgui')
local d3d8  = require('d3d8')
local ffi   = require('ffi')
local chat  = require('chat')
local config = require('cw.config')
local D  = require('cw.data')
local ELEMENTS, EFFECT_MANEUVER_1 = D.ELEMENTS, D.EFFECT_MANEUVER_1
local ATTACH_OFFSET, EQUIP_OFFSET = D.ATTACH_OFFSET, D.EQUIP_OFFSET
local ABILITY_ICON = D.ABILITY_ICON
local tm = require('cw.state')
local A  = require('cw.attachments')
local fmtMod = A.fmtMod
local U  = require('cw.util')
local safe = U.safe
local P  = require('cw.pet')
local MAX_EFFECT_AGE, petEffects = P.MAX_EFFECT_AGE, P.petEffects
-- for the name -> item id map behind the ability icons. cw/sets.lua requires
-- nothing from the UI, so this stays acyclic.
local S  = require('cw.sets')

-- Element colours, matching the in-game elemental palette.
local EL_COLOR =
{
    Fire    = { 0.90, 0.35, 0.28, 1.0 },  Ice   = { 0.50, 0.80, 0.92, 1.0 },
    Wind    = { 0.48, 0.82, 0.55, 1.0 },  Earth = { 0.82, 0.68, 0.36, 1.0 },
    Thunder = { 0.70, 0.55, 0.90, 1.0 },  Water = { 0.40, 0.62, 0.92, 1.0 },
    Light   = { 0.94, 0.90, 0.62, 1.0 },  Dark  = { 0.64, 0.56, 0.78, 1.0 },
}
local COL_GOOD = { 0.40, 0.95, 0.45, 1.0 }
local COL_WARN = { 1.00, 0.85, 0.35, 1.0 }
local COL_BAD  = { 1.00, 0.40, 0.40, 1.0 }
local COL_DIM  = { 0.62, 0.62, 0.62, 1.0 }
local COL_TEXT = { 0.88, 0.88, 0.88, 1.0 }
local COL_MP   = { 0.36, 0.60, 0.95, 1.0 }
-- TP is gold, the colour the game's own gauge uses; grey read as 'inactive'
-- and the green it turned at 1000 read as a second HP bar.
local COL_TP   = { 0.80, 0.66, 0.24, 1.0 }
local COL_TPUP = { 1.00, 0.86, 0.32, 1.0 }   -- TP >= 1000: a WS can fire

-- A HUD, not a form: no title bar or border, sized to its content. Drag
-- anywhere on the panel to move it; /cw show hides it.
local HUD_FLAGS = bit.bor(ImGuiWindowFlags_NoTitleBar, ImGuiWindowFlags_NoCollapse,
                          ImGuiWindowFlags_NoScrollbar, ImGuiWindowFlags_AlwaysAutoResize)

-- ------------------------------------------------------------- scaling --
-- TWO factors, and they are not the same factor.
--
-- tm.px hands ImGui a BASE size: Ashita 4.3's signature is
-- PushFont(font, font_size_base_unscaled), so ImGui multiplies the style's
-- FontScaleMain and FontScaleDpi onto whatever we pass. Our own scale is all
-- tm.px may apply, or the text scales twice.
--
-- tm.s is the layout, and the layout has to agree with the size the text is
-- actually DRAWN at - ours AND ImGui's. Otherwise a player who raises Ashita's
-- global font scale gets bigger strings over an unchanged layout: the strings
-- know about it and the offsets do not.
--
-- Both are read once a frame by tm.rescale, in draw(): each hits GetStyle(),
-- and a frame calls tm.s a few hundred times.
tm.own, tm.draw = 1, 1
tm.rescale = function()
    local st = imgui.GetStyle()
    tm.own  = (config.ui_scale or 100) / 100
    -- nil-safe: an Ashita older than 4.2.0.1 has neither field.
    tm.draw = tm.own * (st.FontScaleMain or 1) * (st.FontScaleDpi or 1)
end

-- `n` px as it will be drawn. Rounds rather than truncates, and never returns
-- 0 for a number that was not 0: a 1 px separator that scales away leaves the
-- compact strip with no rail. Ashita's own libs/scaling.lua floors its fonts
-- and XIUI floors its at 8, for the same reason.
tm.s = function(n)
    if n == 0 then return 0 end
    local v = math.floor(n * tm.draw + 0.5)
    if v == 0 then return (n > 0) and 1 or -1 end
    return v
end

-- Content width inside the panel (8 px padding each side, scaled). Nothing may
-- size itself from the window instead: with AlwaysAutoResize a stretch table or
-- a bar that fills the available width ratchets the window wider every frame.
local BASE_PAD = 8
local function hudPad()   return tm.s(BASE_PAD) end
local function hudInner() return tm.s(config.base_width) - hudPad() * 2 end

-- A message that may run past the panel, wrapped at the panel's width. Plain
-- TextWrapped wraps at the window's own width, which an auto-resizing window
-- takes from its content - so it never wraps and the panel grows instead.
-- Still ImGui's own wrapped text, with the HUD's font pushed and no shadow:
-- wrapping on the draw list means breaking lines by hand, and these are the
-- dim tails and the messages.
local function hudText(col, text)
    imgui.PushFont(tm.font, tm.px('text'))
    imgui.PushTextWrapPos(hudPad() + hudInner())
    imgui.TextColored(col, text)
    imgui.PopTextWrapPos()
    imgui.PopFont()
end

-- Explanatory text that would otherwise cost a permanent line. Call it
-- directly after the widget it describes.
-- ImGui's SetTooltip takes a printf FORMAT string, so a bare % in the text is
-- a conversion and eats whatever is next on the stack: `use now: 10% overload`
-- renders as `use now: 46756014verload`. Doubling them here fixes
-- every tooltip at once, and is why no caller needs to know.
local function tip(text)
    if imgui.IsItemHovered() then
        imgui.SetTooltip((tostring(text):gsub('%%', '%%%%')))
    end
end

-- Diagonal offsets for outlined text. Hoisted: this runs three times a frame.
local OUTLINE = { { -1, -1 }, { 1, -1 }, { -1, 1 }, { 1, 1 } }
-- The target bar's colour, shared by tm.targetRow and the compact strip.
local COL_MOB = { 0.85, 0.35, 0.32, 1.0 }   -- see tm.targetRow on why not the pet scale

-- ------------------------------------------------------------- surface --
-- How the HUD draws: one typeface at three sizes, every string shadowed on
-- the window draw list. Nothing here knows what a number means.

-- The fonts, loaded ONCE on the load event. AddFontFromFileTTF rebuilds
-- the atlas, and doing that inside d3d_present with draw-list entries
-- pending crashes the client on this Ashita (XIUI, libs/imtext.lua). nil
-- means ImGui's own font: PushFont(nil, px) still sizes it.
tm.font, tm.fontBold = nil, nil
tm.fontLoad = function()
    local missing = {}
    local function load(file)
        local f = safe(function()
            return imgui.AddFontFromFileTTF('C:\\Windows\\Fonts\\' .. file, 16)
        end, nil)
        if not f then missing[#missing + 1] = file return nil end
        return f
    end
    tm.font     = load(config.font_regular)
    tm.fontBold = load(config.font_bold)
    if #missing > 0 then
        print(chat.header('clockwork'):append(chat.error(
            ('font not found in C:\\Windows\\Fonts: %s - using the default font')
            :format(table.concat(missing, ', ')))))
    end
    return #missing == 0
end

-- Three sizes off ImGui's base, so the player's scale holds. The base
-- itself is 13, which is where ProggyClean was DESIGNED to read - a
-- proportional face at the same pixel size has half the x-height and
-- comes out tiny, so every voice sits
-- above it: 13 / 16 / 19 at the stock scale.
local SCALE = { label = 1.0, text = 1.25, head = 1.45 }
tm.px = function(kind)
    -- tm.own, not tm.draw: see the scaling block above.
    return math.floor(imgui.GetStyle().FontSizeBase * tm.own * (SCALE[kind] or 1) + 0.5)
end

-- The height a voice actually OCCUPIES on screen: tm.px is the base we hand
-- PushFont, and this is that size after ImGui has applied its own scale on top.
-- A box drawn to match a string - an icon, a recast square, a cell - is a layout
-- number and has to use this one.
tm.dpx = function(kind)
    return math.floor(imgui.GetStyle().FontSizeBase * tm.draw * (SCALE[kind] or 1) + 0.5)
end

-- Colours as ImGui packs them, cached by table: a GetColorU32 for every
-- string of every frame is the kind of cost that adds up at 60 Hz.
local u32 = {}
tm.u32 = function(col)
    local v = u32[col]
    if v == nil then v = imgui.GetColorU32(col) u32[col] = v end
    return v
end
-- Opaque, not 85%: at label size a translucent shadow leaves no edge and
-- the string dissolves into whatever is behind the panel.
tm.SHADOW = 0xFF000000   -- the harness skips this colour

-- One string: shadow then fill on the draw list, and a Dummy of the
-- measured size so the auto-resizing window counts it and tip() has an
-- item to hover (statustimers' main_ui, where the comment says outright
-- that the Dummy is what makes the resize come out right). Two AddText
-- per string; the HUD draws about forty.
tm.text = function(kind, col, s)
    s = tostring(s)
    imgui.PushFont((kind == 'head') and tm.fontBold or tm.font, tm.px(kind))
    local w, h = imgui.CalcTextSize(s)
    local x, y = imgui.GetCursorScreenPos()
    local dl = imgui.GetWindowDrawList()
    local o = tm.s(1)
    dl:AddText({ x + o, y + o }, tm.SHADOW, s)
    dl:AddText({ x, y }, tm.u32(col), s)
    imgui.Dummy({ w, h })
    imgui.PopFont()
end

-- The headline voice - the automaton's name and the two answers, weaponskill
-- and spell: the semibold at head size, outlined on all four diagonals rather
-- than shadowed once like tm.text.
tm.head = function(col, s)
    s = tostring(s)
    imgui.PushFont(tm.fontBold, tm.px('head'))
    local w, h = imgui.CalcTextSize(s)
    local x, y = imgui.GetCursorScreenPos()
    local dl = imgui.GetWindowDrawList()
    local o = tm.s(1)
    for _, d in ipairs(OUTLINE) do
        dl:AddText({ x + d[1] * o, y + d[2] * o }, 0xFF000000, s)
    end
    dl:AddText({ x, y }, tm.u32(col), s)
    imgui.Dummy({ w, h })
    imgui.PopFont()
end

-- A string's width at a size, for the SameLine arithmetic the layout runs on.
tm.width = function(kind, s)
    imgui.PushFont((kind == 'head') and tm.fontBold or tm.font, tm.px(kind))
    local w = imgui.CalcTextSize(tostring(s))
    imgui.PopFont()
    return w
end

-- The tabs, as { key, letters, tooltip }; tm.tabButtons draws them. tm.tab
-- = 'all' draws every tab at once and exists for the harness only.
local TABS = { { 'status', 'ST', 'Status' }, { 'loadout', 'LO', 'Loadout' },
               { 'tuning', 'TU', 'Tuning' }, { 'settings', 'SE', 'Settings' } }
tm.tab = 'status'
-- Tuning is two views, not one long tab. `model` is what the tab is
-- opened for - the error, the anomalies, the recast history - so it is
-- the default; the per-element stat checks wait behind their button.
tm.tuneTab = 'model'
-- The header's button row, right-aligned as a unit at the end of the name
-- line: the lettered tabs, ? (the what-if window), C (compact), the cog
-- (Settings) and x (close).
tm.tabButtons = function()
    -- Measured, not estimated: every button is its own label wide, so a row
    -- priced at the widest one over-reserves and the slack shows up as a
    -- gap before whatever is pinned to the edge.
    local pad, gap = tm.s(8), tm.s(3)                   -- a SmallButton's padding, and the run's gap
    local h = tm.dpx('label') + tm.s(4)                 -- a SmallButton's height
    local total = tm.width('label', 'x') + pad + gap    -- the close, and its gap
    for _, t in ipairs(TABS) do
        total = total + ((t[1] == 'settings') and h or (tm.width('label', t[2]) + pad)) + gap
    end
    total = total + tm.width('label', '?') + pad + gap + tm.width('label', 'C') + pad + gap
    imgui.SameLine(hudPad() + hudInner() - total, 0)
    imgui.PushFont(tm.font, tm.px('label'))
    -- Settings is not in this run: it is a cog, and it sits at the far end
    -- beside the close, so the three lettered tabs read as one
    -- group rather than as three letters and a picture.
    for i, t in ipairs(TABS) do
        if t[1] ~= 'settings' then
            if i > 1 then imgui.SameLine(0, tm.s(3)) end
            imgui.PushStyleColor(ImGuiCol_Text, (tm.tab == t[1]) and COL_TEXT or COL_DIM)
            if imgui.SmallButton(t[2] .. '##cw_tab') then tm.tab = t[1] end
            imgui.PopStyleColor()
            tip(t[3])
        end
    end
    -- The what-if window's switch. It sits here with every other control
    -- that opens or closes a window, so the WS line can start on the answer.
    imgui.SameLine(0, tm.s(3))
    imgui.PushStyleColor(ImGuiCol_Text, config.sidebar and COL_TEXT or COL_DIM)
    if imgui.SmallButton('?##cw_side') then
        config.sidebar = not config.sidebar
        tm.sidebarInvalidate()
        tm.saveSettings()
    end
    imgui.PopStyleColor()
    tip('What-if sidebar: what each maneuver would change if you use it\nnow.')
    imgui.SameLine(0, tm.s(3))
    if imgui.SmallButton('C##cw_layout') then
        config.compact = true
        tm.saveSettings()
    end
    tip('Shrink to the one-line strip. Same as /cw compact.')
    -- Drawn, not lettered: the same height as a SmallButton so the row sits
    -- level, and an InvisibleButton to own the click. The cog is drawn well
    -- inside its square, at 0.26 of it: any larger and, with the teeth, it
    -- fills the box and reads heavier than the letters.
    imgui.SameLine(0, tm.s(3))
    local cx, cy = imgui.GetCursorScreenPos()
    if imgui.InvisibleButton('SE##cw_tab', { h, h }) then tm.tab = 'settings' end
    tm.cog(cx + h / 2, cy + h / 2, h * 0.26, (tm.tab == 'settings') and COL_TEXT or COL_DIM)
    tip('Settings')
    -- Closing the panel lives HERE rather than on the Settings tab: a switch
    -- that hides the window it sits on can only be undone from the command
    -- line, which is a poor place to keep the way back.
    imgui.SameLine(0, tm.s(3))
    if imgui.SmallButton('x##cw_close') then
        config.show_window = false
        tm.saveSettings()
    end
    tip('Hide the panel. Logging keeps running. /cw show brings it back.')
    imgui.PopFont()
end

-- -------------------------------------------------------------- shapes --
-- Bars, squares, gems and the cog, all on the draw list; each but the cog
-- reserves its room with a Dummy or an Image. Colours are module tables so
-- tm.u32 can cache them.

tm.col = {
    track = { 0, 0, 0, 0.45 },          edge  = { 1, 1, 1, 0.12 },
    fill  = { 0.88, 0.88, 0.88, 0.55 }, ready = { 0.40, 0.95, 0.45, 0.35 },
    knob  = { 0.88, 0.88, 0.88, 1 },    on    = { 0.40, 0.95, 0.45, 0.35 },
    off   = { 1, 1, 1, 0.14 },   hub   = { 0.06, 0.06, 0.07, 1 },
}
-- the same hue at 60%, for the dark end of a fill
local dark = {}
local function darkOf(col)
    local d = dark[col]
    if d == nil then d = { col[1] * 0.6, col[2] * 0.6, col[3] * 0.6, col[4] } dark[col] = d end
    return d
end

-- One bar: a rounded track and a left-dark-to-colour fill. The label, if
-- any, before it at label size; the value, if any, after it. h defaults to
-- 0.6 of the base size - 8 px at the default 13. On tm so the header's
-- target row and the compact strip draw the same bar.
tm.bar = function(label, frac, overlay, col, barW, h)
    if label ~= nil then
        tm.text('label', COL_DIM, label)
        imgui.SameLine()
    end
    frac = math.max(0, math.min(1, frac or 0))
    h = h or tm.s(math.floor(imgui.GetStyle().FontSizeBase * 0.6 + 0.5))
    local x, y = imgui.GetCursorScreenPos()
    local dl = imgui.GetWindowDrawList()
    dl:AddRectFilled({ x, y }, { x + barW, y + h }, tm.u32(tm.col.track), h / 2)
    if frac > 0 then
        dl:AddRectFilledMultiColor({ x, y }, { x + barW * frac, y + h },
                                   tm.u32(darkOf(col)), tm.u32(col), tm.u32(col), tm.u32(darkOf(col)))
    end
    imgui.Dummy({ barW, h })
    if overlay ~= nil then
        imgui.SameLine()
        tm.text('label', COL_TEXT, overlay)
    end
end

-- A recast square: filled bottom-up as the recast runs down, green when
-- ready, an empty outline for '?'. XIUI's petbar idiom at this row's size.
tm.square = function(state, frac)
    local sz = tm.dpx('text') - tm.s(2)
    local x, y = imgui.GetCursorScreenPos()
    y = y + tm.s(1)
    local dl = imgui.GetWindowDrawList()
    if state == 'ready' then
        dl:AddRectFilled({ x, y }, { x + sz, y + sz }, tm.u32(tm.col.ready), tm.s(2))
        dl:AddRect({ x, y }, { x + sz, y + sz }, tm.u32(COL_GOOD), tm.s(2))
    else
        dl:AddRectFilled({ x, y }, { x + sz, y + sz }, tm.u32(tm.col.track), tm.s(2))
        if state == 'counting' and (frac or 0) > 0 then
            dl:AddRectFilled({ x, y + sz * (1 - math.min(1, frac)) }, { x + sz, y + sz },
                             tm.u32(tm.col.fill), tm.s(2))
        end
        dl:AddRect({ x, y }, { x + sz, y + sz }, tm.u32(tm.col.edge), tm.s(2))
    end
    imgui.Dummy({ sz, sz + tm.s(2) })
end

-- The column right of the maneuver table.
--
-- EVERY recast cell sits here, whatever height the table happens to be.
-- Rationed to the table's rows, a cell would move between this column and
-- the footer line each time a maneuver came up or fell off, and the abilities
-- would never sit still - which is exactly what a recast clock is read for.
-- `lines` rations only the deltas, which have no fixed place to be and read
-- the same on the footer; what does not fit is returned for the caller.
tm.sideColumn = function(lines, buffs)
    local left = {}
    local labelW = 0
    for _, r in ipairs(tm.rows) do
        local w = tm.width('label', r.label)
        if w > labelW then labelW = w end
    end
    for _, r in ipairs(tm.rows) do
        tm.recastCell(r, labelW)
    end
    -- The deltas go here or on the footer line, never half in each: room
    -- for the `gives` label but not for what it labels is not room, and
    -- dividing them would draw the label in both places, since the footer
    -- line brings its own.
    if #buffs > 0 then
        if lines - #tm.rows < #buffs + 1 then
            left[#left + 1] = { kind = 'label' }
            for _, b in ipairs(buffs) do left[#left + 1] = { kind = 'buff', mod = b } end
            return left
        end
        tm.text('label', COL_DIM, 'gives')
        tip('What your maneuvers are adding right now. Let them drop and you\nlose this much.')
        for _, b in ipairs(buffs) do
            tm.text('text', COL_GOOD, fmtMod(b) .. (b[4] and '*' or ''))
        end
    end
    return left
end

-- A cog, drawn. ImGui's default glyph range is ASCII and Ashita's
-- AddFontFromFileTTF takes no range argument, so a real U+2699 comes out as
-- a box in any typeface: six teeth, a body and a punched hub instead.
tm.cog = function(cx, cy, r, col)
    local dl = imgui.GetWindowDrawList()
    local c = tm.u32(col)
    for i = 0, 5 do
        local a = i * math.pi / 3
        local tx, ty = cx + math.cos(a) * r, cy + math.sin(a) * r
        local t = r * 0.3                    -- the teeth, in the cog's own terms
        dl:AddRectFilled({ tx - t, ty - t }, { tx + t, ty + t }, c, 0.5)
    end
    dl:AddCircleFilled({ cx, cy }, r * 0.85, c, 12)
    dl:AddCircleFilled({ cx, cy }, r * 0.34, tm.u32(tm.col.hub), 8)
end

-- What the `maneuver cost` source column says. The stored tokens stay as
-- they are - the log and the tests read them - and only the display moves.
tm.costWord = function(src)
    return ({ set = 'forced', cast = 'from your last use', computed = 'from your gear now',
              learned = 'learned', observed = 'from the server',
              yours = 'your setting' })[src] or 'assumed'
end

-- The element's gem at px, or its two-letter token when no texture loaded.
-- imgui.Image is an item, so tip() after it works. Through tm.elementIcon,
-- not elementIcon: that local is declared further down, so naming it here
-- would compile to a global read and throw on the first draw.
tm.gem = function(el, px)
    local icon = tm.elementIcon(el)
    if icon then
        imgui.Image(icon, { px, px })
    else
        tm.text('text', EL_COLOR[el] or COL_DIM, el:sub(1, 2))
    end
end

-- The panel look every window shares: XIUI's rounding and padding, a flat
-- background dark enough that the zone does not read through the text
-- (85%). Six vars and two colours; pop after End.
tm.panelPush = function()
    imgui.PushStyleVar(ImGuiStyleVar_WindowRounding, tm.s(6))
    imgui.PushStyleVar(ImGuiStyleVar_WindowBorderSize, 0.0)
    imgui.PushStyleVar(ImGuiStyleVar_WindowPadding, { hudPad(), tm.s(6) })
    imgui.PushStyleVar(ImGuiStyleVar_FrameRounding, tm.s(3))
    imgui.PushStyleVar(ImGuiStyleVar_FramePadding, { tm.s(4), tm.s(2) })
    imgui.PushStyleVar(ImGuiStyleVar_ItemSpacing, { tm.s(6), tm.s(2) })
    imgui.PushStyleColor(ImGuiCol_WindowBg, { 0.04, 0.04, 0.05, 0.85 })
    imgui.PushStyleColor(ImGuiCol_FrameBg, { 0.16, 0.16, 0.16, 0.60 })
end
tm.panelPop = function()
    imgui.PopStyleColor(2)
    imgui.PopStyleVar(6)
end

-- HP / MP / TP on ONE row: three labelled bars sharing the window width, so
-- the vitals cost a single line instead of three.
-- `mpp` may be nil: the MP read failed on its own (reading.petInfo), which
-- the model treats as unknown. The bar is then empty and dim and the value
-- reads '?' - 0% would claim an empty pool the ladder is not working from.
-- A real 0 is still 0%.
local function vitals(hpp, hpCol, mpp, tp)
    local pad  = imgui.GetStyle().ItemSpacing.x
    local barW = (hudInner() - pad * 2) / 3
    tm.bar(nil, hpp / 100, nil, hpCol, barW)
    imgui.SameLine()
    tm.bar(nil, (mpp or 0) / 100, nil, mpp and COL_MP or COL_DIM, barW)
    imgui.SameLine()
    -- TP fills to 1000, the threshold LSB gates a pet WS on; the value still
    -- shows the true number, which can run past it to 3000.
    tm.bar(nil, math.min(tp, 1000) / 1000, nil, (tp >= 1000) and COL_TPUP or COL_TP, barW)
    -- the labels and values under their bars, each at its bar's origin
    local function under(i, label, value)
        if i > 1 then imgui.SameLine(hudPad() + (i - 1) * (barW + pad), 0) end
        tm.text('label', COL_DIM, label)
        imgui.SameLine(0, tm.s(4))
        tm.text('label', COL_TEXT, value)
    end
    under(1, 'HP', ('%d%%'):format(hpp))
    under(2, 'MP', mpp and ('%d%%'):format(mpp) or '?')
    under(3, 'TP', ('%d'):format(tp))
end

-- Status icons come out of the game's own resources, decoded once per effect
-- id and then cached - the route statustimers and HXUI both take. A failure
-- caches false so a bad id is not re-decoded on every frame.
local iconCache = {}
local function statusIcon(id)
    local hit = iconCache[id]
    if hit ~= nil then return hit.handle end
    local tex = safe(function()
        local icon = AshitaCore:GetResourceManager():GetStatusIconByIndex(id)
        if icon == nil then return nil end
        local out = ffi.new('IDirect3DTexture8*[1]')
        local hr = ffi.C.D3DXCreateTextureFromFileInMemoryEx(
            d3d8.get_device(), icon.Bitmap, icon.ImageSize,
            0xFFFFFFFF, 0xFFFFFFFF, 1, 0, ffi.C.D3DFMT_A8R8G8B8,
            ffi.C.D3DPOOL_MANAGED, ffi.C.D3DX_DEFAULT, ffi.C.D3DX_DEFAULT,
            0xFF000000, nil, nil, out)
        if hr ~= ffi.C.S_OK then return nil end
        return d3d8.gc_safe_release(ffi.cast('IDirect3DTexture8*', out[0]))
    end, nil)
    -- imgui.Image takes the texture as a plain number. Handing it the cdata
    -- draws a white box - the same cast HXUI does on the way out of its own
    -- cache (HXUI statushandler.lua). The cdata still has to be held onto:
    -- gc_safe_release put a finalizer on it, so letting it be collected would
    -- release the texture out from under the handle.
    iconCache[id] = {
        tex    = tex,
        handle = (tex ~= nil) and tonumber(ffi.cast('uint32_t', tex)) or false,
    }
    return iconCache[id].handle
end

-- The element symbols: assets/elements/<element>.png (the game's own element
-- gems as shipped by the mobdb addon, see the README there), loaded once
-- through D3DX - the d3d8 library
-- declares D3DXCreateTextureFromFileA. A missing or unloadable file falls
-- back to the maneuver status icon (300..307 = Fire..Dark), and false when
-- neither loads: callers then fall back to the two-letter token.
local ELEMENT_INDEX = {}
for i, el in ipairs(ELEMENTS) do ELEMENT_INDEX[el] = i end
local elementIconCache = {}
local function elementIcon(el)
    local hit = elementIconCache[el]
    if hit ~= nil then return hit.handle end
    local i = ELEMENT_INDEX[el]
    if i == nil then return false end
    local tex = safe(function()
        local path = (addon.path or ''):gsub('[/\\]+$', '') .. '/assets/elements/' .. el:lower() .. '.png'
        local out = ffi.new('IDirect3DTexture8*[1]')
        if ffi.C.D3DXCreateTextureFromFileA(d3d8.get_device(), path, out) ~= ffi.C.S_OK then return nil end
        return d3d8.gc_safe_release(ffi.cast('IDirect3DTexture8*', out[0]))
    end, nil)
    local handle = (tex ~= nil) and tonumber(ffi.cast('uint32_t', tex)) or nil
    if handle == nil then handle = statusIcon(EFFECT_MANEUVER_1 + i - 1) end
    elementIconCache[el] = { tex = tex, handle = handle }
    return handle
end
tm.elementIcon = elementIcon   -- how tm.gem, above, reaches it

local function statusName(id)
    return safe(function()
        return AshitaCore:GetResourceManager():GetString('buffs.names', id)
    end, nil) or ('effect %d'):format(id)
end

-- The cached name, but only for the target it was actually read for. Without
-- the stamp a target that never resolves keeps the previous mob's name.
tm.targetName = function()
    if tm.demo ~= nil then return tm.mobName or '?' end
    if tm.mobNameFor ~= tm.petTarget then return '?' end
    return tm.mobName or '?'
end

-- What the automaton is fighting, and how far along that fight is. petTarget
-- is the only engagement signal the client has - the server id of whatever the
-- automaton last ACTED on - so this is the automaton's target, which need not
-- be the master's. It is cleared on every lifecycle edge, so a dismissed or
-- resummoned automaton starts NOT ENGAGED rather than on a stale target.
--
-- HP% is all the entity table carries for a mob - no absolute HP, no max - so
-- the bar is a percentage and says so.
tm.targetRow = function()
    if not config.show_target then return end
    -- Nothing to fight: said outright rather than by leaving the row out, so
    -- nothing under it moves.
    if tm.petTarget == 0 then
        tm.text('label', COL_DIM, 'target')
        imgui.SameLine()
        tm.text('text', COL_DIM, 'NOT ENGAGED')
        return
    end
    local slot = tm.mobSlot()
    local pad  = imgui.GetStyle().ItemSpacing.x
    if slot == nil then
        -- Out of the entity table: too far to render, or dead and despawned.
        -- The last name is kept so a one-frame flap does not blank the row.
        tm.text('label', COL_DIM, 'target')
        imgui.SameLine()
        tm.text('text', COL_DIM, ('%s - out of sight'):format(tm.targetName()))
        tip('Too far away to read, or dead.')
        return
    end
    local hpp = tm.mobHpp(slot)
    -- Still in the entity table at zero: it is dead, not on 0% of its health -
    -- the server never reports a living mob below 1.
    if hpp <= 0 then
        tm.text('label', COL_DIM, 'target')
        imgui.SameLine()
        tm.text('text', COL_DIM, 'NOT ENGAGED')
        return
    end
    -- The name takes a third of the row and the bar the rest, so a long mob
    -- name cannot squeeze the bar away. Truncated, never wrapped: this row
    -- sits between the vitals and the tab bar and must stay one line tall.
    local nameW = hudInner() / 3
    tm.text('label', COL_DIM, tm.fit(tm.targetName(), nameW, 'label'))
    imgui.SameLine(hudPad() + nameW, 0)
    -- NOT the pet's green/amber/red scale. On a mob a low bar is good news, so
    -- that scale would read backwards - red at exactly the moment things are
    -- going well. One colour, the game's own enemy-bar convention.
    tm.bar(nil, hpp / 100, ('%d%%'):format(hpp), COL_MOB,
           hudInner() - nameW - tm.width('label', '100%') - pad, 6)
    tip('What the automaton last acted on - not necessarily your target.')
end

-- Which effects are debuffs: XIUI's classification (libs/bufftable.lua,
-- statusEffects = 1), the one its pet bar draws with. Everything else
-- is a buff.
tm.debuff = {}
for id in ('1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 28 29 30 31 128 129 130 131 132 133 134 135 136 137 138 139 140 141 142 143 144 145 146 147 148 149 155 156 168 171 172 173 174 175 186 189 192 193 194 259 260 261 262 263 264 291 298 299 309 391 392 393 394 395 396 397 398 399 400 404 448 449 450 451 452 536 557 558 559 560 561 562 563 564 565 566 567 572 576 597 630 631'):gmatch('%d+') do
    tm.debuff[tonumber(id)] = true
end

-- The strip's two halves, each oldest first: what the automaton has going
-- for it, and what is on it. Pure - the harness reads it straight.
tm.petStrip = function(now)
    local buffs, debuffs = {}, {}
    for id, at in pairs(petEffects) do
        if tm.petLive(id, now) then
            local list = tm.debuff[id] and debuffs or buffs
            list[#list + 1] = { id = id, at = at }
        elseif now - at > MAX_EFFECT_AGE then
            petEffects[id], tm.petUntil[id] = nil, nil   -- long dead: drop it
        end
    end
    local byAge = function(a, b) return a.at < b.at end
    table.sort(buffs, byAge)
    table.sort(debuffs, byAge)
    return buffs, debuffs
end

-- Buffs on the left, debuffs on the right, each oldest first. No countdown
-- for a bare message (the server never said how long); the tooltip reports
-- how long the effect has been up, or what is left when the landing came
-- with a clock. Draws nothing at all when the automaton is clean.
local function petStatusStrip()
    local now = os.clock()
    local buffs, debuffs = tm.petStrip(now)
    if #buffs == 0 and #debuffs == 0 then return end
    local size = tm.s(imgui.GetStyle().FontSizeBase * 1.5)
    local gap  = imgui.GetStyle().ItemSpacing.x
    local function icon(ef)
        local tex = statusIcon(ef.id)
        if tex then
            imgui.Image(tex, { size, size })
        else
            tm.text('text', COL_DIM, '?')
        end
        -- The id is in the tooltip on purpose: this list is inferred, so being
        -- able to read the raw effect id off a wrong-looking icon is the only
        -- way to tell a bad message mapping from a bad icon.
        local ends = tm.petUntil[ef.id]
        local clock = ends and ('%ds left'):format(math.max(0, math.ceil(ends - now)))
                      or ('up %ds'):format(math.floor(now - ef.at))
        tip(('%s (#%d, %s)\n%s, estimated')
            :format(statusName(ef.id), ef.id, tm.debuff[ef.id] and 'debuff' or 'buff', clock))
    end
    for i, ef in ipairs(buffs) do
        if i > 1 then imgui.SameLine() end
        icon(ef)
    end
    if #debuffs > 0 then
        -- Right-aligned to the content edge, where the vitals bars end - the
        -- way the distance sits at the end of the name line. If the two
        -- halves cannot share the row, the debuffs take the next one.
        local wantW = #debuffs * size + (#debuffs - 1) * gap
        local haveW = #buffs * (size + gap)
        local x = hudPad() + hudInner() - wantW
        if #buffs == 0 then
            imgui.Dummy({ 0, size })   -- an item to be on the same line as
            imgui.SameLine(x, 0)
        elseif haveW + gap + wantW <= hudInner() then
            imgui.SameLine(x, 0)
        else
            imgui.Dummy({ 0, 0 })
            imgui.SameLine(x, 0)
        end
        for i, ef in ipairs(debuffs) do
            if i > 1 then imgui.SameLine() end
            icon(ef)
        end
    end
end

-- The dimming over a recast cell that is not ready. tm.u32 caches on the table
-- itself, so this is one table, not a literal per frame.
local CELL_SCRIM = { 0, 0, 0, 0.55 }
-- The icon of the ITEM that grants an ability - the attachment worn or the
-- frame out - straight from the client's resource table, which is the same
-- bitmap the Automaton equipment screen draws. IItem carries Bitmap and
-- ImageSize exactly as IStatusIcon does, so this is statusIcon's loader keyed
-- by item id; itemIcon, below, resolves a name to that id through the set
-- store's name map, and a tier ('Strobe II') is its own icon.
local itemIconCache = {}
local function itemIconById(id)
    if id == nil then return false end
    local hit = itemIconCache[id]
    if hit ~= nil then return hit.handle end
    local tex = safe(function()
        local item = AshitaCore:GetResourceManager():GetItemById(id)
        if item == nil or item.Bitmap == nil or item.ImageSize == nil then return nil end
        local out = ffi.new('IDirect3DTexture8*[1]')
        local hr = ffi.C.D3DXCreateTextureFromFileInMemoryEx(
            d3d8.get_device(), item.Bitmap, item.ImageSize,
            0xFFFFFFFF, 0xFFFFFFFF, 1, 0, ffi.C.D3DFMT_A8R8G8B8,
            ffi.C.D3DPOOL_MANAGED, ffi.C.D3DX_DEFAULT, ffi.C.D3DX_DEFAULT,
            0xFF000000, nil, nil, out)
        if hr ~= ffi.C.S_OK then return nil end
        return d3d8.gc_safe_release(ffi.cast('IDirect3DTexture8*', out[0]))
    end, nil)
    -- held for the same reason the status icons are: gc_safe_release put a
    -- finalizer on the cdata, so dropping it releases the texture underneath
    itemIconCache[id] = {
        tex    = tex,
        handle = (tex ~= nil) and tonumber(ffi.cast('uint32_t', tex)) or false,
    }
    return itemIconCache[id].handle
end

-- Art the client does not have, shipped with the addon. Same loader the element
-- gems use: a file under assets/, straight to a texture.
local pngIconCache = {}
local function pngIcon(name)
    local hit = pngIconCache[name]
    if hit ~= nil then return hit.handle end
    local tex = safe(function()
        local path = (addon.path or ''):gsub('[/\\]+$', '')
                     .. '/assets/abilities/' .. name .. '.png'
        local out = ffi.new('IDirect3DTexture8*[1]')
        if ffi.C.D3DXCreateTextureFromFileA(d3d8.get_device(), path, out) ~= ffi.C.S_OK then
            return nil
        end
        return d3d8.gc_safe_release(ffi.cast('IDirect3DTexture8*', out[0]))
    end, nil)
    pngIconCache[name] = {
        tex    = tex,
        handle = (tex ~= nil) and tonumber(ffi.cast('uint32_t', tex)) or false,
    }
    return pngIconCache[name].handle
end

-- An item's icon by name, which is what the granting attachment or frame is
-- known by.
local function itemIcon(name)
    if name == nil then return false end
    local map = S.itemIds()
    return itemIconById((map.attachment[name] and ATTACH_OFFSET + map.attachment[name])
                     or (map.frame[name] and EQUIP_OFFSET + map.frame[name]) or nil)
end

-- The art a cell should show, and what kind it is - the kind goes in the tooltip,
-- because a wrong-looking icon is only diagnosable if you can see which table
-- chose it (the same reason the pet strip prints its raw effect id).
local function abilityArt(r)
    local m = ABILITY_ICON[r.id]
    if m ~= nil and m.status ~= nil then return statusIcon(m.status), statusName(m.status) end
    if m ~= nil and m.item ~= nil then return itemIconById(m.item), nil end
    -- shipped art falls back to the attachment if the file is missing
    if m ~= nil and m.png ~= nil then
        local tex = pngIcon(m.png)
        if tex then return tex, nil end
    end
    return itemIcon(r.grant), r.grant
end

-- How wide one ability cell is. Not the icon's size: the seconds are drawn
-- ON the icon, so the cell has to hold the widest string fmtLeft can produce
-- ('20s' under a minute, '3:00' over it) or the text runs over the
-- neighbouring cells.
local function cellW()
    return math.max(tm.dpx('text'), tm.width('label', '00s'), tm.width('label', '0:00')) + tm.s(4)
end

-- One ability's cell, for the compact strip and tm.recastCell: the granting
-- item's icon, with the state drawn over it rather than beside it. Ready is
-- the icon at full brightness inside a green outline; counting dims it under
-- a scrim; not-seen-since-load is the same scrim. Falls back to the plain
-- square when the icon will not load, so a client that refuses one still
-- shows the strip.
-- `showRemaining` draws the countdown ON the icon, which is what the compact
-- strip needs because it has no room beside the cell. The Status page prints
-- the seconds next to the icon already, so it leaves this off and the state
-- reads from the green outline and the scrim alone.
local function abilityCell(r, showRemaining)
    local sz = cellW()
    local tex = abilityArt(r)
    if not tex then
        tm.square(r.state, (r.state == 'counting')
                           and (1 - r.remaining / math.max(1, r.model or 1)) or 0)
        return
    end
    local x, y = imgui.GetCursorScreenPos()
    local dl = imgui.GetWindowDrawList()
    imgui.Image(tex, { sz, sz })
    if r.state == 'ready' then
        local o = tm.s(1)
        dl:AddRect({ x - o, y - o }, { x + sz + o, y + sz + o }, tm.u32(COL_GOOD), tm.s(3))
    else
        dl:AddRectFilled({ x, y }, { x + sz, y + sz }, tm.u32(CELL_SCRIM), tm.s(3))
        if not showRemaining then return end
        local txt = (r.state == 'counting') and tm.fmtLeft(r.remaining) or '?'
        -- tm.text draws at the cursor and advances it; this has to land ON the
        -- icon, so it is the same shadow-then-fill pass done in place.
        imgui.PushFont(tm.font, tm.px('label'))
        local w, h = imgui.CalcTextSize(txt)
        local tx, ty = x + (sz - w) / 2, y + (sz - h) / 2
        dl:AddText({ tx + tm.s(1), ty + tm.s(1) }, tm.SHADOW, txt)
        dl:AddText({ tx, ty }, tm.u32((r.state == 'counting') and COL_TEXT or COL_DIM), txt)
        imgui.PopFont()
    end
end

-- Seconds left as the cells print them: '20s' under a minute, '3:00' over it.
tm.fmtLeft = function(s)
    s = math.ceil(s)
    if s < 60 then return ('%ds'):format(s) end
    return ('%d:%02d'):format(math.floor(s / 60), s % 60)
end
-- One recast cell: the square, the label, the seconds or `ready` or `?`, and
-- the tooltip. Shared by the column beside the table and the footer line.
-- labelW pads every label to the widest in its group, so the values end level
-- however the abilities are named.
tm.recastCell = function(r, labelW)
    local txt = (r.state == 'counting' and tm.fmtLeft(r.remaining))
             or (r.state == 'ready' and 'ready') or '?'
    abilityCell(r)
    imgui.SameLine(0, tm.s(3))
    tm.text('label', COL_DIM, r.label)
    imgui.SameLine(0, tm.s(4) + math.max(0, (labelW or 0) - tm.width('label', r.label)))
    tm.text('text', (r.state == 'ready') and COL_GOOD or (r.state == 'counting') and COL_TEXT or COL_DIM, txt)
    tip(('%s: %ds recast. Ready means usable, not that it is about to\nfire. ? = not used since the addon loaded.')
        :format(r.name, r.model))
end

-- The maneuver table's column origins, as absolute SameLine offsets rather
-- than an ImGui table. An ImGui table sizes its LAST column down to a single
-- character - an 18% overload chance drawn as '1' - and its arithmetic
-- is exactly the part no offline test can reach: the harness's ImGui is a
-- stub, so BeginTable's internal width negotiation never runs. Every x here is
-- one the harness records and can assert, and the rest of the HUD lays out the
-- same way.
-- Origins are cumulative, each measured off the widest string its column can
-- actually hold - header or cell, whichever is longer - plus EL_GAP, so they
-- follow whatever font Ashita is running rather than a pixel guess. x[6] is
-- where the table ends and the recast column starts.
local EL_GAP = 10
tm.elCols = function()
    local function widest(a, b)
        local wa, wb = tm.width('text', a), tm.width('text', b)
        return (wa > wb) and wa or wb
    end
    local gap = tm.s(EL_GAP)
    local x = { hudPad() }
    x[2] = x[1] + widest('#', '3') + gap
    x[3] = x[2] + tm.dpx('text') + gap   -- the gem alone: the name is its tooltip
    x[4] = x[3] + widest('left', '300s') + gap
    x[5] = x[4] + widest('burden', '105') + gap
    x[6] = x[5] + widest('OL%', '100%')   -- where the table ends
    return x
end
-- `text` cut to `width` at the voice `kind`, with a trailing '..', so a string
-- cannot run under whatever sits beside it.
tm.fit = function(text, width, kind)
    kind = kind or 'text'
    if tm.width(kind, text) <= width then return text end
    local n = text
    while #n > 3 and tm.width(kind, n .. '..') > width do n = n:sub(1, -2) end
    return n .. '..'
end

-- The icon caches are cleared in place, never replaced: the hook holds them.
local function resetIcons()
    tm.clear(iconCache) tm.clear(elementIconCache)
    tm.clear(itemIconCache) tm.clear(pngIconCache)
end

return { EL_COLOR = EL_COLOR, COL_GOOD = COL_GOOD, COL_WARN = COL_WARN, COL_BAD = COL_BAD,
         COL_DIM = COL_DIM, COL_TEXT = COL_TEXT, COL_MP = COL_MP, COL_TP = COL_TP,
         COL_TPUP = COL_TPUP, COL_MOB = COL_MOB, HUD_FLAGS = HUD_FLAGS,
         hudPad = hudPad, hudInner = hudInner, hudText = hudText, tip = tip, vitals = vitals,
         elementIcon = elementIcon, petStatusStrip = petStatusStrip, resetIcons = resetIcons,
         abilityCell = abilityCell, cellW = cellW, abilityArt = abilityArt }
