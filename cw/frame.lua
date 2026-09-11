-- cw/frame.lua - the render thread's per-frame model work, and whether to draw
-- at all. Owns the visibility checks and target expiry. Exports tick(), which
-- refreshes the snapshot the packet thread reads (tm.snap, tm.spell,
-- tm.predManeuvers) and returns true only when the HUD should draw.
local config = require('cw.config')
local D  = require('cw.data')
local ELEMENTS = D.ELEMENTS
local tm = require('cw.state')
local U  = require('cw.util')
local safe, isPup, isPupSub, equippedThreshold = U.safe, U.isPup, U.isPupSub, U.equippedThreshold
local isLoggedIn, atCharacterSelect = U.isLoggedIn, U.atCharacterSelect
local L  = require('cw.log')
local logEvent = L.logEvent
local R  = require('cw.reading')
local hasAttachment, partyIds = R.hasAttachment, R.partyIds
local B  = require('cw.burden')
local refreshStatChecks, activeManeuvers, maneuverCounts, decay = B.refreshStatChecks, B.activeManeuvers, B.maneuverCounts, B.decay
local refreshPrediction = B.refreshPrediction
local P  = require('cw.pet')
local DEMO = require('cw.demo')
local resolveIds, forgetCharacter = P.resolveIds, P.forgetCharacter
-- The shared tables, never reassigned after cw/state.lua creates them.
local ids, snap = tm.ids, tm.snap

-- ------------------------------------------------------------ visibility --
-- Same courtesy every other UI addon extends: get out of the way for the map,
-- for cutscenes, for the game's own hide-interface toggle, and whenever there
-- is no logged-in character to talk about. Signatures are Velyn's, by way of
-- HXUI and XIUI (XIUI/core/gamestate.lua). Scanned once and cached - a
-- find() walks a ~2.9MB image and this is called every frame.
local sigs = nil
local function gameSigs()
    if sigs == nil then
        sigs = {
            menu      = ashita.memory.find('FFXiMain.dll', 0,
                '8B480C85C974??8B510885D274??3B05', 16, 0),
            event     = ashita.memory.find('FFXiMain.dll', 0,
                'A0????????84C0741AA1????????85C0741166A1????????663B05????????0F94C0C3', 0, 0),
            interface = ashita.memory.find('FFXiMain.dll', 0,
                '8B4424046A016A0050B9????????E8????????F6D81BC040C3', 0, 0),
        }
    end
    return sigs
end

-- The open menu's internal name, e.g. 'menu    map     '. Empty when none is.
local function menuName()
    local p = gameSigs().menu
    if p == nil or p == 0 then return '' end
    local sub = ashita.memory.read_uint32(p)
    if sub == 0 then return '' end
    local val = ashita.memory.read_uint32(sub)
    if val == 0 then return '' end
    local header = ashita.memory.read_uint32(val + 4)
    if header == 0 then return '' end
    return (ashita.memory.read_string(header + 0x46, 16):gsub('\x00', ''))
end

local function uiHidden()
    return safe(function()
        -- map and region map both carry 'map' in the menu name
        if menuName():match('map') ~= nil then return true end

        local ev = gameSigs().event
        if ev ~= nil and ev ~= 0 then
            local p = ashita.memory.read_uint32(ev + 1)
            if p ~= 0 and ashita.memory.read_uint8(p) == 1 then return true end
        end

        local hidden = gameSigs().interface
        if hidden ~= nil and hidden ~= 0 then
            local p = ashita.memory.read_uint32(hidden + 10)
            if p ~= 0 and ashita.memory.read_uint8(p + 0xB4) == 1 then return true end
        end

        -- No party slot 0 means no character in the world: title screen,
        -- character select, mid-zone.
        return AshitaCore:GetMemoryManager():GetParty():GetMemberTargetIndex(0) == 0
    end, false)
end

