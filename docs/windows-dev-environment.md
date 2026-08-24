# Building and testing reprobuild on Windows

This is the Windows counterpart of `.envrc` / `use flake`. If you are on
Linux or macOS you do not need it.

Everything here was learned by getting it wrong first. The failures in this
document do not announce themselves as environment problems — they surface as
linker errors, silent hangs, and compiler crashes that read like a broken
checkout.

## The one rule: source `env.ps1`, do not hand-set its variables

```powershell
cd D:\path\to\reprobuild
$env:PSModulePath = [Environment]::GetEnvironmentVariable('PSModulePath','Machine')
. .\env.ps1
```

It prints what it resolved. **Read that summary** — a wrong toolchain is
visible there, and invisible everywhere else until it costs you an hour:

```
reprobuild dev environment ready.
  nim          = ...\nim\2.2.8\prebuilt\nim-2.2.8\bin\nim.exe
  gcc          = ...\gcc\15.2.0\bin\gcc.exe
  just         = ...\just\1.51.0\just.exe
  bash         = ...\msys2\msys64\usr\bin\bash.exe
  clingo       = ...\clingo\5.8.0\clingo.dll
  nim-bearssl  = ...\nim-bearssl\<rev>
  openssl      = ...\openssl\3.6.3\lib
  codetracer   / runquota / stackable-hooks = <sibling checkouts>
```

The `PSModulePath` line is not optional if you launched from pwsh 7: PowerShell
5.1 otherwise resolves `Microsoft.PowerShell.Utility` to pwsh 7's copy and
every `Get-FileHash` in the provisioning path fails at once.

### Why not just set the one variable you think you need

Because the variables are not independent, and the obvious guess is wrong.

Setting `REPRO_WINDOWS_CLINGO_DIR` by hand is the specific trap. There is a
second clingo on a typical box — the one belonging to the **Windows runner
system profile** under `C:\dev-deps\reprobuild\` — and pointing at it looks
like it works. Meanwhile you have silently skipped `nim-bearssl`,
`LIBRARY_PATH` and the sibling-repo exports, and you will spend the next hour
attributing the resulting failures to the tree.

If a build fails outside a sourced `env.ps1`, suspect the environment before
you suspect the code.

## What `env.ps1` provisions that is not obvious

`windows/toolchain-versions.env` holds the pins; `windows/ensure-*.ps1` do the
work. Three of them are hard dependencies whose absence produces a misleading
error rather than a missing-dependency message:

| Step | Absent symptom | Why it is not optional |
|---|---|---|
| `ensure-clingo` | `could not load: clingo.dll` before `main` | `repro_solver`'s FFI is resolved eagerly at module init. There is no degraded mode. |
| `ensure-nim-bearssl` | `cannot open file: bearssl/ec` | `repro_peer_cache/auth.nim` imports it. Pinned to the same rev as the flake's `bearssl-src`; bump both together. |
| `ensure-openssl` | `ld.exe: cannot find -lssl` | See below. |

### OpenSSL, and why it is an environment concern rather than a catalog one

`repro`, `repro-binary-cache` and `repro-harvest-apt` are compiled with
`--define:ssl`. For any such entry point the builtin catalog's nim typed-tool
appends the **portable** linker names `-lssl -lcrypto`
(`packages/nim.nim`, `opensslPassLForSsl`) and deliberately bakes in **no**
search path — `t_nim_ssl_dependency.nim` asserts that an ambient path never
reaches `passL`, which is what keeps catalog actions hermetic and identical
across platforms.

Supplying the search directory is therefore the *toolchain environment's* job.
The flake devShell does it through `NIX_LDFLAGS`. `env.ps1` does it through
`LIBRARY_PATH`, which gcc consults natively when resolving `-l<name>`. That
choice matters: it reaches **both** build routes, and a `--passL` would not.

* `bash scripts/build_apps.sh` — sets its own nim flags.
* `repro build .#apps` — the graph route, whose actions the build engine
  spawns and which therefore never observe `build_apps.sh`'s variables.

Do not "fix" a future OpenSSL problem by threading a path through the catalog.
That is the thing the hermeticity test exists to prevent.

Two further notes:

