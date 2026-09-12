-- cw/data.lua - the static tables: message, ability and effect ids, the 0x028
-- categories, the automaton mobskills and weaponskill lists, the skillchain
-- tables, oil ids, the stat, gear and slot maps, the equipment offsets, the
-- head/frame element caps (PUPPET_CAP) and ABILITY_ICON. Returns them all in
-- one table; publishes nothing on tm.

-- ================================================================ tables =
local ELEMENTS = { 'Fire', 'Ice', 'Wind', 'Earth', 'Thunder', 'Water', 'Light', 'Dark' }

local MSG_OVERLOAD_CHANCE = 798
local MSG_OVERLOADED      = 799
local ABIL_MANEUVER_FIRST = 141   -- 141..148 == Fire..Dark, LSB abilities.sql
local ABIL_DEA            = 310   -- Deus Ex Automata, LSB abilities.sql
local ABIL_ACTIVATE       = 136   -- Activate, LSB abilities.sql (abilityId; 205 there is the animation)
local EFFECT_OVERLOAD     = 299
local EFFECT_MANEUVER_1   = 300   -- 300..307 == Fire..Dark

local CAT_ABILITY, CAT_MOBSKILL, CAT_WS, CAT_AVATAR = 6, 11, 3, 13
local CAT_MAGIC, CAT_MAGIC_START = 4, 8   -- XiPackets 0x0028: Magic Finish, Magic Start

-- LSB battleentity.cpp - any pet skill with id >= 256 is routed as
-- MobSkillFinish (category 11), NOT SkillFinish. Automaton weaponskills and
-- the Sharpshot shot are all mobskills, so act.param is a MOBSKILL id.
-- Ids from LSB mob_skills.sql.
local PET_MOBSKILL =
{
    [1940] = 'Chimera Ripper', [1941] = 'String Clipper',
    [1942] = 'Arcuballista',   [1943] = 'Slapstick',
    [1949] = 'Ranged Attack',
    [2065] = 'Cannibal Blade', [2066] = 'Daze', [2067] = 'Knockout',
}
local MOBSKILL_RANGED = 1949

