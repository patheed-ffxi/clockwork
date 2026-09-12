-- Offline harness for clockwork. test/run_tests.py joins this file, the other
-- fixtures and the suites into one chunk, in the order its FILES list gives:
-- the fixtures stub the Ashita environment and load the addon, and the suites
-- reach its internals through `api` (fixtures/load.lua). Never in the game.

local ADDON_DIR, SCRATCH = ...
package.path = ADDON_DIR .. '/?.lua;' .. package.path

local failures, checks = {}, 0
local function check(name, got, want)
    checks = checks + 1
    if got ~= want then
        failures[#failures + 1] = ('%s: got %s, want %s'):format(name, tostring(got), tostring(want))
    end
end

-- ------------------------------------------------------------ fake world --
-- Everything the stubs answer from. Tests mutate this directly.
local world = {
    mainjob = 18, subjob = 0,
    -- the level the maneuver's stat grant is read off: 1 + level / 15, so 75
    -- is the +6 every derived row in MANEUVER_GAIN is exact at
    mainlvl = 75, sublvl = 37,
    petIndex = 0, petId = 0,
    -- the PUP memory buffer's 14 slot bytes: head, frame, 12 attachments
    buffer = { 2, 33, 5, 4, 1, 2, 3, 0, 0, 0, 0, 0, 0, 0 },
    equipCalls = {},     -- every equip-function call: { isSub, job, index, id }
    equipRc = nil,       -- what the equip stub returns; nil means 1 (accepted)
    answered = 0,        -- how many of equipCalls the fake server has answered
    task = nil,          -- the coroutine ashita.tasks.once was handed
}

-- Item names the resource manager answers with. Heads and frames use the live
-- client's short names (VE_tank.txt, written by pupsets from this same call).
-- Attachment ids 1-7 and 98 are the real item_puppet rows; the rest are fixture
-- ids - the addon never hardcodes attachment ids, it asks the resource manager.
local ITEMS = {
    [0x2000 + 1]  = 'Harlequin Head',   [0x2000 + 2]  = 'Valoredge Head',
    [0x2000 + 3]  = 'Sharpshot Head',   [0x2000 + 4]  = 'Stormwaker Head',
    [0x2000 + 5]  = 'Soulsoother Head', [0x2000 + 6]  = 'Spiritreaver Head',
    [0x2000 + 32] = 'Harlequin Frame',  [0x2000 + 33] = 'Valoredge Frame',
    [0x2000 + 34] = 'Sharpshot Frame',  [0x2000 + 35] = 'Stormwaker Frame',
    [0x2100 + 1]  = 'Strobe',           [0x2100 + 2]  = 'Tension Spring',
    [0x2100 + 3]  = 'Inhibitor',        [0x2100 + 4]  = 'Tension Spring II',
    [0x2100 + 5]  = 'Attuner',          [0x2100 + 7]  = 'Flame Holder',
    [0x2100 + 98] = 'Armor Plate',
    [0x2100 + 200] = 'Armor Plate II',  [0x2100 + 201] = 'Analyzer',
    [0x2100 + 202] = 'Auto-Repair Kit', [0x2100 + 203] = 'Accelerator',
    [0x2100 + 204] = 'Coiler',          [0x2100 + 205] = 'Amplifier',
    [0x2100 + 206] = 'Heatsink',
    [0x2100 + 207] = 'Drum Magazine',   [0x2100 + 208] = 'Flashbulb',
    [0x2100 + 209] = 'Shock Absorber',  [0x2100 + 210] = 'Scanner',
    [0x2100 + 211] = 'Damage Gauge',    [0x2100 + 212] = 'Mana Booster',
    [0x2100 + 213] = 'Tactical Processor',
}

-- Spell names the resource manager answers with, for the Spell line and the log.
-- Ids inside the real spell range that no fixture names get a generated one:
-- the addon fills tm.names for its whole table on the first frame and probes
-- through safe(), so an unnamed id was a swallowed error every session. An id
-- outside the range still answers nil, which is what exercises the
-- 'spell <id>' fallback.
local SPELLS = setmetatable({}, { __index = function(_, id)
    if type(id) == 'number' and id >= 1 and id <= 1000 then return 'Spell ' .. id end
    return nil
end })
for k, v in pairs({
    [1] = 'Cure', [2] = 'Cure II', [3] = 'Cure III', [4] = 'Cure IV', [5] = 'Cure V', [14] = 'Poisona',
    [16] = 'Blindna', [23] = 'Dia', [24] = 'Dia II', [43] = 'Protect', [44] = 'Protect II',
    [45] = 'Protect III', [46] = 'Protect IV',
    [48] = 'Shell', [50] = 'Shell III', [51] = 'Shell IV', [54] = 'Stoneskin', [56] = 'Slow', [57] = 'Haste', [58] = 'Paralyze',
    [59] = 'Silence', [106] = 'Phalanx', [108] = 'Regen', [110] = 'Regen II', [111] = 'Regen III',
    [143] = 'Erase',
    [144] = 'Fire', [149] = 'Blizzard', [159] = 'Stone', [160] = 'Stone II',
    [164] = 'Thunder', [165] = 'Thunder II',
    -- the tiers the MP ladder actually chooses between, which read as
    -- 'spell 162' until a fixture needed to name one
    [146] = 'Fire III', [147] = 'Fire IV', [151] = 'Blizzard III', [152] = 'Blizzard IV',
    [156] = 'Aero III', [157] = 'Aero IV', [161] = 'Stone III', [162] = 'Stone IV',
    [166] = 'Thunder III', [167] = 'Thunder IV', [171] = 'Water III', [172] = 'Water IV',
    [220] = 'Poison', [230] = 'Bio', [231] = 'Bio II', [245] = 'Drain', [247] = 'Aspir',
    [254] = 'Blind', [260] = 'Dispel', [270] = 'Absorb-INT', [277] = 'Dread Spikes',
}) do rawset(SPELLS, k, v) end
