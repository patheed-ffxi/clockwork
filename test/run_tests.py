"""
Offline test run for the clockwork addon.

No standalone Lua interpreter is needed: the addon is loaded into lupa's
embedded LuaJIT 2.1 - the Lua Ashita runs; lupa's default runtime may be a
different Lua - with the Ashita environment and ImGui stubbed out. The harness
drives the addon against a scratch directory that is deleted afterwards, feeds
it synthetic packets, draws the panel into a recorder, and steps the apply
coroutine by hand, so most of it is exercised without a game running.

The harness is the files in FILES below, joined into one Lua chunk in that
order: the fixtures stub Ashita and load the addon, then each suite runs on the
state the suites before it left - which is why the order matters, and why the
fixtures' locals are in scope in every suite. An error is reported against the
file and line it came from.

Needs Windows (the fixtures stand in for Ashita's file functions with Windows
shell commands) and lupa 2.x:  python -m pip install -r test/requirements.txt

Config is inline. Run it:  python test/run_tests.py
"""

import os
import re
import shutil
import sys
import tempfile

try:
    import lupa.luajit21 as lupa   # LuaJIT 2.1, as Ashita runs; LuaError and LuaRuntime live here too
except ImportError:
    sys.exit("lupa 2.x with LuaJIT 2.1 is required: python -m pip install -r test/requirements.txt")

HERE = os.path.dirname(os.path.abspath(__file__))

# Which copy of the addon to test.
TARGET = os.path.normpath(os.path.join(HERE, ".."))
# TARGET = r"<your ashita folder>\addons\clockwork"   # to test a deployed copy

# The harness, in the order it runs.
FILES = [
    ("fixtures/world.lua", "check(), and the fake world every stub answers from"),
    ("fixtures/stubs.lua", "Ashita, ImGui, FFI, chat and clock stubs"),
    ("fixtures/load.lua", "strict globals, the addon loaded, and the api the suites reach it through"),
    ("fixtures/helpers.lua", "packet builders, the automaton in and out, frame() and the draw-list, log and recast readers"),
    ("suites/01_sets_and_apply.lua", "the set store, capacity, ownership, attachment effects, the planner and Apply"),
    ("suites/02_render.lua", "the panel and compact strip drawn: target row, header controls, login gate, icons"),
    ("suites/03_burden_and_recasts.lua", "burden decay, Activate seeding, the 0x028 round-trip and recast timers"),
    ("suites/04_spell_ladder.lua", "recast cells, spell data, rung windows, mob effects and the spell ladder"),
    ("suites/05_chat_and_settings.lua", "prediction and anomaly chat lines, the log switches and the settings file"),
    ("suites/06_model_edges.lua", "burden catch-up, Deus Ex seeding, empty buffers and the caster's target"),
    ("suites/07_sidebar_and_weaponskills.lua", "the what-if sidebar, weaponskill choice, skillchains, Heatsink and tooltips"),
    ("suites/08_effects_and_regen.lua", "effects that land in silence, enhance inference, Regen targeting and expiry"),
    ("suites/09_hardening.lua", "JSON records, set names, poisoned settings, swallowed reads and the packet gates"),
    ("suites/10_status_and_mp.lua", "uncertain predictions, bounded inference, Dia/Bio tiers, resonance, zoning, MP"),
    ("suites/11_automaton_buffs.lua", "the automaton's own buffs: after a reload, after a summon, from mob skills"),
    ("suites/12_ui_tabs_and_scale.lua", "tabs, the draw surface, the UI scale and the Settings tab"),
    ("suites/13_logging_and_limits.lua", "log rotation, learned-cost overrides and the upvalue ceilings"),
    ("suites/14_deploy_and_switching.lua", "Deploy and Retrieve, the compact strip, reconcile, culled automatons, character switches"),
    ("suites/15_demo.lua", "demo mode"),
    ("fixtures/report.lua", "the totals; any failure makes the run fail"),
]


def build():
    """The joined chunk, and for each of its lines the file and line it came from."""
    parts, origin = [], []
    for rel, _ in FILES:
        with open(os.path.join(HERE, rel), encoding="utf-8") as fh:
            text = fh.read()
        if not text.endswith("\n"):
            text += "\n"
        origin.extend((rel, n) for n in range(1, text.count("\n") + 1))
        parts.append(text)
    return "".join(parts), origin


def locate(message, origin):
    """Rewrite the chunk's line numbers in an error message as file:line."""
    def repl(m):
        n = int(m.group(1))
        return "%s:%d" % origin[n - 1] if 0 < n <= len(origin) else m.group(0)
    return re.sub(r'\[string "harness"\]:(\d+)', repl, message)


def main():
    source, origin = build()
    scratch = tempfile.mkdtemp(prefix="clockwork-test-")
    runtime = lupa.LuaRuntime(unpack_returned_tuples=True)
    run = runtime.eval(
        "function(src, dir, scratch) return assert(load(src, 'harness'))(dir, scratch) end"
    )
    try:
        run(source, TARGET.replace("\\", "/"), scratch.replace("\\", "/"))
    except lupa.LuaError as err:
        print("harness aborted:")
        print(locate(str(err), origin))
        sys.exit(1)
    finally:
        shutil.rmtree(scratch, ignore_errors=True)


if __name__ == "__main__":
    main()
