-- cw/timers.lua - recast clocks for the automaton's own abilities, which the
-- server never reports. Owns tm.usedAt, tm.gaps, tm.model and tm.rows; publishes
-- tm.ability, tm.order and tm.timerRows (render thread); returns noteUse (packet
-- thread) and timersClear.
local config = require('cw.config')
local D  = require('cw.data')
local MOBSKILL_RANGED = D.MOBSKILL_RANGED
local tm = require('cw.state')
local A  = require('cw.attachments')
local attachMods = A.attachMods
local L  = require('cw.log')
local logEvent, flagAnomaly = L.logEvent, L.flagAnomaly
local R  = require('cw.reading')
local hasAttachment = R.hasAttachment
local B  = require('cw.burden')
local maneuverCounts = B.maneuverCounts

-- The automaton's own abilities, each on a recast the server never reports:
-- the clock starts when the 0x028 shows the use, the length is LSB's
-- (the per-ability automaton scripts, addRecast; Shield Bash and the shot
-- from automaton_controller.cpp setCooldowns / TryRangedAttack), and every
-- use is logged against it. The model's Horizon lengths: Provoke 30,
-- Flashbulb 45, Shock Absorber 180 and Shield Bash 180, and a resummon
-- clears them all - provisional, which is what the recast_early record is
-- for.

-- [mobskill id] = { name, cell label, LSB seconds, and either the frame
-- that owns it or the attachments that grant it }. A cell shows only
-- while its attachment is worn or its frame is out.
tm.ability = {
    [1944] = { name = 'Shield Bash',     label = 'Bash',       secs = 180, frame = 'Valoredge' },
    [1949] = { name = 'Ranged Attack',   label = 'Shot',       secs = 36,  frame = 'Sharpshot' },
    [1945] = { name = 'Provoke',         label = 'Provoke',    secs = 30,  attach = { 'Strobe', 'Strobe II' } },
    [1947] = { name = 'Flashbulb',       label = 'Flash',      secs = 45,  attach = { 'Flashbulb' } },
    -- labelled Stoneskin, not Absorber: the ability's effect on the
    -- automaton is a Stoneskin, and that is what the cell is read as at a
    -- glance. `name` stays the real ability name - the log records and the
    -- LSB recast model key off it.
    [1946] = { name = 'Shock Absorber',  label = 'Stoneskin',  secs = 180, attach = { 'Shock Absorber', 'Shock Absorber II', 'Shock Absorber III' } },
    [1948] = { name = 'Mana Converter',  label = 'Converter',  secs = 180, attach = { 'Mana Converter' } },
    [2021] = { name = 'Eraser',          label = 'Eraser',     secs = 30,  attach = { 'Eraser' } },
    [2031] = { name = 'Reactive Shield', label = 'R.Shield',   secs = 65,  attach = { 'Reactive Shield' } },
    [2068] = { name = 'Economizer',      label = 'Economizer', secs = 180, attach = { 'Economizer' } },
    [2132] = { name = 'Replicator',      label = 'Replicator', secs = 60,  attach = { 'Replicator' } },
    [2745] = { name = 'Heat Capacitor',  label = 'Capacitor',  secs = 90,  attach = { 'Heat Capacitor', 'Heat Capacitor II' } },
    [2746] = { name = 'Barrage Turbine', label = 'Turbine',    secs = 180, attach = { 'Barrage Turbine' } },
    [2747] = { name = 'Disruptor',       label = 'Disruptor',  secs = 60,  attach = { 'Disruptor' } },
}
-- cell order: the ones that fire every fight first
tm.order = { 1945, 1947, 1946, 1944, 1949, 2021, 1948, 2031, 2068, 2132, 2745, 2746, 2747 }

