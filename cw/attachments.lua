-- cw/attachments.lua - what each attachment does at each maneuver count.
-- Owns the effect tables (ATTACH_MODS, REGEN_FORMULA), the ATTACH_ELEM element
-- and capacity costs, the Optic Fiber boost and the maneuvers' own stat gain.
-- Exports those three tables plus attachMods, fmtMod, attachEffect and
-- buffSummary.
local config = require('cw.config')
local D      = require('cw.data')
local ELEMENTS = D.ELEMENTS
local tm     = require('cw.state')
local U      = require('cw.util')
local safe, player, isPup, isPupSub = U.safe, U.player, U.isPup, U.isPupSub
local R      = require('cw.reading')
local equippedAttachments = R.equippedAttachments

-- =================================================== attachment effects ==
-- Generated from LSB automaton.lua (attachmentModifiers) and item_puppet.sql
-- (element + capacity, a nibble per element - see puppetutils.cpp). Values
-- are indexed [maneuvers + 1] of the attachment's OWN element, capped at 3
-- (automaton.lua). Percent mods
-- marked 'p' are stored in 1/10000; '%' ones are already percent.
local ATTACH_MODS =
{
    ['Accelerator'] = {{'EVA','',{5,10,15,20}}},
    ['Accelerator II'] = {{'EVA','',{10,15,20,25}}},
    ['Accelerator III'] = {{'EVA','',{20,30,40,50}}},
    ['Accelerator IV'] = {{'EVA','',{30,45,60,80}}},
    ['Analyzer'] = {{'Analyzer','',{1,2,4,6}}},
    ['Arcanic Cell'] = {{'Occult Acumen','',{10,20,35,50}}},
    ['Arcanic Cell II'] = {{'Occult Acumen','',{20,40,70,100}}},
    ['Arcanoclutch'] = {{'M.Dmg','',{20,40,60,80}}},
    ['Arcanoclutch II'] = {{'M.Dmg','',{40,60,80,120}}},
    ['Armor Plate'] = {{'PDT','p',{-500,-700,-1000,-1500}}},
    ['Armor Plate II'] = {{'PDT','p',{-1000,-1500,-2000,-2500}}},
    ['Armor Plate III'] = {{'PDT','p',{-1500,-2000,-2500,-3000}}},
    ['Armor Plate IV'] = {{'PDT','p',{-2000,-2500,-3000,-4000}}},
    ['Auto-Repair Kit'] = {{'Max HP','%',{5,5,5,5}}},
    ['Auto-Repair Kit II'] = {{'Max HP','%',{10,10,10,10}}},
    ['Auto-Repair Kit III'] = {{'Max HP','%',{15,15,15,15}}},
    ['Auto-Repair Kit IV'] = {{'Max HP','%',{20,20,20,20}}},
    ['Coiler'] = {{'Dbl.Atk','%',{3,10,20,30}}},
    ['Coiler II'] = {{'Dbl.Atk','%',{10,15,25,35}}},
    ['Damage Gauge'] = {{'Cure at HP','%',{30,40,50,75}},{'Cure delay','-s',{3,6,8,10}}},
    ['Drum Magazine'] = {{'R.Delay','-s',{3,6,9,15}}},
    ['Dynamo'] = {{'Crit','%',{3,5,7,9}}},
    ['Dynamo II'] = {{'Crit','%',{5,10,15,20}}},
    ['Dynamo III'] = {{'Crit','%',{10,15,25,35}}},
    ['Equalizer'] = {{'Equalizer','',{10,25,50,75}}},
    ['Galvanizer'] = {{'Counter','%',{10,20,35,50}}},
    ['Hammermill'] = {{'Shield Bash','',{15,25,50,100}},{'SB slow','%',{0,12,19,25}}},
    -- This model's Horizon override, not upstream. Upstream LSB's table is
    -- {1,3,4,5}: a passive +1 and a first-Water step of +2, which the model
    -- assumes Horizon does not run (see config.heatsink_decay). The row is
    -- driven off that config, so the Loadout
    -- tab, the 'maneuvers give' strip and the sidebar quote the numbers the
    -- burden model predicts from, and a recalibration moves both together.
    ['Heatsink'] = {{'Burden decay','',{config.heatsink_decay[0], config.heatsink_decay[1],
                                        config.heatsink_decay[2], config.heatsink_decay[3]}}},
    ['Inhibitor'] = {{'Store TP','',{5,15,25,40}}},
    ['Inhibitor II'] = {{'Store TP','',{10,25,40,65}}},
    ['Loudspeaker'] = {{'M.ATT','',{5,10,15,20}}},
    ['Loudspeaker II'] = {{'M.ATT','',{10,15,20,25}}},
    ['Loudspeaker III'] = {{'M.ATT','',{20,30,40,50}}},
    ['Loudspeaker IV'] = {{'M.ATT','',{30,40,50,60}}},
    ['Loudspeaker V'] = {{'M.ATT','',{40,50,60,70}}},
    ['Magniplug'] = {{'DMG','',{5,15,30,45}},{'R.DMG','',{5,15,30,45}}},
    ['Magniplug II'] = {{'DMG','',{10,20,35,50}},{'R.DMG','',{10,20,35,50}}},
    ['Mana Booster'] = {{'Magic delay','-s',{2,4,6,8}}},
    ['Mana Conserver'] = {{'Conserve MP','%',{15,30,45,60}}},
    ['Mana Jammer'] = {{'M.DEF','',{10,20,30,40}}},
    ['Mana Jammer II'] = {{'M.DEF','',{20,30,40,50}}},
    ['Mana Jammer III'] = {{'M.DEF','',{30,40,50,60}}},
    ['Mana Jammer IV'] = {{'M.DEF','',{40,50,60,70}}},
    ['Mana Tank'] = {{'Max MP','%',{5,5,5,5}}},
    ['Mana Tank II'] = {{'Max MP','%',{10,10,10,10}}},
    ['Mana Tank III'] = {{'Max MP','%',{15,15,15,15}}},
    ['Mana Tank IV'] = {{'Max MP','%',{20,20,20,20}}},
    ['Optic Fiber'] = {{'Perf. boost','%',{10,20,25,30}}},
    ['Optic Fiber II'] = {{'Perf. boost','%',{15,30,37,45}}},
    ['Percolator'] = {{'Skillup rate','%',{5,10,15,20}}},
    ['Repeater'] = {{'Dbl.Shot','%',{10,15,35,65}}},
    ['Scanner'] = {{'Scan resists','',{0,1,1,1}}},
    ['Schurzen'] = {{'Schurzen','',{0,1,1,1}}},
    ['Scope'] = {{'R.ACC','',{10,20,30,40}}},
    ['Scope II'] = {{'R.ACC','',{20,30,40,50}}},
    ['Scope III'] = {{'R.ACC','',{30,40,55,70}}},
    ['Scope IV'] = {{'R.ACC','',{40,50,65,80}}},
    ['Speedloader'] = {{'SC bonus','',{20,30,40,60}}},
    ['Speedloader II'] = {{'SC bonus','',{35,45,60,80}}},
    ['Stabilizer'] = {{'ACC','',{5,10,15,20}}},
    ['Stabilizer II'] = {{'ACC','',{10,15,20,25}}},
    ['Stabilizer III'] = {{'ACC','',{20,30,40,50}}},
    ['Stabilizer IV'] = {{'ACC','',{30,40,55,70}}},
    ['Stabilizer V'] = {{'ACC','',{40,50,65,80}}},
    ['Stealth Screen'] = {{'Enmity','',{-10,-20,-30,-40}}},
    ['Stealth Screen II'] = {{'Enmity','',{-15,-25,-35,-45}}},
    ['Steam Jacket'] = {{'Steam Jacket','',{2,3,4,5}},{'SJ reduction','%',{30,45,60,80}}},
    ['Strobe'] = {{'Enmity','',{10,25,40,60}}},
    ['Strobe II'] = {{'Enmity','',{20,40,65,100}}},
    ['Tactical Processor'] = {{'Decision delay','-cs',{50,70,85,115}}},
    ['Tension Spring'] = {{'ATT','%',{3,6,9,12}},{'R.ATT','%',{3,6,9,12}}},
    ['Tension Spring II'] = {{'ATT','%',{6,9,12,15}},{'R.ATT','%',{6,9,12,15}}},
    ['Tension Spring III'] = {{'ATT','%',{12,15,18,21}},{'R.ATT','%',{12,15,18,21}}},
    ['Tension Spring IV'] = {{'ATT','%',{15,18,21,24}},{'R.ATT','%',{15,18,21,24}}},
    ['Tension Spring V'] = {{'ATT','%',{18,21,24,27}},{'R.ATT','%',{18,21,24,27}}},
    ['Tranquilizer'] = {{'M.ACC','',{10,30,40,50}}},
    ['Tranquilizer II'] = {{'M.ACC','',{20,40,55,70}}},
    ['Tranquilizer III'] = {{'M.ACC','',{30,50,70,80}}},
    ['Tranquilizer IV'] = {{'M.ACC','',{40,60,80,110}}},
    ['Truesights'] = {{'R.Dmg','%',{5,15,30,45}}},
    ['Turbo Charger'] = {{'Haste','p',{500,1500,2000,2500}}},
    ['Turbo Charger II'] = {{'Haste','p',{700,1700,2800,4375}}},
    ['Vivi-Valve'] = {{'Cure pot','%',{5,15,30,45}}},
    ['Vivi-Valve II'] = {{'Cure pot','%',{10,20,35,50}}},
    ['Volt Gun'] = {{'Enspell','',{5,5,5,5}},{'Enspell rate','%',{20,35,50,65}}},
}

