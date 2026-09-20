-- cw/config.lua - the defaults: the burden model's constants, the
-- logging switches and the display options; returns the table. Edit a value,
-- then /addon reload clockwork. The exception is every key in cw/settings.lua's
-- PERSIST list (the Settings tab's switches, ui_scale, warn_at): the Settings
-- tab writes those into this table, and a saved settings file overrides them.
local config =
{
    -- Burden model ------------------------------------------------------
    threshold      = 30,   -- LSB base. OVERLOAD_THRESH gear is NOT added here: it
                           -- is read off the hands/neck worn when each maneuver
                           -- resolves (OVERLOAD_GEAR), because a gear profile may
                           -- swap the AF gloves in and out around the maneuver.
    decay_per_tick = 1,    -- LSB base. The AF gloves are not decay: LSB item_mods
                           -- 14930 is OVERLOAD_THRESH +5. Heatsink is heatsink_decay.
    tick_seconds   = 3.0,
    -- Heatsink as this model assumes it works on Horizon: no passive effect,
    -- and while Water maneuvers are up EVERY element decays this much faster
    -- per tick, indexed by the number of Water maneuvers active. [0] = 0 and
    -- [1] = +1 are model overrides; [2] and [3] follow a community report
    -- ("2 / 3 / 4 per tick vs base 1"). All four are provisional - a
    -- burden_mismatch with water_ticks > 0 says when one is wrong. Upstream
    -- LSB's table is {1,3,4,5} with a passive +1; this model does not use it.
    heatsink_decay = { [0] = 0, [1] = 1, [2] = 2, [3] = 3 },
    -- "needs Heatsink" is the community's attribution (Condenser and a bare
    -- Water maneuver do not touch burden), not something this model checks.
    -- To test: unequip Heatsink, use a Water maneuver, read a Fire chance
    -- 30-60s later. false = the Water maneuver alone does it.
    heatsink_required = true,
    -- burden per maneuver when your stat is below the automaton's; a won
    -- check costs 5 less. Dark compares MP and uses dark_cost.
    default_cost   = 20,
    dark_cost      = 15,
    -- Deus Ex Automata "unsound state": this model takes it as heavy burden
    -- on arrival and seeds 105 on every element (upstream LSB's DEA adds
    -- none). Provisional: burden_reseed logs implied_seed on the maneuver that
    -- follows a DEA, so the seed can be checked against any log.
    dea_burden     = 105,
    -- A plain Activate. Upstream builds a zero-burden automaton; this model
    -- assumes a Horizon Activate seeds every element and decays from there,
    -- rather than carrying the previous automaton's values over. 29 sits just
    -- under the base threshold of 30, so the first maneuver after an Activate
    -- resolves at a few percent rather than at zero. Provisional, like
    -- dea_burden: a seed set too low shows as every first-maneuver reading
    -- erring NEGATIVE while VERIFIED maneuvers sit at err 0; a reading taken
    -- long after the Activate leans on the decay estimate and back-solves
    -- lower, so the ones near it are the ones to calibrate from.
    -- Seeded unverified, like dea_burden, and TIMED: the Activate is caught in
    -- the 0x028 stream and the first maneuver of each element after it logs
    -- since_activate, pre_cast and implied_seed. A CENSORED reading (actualPct
    -- 0) is an upper bound, not a measurement - ignore those when calibrating.
    -- nil = carry the previous values over unchanged, and still log the timing.
    activate_burden = 29,

    -- Stat check: LSB charges 20 burden if YOUR stat is below the automaton's,
    -- 15 if you meet or beat it (Dark compares MP: 15 / 10). nil = work it out:
    -- your stat against the automaton's from the 0x044 packet, or inferred from
    -- verified burden readings until one arrives; the panel says which
    -- (tm.costSource). 'lose' = your stat is lower, 'win' = you meet or beat
    -- it: either pins the cost, for when the automaton's status window and the
    -- computation disagree.
    --
    -- A NUMBER is the stat you are WEARING when that element's maneuver goes
    -- off - a gear-swap set's, say. The client cannot be asked for it: a swap
    -- does not refresh your stats, so the value in memory is whatever you wore
    -- at the last refresh (the equipment menu, a level, a kill), and a maneuver
    -- set's stats never reach it. The number is compared against the
    -- automaton's LIVE stat, so it still wins the first check of an element and
    -- loses once that element is stacked - which 'win' and 'lose' cannot say.
    -- Set it in game with `/cw stat <element> <number|now|off>`, which
    -- remembers it in settings.txt; editing it here is the same thing without
    -- the file. Dark is ignored - it compares MP, which is read live.
    stat_check =
    {
        Fire = nil,      -- STR
        Ice  = nil,      -- INT
        Wind = nil,      -- AGI
        Earth = nil,     -- VIT
        Thunder = nil,   -- DEX
        Water = nil,     -- MND
        Light = nil,     -- CHR
        Dark = nil,      -- MP
    },

    -- Feedback / logging ------------------------------------------------
    -- Every switch in this block is OFF by default: nothing is written to disk
    -- or printed to chat until the player turns it on from the Settings tab.
    logging        = false,
    log_all_casts  = false, -- abilities and casts are always logged; true adds unrecognised pet skill ids
    -- Anomalies are reported on two independent channels, because they answer
    -- different questions. The chat line is immediate and is what makes
    -- watching the model worthwhile; the file is the dataset the model is
    -- corrected from afterwards.
    -- anomaly_file is NOT gated on `logging`: false/true is the quiet-disk mode
    -- - routine records (every maneuver, every cast, every ability) stop, and
    -- only the cases where the model was wrong are still written. That is the
    -- whole log a mispredict investigation needs.
    anomaly_chat   = false,
    anomaly_file   = false,
    -- Say so in chat when a prediction LANDS, not only when it misses. Without
    -- it a working prediction is silent - it goes to the log as pet_spell /
    -- pet_ws and nothing else - while a miss shouts, so in game the feature
    -- looks like it only ever fails. Worth turning on alongside anomaly_chat
    -- while checking the model against your own play.
    debug_predictions = false,
    -- The reason behind a prediction: the dim tail after the spell or the
    -- weaponskill on the HUD ('heal - you at 42%', 'nuke - Ice x2, tier by MP')
    -- and the same text on the chat lines. Off leaves the NAME on both, which
    -- is the whole answer once the model is trusted and the reasoning is just
    -- noise on a busy screen. The log keeps expected_why either way - that is
    -- the dataset a mispredict is diagnosed from, not a display.
    -- A prediction of NOTHING is unaffected: there the reason IS the message
    -- ('nothing to cast', 'none ready - heal 12s'), so hiding it would leave a
    -- bare label saying nothing at all.
    show_reasoning = true,
    burden_tolerance = 2,   -- pp of error before it counts as an anomaly
    recast_tolerance = 2,   -- seconds early before an ability use counts as an anomaly
    log_dir        = nil,   -- nil = <ashita>/config/addons/clockwork/

    -- Display -----------------------------------------------------------
    warn_at     = 25,
    show_window = true,
    -- The automaton's target and its HP under the vitals. Drawn only while the
    -- automaton has actually acted on something, so it costs no line at rest.
    show_target = true,
    -- Three lines a player can do without once they are known: the WS line
    -- (and the weaponskill on the compact strip), the `gives` list of what the
    -- maneuvers are adding, and the oil counts - their no-oils warning too;
    -- the compact strip's rail still turns red with none left. Off hides the
    -- line only: the weaponskill is still predicted and logged.
    show_ws     = true,
    show_gives  = true,
    show_oils   = true,
    -- An element with no maneuver up whose next maneuver would overload at 0%
    -- sits in the Status tab's table only to carry its burden number, and that
    -- number is not a decision: it cannot cost anything until it climbs. Off
    -- drops those rows. A maneuver that IS up keeps its burden whatever the
    -- chance reads - that row is there for the maneuver, not for the burden.
    show_idle_burden = true,
    -- The HUD's typeface: two files under C:\Windows\Fonts, loaded once on the
    -- load event and never in a frame (tm.fontLoad). A missing file falls back
    -- to ImGui's own font at the same sizes. Segoe UI ships its semibold as a
    -- separate file; Bahnschrift does not - one variable file, and ImGui's
    -- rasteriser reads only its default instance - which is why it is not the
    -- default. Inline, not on the settings whitelist: chosen once.
    font_regular = 'segoeui.ttf',
    font_bold    = 'seguisb.ttf',
    -- The what-if sidebar on the Status tab: what each maneuver would change if
    -- you used it now. Off by default - it widens the panel, and it runs eight
    -- predictions a frame (throttled to 4 Hz) that a player who is not deciding
    -- between maneuvers does not need. The header's ? button and the Settings
    -- tab toggle it, and the choice is saved.
    sidebar     = false,
    -- The one-line layout: gems, the answers, the bars, the recasts. Its own
    -- window, so its position is remembered apart from the panel's.
    compact     = false,
    -- How big the HUD draws, as a percent. 100 is the size every offset in
    -- this addon was laid out at; the Settings tab sets it. Everything
    -- scales together - text, gems, bars, padding
    -- and the panel's own width - so the layout holds at any of them.
    ui_scale    = 100,
    -- The panel's width AT 100%. Not a setting: it is the width the tabs were
    -- laid out against, and ui_scale is what the player moves. tm.s() scales it.
    base_width  = 380,
    max_samples = 300,
}

return config
