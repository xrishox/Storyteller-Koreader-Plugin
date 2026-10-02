# Running the compatibility regressions

Run from the plugin repository root with Python 3, LuaJIT, LuaSocket/LuaSec, RapidJSON and LuaFileSystem available. Point at an extracted KOReader v2026.07.2 package and the SimpleUI fork checkout at `v2.7.1-storyteller.1`. Apply [the optional adapter](../docs/simpleui-background-loading.patch) to that checkout before running the full suite, which includes background-loading tests:

```sh
export KOREADER_ROOT=/path/to/koreader
export SIMPLEUI_ROOT=/path/to/simpleui.koplugin
python3 tests/run.py
```

If Lua modules are installed in a private LuaRocks tree, add its `lib/lua/5.1/?.so` to `LUA_CPATH`. These are test dependencies, not files to copy onto the Kindle. KOReader supplies the runtime dependencies.

The runner starts a loopback-only HTTP fixture on an ephemeral port. It tests real requests, response codes and streamed bytes without a Storyteller account or external service. The Lua suite also uses deterministic failure injection for sink completion, download integrity, nullable responses and sync conflicts. KOReader's actual process, fsync, LuaSettings reader, serializer, socketutil and SHA-256 helpers are loaded from `KOREADER_ROOT`; UI services and document file access are mocked. The suite forks real child processes and runs a simulated UI scheduler to exercise cancellation and stale-result guards. Storage failure injection covers open/write/flush/fsync/close/rename errors and interrupted EPUB/metadata commits. The actual SimpleUI Storyteller screen is loaded from `SIMPLEUI_ROOT`.

This is not a test of a running Storyteller installation or the Kindle display/native reader engine. Fixtures are based on Storyteller `web-v3.0.0-beta.46`; see the [audit](../docs/compatibility-audit-2026-10-02.md) for source references and limits.
