-- --------------------------------------------------------- ashita stubs --
local handlers, printed = {}, {}
addon = { name = '', author = '', version = '', desc = '', path = ADDON_DIR }

local function winpath(p) return (p:gsub('/+$', ''):gsub('/', '\\')) end

ashita = {
    events = { register = function(event, _, fn) handlers[event] = fn end },
    -- LSB-first bit fields, as the 0x028 parser reads them; build028 below
    -- packs the same way, so the pair is self-consistent whatever Ashita's
    -- own bit order is - what gets tested is the addon's field layout.
    bits   = { unpack_be = function(bytes, offset, len)
                   local v = 0
                   for i = 0, len - 1 do
                       local k = offset + i
                       local byte = bytes[math.floor(k / 8) + 1] or 0
                       if math.floor(byte / 2 ^ (k % 8)) % 2 == 1 then v = v + 2 ^ i end
                   end
                   return v
               end },
    memory = {
        -- world.signatureMissing plays a client whose code the scan cannot find
        find        = function() if world.signatureMissing then return 0 end return 0x1000 end,
        read_uint32 = function() return 0x3000 end,
        read_uint8  = function() return 0 end,
        read_string = function() return '' end,
        read_array  = function() return world.buffer end,
    },
    fs = {
        create_directory = function(p) os.execute('mkdir "' .. winpath(p) .. '" 2>nul') return true end,
        get_directory = function(p, mask)
            local out, ph = {}, io.popen('dir /b "' .. winpath(p) .. '" 2>nul')
            if ph == nil then return out end
            for line in ph:lines() do
                if mask == nil or line:match('%.txt$') then out[#out + 1] = line end
            end
            ph:close()
            return out
        end,
        exists = function(p) local f = io.open(p, 'r') if f then f:close() return true end return false end,
        remove = function(p) return os.remove(p) ~= nil end,
    },
    tasks = { once = function(_, fn) world.task = coroutine.create(fn) return world.task end },
}
coroutine.sleep = function(s)
    local t = world.sleeps                -- the apply fixtures read the durations back
    if t ~= nil then t[#t + 1] = s end
    coroutine.yield()
end

local realPrint = print
print = function(s) printed[#printed + 1] = tostring(s) end

package.preload['common'] = function()
    -- the one common extension the addon uses: '/cw a b':args()
    string.args = function(s) local t = {} for w in s:gmatch('%S+') do t[#t + 1] = w end return t end
    string.totable = function(s) local t = {} for i = 1, #s do t[i] = s:byte(i) end return t end
    return {}
end
package.preload['chat'] = function()
    local function passthru(s) return tostring(s) end
    return {
        -- chainable, as the real one is: flagAnomaly appends twice
        header  = function(s) return setmetatable({ v = s .. ':' }, {
                      __index = { append = function(self, x) self.v = self.v .. ' ' .. tostring(x) return self end },
                      __tostring = function(self) return self.v end }) end,
        message = passthru, error = passthru, success = passthru, warning = passthru,
    }
end
package.preload['d3d8'] = function()
    return { get_device = function() return nil end, gc_safe_release = function(x) return x end }
end
-- LuaJIT's own ffi, captured before the stub takes its place: the file
-- replace in cw/util.lua goes through kernel32's MoveFileExA, and the stub
-- hands that one call to the real thing - with a switch to make it fail.
-- require(), then forget it was loaded: the loader registers the real module
-- in package.loaded, and left there the addon's own require('ffi') got the
-- real ffi instead of the stub below - and its equipex cast then segfaulted.
local realFfi = require('ffi')
package.loaded['ffi'] = nil
if realFfi ~= nil then
    pcall(realFfi.cdef, [[
        int MoveFileExA(const char* from, const char* to, unsigned int flags);
        unsigned int GetLastError(void);
    ]])
end
package.preload['ffi'] = function()
    return {
        -- as LuaJIT: a declaration is accepted once, and a repeat of the same
        -- text raises (attempt to redefine)
        cdef = (function()
            local declared = {}
            return function(text)
                if declared[text] then error('attempt to redefine a typedef (harness ffi)') end
                declared[text] = true
            end
        end)(),
        C = { S_OK = 0, D3DFMT_A8R8G8B8 = 21, D3DPOOL_MANAGED = 1, D3DX_DEFAULT = -1,
              MoveFileExA = function(from, to, flags)
                  if world.replaceFails then return 0 end
                  return realFfi.C.MoveFileExA(from, to, flags)
              end,
              GetLastError = function() return world.replaceFails and 5 or 0 end,
              D3DXCreateTextureFromFileInMemoryEx = function() return world.iconsAvailable and 0 or 1 end,
              D3DXCreateTextureFromFileA = function(_, path)
                  world.lastPng = path
                  return world.pngAvailable and 0 or 1
              end },
        new = function() return {} end,
        cast = function(ctype, v)
            if ctype == 'equipex_t' then
                return function(isSub, job, index, id)
                    -- an error raised INSIDE the task body, which is the whole
                    -- of what the finaliser has to survive
                    if world.equipThrow then world.equipThrow = nil error('equipex blew up') end
                    local rc = world.equipRc or 1   -- the real one: 1 accepted, 0 refused
                    if world.refuseFirst and #world.equipCalls < world.refuseFirst then rc = 0 end
                    world.equipCalls[#world.equipCalls + 1] = { isSub, job, index, id, rc = rc }
                    return rc
                end
            end
            if ctype == 'uint32_t' then return 0x100 end      -- a texture handle
            if ctype:match('%*$') then return { [0] = 0x100 } end
            return v
        end,
        string = function() return '' end, sizeof = function() return 0 end,
        fill = function() end, copy = function() end,
    }
end

-- imgui: permissive, but value-returning calls answer with the right shape so
-- a render smoke test cannot die on `false.ItemSpacing`. Begin/Push calls
-- are counted against their End/Pop so a frame can be checked for balance;
-- Button and Selectable answer true once for a label in `clicks`; InputText
-- writes `typed` into its buffer. Begin* names in `answerFalse` answer false.
local drawn, clicks, typed, answerFalse, depth = {}, {}, nil, {}, {}
local typedBox = {}             -- label -> the text a test types and enters
-- The size stack PushFont builds, so a font-aware CalcTextSize can answer at
-- the size actually pushed. Only world.fontAware reads it; every other block
-- keeps the flat text model its numbers were written against.
local fontPx = {}
local availCalls = 0            -- GetContentRegionAvail calls this frame; must stay 0
local addTexts, dummies = 0, 0  -- draw-list strings, and the Dummy items that reserve room for them
local hoverArmed = false        -- IsItemHovered answers true once after the InvisibleButton in world.hover
local shadowCol = nil           -- tm.SHADOW once the addon exports it; that pass is not recorded
local OUTLINE_COL = 0xFF000000  -- tm.head's four-way outline, and tm.bar's: decoration, not a string

-- The window draw list, recorded. A string goes down bare - the same record
-- TextColored leaves - so a check written against a widget keeps its meaning
-- when the string moves onto the draw list. The shadow pass is skipped by its
-- colour so a shadow-then-fill string counts once. Rects and circles are
-- counted, not measured: layout is asserted through the DUMMY the helper
-- reserves, never through pixel maths the stub cannot do.
local drawList = {
    AddText = function(_, a, b, c, d, e)
        -- (pos, col, text) or (font, size, pos, col, text)
        local col, text = b, c
        if e ~= nil then col, text = d, e end
        if col == OUTLINE_COL or (shadowCol ~= nil and col == shadowCol) then return end
        addTexts = addTexts + 1
        drawn[#drawn + 1] = tostring(text)
    end,
    AddRectFilled           = function() drawn[#drawn + 1] = 'RECT' end,
    AddRectFilledMultiColor = function() drawn[#drawn + 1] = 'RECT' end,
    AddRect                 = function() drawn[#drawn + 1] = 'RECT' end,
    AddCircleFilled         = function() drawn[#drawn + 1] = 'CIRC' end,
    AddImage                = function(_, tex) drawn[#drawn + 1] = 'IMG:' .. tostring(tex) end,
}
local OPENS = { Begin = true, BeginChild = true, BeginTable = true, BeginTabBar = true,
                BeginTabItem = true, BeginCombo = true, BeginPopup = true }
local PAIRS = { Begin = 'End', BeginChild = 'EndChild', BeginTable = 'EndTable',
                BeginTabBar = 'EndTabBar', BeginTabItem = 'EndTabItem', BeginCombo = 'EndCombo', BeginPopup = 'EndPopup',
                -- BeginGroup was not always tracked here, and that hole let a pair of
                -- EndGroup calls survive their BeginGroup being deleted: the suite
                -- passed while the main window drew squashed to half its width.
                -- Group balance is layout correctness, same as the rest.
                BeginGroup = 'EndGroup',
                BeginDisabled = 'EndDisabled', PushItemWidth = 'PopItemWidth',
                PushStyleVar = 'PopStyleVar', PushStyleColor = 'PopStyleColor',
                PushTextWrapPos = 'PopTextWrapPos', PushFont = 'PopFont' }
local CLOSES = {}
for open, close in pairs(PAIRS) do CLOSES[close] = open end
local RETURNS = {
    -- FontScaleMain and FontScaleDpi are ImGui 1.92's own scales, which it
    -- multiplies onto every size the addon pushes. world.fontScaleMain lets a
    -- test raise the player's global scale, which the layout has to follow.
    GetStyle              = function()
        return { ItemSpacing = { x = 8, y = 3 }, FontSizeBase = 14,
                 FontScaleMain = world.fontScaleMain or 1,
                 FontScaleDpi  = world.fontScaleDpi or 1 }
    end,
    GetContentRegionAvail = function() availCalls = availCalls + 1 return 300 end,
    -- A constant by default, because most tests only care that a width was
    -- SET. world.textWidth switches it to 7px per character, which is the only
    -- way anything that truncates or wraps to fit can be exercised at all.
    CalcTextSize          = function(s)
        local w, h = 20, 14
        if world.textWidth then w = #tostring(s) * 7 end
        -- Real text grows with the size pushed; the flat model above does not,
        -- which is fine for a layout measured at one scale and useless for one
        -- measured at two. world.fontAware turns the size back on: 14 is this
        -- stub's FontSizeBase, so the factor is 1 at the stock scale and every
        -- number the existing blocks assert is unchanged.
        if world.fontAware then
            local px = fontPx[#fontPx]
            if px ~= nil and px > 0 then
                local f = px / 14
                w, h = math.floor(w * f + 0.5), math.floor(h * f + 0.5)
            end
        end
        return w, h
    end,
    -- the main window's position, which the sidebar's first-use placement reads
    GetWindowPos          = function() return 100, 200 end,
    GetItemRectMin        = function() return 0, 0 end,
    GetItemRectMax        = function() return 100, 14 end,
    GetWindowDrawList     = function() return drawList end,
    GetCursorScreenPos    = function() return 10, 10 end,
    GetColorU32           = function() return 0xFFFFFFFF end,
    Image                 = function(tex) drawn[#drawn + 1] = 'IMG:' .. tostring(tex) end,
    AddFontFromFileTTF    = function() return { font = true } end,
    IsItemHovered         = function() local h = hoverArmed hoverArmed = false return h end,
}
package.preload['imgui'] = function()
    -- The VALUES Ashita 4.3 defines, checked against adn/libs/imgui.lua (which
    -- names the ImGui commit it was cut from). Five StyleVars and PlotHistogram
    -- were a older ImGui's numbers until 1.17.0 - harmless, since the stub only
    -- passes them through, and wrong in a file whose whole point is fidelity.
    rawset(_G, 'ImGuiChildFlags_Borders',            1)
    rawset(_G, 'ImGuiCond_FirstUseEver',             4)
    rawset(_G, 'ImGuiTableFlags_SizingFixedFit',     8192)
    rawset(_G, 'ImGuiTableFlags_SizingStretchProp',  3 * 8192)
    rawset(_G, 'ImGuiTableColumnFlags_WidthFixed',   16)
    rawset(_G, 'ImGuiStyleVar_ItemSpacing',          14)
    rawset(_G, 'ImGuiCol_PlotHistogram',             45)
    rawset(_G, 'ImGuiComboFlags_None',               0)
    rawset(_G, 'ImGuiInputTextFlags_EnterReturnsTrue', 64)
    rawset(_G, 'ImGuiWindowFlags_NoTitleBar',        1)
    rawset(_G, 'ImGuiWindowFlags_NoScrollbar',       8)
    rawset(_G, 'ImGuiWindowFlags_NoCollapse',        32)
    rawset(_G, 'ImGuiWindowFlags_AlwaysAutoResize',  64)
    rawset(_G, 'ImGuiStyleVar_WindowPadding',        2)
    rawset(_G, 'ImGuiStyleVar_WindowRounding',       3)
    rawset(_G, 'ImGuiStyleVar_WindowBorderSize',     4)
    rawset(_G, 'ImGuiStyleVar_FramePadding',         11)
    rawset(_G, 'ImGuiStyleVar_FrameRounding',        12)
    rawset(_G, 'ImGuiCol_WindowBg',                  2)
    rawset(_G, 'ImGuiCol_Text',                      0)
    rawset(_G, 'ImGuiCol_FrameBg',                   7)
    -- STRICT. A permissive __index made a misspelled ImGui call a silent no-op
    -- offline and a per-frame nil call in game: `imgui.Separator` mistyped
    -- passed 924 checks and drew nothing. Anything the addon calls has to be
    -- named here, so adding a call means adding it to KNOWN as well.
    local KNOWN = {}
    for _, k in ipairs({
        'Begin','End','BeginChild','EndChild','BeginTable','EndTable','BeginTabBar','EndTabBar',
        'BeginTabItem','EndTabItem','BeginCombo','EndCombo','BeginPopup','EndPopup','BeginGroup',
        'EndGroup','BeginDisabled','EndDisabled','PushItemWidth','PopItemWidth','PushStyleVar',
        'PopStyleVar','PushStyleColor','PopStyleColor','PushTextWrapPos','PopTextWrapPos',
        'Text','TextWrapped','TextColored','TextDisabled','TextUnformatted','Button','SmallButton',
        'Selectable','Checkbox','SliderInt','SliderFloat','InputText','InputInt','Combo',
        'Separator','SeparatorText','SameLine','Spacing','NewLine','Dummy','Indent','Unindent',
        'TableNextRow','TableNextColumn','TableSetColumnIndex','TableSetupColumn',
        'TableHeadersRow','TableSetupScrollFreeze','SetTooltip','SetNextWindowSize',
        'SetNextWindowPos','SetNextWindowBgAlpha','SetNextItemWidth','SetCursorPosX',
        'SetCursorPosY','SetCursorPos','GetCursorPosX','GetCursorPosY','OpenPopup','CloseCurrentPopup',
        'IsItemClicked','IsItemActive','IsMouseDoubleClicked','ProgressBar','Image','ImageButton',
        'PlotLines','PlotHistogram','CalcTextSize','GetStyle','GetContentRegionAvail',
        'GetWindowPos','GetWindowSize','GetItemRectMin','GetItemRectMax','IsItemHovered',
        'GetWindowDrawList','GetFontSize','SetWindowFontScale','PushFont','PopFont','PushID','PopID',
        'AlignTextToFramePadding','BulletText','Bullet','LabelText','RadioButton','ColorEdit3',
        'ColorEdit4','InputFloat','DragInt','DragFloat','Columns','NextColumn','SetColumnWidth',
        'GetColumnWidth','TreeNode','TreePop','CollapsingHeader','Value','ShowDemoWindow','InvisibleButton',
    }) do KNOWN[k] = true end
    return setmetatable({}, { __index = function(_, key)
        if RETURNS[key] then return RETURNS[key] end
        if not KNOWN[key] then
            error('imgui.' .. tostring(key) .. ' is not a stubbed ImGui call - '
                  .. 'add it to KNOWN in test/fixtures/stubs.lua if it is real, or fix the typo', 2)
        end
        return function(...)
            local args = { ... }
            if key == 'PushFont' then fontPx[#fontPx + 1] = args[2] end
            if key == 'PopFont'  then fontPx[#fontPx] = nil end
            if PAIRS[key] then depth[key] = (depth[key] or 0) + 1 end
            if CLOSES[key] then
                local open = CLOSES[key]
                depth[open] = (depth[open] or 0) - ((type(args[1]) == 'number') and args[1] or 1)
                if depth[open] < 0 then error(key .. ' without ' .. open) end
            end
            if key == 'BeginTable' and type(args[4]) == 'table' then
                drawn[#drawn + 1] = 'TABLE:' .. tostring(args[1]) .. ':' .. tostring(args[4][1])
            end
            -- Column headers are drawn by TableHeadersRow inside ImGui, so the
            -- only place their text is visible to a test is where it is declared.
            if key == 'TableSetupColumn' then
                drawn[#drawn + 1] = 'COL:' .. tostring(args[1])
            end
            if OPENS[key] then
                drawn[#drawn + 1] = 'WINDOW:' .. tostring(args[1])
                return not answerFalse[key]
            end
            if key == 'Text' or key == 'TextWrapped' then drawn[#drawn + 1] = tostring(args[1]) end
            if key == 'TextColored' then drawn[#drawn + 1] = tostring(args[2]) end
            -- WHICH text was drawn inside a wrap, not merely that some wrap was
            -- pushed: every tab draws in this stub, so a bare count of wraps is
            -- satisfied by whatever the Loadout tab happens to wrap.
            if (key == 'Text' or key == 'TextWrapped' or key == 'TextColored')
               and (depth['PushTextWrapPos'] or 0) > 0 then
                drawn[#drawn + 1] = 'WRAPPED:' ..
                    tostring((key == 'TextColored') and args[2] or args[1])
            end
            -- SmallButton is a button for every purpose that matters here: it
            -- draws a label and answers a click. The sidebar toggle uses it.
            if key == 'Button' or key == 'SmallButton' or key == 'Selectable' then
                drawn[#drawn + 1] = 'BTN:' .. tostring(args[1])
                if clicks[args[1]] then clicks[args[1]] = nil return true end
            end
            -- Checkbox and SliderInt carry the Settings tab, and neither was
            -- visible to a test before it existed. A checkbox in `clicks`
            -- FLIPS its buffer and reports the change, which is what ImGui
            -- does and what lets a test prove the value writes through.
            if key == 'Checkbox' then
                drawn[#drawn + 1] = 'CHK:' .. tostring(args[1])
                if clicks[args[1]] then
                    clicks[args[1]] = nil
                    args[2][1] = not args[2][1]
                    return true
                end
            end
            if key == 'SliderInt' then
                drawn[#drawn + 1] = 'SLIDER:' .. tostring(args[1])
            end
            -- A typed box, recorded with the text it is DISPLAYING and the
            -- flags it asked for - the second is the only way an offline stub
            -- can check that the value applies on Enter and not while typing.
            -- A label in `typedBox` is that Enter: the text goes into the
            -- buffer and the call answers true, once, as ImGui does.
            if key == 'InputText' then
                drawn[#drawn + 1] = ('TXT:%s:%s'):format(tostring(args[1]),
                                                         tostring(args[2] and args[2][1]))
                drawn[#drawn + 1] = 'TXTFLAGS:' .. tostring(args[4])
                local v = typedBox[args[1]]
                if v ~= nil then typedBox[args[1]] = nil args[2][1] = v return true end
            end
            if key == 'Dummy' and type(args[1]) == 'table' then
                dummies = dummies + 1
                drawn[#drawn + 1] = ('DUMMY:%s:%s'):format(tostring(args[1][1]), tostring(args[1][2]))
            end
            -- A drawn thing is not an item; the addon puts an InvisibleButton
            -- under anything it wants hoverable. Recorded like a button, clicked
            -- like a button, and it arms IsItemHovered when world.hover names it.
            if key == 'InvisibleButton' then
                drawn[#drawn + 1] = 'BTN:' .. tostring(args[1])
                if world.hover == args[1] then hoverArmed = true end
                if clicks[args[1]] then clicks[args[1]] = nil return true end
            end
            -- The width the addon ASKS for. Only FirstUseEver reaches the real
            -- ImGui, but what is asserted here is the number the addon computed.
            if key == 'SetNextWindowSize' and type(args[1]) == 'table' then
                drawn[#drawn + 1] = 'WSIZE:' .. tostring(args[1][1])
            end
            if key == 'SetTooltip' then drawn[#drawn + 1] = 'TIP:' .. tostring(args[1]) end
            if key == 'InputText' and typed ~= nil then args[2][1] = typed typed = nil end
            if key == 'PushTextWrapPos' then drawn[#drawn + 1] = 'WRAP:' .. tostring(args[1]) end
            if key == 'Image' then drawn[#drawn + 1] = 'IMG:' .. tostring(args[1]) end
            if key == 'SameLine' and type(args[1]) == 'number' and args[1] > 0 then
                drawn[#drawn + 1] = 'X:' .. tostring(args[1])
            end
            if key == 'SameLine' and (args[1] == nil or args[1] == 0)
               and type(args[2]) == 'number' and args[2] > 0 then
                drawn[#drawn + 1] = 'SP:' .. tostring(args[2])
            end
            return false
        end
    end })
end

-- Method-call convention: the addon calls mgr:Method(i), so stubs take (self, i).
-- Unknown methods answer 0; the ones that must return tables are explicit.
-- STRICT, like the imgui stub: an AshitaCore method the addon calls but the
-- harness has never heard of used to answer 0 silently, so a misremembered
-- name read as "the game says zero" offline and was a nil call in game. Names
-- the addon really uses go in KNOWN_API; the value is still 0.
local KNOWN_API = {}
for _, k in ipairs({
    'GetMainJob','GetSubJob','GetStatusIcons','GetStatusTimers','GetHPMax','GetPetMPPercent',
    'GetPetTP','GetName','GetServerId','GetHPPercent','GetDistance','GetMemberTargetIndex',
    'GetMemberName','GetMemberHP','GetMemberIsActive','GetMemberHPPercent','GetMemberTP',
    'GetContainerItem','GetContainerCount','GetItemById','GetStatusIconByIndex','GetString',
    'GetSpellById','GetAbilityById',
    -- called only from inside safe(), so a permissive stub answered 0 and
    -- nothing ever noticed they were unstubbed
    'GetStat','GetStatModifier','GetEquippedItem','GetMemberMP',
}) do KNOWN_API[k] = true end
local function permissive(explicit)
    return setmetatable(explicit or {}, { __index = function(_, key)
        if not KNOWN_API[key] then
            error('AshitaCore method "' .. tostring(key) .. '" is not stubbed - '
                  .. 'add it to KNOWN_API in test/fixtures/stubs.lua if it is real, or fix the name', 2)
        end
        return function() return 0 end
    end })
end
local player = permissive({
    -- 2 = in game. The addon draws nothing at 0 (character select) or 1.
    GetLoginStatus = function() return world.login or 2 end,
    GetMainJob = function() return world.mainjob end,
    GetSubJob  = function() return world.subjob end,
    GetMainJobLevel = function() return world.mainlvl end,
    GetSubJobLevel  = function() return world.sublvl end,
    GetStatusIcons = function() return world.icons or {} end,     -- 300..307 = maneuvers
    GetStatusTimers = function() return world.timers or {} end,
    GetHPMax = function() return world.maxhp or 0 end,
    -- world.petMppRead = 'nil' answers nothing, 'error' raises: the two ways
    -- one native read can fail while the entity reads around it succeed
    GetPetMPPercent = function()
        if world.petMppRead == 'nil' then return nil end
        if world.petMppRead == 'error' then error('MP read failed') end
        return world.petMpp or 0
    end,
})
AshitaCore = {
    GetInstallPath = function() return SCRATCH end,
    GetMemoryManager = function()
        return {
            GetPlayer = function() return player end,
            GetEntity = function() return permissive({
                -- Per index, not one name for the whole table: the header's
                -- target row names the MOB while the line above it names the
                -- automaton, and a single answer could not tell them apart.
                GetName = function(_, i)
                    if i == world.mobIndex then return world.mobName or 'Steelshell Crab' end
                    return 'Bobeche'
                end,
                GetServerId = function(_, i)
                    if i == world.mobIndex then return world.mobId or 0 end
                    if i == world.petIndex then return world.petId or 0 end
                    return 0
                end,
                GetHPPercent = function(_, i)
                    if i == world.mobIndex then return world.mobHpp or 100 end
                    return world.petHpp or 100
                end,
                -- the game stores distance SQUARED and the addon roots it, so
                -- world.petDist is a real yalm figure and this squares it back
                GetDistance = function() return (world.petDist or 0) ^ 2 end,
            }) end,
            GetParty  = function() return permissive({
                GetMemberTargetIndex = function() return 1 end,
                -- slot 0 is the master; slots 1-5 answer from world.partyNames
                -- and world.partyHp (slot -> name, slot -> current HP)
                GetMemberName = function(_, i)
                    if (i or 0) == 0 then return world.charName or 'Harness' end
                    return (world.partyNames or {})[i] or ('Member' .. i)
                end,
                GetMemberHP = function(_, i)
                    if (i or 0) == 0 then return world.hp or 0 end
                    return (world.partyHp or {})[i] or 0
                end,
                -- slots 1-5 for LSB's Soulsoother + Light party heal. world.party
                -- is a sparse map of slot -> HP%; an absent slot is not in the party.
                GetMemberIsActive = function(_, i)
                    return ((world.party or {})[i] ~= nil) and 1 or 0
                end,
                GetMemberHPPercent = function(_, i)
                    return (world.party or {})[i] or 100
                end,
                -- world.partyIds: slot -> ServerId, for the render snapshot's
                -- party set (a member's blow on a mob counts as ours)
                GetMemberServerId = function(_, i)
                    return (world.partyIds or {})[i] or 0
                end,
                GetMemberTP = function() return world.tp or 0 end,
            }) end,
            GetInventory = function() return permissive({
                -- .Index is a container/slot pair; 0 means the slot is empty,
                -- which is the shape equippedItemId walks
                -- world.gear: 0-based slot -> item id, so a fixture can wear
                -- a piece; each worn slot is container 0, index slot + 1
                GetEquippedItem = function(_, slot)
                    if world.gear and world.gear[slot] then return { Index = slot + 1 } end
                    return world.equipped or { Index = 0 }
                end,
                GetContainerItem = function(_, _, idx)
                    local id = world.gear and world.gear[idx - 1]
                    return id and { Id = id, Count = 1 } or nil
                end,
            }) end,
        }
    end,
    GetPointerManager = function() return { Get = function() return 0x2000 end } end,
    GetResourceManager = function()
        return {
            GetItemById = function(_, id)
                local n = ITEMS[id]
                if n == nil then return nil end
                -- Bitmap/ImageSize are real IItem fields and are what the
                -- compact strip's ability icons load from; withheld with the
                -- status icons so the fallback path can be tested too.
                if world.iconsAvailable then
                    return { Name = { n }, Bitmap = 0, ImageSize = 0 }
                end
                return { Name = { n } }
            end,
            GetStatusIconByIndex = function(_, id)
                if world.iconsAvailable then return { Bitmap = 0, ImageSize = 0, id = id } end
                return nil
            end,
            GetString = function() return nil end,
            GetSpellById = function(_, id)
                if SPELLS[id] == nil then return nil end
                return { Name = { SPELLS[id] } }
            end,
        }
    end,
}
function GetPlayerEntity()
    -- settable so a character switch inside one session can be played: the
    -- log's filename carries the name and its rotation check carries the id
    return { ServerId = world.selfId or 0x01000001, Name = world.charName or 'Harness',
             PetTargetIndex = world.petIndex }
end
function GetEntity(i)
    if i ~= 0 and i == world.petIndex then return { ServerId = world.petId, Name = 'Bobeche' } end
    return nil
end

local fakeClock = 0
os.clock = function() return fakeClock end
local function advance(seconds) fakeClock = fakeClock + seconds end
-- os.date was the one clock nothing could move, and the log's filename is
-- built from it: a fixture that needs a different DAY, not a different second,
-- had no way to say so. world.dayShift is in seconds and shifts every format.
-- Every date defaults to noon of the day the run started, so a run that
-- crosses midnight still names the files its checks expect.
local realDate = os.date
local NOON = realDate('*t')
NOON.hour, NOON.min, NOON.sec = 12, 0, 0
NOON = os.time(NOON)
os.date = function(fmt, t) return realDate(fmt, (t or NOON) + (world.dayShift or 0)) end
