-- cw/ui/whatif.lua - the what-if sidebar: what using each maneuver right now
-- would change about the automaton, and the rows that say it. Exports nothing;
-- publishes tm.whatIf, tm.sidebarRows, tm.sidebarInvalidate, tm.sidebarCells,
-- tm.rescaleSide and tm.SIDE_W, and writes tm.sideWs and tm.sideDrop.
local imgui = require('imgui')
local config = require('cw.config')
local D  = require('cw.data')
local ELEMENTS = D.ELEMENTS
local tm = require('cw.state')
local A  = require('cw.attachments')
local attachMods, fmtMod, buffSummary = A.attachMods, A.fmtMod, A.buffSummary
local R  = require('cw.reading')
local hasAttachment, equippedAttachments = R.hasAttachment, R.equippedAttachments
local B  = require('cw.burden')
local predict, overloadDuration, activeManeuvers, maneuverCounts = B.predict, B.overloadDuration, B.activeManeuvers, B.maneuverCounts
local decayRate, predictWS = B.decayRate, B.predictWS
local SF = require('cw.ui.surface')
local COL_GOOD, COL_WARN, COL_BAD, COL_DIM = SF.COL_GOOD, SF.COL_WARN, SF.COL_BAD, SF.COL_DIM
local COL_TEXT, tip = SF.COL_TEXT, SF.tip

-- ======================================================= what-if sidebar ==
-- What using each maneuver right now would CHANGE about the automaton. Every
-- answer comes from the same predictors the panel already runs, handed a
-- different maneuver-count vector - there is no second model here.

-- LSB automaton.lua - a fourth maneuver evicts the
-- OLDEST, it does not fail. activeManeuvers() already sorts by remaining
-- ascending, so entry 1 is the one that dies. Returns the hypothetical
-- counts and the element evicted (nil when there is room).
tm.whatIf = function(counts, maneuvers, el)
    local c = {}
    for _, e in ipairs(ELEMENTS) do c[e] = counts[e] or 0 end
    local evicted = nil
    if #maneuvers >= 3 then
        evicted = maneuvers[1].element
        c[evicted] = math.max(0, c[evicted] - 1)
    end
    c[el] = c[el] + 1
    return c, evicted
end

-- Damage Gauge's 'Cure at HP' value under a maneuver-count vector: what
-- gather() adds to tryHeal's threshold. Shared by the clone and the sidebar's
-- own 'heal at' line, so the two cannot disagree about the same Gauge.
local function gaugeFor(counts)
    if not hasAttachment('Damage Gauge') then return 0 end
    local _, _, mods = attachMods('Damage Gauge', counts)
    return (mods[1] and mods[1][3]) or 0
end

-- The two mods gather() derives from the maneuver count. Everything else in
-- the context - the party, the master's and the mob's HP, the status icons,
-- the entity scan - is live state a hypothetical maneuver cannot move, so
-- the clone keeps it and gather is paid for once a frame instead of eight
-- times. That is what makes eight predictions a frame affordable at all.
local function cloneCtx(base, counts)
    local c = {}
    for k, v in pairs(base) do c[k] = v end
    c.counts  = counts
    c.scanner = hasAttachment('Scanner') and (counts.Ice or 0) > 0
    c.gauge   = gaugeFor(counts)
    return c
end

-- Modifiers where a NEGATIVE value is the good outcome, so a delta cannot be
-- coloured by its sign. PDT is the damage the automaton TAKES; every other
-- label in ATTACH_MODS is a thing you want more of, including the '-s' and
-- '-cs' delays, whose stored value is the size of the reduction.
local LOWER_IS_BETTER = { PDT = true }

-- One buffSummary difference, turned into coloured signal lines.
local function deltaSignals(names, counts, baseCounts)
    local out = {}
    for _, m in ipairs(buffSummary(names, counts, baseCounts)) do
        -- 'Burden decay' is Heatsink, and the decay signal states it as a
        -- RATE ('decay 1 -> 2/tick') under the same Heatsink gate. Two lines
        -- for one fact, and the delta form is the weaker of the two.
        if m[1] ~= 'Burden decay' then
            -- Sign is not polarity: PDT is damage TAKEN, so Armor Plate's
            -- -10% is a 10% reduction, and colouring by sign alone would
            -- paint the best attachment on the automaton red.
            local good = LOWER_IS_BETTER[m[1]] and (m[3] < 0) or
                         (not LOWER_IS_BETTER[m[1]] and m[3] > 0)
            out[#out + 1] = { good and COL_GOOD or COL_BAD,
                              fmtMod(m) .. (m[4] and '*' or '') }
        end
    end
    return out
end

