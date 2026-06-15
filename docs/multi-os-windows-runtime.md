# Multi-OS Windows Runtime (W1 architecture decision)

**Status.** W1 architecture decision — Phase W of the
`ReproOS-Multi-OS-Catalog-PoC` campaign. Companion document to
[`foreign-package-runtime.md`](foreign-package-runtime.md) (the C3
Linux launcher). This document decides how ReproOS executes Windows
software harvested from reprobuild's existing Windows catalog (gh,
just, ninja) via WINE on Linux.

This is a PoC-scoped decision. Production-breadth concerns (per-package
isolation, multi-Windows-version support, GPU passthrough, etc.) are
called out as post-PoC follow-ups but not implemented in this
milestone.

* W2 — extend the C3 launcher with a `runtime=wine` manifest key
  (consumes the layout decided here).
* W3 — extend the catalog format with `runtime=wine` records (consumes
  the layout decided here).
* W4 — `vm-harness` end-to-end Windows-via-WINE boot test.

## Summary of decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| WINEPREFIX topology | **Single shared WINEPREFIX** (one prefix; all 3 PoC packages share `drive_c/`) | ~150 MB cold cost, smallest ISO footprint; PoC tools (gh/just/ninja) are standalone Win64 console tools with no registry conflicts. |
| Per-package store layout inside the prefix | `drive_c/repro-store/<hash>/` (one subtree per Windows package) | Matches the campaign spec's baked-in decision (§1). Inside WINE this appears as `C:\repro-store\<hash>\`. |
| WINE provisioning path | **C2 apt harvest** of `wine` from Debian bookworm snapshot | Same machinery as Phase X1; WINE is just another foreign package. Avoids a from-source WINE build. ~80 MB compressed. |
| `wineboot -i` timing | **Bake at ISO build** (initialized `$WINEPREFIX` shipped in initramfs) | Snappy first-run (no 30 s cold init); ISO size cost is ~150 MB, within the 200 MB PoC budget. |
| Bind-mount surface (W2) | Launcher binds **both** the WINE binaries closure and the WINEPREFIX into the namespace; exec()s `wine drive_c/repro-store/<hash>/bin/<binary>.exe` | Mirrors C3's existing bind-set discipline; the WINEPREFIX is just two more bind sources. |

## Why a shared WINEPREFIX (not per-package, not per-Windows-version)