* This is a **link** dependency. It is unrelated to the `openssl` entry in the
  builtin catalog, which is a nix-only `nixPackage` exposing `bin/openssl` —
  the CLI, never the import libraries a linker needs.
* The package must be the MSYS2 **`ucrt64`** variant, because the pinned gcc is
  WinLibs POSIX UCRT. An MSVCRT-built libcrypto under a UCRT gcc links cleanly
  and then misbehaves at runtime around `FILE*`, `errno` and locale — strictly
  worse than a link error, because nothing points back at the cause.

## Use `just test`. Do not drive `repro build` by hand

```powershell
D:\...\just.exe test        # -> bash scripts/run_tests.sh
```

Running `.\build\bin\repro.exe build .#<target>` directly *looks* equivalent
and is not. `scripts/run_tests.sh` locates the `runquotad` / `runquota`
binaries and puts them on `PATH` first. Without that, the build reaches a
differently-configured quota authority and every action is denied:

```
runquota.denied repro provider compile edge attempt=N backoffMs=5000 \
  reason=lease request exceeds machine memory budget: local
```

That check is `possible()` in `runquota_daemon.nim` — a **static feasibility**
test comparing the request against the machine's *declared* capacity. It is
not a report of memory pressure, and it is not leaked leases: you can see it
on an idle box with 100+ GB free. The build then retries on a 5-second backoff
**forever** rather than failing, so the first symptom is a process sitting at
0 CPU with an empty log. Check for `runquota.denied` in the log before
concluding anything is hung.

Two related traps while you are here:

* `REPROBUILD_MAX_PARALLELISM=1` combined with a hand-run `repro build`
  produced the same silent 0-CPU stall for us. Prefer the default.
* Force-killing `repro.exe` leaves a daemon that a later invocation may attach
  to. If a build produces no output and no `gcc`/`nim` children, check for a
  leftover `repro` process with 0 CPU seconds before re-running.

## Fixed: access violations under the automatic dependency monitor

Older Windows monitor shims could make an action fail with an exit code of
`-1073741819` — `0xC0000005`, STATUS_ACCESS_VIOLATION — accompanied by

```
repro internal io monitor: error: The process cannot access the file because
it is being used by another process.
```

The affected actions all carry `dependencyPolicyKind: dgAutomaticMonitor`. The
failure was **nondeterministic** because a Win64 callee may leave the upper half
of the return register undefined for a 32-bit `BOOL` result. Narrowing the full
register in an injected hook could raise a `RangeDefect` inside the monitored
process. `io-mon` now applies Windows' 32-bit return-value semantics explicitly.

**Do not "fix" this by disabling the monitor.** A declared-only /
monitor-disabled dependency mode is a deliberate, documented soundness hole —
it marks actions complete and cacheable on declared inputs alone while
dropping runtime read-set discovery, so a changed dependency silently does not
rebuild. It has been introduced by agents without approval more than once
(`dgDeclaredOnly`, `dgNoRuntimeDependencies`, `declaredOnlyDependencyPolicy`,
`REPRO_MACOS_DISABLE_ACTION_MONITOR`) and removed each time. See the NOTE in
`repro_core/dependency_gathering.nim` and `repro_build_engine.nim`. An action
that genuinely cannot be monitored must FAIL or be NON-CACHEABLE
(`Monitor-Hook-Shim.md:501`) — never marked complete-on-declared-inputs.

If this signature returns, first sync `io-mon`, stop any running Reprobuild
daemon, and run `just build` so `build/lib/librepro_monitor_shim.dll` is rebuilt
before the daemon starts again. Re-running with a stale DLL can appear to fix
the problem by chance and is not a valid workaround.

## Scale: the full suite is long, not broken

Past `.#apps` (18 actions), `run_tests.sh` builds `.#test-helpers`,
`.#test-fixtures` and `.#test-builds` — 1276 binaries. The script's own comment
records a cold run reaching 969/1168 before a 90-minute timeout. Budget for it,
or run a targeted set and diff the failing sets across `git stash`.

`REPROBUILD_TEST_WARM_REUSE=1` keeps `build/test-bin` instead of deleting it,
which is what makes a second run tractable.