-- Attachment element and capacity cost: which nibble of the item's `element`
-- word is set, and to what. ATTACHMENTS ONLY - a head or a frame GIVES
-- capacity across several elements, and that is PUPPET_CAP's job.
--
-- Read from the CLIENT, not from item_puppet.sql. All 117 rows were dumped
-- off the client's own IItem.PuppetElements - the same data the
-- Automaton equipment screen renders. LandSandBoat's item_puppet.sql is the
-- baseline Horizon forked from, not Horizon, and where the two disagree - tiers
-- I and II of Stabilizer, Loudspeaker, Tranquilizer, Auto-Repair Kit and Mana
-- Tank; III and up match - the client wins.
--
-- Keyed by the client's resource name, which is the full name - "Tension
-- Spring V", not an abbreviation - so a key spelled any other way resolves to
-- nothing in game: no cost, no effect, no capacity spent. ATTACH_MODS above
-- uses the same keys.
--
-- Re-read the names from the client after any client patch rather than
-- hand-editing, and beware item_puppet.sql's own names if you consult it:
-- row 8556 is armor_plate_iv but is labelled 'barrier_module'.
local ATTACH_ELEM =
{
    ['Accelerator'] = {'Wind',2},
    ['Accelerator II'] = {'Wind',3},
    ['Accelerator III'] = {'Wind',4},
    ['Accelerator IV'] = {'Wind',5},
    ['Amplifier'] = {'Ice',2},
    ['Amplifier II'] = {'Ice',3},
    ['Analyzer'] = {'Earth',1},
    ['Arcanic Cell'] = {'Light',1},
    ['Arcanic Cell II'] = {'Light',2},
    ['Arcanoclutch'] = {'Ice',1},
    ['Arcanoclutch II'] = {'Ice',2},
    ['Armor Plate'] = {'Earth',2},
    ['Armor Plate II'] = {'Earth',3},
    ['Armor Plate III'] = {'Earth',4},
    ['Armor Plate IV'] = {'Earth',5},
    ['Attuner'] = {'Fire',2},
    ['Auto-Repair Kit'] = {'Light',1},
    ['Auto-Repair Kit II'] = {'Light',2},
    ['Auto-Repair Kit III'] = {'Light',4},
    ['Auto-Repair Kit IV'] = {'Light',5},
    ['Barrage Turbine'] = {'Wind',2},
    ['Barrier Module'] = {'Earth',1},
    ['Barrier Module II'] = {'Earth',2},
    ['Coiler'] = {'Thunder',2},
    ['Coiler II'] = {'Thunder',3},
    ['Condenser'] = {'Water',1},
    ['Damage Gauge'] = {'Light',1},
    ['Damage Gauge II'] = {'Light',2},
    ['Disruptor'] = {'Dark',2},
    ['Drum Magazine'] = {'Wind',2},
    ['Dynamo'] = {'Thunder',2},
    ['Dynamo II'] = {'Thunder',3},
    ['Dynamo III'] = {'Thunder',4},
    ['Economizer'] = {'Dark',1},
    ['Equalizer'] = {'Earth',2},
    ['Eraser'] = {'Light',2},
    ['Flame Holder'] = {'Fire',1},
    ['Flashbulb'] = {'Light',2},
    ['Galvanizer'] = {'Thunder',2},
    ['Hammermill'] = {'Earth',1},
    ['Heat Capacitor'] = {'Fire',1},
    ['Heat Capacitor II'] = {'Fire',2},
    ['Heat Seeker'] = {'Thunder',1},
    ['Heatsink'] = {'Water',1},
    ['Ice Maker'] = {'Ice',1},
    ['Inhibitor'] = {'Fire',1},
    ['Inhibitor II'] = {'Fire',2},
    ['Loudspeaker'] = {'Ice',2},
    ['Loudspeaker II'] = {'Ice',3},
    ['Loudspeaker III'] = {'Ice',3},
    ['Loudspeaker IV'] = {'Ice',4},
    ['Loudspeaker V'] = {'Ice',5},
    ['Magniplug'] = {'Fire',1},
    ['Magniplug II'] = {'Fire',2},
    ['Mana Booster'] = {'Ice',2},
    ['Mana Channeler'] = {'Water',2},
    ['Mana Channeler II'] = {'Water',3},
    ['Mana Conserver'] = {'Dark',1},
    ['Mana Converter'] = {'Dark',2},
    ['Mana Jammer'] = {'Water',2},
    ['Mana Jammer II'] = {'Water',3},
    ['Mana Jammer III'] = {'Water',4},
    ['Mana Jammer IV'] = {'Water',5},
    ['Mana Tank'] = {'Dark',1},
    ['Mana Tank II'] = {'Dark',2},
    ['Mana Tank III'] = {'Dark',4},
    ['Mana Tank IV'] = {'Dark',5},
    ['Optic Fiber'] = {'Light',1},
    ['Optic Fiber II'] = {'Light',2},
    ['Pattern Reader'] = {'Wind',1},
    ['Percolator'] = {'Water',1},
    ['Power Cooler'] = {'Ice',2},
    ['Reactive Shield'] = {'Fire',1},
    ['Regulator'] = {'Dark',3},
    ['Repeater'] = {'Wind',2},
    ['Replicator'] = {'Wind',1},
    ['Resister'] = {'Water',1},
    ['Resister II'] = {'Water',2},
    ['Scanner'] = {'Ice',1},
    ['Schurzen'] = {'Earth',1},
    ['Scope'] = {'Wind',1},
    ['Scope II'] = {'Wind',2},
    ['Scope III'] = {'Wind',3},
    ['Scope IV'] = {'Wind',4},
    ['Shock Absorber'] = {'Earth',1},
    ['Shock Absorber II'] = {'Earth',2},
    ['Shock Absorber III'] = {'Earth',3},
    ['Smoke Screen'] = {'Dark',2},
    ['Speedloader'] = {'Fire',1},
    ['Speedloader II'] = {'Fire',2},
    ['Stabilizer'] = {'Thunder',2},
    ['Stabilizer II'] = {'Thunder',3},
    ['Stabilizer III'] = {'Thunder',3},
    ['Stabilizer IV'] = {'Thunder',4},
    ['Stabilizer V'] = {'Thunder',5},
    ['Stealth Screen'] = {'Water',1},
    ['Stealth Screen II'] = {'Water',2},
    ['Steam Jacket'] = {'Water',1},
    ['Strobe'] = {'Fire',1},
    ['Strobe II'] = {'Fire',2},
    ['Tactical Processor'] = {'Ice',1},
    ['Target Marker'] = {'Thunder',2},
    ['Tension Spring'] = {'Fire',1},
    ['Tension Spring II'] = {'Fire',2},
    ['Tension Spring III'] = {'Fire',3},
    ['Tension Spring IV'] = {'Fire',4},
    ['Tension Spring V'] = {'Fire',5},
    ['Tranquilizer'] = {'Ice',2},
    ['Tranquilizer II'] = {'Ice',2},
    ['Tranquilizer III'] = {'Ice',3},
    ['Tranquilizer IV'] = {'Ice',4},
    ['Truesights'] = {'Wind',1},
    ['Turbo Charger'] = {'Wind',2},
    ['Turbo Charger II'] = {'Wind',3},
    ['Vivi-Valve'] = {'Light',2},
    ['Vivi-Valve II'] = {'Light',3},
    ['Volt Gun'] = {'Thunder',1},
}

