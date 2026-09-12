-- ------------------------------------------------------------- helpers --
-- What the suites build their fixtures from: the 0x044, 0x029 and 0x028
-- packet builders, the automaton in and out of the world, act() for one
-- automaton action, frame() and the draw-list queries, and the log and
-- recast-row readers. Nothing here asserts anything by itself except
-- frame(), which checks every Begin/Push met its End/Pop.

-- ------------------------------------------------------ 0x044 builder --
-- Raw offsets per LSB 0x044_extended_job_pup.h with PacketData at 0x04:
-- 0x04 job, 0x08 head, 0x09 frame, 0x0A..0x15 attachments, 0x18 heads mask,
-- 0x1C frames mask, 0x38..0x57 attachments mask (256 bits), stat block to 0xA0.
local function u32bytes(v)
    return string.char(v % 256, math.floor(v / 256) % 256, math.floor(v / 65536) % 256, math.floor(v / 16777216) % 256)
end
local function u16bytes(v)
    return string.char(v % 256, math.floor(v / 256) % 256)
end
local function build044(s)
    local b = {}
    for i = 1, 0xA4 do b[i] = 0 end
    -- The job the packet describes. BST shares the opcode with a different
    -- layout, so the addon gates on this - and the builder hardcoded 18, which
    -- is why a mutant that deleted the gate passed every check.
    b[0x04 + 1] = s.job or 18
    b[0x08 + 1] = s.head or 0
    b[0x09 + 1] = s.frame or 0
    -- the stat block: HP/MP at 0x68..0x6E, then the three skills in pairs -
    -- melee 0x70, ranged 0x74, magic 0x78 (0x044_extended_job_pup.h). Melee and
    -- ranged gate predictWS's weaponskill list, so they have to be settable.
    local function put16(off, v) local w = u16bytes(v or 0) b[off + 1] = w:byte(1) b[off + 2] = w:byte(2) end
    put16(0x68, s.hp) put16(0x6A, s.maxhp) put16(0x6C, s.mp) put16(0x6E, s.maxmp)
    put16(0x70, s.melee) put16(0x74, s.ranged) put16(0x78, s.magic)
    -- The attachments the fixture names, else whatever world.buffer says the
    -- automaton is wearing: since 1.17.12 the addon reads the 0x044 first
    -- and the buffer only when no packet has arrived, and a fixture that
    -- dresses the automaton through world.buffer and then sends a 0x044
    -- describes ONE automaton, as the server and client do.
    local wearing = s.attachments
    if wearing == nil and world.buffer ~= nil then
        wearing = {}
        for i = 1, 12 do wearing[i] = world.buffer[i + 2] or 0 end
    end
    for i = 1, 12 do b[0x0A + i] = (wearing and wearing[i]) or 0 end
    local heads, frames = u32bytes(s.heads or 0), u32bytes(s.frames or 0)
    for i = 1, 4 do b[0x18 + i] = heads:byte(i) b[0x1C + i] = frames:byte(i) end
    for _, id in ipairs(s.owned or {}) do
        local byte = 0x38 + math.floor(id / 8) + 1
        b[byte] = b[byte] + 2 ^ (id % 8)
    end
    -- the stat block: base at 0x80.. in steps of 4, bonus left at 0
    local STAT_OFF = { STR = 0x80, DEX = 0x84, VIT = 0x88, AGI = 0x8C, INT = 0x90, MND = 0x94, CHR = 0x98 }
    for name, v in pairs(s.stats or {}) do
        b[STAT_OFF[name] + 1] = v % 256
        b[STAT_OFF[name] + 2] = math.floor(v / 256)
    end
    local out = {}
    for i = 1, #b do out[i] = string.char(b[i]) end
    return table.concat(out)
end
local last044 = nil
local function send044(s)
    last044 = s
    handlers['packet_in']({ id = 0x044, injected = false, data = build044(s) })
end

