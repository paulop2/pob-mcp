"""Run a Lua script with Path of Building's patched lua51.dll.

Path of Building ships a LuaJIT build with compound-assignment support
(``x += 1``). Stock LuaJIT releases do not parse that syntax, so a plain
``luajit`` binary cannot even load ``Launch.lua``.

This module is a drop-in replacement for ``luajit <script> [args...]``:

    python tools/pob_luajit.py <script.lua> [args...]

It loads the ``lua51.dll`` that ships with PoB, seeds the standard ``arg``
table, and runs the script with the current working directory unchanged.
Set ``POB_LUA_DLL`` to point at a different lua51.dll.
"""

from __future__ import annotations

import ctypes
import os
import sys

LUA_MULTRET = -1
LUA_OK = 0


def _lua_string(dll: ctypes.CDLL, state: ctypes.c_void_p, index: int) -> str:
    size = ctypes.c_size_t()
    ptr = dll.lua_tolstring(state, index, ctypes.byref(size))
    if not ptr:
        return "<non-string error object>"
    return ctypes.string_at(ptr, size.value).decode("utf-8", "replace")


def _fail(dll: ctypes.CDLL, state: ctypes.c_void_p, prefix: str, code: int) -> None:
    message = _lua_string(dll, state, -1)
    sys.stderr.write(f"{prefix}: {message}\n")
    sys.stderr.flush()
    if code in (2, 3):
        sys.stdout.flush()
    raise SystemExit(1)


def _lua_quote(value: str) -> str:
    escaped = (
        value.replace("\\", "\\\\")
        .replace("\"", "\\\"")
        .replace("\n", "\\n")
        .replace("\r", "\\r")
    )
    return f"\"{escaped}\""


def _resolve_dll() -> str:
    override = os.environ.get("POB_LUA_DLL")
    if override:
        if not os.path.isfile(override):
            raise SystemExit(f"POB_LUA_DLL does not exist: {override}")
        return os.path.abspath(override)

    candidates = [
        os.path.join(os.getcwd(), "..", "runtime", "lua51.dll"),
        os.path.join(os.getcwd(), "runtime", "lua51.dll"),
    ]
    pob_path = os.environ.get("POB_PATH") or os.environ.get("POB_FORK_PATH")
    if pob_path:
        candidates.append(os.path.join(pob_path, "..", "runtime", "lua51.dll"))
        candidates.append(os.path.join(pob_path, "runtime", "lua51.dll"))

    for candidate in candidates:
        candidate = os.path.abspath(candidate)
        if os.path.isfile(candidate):
            return candidate

    raise SystemExit(
        "Could not find PoB's lua51.dll. Set POB_LUA_DLL or run from the "
        "PathOfBuilding/src directory."
    )


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        sys.stderr.write("usage: pob_luajit.py <script.lua> [args...]\n")
        return 2

    script = argv[1]
    script_args = argv[2:]
    dll_path = _resolve_dll()

    if not os.path.isfile(script):
        sys.stderr.write(f"cannot open {script}: no such file\n")
        return 1

    os.add_dll_directory(os.path.dirname(dll_path))
    dll = ctypes.CDLL(dll_path)

    dll.luaL_newstate.restype = ctypes.c_void_p
    dll.luaL_newstate.argtypes = []
    dll.luaL_openlibs.restype = None
    dll.luaL_openlibs.argtypes = [ctypes.c_void_p]
    dll.luaL_loadstring.restype = ctypes.c_int
    dll.luaL_loadstring.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
    dll.luaL_loadfile.restype = ctypes.c_int
    dll.luaL_loadfile.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
    dll.lua_pcall.restype = ctypes.c_int
    dll.lua_pcall.argtypes = [
        ctypes.c_void_p,
        ctypes.c_int,
        ctypes.c_int,
        ctypes.c_int,
    ]
    dll.lua_tolstring.restype = ctypes.c_char_p
    dll.lua_tolstring.argtypes = [
        ctypes.c_void_p,
        ctypes.c_int,
        ctypes.POINTER(ctypes.c_size_t),
    ]

    state = dll.luaL_newstate()
    if not state:
        sys.stderr.write("luaL_newstate failed\n")
        return 1
    dll.luaL_openlibs(state)

    arg_entries = [f"arg[0] = {_lua_quote(script)}"]
    for index, value in enumerate(script_args, start=1):
        arg_entries.append(f"arg[{index}] = {_lua_quote(value)}")
    bootstrap = "arg = {}\n" + "\n".join(arg_entries) + "\n"

    if dll.luaL_loadstring(state, bootstrap.encode("utf-8")) != LUA_OK:
        _fail(dll, state, "arg bootstrap", 2)
    if dll.lua_pcall(state, 0, 0, 0) != LUA_OK:
        _fail(dll, state, "arg bootstrap", 2)

    if dll.luaL_loadfile(state, script.encode("utf-8")) != LUA_OK:
        _fail(dll, state, f"cannot load {script}", 2)
    if dll.lua_pcall(state, 0, LUA_MULTRET, 0) != LUA_OK:
        _fail(dll, state, f"error running {script}", 2)

    sys.stdout.flush()
    sys.stderr.flush()
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