-- Regen/Refresh are computed rather than tabled (automaton.lua):
--   value = base[n+1] + pool * (pct[n+1] / 100)
-- where pool is the automaton's max HP for Regen (Auto-Repair Kit) and its max
-- MP for Refresh (Mana Tank), both from the 0x044; the result takes the Optic
-- Fiber boost.
local REGEN_FORMULA =
{
    ['Auto-Repair Kit']     = { 'Regen',   { 0, 1, 2, 3 },    { 0, 0.125, 0.225, 0.375 } },
    ['Auto-Repair Kit II']  = { 'Regen',   { 0, 3, 6, 9 },    { 0, 0.6, 1.2, 1.8 } },
    ['Auto-Repair Kit III'] = { 'Regen',   { 0, 9, 12, 15 },  { 0, 1.8, 2.4, 3.0 } },
    ['Auto-Repair Kit IV']  = { 'Regen',   { 0, 15, 18, 21 }, { 0, 3.0, 3.6, 4.2 } },
    ['Mana Tank']           = { 'Refresh', { 0, 1, 2, 3 },    { 0, 0.2, 0.4, 0.6 } },
    ['Mana Tank II']        = { 'Refresh', { 0, 2, 3, 4 },    { 0, 0.4, 0.6, 0.8 } },
    ['Mana Tank III']       = { 'Refresh', { 0, 3, 4, 5 },    { 0, 0.6, 0.8, 1.0 } },
    ['Mana Tank IV']        = { 'Refresh', { 0, 4, 5, 6 },    { 0, 0.8, 1.0, 1.2 } },
}

