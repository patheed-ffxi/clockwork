-- cw/spell.lua - the caster ladder: what each automaton head casts, when it can,
-- and the spell it will choose next, plus the enfeebles held on each mob.
-- Returns an empty table. Publishes on tm: currentHead, spellName, spellDur,
-- spellEffect, noteMob, mobWearOff, mobPrune, spellObserve, nukeTier, predictSpell
-- and fn (its tables and helpers); keeps tm.mp/mpHi/maxmp, windows, regenHedge.
local D  = require('cw.data')
local CAT_MAGIC, CAT_MAGIC_START = D.CAT_MAGIC, D.CAT_MAGIC_START
local tm = require('cw.state')
local A  = require('cw.attachments')
local attachMods = A.attachMods
local U  = require('cw.util')
local safe, player = U.safe, U.player
local L  = require('cw.log')
local flagAnomaly = L.flagAnomaly
local R  = require('cw.reading')
local petInfo, equippedNames, hasAttachment = R.petInfo, R.equippedNames, R.hasAttachment
local B  = require('cw.burden')
local maneuverCounts = B.maneuverCounts
local P  = require('cw.pet')
local MSG_STATUS_ON, MSG_STATUS_OFF, petEffects = P.MSG_STATUS_ON, P.MSG_STATUS_OFF, P.petEffects