-- ------------------------------------------------------- target expiry --
-- petTarget is only ever ASSIGNED - by an action the automaton takes - so
-- something has to take it away again. A death message does that exactly
-- (inbound.lua, 0x029), but not every target ends in one we see: a mob that
-- depops, one that deaggroes and walks home, or anything killed while we are
-- out of range leaves the id naming an entity that is simply gone. Left
-- alone, the row would read '<mob> - out of sight' for the rest of the
-- session and ctx.engaged would stay true with nothing to fight.
--
-- So: once the target has been unreadable for TARGET_GRACE, it is over. The
-- grace matters - a slot flap between frames is normal and must not end a
-- fight - and so does the throttle: this is a native read, and mobSlot()
-- walks 1,536 entity slots whenever its cached index misses.
local TARGET_GRACE = 10
-- One grace clock. `st` is its state ({ at, id, checkAt }, on tm so a reload
-- starts clean), `id` the entity it runs for (0 or nil: nothing to watch) and
-- `slot` how to find that entity. Returns true once the entity has been
-- unreadable for TARGET_GRACE - out of the entity table, or in it at zero:
-- the server never reports a living mob below 1, so both mean the same.
-- The clock belongs to ONE id and starts over when the id changes, so a new
-- target that is itself out of range on first sight does not inherit the
-- last one's nearly spent clock and get dropped on its second check.
local function goneFor(st, id, slot)
    if id == nil or id == 0 or tm.demo ~= nil then st.at = nil return false end
    local now = os.clock()
    if st.checkAt ~= nil and now - st.checkAt < 1 then return false end
    st.checkAt = now
    local s = slot()
    if s ~= nil and tm.mobHpp(s) > 0 then st.at = nil return false end
    if st.at == nil or st.id ~= id then st.at, st.id = now, id return false end
    if now - st.at >= TARGET_GRACE then st.at = nil return true end
    return false
end
-- The engagement, and separately the Deploy pending on a mob nobody has acted
-- on yet: a death message ends either (inbound.lua), and for everything that
-- does not send one - a depop, a deaggro, a kill out of range - this does.
-- A pending Deploy that outlives its target reads as an engagement in
-- gather(), and the enhance rung would withhold Regen for a fight that has ended.
local function expireTarget()
    if goneFor(tm.targetGone, tm.petTarget, tm.mobSlot) then tm.petTarget = 0 end
    if goneFor(tm.deployGone, tm.deployTo, tm.deploySlot) then tm.deployTo = nil end
end

-- Flame Holder measurement: the server strips maneuvers on weaponskill EXIT,
-- so count Fire a beat after the packet, again once it has settled, and log
-- the difference. tm.fhPending is set by the automaton's weaponskill handler
-- (inbound.lua) and cleared here.
local function sampleFlameHolder()
    if tm.fhPending == nil then return end
    local mans = activeManeuvers()
    if tm.fhPending.before == nil and os.clock() - tm.fhPending.at < 0.35 then
        local fire, minRem = 0, 999
        for _, m in ipairs(mans) do
            if m.element == 'Fire' then
                fire = fire + 1
                if (m.remaining or 0) < minRem then minRem = m.remaining or 0 end
            end
        end
        tm.fhPending.before, tm.fhPending.minRem = fire, (fire > 0) and minRem or 0
    elseif tm.fhPending.before ~= nil and os.clock() - tm.fhPending.at > 2.5 then
        local after = 0
        for _, m in ipairs(mans) do
            if m.element == 'Fire' then after = after + 1 end
        end
        local equipped = hasAttachment('Flame Holder')
        if tm.fhPending.before > 0 then
            logEvent('flame_holder', {
                ws            = tm.fhPending.ws,
                fire_before   = tm.fhPending.before,
                fire_after    = after,
                consumed      = tm.fhPending.before - after,
                -- if the shortest-lived Fire maneuver had under ~3s left it
                -- could have expired naturally; treat those samples as soft
                min_remaining = tm.fhPending.minRem,
                natural_risk  = (tm.fhPending.minRem <= 3),
                equipped      = equipped,
            })
        end
        tm.fhPending = nil
    elseif os.clock() - tm.fhPending.at > 5.0 then
        tm.fhPending = nil
    end
end