-- world.buffer is "what the automaton is wearing", and 88 fixtures dress it
-- that way. Since 1.17.12 the addon reads the 0x044 first and the client
-- buffer only until one has arrived, so a fixture that changes the outfit
-- while a packet is live has to say so the way the server does - with
-- another 0x044 - or the addon keeps reading the packet it already has.
-- Done once, here, for every site: the field lives behind a metatable, and
-- an assignment while a packet is live re-sends the last one with the new
-- head, frame and attachments (build044 takes those from the buffer). With
-- no packet live - the start of the suite, and after api.clear044() - the
-- buffer is read directly, which is the fallback path under test there.
local bufferShadow = rawget(world, 'buffer')
rawset(world, 'buffer', nil)
setmetatable(world, {
    __index = function(_, k) if k == 'buffer' then return bufferShadow end return nil end,
    __newindex = function(t, k, v)
        if k ~= 'buffer' then rawset(t, k, v) return end
        bufferShadow = v
        if v ~= nil and last044 ~= nil and api.state().auto044 ~= nil then
            local s = {}
            for kk, vv in pairs(last044) do s[kk] = vv end
            if (v[1] or 0) ~= 0 then s.head = v[1] end
            if (v[2] or 0) ~= 0 then s.frame = v[2] end
            s.attachments = nil
            send044(s)
        end
    end,
})

-- 0x029 battle message: 0x04 actor, 0x08 target, 0x0C param, 0x18 message
local function send029(cas, tgt, param, msg)
    local b = {}
    for i = 1, 0x20 do b[i] = 0 end
    local function put32(off, v) local w = u32bytes(v) for i = 1, 4 do b[off + i] = w:byte(i) end end
    put32(0x04, cas) put32(0x08, tgt) put32(0x0C, param)
    local w = u16bytes(msg) b[0x18 + 1], b[0x18 + 2] = w:byte(1), w:byte(2)
    local out = {}
    for i = 1, #b do out[i] = string.char(b[i]) end
    handlers['packet_in']({ id = 0x029, injected = false, data = table.concat(out) })
end
-- The automaton and its target in the world, and the packet thread's
-- snapshot refreshed (only d3d_present does that). The mob id is a
-- parameter because gather() finds the target's HP% by scanning
-- GetServerId for petTarget: a block that fights MOB + n must put that
-- same id in the entity table or its HP is unreadable.
local PET, MOB = 0x01000200, 0x01000300
local function petOut(id, mob)
    world.mainjob, world.petIndex, world.petId = 18, 5, id or PET
    world.mobIndex, world.mobId = 9, mob or MOB
    handlers['d3d_present']()
end
local function petIn()
    world.petIndex, world.petId = 0, 0
    handlers['d3d_present']()
end
-- one automaton action, one target, one result line.
-- Category 8 is not literal: the server puts the spell's FourCC in the header
-- action id - 24931 for every cast of every group - and the spell id in the
-- first result's param. `act(8, <spell id>)` therefore builds THAT shape, so
-- the fixtures exercise the packet the server sends rather than one it never
-- does. (No cat-8 fixture passes `aparam`, which is what the spell id takes.)
local function act(category, param, tgt, message, aparam, recast)
    local header, result = param, aparam or 0
    if category == 8 then header, result = 24931, param end
    return { actor = world.petId, category = category, param = header, recast = recast,
             targets = { { id = tgt or MOB, actions = { { message = message or 0, param = result } } } } }
end

-- ---------------------------------------------------- frame and draw list --
-- frame() renders one frame into `drawn`; saw / sawExact / countExact ask
-- what it drew.
local function saw(text)
    for _, d in ipairs(drawn) do if d:find(text, 1, true) then return true end end
    return false
end
local function sawExact(text)
    for _, d in ipairs(drawn) do if d == text then return true end end
    return false
end
-- How MANY times, for layout offsets a header and its rows both emit: 'was
-- SameLine(128) called' cannot tell the two apart, and dropping either one
-- leaves the other behind to satisfy it.
local function countExact(text)
    local n = 0
    for _, d in ipairs(drawn) do if d == text then n = n + 1 end end
    return n
end

