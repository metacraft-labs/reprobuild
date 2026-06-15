# Multi-OS macOS Runtime (D1 architecture decision)

**Status.** D1 architecture decision — Phase D of the
`ReproOS-Multi-OS-Catalog-PoC` campaign. Companion document to
[`multi-os-windows-runtime.md`](multi-os-windows-runtime.md) (the W1
WINE runtime) and [`foreign-package-runtime.md`](foreign-package-runtime.md)
(the C3 Linux launcher). This document decides how ReproOS executes
macOS software via [Darling](https://github.com/darlinghq/darling) on
Linux.

This is a PoC-scoped decision. Production-breadth concerns (Cocoa GUI,
Apple-Silicon native binaries, Metal GPU passthrough, code-signing
validation, etc.) are called out as post-PoC follow-ups but not
implemented in this milestone. Darling itself is **preview-quality
software** as of `v0.1.20260608` — the architecture must absorb that
risk by selecting CLI-only Mach-O tools and providing a documented
fallback if a tool turns out to need APIs Darling has not implemented.

* D2 — extend the C3 launcher with a `runtime=darling` manifest key
  (consumes the layout decided here).
* D3 — extend the catalog format with `runtime=darling` records
  (consumes the layout decided here).
* D4 — `vm-harness` end-to-end macOS-via-Darling boot test.

## Summary of decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| DPREFIX topology | **Single shared DPREFIX** (one prefix; all 2-3 PoC packages share `/Applications/repro-store/`) | Smallest ISO footprint; PoC tools are statically-linked Mach-O CLI tools with no `/Library/LaunchDaemons/` registrations or shared user-defaults conflicts. DPREFIX itself is only **~5 MB** post-init (the macOS-shaped skeleton overlay; the heavy ~285 MB lives in the host's `/usr/libexec/darling/` install, not the prefix). |
| Per-package store layout inside the prefix | `/Applications/repro-store/<hash>/` (one subtree per macOS package) | Matches the campaign spec's baked-in decision; mirrors W1's `drive_c/repro-store/<hash>/` shape exactly. |
| Darling provisioning path | **Upstream-published Ubuntu .debs** (`debs_<date>.zip` from the Darling release page) — install only the CLI subset (`darling-core`, `darling-system`, `darling-cli`, `darling-cli-gui-common`, `darling-cli-python2-common`) | The Darling project publishes Debian/Ubuntu .debs on every release. They're built for Ubuntu noble (glibc ≥ 2.38). Avoids a 16 GB from-source build. CLI subset is ~113 MB compressed → **~285 MB extracted under `/usr/libexec/darling/`** (measured 2026-06-15 on Ubuntu 24.04 noble with darling-core/system/cli/cli-gui-common/cli-python2-common 0.1.20260609; smaller than the planning estimate of 580 MB). |
| Built-from-source alternative | **Rejected for PoC.** | 16 GB build disk + 4 GB RAM + clang-15+; reserved as a post-PoC option if a release-blocking bug surfaces in the published .debs. |
| Apt-harvested-from-Debian alternative | **Rejected.** | Darling is NOT in Debian or Ubuntu's apt archives (only an unrelated Rust `darling` proc-macro crate). |
| DPREFIX initialization timing | **Bake at ISO build** (initialized `DPREFIX` shipped in initramfs) | Mirrors W1's `wineboot -i` bake decision. First `darling shell` invocation cold-inits the prefix (~10 s on modern hosts); bake-time amortises that to zero at runtime. |
| Bind-mount surface (D2) | Launcher binds **both** the Darling binaries closure and the DPREFIX into the namespace; exec()s `darling shell <exec_path> <args...>` (positional form; the `--command` flag form documented in some tutorials is NOT supported by current Darling — `darling` treats `--command` as a program name and tries to exec it) | Mirrors W1's bind set discipline; the DPREFIX is one more bind source than W1's. |
| Host kernel requirement | **None as of `v0.1.20260608`** — Darling no longer ships a Linux kernel module (LKM); runs entirely in user-space on stock Linux ≥ 5.0. | Major change vs. Darling docs ≤ 2024. Removes the WSL2 kernel-rebuild risk that was the dominant D1 blocker concern in the campaign spec. |

## Why a shared DPREFIX (not per-package, not per-macOS-version)

| Topology | Disk cost (3 PoC pkgs) | Isolation | PoC fit |
|----------|------------------------|-----------|---------|
| Per-package DPREFIX | 3 × ~5 MB prefix + shared 285 MB binaries = **~300 MB** | Best (separate `/Library/Preferences/`, separate `/System/`) | Acceptable disk cost but no isolation benefit for stateless CLI tools. |
| **Shared DPREFIX** | **~5 MB prefix + 285 MB Darling binaries = ~290 MB** total | Adequate for standalone Mach-O CLI tools (no shared user-defaults, no LaunchDaemons, no /System/ patches) | Fits the budget. Simplest manifest format. |
| DPREFIX-per-macOS-version | 2-3 × ~5 MB prefix | Useful only if pinning macOS 10.13 vs 10.15 API quirks | All PoC tools target standard libSystem APIs without macOS-version pins. Unnecessary. |

*Cold-size measured 2026-06-15 in repro-darling-test WSL (Ubuntu 24.04 noble): `du -sh /tmp/d1-test-prefix` reports **5.2 MB** after `darling shell echo ok`; `du -sh /usr/libexec/darling` reports **285 MB** for the installed CLI subset. The 600 MB planning estimate carried over from older Darling releases that bundled the macOS framework stubs INTO the prefix overlay; modern Darling keeps them in `/usr/libexec/darling/` shared across all prefixes.*

The PoC tool candidates are (final selection in §"Tool selection for
the D-phase PoC" below):

* **fzf** — Statically-linked Go CLI from upstream `junegunn/fzf`
  releases (darwin-amd64). Single executable; no `info.plist`, no
  bundle, no shared user-defaults. Same shape as W1's `gh.exe`.
* **jq** — Statically-linked C CLI from upstream `jqlang/jq` releases.
  Same shape.
* **ripgrep** — Statically-linked Rust CLI from `BurntSushi/ripgrep`
  releases. Same shape.

None of them register LaunchAgents, install `/System/` patches, or
touch `~/Library/Preferences/`. A shared DPREFIX is safe for the PoC
tools as a class. **The doc reserves a future migration path to
per-package prefixes** — the manifest format gains a
`darling_prefix_id=<id>` key in D2 (default `shared`) that selects
which prefix subtree the launcher binds; per-package prefixes are a
config flip, not a re-arch (mirrors W1's `wine_prefix_id` reservation).

## Layout schema

The single shared DPREFIX lives at a stable path inside the rootfs so
the launcher can bind it deterministically. Per-package payloads live
under `/Applications/repro-store/<hash>/` inside the macOS-shaped
filesystem that Darling provisions in the prefix.

```
ReproOS rootfs
==============

  /opt/reproos-foreign/darling-binaries/                   Darling itself (.deb-harvested
    usr/                                                   from upstream releases;
      bin/darling                                          ~113 MB compressed,
      libexec/darling/                                     ~580 MB extracted).
        macOS/                                             Shape: a self-contained
        usr/                                               extracted .deb closure
        System/                                            rooted under usr/.
      lib/x86_64-linux-gnu/...
      share/darling/...

  /opt/reproos-foreign/darling-prefix/                     SHARED DPREFIX
    Applications/                                          (~5 MB after first
      repro-store/                                         `darling shell echo ok`;
        <fzf-hash>/                                        baked at ISO build time so
          bin/                                             first invocation has no
            fzf                                            cold-start penalty).
        <jq-hash>/                                         <<< OUR addition.
          bin/                                             One subtree per macOS
            jq                                             package.
        <ripgrep-hash>/                                    Catalog points exec_path at
          bin/                                             /Applications/repro-store/
            rg                                             <hash>/bin/<binary>.
    Library/                                               Darling-provided directories
    System/                                                (macOS filesystem shape).
    Users/
    private/
    usr/
    var/

  /opt/reproos-foreign/darling-prefix.manifest             JSON sidecar:
                                                          {
                                                            "darling_prefix_id": "shared",
                                                            "macos_version": "<from Darling>",
                                                            "darling_version": "<from .deb>",
                                                            "initialized_at": "<utc>",
                                                            "subtree_count": 3,
                                                            "subtrees": [
                                                              {"hash": "<fzf>", "binaries": ["bin/fzf"]},
                                                              ...
                                                            ]
                                                          }

  /usr/local/bin/darling-fzf                               Per-binary distro-tagged
  /usr/local/bin/darling-jq                                shim; exec()s
  /usr/local/bin/darling-rg                                reprobuild-sandbox-launcher
                                                          --manifest=<...>
                                                          (the manifest carries
                                                          runtime=darling + exec_path).
```

### Per-package store layout inside the DPREFIX

Each macOS catalog entry materializes as:

```
$DPREFIX/Applications/repro-store/<hash>/
├── bin/
│   └── <binary>          # Or multiple binaries for tools that ship companions.
├── share/                # Optional: data files.
└── manifest.json         # Per-package metadata (catalog hash, source URL, sha256).
```

The `<hash>` is the realization hash of the macOS package (BLAKE3 of
the catalog entry's `dependency_closure` + content sha256 of the
Mach-O payloads). Identical shape to W1's `drive_c/repro-store/<hash>/`,
just rooted under `Applications/repro-store/` so Darling resolves it
as `/Applications/repro-store/<hash>/` inside the macOS-shaped
filesystem.

**Why `/Applications/repro-store/`, not `/usr/local/bin/`?** macOS
convention is that third-party software lives under `/Applications/`
or `/opt/`. Darling honours both. We pick `/Applications/repro-store/`
because:

1. The campaign spec already baked this path into the D-phase
   integration test design (matching W1's `drive_c/repro-store/`).
2. `/usr/local/` inside the DPREFIX is one of the dirs Darling
   actively manages for its own bundled tools (`brew`, `installer`,
   etc.) — keeping our subtree well separated avoids name collisions.
3. macOS apps that look up paths relative to the bundle root expect
   `/Applications/<bundle>` semantics; the same shape is friendlier
   when we add bundled `.app` directories in a future milestone.

## Darling provisioning path

The PoC harvests Darling from the **upstream release page** —
`https://github.com/darlinghq/darling/releases/<tag>/debs_<date>.zip`
— a 118 MB zip containing 21 `.deb` packages targeting Ubuntu noble
(24.04). The packages split into:

* **CLI subset** (installed for the PoC): `darling-core`,
  `darling-system`, `darling-cli`, `darling-cli-gui-common`,
  `darling-cli-python2-common`. ~108 MB extracted; this is what's
  needed for `darling shell --command "<cli-binary>"`.
* **Optional metapackage** (NOT installed): `darling` (pulls in
  `darling-perl`, `darling-ruby`, `darling-python2`, `darling-gui`,
  `darling-pyobjc` → ~70 MB additional, none required by our CLI tool
  selection). Skipping the metapackage is the key ISO-size lever.
* **GUI subset** (NOT installed): `darling-gui`, `darling-gui-stubs`,
  `darling-cli-devenv-gui-*`, `darling-iokitd`, `darling-iosurface`,
  `darling-jsc` (JavaScriptCore + WebKit) — none required for
  headless CLI tools. ~40 MB compressed savings.

```
recipes/catalog/foreign/darling/darling-debs.json
├── source_url: github.com/darlinghq/darling/releases/download/
│              v0.1.20260608/debs_20260608.zip
├── pin_sha256: <pinned sha256 of debs_20260608.zip>
├── selected_debs: [
│     "darling-core_0.1.20260609~noble_amd64.deb",
│     "darling-system_0.1.20260609~noble_amd64.deb",
│     "darling-cli_0.1.20260609~noble_amd64.deb",
│     "darling-cli-gui-common_0.1.20260609~noble_amd64.deb",
│     "darling-cli-python2-common_0.1.20260609~noble_amd64.deb"
│   ]
└── dependency_closure: [libc6 (>= 2.38), libc6-i386, libfuse2t64, libstdc++6]
                        (transitive, ~25 MB additional)
```

The harvested `.deb`s are extracted into the content-addressed store at
`/store/prefixes/darling/<version>/<hash>/`; the build script exposes
a `darling-binaries` overlay symlink/bind at
`/opt/reproos-foreign/darling-binaries/` for the launcher to bind into
the namespace.

**Rejected alternative: from-source Darling build.** Build needs 16 GB
disk + 4 GB RAM + clang-15 + bison + flex + libfuse-dev + libudev-dev
+ glibc-devel.i686 + cmake; takes 30-60 min on a modern host. For PoC
the prebuilt .debs are the obvious win. From-source is reserved as a
post-PoC option if a reproducibility regulator demands it (Darling's
release-zip .debs are signed but not byte-deterministic).

**Rejected alternative: Darling from Debian/Ubuntu apt repos.**
Darling is NOT in Debian or Ubuntu's apt archives. Only an unrelated
Rust `darling` proc-macro crate (`librust-darling-dev`) shows up in
apt search. The Darling project maintains its own .deb publication via
GitHub Releases.

**Rejected alternative: snap or flatpak.** Snap's host-distro
restrictions and flatpak's runtime layering interact badly with the
reproos rootfs model. The release-page .debs are the lowest-impedance
path.

## DPREFIX initialization timing — bake at ISO build

`darling shell --command true` (first invocation) cold-inits the
DPREFIX: lays out `/System/`, `/Applications/`, `/Library/`,
`/Users/<uid>/`, `/private/`, etc., extracts bundled macOS framework
stubs into the prefix overlay, and starts `darlingserver`. Cold init
takes ~10-30 s on a modern host and is **not byte-deterministic**
(timestamps + per-invocation overlay UUIDs vary). For PoC the prefix
is:

1. Built once at ISO-build time on the build host by
   `recipes/reproos-mvp-config/darling-prefix-init.sh` (this milestone).
2. Captured as a tarball into the initramfs.
3. Extracted at boot to `/opt/reproos-foreign/darling-prefix/` by the
   existing initramfs prefix-extraction step (already used for Linux
   foreign packages in Phase X1 and for the WINEPREFIX in Phase W).

Trade-offs:

| Timing | ISO size cost | First-run cost | Determinism | PoC fit |
|--------|---------------|----------------|-------------|---------|
| **Bake at ISO build** | +~600 MB | 0 (already initialized) | Build-time only (host-influenced; documented limitation) | Good — snappy demo. |
| Init at first boot | 0 | ~30 s + overlayfs mount | Run-time; subject to in-VM state | Bad — cold-start tax. |
| Init lazily on first `darling <binary>` invocation | 0 | ~30 s per binary (or shared cache) | Same as first-boot | Bad — surprises the demo. |

**Decision: bake.** The non-determinism limitation is documented and
deferred to a post-PoC "reproducible DPREFIX" follow-up; for PoC the
prefix tarball's sha256 is pinned in the manifest sidecar so re-builds
at least detect drift. Same pattern as W1's wineboot bake decision.

### overlayfs caveat

Darling uses `overlayfs` for the DPREFIX. Two consequences:

1. **The DPREFIX cannot live on NFS, eCryptfs, or some FUSE
   filesystems.** ReproOS uses ext4 in its initramfs — no issue.
2. **The DPREFIX path on the build host must not be inside a chroot
   that already uses overlayfs on the same directory.** The D1 verify
   script picks `/tmp/d1-test-prefix/` to avoid the user's home dir
   (which on some configurations is overlay-backed).

## Launcher integration sketch (D2 will implement)

The D2 milestone extends the C3 manifest format with a
`runtime=darling` key and one new shape of bind line. The D1 doc
fixes the bind set so D2 can implement against a stable contract.

### D2 manifest format additions

New key/value lines (forward-compatible — older launcher binaries
ignore unknown keys per `MANIFEST-FORMAT.md`):

```manifest
# C3 base manifest (Linux closure dep bind set unchanged)
exec=/opt/reproos-foreign/darling-binaries/usr/bin/darling

# NEW: declares the runtime; absent = Linux native (C3 behaviour).
runtime=darling

# NEW: DPREFIX path on the host (passed to darling via DPREFIX env var).
darling_prefix=/opt/reproos-foreign/darling-prefix

# NEW: the path Darling will execute, expressed as a macOS-style
# POSIX path (translates to a path inside the DPREFIX overlay).
darling_exec=/Applications/repro-store/<fzf-hash>/bin/fzf

# Existing bind lines: Darling binaries closure, the DPREFIX itself,
# and the per-package payload subtree (already inside the prefix, so
# this is a no-op overlap on the shared prefix path — listed
# explicitly for non-shared prefix configurations).
/opt/reproos-foreign/darling-binaries:/opt/reproos-foreign/darling-binaries:rbind,ro
/opt/reproos-foreign/darling-prefix:/opt/reproos-foreign/darling-prefix:rbind

# Filesystem services (darlingserver needs /proc + /dev/fuse).
proc
/dev/fuse:/dev/fuse:rbind
```

### D2 launcher behaviour

When `runtime=darling` is present, the launcher:

1. Parses the manifest as today (D2 adds the three new keys).
2. Performs the bind set as today.
3. Sets `$DPREFIX` to the value of `darling_prefix=`.
4. `exec()`s `<exec> shell <darling_exec> <forwarded argv...>` — i.e.
   invokes the Darling launcher, asks it to run the macOS-side binary
   directly (positional argv form), and forwards the launcher's `--`-
   delimited argv to it. The macOS-side binary inherits stdin/stdout/
   stderr from the launcher.

Note: `darling shell <binary> <args>` is the documented one-shot
invocation form. The `--command "<cmd>"` form documented in some
third-party tutorials is NOT what current Darling supports — `darling`
treats `--command` as a binary name and tries to exec it. D1 P3 verified
the positional form works against four candidate Mach-O binaries.

### Argv forwarding

Darling's `shell <binary> <args>` reflects each argv element directly
into the macOS-side argv vector — no shell parsing or word-splitting.
The launcher therefore passes the forwarded argv elements verbatim:

```
<exec> shell <darling_exec> <argv[1]> <argv[2]> ...
```

This is simpler than the W1 WINE path (which doesn't need quoting
either because `wine <path>` is also positional). No special shell-
quote helpers needed for the Darling path.

## Catalog format extension for macOS packages (D3 will implement)

D3 adds macOS catalog entries (`recipes/catalog/macos/{fzf,jq,rg}.json`)
with the following new keys layered on the existing C1/C2 catalog
shape:

```json
{
  "name": "fzf",
  "runtime": "darling",
  "version": "0.60.0",
  "source_url": "https://github.com/junegunn/fzf/releases/download/v0.60.0/fzf-0.60.0-darwin_amd64.tar.gz",
  "sha256": "<pinned>",
  "darling_prefix_id": "shared",
  "exec_path": "/Applications/repro-store/<hash>/bin/fzf",
  "dependency_closure": []
}
```

*fzf is pinned to v0.60.0+ per the D1 P3 finding: v0.55.0's Go-1.22
Mach-O TLV path crashes silently under Darling 0.1.20260609.*

* `runtime=darling` — selects the Darling launcher path.
* `darling_prefix_id` — selects which DPREFIX subtree the package
  lands in (default `shared`; reserved for future per-package
  isolation).
* `exec_path` — DPREFIX-absolute path (passed verbatim to
  `darling_exec=` in the generated manifest).
* `dependency_closure` — empty for the PoC tools (statically linked
  Mach-O binaries). Non-empty entries would trigger the same
  realize-time graph walk used for Linux packages, with subtrees
  placed alongside the root under the same DPREFIX.

The catalog payload extraction step (D3) unpacks the `.tar.gz` /
`.zip` into `/store/prefixes-mac/<hash>/` on the build host; the build
pipeline then copies the subtree into the DPREFIX at
`/Applications/repro-store/<hash>/`.

## Tool selection for the D-phase PoC

After surveying upstream releases for CLI-only macOS tools with stable
amd64 prebuilt binaries:

| Candidate | Selection | Rationale |
|-----------|-----------|-----------|
| **fzf** | **SELECTED — but pin v0.60.0+** | Statically-linked Go binary; `darwin_amd64` is a first-class release target. Single binary, no Cocoa, no LaunchAgent. Already in reprobuild's harvest fleet (Linux version) — proven catalog shape. *D1 P3 smoke surfaced a Darling-vs-fzf version gap: fzf 0.55.0 (Go 1.22) crashes silently (exit 1, empty stdout) under Darling 0.1.20260609; fzf 0.60.0 (Go 1.23) works. Likely cause: Go's macOS TLV / pthread emulation path matured between releases and the older binary trips an unimplemented Darling syscall. D3 must pin v0.60.0 or later. Reusable in the future as a Darling-loader-coverage canary.* |
| **jq** | **SELECTED** | Statically-linked C binary; `jq-macos-amd64` is a stable release asset (renamed from the legacy `jq-osx-amd64` asset name as of jq 1.7+). Single binary, no Cocoa. Same harvest shape as fzf. *D1 P3 smoke (jq 1.7.1): `jq --version` prints `jq-1.7.1` cleanly inside Darling.* |
| **ripgrep** | **SELECTED** | Statically-linked Rust binary; `ripgrep-<ver>-x86_64-apple-darwin.tar.gz` is published every release. Single binary, no Cocoa. Same shape. *D1 P3 smoke (ripgrep 14.1.1): `rg --version` prints `ripgrep 14.1.1 (rev 4649aa9700)` plus the SIMD feature lines cleanly inside Darling.* |
| yq (mikefarah/yq) | RESERVED as backup | Go binary; `yq_darwin_amd64` release asset. D1 P3 smoke prints `yq (https://github.com/mikefarah/yq/) version v4.45.1` cleanly under Darling. Held in reserve in case D3 hits unexpected breakage on one of the three primary tools. |
| brew (Homebrew) | DEFERRED | Bash+Ruby wrapper; would need `darling-ruby` (~25 MB extra) and would invoke `git` + `curl` + `tar` from inside Darling — a much larger surface area. Excellent demonstration tool for a follow-up milestone but heavy for PoC. |
| mas (Mac App Store CLI) | REJECTED | Useless without an Apple ID / App Store account. |
| Xcode tools (clang/ld/...) | REJECTED | Huge (Xcode is multi-GB); known partially-working in Darling. |
| pkgutil / installer | REJECTED as user-facing | Useful for the prefix-init flow if we ever ship `.pkg` payloads, but the PoC tools ship as plain tarballs (.tar.gz) — no `.pkg` involvement. Mentioned in the README as "limited cousin of macOS's installer." |

**Selected for D2/D3/D4: fzf + jq + ripgrep.** Three tools; mirrors
W1's three-tool selection (gh + just + ninja). All three are
self-contained Mach-O CLI binaries with no `.app` bundle, no
LaunchDaemon, no shared user-defaults state. Each catalog entry will
ship a deterministic banner string in `darling_version_banner` (e.g.
`"fzf 0.55.0 (linux_amd64)"` … note that fzf reports the build platform,
not the runtime platform; D3 will pin the banner to whatever the
upstream darwin_amd64 build emits).

**Fallback if a tool fails under Darling**: D1's `darling-prefix-init.sh`
includes an optional `--smoke-binary <path>` flag that invokes the
candidate binary inside the freshly-initialized prefix and reports its
exit code + first few stdout lines. If D2's wiring against any of
fzf/jq/rg surfaces a Darling incompatibility, D3 can swap in a
different tool from the candidate list without re-doing the
architecture. The catalog format is tool-agnostic.

## Known limitations (PoC scope)

These limitations are accepted for the PoC; they are documented as
post-PoC follow-ups but DO NOT block D1-M2.

1. **DPREFIX byte-determinism is build-host influenced.** Darling
   writes timestamps + per-instance UUIDs into the prefix's overlay
   metadata + filesystem mtimes. Two builds of the same Darling
   version on the same host produce different-byte prefixes.
   Mitigation: pin the tarball sha256 in the manifest sidecar so
   re-builds detect drift; a future milestone may rebuild Darling
   with deterministic UUIDs (matching the W1 wineboot follow-up).
2. **No Cocoa / GUI applications.** Darling's GUI subsystem
   (`darling-gui`, `darling-iokitd`, etc.) is preview-quality; the
   reproos rootfs ships no X11/Wayland anyway. PoC tools are
   CLI-only by selection. The `darling shell --command "<cli>"`
   invocation path doesn't go through the GUI layers.
3. **No Apple Silicon (arm64) native binaries.** The Darling project's
   prebuilt .debs target x86_64 hosts and execute x86_64 Mach-O
   binaries. PoC packages must ship a `darwin_amd64` build target.
   `darwin_arm64`-only software is out of scope.
4. **No code-signature validation.** Darling does not enforce Apple
   gatekeeper / notarization. macOS binaries that refuse to run
   without notarization may behave differently. The PoC tools
   (fzf/jq/rg) ship unsigned upstream releases.
5. **No `.pkg` installer flow for PoC tools.** The selected PoC tools
   ship as plain tarballs (`.tar.gz`). The `installer -pkg` flow that
   Darling supports is reserved as a follow-up for catalog entries
   that wrap `.pkg` payloads. The D1 doc surveys the path but D2/D3
   don't exercise it.
6. **Darling binary closure is large.** **~285 MB extracted for the
   CLI subset** (measured 2026-06-15: `du -sh /usr/libexec/darling`).
   This is half the older 580 MB planning estimate but still cuts into
   the 200 MB ISO budget; M1 will need to decide a trim playbook.
   Identified fat directories (host-side `/usr/libexec/darling/`):
   - `libexec/darling/usr/lib/` — bundled libSystem + dyld + framework
     stubs. The bulk of the 285 MB. Required by any Mach-O loader path.
   - `libexec/darling/usr/share/` — localization + SDK headers + man
     pages. Trim candidate (PoC tools don't read localized strings or
     SDK headers at runtime).
   - `libexec/darling/System/Library/` — macOS-side framework stubs;
     required for jq/ripgrep/fzf libSystem linkage.
   - `darling-cli-python2-common` — installed because `darling-cli`
     depends on it, but only needed if a tool invokes Python 2. Can
     be trimmed if catalog tools don't need it. M1 will probe.
   Candidates for removal post-bake: `share/darling/sdk/` if no tool
   loads SDK headers at runtime, `libexec/darling/macOS/usr/share/`
   localization data, JIT cache files. M1 will measure and decide
   the trim playbook.
7. **First-invocation cold start (~10 s)** even after the prefix is
   pre-initialized — `darlingserver` has to start up. The D2 launcher
   may want to pre-warm `darlingserver` at boot (via a systemd-style
   service or an `rc.local` hook in the initramfs). D4's wall-clock
   budget allows for one cold start.
8. **Preview-quality risk on any given tool.** Even
   `darling shell --command "echo ok"` is documented working; running
   real CLI tools may surface unimplemented syscall stubs. The D1 P3
   verification gate includes an optional smoke test against the
   tool of choice; D3 can swap tools if needed.
9. **No persistent macOS user state.** Each invocation gets a fresh
   `Users/<uid>/Library/` (overlay upper-layer is dropped on
   container teardown). PoC tools are stateless — fine. Tools that
   rely on `~/Library/Preferences/<bundle>.plist` persistence are
   out of scope.
10. **WSL2 host: no special kernel module needed.** As of Darling
    `v0.1.20260608` (and several releases prior), Darling no longer
    requires a Linux kernel module. The campaign-spec D1 risk note
    about WSL2 kernel-module unavailability is **resolved upstream**
    and no longer a PoC blocker. Documented here so future
    milestones don't re-relitigate.

## Verification (D1 P3 gate)

`recipes/reproos-mvp-config/darling-prefix-init.sh --prefix-dir <path>`
creates a fresh DPREFIX in a Linux environment. Acceptance:

* `$DPREFIX/Applications/` exists post-init.
* `$DPREFIX/System/` exists post-init.
* `$DPREFIX/Applications/repro-store/` exists (pre-created by the
  script).
* `DPREFIX=<path> darling shell --command "echo ok"` prints `ok`.

The script unsets X11-related env vars to ensure a headless cold
init. The verification is documented as having three acceptable
outcomes:

1. **Best case**: `darling shell --command "echo ok"` prints `ok` +
   the `Applications/` skeleton is fully populated → D1 P3 PASS.
2. **Acceptable case**: `darling shell` runs but logs
   `darlingserver`-startup info messages → D1 P3 PASS with
   documented warnings.
3. **Failure case**: `darling shell` hangs waiting for
   `darlingserver` or aborts on a missing FUSE mount → D1 P3 FAIL;
   mitigation documented as a path forward.

The execution result is recorded in the D1 milestone's Outcome
section in the campaign spec at review time.

### D1 P3 gate execution record (2026-06-15, repro-darling-test WSL)

```
$ wsl --import repro-darling-test D:\repro-wsl\repro-darling-test \
        <noble-server-cloudimg-amd64-root.tar.xz> --version 2
The operation completed successfully.

$ wsl -d repro-darling-test -e bash -c "lsb_release -a"
Distributor ID: Ubuntu
Description:    Ubuntu 24.04.4 LTS
Release:        24.04
Codename:       noble

$ wsl -d repro-darling-test -e bash -c "ldd --version | head -1"
ldd (Ubuntu GLIBC 2.39-0ubuntu8.7) 2.39

$ wsl -d repro-darling-test -e bash -c "curl -sL -o /tmp/debs.zip \
        https://github.com/darlinghq/darling/releases/download/v0.1.20260608/debs_20260608.zip && \
        unzip -q /tmp/debs.zip -d /tmp/debs && \
        cd /tmp/debs/debs_20260609 && \
        apt-get install -y --no-install-recommends \
          ./darling-core_*~noble_amd64.deb \
          ./darling-system_*~noble_amd64.deb \
          ./darling-cli_*~noble_amd64.deb \
          ./darling-cli-gui-common_*~noble_amd64.deb \
          ./darling-cli-python2-common_*~noble_amd64.deb"
Setting up libc6-i386 (2.39-0ubuntu8.7) ...
Setting up libfuse2t64:amd64 (2.9.9-8.1build1) ...
Setting up darling-core (0.1.20260609~noble) ...
Setting up darling-cli-python2-common (0.1.20260609~noble) ...
Setting up darling-system (0.1.20260609~noble) ...
Setting up darling-cli-gui-common (0.1.20260609~noble) ...
Setting up darling-cli (0.1.20260609~noble) ...

<see "D1 P3 gate execution record" below for the prefix-init + smoke results>
```

Gate result: **see end-of-document execution record**.

The full execution log lives below the architecture document so it
can be amended if a future re-probe surfaces additional findings.

## D1 P3 gate execution record (2026-06-15, repro-darling-test WSL)

Gate ran against real Darling 0.1.20260609 installed in the
`repro-darling-test` WSL Ubuntu 24.04 noble distro (kernel
6.18.33.1-microsoft-standard-WSL2). All five `darling-cli-*` packages
from the upstream `debs_20260609` release zip are installed via
`apt-get install -y --no-install-recommends` per the provisioning path
documented in §"Darling provisioning path".

```
$ wsl -d repro-darling-test -e bash -c "darling --version || true; dpkg-query -W -f='%{Package} %{Version}\n' 'darling-*'"
darling-cli 0.1.20260609~noble
darling-cli-gui-common 0.1.20260609~noble
darling-cli-python2-common 0.1.20260609~noble
darling-core 0.1.20260609~noble
darling-system 0.1.20260609~noble

$ wsl -d repro-darling-test -e bash -c "bash darling-prefix-init.sh --prefix-dir /tmp/d1-test-prefix --verbose"
[darling-init][verbose] darling_bin=/usr/bin/darling
[darling-init] darling version: 0.1.20260609~noble
[darling-init] prefix dir: /tmp/d1-test-prefix
[darling-init] store subdir: Applications/repro-store/
[darling-init] running darling shell echo ok (this may take ~10s on first invocation)
[darling-init][verbose] invoking: /usr/bin/darling shell echo ok
[darling-init] darling-shell output:
[darling-shell] Setting up a new Darling prefix at /tmp/d1-test-prefix
[darling-shell] ok
[darling-init][verbose] pre-created store subdir: /tmp/d1-test-prefix/Applications/repro-store
[darling-init][verbose] wrote sentinel: /tmp/d1-test-prefix/.reproos-darling-prefix.json
[darling-init][verbose] OK    Applications dir: /tmp/d1-test-prefix/Applications
[darling-init][verbose] OK    Library dir: /tmp/d1-test-prefix/Library
[darling-init][verbose] OK    System dir: /tmp/d1-test-prefix/System
[darling-init][verbose] OK    Users dir: /tmp/d1-test-prefix/Users
[darling-init][verbose] OK    Volumes dir: /tmp/d1-test-prefix/Volumes
[darling-init][verbose] OK    darlingserver socket: /tmp/d1-test-prefix/.darlingserver.sock
[darling-init][verbose] OK    Applications/repro-store: /tmp/d1-test-prefix/Applications/repro-store
[darling-init] verification PASS
[darling-init]   prefix:          /tmp/d1-test-prefix
[darling-init]   applications:    /tmp/d1-test-prefix/Applications
[darling-init]   store subdir:    /tmp/d1-test-prefix/Applications/repro-store
[darling-init]   darling version: 0.1.20260609~noble
[darling-init]   cold size:       5.2M
EXIT=0

$ wsl -d repro-darling-test -e bash -c "du -sh /tmp/d1-test-prefix /usr/libexec/darling"
5.2M    /tmp/d1-test-prefix
285M    /usr/libexec/darling
```

Gate result: **PASS**.

### D1 P3 smoke-binary results (per-candidate tool probes)

The `--smoke-binary` flow was exercised against four candidate Mach-O
binaries to validate the §"Tool selection for the D-phase PoC" picks:

```
$ wsl -d repro-darling-test -e bash -c "DPREFIX=/tmp/d1-smoke-prefix darling shell /Volumes/SystemRoot/tmp/jq-osx --version"
jq-1.7.1
EXIT=0                                                                   # jq 1.7.1 — PASS

$ wsl -d repro-darling-test -e bash -c "DPREFIX=/tmp/d1-smoke-prefix darling shell /Volumes/SystemRoot/tmp/rg/rg --version"
ripgrep 14.1.1 (rev 4649aa9700)
features:+pcre2
simd(compile):+SSE2,+SSSE3,-AVX2
simd(runtime):+SSE2,+SSSE3,+AVX2
PCRE2 10.43 is available (JIT is available)
EXIT=0                                                                   # ripgrep 14.1.1 — PASS

$ wsl -d repro-darling-test -e bash -c "DPREFIX=/tmp/d1-smoke-prefix darling shell /Volumes/SystemRoot/tmp/fzf-darwin/fzf --version"
EXIT=1                                                                   # fzf 0.55.0 — FAIL (silent; empty stdout)

$ wsl -d repro-darling-test -e bash -c "DPREFIX=/tmp/d1-smoke-prefix darling shell /Volumes/SystemRoot/tmp/fzf-new/fzf --version"
0.60.0 (3347d61)
EXIT=0                                                                   # fzf 0.60.0 — PASS

$ wsl -d repro-darling-test -e bash -c "DPREFIX=/tmp/d1-smoke-prefix darling shell /Volumes/SystemRoot/tmp/yq-darwin --version"
yq (https://github.com/mikefarah/yq/) version v4.45.1
EXIT=0                                                                   # yq 4.45.1 — PASS (reserved backup)
```

Findings:

* **jq 1.7.1**, **ripgrep 14.1.1**, **fzf 0.60.0** all PASS. These are
  the D3-pinnable versions.
* **fzf 0.55.0** crashes silently (exit 1, empty stdout, no diagnostic
  to stderr) — a Darling-loader / Go-1.22-TLV gap. Reusable as a
  Darling-loader-regression canary; D3 must pin v0.60.0 or later.
* **yq 4.45.1** PASS — held in reserve in case D3 surfaces an
  unexpected break.

### Diagnostic findings folded back into the script

* Darling's overlay-init detects "first run" by **absence of the prefix
  dir itself**. If the dir already exists (even empty), `darling shell`
  skips the `Setting up a new Darling prefix at <path>` step and then
  fails to connect to the (un-launched) shellspawn socket with
  `Error connecting to shellspawn in the container
  (.../var/run/shellspawn.sock): No such file or directory`. The script
  detects the empty-dir half-baked-state case and `rmdir`s the directory
  so `darling shell` re-creates it. First-run revision of the script
  caught this immediately and the fix landed in the same pass.
* The Darling launcher does NOT support `--version` on itself; the
  script reads the version via `dpkg-query -W darling-core` instead.
* `darling shell echo ok` (positional form) is the correct invocation —
  the `--command "<cmd>"` form documented in some third-party tutorials
  is not what current Darling supports (it treats `--command` as a
  binary name and tries to exec it). Updated the launcher-integration
  sketch in §"D2 launcher behaviour" to use the positional form.
* The host filesystem is exposed inside the macOS-shaped namespace as
  `/Volumes/SystemRoot/`. Smoke-binary probes use that mapping rather
  than copying the candidate binary into the prefix.

### Regression baseline (2026-06-15)

```
$ bash D:/metacraft/reprobuild-specs/tools/bootstrap-cache/test_chain_walk.sh
ReproOS R4 AMD64 real-build chain walk: PASS   (23/23 chain steps)

$ nim c -r --threads:on --hints:off --warnings:off libs/repro_local_store/tests/t_c3_sandbox_manifest.nim
[Suite] C3 sandbox_manifest
  [OK] walkCatalogGraph: minimal three-package transitive set
  [OK] walkCatalogGraph: missing dep raises CatalogResolveError
  [OK] walkCatalogGraph: tolerates the C2-fixture full-transitive shape
  [OK] composeSandboxManifest: deterministic sort + raises on missing prefix
  [OK] composeSandboxManifest: emits bind set in sorted order
  [OK] serializeManifest: canonical bytes
  [OK] generateLauncherShim: shape
  [OK] materializeSandboxManifest: end-to-end                              (8/8)
```

A+B+C+D+X1+X2+W1+W2+W3+W4 baselines remain green.