-- Packet thread. The model length comes from tm.model, filled by
-- timerRows on the render thread - no native reads here.
local function noteUse(id, now)
    local row = tm.ability[id]
    if row == nil then return end
    local model = tm.model[id] or row.secs
    -- ...and whether that model came from a head the client could read.
    -- Only the anomaly is withheld when it did not: the use is still
    -- logged, with its real gap, so the calibration set keeps growing.
    local known = tm.modelKnown[id] ~= false
    local last  = tm.usedAt[id]
    local rec   = { skill_id = id, name = row.name, model = model }
    if not known then rec.model_known = false end
    if last ~= nil then
        local gap = math.floor((now - last) * 10) / 10
        rec.gap = gap
        local g = tm.gaps[id] or {}
        g[#g + 1] = gap
        while #g > 30 do table.remove(g, 1) end
        tm.gaps[id] = g
        if known and gap < model - config.recast_tolerance then
            rec.early = math.floor((model - gap) * 10) / 10
            flagAnomaly('recast_early', rec)
        else
            logEvent('pet_ability', rec)
        end
    elseif tm.edgeAt ~= nil then
        -- first use since a summon or a zone: how long the automaton
        -- waited says whether Horizon really starts it clear. `edge` says
        -- which of the two it was, so the populations stay separable.
        rec.since_edge = math.floor((now - tm.edgeAt) * 10) / 10
        rec.edge = tm.edgeSrc or 'unknown'
        logEvent('recast_edge', rec)
    else
        logEvent('pet_ability', rec)
    end
    tm.usedAt[id] = now
end

-- edge = true: everything ready. false: unknown. `src` names WHAT made the
-- edge - 'activate', 'dea', 'zone', 'pet_despawn', 'pet_respawn' - and
-- rides along on the recast_edge record. Without it a zone reading and a
-- fresh-automaton reading are the same line in the log, and they are not
-- the same thing: one is the server resetting a surviving
-- automaton's recasts, the other is an automaton that has just been built.
local function timersClear(edge, src)
    tm.usedAt, tm.gaps, tm.windowAt, tm.spellRecast = {}, {}, {}, {}
    -- tm.mobs is NOT cleared: the mobs did not change when the automaton
    -- did. The zone handler clears it, and a death drops its own mob.
    tm.edgeAt = edge and os.clock() or nil
    tm.edgeSrc = edge and src or nil
    -- petTarget belongs to the incarnation too. It is assigned in exactly
    -- one place and, without this, never returns to 0 - so it keeps naming
    -- an entity from a previous fight, zone or job. Two things depend on
    -- that being wrong: the 0x028 handler's mob-effect block, which sits
    -- ABOVE its is_pup gate and would otherwise record any job's status
    -- wear-offs against a stale id; and ctx.engaged, which is
    -- `petTarget ~= 0` and would otherwise be true for the whole session.
    tm.petTarget = 0
    tm.deployTo = nil
end

-- Render thread, once per frame: which timers are live, their model
-- length under the head / frame / attachments worn now, and their state.
-- Also the packet thread's copy of the model (tm.model).
tm.timerRows = function()
    local now, rows = os.clock(), {}
    local counts = maneuverCounts()
    local head = tm.currentHead() or 0
    -- The server's frame first (tm.frameNow). Without it the shot's model
    -- falls back to row.secs (36 s) while noteUse fires anyway, so a normal
    -- 20 s Sharpshot cadence would flag recast_early, with a red chat line,
    -- on every single shot.
    local frame = tm.frameNow()
    for _, id in ipairs(tm.order) do
        -- `grant` is the ITEM the ability came from - the attachment worn, or
        -- the frame out. The compact strip draws that item's own icon in place
        -- of a coloured box, so the cell says which ability it is rather than
        -- relying on a fixed order the player has to learn.
        local row, show, grant = tm.ability[id], false, nil
        if row.frame ~= nil then
            show = (frame == row.frame)
            grant = show and (row.frame .. ' Frame') or nil
        else
            for _, a in ipairs(row.attach) do
                if hasAttachment(a) then show, grant = true, a break end
            end
        end
        -- The model is the packet thread's copy, so it is computed
        -- whether or not the cell shows: noteUse fires unconditionally and
        -- would otherwise measure a real gap against row.secs.
        local secs, known = row.secs, true
        if id == MOBSKILL_RANGED then
            -- TryRangedAttack: by head, less Drum Magazine, floored. NOTE
            -- that 36 is also the fallback when the head is UNKNOWN, not
            -- just when it is a non-Sharpshot head - `head` is 0 until
            -- either a 0x044 or the client buffer names one. Judging a real
            -- 20 s cadence against 36 would flag every shot, with a chat
            -- line, for the whole window after a reload; say the model is
            -- not known instead. Every other row's model is a constant, so
            -- only this one can be unknown.
            known = head ~= 0
            secs = (head == 3) and 20 or (head == 1) and 25 or 36
            if hasAttachment('Drum Magazine') then
                local _, _, mods = attachMods('Drum Magazine', counts)
                secs = secs - ((mods[1] and mods[1][3]) or 0)
            end
            secs = math.max(secs, (head == 3) and 5 or 10)
        end
        tm.model[id], tm.modelKnown[id] = secs, known
        if show then
            local r = { id = id, label = row.label, name = row.name, model = secs,
                        grant = grant }
            local last = tm.usedAt[id]
            if last == nil then
                r.state = (tm.edgeAt ~= nil) and 'ready' or 'unknown'
            else
                local rem = secs - (now - last)
                if rem > 0 then r.state, r.remaining = 'counting', rem
                else r.state = 'ready' end
            end
            rows[#rows + 1] = r
        end
    end
    tm.rows = rows
    return rows
end

return { noteUse = noteUse, timersClear = timersClear }