-- Render one frame; every Begin/Push must have met its End/Pop.
local function frame(label)
    drawn, availCalls, addTexts, dummies, hoverArmed = {}, 0, 0, 0, false
    handlers['d3d_present']()
    local open = {}
    for k, d in pairs(depth) do
        if d ~= 0 then open[#open + 1] = k .. '=' .. d end
        depth[k] = 0
    end
    table.sort(open)
    check(label .. ': balanced', table.concat(open, ' '), '')
end

-- ------------------------------------------------------- 0x028 builder --
-- Bit layout per unpackAction: actor at 40/32, target count at 72/10,
-- category at 82/4, param at 86/16, targets from 150: id 32 + count 4, then
-- 86 bits per action (reaction 5, animation 12, effect 4, gap 6, param 17,
-- message 10, the rest unused) and one more for the two extension flags,
-- both left 0. Also: recast at 118/32, and the header's sequence at 16/16.
local seq028 = 0
local function build028(p)
    local bits = {}
    local function put(offset, len, v)
        for i = 0, len - 1 do
            if math.floor(v / 2 ^ i) % 2 == 1 then bits[offset + i] = true end
        end
    end
    -- The server stamps every packet in a chunk with the chunk's number and a
    -- resent chunk carries the same one (map_networking.cpp), which is what
    -- isDuplicate's 24-byte key relies on. A fresh number per packet here, so
    -- two real actions of the same shape are two packets as they are in the
    -- game; a fixture passes `seq` to play a resend.
    if p.seq == nil then seq028 = seq028 + 1 end
    put(16, 16, p.seq or seq028)
    put(40, 32, p.actor)
    put(72, 10, #p.targets)
    put(82, 4, p.category)
    put(86, 16, p.param)
    -- the recast the server applied, in seconds (s2c/0x028_battle2.cpp:46)
    put(118, 32, p.recast or 0)
    local offset = 150
    for _, tgt in ipairs(p.targets) do
        put(offset, 32, tgt.id)
        put(offset + 32, 4, #tgt.actions)
        offset = offset + 36
        for _, a in ipairs(tgt.actions) do
            put(offset + 27, 17, a.param or 0)
            put(offset + 44, 10, a.message or 0)
            -- the two variable-length tails, exactly as unpackAction reads
            -- them: the additional-effect flag is the last bit of the fixed 86
            -- and costs 37 more when set; the spikes flag follows it and costs
            -- 35. Both clear is the old 86 + 1.
            local n = offset + 86
            -- a.add = { message, param } fills the additional-effect tail the
            -- way fancychat lays it out (param at +10 for 17 bits, message at
            -- +27 for 10); a.spike = { message, param } the spikes tail
            -- (flag, then param at +11 for 14, message at +25 for 10).
            if a.addeff or a.add then
                put(n - 1, 1, 1)
                if a.add then put(n + 10, 17, a.add.param or 0) put(n + 27, 10, a.add.message or 0) end
                n = n + 37
            end
            if a.spikes or a.spike then
                put(n, 1, 1)
                if a.spike then put(n + 11, 14, a.spike.param or 0) put(n + 25, 10, a.spike.message or 0) end
                n = n + 35
            else n = n + 1 end
            offset = n
        end
    end
    local out = {}
    for i = 1, math.ceil((offset + 8) / 8) + 24 do
        local b = 0
        for j = 0, 7 do if bits[(i - 1) * 8 + j] then b = b + 2 ^ j end end
        out[i] = string.char(b)
    end
    return table.concat(out)
end
local function send028(p)
    handlers['packet_in']({ id = 0x028, injected = false, data = build028(p) })
end

-- ------------------------------------------------------- 0x076 builder --
-- The party's buffs: up to five { id = ServerId, buffs = { effect ids } },
-- laid out as XiPackets world/server/0x0076 has it - 0x30 bytes each from
-- 0x04, the id at +0, two high bits per buff at +0x08, the low bytes at +0x10
-- with 0xFF in every unused slot.
local function send076(members)
    local b = {}
    for i = 1, 0x04 + 5 * 0x30 do b[i] = 0 end
    for i, mem in ipairs(members) do
        local base = 0x04 + 0x30 * (i - 1)
        for k = 0, 3 do b[base + k + 1] = math.floor(mem.id / 256 ^ k) % 256 end
        for j = 0, 31 do b[base + 0x10 + j + 1] = 0xFF end
        for j, buff in ipairs(mem.buffs or {}) do
            local slot = j - 1
            b[base + 0x10 + slot + 1] = buff % 256
            local at = base + 0x08 + math.floor(slot / 4) + 1
            b[at] = b[at] + math.floor(buff / 256) * 4 ^ (slot % 4)
        end
    end
    local out = {}
    for i = 1, #b do out[i] = string.char(b[i]) end
    handlers['packet_in']({ id = 0x076, injected = false, data = table.concat(out) })
end

-- ------------------------------------------------------- log and recasts --
-- The last log record of a kind, read back from the file the addon writes,
-- and one recast row by ability id.
local function lastLog(kind)
    local f = io.open(SCRATCH .. '/config/addons/clockwork/Harness_' .. os.date('%Y.%m.%d') .. '.jsonl', 'r')
    if f == nil then return nil end
    local hit = nil
    for line in f:lines() do
        if line:find('"kind":"' .. kind .. '"', 1, true) then hit = line end
    end
    f:close()
    return hit
end
local function timerRow(id)
    for _, r in ipairs(api.timerRows()) do if r.id == id then return r end end
    return nil
end