-- ======================================================= Optic Fiber ==
-- Every attachment mod LSB flags (attachmentModifiers' third field) is
-- multiplied by the performance boost the automaton's Optic Fibers grant and
-- then floored - `modValue = floor(modValue * (1 + boost / 100))`
-- (automaton.lua updateAttachmentModifier). 82 of its 104 rows carry the flag,
-- so the EXCEPTIONS are listed here instead, keyed by the label the table above
-- gives them. Without the boost the summary would quote raw table values:
-- with Stabilizer II and one Optic Fiber, one Light maneuver up, the
-- automaton's ACC steps +6 per Thunder maneuver (15 -> 20 boosted 20%, i.e.
-- 18 -> 24) where the bare table says +5.
-- 'Burden decay' is ours rather than LSB's, which does boost Heatsink: that row
-- is driven off config.heatsink_decay, a model override for Horizon with any
-- Optic Fiber effect already inside it, and the burden model predicts from that same
-- config - boosting the display alone would put the readout at odds with the
-- prediction.
local NO_BOOST =
{
    ['Max HP'] = true, ['Max MP'] = true, ['Cure delay'] = true,
    ['Magic delay'] = true, ['Perf. boost'] = true, ['Scan resists'] = true,
    ['Schurzen'] = true, ['Steam Jacket'] = true, ['Decision delay'] = true,
    ['Enspell'] = true, ['Enspell rate'] = true, ['Burden decay'] = true,
}