| Topology | Disk cost (3 PoC pkgs) | Isolation | PoC fit |
|----------|------------------------|-----------|---------|
| Per-package WINEPREFIX | 3 × 150 MB = **450 MB** prefixes alone | Best (separate registry, separate `C:\windows\`) | Blows the 200 MB ISO budget. |
| **Shared WINEPREFIX** | **150 MB** total | Adequate for standalone .exe tools (no shared HKCU keys, no registered COM servers) | Fits the budget; simplest manifest format. |
| WINEPREFIX-per-Windows-version | 2-3 × 150 MB = 300-450 MB | Useful only if pinning Win7 vs Win10 quirks | All 3 PoC tools are Win64 console tools without Windows-version pins. Unnecessary. |

The PoC tools are:

* **gh** — GitHub CLI; single statically-linked `gh.exe` from upstream
  releases. No installer, no registry use, no DLL surface beyond the
  standard `kernel32`/`advapi32` set provided by WINE itself.
* **just** — Task runner; single Rust-compiled `just.exe`. Same shape.
* **ninja** — Build tool; single C++ compiled `ninja.exe`. Same shape.

None of them register COM servers, install services, or write to
`HKLM\Software\<vendor>`. A shared WINEPREFIX is safe for the PoC
tools as a class. **The doc reserves a future migration path to
per-package prefixes if a future catalog tool registers conflicting
registry state** — the manifest format gains a `wine_prefix_id=<id>`
key in W2 (default `shared`) that selects which prefix subtree the
launcher binds; per-package prefixes are a config flip, not a re-arch.

## Layout schema

The single shared WINEPREFIX lives at a stable path inside the rootfs
so the launcher can bind it deterministically. Per-package payloads
live under `drive_c/repro-store/<hash>/`.

```
ReproOS rootfs
==============

  /opt/reproos-foreign/wine-binaries/                  WINE itself (apt-harvested
    usr/                                               from Debian bookworm
      bin/wine                                         snapshot; ~80 MB compressed,
      bin/wine64                                       ~250 MB extracted).
      bin/wineserver                                   Shape: a self-contained
      bin/wineboot                                     extracted .deb closure
      lib/x86_64-linux-gnu/wine/                       rooted under usr/.
      lib/x86_64-linux-gnu/libwine.so.1
      share/wine/...

  /opt/reproos-foreign/wine-prefix/                    SHARED WINEPREFIX
    drive_c/                                           (~150 MB after wineboot -i;
      windows/                                          baked at ISO build time so
        System32/                                       first invocation has no
        SysWOW64/                                       cold-start penalty).
      ProgramData/
      users/                                           WINE-provided directories.
      repro-store/                                     <<< OUR addition.
        <gh-hash>/                                     One subtree per Windows
          bin/                                         package.
            gh.exe                                     Catalog points exec_path at
        <just-hash>/                                   drive_c/repro-store/<hash>/
          bin/                                         bin/<binary>.exe (relative
            just.exe                                   to the WINEPREFIX root).
        <ninja-hash>/
          bin/
            ninja.exe
    dosdevices/                                        WINE-provided drive-letter
      c:                                                symlinks; we DON'T modify.
      z:

  /opt/reproos-foreign/wine-prefix.manifest            JSON sidecar:
                                                       {
                                                         "wine_prefix_id": "shared",
                                                         "windows_version": "win10",
                                                         "wine_version": "<from .deb>",
                                                         "wineboot_initialized_at": "<utc>",
                                                         "subtree_count": 3,
                                                         "subtrees": [
                                                           {"hash": "<gh>", "binaries": ["bin/gh.exe"]},
                                                           ...
                                                         ]
                                                       }

  /usr/local/bin/wine-gh                               Per-binary distro-tagged
  /usr/local/bin/wine-just                             shim; exec()s
  /usr/local/bin/wine-ninja                            reprobuild-sandbox-launcher
                                                       --manifest=<...>
                                                       (the manifest carries
                                                       runtime=wine + exec_path).
```

### Per-package store layout inside the WINEPREFIX

Each Windows catalog entry materializes as:

```
$WINEPREFIX/drive_c/repro-store/<hash>/
├── bin/
│   └── <binary>.exe          # Or multiple binaries for tools that ship companions.
├── share/                    # Optional: data files (just templates, gh themes, ...).
└── manifest.json             # Per-package metadata (catalog hash, source URL, sha256).
```

The `<hash>` is the realization hash of the Windows package (BLAKE3
of the catalog entry's `dependency_closure` + content sha256 of the
.exe payloads). This is exactly the same shape as C3 Linux packages'
`/store/prefixes/<package>/<hash>/`, just rooted under
`drive_c/repro-store/` so WINE resolves it as
`C:\repro-store\<hash>\`.

## WINE provisioning path

The PoC harvests WINE itself via the **existing C2 apt harvester**.
WINE is just another foreign package; no new harvester is needed.

```
recipes/catalog/foreign/apt/wine.json
├── source_url: snapshot.debian.org/archive/debian/<snapshot>/
│              pool/main/w/wine/wine_*.deb
├── pin_sha256: <pinned sha256 of the .deb>
└── dependency_closure: [libwine, libwine-mono-runtime, libwine-gecko, ...]
                        (transitive, ~250 MB extracted in total)
```

C2's existing `repro-harvest-apt` walks the apt dependency tree and
materializes each dependency into the content-addressed store. The
WINE binaries land at
`/store/prefixes/apt/wine/<hash>/usr/bin/wine` etc.; the build script
exposes a `wine-binaries` overlay symlink/bind at
`/opt/reproos-foreign/wine-binaries/` for the launcher to bind into
the namespace.

**Rejected alternative: from-source WINE build.** Faster ISO build to
harvest the prebuilt .debs; matches the rest of the foreign-package
model (we don't compile git, vim, or curl from source either —
consistency with Phase X1). From-source WINE is reserved as a
post-PoC option if licensing or reproducibility concerns surface.

**Rejected alternative: WINE from a Nix package.** ReproOS targets
both Nix-derived and apt-derived foreign packages, but the PoC stays
on the apt path established in Phase X1 to avoid mixing provisioning
models inside a single milestone.

## `wineboot -i` timing — bake at ISO build

`wineboot -i` populates `$WINEPREFIX/drive_c/windows/`,
`$WINEPREFIX/drive_c/Program Files/`, registers default WINE DLL
overrides, and creates the user-profile skeleton. Cold init takes
~20-30 s on a modern host and is **not deterministic across WINE
versions** (timestamps, registry hive UUIDs vary). For PoC purposes
the prefix is:

1. Built once at ISO-build time on the build host by
   `recipes/reproos-mvp-config/wine-prefix-init.sh` (this milestone).
2. Captured as a tarball into the initramfs.
3. Extracted at boot to `/opt/reproos-foreign/wine-prefix/` by the
   existing initramfs prefix-extraction step (already used for Linux
   foreign packages in Phase X1).

Trade-offs:

| Timing | ISO size cost | First-run cost | Determinism | PoC fit |
|--------|---------------|----------------|-------------|---------|
| **Bake at ISO build** | +~150 MB | 0 (already initialized) | Build-time only (host-influenced; documented limitation) | Good — snappy demo. |
| Init at first boot | 0 | ~30 s + X11/headless workarounds | Run-time; subject to in-VM state | Bad — cold-start tax + GUI dialog risk. |
| Init lazily on first `wine <binary>` invocation | 0 | ~30 s per binary (or shared cache) | Same as first-boot | Bad — surprises the demo. |

**Decision: bake.** The non-determinism limitation is documented and
deferred to a post-PoC "reproducible WINEPREFIX" follow-up; for the
PoC the prefix tarball's sha256 is pinned in the manifest sidecar so
re-builds at least detect drift.

## Launcher integration sketch (W2 will implement)

The W2 milestone extends the C3 manifest format with a `runtime=wine`
key and one new shape of bind line. The W1 doc fixes the bind set so
W2 can implement against a stable contract.

### W2 manifest format additions

New key/value lines (forward-compatible — older launcher binaries
ignore unknown keys per `MANIFEST-FORMAT.md`):

```manifest
# C3 base manifest (Linux closure dep bind set unchanged)
exec=/opt/reproos-foreign/wine-binaries/usr/bin/wine

# NEW: declares the runtime; absent = Linux native (C3 behaviour).
runtime=wine

# NEW: WINEPREFIX path on the host (passed to wine via WINEPREFIX env var).
wine_prefix=/opt/reproos-foreign/wine-prefix

# NEW: the path WINE will execute, expressed as a drive_c-relative
# POSIX path (translates to a C:\ path inside WINE).
wine_exec=drive_c/repro-store/<gh-hash>/bin/gh.exe

# Existing bind lines: WINE binaries closure, the WINEPREFIX itself,
# and the per-package payload subtree (already inside the prefix, so
# this is a no-op overlap on the shared prefix path — listed
# explicitly for non-shared prefix configurations).
/opt/reproos-foreign/wine-binaries:/opt/reproos-foreign/wine-binaries:rbind,ro
/opt/reproos-foreign/wine-prefix:/opt/reproos-foreign/wine-prefix:rbind

# Filesystem services (wine needs /proc for process discovery).
proc
```

### W2 launcher behaviour

When `runtime=wine` is present, the launcher:

1. Parses the manifest as today (W2 adds the three new keys).
2. Performs the bind set as today.
3. Sets `$WINEPREFIX` to the value of `wine_prefix=`.
4. Sets `$WINEDEBUG=-all` and `$WINEDLLOVERRIDES=mscoree,mshtml=` to
   suppress Mono/Gecko nags.
5. `exec()`s `<exec> <wine_exec> <forwarded argv>` — i.e. invokes
   the WINE binary from `exec=`, passing the drive_c-relative path
   as the first argument, then forwarding everything after the C3
   `--` delimiter.

The launcher does NOT translate the `wine_exec` path to a `C:\...`
form. WINE accepts forward-slash POSIX paths and resolves them
relative to `$WINEPREFIX/dosdevices/` automatically.

## Catalog format extension for Windows packages (W3 will implement)

W3 adds Windows catalog entries (`recipes/catalog/windows/{gh,just,ninja}.json`)
with the following new keys layered on the existing C1/C2 catalog
shape:

```json
{
  "name": "gh",
  "runtime": "wine",
  "version": "2.40.0",
  "source_url": "https://github.com/cli/cli/releases/download/v2.40.0/gh_2.40.0_windows_amd64.zip",
  "sha256": "<pinned>",
  "wine_prefix_id": "shared",
  "exec_path": "drive_c/repro-store/<hash>/bin/gh.exe",
  "dependency_closure": []
}
```

* `runtime=wine` — selects the WINE launcher path.
* `wine_prefix_id` — selects which WINEPREFIX subtree the package
  lands in (default `shared`; reserved for future per-package
  isolation).
* `exec_path` — WINEPREFIX-relative path (passed verbatim to
  `wine_exec=` in the generated manifest).
* `dependency_closure` — empty for the PoC tools (statically linked).
  Non-empty entries trigger the same realize-time graph walk used for
  Linux packages, with subtrees placed alongside the root under the
  same WINEPREFIX.

The catalog payload extraction step (W3) unpacks the .zip / .exe into
`/store/prefixes-win/<hash>/` on the build host; the build pipeline
then copies the subtree into the WINEPREFIX at
`drive_c/repro-store/<hash>/`.

## Known limitations (PoC scope)

These limitations are accepted for the PoC; they are documented as
post-PoC follow-ups but DO NOT block W1-M2.

1. **WINEPREFIX byte-determinism is build-host influenced.** The
   `wineboot -i` step writes timestamps + UUIDs into the registry
   hives + filesystem mtimes. Two builds of the same WINE version on
   the same host produce different-byte prefixes. Mitigation: pin the
   tarball sha256 in the manifest sidecar so re-builds detect drift;
   a future milestone may rebuild WINE with deterministic UUIDs.
2. **No GUI applications.** WINE runs headless (no X11 in the
   ReproOS rootfs); GUI Windows apps would deadlock on
   `CreateWindowEx`. PoC tools are CLI-only by selection.
3. **No multi-Windows-version support.** Shared prefix uses WINE's
   default Win10 emulation. Apps requiring Win7-only APIs or Win11
   APIs are out of PoC scope.
4. **No registered-COM-server support.** The PoC tools don't register
   COM servers. Apps that do (e.g. installer-style packages) would
   leak state across packages in a shared prefix.
5. **No `winetricks` integration.** PoC packages use WINE's default
   DLL set; tools requiring `winetricks corefonts` / `dotnet48` /
   etc. are out of scope. The wine-prefix-init.sh script exposes a
   `--winetricks-verbs` hook for future use but doesn't run it by
   default.
6. **WINE binary closure is large.** ~250 MB extracted; cuts into the
   200 MB ISO budget. The PoC may need to strip unused WINE
   components (e.g. `wine-mono`, `wine-gecko` — neither is needed by
   the PoC tools) before the ISO budget closes. M1 will measure.
   *W1 gate measurement (Ubuntu 22.04 wine-6.0.3): the initialized
   WINEPREFIX itself is **533 MB**, substantially larger than the
   ~150 MB estimate; the bulk is `wine-gecko-2.47-x86.msi` and
   `wine-mono-5.0.0-x86.msi` cached under `drive_c/windows/Installer/`.
   Both are inert at runtime for the PoC tools (mscoree/mshtml are
   disabled via WINEDLLOVERRIDES) — a post-PoC follow-up should
   delete the Installer/ cache + the Mono/Gecko DLL files after
   wineboot completes. Net rewrite candidate is ~250 MB.*

7. **wine32 i386 multi-arch not enabled.** Ubuntu's wine package
   triggers a `wine32 is missing` warning on every invocation unless
   `dpkg --add-architecture i386` is run upfront. The warning is
   harmless for Win64 PoC tools (gh/just/ninja are all amd64). The
   ReproOS rootfs harvest (W2/W3) should add i386 multi-arch
   support to the apt closure walker OR document the warning as
   ignorable; the latter is the PoC choice.

## Verification (W1 P3 gate)

`recipes/reproos-mvp-config/wine-prefix-init.sh --prefix-dir <path>`
creates a fresh WINEPREFIX in a Linux environment. Acceptance:

* `$WINEPREFIX/drive_c/` exists post-init.
* `$WINEPREFIX/drive_c/windows/` exists post-init.
* `WINEPREFIX=<path> wine --version` reports a wine version string.

The script suppresses GUI dialog nags via `WINEDEBUG=-all` and
`WINEDLLOVERRIDES=mscoree,mshtml=`. The verification is documented as
having two acceptable outcomes:

1. **Best case**: `wine --version` reports a stable version + the
   `drive_c` skeleton is fully populated → W1 P3 PASS.
2. **Acceptable case**: `wineboot -i` runs but logs Mono/Gecko
   warnings (these are documentation noise, not failures) → W1 P3
   PASS with documented warnings.
3. **Failure case**: `wineboot -i` deadlocks waiting for an X11
   server → W1 P3 FAIL; mitigation documented as a path forward.

The execution result is recorded in the W1 milestone's Outcome
section in the campaign spec at review time.

### W1 P3 gate execution record (2026-06-15, repro-ubuntu WSL)

```
$ wsl -d repro-ubuntu -e bash -c "wine --version"
wine-6.0.3 (Ubuntu 6.0.3~repack-1)

$ bash wine-prefix-init.sh --prefix-dir /tmp/w1-test-prefix --verbose
[wine-init] wine version: wine-6.0.3 (Ubuntu 6.0.3~repack-1)
[wine-init] prefix dir: /tmp/w1-test-prefix
[wine-init] running wineboot -i (this may take 10-30s on first invocation)
[wineboot] wine: configuration in L"/tmp/w1-test-prefix" has been updated.
[wine-init][verbose] draining wineserver: /usr/bin/wineserver -w
[wine-init][verbose] OK    drive_c dir: /tmp/w1-test-prefix/drive_c
[wine-init][verbose] OK    drive_c/windows: /tmp/w1-test-prefix/drive_c/windows
[wine-init][verbose] OK    drive_c/users: /tmp/w1-test-prefix/drive_c/users
[wine-init][verbose] OK    drive_c/repro-store: /tmp/w1-test-prefix/drive_c/repro-store
[wine-init][verbose] OK    system.reg hive: /tmp/w1-test-prefix/system.reg
[wine-init][verbose] OK    userdef.reg hive: /tmp/w1-test-prefix/userdef.reg
[wine-init] verification PASS
EXIT=0

$ WINEPREFIX=/tmp/w1-test-prefix wine --version
wine-6.0.3 (Ubuntu 6.0.3~repack-1)

$ du -sh /tmp/w1-test-prefix
533M    /tmp/w1-test-prefix

$ ls /tmp/w1-test-prefix/drive_c/
Program Files  Program Files (x86)  ProgramData  repro-store  users  windows
```

Gate result: **PASS**.

Diagnostic findings folded back into the script:

* `wineboot -i` returns asynchronously — the registry hives
  (`system.reg`, `userdef.reg`) are flushed by `wineserver` after
  the foreground tool exits. The script now invokes `wineserver -w`
  to block until the drain completes; without this drain, the
  verification step races and reports false MISS lines for the reg
  hives. First-run revision of the script caught the race
  immediately and the fix landed in the same pass.
* The `wine32 is missing` warning on Ubuntu is harmless for the PoC
  Win64 tool selection. See known limitation #7.
* Observed disk footprint (533 MB) exceeds the doc's planning
  estimate (150 MB) by ~3.5x because Ubuntu's wine package caches
  Mono + Gecko MSI installers. See known limitation #6 for the
  follow-up.