-- What every frame does before anything is drawn: the ids, the decay tick,
-- the snapshot the packet thread reads, the Flame Holder sample, the stat
-- checks, the predictions, the recast rows, the loadout record. Returns
-- whether the window should draw this frame.
local function tick()
    -- Nothing to instrument, and nothing to draw over, without a character in
    -- the world. First, before any of the reads below: at character select the
    -- job memory still says PUP and the party table still holds a slot, so the
    -- gates further down would all answer yes and put the HUD on top of the
    -- character list. Demo mode is no exception - it fakes a world, not a login.
    if not isLoggedIn() then
        -- At the character screen nothing that has arrived so far can be
        -- the next character's: mark the sequence, so that only a 0x044
        -- after this point counts as theirs below.
        if atCharacterSelect() then tm.auto044SeqSeen = tm.auto044Seq end
        return false
    end
    -- The made-up world moves before anything reads it, so the model sees a
    -- moving picture rather than a still one. Costs nothing when demo mode is off.
    DEMO.tick()
    -- resolveIds() before decay(): decay needs to know whether a pet exists.
    -- Not under demo: the made-up automaton has no client entity, so the
    -- respawn/despawn edges resolveIds() draws from the real one would fire
    -- against it - every demo recast reading 'ready', the target row blank
    -- and a false pet_despawn in the log.
    if tm.demo == nil then
        resolveIds()
        -- A different character than this state describes: forget it. The
        -- zone-in of the new one comes with a 0x044 during the loading
        -- screen, when no frame runs, so a packet newer than the last frame
        -- saw is the new character's and stays.
        if ids.self_id ~= 0 then
            if tm.owner ~= nil and ids.self_id ~= tm.owner then
                forgetCharacter(tm.auto044Seq > tm.auto044SeqSeen)
            end
            tm.owner = ids.self_id
        end
        tm.auto044SeqSeen = tm.auto044Seq
    end
    decay()
    snap.self_id = ids.self_id
    snap.pet_id  = ids.pet_id
    snap.party   = partyIds()   -- a member's blow counts as ours on a mob's enmity list
    snap.is_pup  = isPup() or isPupSub()
    snap.thresh  = equippedThreshold()   -- for elements that have not resolved yet
    expireTarget()   -- before anything reads petTarget: the ladder, the row
    sampleFlameHolder()

    if tm.statsDirty then
        tm.statsDirty = false
        refreshStatChecks()   -- needs player() reads, so it happens here
    end
    if not snap.is_pup then return false end
    -- Render-thread snapshot for the packet handler: it must never do the
    -- native reads (PUP buffer, resources, status icons) itself. Runs even
    -- with the window hidden - logging works either way.
    refreshPrediction()
    tm.timerRows()   -- tm.model for the packet thread, tm.rows for the HUD
    tm.flushLoadout()   -- one record per Activate, once the server names the new automaton
    do   -- the spell snapshot the packet thread compares a cast start with
        tm.windows = ''
        local name, why, mode, rung, hedge, mpUnsure = tm.predictSpell()
        -- A non-nil hedge means the line that went out named a Regen as the
        -- thing that might take the window instead, and the packet thread
        -- needs that to judge the cast. Taken from the RETURN, not from tm:
        -- the sidebar's hypothetical ladders run after this and write their
        -- own tm.regenHedge, which is a frame too late to be this line's.
        tm.spell = { name = name, why = why, mode = mode, rung = rung, windows = tm.windows,
                     hedge = (hedge ~= nil) and 'regen' or nil, mpUnsure = mpUnsure }
    end
    do  -- compact maneuver census recorded alongside every prediction
        local c = maneuverCounts()
        local parts = {}
        for _, el in ipairs(ELEMENTS) do
            if (c[el] or 0) > 0 then parts[#parts + 1] = el:sub(1, 2) .. c[el] end
        end
        tm.predManeuvers = (#parts > 0) and table.concat(parts, '/') or 'none'
    end
    if not config.show_window then return false end
    -- Everything above this line is the model and the logger: they keep
    -- running with the window down. Only the drawing stops.
    if uiHidden() then return false end
    return true
end

return { tick = tick }
