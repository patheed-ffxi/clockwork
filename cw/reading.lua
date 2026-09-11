-- cw/reading.lua - what the client says about the automaton, its target and its
-- gear. Exports petInfo, equippedNames, equippedAttachments, hasAttachment,
-- ownedAttachments, oilCounts and partyIds; publishes tm.mobHpp, tm.mobSlot and
-- tm.deploySlot. The packet thread must never call into here: a native read
-- racing zone-in entity churn is an SEH fault (see tm.snap in cw/state.lua).
local ffi = require('ffi')
local D  = require('cw.data')
local ATTACH_OFFSET, EQUIP_OFFSET, OIL_IDS = D.ATTACH_OFFSET, D.EQUIP_OFFSET, D.OIL_IDS
local tm = require('cw.state')
local U  = require('cw.util')
local safe, player, isPup = U.safe, U.player, U.isPup
local ids = tm.ids

-- =============================================================== reading =
local function petInfo()
    if tm.demo ~= nil then return tm.demo.pet end
    return safe(function()
        if ids.pet_index == 0 then return nil end
        local ent = AshitaCore:GetMemoryManager():GetEntity()
        -- The entity table only carries HP%. Pet MP% and TP live in the player
        -- memory block instead - same source Ashita's own petinfo.lua reads.
        local p = player()
        return { name = ent:GetName(ids.pet_index),
                 hpp  = ent:GetHPPercent(ids.pet_index),
                 -- GetDistance answers the SQUARE of the distance - the game
                 -- stores it that way and never roots it. luashitacast takes the
                 -- same sqrt for its own pet table (luashitacast data.lua).
                 dist = math.sqrt(ent:GetDistance(ids.pet_index) or 0),
                 -- nil, not 0, when the read fails or answers nothing: a zero
                 -- here is an empty pool, which gather() would publish as a
                 -- reading and the ladder would refuse every spell against.
                 -- nil is "no reading", and gather() widens to the whole pool.
                 mpp  = safe(function() return p:GetPetMPPercent() end, nil),
                 tp   = safe(function() return p:GetPetTP() end, 0) or 0 }
    end, nil)
end

-- The target's HP% in entity slot `slot`, for the header row and the compact
-- strip. One guarded read, on tm beside mobSlot because the UI reaches both
-- that way and requires nothing from this file.
tm.mobHpp = function(slot)
    if tm.demo ~= nil then return tm.demo.mob.hpp end
    return safe(function()
        return AshitaCore:GetMemoryManager():GetEntity():GetHPPercent(slot)
    end, nil) or 0
end

-- The entity slot holding server id `id`, or nil. Static NPCs and mobs sit in
-- 0-0x3FF, players in 0x400-0x6FF, and 0x700-0x8FF holds pets and the mobs the
-- server builds at runtime (battlefields, script pops). The player band is
-- never a target, so it is skipped. Stopping at 0x3FF would read a battlefield
-- mob as out of sight all fight.
local function scanFor(ent, id)
    for i = 0, 0x8FF do
        if (i < 0x400 or i >= 0x700) and ent:GetServerId(i) == id then return i end
    end
    return nil
end

-- The entity slot the automaton's target is sitting in, or nil. Found once per
-- target and then RE-CHECKED, not trusted - entity indices are recycled, so a
-- slot that held the target can come back as another mob mid-fight and hand us
-- its HP instead. One GetServerId a frame confirms it; a mismatch pays for a
-- rescan.
-- A FAILED scan is NOT remembered. Caching the negative would make one bad
-- frame permanent - with mobIndex nil and mobIndexFor already equal to
-- petTarget nothing would rescan - so a mob whose entity slot is momentarily
-- empty (the draw-distance flap resolveIds() handles for the automaton) would
-- leave the target's HP unreadable for the rest of the fight, silently
-- degrading the Stormwaker low-HP branch and tryElemental's uncertain flag.
-- Instead the rescan is throttled: 1,536 native GetServerId calls at most once
-- a second while the target is genuinely absent.
--
-- Called twice a frame while a caster head is out - once by gather for the
-- ladder, once by the target row - which costs one extra GetServerId on a hit
-- and nothing at all on a miss, where mobScanAt already holds the rescan down
-- to once a second.
tm.mobSlot = function()
    if tm.demo ~= nil then return tm.demo.mob.slot end
    return safe(function()
        if tm.petTarget == 0 then return nil end
        local ent = AshitaCore:GetMemoryManager():GetEntity()
        local hit = tm.mobIndexFor == tm.petTarget and tm.mobIndex ~= nil
                    and ent:GetServerId(tm.mobIndex) == tm.petTarget
        if not hit then
            tm.mobIndex = nil
            local at = os.clock()
            if tm.mobScanAt == nil or at - tm.mobScanAt >= 1 then
                tm.mobScanAt = at
                tm.mobIndexFor, tm.mobIndex = tm.petTarget, scanFor(ent, tm.petTarget)
            end
        end
        if tm.mobIndex == nil then return nil end
        -- Remembered so a one-frame slot flap does not blank the name out of
        -- the target row. Stamped with the id it was read FOR, so a new target
        -- that never resolves does not inherit the last one's name - the row
        -- would read '<the mob before it> - out of sight' and look stuck when
        -- it had in fact moved on.
        tm.mobName, tm.mobNameFor = ent:GetName(tm.mobIndex), tm.petTarget
        return tm.mobIndex
    end, nil)
