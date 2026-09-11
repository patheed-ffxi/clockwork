-- cw/sets.lua - the saved attachment sets and the Apply coroutine that equips
-- one. Owns the set files (pupsets' format), the capacity and ownership checks
-- and the Apply plan. Exports the store (list/load/save/delete/rename and
-- validSetName), capacityOf, unownedIn, equippedSet, liveSet, planApply,
-- startApply and their helpers; publishes tm.flushLoadout and tm.applyState.
local ffi  = require('ffi')
local chat = require('chat')
local D  = require('cw.data')
local ELEMENTS, ATTACH_OFFSET, EQUIP_OFFSET, PUPPET_CAP = D.ELEMENTS, D.ATTACH_OFFSET, D.EQUIP_OFFSET, D.PUPPET_CAP
local tm = require('cw.state')
local A  = require('cw.attachments')
local ATTACH_ELEM = A.ATTACH_ELEM
local U  = require('cw.util')
local safe, isPup, isPupSub, writeFile = U.safe, U.isPup, U.isPupSub, U.writeFile
local L  = require('cw.log')
local logEvent = L.logEvent
local R  = require('cw.reading')
local equippedNames = R.equippedNames
local P  = require('cw.pet')
local resolveIds = P.resolveIds
-- The shared tables, never reassigned after cw/state.lua creates them.
local ids = tm.ids

-- ================================================================= sets ==
-- Named attachment loadouts: what pupsets does, with a preview and an apply
-- that confirms each step against the server.
--
-- A set is { head = name, frame = name, attachments = { name, ... } }.
-- Attachments are a BAG - slot positions mean nothing to the game, so two
-- sets with the same items in different slots are the same set.
--
-- File format is pupsets' own, one item name per line, head then frame then
-- attachments, so a file copied in either direction just works. Only filled
-- slots are written; blank lines (pupsets writes one per empty slot) are
-- tolerated on read.

local function serializeSet(set)
    local lines = { set.head or '', set.frame or '' }
    for _, a in ipairs(set.attachments or {}) do
        if a ~= nil and a ~= '' then lines[#lines + 1] = a end
    end
    return table.concat(lines, '\n') .. '\n'
end

local function parseSetFile(text)
    local lines = {}
    for line in (text .. '\n'):gmatch('([^\r\n]*)\r?\n') do
        lines[#lines + 1] = line:match('^%s*(.-)%s*$')
    end
    local set = { head = lines[1] or '', frame = lines[2] or '', attachments = {} }
    for i = 3, #lines do
        if lines[i] ~= '' then set.attachments[#set.attachments + 1] = lines[i] end
    end
    if set.head == '' or set.frame == '' then return nil, 'head and frame are required' end
    if #set.attachments > 12 then return nil, 'more than 12 attachments' end
    return set
end

-- Set names become file names. Letters, digits, space, '-' and '_' only;
-- anything else is refused outright rather than mangled.
-- Windows reserves these whatever the extension, and they are not errors: the
-- open SUCCEEDS and the bytes go to the device, so a set named `nul` would
-- report saved and leave no file behind - the set would silently vanish.
local RESERVED = {}
for _, n in ipairs({ 'con', 'prn', 'aux', 'nul' }) do RESERVED[n] = true end
for i = 1, 9 do RESERVED['com' .. i] = true RESERVED['lpt' .. i] = true end
local function validSetName(name)
    if type(name) ~= 'string' then return false end
    name = name:match('^%s*(.-)%s*$')
    if name == '' or #name > 40 then return false end
    if name:match('^[%w _%-]+$') == nil then return false end
    -- The pattern above refuses '.', so the whole name is the stem Windows
    -- checks: 'nul' is a device, 'nulled' is an ordinary name.
    return not RESERVED[name:lower()]
end

-- <ashita>/config/addons/clockwork/sets/<name>.txt - clockwork's own folder,
-- so nobody needs pupsets installed to use this.
local function setsDir()
    return ('%s/config/addons/clockwork/sets/'):format(tm.installRoot())
end
local function setPath(name) return setsDir() .. name .. '.txt' end

local function listSets()
    local names = {}
    local files = safe(function() return ashita.fs.get_directory(setsDir(), '.*.txt', false) end, nil)
    for _, f in ipairs(files or {}) do
        local n = f:match('([^/\\]+)%.txt$')
        if n ~= nil and n ~= '' then names[#names + 1] = n end
    end
    table.sort(names, function(a, b) return a:lower() < b:lower() end)
    return names
end

-- Windows file names are case-insensitive; so is this. Pass the cached list
-- when asking every frame; without one it reads the directory.
local function setExists(name, names)
    for _, n in ipairs(names or listSets()) do
        if n:lower() == name:lower() then return true end
    end
    return false
end

local function loadSet(name)
    local f = io.open(setPath(name), 'r')
    if f == nil then return nil, 'cannot open ' .. name end
    local text = f:read('*a') or ''
    f:close()
    return parseSetFile(text)
end

local function saveSet(name, set)
    -- Here, not only in the Loadout tab's own check: `nul` and its siblings
    -- OPEN successfully on Windows and swallow the bytes, so without this a
    -- direct caller would get success and no set.
    if not validSetName(name) then return false, 'not a usable set name: ' .. tostring(name) end
    safe(function() ashita.fs.create_directory(setsDir()) end)
    -- Through writeFile's temp file, with the write and the close both
    -- checked: a failed write reports failure and leaves the existing set
    -- whole rather than truncated.
    return writeFile(setPath(name), serializeSet(set))
end

local function deleteSet(name)   return os.remove(setPath(name)) ~= nil end
local function renameSet(old, new)
    -- os.rename happens to refuse a device name today, which is luck rather
    -- than a guarantee: say so explicitly, as saveSet does.
    if not validSetName(new) then return false end
    return os.rename(setPath(old), setPath(new)) ~= nil
end

local function elementCaps(rawId)
    local v, caps = PUPPET_CAP[rawId] or 0, {}
    for i, el in ipairs(ELEMENTS) do
        caps[el] = math.floor(v / (16 ^ (i - 1))) % 16
    end
    return caps
end

-- name -> raw id for everything the automaton can wear, built once from the
-- resource manager: heads 1-7 and frames 32-39 at EQUIP_OFFSET, attachments
-- 1-254 at ATTACH_OFFSET - the ranges pupsets scans on every call. Not cached
-- until the heads resolve, so an early call before resources load cannot pin
-- an empty map.
local itemIdCache = nil
local function itemIds()
    if itemIdCache ~= nil then return itemIdCache end
    local map = { head = {}, frame = {}, attachment = {} }
    safe(function()
        local res = AshitaCore:GetResourceManager()
        local function scan(kind, base, from, to)
            for id = from, to do
                local item = res:GetItemById(base + id)
                local name = item and item.Name and item.Name[1] or nil
                if name ~= nil and name ~= '' and name:sub(1, 1) ~= '.' then
                    map[kind][name] = id
                end
            end
        end
        scan('head', EQUIP_OFFSET, 1, 7)
        scan('frame', EQUIP_OFFSET, 32, 39)
        scan('attachment', ATTACH_OFFSET, 1, 254)
    end)
    if next(map.head) ~= nil then itemIdCache = map end
    return map
end

-- Per element: what the set uses against what its head and frame give. The
-- server's rule (puppetutils.cpp): every attachment's cost summed per
-- element must fit within head + frame capacity for that element.
local function capacityOf(set)
    local ids = itemIds()
    local h = elementCaps(ids.head[set.head] or 0)
    local f = elementCaps(ids.frame[set.frame] or 0)
    local used, caps, fits = {}, {}, true
    for _, el in ipairs(ELEMENTS) do
        caps[el] = (h[el] or 0) + (f[el] or 0)
        used[el] = 0
    end
    -- Once per NAME. The automaton holds one of each attachment, so a set
    -- file that lists the same one twice still costs its capacity once -
    -- which is what planApply plans and what the server charges. Summing per
    -- line would read a set with a duplicated row as over capacity and refuse
    -- an Apply that fits.
    local counted = {}
    for _, a in ipairs(set.attachments or {}) do
        local info = ATTACH_ELEM[a]
        if info ~= nil and not counted[a] then
            counted[a] = true
            used[info[1]] = used[info[1]] + info[2]
        end
    end
    for _, el in ipairs(ELEMENTS) do
        if used[el] > caps[el] then fits = false end
    end
    return used, caps, fits
end

local function hasBit(mask, n) return math.floor((mask or 0) / (2 ^ n)) % 2 == 1 end

-- UnlockedAttachments[8] arrives as a 32-byte string; bit index = attachment
-- id, same decode ownedAttachments() uses.
local function ownedBit(mask, id)
    if mask == nil then return false end
    local byte = mask:byte(math.floor(id / 8) + 1) or 0
    return math.floor(byte / (2 ^ (id % 8))) % 2 == 1
end

-- Which parts of a set the server says you do NOT own, per the 0x044 masks
-- (heads and frames bit (id & 0x0F), attachments bit id -
-- puppetutils.cpp). Harlequin head and frame need no bit. A name the
-- resource manager cannot resolve counts as unowned. nil when no 0x044 has
-- arrived: unknown is not the same as unowned.
local function unownedIn(set)
    if tm.auto044 == nil or tm.auto044.heads == nil then return nil end
    local ids, out = itemIds(), {}
    local hid, fid = ids.head[set.head], ids.frame[set.frame]
    if hid == nil or (hid ~= 1 and not hasBit(tm.auto044.heads, hid % 16)) then out[#out + 1] = set.head end
    if fid == nil or (fid ~= 32 and not hasBit(tm.auto044.frames, fid % 16)) then out[#out + 1] = set.frame end
    for _, a in ipairs(set.attachments or {}) do
        local id = ids.attachment[a]
        if id == nil or not ownedBit(tm.auto044.owned, id) then out[#out + 1] = a end
    end
    return out
end

-- The resource manager's name for an id at a base offset; nil for an empty
-- slot or an id it does not know. Not util's itemName(id): that one answers
-- '-' or the raw id so there is always something to print, and this one has
-- to make empty slots drop out.
local function resName(base, id)
    if id == nil or id == 0 then return nil end
    return safe(function()
        local item = AshitaCore:GetResourceManager():GetItemById(base + id)
        local n = item and item.Name and item.Name[1] or nil
        if n == nil or n == '' or n:sub(1, 1) == '.' then return nil end
        return n
    end, nil)
end

-- What is on the automaton now, as a set - from the server's last 0x044,
-- the same source the equipped marker and Apply use, so the three can never
-- disagree. Not the client's memory buffer: pupsets warns that one lags
-- until a menu is opened. nil until a 0x044 has arrived (zone, job change,
-- automaton activation or any status effect change - opening a menu does
-- not send one) or when it names no head or frame. Derived once
-- per 0x044, not per frame: the tab asks every frame and the answer only
-- changes when the packet does.
local eqSetCache, eqSetSeq = nil, -1
local function equippedSet()
    if eqSetSeq == tm.auto044Seq then return eqSetCache end
    local a, set = tm.auto044, nil
    if a ~= nil and a.attachments ~= nil then
        local head, frame = resName(EQUIP_OFFSET, a.head), resName(EQUIP_OFFSET, a.frame)
        if head ~= nil and frame ~= nil then
            set = { head = head, frame = frame, attachments = {} }
            for slot = 1, 12 do
                local n = resName(ATTACH_OFFSET, a.attachments[slot])
                if n ~= nil then set.attachments[#set.attachments + 1] = n end
            end
        end
    end
    eqSetCache, eqSetSeq = set, tm.auto044Seq
    return set
end

-- The automaton's loadout, once per Activate. RENDER thread only: equippedSet
-- resolves item ids through the resource manager, which the packet thread must
-- not touch. The Activate arm records auto044Seq and this waits for the server
-- to move past it - the next 0x044 is the one describing the automaton that
-- just came out, so the record is the new loadout rather than the previous one.
-- Why it exists: no other record carries the head, the frame or the
-- attachments, and both the shot's recast model and the whole spell ladder are
-- derived from them, so without this a recast_early or a spell_mispredicted
-- cannot be attributed to a loadout after the session.
tm.flushLoadout = function()
    local at = tm.logLoadoutAt
    if at == nil or tm.auto044Seq <= at then return end
    tm.logLoadoutAt = nil
    local set = equippedSet()
    if set == nil then
        -- the 0x044 arrived but the ids did not resolve; say so rather than
        -- leave the summon unrecorded
        logEvent('loadout', { unknown = true })
        return
    end
    logEvent('loadout', {
        head  = set.head,
        frame = set.frame,
        -- flattened: logEvent's encoder tostring()s anything that is not a
        -- number or a boolean, so a table would land as "table: 0x...".
        attachments = table.concat(set.attachments, ', '),
        count       = #set.attachments,
    })
end

-- The equipped row's data: the 0x044 when one has arrived since load, else
-- the client's memory buffer, flagged (fromBuffer) so the tab can say so.
-- Display only: a save still needs the 0x044.
local function liveSet()
    local s = equippedSet()
    if s ~= nil then return s end
    local eq = equippedNames()
    if eq[1] == nil or eq[1] == '' or eq[2] == nil or eq[2] == '' then return nil end
    local set = { head = eq[1], frame = eq[2], attachments = {}, fromBuffer = true }
    for i = 3, 14 do
        if eq[i] ~= nil and eq[i] ~= '' then set.attachments[#set.attachments + 1] = eq[i] end
    end
    return set
end

-- The steps Apply will take, from the server's view (cur: ids from 0x044) to
-- the set (names). ORDER IS THE POINT: removals first, which frees capacity;
-- then head, then frame, so the new caps are in place; then additions into
-- the lowest free slots. Anything already in place is never touched, and a
-- set that changes only attachments never touches head or frame - so no 60s
-- Activate recast. A reset-then-refill order swaps the frame early and can
-- run over capacity along the way; this order cannot.
--
-- skip: names to leave out (the ones you do not own). Returned separately
-- with anything the resource manager cannot resolve, each name once.
-- Head before frame only because one of them has to go first: on stock
-- LSB neither setHead nor setFrame re-checks capacity, so the order cannot
-- be refused there. If Horizon added such a check, a refused head or frame
-- step with a set that fits is the sign, and trying the other first is the
-- fix.
local function planApply(cur, set, skip)
    local ids = itemIds()
    local steps, skipped, want, have, named = {}, {}, {}, {}, {}
    for _, a in ipairs(set.attachments or {}) do
        local id = ids.attachment[a]
        if id == nil or skip[a] then
            if not named[a] then
                skipped[#skipped + 1] = a
                named[a] = true
            end
        else want[id] = a end
    end
    -- 1. removals
    local free = {}
    for slot = 1, 12 do
        local id = cur.attachments[slot] or 0
        if id ~= 0 and want[id] then
            have[id] = true
        else
            if id ~= 0 then steps[#steps + 1] = { op = 'remove', slot = slot, id = id } end
            free[#free + 1] = slot   -- empty now, or empty once the removal lands
        end
    end
    -- 2. head, 3. frame - only when different
    local hid, fid = ids.head[set.head], ids.frame[set.frame]
    if hid ~= nil and hid ~= cur.head then steps[#steps + 1] = { op = 'head', id = hid, name = set.head } end
    if fid ~= nil and fid ~= cur.frame then steps[#steps + 1] = { op = 'frame', id = fid, name = set.frame } end
    -- 4. additions, in the set's order, into the lowest free slots
    local fi = 1
    for _, a in ipairs(set.attachments or {}) do
        local id = ids.attachment[a]
        if id ~= nil and want[id] and not have[id] and free[fi] ~= nil then
            steps[#steps + 1] = { op = 'add', slot = free[fi], id = id, name = a }
            have[id] = true
            fi = fi + 1
        end
    end
    return steps, skipped
end

-- ------------------------------------------------------------- applying --
-- One slot through the client's OWN equip function - the same call pupsets
-- and Ashita's blusets make, so the packet is the one the game's screen
-- would send. isSubJob 0/1, job type 0x1200 (PUP), index 0 = head, 1 = frame,
-- 2-13 = attachments, id 0 unsets. Bound
-- lazily and once: ffi.cdef refuses to redefine a typedef within one Lua
-- state. Returns nil when the signature is not found, else the function's
-- own answer: 1 accepted, 0 refused by the client.
local equipexFn, equipexDeclared = nil, false
local function equipex(index, id)
    if equipexFn == nil then
        -- The typedef is declared once, on the first attempt, whether or not
        -- the scan then finds the function: LuaJIT refuses to redefine it, so
        -- an Apply after a failed scan skips the cdef and reports the plain
        -- "not found" below.
        if not equipexDeclared then
            equipexDeclared = true
            ffi.cdef[[
                typedef uint8_t (__cdecl *equipex_t)(uint8_t isSubJob, uint16_t jobType, uint16_t index, uint8_t id);
            ]]
        end
        local addr = ashita.memory.find('FFXiMain.dll', 0,
            '8B0D????????81EC9C00000085C95356570F??????????8B', 0, 0)
        if addr == nil or addr == 0 then return nil end
        equipexFn = ffi.cast('equipex_t', addr)
    end
    return equipexFn(isPup() and 0 or 1, 0x1200, index, id)
end

local APPLY_TIMEOUT = 3.0   -- seconds to wait for the server's 0x044 per step
-- Seconds from a landed step to the next send. Horizon's pupsets sleeps a
-- fixed 1.0 s per slot; on the server's confirmation alone a full set went
-- several times faster than that, and matching its pace is the point.
local APPLY_STEP_GAP = 1.0

-- Did the server's latest 0x044 show this step landed?
local function stepLanded(step, a)
    if a == nil or a.attachments == nil then return false end
    if step.op == 'remove' then return (a.attachments[step.slot] or 0) == 0 end
    if step.op == 'add'    then return a.attachments[step.slot] == step.id end
    if step.op == 'head'   then return a.head == step.id end
    if step.op == 'frame'  then return a.frame == step.id end
    return false
end

-- The current apply, for the tab's status line. Lives past completion so the
-- result stays readable; the next startApply replaces it.
tm.applyState = nil

local function describe(step)
    return ('%s %s'):format(step.op, step.name or ('slot ' .. tostring(step.slot)))
end

local function skippedNote(skipped)
    return (#skipped > 0) and (', %d skipped'):format(#skipped) or ''
end

-- Runs the steps in a task coroutine, like pupsets. Each step: send, then wait
-- until the server's 0x044 stream SHOWS the change, or the timeout. Landed:
-- pause APPLY_STEP_GAP, then the next step. Timed out with packets in
-- between: the server refused it. Timed
-- out with no packet at all: silence. The client's own function saying no (it
-- returns 0) is retried, then fails. Any failure stops the sequence - never
-- continue into the over-capacity cascade - and everything completed was
-- confirmed, so the automaton is consistent and Apply again redoes only what
-- is missing. An automaton out, a job change or a zone stop it too, checked
-- between steps AND between retries.
local function runApply(name, steps, skipped)
    tm.applyState = { set = name, steps = steps, i = 0, status = 'starting', skipped = skipped, recast = false }
    local st = tm.applyState
    local zone0 = tm.zoneSeq
    -- Every reason to stop that is not about the step itself. Read again on
    -- each retry as well as between steps: the retry loop holds one step for
    -- up to two seconds, which is long enough to zone or to summon in.
    local function guard(i)
        resolveIds()
        if ids.pet_id ~= 0 then
            return ('automaton came out - stopped before step %d'):format(i)
        end
        if not (isPup() or isPupSub()) then return 'no longer PUP - stopped' end
        if tm.zoneSeq ~= zone0 then return ('zoned - stopped before step %d'):format(i) end
        return nil
    end
    local function body()
        for i, step in ipairs(steps) do
            st.i = i
            st.failed = guard(i)
            if st.failed ~= nil then return end
            st.status = ('%d/%d %s'):format(i, #steps, describe(step))
            local index = (step.op == 'head') and 0 or (step.op == 'frame') and 1 or (step.slot + 1)
            -- The client's function answers 0 for a moment after the previous
            -- step lands - its own equip state is still settling (on the add
            -- right after a remove) - so a refusal is retried for
            -- two seconds before it counts.
            local rc, before
            for attempt = 1, 8 do
                st.failed = guard(i)
                if st.failed ~= nil then return end
                -- Read immediately before the send, not before the retry loop:
                -- otherwise a refused attempt and its sleep would sit inside
                -- the window, and a 0x044 from that stretch would count as
                -- the reply to a packet that had not been sent yet.
                before = tm.auto044Seq
                rc = equipex(index, (step.op == 'remove') and 0 or step.id)
                if rc ~= 0 then break end
                st.status = ('%d/%d %s (retry %d)'):format(i, #steps, describe(step), attempt)
                coroutine.sleep(0.25)
            end
            if rc == nil then
                st.failed = 'equip function not found - client signature changed?'
                return
            end
            if rc == 0 then
                st.failed = ('client refused step %d (%s) eight times'):format(i, describe(step))
                return
            end
            -- Wait for the step to LAND, not for the next packet of any kind.
            -- LSB's PostTick sends a 0x044 on every master effect change
            -- (charentity.cpp:1110), so taking any packet as the answer would
            -- read a buff wearing off in this window as a refusal - and then
            -- the equip would land anyway.
            local t0 = os.clock()
            while not stepLanded(step, tm.auto044) and os.clock() - t0 < APPLY_TIMEOUT do
                coroutine.sleep(0.1)
            end
            if not stepLanded(step, tm.auto044) then
                -- Nothing at all came back, or something did and the change was
                -- not in it. The two read very differently to a player.
                st.failed = (tm.auto044Seq == before)
                    and ('no reply from the server for step %d (%s)'):format(i, describe(step))
                     or ('server refused step %d (%s)'):format(i, describe(step))
                return
            end
            if step.op == 'head' or step.op == 'frame' then st.recast = true end
            if i < #steps then coroutine.sleep(APPLY_STEP_GAP) end
        end
    end
    ashita.tasks.once(0, function()
        -- The finaliser. Nothing in the body is expected to throw, but `busy`
        -- on the Apply button is `not applyState.done`, so an error that
        -- skipped the line below would disable Apply until /addon reload.
        -- LuaJIT yields across pcall, so the body can still sleep inside it.
        local ok, err = pcall(body)
        if not ok and st.failed == nil then
            st.failed = ('apply stopped on an error at step %d: %s')
                        :format(st.i or 0, tostring(err))
        end
        st.done = true
        if st.failed ~= nil then
            st.status = st.failed
            print(chat.header('clockwork'):append(chat.error(('apply %s: %s'):format(name, st.failed))))
        else
            st.status = ('done - %d changes%s'):format(#steps, skippedNote(skipped))
            print(chat.header('clockwork'):append(chat.message(('applied %s: %d changes'):format(name, #steps))))
        end
        if #skipped > 0 then
            print(chat.header('clockwork'):append(chat.message(
                'skipped (not owned or unknown): ' .. table.concat(skipped, ', '))))
        end
    end)
end

-- Entry from the Apply button. Needs a 0x044 to diff against; the button is
-- disabled without one. Items you do not own are skipped and named.
local function startApply(name, set)
    if tm.auto044 == nil or tm.auto044.attachments == nil then return end
    local cur = { head = tm.auto044.head, frame = tm.auto044.frame, attachments = tm.auto044.attachments }
    local skip = {}
    for _, n in ipairs(unownedIn(set) or {}) do skip[n] = true end
    local steps, skipped = planApply(cur, set, skip)
    if #steps == 0 then
        tm.applyState = { set = name, steps = steps, i = 0, done = true,
                       status = 'already equipped' .. skippedNote(skipped),
                       skipped = skipped, recast = false }
        return
    end
    runApply(name, steps, skipped)
end

return { serializeSet = serializeSet, parseSetFile = parseSetFile, validSetName = validSetName,
         setsDir = setsDir, listSets = listSets, setExists = setExists, loadSet = loadSet,
         saveSet = saveSet, deleteSet = deleteSet, renameSet = renameSet, elementCaps = elementCaps,
         itemIds = itemIds, capacityOf = capacityOf, unownedIn = unownedIn,
         equippedSet = equippedSet, liveSet = liveSet, planApply = planApply,
         startApply = startApply }
