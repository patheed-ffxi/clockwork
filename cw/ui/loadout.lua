-- cw/ui/loadout.lua - the Loadout tab: what the automaton wears, the saved sets,
-- and the preview and apply of one. Owns the tab's UI state (setsUi); exports
-- NO_DATA, refreshSets, selectSet and drawLoadoutTab.
local imgui = require('imgui')
local chat  = require('chat')
local D  = require('cw.data')
local ELEMENTS = D.ELEMENTS
local tm = require('cw.state')
local A  = require('cw.attachments')
local ATTACH_ELEM, attachEffect = A.ATTACH_ELEM, A.attachEffect
local B  = require('cw.burden')
local maneuverCounts = B.maneuverCounts
local S  = require('cw.sets')
local validSetName, listSets, setExists, loadSet = S.validSetName, S.listSets, S.setExists, S.loadSet
local saveSet, deleteSet, renameSet, itemIds = S.saveSet, S.deleteSet, S.renameSet, S.itemIds
local capacityOf, unownedIn, equippedSet, liveSet = S.capacityOf, S.unownedIn, S.equippedSet, S.liveSet
local startApply = S.startApply
local SF = require('cw.ui.surface')
local EL_COLOR, COL_GOOD, COL_WARN, COL_BAD = SF.EL_COLOR, SF.COL_GOOD, SF.COL_WARN, SF.COL_BAD
local COL_DIM, COL_TEXT, hudPad, hudInner = SF.COL_DIM, SF.COL_TEXT, SF.hudPad, SF.hudInner
local hudText, tip, elementIcon = SF.hudText, SF.tip, SF.elementIcon
-- The shared tables, never reassigned after cw/state.lua creates them.
local ids, snap = tm.ids, tm.snap

-- ---------------------------------------------------------- loadout tab --
-- Shown wherever the tab needs the 0x044 and has none: it lists what makes the
-- server send one (LSB: gameok, myroom_job, automaton PostTick,
-- m_EffectsChanged, merits, every 0x102). Opening a menu does not.
local NO_DATA = 'no automaton data from the server yet: zone, change job, activate, equip or unequip any piece of gear or an attachment, or gain any status effect'

-- One tab for what the automaton wears and for the saved sets: one list,
-- one preview.
local setsUi = {
    names = nil,          -- nil = list not read yet
    cache = {},           -- [name] = parsed set (or false when the file is bad)
    selected = nil,       -- nil = the equipped row
    nameBuf = { '' },     -- InputText buffer
    confirm = nil,        -- { action = 'save'|'delete', name = x, at = clock } - second-click guard
}

local function refreshSets()
    setsUi.names, setsUi.cache = listSets(), {}
    for _, n in ipairs(setsUi.names) do
        setsUi.cache[n] = loadSet(n) or false
    end
    if setsUi.selected ~= nil and setsUi.cache[setsUi.selected] == nil then setsUi.selected = nil end
end

-- nil selects the equipped row and leaves the name field alone.
local function selectSet(name)
    setsUi.selected = name
    if name ~= nil then setsUi.nameBuf[1] = name end
    setsUi.confirm = nil
end

-- Same head, same frame, same bag of attachments as the server's 0x044.
local function sameAsEquipped(set, a)
    if not set or a == nil or a.attachments == nil then return false end
    local byName = itemIds()
    if byName.head[set.head] ~= a.head or byName.frame[set.frame] ~= a.frame then return false end
    local want, n = {}, 0
    for _, name in ipairs(set.attachments) do
        local id = byName.attachment[name]
        if id == nil then return false end
        if not want[id] then want[id] = true n = n + 1 end
    end
    local have = 0
    for slot = 1, 12 do
        local id = a.attachments[slot] or 0
        if id ~= 0 then
            if not want[id] then return false end
            have = have + 1
        end
    end
    return have == n
end

-- A confirm outlives one click by four seconds, then the button reverts.
local function confirmed(action, name)
    local c = setsUi.confirm
    if c == nil or c.action ~= action or c.name ~= name then return false end
    if os.clock() - c.at > 4.0 then setsUi.confirm = nil return false end
    return true
end

