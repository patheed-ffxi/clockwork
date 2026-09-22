addon.name    = 'clockwork'
addon.author  = 'Pathead'
addon.version = '1.18.0'
addon.desc    = 'Puppetmaster burden, maneuvers, weaponskill prediction, loadout and anomaly logging.'

require('common')
local chat  = require('chat')

-- The modules, in dependency order: each requires only modules above it,
-- which keeps the graph acyclic. The shared state is cw/state.lua (`tm`). A
-- function a module publishes on tm is looked up at call time, which is how a
-- module calls one defined below it (tm.saveSettings, tm.sidebarInvalidate).
require('cw.config')
require('cw.data')
local tm     = require('cw.state')
local U      = require('cw.util')
local L      = require('cw.log')
require('cw.reading')
require('cw.attachments')
require('cw.burden')
require('cw.timers')
local P      = require('cw.pet')
require('cw.spell')      -- publishes tm.fn, tm.predictSpell and the rest
require('cw.settings')   -- publishes tm.loadSettings, tm.saveSettings, tm.restoreDefaults
local S      = require('cw.sets')
require('cw.demo')
local IN     = require('cw.inbound')
local C      = require('cw.commands')
local F      = require('cw.frame')
require('cw.ui.surface')
require('cw.ui.whatif')  -- publishes tm.whatIf, tm.sidebarRows and the rest
require('cw.ui.loadout')
local PN     = require('cw.ui.panel')

ashita.events.register('packet_in', 'clockwork_packet', IN.onPacket)

ashita.events.register('d3d_present', 'clockwork_present', function()
    if F.tick() then PN.draw() end
end)

ashita.events.register('command', 'clockwork_cmd', C.onCommand)

ashita.events.register('load', 'clockwork_load', function()
    P.resolveIds()
    -- BEFORE logOpen: `logging` and `anomaly_file` decide whether a file is
    -- opened at all, and the saved values are the ones that should decide it.
    tm.loadSettings()
    tm.fontLoad()
    L.logOpen()
    U.safe(function() ashita.fs.create_directory(S.setsDir()) end)
    -- Burden starts at zero and unverified, so the first maneuver of each
    -- element after a (re)load is a reseed, not an anomaly. Mark the edge in
    -- the log.
    L.logEvent('load', { version = addon.version, pet = (tm.ids.pet_id ~= 0) })
    print(chat.header('clockwork'):append(chat.message(
        'loaded. /cw show - /cw attachments - packet driven, ServerId filtered.')))
end)

ashita.events.register('unload', 'clockwork_unload', function()
    L.close()
end)
