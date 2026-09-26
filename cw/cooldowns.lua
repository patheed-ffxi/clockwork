-- cw/cooldowns.lua - your own job abilities' recasts, for the Status tab's
-- recast column. The client keeps these itself, so they are READ, not
-- modelled: nothing here is logged, and there is nothing to calibrate. Native
-- reads, so render thread only - the packet thread must never require this
-- file. Publishes tm.jaList and tm.jaRefresh; tm.jaRefresh writes tm.jaRows.
local config = require('cw.config')
local tm = require('cw.state')
local U  = require('cw.util')
local safe, player = U.safe, U.player

-- The PUP job abilities, in the order the column lists them: bringing the
-- automaton back, keeping it alive, the next maneuver, the tank tools, then
-- the ten-second housekeeping and the two-hour. `ability` is LSB's abilityId,
-- `timer` its recastId (sql/abilities.sql), which is the id the server puts in
-- the client's recast table. Each is listed while config['cd_' .. key] is on.
-- Tactical Switch, Cooldown and Heady Artifice are past the level cap.
tm.jaList = {
    { key = 'activate',      label = 'Activate',   name = 'Activate',         ability = 136, timer = 205 },
    { key = 'dea',           label = 'Deus Ex',    name = 'Deus Ex Automata', ability = 310, timer = 115 },
    { key = 'repair',        label = 'Repair',     name = 'Repair',           ability = 137, timer = 206 },
    -- LSB tags it ABYSSEA; HasAbility says whether this server grants it
    { key = 'maintenance',   label = 'Maint.',     name = 'Maintenance',      ability = 322, timer = 214 },
    -- all eight maneuvers share timer 210, so one row; Fire Maneuver stands in
    -- for the eight when asking whether you have them
    { key = 'maneuver',      label = 'Maneuver',   name = 'Maneuver',         ability = 141, timer = 210 },
    { key = 'role_reversal', label = 'Reversal',   name = 'Role Reversal',    ability = 179, timer = 211 },
    { key = 'ventriloquy',   label = 'Ventrilo',   name = 'Ventriloquy',      ability = 180, timer = 212 },
    { key = 'deploy',        label = 'Deploy',     name = 'Deploy',           ability = 138, timer = 207 },
    { key = 'retrieve',      label = 'Retrieve',   name = 'Retrieve',         ability = 140, timer = 209 },
    { key = 'deactivate',    label = 'Deactivate', name = 'Deactivate',       ability = 139, timer = 208 },
    -- the two-hour: slot 0 of the recast table, whose timer id is 0
    { key = 'overdrive',     label = 'Overdrive',  name = 'Overdrive',        ability = 135, timer = 0 },
}

-- HasAbility takes the resource id, which for a job ability is 0x200 on top of
-- LSB's abilityId: thotbar scans GetAbilityById over 0x200..0x600 for them and
-- XIUI hands HasAbility that same id. Inferred from those two, not read off
-- the SDK. If it is wrong, every row reads as unlearned and the group is
-- simply absent - never a wrong number.
local JA_RESOURCE = 0x200

-- Seconds left on every recast the client is counting, by timer id. A ready
-- ability holds no slot at all. Slot 0 is the two-hour and its timer id is 0,
-- which in any other slot means empty - hence (id ~= 0 or i == 0), the guard
-- Ashita's own recast addon uses. The timer counts 1/60 s ticks.
local function recastLeft()
    local r, left = AshitaCore:GetMemoryManager():GetRecast(), {}
    for i = 0, 31 do
        local id, ticks = r:GetAbilityTimerId(i), r:GetAbilityTimer(i)
        if (id ~= 0 or i == 0) and ticks > 0 then left[id] = ticks / 60 end
    end
    return left
end

-- How long each recast is, by timer id. The client says only what is left,
-- but this runs every frame, so the first value seen after a use is the whole
-- recast - merits and gear included - and the most seen since is kept until
-- the ability is ready again. After a reload mid-recast the first value seen
-- is part of one, so that recast's dial starts full.
local longest = {}

-- Render thread, once a frame from frame.tick, below its visibility gates:
-- this is display only, so it has no reason to run with the window down. One
-- safe() round the lot, so a failed read is an empty group and one count in
-- tm.swallowed.
tm.jaRefresh = function()
    tm.jaRows = safe(function()
        local left, p, rows = recastLeft(), player(), {}
        for timer in pairs(longest) do
            if left[timer] == nil then longest[timer] = nil end
        end
        for timer, rem in pairs(left) do
            if rem > (longest[timer] or 0) then longest[timer] = rem end
        end
        for _, ja in ipairs(tm.jaList) do
            local rem = left[ja.timer]
            if config['cd_' .. ja.key] and p:HasAbility(JA_RESOURCE + ja.ability)
               and (rem ~= nil or not config.cd_hide_ready) then
                rows[#rows + 1] = { key = ja.key, label = ja.label, name = ja.name,
                                    state = (rem ~= nil) and 'counting' or 'ready',
                                    remaining = rem, total = longest[ja.timer] }
            end
        end
        return rows
    end, {})
end

return {}
