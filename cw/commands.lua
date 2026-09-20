-- cw/commands.lua - the /clockwork and /cw command handler: the help, the owned
-- and equipped listings, demo, compact, show, reset and sync. Exports onCommand.
local chat = require('chat')
local config = require('cw.config')
local D  = require('cw.data')
local ELEMENTS = D.ELEMENTS
local tm = require('cw.state')
local L  = require('cw.log')
local logPath = L.logPath
local R  = require('cw.reading')
local equippedNames, ownedAttachments = R.equippedNames, R.ownedAttachments
local B  = require('cw.burden')
local applyStatCheck, computeCost, myStat = B.applyStatCheck, B.computeCost, B.myStat
local P  = require('cw.pet')
local S  = require('cw.sets')
local DEMO = require('cw.demo')
local resetModel = P.resetModel
-- The shared table, never reassigned after cw/state.lua creates it.
local samples = tm.samples

-- `/cw stat` - your side of the stat check, typed, for the gear the client
-- cannot be asked about: a swap sends no stat packet, so a maneuver set's stats
-- never reach memory and the live read is whatever was worn at the last refresh
-- (the equipment menu, a level, a kill). The number is compared against the
-- automaton's LIVE stat on every use, so an element you beat bare still costs
-- 20 once that element is stacked.
local function statCommand(which, value)
    local function say(line) print(chat.header('clockwork'):append(chat.message(line))) end
    local function oops(line) print(chat.header('clockwork'):append(chat.error(line))) end
    local function statName(el) return D.MANEUVER_STAT[el] or '?' end

    if which == nil then
        say('the stat you wear when each maneuver goes off:')
        for _, el in ipairs(ELEMENTS) do
            if el ~= 'Dark' then
                local v = config.stat_check[el]
                say(('  %-8s %-4s %s'):format(el, statName(el),
                    (type(v) == 'number') and tostring(v)
                    or (type(v) == 'string') and (v .. ' - forced in cw/config.lua')
                    or 'read from your gear'))
            end
        end
        say('/cw stat <element> <number|now|off> - `now` takes what you are wearing')
        return
    end

    local el = nil
    for _, e in ipairs(ELEMENTS) do if e:lower() == which:lower() then el = e end end
    if el == nil then
        oops(('"%s" is not an element - fire, ice, wind, earth, thunder, water or light')
             :format(tostring(which)))
        return
    elseif el == 'Dark' then
        oops('Dark compares MP, which is read live and needs no setting')
        return
    end

    local v = value and value:lower() or nil
    local took = nil
    if v == nil then
        oops(('/cw stat %s <number|now|off>'):format(el:lower()))
        return
    elseif v == 'off' or v == 'clear' or v == 'none' then
        config.stat_check[el] = nil
    elseif v == 'now' then
        -- The live read, deliberately not the setting: this is the one call
        -- that must see what memory holds rather than what you have told us.
        local n = myStat(el)
        if n == nil or n <= 0 then
            oops(('your %s could not be read'):format(statName(el)))
            return
        end
        config.stat_check[el], took = n, n
    else
        local n = tonumber(v:match('%d+') or '')
        if n == nil or n < 1 or n > 999 then
            oops(('"%s" is not a stat between 1 and 999'):format(tostring(value)))
            return
        end
        config.stat_check[el] = math.floor(n)
    end

    applyStatCheck(el)
    tm.saveSettings()
    local set = config.stat_check[el]
    if set == nil then
        say(('%s: back to reading your %s off your gear'):format(el, statName(el)))
        return
    end
    local c, _, theirs = computeCost(el)
    say(('%s: your %s is %d%s'):format(el, statName(el), set,
        (theirs ~= nil and c ~= nil)
        and (', the automaton has %d - a maneuver costs %d'):format(theirs, c)
        or ' - no automaton data yet'))
    if took ~= nil then
        say('  taken from memory - open the equipment menu while wearing the set if that looks wrong')
    end
end