-- =========================================================== spell model ==
-- What the caster heads cast and when: LSB automaton_controller.cpp
-- TrySpellcast and the five rungs under it, the per-head windows of
-- setMagicCooldowns, the spell table automaton_spells.sql joined with
-- spell_list.recastTime, and the erasable / dispelable flags of
-- status_effects.sql. Fully deterministic server side; what the client
-- cannot see (enmity, the mob's raw HP) is said, not guessed.

-- automaton_spells.sql: id, skilllevel, heads bitmask (1<<(head-1)),
-- the effect it lands (blocks a repeat), the immunity bit, the effects a
-- -na removes (packed bytes), spell_list recast in seconds, spell_list
-- mpCost, the rung. The MP is a real gate, not decoration: LSB's Cast()
-- reaches CMagicState, whose CanCastSpell -> HasCost -> CanAffordSpell is
-- health.mp >= spellCost, and IgnoreRecastsAndCosts::Yes does not bypass
-- it (it only skips IsAnySpellAvailable). An unaffordable spell is
-- skipped and the ladder walks on, exactly like a failed skill check.
-- Row 847 (skill 368, no spell_list entry) dropped - past any era cap.
local ROWS = {
    {   1,  12, 31,   0,   0,  136129,   5,   8, 'heal'      }, -- cure
    {   2,  45, 31,   0,   0,       0,   5,  24, 'heal'      }, -- cure ii
    {   3,  81, 31,   0,   0,       0,   6,  46, 'heal'      }, -- cure iii
    {   4, 147, 31,   0,   0,       0,   8,  88, 'heal'      }, -- cure iv
    {   5, 207, 16,   0,   0,       0,  10, 135, 'heal'      }, -- cure v
    {   6, 313, 16,   0,   0,       0,  15, 227, 'heal'      }, -- cure vi
    {  14,  27, 16,   0,   0,       3,   5,   8, 'status'    }, -- poisona
    {  15,  36, 16,   0,   0,       4,   5,  12, 'status'    }, -- paralyna
    {  16,  45, 16,   0,   0,       5,  10,  16, 'status'    }, -- blindna
    {  17,  60, 16,   0,   0,       6,   5,  24, 'status'    }, -- silena
    {  18, 120, 16,   0,   0,       7,   5,  40, 'status'    }, -- stona
    {  19, 105, 16,   0,   0,    2079,   5,  48, 'status'    }, -- viruna
    {  20,  90, 16,   0,   0,  594974,  10,  30, 'status'    }, -- cursna
    {  23,   0, 61, 134,   0,       0,   5,   7, 'enfeeble'  }, -- dia
    {  24,  96, 61, 134,   0,       0,   6,  30, 'enfeeble'  }, -- dia ii
    {  43,  24, 24,   0,   0,       0,   5,   9, 'enhance'   }, -- protect
    {  44,  84, 24,   0,   0,       0,   5,  28, 'enhance'   }, -- protect ii
    {  45, 144, 24,   0,   0,       0,   5,  46, 'enhance'   }, -- protect iii
    {  46, 217, 24,   0,   0,       0,   5,  65, 'enhance'   }, -- protect iv
    {  47, 281, 16,   0,   0,       0,   6,  84, 'enhance'   }, -- protect v
    {  48,  54, 24,   0,   0,       0,   5,  18, 'enhance'   }, -- shell
    {  49, 114, 24,   0,   0,       0,   5,  37, 'enhance'   }, -- shell ii
    {  50, 188, 24,   0,   0,       0,   5,  56, 'enhance'   }, -- shell iii
    {  51, 241, 24,   0,   0,       0,   5,  75, 'enhance'   }, -- shell iv
    {  52, 347, 24,   0,   0,       0,   6,  93, 'enhance'   }, -- shell v
    {  54, 105,  8,   0,   0,       0,  30,  29, 'enhance'   }, -- stoneskin
    {  56,  42, 61,  13, 128,       0,  20,  15, 'enfeeble'  }, -- slow
    {  57, 147, 24,   0,   0,       0,  20,  40, 'enhance'   }, -- haste
    {  58,  21, 61,   4,  32,       0,  10,   6, 'enfeeble'  }, -- paralyze
    {  59,  57, 61,   6,  16,       0,  10,  16, 'enfeeble'  }, -- silence
    { 106,  99,  8,   0,   0,       0,  10,  21, 'enhance'   }, -- phalanx
    { 108,  66, 16,   0,   0,       0,  12,  15, 'enhance'   }, -- regen
    { 110, 135, 16,   0,   0,       0,  16,  36, 'enhance'   }, -- regen ii
    { 111, 232, 16,   0,   0,       0,  20,  64, 'enhance'   }, -- regen iii
    { 129, 425, 16,   0,   0,       0,  19,  84, 'enhance'   }, -- protectra v
    { 134, 434, 16,   0,   0,       0,  19,  93, 'enhance'   }, -- shellra v
    { 143,  99, 16,   0,   0,       0,  15,  18, 'status'    }, -- erase
    { 144,  60, 40,   0,   0,       0,   2,   7, 'elemental' }, -- fire
    { 145, 153, 40,   0,   0,       0,   6,  26, 'elemental' }, -- fire ii
    { 146, 251, 40,   0,   0,       0,  15,  63, 'elemental' }, -- fire iii
    { 147, 281, 40,   0,   0,       0,  30, 135, 'elemental' }, -- fire iv
    { 148, 349, 32,   0,   0,       0,  45, 228, 'elemental' }, -- fire v
    { 149,  75, 40,   0,   0,       0,   2,   8, 'elemental' }, -- blizzard
    { 150, 178, 40,   0,   0,       0,   6,  31, 'elemental' }, -- blizzard ii
    { 151, 256, 40,   0,   0,       0,  15,  75, 'elemental' }, -- blizzard iii
    { 152, 286, 40,   0,   0,       0,  30, 162, 'elemental' }, -- blizzard iv
    { 153, 368, 32,   0,   0,       0,  45, 267, 'elemental' }, -- blizzard v
    { 154,  45, 40,   0,   0,       0,   2,   6, 'elemental' }, -- aero
    { 155, 138, 40,   0,   0,       0,   6,  22, 'elemental' }, -- aero ii
    { 156, 246, 40,   0,   0,       0,  15,  54, 'elemental' }, -- aero iii
    { 157, 276, 40,   0,   0,       0,  30, 115, 'elemental' }, -- aero iv
    { 158, 331, 32,   0,   0,       0,  45, 198, 'elemental' }, -- aero v
    { 159,  15, 40,   0,   0,       0,   2,   4, 'elemental' }, -- stone
    { 160, 108, 40,   0,   0,       0,   6,  16, 'elemental' }, -- stone ii
    { 161, 227, 40,   0,   0,       0,  15,  40, 'elemental' }, -- stone iii
    { 162, 266, 40,   0,   0,       0,  30,  88, 'elemental' }, -- stone iv
    { 163, 296, 32,   0,   0,       0,  45, 156, 'elemental' }, -- stone v
    { 164,  90, 40,   0,   0,       0,   2,   9, 'elemental' }, -- thunder
    { 165, 203, 40,   0,   0,       0,   6,  37, 'elemental' }, -- thunder ii
    { 166, 261, 40,   0,   0,       0,  15,  91, 'elemental' }, -- thunder iii
    { 167, 291, 40,   0,   0,       0,  30, 195, 'elemental' }, -- thunder iv
    { 168, 389, 32,   0,   0,       0,  45, 306, 'elemental' }, -- thunder v
    { 169,  30, 40,   0,   0,       0,   2,   5, 'elemental' }, -- water
    { 170, 123, 40,   0,   0,       0,   6,  19, 'elemental' }, -- water ii
    { 171, 236, 40,   0,   0,       0,  15,  46, 'elemental' }, -- water iii
    { 172, 271, 40,   0,   0,       0,  30,  99, 'elemental' }, -- water iv
    { 173, 313, 32,   0,   0,       0,  45, 175, 'elemental' }, -- water v
    { 220,  18, 61,   3, 256,       0,   5,   5, 'enfeeble'  }, -- poison
    { 221, 141, 57,   3, 256,       0,   5,  38, 'enfeeble'  }, -- poison ii
    { 230,  33, 61, 135,   0,       0,   5,  15, 'enfeeble'  }, -- bio
    { 231, 111, 61, 135,   0,       0,   5,  36, 'enfeeble'  }, -- bio ii
    { 245,  45, 32,   0,   0,       0,  60,  21, 'enfeeble'  }, -- drain
    { 247,  78, 32,   0,   0,       0,  60,  10, 'enfeeble'  }, -- aspir
    { 248, 331, 32,   0,   0,       0,  75,   5, 'enfeeble'  }, -- aspir ii
    { 254,  27, 61,   5,  64,       0,  10,   5, 'enfeeble'  }, -- blind
    { 260, 105,  8,   0,   0,       0,  10,  25, 'enfeeble'  }, -- dispel
    { 270, 120, 32, 140,   0,       0,  60,  33, 'enfeeble'  }, -- absorb-int
    { 277, 256, 32,   0,   0,       0, 180,  78, 'enhance'   }, -- dread spikes
    { 286, 337, 61,  21,   0,       0,  20,  36, 'enfeeble'  }, -- addle
    { 477, 337, 16,   0,   0,       0,  24,  82, 'enhance'   }, -- regen iv
    { 511, 410,  8,   0,   0,       0,  20,  80, 'enhance'   }, -- haste ii
}
local SPELL = {}
for _, r in ipairs(ROWS) do
    local removes, packed = {}, r[6]
    while packed > 0 do
        removes[#removes + 1] = packed % 256
        packed = math.floor(packed / 256)
    end
    SPELL[r[1]] = { id = r[1], skill = r[2], heads = r[3], enfeeble = r[4],
                    immunity = r[5], removes = removes, recast = r[7],
                    mp = r[8], rung = r[9] }
end

-- setMagicCooldowns, by head enum; a missing rung is one that head never
-- tries. Seconds. (Stormwaker's heal / elemental / enhance and Sharpshot's
-- heal are LSB's own guesses.)
local WINDOWS = {
    [1] = { magic = 10, heal = 15, enfeeble = 10 },
    [2] = { magic = 20, heal = 20 },
    [3] = { magic = 12, heal = 18, enfeeble = 12 },
    [4] = { magic = 10, heal = 15, enfeeble = 12, elemental = 33, enhance = 10 },
    [5] = { magic = 4,  heal = 15, enfeeble = 4, enhance = 15, status = 15 },
    [6] = { magic = 10, enfeeble = 10, elemental = 33, enhance = 135 },
}

-- status_effects.flags: 0x2 erasable (what Erase answers), 0x1 dispelable
-- (what Stormwaker's Dispel branch looks for on the mob)
local ERASABLE, DISPELABLE = {}, {}
for id in ('10 11 12 13 21 128 129 130 131 132 133 134 135 136 137 138 139 140 141 142 144 145 146 147 148 149 156 167 174 175 189 192 194 291 298 404 536 571'):gmatch('%d+') do
    ERASABLE[tonumber(id)] = true
end
for id in ('32 33 34 35 36 37 38 39 40 41 42 43 56 57 58 59 60 61 62 64 66 67 68 69 70 71 72 73 74 75 76 77 78 79 80 81 82 83 84 85 86 88 89 90 91 92 93 94 95 96 97 98 99 100 101 102 103 104 105 106 107 108 109 110 111 112 116 117 118 119 120 121 122 123 124 125 150 151 152 153 154 173 190 191 195 196 197 198 199 200 201 202 203 205 206 207 209 210 214 215 216 218 219 220 221 222 274 277 278 279 280 281 282 286 288 293 294 295 296 297 310 311 312 313 314 315 316 317 318 319 320 321 322 323 324 325 326 327 328 329 330 331 332 333 334 335 336 337 338 339 344 345 353 354 403 417 418 419 420 421 431 462 573 583 599 605 606 607 608 609 610 619 621 622'):gmatch('%d+') do
    DISPELABLE[tonumber(id)] = true
end

local HEAD_BY_NAME = { Harlequin = 1, Valoredge = 2, Sharpshot = 3,
                       Stormwaker = 4, Soulsoother = 5, Spiritreaver = 6 }

-- The head enum: the server's 0x044 when it has named one, else the
-- client buffer's head item. nil when neither knows.
tm.currentHead = function()
    local h = tm.auto044 and tm.auto044.head or 0
    if h >= 1 and h <= 6 then return h end
    local eq = equippedNames()
    local name = eq and eq[1] or ''
    for key, n in pairs(HEAD_BY_NAME) do
        if name:find(key) then return n end
    end
    return nil
end

tm.spellName = function(id)
    return safe(function() return AshitaCore:GetResourceManager():GetSpellById(id).Name[1] end, nil)
           or ('spell ' .. tostring(id))
end

-- Bit n (0 = lowest) of a mask such as a spell's heads bitmask.
local function bitAt(mask, n)
    return math.floor((mask or 0) / (2 ^ n)) % 2 == 1
end

-- automaton::CanUseSpell: the head bit and the magic skill. With no
-- 0x044 there is no skill to gate on - predict optimistically, as
-- predictWS does.
local function canCast(id)
    local row, head = SPELL[id], tm.currentHead()
    if row == nil or head == nil then return false end
    if not bitAt(row.heads, head - 1) then return false end
    if tm.auto044 ~= nil and tm.auto044.magic < row.skill then return false end
    return true
end

-- Backstop for a wear-off that never arrived. Set from the LONGEST base
-- duration the ladder can put on a mob, not from Dia II and Bio II:
-- enfeebling_spell.lua's table gives Blind 180, Slow 180, Addle 180,
-- Paralyze 120, Silence 120, Poison II 120, Poison 90. Anything shorter
-- ages a live Blind or Slow out of the model while it is still on the
-- target, and the ladder re-offers it.
-- Erring long is the safe direction: a real wear-off arrives as a
-- MSG_STATUS_OFF and clears the entry exactly, so this only ever covers a
-- message we missed.
local TARGET_EFFECT_AGE = 180
-- How long a blow from the master, the automaton or the party is taken as
-- proof that a mob's enmity list is not empty (tm.touched). The list itself
-- lasts until the mob dies or walks home, and the client sees neither the
-- walk nor the list; a minute without one of us landing anything is the
-- ASSUMPTION that it did. Inside a fight the blows keep coming.
local TOUCH_AGE = 60

-- Dia and Bio announce NOTHING when they land. Their spell scripts return
-- damage from onSpellCast and add the DoT silently, so the 0x028 carries a
-- damage message and no status line at all - only the wear-off is
-- announced, so a table filled from ON lines alone would never hold 134 or
-- 135. In the chat window a Bio II landing shows only its damage, where
-- a Blind shows '(blinded)'.
-- The cast is therefore the only signal, and it is a sound one: the effect
-- is added whatever the message, a full resist included. Bio deletes Dia
-- and Dia deletes Bio (the tier check in the spell script), so recording
-- one drops the other. Keyed off the enfeeble column rather than a list of
-- spell ids - only the Dia and Bio families carry 134 or 135 there.
-- Base durations in seconds for the enfeebles the automaton can land, from
-- enfeebling_spell.lua's table and the Dia / Bio spell scripts. Resistance
-- only ever SHORTENS these, and a shortened one still arrives as a
-- wear-off, so treating the base as the expiry is safe in one direction
-- and exact in the other.
tm.spellDur = { [220] = 90, [221] = 120, [254] = 180, [56] = 180, [58] = 120,
                [59] = 120, [286] = 180, [23] = 60, [24] = 120, [230] = 60, [231] = 120,
                -- ...and what OTHER casters bring, so their landings get a
                -- clock too. Book values from XIUI's debuffhandler; unlisted
                -- spells fall to the backstop.
                [80] = 120, [79] = 180, [357] = 180, [276] = 180, [361] = 180, [359] = 120,
                [25] = 150, [33] = 60, [232] = 150,
                [341] = 180, [342] = 300, [344] = 180, [345] = 300, [347] = 180, [348] = 300 }

-- Spell -> effect for the enfeebles OTHER casters bring to a mob, for the
-- two signals that do not name the effect: a Dia/Bio damage line and a
-- "has no effect". The automaton's own spells carry theirs in
-- SPELL[id].enfeeble. Ids from XIUI's libs/bufftable.lua.
tm.spellEffect = { [23] = 134, [24] = 134, [25] = 134, [33] = 134,
                   [230] = 135, [231] = 135, [232] = 135,
                   [58] = 4, [80] = 4, [56] = 13, [79] = 13, [357] = 13,
                   [254] = 5, [276] = 5, [361] = 5, [59] = 6, [359] = 6,
                   [220] = 3, [221] = 3, [222] = 3, [223] = 3, [224] = 3, [225] = 3,
                   [341] = 5, [342] = 5, [344] = 13, [345] = 13, [347] = 3, [348] = 3 }

-- The clock a landing gets: the automaton's own readings on that spell
-- (the median of the last five, once three are in) beat the book, and the
-- book beats nothing - nil means the flat backstop. Stored two seconds
-- SHORT of the real expiry, so the entry is "when we stop believing it"
-- rather than "when it ends": the server re-casts at its first window
-- after the effect ends and the wear-off reaches us in the same breath as
-- that cast, so believing it to the last millisecond cannot predict the
-- cast. Being early is nearly free: in those two seconds the server either
-- casts nothing (with the enfeeble rung last, no cast is ever judged) or
-- casts from a rung this model checks first anyway.
-- The BOOK duration is an upper bound: a resisted enfeeble runs at half,
-- and how often that happens is a property of the mobs being fought, not
-- of the spell (a resisted Silence can expire well before its base
-- duration). So prefer what has actually been seen.
local function clockFor(spellId, now)
    if spellId == nil then return nil end
    local d = tm.spellDur[spellId]
    local seen = tm.seenDur[spellId]
    if seen ~= nil and #seen >= 3 then
        local s = {}
        for i = 1, #seen do s[i] = seen[i] end
        table.sort(s)
        d = s[math.floor(#s / 2) + 1]
    end
    return (d ~= nil) and (now + d - 2) or nil
end

-- Is an entry still believed? Its own clock when the cast was seen, the
-- flat backstop for an effect whose cast never was. The entry itself is
-- KEPT until the wear-off, the death or the prune: a wear-off that comes
-- after we stopped believing is still a reading - the effect outlived the
-- learned clock - and it needs `at` to measure against.
local function live(f, now)
    if f.ends ~= nil then return now < f.ends end
    return now - f.at <= TARGET_EFFECT_AGE
end

-- Packet thread. One result line of one 0x028 aimed at one mob, from ANY
-- actor. `who` is the actor's side ('pet' | 'you' | 'other'); `spell` the
-- spell id when the action was a Magic Finish, else nil.
tm.noteMob = function(id, message, param, who, spell)
    local now = os.clock()
    -- the effect the spell applies, for the two messages that do not say
    local e = 0
    if spell ~= nil then
        local row = SPELL[spell]
        e = (row ~= nil and row.enfeeble ~= 0) and row.enfeeble or (tm.spellEffect[spell] or 0)
    end
    local on  = MSG_STATUS_ON[message] and param ~= nil and param > 0 and param < 0x400
    local off = MSG_STATUS_OFF[message] and param ~= nil
    if off then
        -- a dispel or an erase from anyone ends it as a wear-off does
        tm.mobWearOff(id, param)
        return
    end
    -- Only something that lands opens an entry: a Cure on a party member
    -- or a swing at a mob nobody has debuffed must not fill the table
    -- with empty rows (XIUI's does; it only ever clears on zone).
    if not (on or (e ~= 0 and (message == 75 or e == 134 or e == 135))) then return end
    local mob = tm.mobs[id]
    if mob == nil then
        mob = { fx = {}, seenAt = now }
        tm.mobs[id] = mob
        tm.mobPrune(now)   -- amortised: only when a NEW mob appears
    end
    mob.seenAt = now
    local fx = mob.fx
    if on then
        -- A landing, from anyone. A re-land on a live effect is a STRONGER
        -- caster's - status_effects.sql overwrites Paralysis, Blindness,
        -- Slow, Dia and Bio only for a higher power and Silence, Poison,
        -- Bind and Stun never - so it replaces the entry, restarts the
        -- clock, and `who` changes hands with it.
        fx[param] = { at = now, ends = clockFor(spell, now), spell = spell, who = who, src = 'landed' }
    elseif message == 75 and e ~= 0 then
        -- MAGIC_NO_EFFECT, "has no effect": the mob already carries it, or
        -- is immune (enfeebling_spell.lua sends 75 for both). The server's
        -- own CanUseEnfeeble answers no to the automaton either way, so
        -- this is the one way to learn of an effect that landed before we
        -- were in range. The book clock is an UPPER bound here: it has
        -- already been up for some unknown time.
        if fx[e] == nil or not live(fx[e], now) then
            fx[e] = { at = now, ends = now + (tm.spellDur[spell] or TARGET_EFFECT_AGE) - 2,
                      spell = spell, who = who, src = 'refused' }
        end
        return
    end
    if e == 134 or e == 135 then
        -- Dia and Bio announce NOTHING when they land: the cast is
        -- the only signal, and it is sound - the effect is added whatever
        -- the message, a full resist included. Each displaces the other
        -- only when it outranks it - see tm.diaBioLands.
        local other = (e == 134) and 135 or 134
        local held = fx[other] ~= nil and live(fx[other], now) and fx[other].spell or nil
        -- ...and the same family: a Dia into a live Dia II is refused by the
        -- server (overwrite HIGHER) and must not overwrite the entry here
        -- with a weaker tier and a fresh clock.
        local same = fx[e] ~= nil and live(fx[e], now) and fx[e].spell or nil
        local lands = tm.diaBioLands(spell, held, same)
        if lands ~= false then
            if lands == true then fx[other] = nil end
            fx[e] = { at = now, ends = clockFor(spell, now), spell = spell, who = who, src = 'cast' }
        end
    end
end

-- Packet thread. A wear-off - or a dispel, an erase - of one effect on one
-- mob: learn what it ran for, then forget it.
tm.mobWearOff = function(id, effect)
    local mob = tm.mobs[id]
    local f = mob and mob.fx[effect] or nil
    if f == nil then return end
    -- What it ACTUALLY ran for, landing -> wear-off on this one mob. Only
    -- the automaton's own landing counts, and only while nobody stronger
    -- has replaced it (a replacement rewrote `who`): a party member's
    -- Paralyze has its own skill and its own resist rate, and a Dia/Bio
    -- cast or a refused entry never saw a landing at all. The reading is
    -- keyed by the SPELL, not the effect - Poison and Poison II share
    -- effect 3 and run 90 and 120.
    if f.who == 'pet' and f.src == 'landed' and f.spell ~= nil then
        local d = os.clock() - f.at
        if d > 5 and d < 1200 then
            local seen = tm.seenDur[f.spell] or {}
            seen[#seen + 1] = d
            while #seen > 5 do table.remove(seen, 1) end
            tm.seenDur[f.spell] = seen
        end
    end
    mob.fx[effect] = nil
end

-- Keep the table about the camp, not the zone: past 48 mobs, drop any not
-- named for ten minutes with nothing live on it. Never the current target.
tm.mobPrune = function(now)
    local n = 0
    for _ in pairs(tm.mobs) do n = n + 1 end
    if n <= 48 then return end
    for id, mob in pairs(tm.mobs) do
        if id ~= tm.petTarget and now - mob.seenAt > 600 then
            local held = false
            for _, f in pairs(mob.fx) do
                if live(f, now) then held = true break end
            end
            if not held then tm.mobs[id] = nil end
        end
    end
end

-- Render thread: does the automaton's target carry this effect now?
local function targetHas(effect)
    local mob = tm.mobs[tm.petTarget]
    local f = mob and mob.fx[effect] or nil
    return f ~= nil and live(f, os.clock())
end
-- Packet thread: a cast starting closes the global window and its
-- rung's; a cast finishing sets the spell's own recast - the packet's
-- value when the server sent one, the table's otherwise.
tm.spellObserve = function(category, id, recast, now)
    local row = SPELL[id]
    if category == CAT_MAGIC_START then
        tm.windowAt.magic = now
        if row ~= nil then
            tm.windowAt[row.rung] = now
            -- The rung is the path the server took, not a property of the
            -- spell. Cure is in naSpells - its removes mask carries Sleep
            -- I, Sleep II and Lullaby - so TryStatusRemoval casts it and
            -- stamps m_LastStatusTime, never m_LastHealTime. It is the one
            -- row whose table rung and na-list rung disagree, and from the
            -- packet the two paths are indistinguishable. Stamp both: that
            -- can only suppress a prediction, never invent one.
            if id == 1 then tm.windowAt.status = now end
        end
    elseif category == CAT_MAGIC then
        -- The packet's own number when it is plausible, the table's when
        -- it is not. Unclamped, one bad 32-bit read pins that spell off
        -- the ladder for the rest of the session with nothing to show for
        -- it; the longest recast in the table is Dread Spikes at 180. Same
        -- house rule as noteMob's param bound above.
        local secs
        if recast ~= nil and recast > 0 and recast <= 600 then
            secs = recast
        else
            secs = (row and row.recast) or 0
            if recast ~= nil and recast > 600 then
                flagAnomaly('spell_recast_implausible', { spell_id = id, recast = recast })
            end
        end
        tm.spellRecast[id] = { at = now, secs = secs }
    end
    return row
end

-- Render thread. Seconds until a rung's window reopens under the head
-- worn now: 0 when open, nil when that head never tries the rung. Never
-- seen means open. Mana Booster shortens the magic window, Damage
-- Gauge the heal one (attachMods reads the live maneuver counts).
local function windowLeft(rung, head, counts)
    local w = WINDOWS[head or 0]
    if w == nil or w[rung] == nil then return nil end
    local at = tm.windowAt[rung]
    if at == nil then return 0 end
    local secs = w[rung]
    if rung == 'magic' and hasAttachment('Mana Booster') then
        local _, _, mods = attachMods('Mana Booster', counts)
        secs = secs - ((mods[1] and mods[1][3]) or 0)
    elseif rung == 'heal' and hasAttachment('Damage Gauge') then
        local _, _, mods = attachMods('Damage Gauge', counts)
        secs = secs - ((mods[2] and mods[2][3]) or 0)
    end
    return math.max(0, secs - (os.clock() - at))
end

local function spellRecastLeft(id)
    local r = tm.spellRecast[id]
    if r == nil then return 0 end
    return math.max(0, r.secs - (os.clock() - r.at))
end

-- Every window this head has, compactly: 'mag0/hea12/enf4'. The windows go
-- on the cast record, in the Spell line's hover and on Tuning: without them
-- a mispredict cannot be told from a rung the server never reached. Render
-- thread; the ladder calls it once a frame and
-- puts the result on the snapshot, so the record shows the windows as
-- they were when the prediction was made, not after the cast closed them.
local RUNGS = { 'magic', 'heal', 'enfeeble', 'elemental', 'enhance', 'status' }
local function windowSummary(head, counts)
    local parts = {}
    for _, rung in ipairs(RUNGS) do
        local left = windowLeft(rung, head, counts)
        if left ~= nil then
            parts[#parts + 1] = ('%s%d'):format(rung:sub(1, 3), math.ceil(left))
        end
    end
    return table.concat(parts, '/')
end

-- ---- the inputs, read once per prediction on the render thread ------
-- The automaton's MP as the interval its percent reading allows, published
-- on tm (mp, mpHi) with maxmp; `seen` is whether mpp is a reading at all.
local function publishMp(seen, mpp)
    -- The client reports the automaton's MP as an integer PERCENT, so a
    -- reading is a RANGE and not a number: 29% of 300 is anything from 87
    -- to 89, and a single point would call Cure IV (88) unaffordable when
    -- the server can cast it. LSB's GetMPP (battleentity.cpp:298) returns
    -- at least 1 for any positive MP, so 1% is its own case - it starts at
    -- 1, not at maxmp/100 - and 0% is exactly empty. tm.mp is the LOW end,
    -- tm.mpHi the high.
    -- CEILING at both ends, not floor. GetMPP is floor(100 * mp / maxmp),
    -- so mp >= maxmp*mpp/100 and mp < maxmp*(mpp+1)/100, and inverting
    -- those two bounds over the integers gives ceil and ceil-minus-one.
    -- Floor agrees only when maxmp*mpp/100 is a whole number - every
    -- multiple of 100 and nothing else. At maxmp 315 it puts the true value
    -- OUTSIDE the interval: 88 reads as 27%, floor gives [85,87], and Cure
    -- IV would be refused.
    if tm.auto044 == nil then
        tm.mp, tm.mpHi = nil, nil
    elseif not seen then
        -- The packet says how big the pool is and nothing says how full: the
        -- whole pool is the honest interval, so every pick inside it is
        -- affordable-but-unproven and marked so by usable(). Defaulting to
        -- 100% would publish [maxmp, maxmp] as a reading - a culled
        -- automaton read as a full pool, and a top tier named off it.
        tm.mp, tm.mpHi = 0, tm.auto044.maxmp
    else
        local maxmp, lo, hi = tm.auto044.maxmp, 0, 0
        if mpp >= 2 then
            lo, hi = math.ceil(maxmp * mpp / 100), math.ceil(maxmp * (mpp + 1) / 100) - 1
        elseif mpp == 1 then
            lo, hi = 1, math.ceil(maxmp * 2 / 100) - 1
        end
        tm.mp, tm.mpHi = lo, math.min(maxmp, math.max(lo, hi))
    end
    tm.maxmp = tm.auto044 and tm.auto044.maxmp or nil
end

local function gather(head, counts)
    local pet = petInfo() or {}
    local mhp, mmax = 0, 0
    safe(function()
        mhp  = AshitaCore:GetMemoryManager():GetParty():GetMemberHP(0) or 0
        mmax = player():GetHPMax() or 0
    end)
    -- The party, slots 1-5: the heal rung's third target and the enhance
    -- rung's party arm. GetMemberHPPercent is the direct answer for the
    -- percent (slot 0's is derived from HP/maxHP above, because IPlayer knows
    -- the master's maximum and IParty does not); the member's current HP
    -- beside it gives the missing HP a Cure tier is chosen from. A member at
    -- 0% is dead or out of the zone, and neither is a target. `fx` is the
    -- member's buffs off the last 0x076, nil until one has named them.
    local party, partyLow = {}, nil
    safe(function()
        local pty = AshitaCore:GetMemoryManager():GetParty()
        for i = 1, 5 do
            local active = pty:GetMemberIsActive(i)
            if active ~= nil and active ~= 0 and active ~= false then
                local p = pty:GetMemberHPPercent(i)
                if p ~= nil and p > 0 then
                    local sid = pty:GetMemberServerId(i) or 0
                    party[#party + 1] = { sid = sid, hpp = p, hp = pty:GetMemberHP(i) or 0,
                                          name = pty:GetMemberName(i) or ('member ' .. i),
                                          fx = tm.partyBuffs[sid] }
                    if partyLow == nil or p < partyLow then partyLow = p end
                end
            end
        end
    end)
    local masterHpp = (mmax > 0) and math.floor(mhp * 100 / mmax) or 100
    -- for the cast record, which the packet thread writes and which cannot
    -- read memory itself
    tm.partyNow, tm.youHpp = party, masterHpp
    local icons = safe(function() return player():GetStatusIcons() end, nil) or {}
    local master, masterList = {}, {}
    for i = 1, 32 do
        local id = icons[i]
        if id ~= nil and id > 0 and id < 0x400 then
            master[id] = true
            masterList[#masterList + 1] = id
        end
    end
    local now, petList = os.clock(), {}
    for id in pairs(petEffects) do
        if tm.petLive(id, now) then petList[#petList + 1] = id end
    end
    table.sort(petList)
    local dispelable = false
    local mob = tm.mobs[tm.petTarget]
    if mob ~= nil then
        for id in pairs(mob.fx) do
            if DISPELABLE[id] and targetHas(id) then dispelable = true break end
        end
    end
    -- the target's HP%, off the shared slot resolver the header's target
    -- row reads too. nil when the mob is out of the entity table.
    local mobHpp = safe(function()
        local slot = tm.mobSlot()
        if slot == nil then return nil end
        return AshitaCore:GetMemoryManager():GetEntity():GetHPPercent(slot)
    end, nil)
    local gauge = 0
    if hasAttachment('Damage Gauge') then
        local _, _, mods = attachMods('Damage Gauge', counts)
        gauge = (mods[1] and mods[1][3]) or 0
    end
    -- petInfo() is nil while the automaton is culled - resolveIds keeps its id
    -- and drops its entity index on purpose - or when the read failed, so
    -- `seen` is whether these percentages are a reading at all.
    local seen = pet.mpp ~= nil
    local hpp, mpp = pet.hpp or 100, pet.mpp or 100
    publishMp(seen, mpp)
    return {
        head = head, counts = counts,
        masterHpp = masterHpp,
        masterMissing = math.max(0, mmax - mhp),
        petHpp = hpp, petMpp = mpp,
        -- raw MP for the nuke tier. auto044.mp is only as fresh as the last
        -- 0x044; the percent is live, so derive from maxmp. Published on tm
        -- as well, because the cast record is written on the PACKET thread,
        -- which cannot read memory - and affordability is the one ladder
        -- input a log could never be checked against afterwards.
        petMp = tm.mp or 999,
        -- the other end of the same reading; equal to petMp only when the
        -- percent happens to name a single value
        petMpHi = tm.mpHi or 999,
        -- ...and whether that number is real. With no 0x044 the 999 is a
        -- placeholder, and it is the only fabricated input in ctx: it sets
        -- the nuke tier, so tryElemental flags its pick rather than naming
        -- a top-tier nuke in plain text off a made-up MP pool.
        mpKnown = tm.auto044 ~= nil and seen,
        petMissing = tm.auto044 and math.floor(tm.auto044.maxhp * (100 - hpp) / 100) or 0,
        masterHas = function(e) return master[e] == true end,
        masterList = masterList,
        petHas = function(e) return tm.petLive(e, now) end,
        petKnows = function(e) return tm.petKnown[e] == true end,
        petList = petList,
        mobHas = targetHas, mobDispelable = dispelable, mobHpp = mobHpp,
        party = party, partyLow = partyLow,
        -- APPROXIMATION: LSB's isEngaged is "the master is on THIS mob's
        -- enmity list and within 20 yalms", recomputed every tick. petTarget
        -- is the only engagement signal the client has, and timersClear
        -- returns it to 0 on every lifecycle edge - so this is true from the
        -- automaton's first action of an incarnation until it is dismissed,
        -- but it cannot go false mid-fight the way LSB's can. It is read in one place -
        -- tryEnhance's first() - so the divergence is confined to which
        -- entity a Protect/Shell/Haste/Stoneskin/Phalanx is predicted on,
        -- and only while the master has no enmity on the automaton's target
        -- or is out of range.
        -- LSB sets isEngaged whenever the target is a mob and the master
        -- is within 20 yalms, whatever the enmity list holds - so a fresh
        -- Deploy counts, even though petTarget still names the last mob
        -- the automaton actually acted on.
        engaged = tm.petTarget ~= 0 or tm.deployTo ~= nil,
        -- ...but the Regen target comes from the enmity list itself, and
        -- that one really is empty until somebody touches the mob - somebody
        -- the list is searched for: the master, the automaton, the party. A
        -- blow from one of them within TOUCH_AGE (tm.touched) says it is not
        -- empty; a Deploy alone says nothing about it.
        unengaged = tm.deployTo ~= nil
                    and (tm.touched[tm.deployTo] == nil or now - tm.touched[tm.deployTo] > TOUCH_AGE),
        -- AUTO_SCAN_RESISTS is {0,1,1,1} by ICE, not Earth: item_puppet's
        -- scanner element is 16, and ATTACH_ELEM already says Ice
        scanner = hasAttachment('Scanner') and (counts.Ice or 0) > 0,
        gauge = gauge,
    }
end

-- ---- the rungs. Each returns { id, rung, mode, why, uncertain } or nil.
-- TryHeal: the threshold from the Light count and Damage Gauge; the
-- master at or under it, else the automaton at or under half. With hate
-- the two checks swap, and hate is unreadable: both is 'you or automaton'.
-- The tier from missing HP, walked down to what the head can cast. In the
-- ambiguous branch the tier comes from the MASTER's missing HP - the
-- automaton's would give a different Cure - which is half of why that
-- pick is flagged uncertain.
-- The party arm departs from LSB (the assumptions doc, section 3). Upstream's
-- third target (automaton_controller.cpp tryHeal) needs a Light maneuver and
-- a master who does not need the cure; this model assumes a Soulsoother needs
-- neither. With no Light up it still cures a member at or under the
-- threshold, and a member lower than a master who also qualifies may take the
-- cure from them. Upstream picks the member by enmity, which is unreadable,
-- so the model names the LOWEST member, takes the tier from that member's own
-- missing HP, and flags the pick either way. An automaton at or under half
-- keeps the plain branches.
local function cureTier(missing)
    return (missing > 850 and 6) or (missing > 600 and 5) or (missing > 350 and 4)
        or (missing > 190 and 3) or (missing > 120 and 2) or 1
end
local function tryHeal(ctx, usable)
    local light = math.min(ctx.counts.Light or 0, 3)
    local thr = math.min(90, math.max(30, ({ [0] = 30, 40, 50, 75 })[light] + ctx.gauge))
    local master, pet = ctx.masterHpp <= thr, ctx.petHpp <= 50
    local member = nil
    if ctx.head == 5 and not pet then
        for _, m in ipairs(ctx.party or {}) do
            if m.hpp <= thr and (member == nil or m.hpp < member.hpp) then member = m end
        end
    end
    local why, missing, uncertain
    if member ~= nil and (not master or member.hpp < ctx.masterHpp) then
        -- HP beside HP% gives the member's maximum; with the HP unread the
        -- tier stays at its floor, which the flag already covers
        missing = (member.hp > 0) and math.floor(member.hp * (100 - member.hpp) / member.hpp) or 0
        why = master and ('heal · %s at %d%% · or you at %d%%'):format(member.name, member.hpp, ctx.masterHpp)
                      or ('heal · %s at %d%% (enmity picks who)'):format(member.name, member.hpp)
        uncertain = true
    elseif master or pet then
        local who = 'you'
        missing, uncertain = ctx.masterMissing, false
        if master and pet then who, uncertain = 'you or automaton', true
        elseif pet then who, missing = 'automaton', ctx.petMissing end
        why = ('heal · %s at %d%%'):format(who, master and ctx.masterHpp or ctx.petHpp)
        if member ~= nil then
            why, uncertain = ('%s · or %s at %d%%'):format(why, member.name, member.hpp), true
        end
    else
        return nil
    end
    for id = cureTier(missing), 1, -1 do   -- Cure .. Cure VI are spells 1..6
        if usable(id) then
            return { id = id, rung = 'heal', uncertain = uncertain,
                     mode = (light > 0) and 'maneuver' or 'default', why = why }
        end
    end
    return nil
end

-- TryEnfeeble: two lists, the promoted one walked first; a spell whose
-- effect the mob already carries is skipped (CanUseEnfeeble; immunity
-- is unreadable). Stormwaker's case offers Dispel alone. Spiritreaver
-- reaches its debuffs only with Dark up and promotes on two of an
-- element; its Aspir and Drain hinge on the mob's MP and family.
local ELEMENT_OF = { [231] = 'Dark', [230] = 'Dark', [254] = 'Dark', [24] = 'Light', [23] = 'Light',
                     [221] = 'Water', [220] = 'Water', [59] = 'Wind', [56] = 'Earth', [58] = 'Ice', [286] = 'Fire' }
local function tryEnfeeble(ctx, usable)
    local c, cast, dflt, note = ctx.counts, {}, {}, {}
    local function put(promoted, ...)
        local list = promoted and cast or dflt
        for _, id in ipairs({ ... }) do list[#list + 1] = id end
    end
    local function n(el) return c[el] or 0 end
    local mob = ctx.mobHas
    if ctx.head == 4 then
        if ctx.mobDispelable then
            put(true, 260)
            note[260] = { why = 'enfeeble · the target carries a dispelable effect' }
        end
    elseif ctx.head == 6 then
        if ctx.petMpp < 75 then
            put(true, 248, 247)
            note[248] = { why = 'enfeeble · automaton MP under 75%', uncertain = true }
            note[247] = note[248]
        end
        if ctx.petHpp < 75 then
            put(true, 245)
            note[245] = { why = 'enfeeble · automaton HP under 75%', uncertain = true }
        end
        if n('Dark') > 0 then
            if not ctx.petHas(84) then put(false, 270) end
            put(false, 254)
            if not mob(134) then put(false, 231) end
            if not mob(135) then put(n('Light') >= 2, 24) end
            if not mob(134) then put(false, 230) end
            if not mob(135) then put(n('Light') >= 2, 23) end
            put(n('Water') >= 2, 221, 220)
            put(n('Wind') >= 2, 59)
            put(n('Earth') >= 2, 56)
            put(n('Ice') >= 2, 58)
            put(n('Fire') >= 2, 286)
        end
    elseif ctx.head == 5 then
        put(n('Earth') > 0, 56)
        put(n('Water') > 0, 221, 220)
        put(n('Dark') > 0, 254)
        if not mob(134) then put(n('Dark') > 0, 231) end
        if not mob(135) then put(n('Light') > 0, 24) end
        if not mob(134) then put(n('Dark') > 0, 230) end
        if not mob(135) then put(n('Light') > 0, 23) end
        put(n('Wind') > 0, 59)
        put(n('Ice') > 0, 58)
        put(n('Fire') > 0, 286)
    else   -- Harlequin, Sharpshot
        if not mob(134) then put(n('Dark') > 0, 231) end
        if not mob(135) then put(n('Light') > 0, 24) end
        if not mob(134) then put(n('Dark') > 0, 230) end
        if not mob(135) then put(n('Light') > 0, 23) end
        put(n('Water') > 0, 221, 220)
        put(n('Wind') > 0, 59)
        put(n('Earth') > 0, 56)
        put(n('Dark') > 0, 254)
        put(n('Ice') > 0, 58)
        put(n('Fire') > 0, 286)
    end
    local function pick(list, promoted)
        for _, id in ipairs(list) do
            local row, nt = SPELL[id], note[id]
            if (row.enfeeble == 0 or not mob(row.enfeeble)) and usable(id) then
                local el = ELEMENT_OF[id]
                local why = (nt and nt.why)
                    or (promoted and el and ('enfeeble · %s x%d'):format(el, n(el)))
                    or 'enfeeble · list order'
                return { id = id, rung = 'enfeeble', why = why,
                         mode = (promoted and nt == nil) and 'maneuver' or 'default',
                         uncertain = nt ~= nil and nt.uncertain == true }
            end
        end
        return nil
    end
    return pick(cast, true) or pick(dflt, false)
end

-- TryElemental: the tier from the automaton's MP; the target's raw HP,
-- the other ladder, is unreadable and can only lower it, so the pick is
-- marked uncertain once the target is at half or below. Element by list
-- order, a maneuver promoting its own on Spiritreaver - EXCEPT with Scanner
-- and Ice up, where LSB re-sorts the whole list by the target's resistance
-- ranks and promotes nothing (the three branches are one if/else-if chain),
-- and that order is unreadable. An unknown target HP falls into the
-- uncertain branch too, which is what we want.
-- KNOWN GAP: LSB's HP rungs are raw (hp <= 50 / 150 / 200 / 600), and
-- 600 HP is reachable well above 50%. A mob at 55% of 1000 gets tier 3
-- there and tier 4 here, and this marks it certain. It only changes the
-- pick once the magic skill reaches a tier-3 nuke (Stone III, 227), so
-- it is left as is - if the mispredicts say otherwise, widen the flag to
-- "uncertain whenever the tier came from MP alone".
local NUKES = { { 164, 'Thunder' }, { 149, 'Ice' }, { 144, 'Fire' }, { 154, 'Wind' }, { 169, 'Water' }, { 159, 'Earth' } }
-- These boundaries ARE the cheapest nuke of each tier: the tier-3 gate is
-- 88 and Stone IV costs exactly 88. So the tier decides which spells the
-- loop below ever VISITS, and taking it from the low end of the MP
-- interval alone would put every tier-3 nuke out of reach before usable()
-- is asked - which no affordability test can then recover. Read from the
-- high end and let usable() do the filtering it already does; when the two
-- ends disagree about the tier, say so rather than name a tier-2 nuke flatly.
tm.nukeTier = function(mp)
    return (mp < 16 and 0) or (mp < 40 and 1) or (mp < 88 and 2) or (mp < 156 and 3) or 4
end
local function tryElemental(ctx, usable)
    if ctx.petMpHi < 4 then return nil end
    local tier = tm.nukeTier(ctx.petMpHi)
    -- The two ends of the MP interval disagree about the tier, so the
    -- alternative is known exactly: the pick the low end would have made.
    local spread = tier ~= tm.nukeTier(ctx.petMp)
    local cast, dflt = {}, {}
    for _, e in ipairs(NUKES) do
        -- `not ctx.scanner`: with AUTO_SCAN_RESISTS up LSB never reaches the
        -- Spiritreaver arm, so no maneuver promotes anything - list order
        -- stands in for the resistance sort and the pick is flagged below.
        if not ctx.scanner and ctx.head == 6 and (ctx.counts[e[2]] or 0) > 0 then
            cast[#cast + 1] = e
        else
            dflt[#dflt + 1] = e
        end
    end
    -- ...and with no 0x044 the tier came from gather's placeholder MP, which
    -- is not a reading at all - the same class of unknown as the Scanner sort.
    local unsure = ctx.scanner or (ctx.mobHpp or 0) <= 50 or not ctx.mpKnown or spread
    for i = tier, 0, -1 do   -- Thunder .. Thunder V are contiguous ids
        for _, e in ipairs(cast) do
            if usable(e[1] + i) then
                return { id = e[1] + i, rung = 'elemental', mode = 'maneuver', uncertain = unsure,
                         mpUnsure = spread or nil,
                         why = ('nuke · %s x%d, tier by MP'):format(e[2], ctx.counts[e[2]]) }
            end
        end
        for _, e in ipairs(dflt) do
            if usable(e[1] + i) then
                return { id = e[1] + i, rung = 'elemental', mode = 'default', uncertain = unsure,
                         mpUnsure = spread or nil,
                         why = ctx.scanner and 'nuke · Scanner picks by resistance' or 'nuke · list order, tier by MP' }
            end
        end
    end
    return nil
end

-- TryEnhance: Regen on whoever holds the most hate (unreadable: the
-- master unless it already has one), then Protect, Shell, Haste on the
-- first of master and automaton lacking it, Stoneskin and Phalanx on the
-- master. Spiritreaver: Dread Spikes alone. Protectra / Shellra V need
-- skill 425 / 434, past any era cap, so they are not modelled.
-- The Regen goes to ONE entity - the single highest-enmity one - and is
-- skipped outright if that one already has it. There is no fall-through:
-- the master can go minutes without one while the automaton is re-Regened
-- again and again, and take a Haste from the same ladder in the meantime -
-- engaged, in range and eligible, just not the Regen target.
-- Enmity is unreadable, so the model sees three states:
--   both lack one  -> a Regen comes
--   both have one  -> no Regen
--   one lacks one  -> sometimes, sometimes not
-- That last state is the whole residual, and it is not resolvable: it
-- turns on whether hate MOVED since the last Regen. What decides it is
-- whether hate is contested at all - an automaton that holds it throughout
-- leaves the master without, two sides that trade it both get one - and
-- that IS readable, from which sides the server has lately chosen.
-- So: skip the Regen there either way (the model's default), but when the
-- side lacking one has itself been Regened in the last five minutes, say
-- that a Regen may take the window instead of pretending to know. The flag
-- lands where the doubt is and stays off the predictions that are fine.
local function tryEnhance(ctx, usable)
    if ctx.head == 6 then
        if usable(277) then return { id = 277, rung = 'enhance', mode = 'maneuver', why = 'enhance · Dark' } end
        return nil
    end
    local m, p = ctx.masterHas, ctx.petHas
    local mHas, pHas = m(42), p(42)
    local hedge = nil
    if ctx.unengaged then
        -- Deployed onto a mob nobody has touched. TryEnhance chooses its
        -- Regen target by walking that mob's ENMITY LIST - master, then
        -- automaton, then the party - and an untouched mob's list is
        -- empty, so PRegenTarget stays null and no Regen is cast at all,
        -- whoever is or is not carrying one. isEngaged is a different
        -- test and is still true, so Protect, Shell and Haste are
        -- unaffected and the rung simply starts there. Seen on a
        -- Soulsoother: Deploy onto an unengaged mob, and the server casts
        -- Protect, not Regen.
    elseif #(ctx.party or {}) > 0 then
        -- In a party the Regen candidates are the master, the automaton and
        -- every member on the mob's hate list (LSB TryEnhance's party loop),
        -- and the single highest-enmity one is the target. Enmity is
        -- unreadable, so only the two ends are certain: a Regen comes when
        -- nobody has one and never when everybody does. Anything between -
        -- and a member no 0x076 has named counts as either - may go either
        -- way, and is hedged as the solo case is.
        local lack, have = not (mHas and pHas), mHas or pHas
        for _, mem in ipairs(ctx.party) do
            if mem.fx == nil then lack, have = true, true
            elseif mem.fx[42] then have = true
            else lack = true end
        end
        if lack and not have then
            for _, id in ipairs({ 111, 110, 108 }) do
                if usable(id) then
                    return { id = id, rung = 'enhance', mode = 'default', uncertain = true,
                             why = 'enhance · no Regen on anyone (hate picks who)' }
                end
            end
        elseif lack then
            hedge = ' · or a Regen, if hate is on someone without one'
        end
    elseif not mHas and not pHas then
        for _, id in ipairs({ 111, 110, 108 }) do
            if usable(id) then
                return { id = id, rung = 'enhance', mode = 'default', uncertain = true,
                         why = 'enhance · no Regen on you or automaton (hate picks which)' }
            end
        end
    elseif not (mHas and pHas) then
        -- Exactly one side is without a Regen. A Regen is coming only if
        -- hate has moved to it, so the question is whether hate moves at
        -- all here. Five minutes covers several cycles: a Regen runs about
        -- a minute and the ladder re-casts at the first window after it
        -- drops, so a side that is genuinely in contention reappears well
        -- inside it.
        -- Hedge on a FRESH reading for that side, and also on NO reading
        -- at all: silence is not evidence. Only a STALE reading is - it
        -- means we have been watching and the server has not chosen that
        -- side in five minutes. The distinction earns its keep after an
        -- Activate, which clears the reading with the rest of what we knew
        -- about the automaton, and the fresh automaton may be Regened
        -- straight away. Hedging on no reading takes Regens out from behind
        -- confident calls at the cost of a few extra hedges.
        local side = (not mHas) and 'you' or 'automaton'
        local at = tm.regenAt[side]
        if at == nil or (os.clock() - at) <= 300 then
            hedge = (' · or a Regen, if hate has moved back to %s')
                    :format(side == 'you' and 'you' or 'the automaton')
        end
    end
    local function first(ids, effect, label, masterOnly)
        -- The master's arm reads real status icons. The automaton's is
        -- inferred, and inference starts EMPTY on every load - nothing
        -- announces its buffs - so an unread effect there means "no idea",
        -- not "not on". Offering it anyway is a bet that the automaton is
        -- unbuffed, which after a reload with an automaton out is exactly
        -- backwards: Protect and Shell run thirty minutes and are almost
        -- certainly already up. Offering them would call Protect then Shell
        -- for the automaton while the server, which knows both are on it,
        -- buffs the master instead.
        -- So wait for a reading. The ladder simply moves down, and one
        -- arrives quickly: every landing, every wear-off and every enhance
        -- cast above the rung is one.
        local target, unsure = nil, nil
        if ctx.engaged and not m(effect) then target = 'you'
        elseif not masterOnly and ctx.petKnows(effect) then
            if not p(effect) then target = 'automaton'
            else
                -- LSB's party arm: the first member, in party order, on the
                -- mob's hate list and without it. The hate list is unreadable,
                -- so a member without it is named and the pick flagged; a
                -- member whose buffs no 0x076 has named is passed over, not
                -- guessed at.
                for _, mem in ipairs(ctx.party or {}) do
                    if mem.fx ~= nil and not mem.fx[effect] then
                        target, unsure = mem.name, true
                        break
                    end
                end
            end
        end
        if target == nil then return nil end
        for _, id in ipairs(ids) do
            if usable(id) then
                return { id = id, rung = 'enhance', mode = 'default', uncertain = unsure,
                         why = ('enhance · no %s on %s'):format(label, target) }
            end
        end
        return nil
    end
    local r = first({ 47, 46, 45, 44, 43 }, 40, 'Protect')
        or first({ 52, 51, 50, 49, 48 }, 41, 'Shell')
        or first({ 511, 57 }, 33, 'Haste')
        or first({ 54 }, 37, 'Stoneskin', true)
        or first({ 106 }, 116, 'Phalanx', true)
    -- The Regen sits above all of these, so a hate move preempts whatever
    -- they chose - and equally, whatever the rungs BELOW this one chose,
    -- or the silence when nothing chose anything. Publish it for
    -- predictSpell to place; decorating only the pick made here would leave
    -- the 'nothing to cast' lines bare, which is exactly where a Regen
    -- lands.
    tm.regenHedge = hedge
    return r
end

-- TryStatusRemoval: the master's effects, then the automaton's; for each
-- the -na whose list names it (Cure's names Sleep), else Erase when the
-- effect is erasable. (The Water + party branch is out of scope.)
local NA = { 1, 14, 15, 16, 17, 18, 19, 20 }
local function naFor(effect)
    for _, id in ipairs(NA) do
        for _, e in ipairs(SPELL[id].removes) do
            if e == effect then return id end
        end
    end
    if ERASABLE[effect] then return 143 end
    return nil
end
local function tryStatus(ctx, usable)
    for _, side in ipairs({ { ctx.masterList, 'you' }, { ctx.petList, 'automaton' } }) do
        for _, effect in ipairs(side[1]) do
            local id = naFor(effect)
            if id ~= nil and usable(id) then
                return { id = id, rung = 'status', mode = 'default',
                         why = ('status · effect %d on %s'):format(effect, side[2]) }
            end
        end
    end
    return nil
end

-- ---- TrySpellcast: the ladder per head, first open rung that finds a
-- castable spell wins. Returns name, why, mode, rung; name nil when
-- nothing casts and why says why. mode: 'maneuver' a maneuver chose it,
-- 'default' the list order did, 'uncertain' an unreadable input decides,
-- 'closed' no window is open, 'none' this frame or head never casts.
-- CanCastSpells' own gates, ahead of every rung: silence and mute are
-- named outright, and the check ends with CanChangeState(), so sleep,
-- lullaby, stun, petrification and terror stop the ladder the same way.
-- Read through tm.petLive rather than ctx.petHas: this check runs before
-- gather() builds ctx.
local HELD = { [6] = 'silenced', [29] = 'muted', [2] = 'asleep', [19] = 'asleep',
               [193] = 'asleep', [10] = 'stunned', [7] = 'petrified', [28] = 'terrified' }

-- Names for the log, resolved on this thread: the packet thread that
-- writes the record must not touch the resource manager. Gated on Cure
-- resolving, not on the table being empty - spellName falls back to
-- 'spell <id>', which is a perfectly non-nil value, so filling from a
-- frame where the resource manager is not up yet would pin bare ids
-- into every record for the rest of the session. Probing ONE id and
-- not all 81 keeps the retry at a single native call a frame, and
-- leaves a spell the client genuinely has no name for (an era-locked
-- resource file) logging as 'spell <id>' without re-running the fill.
local function fillNames()
    if tm.names[1] == nil then
        local cure = tm.spellName(1)
        if cure ~= 'spell 1' then
            for id in pairs(SPELL) do tm.names[id] = tm.spellName(id) end
        end
    end
end

-- The gates ahead of every rung: the frame, the head, then HELD. Returns
-- the head, or nil with the why and mode that stop the ladder.
local function gate()
    local frame, head = tm.frameNow(), tm.currentHead()
    if frame ~= 'Harlequin' then return nil, 'this frame never casts', 'none' end
    if head == nil then return nil, 'no head yet', 'none' end
    local now = os.clock()
    for e, word in pairs(HELD) do
        if tm.petLive(e, now) then
            -- 'closed', not 'none': the line still shows, saying why
            return nil, ('the automaton is %s'):format(word), 'closed'
        end
    end
    return head
end

-- Seconds left on each rung this head has. The live call also publishes
-- the compact summary of them as tm.windows.
local function readWindows(head, counts, isLive)
    local left = {}
    for rung in pairs(WINDOWS[head]) do left[rung] = windowLeft(rung, head, counts) end
    -- LIVE ONLY. The packet thread reads tm.windows when it writes a
    -- pet_spell record, so a sidebar frame that published its hypothetical
    -- here would stamp every cast record with some other element's windows -
    -- silently, and only visible much later as an unexplainable log.
    if isLive then
        tm.windows = windowSummary(head, counts)   -- for the snapshot, the hover and the record
    end
    return left
end

-- One prediction's working state: the head, ctx, the windows, the three
-- maneuvers the ladders branch on, and the usable() every rung is handed.
local function newPrediction(head, counts, left, ctx)
    local pred = {
        head = head, ctx = ctx, left = left,
        light = (counts.Light or 0) > 0, ice = (counts.Ice or 0) > 0, dark = (counts.Dark or 0) > 0,
        -- `anyRung` runs the ladder as if every window were already open,
        -- which is what answers "and what happens when it is?". It is set for
        -- the one preview walk in idleAnswer and never while a real answer is
        -- being made.
        anyRung = false,
        -- whether the last spell usable() passed was affordable only on the
        -- high end of the MP reading
        mpEdge = false,
    }
    -- canCast is CanUseSpell (head bit + skill); the recast is Cast()'s
    -- HasRecast; the MP is its CanAffordSpell. With no 0x044 there is no
    -- MP to gate on, so predict optimistically - the same rule canCast
    -- uses for the skill, and it keeps gather's petMp fallback of 999
    -- from being read as a real reading.
    -- The MP reading is an interval (see gather). A cost below its low end
    -- is affordable, one above its high end is not, and one BETWEEN them
    -- is affordable-but-unproven: answer yes and mark the row, rather than
    -- silently dropping a tier the server may well have cast.
    pred.usable = function(id)
        pred.mpEdge = false
        if not canCast(id) or spellRecastLeft(id) > 0 then return false end
        if tm.auto044 == nil then return true end
        local mp = SPELL[id].mp or 0
        if ctx.petMp >= mp then return true end
        if ctx.petMpHi < mp then return false end
        pred.mpEdge = true
        return true
    end
    return pred
end

-- Is this rung's window open for the walk? Every one is, on the preview.
local function isOpen(pred, rung)
    return pred.anyRung or (pred.left[rung] ~= nil and pred.left[rung] <= 0)
end

-- TrySpellcast's rung order for the head worn: the first open rung whose
-- try function makes a pick wins. Returns that pick, or nil.
local function walk(pred)
    local head, ctx, usable = pred.head, pred.ctx, pred.usable
    local light, ice, dark = pred.light, pred.ice, pred.dark
    local function rung(name, fn)
        if isOpen(pred, name) then return fn(ctx, usable) end
        return nil
    end
    if head == 2 then
        return rung('heal', tryHeal)
    elseif head == 1 or head == 3 then
        return (light and rung('heal', tryHeal)) or rung('enfeeble', tryEnfeeble)
            or (not light and rung('heal', tryHeal)) or nil
    elseif head == 4 then
        local function ladder(low)
            return (low and rung('elemental', tryElemental))
                or (light and rung('heal', tryHeal))
                or (not low and ice and rung('elemental', tryElemental))
                or rung('enfeeble', tryEnfeeble)
                or (not light and rung('heal', tryHeal))
                or (not low and not ice and rung('elemental', tryElemental))
                or rung('enhance', tryEnhance) or nil
        end
        -- the low-HP nuke needs the target under 30% AND under 300 HP;
        -- only the percent is readable, so at 30% both branches are said
        local maybeLow = ctx.mobHpp ~= nil and ctx.mobHpp <= 30
        local r = ladder(maybeLow)
        if maybeLow and r ~= nil and r.rung == 'elemental' then
            -- The alternative is named by a second walk, whose usable()
            -- calls reset mpEdge: keep the real pick's reading, or the row
            -- was marked mpUnsure (or not) by Dispel's affordability.
            local edge = pred.mpEdge
            local alt = ladder(false)
            pred.mpEdge = edge
            r.uncertain = true
            r.why = ('nuke if the target is under 300 HP, else %s'):format(alt and tm.spellName(alt.id) or 'nothing')
        end
        return r
    elseif head == 5 then
        return (light and rung('heal', tryHeal)) or rung('status', tryStatus)
            or (not light and rung('heal', tryHeal)) or rung('enhance', tryEnhance)
            or rung('enfeeble', tryEnfeeble) or nil
    elseif head == 6 then
        return (ice and rung('elemental', tryElemental)) or (dark and rung('enhance', tryEnhance))
            or ((dark or ctx.petHpp < 75 or ctx.petMpp < 75) and rung('enfeeble', tryEnfeeble))
            or (not ice and rung('elemental', tryElemental)) or nil
    end
    return nil
end

-- Marks the pick with what the model cannot prove about it, and returns
-- the Regen hedge the enhance rung left.
local function markDoubts(pred, r)
    -- The spell whose cost fell INSIDE the MP interval is affordable on the
    -- reading's high end and not on its low one, so the pick stands but is
    -- not proven. Every usable() call site returns its row immediately
    -- after a true answer, so the last true answer is the one behind `r`.
    if pred.mpEdge and r ~= nil then r.uncertain, r.mpUnsure = true, true end
    -- A Regen is the FIRST thing the enhance rung tries, so it preempts
    -- anything the server would otherwise reach below it: the enhance
    -- pick itself, the enfeeble pick on a head that tries enfeeble after
    -- enhance (Soulsoother alone), and the silence when there is no pick.
    -- No rung test is needed to keep it off a heal or a status removal.
    -- The ladders are `or` chains, so tryEnhance runs at all only when
    -- every rung above it has already declined - which makes a non-nil
    -- hedge proof that whatever `r` holds came from the enhance rung or
    -- below it. A shut enhance window never calls tryEnhance either, and
    -- leaves the hedge nil, which is the right answer: nothing can come
    -- from a rung that is closed.
    local hedge = tm.regenHedge
    if hedge ~= nil and r ~= nil then
        r.uncertain, r.why = true, r.why .. hedge
    end
    return hedge
end

-- The answer when nothing casts now: the windows still shut and what the
-- ladder names once they open. Returns predictSpell's no-spell tuple.
local function idleAnswer(pred, magicShut, hedge)
    local left = pred.left
    local waits = {}
    for _, name in ipairs({ 'heal', 'enfeeble', 'elemental', 'enhance', 'status' }) do
        if left[name] ~= nil and left[name] > 0 then
            waits[#waits + 1] = ('%s %ds'):format(name, math.ceil(left[name]))
        end
    end
    -- Nothing is castable NOW, so run the ladder again with the
    -- windows ignored: whatever it names is what the wait is for.
    -- Read off the state as it stands, which is the honest caveat -
    -- an effect wearing off or a Regen expiring in the meantime moves
    -- it, exactly as it moves any other prediction. It is a preview,
    -- so it stays in the reason and never becomes the predicted name:
    -- the packet thread compares a cast against that name, and a
    -- preview standing in for it would turn a genuine miss into a hit.
    local queued = nil
    if magicShut or #waits > 0 then
        pred.anyRung = true
        queued = walk(pred)
        -- The preview must leave nothing of itself behind. tm.regenHedge
        -- is the slot tryEnhance writes, so it is put back to what the
        -- real pass found; the answer itself is built from the `hedge`
        -- argument, taken before the preview ran, so a "none ready" line
        -- never claims a Regen warning it does not show. anyRung is not
        -- put back: pred belongs to this call, and every path out of this
        -- block returns.
        tm.regenHedge = hedge
    end
    local behind = (queued ~= nil) and (' -> then ' .. tm.spellName(queued.id)) or ''
    if magicShut then
        return nil, ('none ready - magic window %ds%s'):format(math.ceil(left.magic), behind),
               'closed', nil, hedge
    end
    -- Self-contained: spellLine draws this ALONE when there is no
    -- spell name, so a bare wait list would read as a fragment and
    -- 'nothing to cast' behind a 'none ready' placeholder read as a
    -- stutter. Every no-spell why says the whole thing itself.
    if #waits > 0 then
        return nil, 'none ready - ' .. table.concat(waits, ' · ') .. (hedge or '') .. behind,
               'closed', nil, hedge
    end
    return nil, 'nothing to cast' .. (hedge or ''), 'closed', nil, hedge
end

-- `counts` and `ctxIn` are the sidebar's hypothetical inputs. Omitting
-- counts is the live call, and only the live call publishes tm.windows. ctxIn lets the sidebar pay for gather() once a frame
-- and hand back eight clones of it, which is the whole reason eight
-- predictions a frame are affordable.
tm.predictSpell = function(counts, ctxIn)
    local isLive = (counts == nil)   -- the frame's own prediction, not a sidebar hypothetical
    fillNames()
    -- Cleared BEFORE the gates below, not after them, so a pass that stops
    -- at one leaves no hedge from a prior pass standing.
    -- Set by tryEnhance when a Regen may take the window; nil when the
    -- enhance rung never ran, which is the right answer for a shut enhance
    -- window - nothing can come from a rung that is closed.
    tm.regenHedge = nil
    local head, stopWhy, stopMode = gate()
    if head == nil then return nil, stopWhy, stopMode, nil end
    counts = counts or maneuverCounts()
    local left = readWindows(head, counts, isLive)
    local pred = newPrediction(head, counts, left, ctxIn or gather(head, counts))
    -- The magic window gates every rung at once, so a shut one has nothing
    -- to say beyond the wait - but there IS something behind it, and
    -- idleAnswer's preview names it.
    local magicShut = not isOpen(pred, 'magic')
    local r = nil
    if not magicShut then r = walk(pred) end
    local hedge = markDoubts(pred, r)
    if r == nil then return idleAnswer(pred, magicShut, hedge) end
    -- The hedge is RETURNED rather than left on tm for the caller to read:
    -- the sidebar's hypothetical ladders run after the live publish and
    -- set tm.regenHedge themselves, so a shared slot could only ever be
    -- read one frame too late.
    -- ...and WHY it is uncertain, where the answer is the MP reading. That
    -- is the one uncertainty whose alternative the model knows exactly -
    -- the tier or the spell the interval's low end would have chosen - so
    -- it is the one a miss can be excused by. Every other `uncertain` is
    -- about something orthogonal to the spell's identity (which party
    -- member a Cure goes to, which side gets a Regen, the element a
    -- Scanner sort picks) and is judged as a plain uncertain pick.
    return tm.spellName(r.id), r.why, r.uncertain and 'uncertain' or r.mode, r.rung,
           hedge, r.mpUnsure
end

-- The ladder's published tables and helpers, read by inbound.lua, the panel,
-- the what-if sidebar and the offline tests' api (test/fixtures/load.lua).
tm.fn = { canCast = canCast, windows = WINDOWS, row = function(id) return SPELL[id] end,
          erasable = ERASABLE, dispelable = DISPELABLE,
          windowLeft = windowLeft, spellRecastLeft = spellRecastLeft, targetHas = targetHas,
          windowSummary = windowSummary,
          -- the sidebar's base context, paid for once a frame and cloned
          gather = gather }

return {}