-- The attachment grid: two columns of six. Each cell: slot number, name,
-- element and cost. On the equipped row a name is dimmed while no maneuver of
-- its element is up. The effect text is a tooltip on the name - live at the
-- current maneuvers, or at zero for a saved set. Unowned names in red. The
-- set's attachment list has no holes, so a row with a right cell has a left one.
-- x offsets are from the window edge (SameLine's origin), so the left column
-- starts at the padding, where a row's first item already sits.
-- The columns are laid out against the PANEL rather than on offsets fixed for
-- the 380 default, so a narrower panel still fits both. Only the index gutter
-- does not scale.
local GRID = { name = 20 }   -- at 100%; scaled where it is read
local function attachmentGrid(set, live, isUnowned)
    local counts = live and maneuverCounts() or {}
    local half   = hudInner() / 2
    local cols   = { hudPad(), hudPad() + half }
    -- No maneuver count per attachment: the element and its cost are what
    -- the row is read for, and the count is on the Status tab whole.
    local nameW, costX = half - tm.s(54), half - tm.s(34)
    for row = 1, 6 do
        for col = 1, 2 do
            local i = (col - 1) * 6 + row
            local name = set.attachments[i]
            if name ~= nil then
                local x = cols[col]
                local el, n, eff = attachEffect(name, counts, set.attachments)
                local info = ATTACH_ELEM[name]
                local active = live and n > 0
                if col > 1 then imgui.SameLine(x, 0) end
                tm.text('text', COL_DIM, ('%2d'):format(i))
                imgui.SameLine(x + tm.s(GRID.name), 0)
                tm.text('text', isUnowned[name] and COL_BAD or ((not live or active) and COL_TEXT or COL_DIM),
                                  tm.fit(name, nameW))
                if eff ~= nil then tip(eff) end
                if el ~= nil then
                    imgui.SameLine(x + costX, 0)
                    local icon, sz = elementIcon(el), tm.dpx('label')
                    if icon then
                        imgui.Image(icon, { sz, sz })
                        imgui.SameLine(x + costX + sz + tm.s(2), 0)
                        tm.text('text', EL_COLOR[el] or COL_DIM, tostring(info and info[2] or 0))
                    else
                        tm.text('text', EL_COLOR[el] or COL_DIM, ('%s%d'):format(el:sub(1, 2), info and info[2] or 0))
                    end
                end
            end
        end
    end
end

-- Capacity as one line of eight cells, used/cap per element: red where
-- over, dim where nothing uses it.
local function capacityLine(used, caps)
    local cell, sz = hudInner() / 8, tm.dpx('label')
    for i, el in ipairs(ELEMENTS) do
        local u, c = used[el], caps[el]
        local x = hudPad() + (i - 1) * cell
        if i > 1 then imgui.SameLine(x, 0) end
        local col = (u > c) and COL_BAD or (u == 0) and COL_DIM or COL_TEXT
        local icon = elementIcon(el)
        if icon then
            imgui.Image(icon, { sz, sz })
            imgui.SameLine(x + sz + tm.s(2), 0)
            tm.text('text', col, ('%d/%d'):format(u, c))
        else
            tm.text('text', col, ('%s%d/%d'):format(el:sub(1, 2), u, c))
        end
    end
    tip('Per element: capacity used / capacity the head and frame give.\nRed means the set will not fit.')
end

-- The dropdown: the equipped row first, then every saved set with its
-- equipped marker. Selecting drives the preview below.
local function setsCombo(a)
    imgui.PushItemWidth(tm.s(150))
    if imgui.BeginCombo('##cw_set', setsUi.selected or 'equipped') then
        if imgui.Selectable('equipped', setsUi.selected == nil) then selectSet(nil) end
        for _, n in ipairs(setsUi.names) do
            if imgui.Selectable(n, setsUi.selected == n) then selectSet(n) end
            if sameAsEquipped(setsUi.cache[n], a) then
                imgui.SameLine()
                tm.text('text', COL_DIM, 'equipped')
            end
        end
        imgui.EndCombo()
    end
    imgui.PopItemWidth()
end

-- The Save... popup: the name field and the actions that need it, with a
-- second-click guard on Overwrite and Delete. Closes itself once an action lands.
local function savePopup(current)
    if not imgui.BeginPopup('cw_save') then return end
    imgui.PushItemWidth(tm.s(150))
    imgui.InputText('##cw_setname', setsUi.nameBuf, 40)
    imgui.PopItemWidth()
    local name = setsUi.nameBuf[1]:match('^%s*(.-)%s*$')
    local nameOk, exists = validSetName(name), setExists(name, setsUi.names)

    imgui.BeginDisabled(not (nameOk and current ~= nil))
    local saveLabel = (exists and confirmed('save', name)) and 'Overwrite?' or 'Save current'
    if imgui.Button(saveLabel .. '##cw_save') then
        if exists and not confirmed('save', name) then
            setsUi.confirm = { action = 'save', name = name, at = os.clock() }
        else
            local ok, err = saveSet(name, current)
            print(chat.header('clockwork'):append(ok and chat.message('saved set ' .. name)
                                                      or chat.error(err or 'save failed')))
            refreshSets()
            selectSet(name)
            imgui.CloseCurrentPopup()
        end
    end
    imgui.EndDisabled()

    if setsUi.selected ~= nil then
        imgui.SameLine()
        imgui.BeginDisabled(not nameOk or exists)
        if imgui.Button('Rename##cw_rename') then
            if renameSet(setsUi.selected, name) then
                refreshSets()
                selectSet(name)
                imgui.CloseCurrentPopup()
            else
                print(chat.header('clockwork'):append(chat.error('rename failed')))
            end
        end
        imgui.EndDisabled()

        imgui.SameLine()
        local delLabel = confirmed('delete', setsUi.selected) and 'Really delete?' or 'Delete'
        if imgui.Button(delLabel .. '##cw_delete') then
            if not confirmed('delete', setsUi.selected) then
                setsUi.confirm = { action = 'delete', name = setsUi.selected, at = os.clock() }
            else
                deleteSet(setsUi.selected)
                setsUi.selected = nil
                refreshSets()
                imgui.CloseCurrentPopup()
            end
        end
    end

    if not nameOk and name ~= '' then
        tm.text('text', COL_DIM, 'names: letters, digits, space, - and _')
    elseif current == nil then
        hudText(COL_DIM, NO_DATA)
    elseif name == '' then
        tm.text('text', COL_DIM, 'type a name to save what the automaton wears now')
    end
    imgui.EndPopup()
end

local function drawLoadoutTab()
    if setsUi.names == nil then refreshSets() end
    local a = tm.auto044
    local current = equippedSet()   -- what Save current writes: the 0x044 only

    -- the equipped row, or the selected saved set; a bad file is neither
    local set, live, bad = nil, false, false
    if setsUi.selected == nil then
        set, live = liveSet(), true
    else
        set = setsUi.cache[setsUi.selected]
        if set == false then set, bad = nil, true end
    end
    local unowned = (set ~= nil and not live) and unownedIn(set) or nil
    local isUnowned = {}
    for _, n in ipairs(unowned or {}) do isUnowned[n] = true end
    local used, caps, fits = {}, {}, true
    if set ~= nil then used, caps, fits = capacityOf(set) end

    -- 1. the top row: dropdown, Save..., and Apply for a saved set. `ids` is
    -- the addon-level self/pet table; the name map gets its own name.
    setsCombo(a)
    imgui.SameLine()
    if imgui.Button('Save...##cw_savebtn') then imgui.OpenPopup('cw_save') end
    savePopup(current)
    if set ~= nil and not live then
        local reason = nil
        local names = itemIds()
        if not snap.is_pup then reason = 'not PUP'
        elseif ids.pet_id ~= 0 then reason = 'deactivate first'
        elseif a == nil or a.attachments == nil then reason = NO_DATA
        elseif names.head[set.head] == nil or names.frame[set.frame] == nil then reason = 'unknown head or frame'
        elseif isUnowned[set.head] or isUnowned[set.frame] then reason = 'head or frame not owned'
        elseif not fits then reason = 'over capacity'
        end
        imgui.SameLine()
        local busy = tm.applyState ~= nil and not tm.applyState.done
        imgui.BeginDisabled(reason ~= nil or busy)
        if imgui.Button('Apply##cw_apply') then startApply(setsUi.selected, set) end
        imgui.EndDisabled()
        if reason ~= nil then hudText(COL_DIM, reason) end
    end

    -- 2. the preview
    if bad then
        hudText(COL_BAD, 'that file did not parse - head and frame lines, then attachments')
    elseif set == nil then
        hudText(COL_DIM, NO_DATA)
    else
        tm.text('text', isUnowned[set.head] and COL_BAD or COL_TEXT, set.head)
        imgui.SameLine()
        tm.text('text', COL_DIM, '/')
        imgui.SameLine()
        tm.text('text', isUnowned[set.frame] and COL_BAD or COL_TEXT, set.frame)
        if set.fromBuffer then
            hudText(COL_DIM, 'showing the client copy - ' .. NO_DATA)
        elseif not live and unowned == nil then
            hudText(COL_DIM, 'ownership unknown - ' .. NO_DATA)
        end
        attachmentGrid(set, live, isUnowned)
        if unowned ~= nil and #unowned > 0 then
            hudText(COL_BAD, 'not owned: ' .. table.concat(unowned, ', '))
        end
        capacityLine(used, caps)
    end

    -- 3. apply status, only for the selected saved set
    if not live and tm.applyState ~= nil and tm.applyState.set == setsUi.selected then
        local col = tm.applyState.failed and COL_BAD or (tm.applyState.done and COL_GOOD or COL_WARN)
        tm.text('text', col, tm.applyState.status)
        if tm.applyState.done and tm.applyState.recast then
            tm.text('text', COL_DIM, 'Activate is on its 60s swap recast')
        end
    end

end

return { NO_DATA = NO_DATA, refreshSets = refreshSets, selectSet = selectSet,
         drawLoadoutTab = drawLoadoutTab }
