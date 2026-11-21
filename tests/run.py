"""Runs the offline Lua tests under Lua 5.1 via lupa (pip install lupa).

    python tests/run.py

Equivalent to `lua tests/sorting_spec.lua` when a Lua binary is installed.
"""
import os
import sys

from lupa.lua51 import LuaRuntime

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SPECS = ["tests/sorting_spec.lua", "tests/snap_spec.lua", "tests/roles_spec.lua", "tests/load_spec.lua"]


def main():
    failed = 0
    for spec in SPECS:
        path = os.path.join(ROOT, spec)
        if not os.path.exists(path):
            continue
        lua = LuaRuntime(unpack_returned_tuples=True)
        # Give the spec a Lua-style arg[0] so it can find the repo root.
        lua.execute("arg = { [0] = ... }", path.replace("\\", "/"))
        lua.execute("os.exit = nil")
        try:
            result = lua.execute(f"return dofile([[{path}]])")
        except Exception as e:  # spec raised
            print(f"{spec}: ERROR {e}")
            failed += 1
            continue
        if result:
            failed += int(result)
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