-- The boost in percent, summed over every Optic Fiber in `names` at the LIGHT
-- count in `counts` (automaton.lua calculatePerformanceBoost). It is read off
-- the counts the caller asked about rather than off live state, so a
-- hypothetical Light maneuver in the what-if sidebar lifts every boosted row
-- with it - which is what a Light maneuver really does, and is why one is
-- worth +1 ACC in the example above with no accuracy attachment involved.
-- Attuner and Shock Absorber are NOT boosted: they carry their own attachment
-- scripts on the server and never reach updateAttachmentModifier, so the
-- multiplier is applied to the tabled rows below and not to their branch.
local function perfBoost(names, counts)
    local n, boost = math.min(counts.Light or 0, 3), 0
    for _, name in ipairs(names or {}) do
        local rows = ATTACH_MODS[name]
        if rows ~= nil and rows[1][1] == 'Perf. boost' then
            boost = boost + rows[1][3][n + 1]
        end
    end
    return boost
end

-- ==================================================== maneuver stat gain ==
-- A maneuver is not only an attachment switch. Each one adds a stat to the
-- automaton for as long as it is up, at power `1 + level / 15` - +6 at 75,
-- CHR per Light maneuver
-- (automaton.lua onUseManeuver, effects/<element>_maneuver.lua). Dark grants
-- nothing at all - its effect script is empty, and MANEUVER_STAT's Dark = MP is
-- the BURDEN check's stat, not a gain - so it has no row here.
--
-- The STAT is what a row says, and nothing else. What the stat then buys the
-- automaton is known - the automaton branches of battleentity.cpp:
--   DEX -> ACC floor(DEX * 0.5)   AGI -> R.ACC floor(AGI * 0.5), EVA AGI / 2
--   STR -> ATT STR * 0.5          VIT -> DEF   floor(VIT * 0.5)
-- (VIT's multiplier is a server setting; this model assumes Horizon runs the
-- era's 0.5 rather than upstream's current 1.5, so two Earth maneuvers would
-- move Defense 274 -> 277 -> 280.) The conversions are deliberately NOT folded into the attachment's
-- own row: a Thunder maneuver would read `ACC +9  DEX +6` - one number combining
-- two sources, with the second still listed beside it as though the DEX were
-- more accuracy again on top. A row names one source: the attachment's mod is
-- the ACC row, the maneuver's grant is the DEX row, and the conversion above is
-- the reader's to apply. The figures are kept here as the reference for it.
local MANEUVER_GAIN =
{
    Fire    = 'STR',
    Ice     = 'INT',
    Wind    = 'AGI',
    Earth   = 'VIT',
    Thunder = 'DEX',
    Water   = 'MND',
    Light   = 'CHR',
}