end

-- The same for the mob a Deploy is pending on: found, confirmed and rescanned
-- the same way, with its own cache, so frame.lua's grace can tell a pending
-- Deploy whose target has gone from one whose target is merely far.
tm.deploySlot = function()
    if tm.demo ~= nil then return nil end
    return safe(function()
        local id = tm.deployTo
        if id == nil then return nil end
        local ent = AshitaCore:GetMemoryManager():GetEntity()
        if tm.deployIndexFor == id and tm.deployIndex ~= nil
           and ent:GetServerId(tm.deployIndex) == id then return tm.deployIndex end
        tm.deployIndex = nil
        local at = os.clock()
        if tm.deployScanAt == nil or at - tm.deployScanAt >= 1 then
            tm.deployScanAt = at
            tm.deployIndexFor, tm.deployIndex = id, scanFor(ent, id)
        end
        return tm.deployIndex
    end, nil)
end

-- The signature scan walks a ~2.9MB image; pupsets and chains both cache it
-- once at load. Running it per render frame would be ~60 scans/sec.
local pupOffsetCached = nil
local function pupBufferPtr()
    return safe(function()
        if pupOffsetCached == nil then
            pupOffsetCached = ffi.cast('uint32_t*', ashita.memory.find(
                'FFXiMain.dll', 0, 'C1E1032BC8B0018D????????????B9????????F3A55F5E5B', 10, 0))
        end
        if pupOffsetCached == nil then return 0 end
        local base = ashita.memory.read_uint32(AshitaCore:GetPointerManager():Get('inventory'))
        if base == 0 then return 0 end
        base = ashita.memory.read_uint32(base)
        if base == 0 then return 0 end
        return base + pupOffsetCached[0] + (isPup() and 0x00 or 0x9C)
    end, 0)
end

-- What the automaton is wearing, as fourteen names: head, frame, twelve
-- attachment slots, '' where a slot is empty. From the server's own 0x044
-- when one has arrived - it is sent on every equip, on zone, job change,
-- activation and any status change - else from the client's PUP memory
-- buffer, which is empty until the attachments window has been opened once
-- this session and goes on answering with the OLD loadout after an Apply
-- until an Activate refreshes it. Read from the buffer alone, the Heatsink
-- decay term, the Inhibitor hold, the sidebar and every attachment-granted
-- recast cell could describe a loadout the server had already replaced, or
-- none at all for the first minutes of a session.
-- The same order equippedSet() / liveSet() give the Loadout tab, so the tab,
-- the sidebar and the model read one loadout. Cached per 0x044 sequence
-- as well as per two seconds, so a fresh packet is seen at once.
local function equippedNames()
    if tm.demo ~= nil then return tm.demo.names end
    if tm.eqCache ~= nil and tm.eqCacheSeq == tm.auto044Seq
       and os.clock() - tm.eqCacheAt < 2.0 then return tm.eqCache end
    local out = {}
    safe(function()
        local res = AshitaCore:GetResourceManager()
        local function nameOf(id, offset)
            local item = res:GetItemById((id or 0) + offset)
            return (item ~= nil and item.Name[1] ~= nil and item.Name[1]:sub(1, 1) ~= '.')
                   and item.Name[1] or ''
        end
        local a = tm.auto044
        if a ~= nil and a.attachments ~= nil and (a.head or 0) ~= 0 and (a.frame or 0) ~= 0 then
            out[1], out[2] = nameOf(a.head, EQUIP_OFFSET), nameOf(a.frame, EQUIP_OFFSET)
            for slot = 1, 12 do out[slot + 2] = nameOf(a.attachments[slot], ATTACH_OFFSET) end
            return
        end
        local ptr = pupBufferPtr()
        if ptr == 0 then return end
        local raw = ashita.memory.read_array(ptr + 0x04, 0xE)
        for k, v in pairs(raw) do
            out[k] = nameOf(v, (k < 3) and EQUIP_OFFSET or ATTACH_OFFSET)
        end
    end)
    tm.eqCache, tm.eqCacheAt, tm.eqCacheSeq = out, os.clock(), tm.auto044Seq
    return out