-- LSB tryHeal's threshold ladder by Light count (automaton_controller.cpp),
-- plus the Damage Gauge and the [30, 90] clamp, exactly as tryHeal computes
-- it; mirrored here only to SAY when a Light maneuver would move it. tryHeal
-- itself stays the authority - this never feeds a prediction. The bare ladder
-- alone would say 'heal at 40%' on an automaton the server heals at 80.
local HEAL_THR = { [0] = 30, 40, 50, 75 }
local function healThr(counts)
    return math.min(90, math.max(30, HEAL_THR[math.min(counts.Light or 0, 3)] + gaugeFor(counts)))
end

-- The signals, in priority order. Each returns a string or nil. `a` is the
-- baseline reading, `b` the hypothetical; both are built once per element.
-- `can` says which of the automaton's behaviours are reachable AT ALL with
-- the head and frame it is wearing. Without it the sidebar would promise things
-- a Valoredge cannot do: 'heal at 40%' on a frame whose ladder has no heal
-- rung - whose ladder is never even entered - is not a change, it is noise.
local function signals(a, b, el, counts, c2, can)
    local out = {}
    if b.ws ~= a.ws and b.ws ~= nil then
        out[#out + 1] = { COL_GOOD, 'WS -> ' .. b.ws }
    end
    if b.spell ~= a.spell and b.spell ~= nil then
        out[#out + 1] = { COL_GOOD, 'Spell -> ' .. b.spell }
    end
    -- Scanner's effect is AUTO_SCAN_RESISTS, which only tryElemental reads
    -- and only on a Spiritreaver: on any other head it arms nothing.
    if el == 'Ice' and can.scan and hasAttachment('Scanner') and (counts.Ice or 0) == 0 then
        out[#out + 1] = { COL_TEXT, 'Scanner arms' }
    end
    if el == 'Earth' and hasAttachment('Shock Absorber') and (counts.Earth or 0) == 0 then
        out[#out + 1] = { COL_TEXT, 'Stoneskin wakes' }
    end
    -- Water only: it is the one element whose own arrival moves the rate.
    -- Any OTHER element that changes it did so by evicting a Water maneuver
    -- - which every element does equally, since they all drop the same
    -- oldest one - so as a per-row headline it would be the same sentence eight
    -- times over, crowding out what each element actually does. That case is
    -- said once, on the eviction line at the head of the sidebar.
    if el == 'Water' then
        local rNow, rNew = decayRate(counts), decayRate(c2)
        if rNew ~= rNow then
            out[#out + 1] = { COL_TEXT, ('decay %d -> %d/tick'):format(rNow, rNew) }
        end
    end
    if el == 'Light' and can.heal then
        local nowT, newT = healThr(counts), healThr(c2)
        if newT ~= nowT then
            out[#out + 1] = { COL_TEXT, ('heal at %d%%'):format(newT) }
        end
    end
    if el == 'Fire' and hasAttachment('Flame Holder') then
        out[#out + 1] = { COL_WARN, 'the WS will eat it' }
    end
    return out
end

-- Eight rows, one per element, in ELEMENTS order. Throttled: the answer does
-- not change at 60 Hz, and gather() walks the party, 32 status icons and -
-- when its cache misses - 1024 entity slots.
local rowsCache, rowsAt = nil, 0
tm.sidebarRows = function()
    if rowsCache ~= nil and os.clock() - rowsAt < 0.25 then return rowsCache end
    local counts, maneuvers = maneuverCounts(), activeManeuvers()
    local frame, head = tm.frameNow(), tm.currentHead()
    local base = (head ~= nil) and tm.fn.gather(head, counts) or nil
    local attachments = equippedAttachments()
    -- What this head and frame can actually do. Only a Harlequin-family
    -- frame ever enters the spell ladder (predictSpell's own first gate),
    -- and within it a head only reaches a rung its cooldown table lists -
    -- Spiritreaver has no heal rung at all.
    local w   = (head ~= nil) and tm.fn.windows[head] or nil
    local can = { heal = (frame == 'Harlequin') and w ~= nil and w.heal ~= nil,
                  scan = (frame == 'Harlequin') and head == 6 }
    -- The baseline both hypotheticals are read against. predictWS with no
    -- counts is the live call; passing counts explicitly makes the pair
    -- symmetrical, which is what lets a difference mean "the maneuver did
    -- this" rather than "the frame moved under us".
    local aWs, _, aMode = nil, nil, nil
    if frame ~= nil then aWs, _, aMode = predictWS(frame, counts) end
    -- The branch predictWS took for the BASELINE. 'chain' and 'hold' both
    -- ignore maneuvers entirely, so no element can move the weaponskill and
    -- every row is silent about it - which reads as "nothing to say" unless
    -- the sidebar says why. Kept off the rows and drawn once at the head.
    tm.sideWs = aMode
    local a = {
        ws    = aWs,
        spell = base and (tm.predictSpell(counts, cloneCtx(base, counts))) or nil,
    }
    -- The board AFTER the drop but BEFORE the new maneuver. At three up
    -- every element evicts the same oldest one, so that half of the change
    -- is identical on all eight rows - left in each row it would print, say,
    -- 'Refresh -6' and 'Conserve MP -15%' eight times over, burying what each
    -- element actually buys. Splitting the difference in two at this line is exact:
    -- buffSummary sums per label, so shared + per-element is the whole of it.
    local dropped, afterEvict = nil, counts
    if #maneuvers >= 3 then
        dropped, afterEvict = maneuvers[1].element, {}
        for _, e in ipairs(ELEMENTS) do afterEvict[e] = counts[e] or 0 end
        afterEvict[dropped] = math.max(0, afterEvict[dropped] - 1)
    end
    tm.sideDrop = dropped and
        { el = dropped, lost = deltaSignals(attachments, afterEvict, counts),
          decayFrom = decayRate(counts), decayTo = decayRate(afterEvict) } or nil

    local rows = {}
    for _, el in ipairs(ELEMENTS) do
        local c2, evicted = tm.whatIf(counts, maneuvers, el)
        local b = {
            ws    = frame and (predictWS(frame, c2)) or nil,
            spell = base and (tm.predictSpell(c2, cloneCtx(base, c2))) or nil,
        }
        local sig = signals(a, b, el, counts, c2, can)
        if el == dropped then
            -- Using again the element that is about to be evicted: the count
            -- comes back to where it started, so nothing about the automaton
            -- moves. Saying that is worth more than eight zeroes, and it is
            -- the one row the shared loss above does NOT apply to.
            sig[#sig + 1] = { COL_TEXT, 'refreshes it - no other change' }
        else
            -- Measured from afterEvict, not from the live counts: what THIS
            -- element buys, with the shared loss already taken out.
            for _, g in ipairs(deltaSignals(attachments, c2, afterEvict)) do
                sig[#sig + 1] = g
            end
        end
        local chance = predict(el)
        -- The eviction's own effect on the decay rate, kept off the row's
        -- headline (see signals) but still worth saying once.
        local rNow, rNew = decayRate(counts), decayRate(c2)
        -- The row for the element being evicted refreshes it: the count nets
        -- to no change, and its own tooltip must not go on to say 'drops your
        -- <el>' under the 'no other change' line it just printed.
        rows[#rows + 1] = { el = el, sig = sig, evicted = (evicted ~= el) and evicted or nil,
                            decayFrom = rNow, decayTo = rNew,
                            chance = chance, dur = overloadDuration(el) }
    end
    rowsCache, rowsAt = rows, os.clock()
    return rows
end

tm.sidebarInvalidate = function() rowsCache = nil end

-- The what-if sidebar. A FIXED width - the HUD is AlwaysAutoResize, so a column
-- that sized itself from the window would ratchet the panel wider every frame.
-- SIG_X is where the signals start, PCT_W what the percentage column reserves on
-- the right, SIG_GAP the spacing between signals packed onto one line.
-- SIDE_W is set by the longest headline the model can produce: 'Spell -> ' plus
-- the longest automaton spell name is ~21 characters, and that has to clear the
-- percentage on the row it shares. Everything past the headline goes on
-- continuation lines, which have the full width and are never truncated.
-- All four at 100%; tm.rescaleSide rewrites them once a frame from draw(),
-- the same shape the compact strip's constants use.
local BASE_SIDE_W = 252
tm.SIDE_W = 252
local SIG_X, PCT_W, SIG_GAP = 28, 34, 10   -- gem, then the signals
tm.rescaleSide = function()
    tm.SIDE_W = tm.s(BASE_SIDE_W)
    SIG_X, PCT_W, SIG_GAP = tm.s(28), tm.s(34), tm.s(10)
end
-- A run of coloured signals packed onto as many lines as they need, each new
-- line starting at `indent`. Shared by the eviction block and by a row's
-- continuation lines, which are the same shape.
local function sigStrip(sig, from, indent, avail)
    local x = 0
    for i = from, #sig do
        local g = sig[i]
        local w = imgui.CalcTextSize(g[2]) + SIG_GAP
        if x == 0 or x + w > avail then
            tm.text('text', COL_TEXT, '')                  -- open a line with a blank left column
            imgui.SameLine(indent, 0)
            x = w
        else
            imgui.SameLine(0, SIG_GAP)
            x = x + w
        end
        tm.text('text', g[1], tm.fit(g[2], avail))
    end
end

tm.sidebarCells = function()
    tm.text('label', COL_DIM, 'if you use')
    tip('What each maneuver would change if you use it now. With three\nalready up a value can be negative: the oldest is dropped to make\nroom, and that loss is counted in.')
    -- Its own close, since the window has no title bar to put one in. The
    -- header's ? button reopens it. Saved, like the ? button's toggle: a
    -- sidebar closed here must not come back on the next load.
    imgui.SameLine(tm.SIDE_W - tm.s(20), 0)
    if imgui.SmallButton('x##cw_sideclose') then
        config.sidebar = false
        tm.sidebarInvalidate()
        tm.saveSettings()
    end
    tip('Close. Reopen with the ? button.')
    -- Rows first: it is what refreshes tm.sideWs, which the head line reads.
    local rows = tm.sidebarRows()
    -- Said once, at the head, rather than eight times in the rows: neither
    -- branch looks at maneuvers, so no maneuver changes what they answer.
    -- tm.sideWs, not tm.spell.mode: 'chain' and 'hold' are predictWS's modes,
    -- and the spell's (none/closed/maneuver/uncertain) never carry either.
    if tm.sideWs == 'chain' then
        tm.text('text', COL_DIM, tm.fit('a chain is open - it picks the WS, not your maneuvers',
                                          tm.SIDE_W - tm.s(4)))
        tip('A chain is open, so the weaponskill is already decided. No maneuver\nbelow can change it.')
    elseif tm.sideWs == 'hold' then
        tm.text('text', COL_DIM, tm.fit('holding TP - no maneuver moves the WS',
                                          tm.SIDE_W - tm.s(4)))
        tip('Inhibitor is holding the automaton\'s TP until you open a chain.\nUntil then no weaponskill is being chosen.')
    end
    -- Everything the eviction costs, in ONE block. At three maneuvers up every
    -- element drops the same oldest one, so this half of the answer is the
    -- same for all eight rows and is said once here (see tm.sidebarRows).
    local drop = tm.sideDrop
    if drop ~= nil then
        local txt = ('any maneuver drops your %s'):format(drop.el)
        if drop.decayTo ~= drop.decayFrom then
            txt = ('%s - decay %d -> %d/tick'):format(txt, drop.decayFrom, drop.decayTo)
        end
        tm.text('text', COL_WARN, tm.fit(txt, tm.SIDE_W - tm.s(4)))
        tip('Three maneuvers are up, so a fourth drops the oldest. What that\n' ..
            'costs is listed here; each row below shows only what its own\n' ..
            'element adds on top.')
        sigStrip(drop.lost, 1, SIG_X, tm.SIDE_W - SIG_X - tm.s(4))
        imgui.Separator()
    end
    for _, r in ipairs(rows) do
        -- The whole answer, built first so both hover targets carry it: tip()
        -- reads IsItemHovered, so it has to follow each item it describes.
        local lines = {}
        for _, g in ipairs(r.sig) do lines[#lines + 1] = g[2] end
        if r.evicted ~= nil then
            lines[#lines + 1] = ('drops your %s - three are already up'):format(r.evicted)
        end
        if r.chance > 0 then
            -- LSB onUseManeuver overloads with removeAllManeuvers(): the cost of
            -- a miss is the whole board, not this element.
            lines[#lines + 1] = ('%d%% overload - every maneuver, for %ds'):format(r.chance, r.dur)
        end
        local hover = (#lines > 0) and table.concat(lines, '\n')
                      or 'Nothing would change.'
        tm.gem(r.el, tm.dpx('text'))
        tip(r.el .. '\n' .. hover)
        imgui.SameLine(SIG_X, 0)
        if #r.sig == 0 then
            tm.text('text', COL_DIM, '-')
        else
            -- The headline shares this line with the percentage, so it is the
            -- one thing that still has to fit: SameLine(x) sets the cursor
            -- absolutely, and an overrun is overprinted rather than pushed
            -- aside. SIDE_W is set so a full 'Spell -> <name>' clears it.
            tm.text('text', r.sig[1][1],
                              tm.fit(r.sig[1][2], tm.SIDE_W - PCT_W - SIG_X - tm.s(6)))
        end
        tip(hover)
        imgui.SameLine(tm.SIDE_W - PCT_W, 0)
        local col = COL_GOOD
        if r.chance >= config.warn_at then col = COL_BAD
        elseif r.chance > 0 then col = COL_WARN end
        tm.text('text', col, ('%d%%'):format(r.chance))
        tip(('A %s maneuver now: %d%% chance to overload, which strips EVERY\nmaneuver for %ds.')
            :format(r.el, r.chance, r.dur))
        -- Everything else this element would change, on continuation lines under
        -- the headline. Nothing shares these lines, so they get the full width
        -- and nothing is truncated or hidden behind a hover. A row with one
        -- thing to say is still one line; only a row with more grows.
        if #r.sig > 1 then
            sigStrip(r.sig, 2, SIG_X, tm.SIDE_W - SIG_X - tm.s(4))
        end
    end
end

return {}