-- 0 when there is no PUP on either job line to read a level off.
local function maneuverPower()
    local lvl = safe(function()
        local p = player()
        if isPup() then return p:GetMainJobLevel() end
        if isPupSub() then return p:GetSubJobLevel() end
        return 0
    end, 0) or 0
    if lvl <= 0 then return 0 end
    return 1 + math.floor(lvl / 15)
end

-- The maneuvers' own contribution at `counts`, in the shape buffSummary sums:
-- one row per element with a maneuver up, carrying the stat and nothing derived
-- from it.
local function maneuverGain(counts)
    local rows, power = {}, maneuverPower()
    if power == 0 then return rows end
    for _, el in ipairs(ELEMENTS) do
        local stat = MANEUVER_GAIN[el]
        local n    = math.min(counts[el] or 0, 3)
        if stat ~= nil and n > 0 then
            rows[#rows + 1] = { stat, '', power * n, false }
        end
    end
    return rows
end

-- One equipped attachment's contribution at the CURRENT maneuver count of its
-- own element, as structured data: { label, unit, value, conditional }.
-- Both the Loadout list and the Status summary read this, so they can never
-- disagree about what an attachment is granting.
-- `names` is the attachment list the Optic Fiber boost is read from - the
-- saved set on the Loadout tab's preview, and what is on the automaton right
-- now everywhere else.
local function attachMods(name, counts, names)
    local info = ATTACH_ELEM[name]
    if info == nil then return nil, 0, {}, {} end
    local el = info[1]
    local n  = math.min(counts[el] or 0, 3)
    local mods, notes = {}, {}
    local boost = perfBoost(names or equippedAttachments(), counts)
    local function boosted(v) return math.floor(v * (1 + boost / 100)) end

    -- Attuner and Shock Absorber carry their own attachment scripts rather
    -- than sitting in attachmentModifiers, so their numbers live here.
    -- Attuner stacks cumulatively per Fire maneuver (5 / +13 / +25 / +39)
    -- and applies ONLY while the target out-levels the automaton, so it is
    -- flagged conditional and never silently inflates the summary.
    if name == 'Attuner' then
        local v = ({ 5, 18, 43, 82 })[n + 1]
        mods[1] = { 'ATT', '%', v, true }
        mods[2] = { 'R.ATT', '%', v, true }
        notes[1] = 'vs higher-lvl only'
    elseif name == 'Shock Absorber' then
        notes[1] = (n > 0) and 'auto-uses Shock Absorber' or 'idle - needs 1+ Earth'
    end

    local reg = REGEN_FORMULA[name]
    if reg ~= nil then
        local pool = (reg[1] == 'Regen') and (tm.auto044 and tm.auto044.maxhp)
                                          or (tm.auto044 and tm.auto044.maxmp)
        mods[#mods + 1] = { reg[1], '',
                            boosted(reg[2][n + 1] + ((pool or 0) * reg[3][n + 1] / 100)),
                            false }
    end

    for _, m in ipairs(ATTACH_MODS[name] or {}) do
        local v = m[3][n + 1]
        mods[#mods + 1] = { m[1], m[2], NO_BOOST[m[1]] and v or boosted(v), false }
    end
    return el, n, mods, notes
end

local function fmtMod(m)
    local lab, unit, v = m[1], m[2], m[3]
    if     unit == 'p'  then return ('%s %+.0f%%'):format(lab, v / 100)
    elseif unit == '%'  then return ('%s %+d%%'):format(lab, v)
    -- The stored value is the SIZE of a reduction, so it is negated and
    -- printed signed. That reads right for a total ('Magic delay -8s') and for
    -- a difference alike: losing 2s of Mana Booster is a delta of -2 and reads
    -- '+2s' - the delay going back up, which is what it means.
    elseif unit == '-s' then return ('%s %+ds'):format(lab, -v)
    elseif unit == '-cs' then return ('%s %+.2fs'):format(lab, -v / 100)   -- AUTO_DECISION_DELAY: 10 ms units
    else                     return ('%s %+d'):format(lab, v) end
end

local function attachEffect(name, counts, names)
    local el, n, mods, notes = attachMods(name, counts, names)
    local parts = {}
    for _, m in ipairs(mods) do parts[#parts + 1] = fmtMod(m) end
    for _, t in ipairs(notes) do parts[#parts + 1] = t end
    return el, n, (#parts > 0) and table.concat(parts, '  ') or nil
end

-- Everything the automaton is carrying, summed across all twelve slots, plus
-- the stat each live maneuver grants. Same-label mods stack additively on the
-- server (getMod sums), so summing here matches what the pet really has. A stat
-- row never collides with an attachment's - ACC is the attachment's, DEX is the
-- maneuver's - so nothing is folded together and no figure is arrived at twice.
--
-- Pass baseCounts to get a DIFFERENCE instead of a total: the values at
-- baseCounts are subtracted, so buffSummary(names, live, {}) yields only what the
-- maneuvers are adding over the same attachments with nothing up. Anything
-- that does not scale with maneuvers cancels to zero and drops out.
local function buffSummary(names, counts, baseCounts)
    local sum, order = {}, {}
    local function add(m, sign)
        local k = m[1]
        if sum[k] == nil then
            sum[k] = { m[1], m[2], 0, false }
            order[#order + 1] = k
        end
        sum[k][3] = sum[k][3] + (m[3] * sign)
        -- only the live pass decides conditionality; the baseline
        -- is the same attachments, so it would just re-flag them
        if m[4] and sign > 0 then sum[k][4] = true end
    end
    local function accumulate(cnts, sign)
        for _, name in ipairs(names or {}) do
            if name ~= nil and name ~= '' then
                local _, _, mods = attachMods(name, cnts, names)
                for _, m in ipairs(mods) do add(m, sign) end
            end
        end
        for _, m in ipairs(maneuverGain(cnts)) do add(m, sign) end
    end
    accumulate(counts, 1)
    if baseCounts ~= nil then accumulate(baseCounts, -1) end
    local out = {}
    for _, k in ipairs(order) do
        if sum[k][3] ~= 0 then out[#out + 1] = sum[k] end
    end
    return out
end

return { ATTACH_MODS = ATTACH_MODS, ATTACH_ELEM = ATTACH_ELEM,
         attachMods = attachMods, fmtMod = fmtMod, attachEffect = attachEffect,
         buffSummary = buffSummary }