end

-- Is a given attachment actually on the automaton right now?
-- equippedNames() is itself cached, so this is cheap to call per frame.
local function hasAttachment(name)
    local eq = equippedNames()
    for i = 3, 14 do
        if eq[i] == name then return true end
    end
    return false
end

-- Owned attachments straight from the 0x044 packet's UnlockedAttachments
-- bitmask - server truth, not a read of client memory.

local function ownedAttachments()
    local names = {}
    local mask = tm.auto044 and tm.auto044.owned or nil
    if mask == nil then return names end
    safe(function()
        local res = AshitaCore:GetResourceManager()
        for byteIndex = 1, #mask do
            local byteVal = mask:byte(byteIndex)
            for bit = 0, 7 do
                if (math.floor(byteVal / (2 ^ bit)) % 2) == 1 then
                    local id   = ((byteIndex - 1) * 8) + bit
                    local item = res:GetItemById(id + ATTACH_OFFSET)
                    if item ~= nil and item.Name[1] ~= nil and item.Name[1]:sub(1, 1) ~= '.' then
                        names[#names + 1] = item.Name[1]
                    end
                end
            end
        end
    end)
    table.sort(names)
    return names
end

local function oilCounts()
    if tm.demo ~= nil then return tm.demo.oils end
    if tm.oilCache ~= nil and os.clock() - tm.oilCacheAt < 2.0 then return tm.oilCache end
    local out = { ['Automaton Oil'] = 0, ['Automaton Oil +1'] = 0,
                  ['Automaton Oil +2'] = 0, ['Automaton Oil +3'] = 0 }
    safe(function()
        local inv = AshitaCore:GetMemoryManager():GetInventory()
        for c = 0, 12 do
            local mx = inv:GetContainerCountMax(c)
            if mx ~= nil and mx > 0 then
                for s = 0, mx do
                    local it = inv:GetContainerItem(c, s)
                    if it ~= nil and it.Id ~= 0 and OIL_IDS[it.Id] ~= nil then
                        out[OIL_IDS[it.Id]] = out[OIL_IDS[it.Id]] + it.Count
                    end
                end
            end
        end
    end)
    tm.oilCache, tm.oilCacheAt = out, os.clock()
    return out
end

-- The party's ServerIds, slots 1-5 (0 is the master), as a set. The 0x028
-- handler reads it off the render snapshot to count a party member's blow as
-- ours: the enmity list TryEnhance walks for its Regen target is the master,
-- the automaton and the party, and a stranger's blow is on none of it.
local function partyIds()
    local out = {}
    safe(function()
        local party = AshitaCore:GetMemoryManager():GetParty()
        for i = 1, 5 do
            local sid = party:GetMemberServerId(i)
            if sid ~= nil and sid ~= 0 then out[sid] = true end
        end
    end)
    return out
end

-- The twelve attachment slots as a plain list - the shape buffSummary and the
-- Sets preview both consume.
local function equippedAttachments()
    local eq, out = equippedNames(), {}
    for i = 3, 14 do
        if eq[i] ~= nil and eq[i] ~= '' then out[#out + 1] = eq[i] end
    end
    return out
end

return { petInfo = petInfo, equippedNames = equippedNames, partyIds = partyIds,
         hasAttachment = hasAttachment, ownedAttachments = ownedAttachments, oilCounts = oilCounts,
         equippedAttachments = equippedAttachments }
