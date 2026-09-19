-- ---------------------------------------------------------- load the addon --
-- The one global the addon looks for: when it exists, cw/log.lua leaves each
-- log event's kind and record in CLOCKWORK_TEST.last for the suites to read.
CLOCKWORK_TEST = {}

local _   -- the throwaway target in the suite's multi-assignments

-- STRICT GLOBALS. Every global the addon may read is defined above this line:
-- the stubs, the ImGui enums, CLOCKWORK_TEST. From here on an undefined global
-- is an error, not nil - a module that forgot a require, or a name that stayed
-- behind in another file, fails at its first read instead of drawing nothing.
-- A global WRITE is an error too: `function name()` without a forward-declared
-- local, or a dropped `local`, fails here instead of leaking into _G.
-- The harness's own later globals go through rawset.
setmetatable(_G, {
    __index    = function(_, k) error('undefined global read: ' .. tostring(k), 2) end,
    __newindex = function(_, k) error('global write: ' .. tostring(k), 2) end,
})
local chunk = assert(loadfile(ADDON_DIR .. '/clockwork.lua'))
chunk()
-- The api the suites reach the addon's internals through, built from the
-- loaded modules: require hands back the instances the addon itself loaded.
local api = (function()
    local config = require('cw.config')
    local D      = require('cw.data')
    local tm     = require('cw.state')
    local L      = require('cw.log')
    local R      = require('cw.reading')
    local A      = require('cw.attachments')
    local B      = require('cw.burden')
    local T      = require('cw.timers')
    local P      = require('cw.pet')
    local S      = require('cw.sets')
    local IN     = require('cw.inbound')
    local SF     = require('cw.ui.surface')
    local LO     = require('cw.ui.loadout')
    local PN     = require('cw.ui.panel')
    return {
        state = function() return { auto044 = tm.auto044, seq = tm.auto044Seq, apply = tm.applyState } end,
        serializeSet = S.serializeSet, parseSetFile = S.parseSetFile, validSetName = S.validSetName,
        listSets = S.listSets, setExists = S.setExists, loadSet = S.loadSet,
        saveSet = S.saveSet, deleteSet = S.deleteSet, renameSet = S.renameSet,
        elementCaps = S.elementCaps, itemIds = S.itemIds, capacityOf = S.capacityOf,
        attachEffect = A.attachEffect,
        unownedIn = S.unownedIn,
        equippedSet = S.equippedSet, buffSummary = A.buffSummary, liveSet = S.liveSet,
        planApply = S.planApply,
        startApply = S.startApply,
        refreshSets = LO.refreshSets, selectSet = LO.selectSet,
        resetIcons = SF.resetIcons,
        unpackAction = IN.unpackAction,
        -- what a recast cell's icon is a picture of: the effect the ability
        -- lands, the item standing in for it, or the attachment that granted it
        abilityArt = function(row) local _, of = SF.abilityArt(row) return of end,
        demoOn = function() return tm.demo ~= nil end,
        demoName = function() return tm.demo and tm.demo.name end,
        demoMob = function() return tm.demo and tm.demo.mob end,
        petInfo = function() return R.petInfo() end,
        currentFrame = function() return tm.frameNow() end,
        activeManeuvers = function() return B.activeManeuvers() end,
        maneuverCounts = function() return B.maneuverCounts() end,
        -- the skillchain former and the two property tables it is fed from,
        -- so a fixture chains real weaponskills rather than bare numbers
        formSkillchain = function(closer, opener) return B.formSkillchain(closer, opener) end,
        scName = function(v) return D.SC_NAME[v] end,
        scProps = function(kind, id) return (kind == 'ws') and D.WS_SC[id] or D.MOBSKILL_SC[id] end,
        timerRows = function() return tm.timerRows() end,
        timersClear = function(edge, src) T.timersClear(edge, src) end,
        currentHead = function() return tm.currentHead() end,
        spellName = function(id) return tm.spellName(id) end,
        canCast = function(id) return tm.fn.canCast(id) end,
        spellWindows = function() return tm.fn.windows end,
        spellRow = function(id) return tm.fn.row(id) end,
        erasable = function(id) return tm.fn.erasable[id] == true end,
        dispelable = function(id) return tm.fn.dispelable[id] == true end,
        windowLeft = function(rung) return tm.fn.windowLeft(rung, tm.currentHead(), B.maneuverCounts()) end,
        spellRecastLeft = function(id) return tm.fn.spellRecastLeft(id) end,
        targetHas = function(id) return tm.fn.targetHas(id) end,
        -- the LIVE effects on petTarget, as the ladder sees them: [effect] = at
        targetEffects = function()
            local out, mob = {}, tm.mobs[tm.petTarget]
            for id, f in pairs(mob and mob.fx or {}) do
                if tm.fn.targetHas(id) then out[id] = f.at end
            end
            return out
        end,
        -- ...and their clocks: [effect] = ends (nil = the flat backstop)
        targetUntil = function()
            local out, mob = {}, tm.mobs[tm.petTarget]
            for id, f in pairs(mob and mob.fx or {}) do
                if tm.fn.targetHas(id) then out[id] = f.ends end
            end
            return out
        end,
        mobs = function() return tm.mobs end,
        petKnown = function() return tm.petKnown end,
        seenDur = function() return tm.seenDur end,
        regenAt = function() return tm.regenAt end,
        partyBuffs = function() return tm.partyBuffs end,
        petTarget = function() return tm.petTarget end,
        deployTo = function() return tm.deployTo end,
        setPetTarget = function(v) tm.petTarget = v end,
        predictSpell = function() return tm.predictSpell() end,
        -- the PUBLISHED snapshot, which is what the packet thread judges a
        -- cast against - not the same thing as calling predictSpell again
        spellSnapshot = function() return tm.spell end,
        -- the MP interval the ladder worked from: low, high
        petMp = function() return tm.mp, tm.mpHi end,
        -- the what-if sidebar
        whatIf = function(counts, maneuvers, el) return tm.whatIf(counts, maneuvers, el) end,
        sidebarRows = function() tm.sidebarInvalidate() return tm.sidebarRows() end,
        sideDrop = function() tm.sidebarInvalidate() tm.sidebarRows() return tm.sideDrop end,
        -- a hypothetical prediction, straight at tm.predictSpell: it must answer
        -- without publishing tm.windows, which the packet thread reads
        predictSpellSim = function(counts) return tm.predictSpell(counts) end,
        spellWindowsSim = function(counts)
            return tm.fn.windowSummary(tm.currentHead(), counts)
        end,
        predictWS = function(frame, counts) return B.predictWS(frame, counts) end,
        spellWindowsNow = function() return tm.windows end,
        fit = function(text, width) return tm.fit(text, width) end,
        spellCountersReset = function() tm.casts, tm.missed = 0, 0 end,
        -- the state after a reload; a new sequence too, or equippedNames()
        -- keeps its cache of the packet just forgotten for two seconds
        clear044 = function() tm.auto044, tm.auto044Seq = nil, tm.auto044Seq + 1 end,
        -- ...and the other half of it: a pet already out, nothing known
        -- about its buffs, which is where petKnown starts on every load
        forgetPet = function()
            tm.clear(P.petEffects) tm.petKnown, tm.petUntil, tm.petDiaBio = {}, {}, {}
        end,
        petLive = function(id) return tm.petLive(id, os.clock()) end,
        petUntil = function() return tm.petUntil end,
        petStrip = function() return tm.petStrip(os.clock()) end,
        mobskillEffect = function(id) return tm.mobskillEffect[id] end,
        -- the settings file
        saveSettings = function() return tm.saveSettings() end,
        saveCount = function() return tm.saveCount end,
        loadSettings = function() return tm.loadSettings() end,
        settingsPath = function() return tm.settingsPath() end,
        logPath = function() return L.logPath() end, setsDir = function() return S.setsDir() end,
        restoreDefaults = function() tm.restoreDefaults() end,
        -- the burden model
        SHADOW = tm.SHADOW, font = function() return tm.font end,
        tab = function() return tm.tab end, selectTab = function(t) tm.tab = t end,
        cog = function(x, y, r, c) return tm.cog(x, y, r, c) end,
        tuneTab = function() return tm.tuneTab end,
        selectTuneTab = function(t) tm.tuneTab = t end,
        sideColumn = function(lines, buffs) return tm.sideColumn(lines, buffs) end,
        fontLoad = function() return tm.fontLoad() end, px = function(k) return tm.px(k) end,
        -- the scaling primitives: px is a font BASE, s is a drawn pixel
        s = function(n) return tm.s(n) end, dpx = function(k) return tm.dpx(k) end,
        -- how many times a native read failed and was silently defaulted
        swallowed = function() return tm.swallowed end,
        resetSwallowed = function() tm.swallowed = 0 end,
        config = config, reconcile = B.reconcile, decayRate = B.decayRate,
        computeCost = function(el, mine) return B.computeCost(el, mine) end,
        model = function()
            return { burden = tm.burden, cost = tm.cost, costSource = tm.costSource,
                     costDispute = tm.costDispute, waterSince = tm.waterSince,
                     verified = tm.burdenVerified, seededBy = tm.seededBy }
        end,
        -- the two big closures' upvalue counts, for the harness's ceiling
        -- checks: debug.getinfo on the module functions, because the
        -- registered handlers are one-line wrappers.
        nups = function()
            return { draw = debug.getinfo(PN.draw, 'u').nups,
                     onPacket = debug.getinfo(IN.onPacket, 'u').nups }
        end,
    }
end)()
shadowCol = api.SHADOW   -- the shadow pass is not a drawn string
api.selectTab('all')   -- the harness draws every tab each frame, as the ImGui stub always did
check('registered packet_in', handlers['packet_in'] ~= nil, true)
check('registered d3d_present', handlers['d3d_present'] ~= nil, true)
check('registered load', handlers['load'] ~= nil, true)
check('test api built', api ~= nil, true)

-- As shipped, nothing is written to disk or printed to chat until the player
-- turns it on. The suite was written against all four on, and reads the log
-- to see what the model did, so it turns them on here.
check('logging ships off', api.config.logging, false)
check('anomaly_file ships off', api.config.anomaly_file, false)
check('anomaly_chat ships off', api.config.anomaly_chat, false)
check('debug_predictions ships off', api.config.debug_predictions, false)
local function suiteLogging()
    local c = api.config
    c.logging, c.anomaly_file, c.anomaly_chat, c.debug_predictions = true, true, true, true
end
suiteLogging()