-- ============================================================ skillchain =
-- With Inhibitor equipped the automaton stops choosing its weaponskill by
-- maneuver count and instead closes whatever skillchain is already open on
-- its target (automaton_controller.cpp TryTPMove). The resonance is left by
-- ANY player's weaponskill, not just the master's - which is why the pet can
-- ignore the maneuvers you are holding.
-- Upstream gates that branch on Inhibitor (AUTO_TP_EFFICIENCY). This model
-- assumes Horizon's melee AI does not: an automaton with no Inhibitor is
-- modelled as closing an open chain, even with a skill that has ZERO
-- maneuvers behind it (Cannibal Blade off Howling Fist, off Seraph Blade,
-- off another automaton's Chimera Ripper). So the chain branch runs
-- unconditionally here; Inhibitor only adds the TP hold. Provisional: a
-- ws_mispredicted record is how the assumption gets checked.
local SC_NAME =
{
    [1]  = 'Transfixion',   [2]  = 'Compression', [3]  = 'Liquefaction',
    [4]  = 'Scission',      [5]  = 'Reverberation', [6] = 'Detonation',
    [7]  = 'Induration',    [8]  = 'Impaction',   [9]  = 'Gravitation',
    [10] = 'Distortion',    [11] = 'Fusion',      [12] = 'Fragmentation',
    [13] = 'Light',         [14] = 'Darkness',    [15] = 'Light II',
    [16] = 'Darkness II',
}

-- battleutils.cpp skillchain_map, flattened to closer*32+opener.
local SC_PAIRS = {}
for _, p in ipairs({
    {13,13,15},{14,14,16},
    {10,9,14},{12,9,12},{9,10,14},{11,10,11},
    {9,11,9},{12,11,13},{10,12,10},{11,12,13},
    {4,1,10},{8,3,11},{2,6,9},{5,7,12},
    {2,1,2},{5,1,5},{1,2,1},{6,2,6},{4,3,4},
    {3,4,3},{5,4,5},{6,4,6},{7,5,7},{8,5,8},
    {4,6,4},{2,7,2},{8,7,8},{3,8,3},{6,8,6},
}) do SC_PAIRS[p[1] * 32 + p[2]] = p[3] end

-- Automaton mobskill -> skillchain properties. Horizon's own table
-- (chains/skills.lua, skills.pup); upstream sql disagrees on String
-- Clipper (no Impaction there) and Daze.
local MOBSKILL_SC =
{
    [1940]={7,6}, [1941]={4,8}, [1942]={3,1}, [1943]={5,8}, [2065]={2,5},
    [2066]={1}, [2067]={4,6},
    [2743]={10,4}, [2744]={11,8},
}

-- Player weaponskill id -> skillchain properties. Horizon's own table
-- (chains/skills.lua, skills[3]) - 16 weaponskills differ from upstream
-- weapon_skills.sql, e.g. Seraph Blade gains Transfixion, Sickle Moon
-- Reverberation, Spiral Hell is Gravitation/Compression.
local WS_SC =
{
    [1]={8}, [2]={5,8}, [3]={2}, [4]={6}, [5]={8}, [6]={3,8}, [7]={1,8},
    [8]={12}, [9]={9,3}, [10]={13,11}, [11]={11,1}, [12]={9,3}, [13]={7,6,8},
    [14]={13,12}, [15]={11,5}, [16]={4}, [17]={4}, [18]={5}, [19]={6},
    [20]={6,8}, [23]={4,6}, [24]={12}, [25]={9,1}, [26]={14,9}, [27]={11,2},
    [28]={12,10}, [29]={10,4}, [30]={4,6,8}, [31]={14,10}, [32]={4}, [33]={3},
    [34]={3,6}, [35]={8}, [36]={4}, [37]={4,1}, [38]={5,8}, [40]={4,8},
    [41]={9}, [42]={12,4}, [43]={13,11}, [44]={12,10}, [45]={11,5},
    [46]={10,4}, [48]={4}, [49]={1}, [50]={7}, [51]={7,6}, [52]={5},
    [53]={4,2}, [54]={4,5}, [55]={12}, [56]={12,10}, [57]={13,11},
    [58]={7,6,8}, [59]={13,10}, [60]={12,4}, [61]={13,12}, [64]={6,8},
    [65]={7,5}, [66]={6}, [67]={7}, [68]={3,4}, [69]={4}, [70]={4,8},
    [71]={11}, [72]={11,6}, [73]={14,9}, [74]={9,5}, [75]={4,6}, [76]={14,12},
    [77]={10,6}, [80]={8}, [81]={4}, [82]={5,4}, [83]={8}, [84]={2}, [85]={8},
    [86]={7,5}, [87]={10}, [88]={10,6}, [89]={13,11}, [90]={12,4},
    [91]={4,6,8}, [92]={13,12}, [93]={11,2}, [96]={4}, [97]={2}, [98]={7,5},
    [99]={2,4}, [100]={5,4}, [101]={1,4}, [102]={7}, [103]={10}, [104]={9,2},
    [105]={14,9}, [106]={11,2}, [107]={2,5}, [108]={14,10}, [109]={9,5},
    [112]={1}, [113]={1,8}, [114]={1,8}, [115]={8}, [116]={2}, [117]={5,1},
    [118]={1,7}, [119]={11}, [120]={9,7}, [121]={13,10}, [122]={11,1},
    [123]={1,4}, [124]={13,12}, [125]={9,1}, [128]={1}, [129]={4}, [130]={5},
    [131]={7,6}, [132]={1,8}, [133]={2}, [134]={6,8}, [135]={9}, [136]={9,1},
    [137]={14,12}, [138]={12,2}, [139]={5,4}, [140]={14,9}, [141]={11,8},
    [144]={1,4}, [145]={7}, [146]={1,8}, [147]={3}, [148]={4,6}, [149]={5,8},
    [150]={7,6}, [151]={10,5}, [152]={11,2}, [153]={13,12}, [154]={9,7},
    [155]={2,4}, [156]={13,10}, [157]={12,2}, [158]={11}, [160]={1},
    [161]={4}, [162]={5}, [165]={7,5}, [166]={6,8}, [167]={8}, [168]={11},
    [169]={12,2}, [170]={13,12}, [172]={7,5}, [174]={11,8}, [175]={14,12},
    [176]={8}, [177]={8}, [178]={6,8}, [179]={2,1}, [180]={1,5}, [181]={6},
    [182]={3,8}, [184]={9,5}, [185]={14,10}, [186]={12,10}, [187]={11,5},
    [188]={9,1}, [189]={2,5}, [191]={9,7}, [192]={3,1}, [193]={5,1},
    [194]={3,1}, [196]={5,1,6}, [197]={7,1}, [198]={11}, [199]={11,1},
    [200]={13,10}, [201]={5,1}, [202]={13,11}, [203]={12,1}, [208]={3,1},
    [209]={5,1}, [210]={3,1}, [212]={5,1,6}, [213]={7,1}, [214]={11},
    [215]={11,1}, [216]={14,12}, [217]={12,4}, [218]={9,1}, [219]={7,6,8},
    [220]={14,9}, [221]={11,5}, [224]={12,4}, [225]={13,10}, [226]={9,4},
    [227]={13}, [228]={13}, [238]={13,12}, [239]={13,11},
}

-- Avatar skill id -> skillchain properties (chains/skills.lua, skills[13]).
-- A summoner's Blood Pact leaves a resonance the automaton will close, the
-- same as a player's weaponskill. Beastmaster pets do not open chains on
-- Horizon (chains/chains.lua), so nothing from a jug pet is listed.
local AVATAR_SC =
{
    [513]={1}, [528]={2}, [529]={1}, [544]={3}, [546]={8}, [547]={2},
    [560]={4}, [562]={5}, [563]={7}, [576]={5}, [578]={6}, [592]={6},
    [608]={7}, [612]={4}, [624]={8},
}

-- Oils by item id (LSB item_basic.sql). The client resource
-- NAMES for the HQ oils are abbreviated ("Automat. Oil +2"), so they are
-- matched by id: the full names would never match an HQ grade.
local OIL_IDS = { [18731] = 'Automaton Oil',    [18732] = 'Automaton Oil +1',
                  [18733] = 'Automaton Oil +2', [19185] = 'Automaton Oil +3' }

local MANEUVER_STAT = { Fire='STR', Ice='INT', Wind='AGI', Earth='VIT',
                        Thunder='DEX', Water='MND', Light='CHR', Dark='MP' }
-- IPlayer exposes stats as GetStat(index) / GetStatModifier(index) - INDEXED.
-- There is no GetStats()/GetStatsModifiers(); the annotations' `---@field Stats`
-- is a struct field, not a getter. Index order follows playerstats_t:
-- Strength, Dexterity, Vitality, Agility, Intelligence, Mind, Charisma.
local PLAYER_STAT_INDEX = { STR=0, DEX=1, VIT=2, AGI=3, INT=4, MND=5, CHR=6 }

-- OVERLOAD_THRESH gear, LSB item_mods.sql mod 505 - era pieces only.
-- BG-wiki agrees on the Dastanas: "increasing the overload threshold by 5".
local OVERLOAD_GEAR = { [14930] = 5, [15030] = 5,   -- Puppetry Dastanas, +1
                        [16281] = 5, [16282] = 5 }  -- Buffoon's Collar, +1
-- MANEUVER_BONUS gear, LSB item_mods.sql mod 504 - era pieces only. Added to
-- the stat each maneuver grants (automaton.lua onUseManeuver).
local MANEUVER_GEAR = { [14930] = 1, [15030] = 1 }  -- Puppetry Dastanas, +1
-- 0-based equipment slots (luashitacast constants.lua lists them 1-based).
local SLOT_HANDS, SLOT_NECK = 6, 9

local EQUIP_OFFSET, ATTACH_OFFSET = 0x2000, 0x2100

-- Head and frame element capacity, raw from LSB item_puppet.sql `element`:
-- a nibble per element, Fire in the LOW nibble, then Ice, Wind, Earth,
-- Thunder, Water, Light, Dark (puppetutils.cpp shifts element*4). Kept as
-- the SQL integers so the transcription can be checked against the file by
-- eye; elementCaps() decodes. Keyed by the id at EQUIP_OFFSET.
local PUPPET_CAP = {
    [1]  = 2236962,     -- Harlequin Head
    [2]  = 33698307,    -- Valoredge X-900 Head
    [3]  = 35783427,    -- Sharpshot Z-500 Head
    [4]  = 540025392,   -- Stormwaker Y-700 Head
    [5]  = 53486128,    -- Soulsoother C-1000 Head
    [6]  = 808460848,   -- Spiritreaver M-400 Head
    [32] = 858993459,   -- Harlequin Frame
    [33] = 590562084,   -- Valoredge X-900 Frame
    [34] = 590623779,   -- Sharpshot Z-500 Frame
    [35] = 1127428674,  -- Stormwaker Y-700 Frame
}

-- LSB automaton_controller.cpp TryTPMove: a skill is VALID when
-- the automaton's gate skill (MELEE for every frame except Sharpshot, which
-- gates on RANGED) is STRICTLY above mob_skill_param; among valid skills the
-- one with the MOST matching master maneuvers wins, ties broken by highest
-- param, remaining ties by list order (strict > on both, so first listed
-- stays). Elements per the per-ability automaton scripts; params from
-- mob_skills.sql; order from mob_skill_lists.sql.
-- WotG-era String Shredder / Armor Shatterer omitted (Horizon is ToAU), and
-- the three tier-3 skills - Bone Crusher (2299), Armor Piercer (2300) and
-- Magic Mortar (2301) - which Horizon does not grant.
-- A resonance open on the target overrides all of this, Inhibitor or not:
-- the closer is chosen instead (see the note above SC_NAME, and burden.lua
-- predictWS's chain branch).
local WS_LISTS =
{
    Valoredge =
    {
        { id = 1940, name = 'Chimera Ripper', el = 'Fire',    param = 0   },
        { id = 1941, name = 'String Clipper', el = 'Thunder', param = 0   },
        { id = 2065, name = 'Cannibal Blade', el = 'Dark',    param = 150 },
    },
    Sharpshot =
    {
        { id = 1942, name = 'Arcuballista',  el = 'Fire',    param = 0   },
        { id = 2066, name = 'Daze',          el = 'Thunder', param = 150 },
    },
    Harlequin =  -- Stormwaker shares this list
    {
        { id = 1943, name = 'Slapstick',    el = 'Thunder', param = 0   },
        { id = 2067, name = 'Knockout',     el = 'Wind',    param = 145 },
    },
}

-- What each automaton ability's cell should be a picture OF. The client has no
-- ability art to give: IAbility carries a ListIconId with nothing in the API that
-- reads it, and these thirteen are mobskills rather than abilities anyway, so they
-- have no such record at all. What the client DOES hand over is status-effect
-- bitmaps and item bitmaps, so each row points at whichever it is about.
--
-- `status` is the effect the ability applies, read off LSB's own scripts
-- (scripts/actions/abilities/pets/automaton/*.lua) and numbered from
-- status_effects.sql - not guessed. The maneuver constants in those scripts are the
-- ability's CHECK, not what it lands, and are deliberately not used here.
--
-- The six not listed - Provoke, Eraser, Economizer, Heat Capacitor, Barrage Turbine
-- and Disruptor - land nothing the client can draw (disruptor.lua and provoke.lua
-- apply xi.effect.NONE; eraser removes a whole list rather than adding one), so
-- they fall back to the icon of the attachment that granted them.
local ABILITY_ICON = {
    [1944] = { status = 10  },   -- Shield Bash    -> Stun       (shield_bash.lua)
    [1946] = { status = 37  },   -- Shock Absorber -> Stoneskin  (shock_absorber.lua)
    [1947] = { status = 156 },   -- Flashbulb      -> Flash      (flashbulb.lua)
    [1948] = { status = 43  },   -- Mana Converter -> Refresh    (mana_converter.lua)
    [2031] = { status = 34  },   -- Reactive Shield-> Blaze Spikes (reactive_shield.lua)
    [2132] = { status = 36  },   -- Replicator     -> Blink      (replicator.lua)
    -- The shot has no effect and no attachment behind it; a bow is the plain
    -- statement of what it is. item_basic.sql 17152, shortbow.
    [1949] = { item = 17152 },
    -- ...and where the game has nothing at all, a file. Provoke lands no effect
    -- and is a mobskill, so there is no art anywhere in the client for it;
    -- assets/abilities/provoke.png is shipped the way the element gems are.
    [1945] = { png = 'provoke' },
}

return { ABILITY_ICON = ABILITY_ICON, ELEMENTS = ELEMENTS, MSG_OVERLOAD_CHANCE = MSG_OVERLOAD_CHANCE,
         MSG_OVERLOADED = MSG_OVERLOADED, ABIL_MANEUVER_FIRST = ABIL_MANEUVER_FIRST,
         ABIL_DEA = ABIL_DEA, ABIL_ACTIVATE = ABIL_ACTIVATE, EFFECT_OVERLOAD = EFFECT_OVERLOAD,
         EFFECT_MANEUVER_1 = EFFECT_MANEUVER_1, CAT_ABILITY = CAT_ABILITY,
         CAT_MOBSKILL = CAT_MOBSKILL, CAT_WS = CAT_WS, CAT_AVATAR = CAT_AVATAR,
         CAT_MAGIC = CAT_MAGIC, CAT_MAGIC_START = CAT_MAGIC_START, PET_MOBSKILL = PET_MOBSKILL,
         MOBSKILL_RANGED = MOBSKILL_RANGED, SC_NAME = SC_NAME, SC_PAIRS = SC_PAIRS,
         MOBSKILL_SC = MOBSKILL_SC, WS_SC = WS_SC, AVATAR_SC = AVATAR_SC,
         MANEUVER_STAT = MANEUVER_STAT, PLAYER_STAT_INDEX = PLAYER_STAT_INDEX,
         OVERLOAD_GEAR = OVERLOAD_GEAR, SLOT_HANDS = SLOT_HANDS, SLOT_NECK = SLOT_NECK,
         MANEUVER_GEAR = MANEUVER_GEAR,
         ATTACH_OFFSET = ATTACH_OFFSET, EQUIP_OFFSET = EQUIP_OFFSET, PUPPET_CAP = PUPPET_CAP,
         OIL_IDS = OIL_IDS, WS_LISTS = WS_LISTS }
