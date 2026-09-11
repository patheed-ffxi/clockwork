-- cw/util.lua - the guarded native reads everything else is built on, and the
-- atomic file write. Publishes tm.swallowed; exports safe, player, the login and
-- job checks, equippedItemId, itemName, equippedThreshold and writeFile, which
-- writes through a temp file that the local replaceFile (MoveFileExA) swaps in.
local ffi = require('ffi')
local config = require('cw.config')
local D  = require('cw.data')
local OVERLOAD_GEAR, SLOT_HANDS, SLOT_NECK = D.OVERLOAD_GEAR, D.SLOT_HANDS, D.SLOT_NECK
local tm = require('cw.state')

-- ============================================================= utilities =
-- Every native read goes through here, because the render and packet threads
-- must not die on one. That also means a genuine bug inside one is invisible:
-- it returns the fallback and the frame carries on. The counter is the only
-- way a test can see it happen - the offline suite asserts it stays at zero
-- across a full render, so a nil call or a bad index shows up as a number
-- instead of as a plausible-looking default.
tm.swallowed = 0
local function safe(fn, fallback)
    local ok, res = pcall(fn)
    if ok then return res end
    tm.swallowed = tm.swallowed + 1
    return fallback
end

local function player() return AshitaCore:GetMemoryManager():GetPlayer() end

-- Is there a character in the world at all? 0 = title / character select,
-- 1 = loading, 2 = in game. This is the ONLY read that answers honestly at the
-- character screen: the job, the party table and the entity table all keep the
-- values the last logged-in character left behind, so a stale main job of 18
-- and a stale party slot 0 would draw the HUD over character select. Same
-- check fancychat, XIUI and captain make.
local function isLoggedIn()
    return safe(function() return player():GetLoginStatus() == 2 end, false)
end
-- ...and the title or character screen specifically (0), as opposed to a
-- loading screen (1): the one moment no character is in the world at all.
local function atCharacterSelect()
    return safe(function() return player():GetLoginStatus() == 0 end, false)
end
-- Demo mode says yes to the job check, which is the gate frame.tick() gives up
-- on. Everything else it fakes is a read, not a decision.
local function isPup()
    if tm.demo ~= nil then return true end
    return safe(function() return player():GetMainJob() == 18 end, false)
end
local function isPupSub() return safe(function() return player():GetSubJob() == 18 end, false) end

-- Item id in an equipment slot, or 0. Same walk as luashitacast equip.lua.
local function equippedItemId(slot)
    return safe(function()
        local inv  = AshitaCore:GetMemoryManager():GetInventory()
        local eq   = inv:GetEquippedItem(slot)
        local idx  = bit.band(eq.Index, 0x00FF)
        if idx == 0 then return 0 end
        local item = inv:GetContainerItem(bit.rshift(eq.Index, 8), idx)
        return (item ~= nil and item.Count > 0) and item.Id or 0
    end, 0)
end

local function itemName(id)
    if id == 0 then return '-' end
    local name = safe(function()
        return AshitaCore:GetResourceManager():GetItemById(id).Name[1]
    end, nil)
    return name or tostring(id)
end

-- The threshold the server would use right now: 30 plus OVERLOAD_THRESH on
-- the worn hands and neck. reconcile reads it as the maneuver resolves; the
-- render thread reads it per frame for elements that have not resolved yet.
local function equippedThreshold()
    return config.threshold + (OVERLOAD_GEAR[equippedItemId(SLOT_HANDS)] or 0)
                            + (OVERLOAD_GEAR[equippedItemId(SLOT_NECK)] or 0)
end

-- Put `tmp` where `path` is, in one step. os.rename is C rename(), which on
-- Windows refuses an existing destination; MoveFileExA with
-- MOVEFILE_REPLACE_EXISTING (1) is the rename that may replace, and on one
-- volume it is a single directory update - there is no moment with neither
-- file on disk. Declared lazily and once: ffi.cdef refuses to redeclare
-- within one Lua state, and pcall covers a host that declared it already.
local replaceDeclared = false
local function replaceFile(tmp, path)
    if not replaceDeclared then
        replaceDeclared = true
        pcall(ffi.cdef, [[
            int MoveFileExA(const char* from, const char* to, unsigned int flags);
            unsigned int GetLastError(void);
        ]])
    end
    local ok, rc = pcall(function() return ffi.C.MoveFileExA(tmp, path, 1) end)
    if not ok then return false, tostring(rc) end
    if rc == 0 then
        local _, code = pcall(function() return ffi.C.GetLastError() end)
        return false, 'MoveFileEx error ' .. tostring(code)
    end
    return true
end

-- Write a whole file, or leave the existing one alone. io.open(path, 'w')
-- truncates before a byte is written, so were the file written in place, a
-- write that fails - disk full, a handle that errors on close - would leave an
-- empty or partial file behind, and would report success unless f:write and
-- f:close are both checked.
-- The bytes go to a sibling temp file first, and only a written and closed
-- temp replaces the target. When the replace itself fails both files stay
-- where they are - the existing one untouched, the new bytes in the temp the
-- reason names. Nothing removes the target ahead of the replace, or the temp
-- after a failed one: together those are the path that could lose both
-- copies. Returns true, or false and a reason.
local function writeFile(path, text)
    local tmp = path .. '.tmp'
    local f, oerr = io.open(tmp, 'w')
    if f == nil then return false, 'cannot write ' .. tmp .. (oerr and (': ' .. tostring(oerr)) or '') end
    local wrote, werr = f:write(text)
    local closed, cerr = f:close()
    if not wrote or not closed then
        os.remove(tmp)   -- incomplete, and the target has not been touched
        return false, 'write failed: ' .. tostring(werr or cerr or '?')
    end
    local moved, merr = replaceFile(tmp, path)
    if not moved then
        return false, ('cannot replace %s (%s) - the new contents are in %s'):format(path, merr, tmp)
    end
    return true
end

return { safe = safe, player = player, isLoggedIn = isLoggedIn, atCharacterSelect = atCharacterSelect,
         isPup = isPup, isPupSub = isPupSub,
         equippedItemId = equippedItemId, itemName = itemName, equippedThreshold = equippedThreshold,
         writeFile = writeFile }