-- ============================================================== commands =
local function onCommand(e)
    local args = e.command:args()
    if #args == 0 then return end
    local c = args[1]:lower()
    if c ~= '/clockwork' and c ~= '/cw' then return end
    e.blocked = true
    -- The bare command says what it can do, rather than printing state the
    -- panel already shows.
    local sub = args[2] and args[2]:lower() or 'help'

    if sub == 'attachments' or sub == 'owned' then
        if tm.auto044 == nil then
            print(chat.header('clockwork'):append(chat.error(
                'no automaton data yet - zone or summon the automaton, then retry.')))
            return
        end
        local owned = ownedAttachments()
        -- sanity gate: everything currently equipped must appear in the
        -- 0x044's owned bitmask
        local eq, missing = equippedNames(), 0
        for i = 3, 14 do
            if eq[i] ~= nil and eq[i] ~= '' then
                local found = false
                for _, o in ipairs(owned) do if o == eq[i] then found = true break end end
                if not found then missing = missing + 1 end
            end
        end
        if missing > 0 then
            print(chat.header('clockwork'):append(chat.error(
                ('%d equipped attachments are missing from the owned list - the automaton data may be out of date')
                :format(missing))))
        end
        if #owned == 0 then
            print(chat.header('clockwork'):append(chat.message(
                'the last automaton update reported no owned attachments.')))
        else
            print(chat.header('clockwork'):append(chat.message(('you own %d attachments:'):format(#owned))))
            for _, n in ipairs(owned) do
                print(chat.header('clockwork'):append(chat.success('  ' .. n)))
            end
        end

    elseif sub == 'equipped' then
        local eq = equippedNames()
        print(chat.header('clockwork'):append(chat.message(('Head: %s'):format(eq[1] or '-'))))
        print(chat.header('clockwork'):append(chat.message(('Frame: %s'):format(eq[2] or '-'))))
        for i = 3, 14 do
            if eq[i] ~= nil and eq[i] ~= '' then
                print(chat.header('clockwork'):append(chat.success('  ' .. eq[i])))
            end
        end

    elseif sub == 'demo' then
        -- One key that walks the list and then turns itself off, rather than a
        -- subcommand per automaton. Deliberately not saved: demo state that
        -- survived a reload would be indistinguishable from a broken addon, and
        -- every number on the panel would be a lie you had to remember was one.
        if tm.demo == nil and tm.ids.pet_id ~= 0 then
            -- enable() writes the scenario over the live burden, recasts,
            -- target and effects and disable() zeroes them: nothing brings
            -- back what the server still holds for a real automaton.
            print(chat.header('clockwork'):append(chat.message(
                'demo needs no pet out - it would overwrite the automaton\'s burden, recasts and target')))
        else
            local name, n = DEMO.cycle()
            if name == nil then
                print(chat.header('clockwork'):append(chat.message(
                    'demo off - back to the real automaton')))
            else
                print(chat.header('clockwork'):append(chat.message(
                    ('demo %d/%d - %s. Nothing here is measured; /cw demo again for the next one')
                    :format(tm.demo.which, n, name))))
            end
        end

    elseif sub == 'stat' then
        statCommand(args[3], args[4])

    elseif sub == 'compact' then
        config.compact = not config.compact
        tm.saveSettings()
        print(chat.header('clockwork'):append(chat.message(
            'compact ' .. tostring(config.compact) .. ' - the one-line layout')))

    elseif sub == 'reset' then
        resetModel(nil)
        tm.dropLearnedCosts(true)
        for _, el in ipairs(ELEMENTS) do applyStatCheck(el) end
        tm.clear(samples) tm.anomalies = 0
        tm.casts, tm.missed = 0, 0
        print(chat.header('clockwork'):append(chat.message('burden, samples, spell counters and anomaly count cleared')))

    elseif sub == 'sync' then
        resetModel('manual')
        print(chat.header('clockwork'):append(chat.message(
            'burden zeroed - manual resync only; an Activate seeds activate_burden on its own')))

    elseif sub == 'show' or sub == 'window' then
        config.show_window = not config.show_window
        tm.saveSettings()
        print(chat.header('clockwork'):append(chat.message(
            'panel ' .. tostring(config.show_window)
            .. ' - the model and the log run either way')))

    else
        -- Plain switches the Settings tab owns - logging, verbose, sidebar,
        -- predictions, size - have no command. Two ways to set one thing is one
        -- way for them to disagree, and the tab is the one that writes the file
        -- and shows the current value. What is here either shows you something,
        -- changes a mode, or is destructive.
        local function say(line) print(chat.header('clockwork'):append(chat.message(line))) end
        say('/cw - what the automaton is doing')
        say('  show - the panel on or off')
        say('  compact - the one-line strip')
        say('  demo - made-up automatons, for looking at the HUD off PUP;')
        say('    each /cw demo is the next one, then off again')
        say('  attachments - the attachments you own')
        say('  equipped - head, frame and attachments')
        say('  stat - the stat you wear for each maneuver, which a gear swap')
        say('    hides from the client: /cw stat wind 83, or now, or off')
        say('  reset - clear burden, costs and counters')
        say('  sync - burden to zero')
        say('Everything else is on the Settings tab: logging, the sidebar,')
        say('the prediction chat lines and how big the HUD draws.')
    end
end

return { onCommand = onCommand }
