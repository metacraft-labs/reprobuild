# `reprobuild-sandbox-launcher` Manifest Format

This document specifies the runtime bind-mount manifest consumed by
`reprobuild-sandbox-launcher` (C3 deliverable for the
`ReproOS-Generations-And-Foreign-Packages` campaign).

## File location

The manifest is emitted at realize time alongside each foreign package's
content-addressed prefix:

    <store-root>/prefixes/<package>/<realization-hash>/launcher.manifest

The per-binary shim at `$prefix/bin/<binary>` references this path via
`reprobuild-sandbox-launcher --manifest=$prefix/launcher.manifest --
/actual/store/path/binary "$@"`.

## Encoding

UTF-8 text, LF line endings, no BOM. Lines are byte-stable across
re-emission for the same input catalog so the launcher manifest can
itself be content-addressed.

## Line grammar

The parser accepts the following line forms.

### Comments / blanks

* Empty / whitespace-only lines are ignored.
* Lines whose first non-whitespace character is `#` are ignored.

### Special directives

* `proc` — mount procfs at `/proc` inside the new mount namespace
  after the bind-mount pass.
* `sys`  — mount sysfs at `/sys` inside the new mount namespace.

### Key/value lines

* `exec=<absolute-path>` — the wrapped binary the launcher will
  `execve()` after namespace setup. The CLI's `--exec=<path>` overrides
  this line. Required when `runtime=` is absent or `runtime=native`;
  ignored when `runtime=wine` (the launcher exec()s `wine_bin`
  instead).
* `cwd=<absolute-path>` — `chdir()` to this directory immediately
  before `execve()`. Optional.

#### W2 runtime selection keys

The following keys select between the native C3 runtime (default) and
the WINE runtime added in W2. Older launcher binaries (pre-W2) ignore
unknown keys per the forward-compatibility contract below, so a W2
manifest will degrade to a native-style execve(wine_bin), which is
still well-defined; pre-W2 launchers simply skip the env setup +
argv-rewrite that the W2 launcher performs.

* `runtime=native` — explicit selection of the C3 behaviour
  (equivalent to omitting the key). The launcher exec()s `exec=`.
* `runtime=wine` — WINE runtime. The launcher:
    1. Performs the bind set as usual.
    2. Verifies `${wine_prefix}/drive_c/` exists post-bind.
    3. Sets `$WINEPREFIX = wine_prefix`,
       `$WINEDEBUG = -all`, and
       `$WINEDLLOVERRIDES = mscoree,mshtml=`
       (the latter two are set with overwrite=0, so the caller can
       override them via the host environment).
    4. exec()s `wine_bin` with argv = `[wine_bin, wine_exec, <forwarded
       args after `--`>]`.

When `runtime=wine` is set, the following three keys are consulted:

* `wine_prefix=<absolute-path>` — WINEPREFIX root on the host. Bound
  into the namespace by the manifest's bind lines and exported as
  `$WINEPREFIX` by the launcher. Required.
* `wine_exec=<path>` — the executable WINE is asked to run. WINE
  accepts both forward-slash POSIX paths under the prefix and
  drive-letter form (`C:/path/to.exe`); both are passed verbatim.
  Required.
* `wine_bin=<absolute-path>` — the WINE binary. Defaults to
  `/usr/bin/wine` if absent.

#### D2 runtime=darling selection keys

The D2 milestone adds a third runtime alongside `native` and `wine`.
The shape mirrors the wine triple exactly; pre-D2 launchers ignore
unknown keys per the forward-compatibility contract below.

* `runtime=darling` — Darling runtime (Mach-O Linux execution). The
  launcher:
    1. Performs the bind set as usual.
    2. Verifies `${darling_prefix}/Applications/` exists post-bind.
    3. Sets `$DPREFIX = darling_prefix`.
    4. exec()s `darling_bin` with argv = `[darling_bin, "shell",
       darling_exec, <forwarded args after `--`>]`. The `shell` form
       is the documented one-shot invocation per D1 P3; `--command`
       is NOT supported by current Darling.

When `runtime=darling` is set, the following three keys are consulted:

* `darling_prefix=<absolute-path>` — DPREFIX root on the host. Visible
  inside the launcher's mount namespace via inherited propagation (do
  NOT add an identity rbind — it breaks Darling's internal overlayfs;
  see the runtime=darling example below). Exported as `$DPREFIX` by
  the launcher. Required.
* `darling_exec=<path>` — the macOS-style POSIX path Darling will run,
  e.g. `/Applications/repro-store/<hash>/bin/<binary>`. Passed verbatim
  to `darling shell`. Required.
* `darling_bin=<absolute-path>` — the Darling launcher binary. Defaults
  to `/usr/bin/darling` if absent.

Any value other than `native`, `wine`, or `darling` for `runtime=` is
rejected at parse time.

#### M6 system build-user keys (`reprobuild-buildusers`)

Two optional keys select the **off-by-default** system build-user mode,
the hardened multi-user posture in which a build executes as a
dedicated, unprivileged system account instead of as the invoking user:

| Key | Meaning |
| --- | --- |
| `build_uid=<n>` | numeric uid of the system build account the target must run as |
| `build_gid=<n>` | numeric gid of the build group |

Semantics:

* **Both or neither.** A manifest carrying only one of the pair is a
  parse error (exit 1), not a half-configured run.
* **Neither may be 0.** `build_uid=0` is rejected: a build user that is
  root is not a build user.
* **Values must be numeric.** Names are not resolved. `getpwnam(3)` is
  not async-signal-safe and the launcher must stay allocation-free on
  this path, so the *caller* resolves the account -- with `getent(1)` or
  equivalent -- and passes the resolved ids. A non-numeric value is a
  parse error rather than a silent 0.
* **Real root required.** The keys are honoured only when the launcher
  itself runs as uid 0. An unprivileged launcher handed a build-user
  manifest exits **6** and executes nothing; it never falls back to
  running the build as the calling user.
* **Ordering.** The drop happens after every mount and immediately
  before `execve(2)`: `setgroups(0)`, then `setgid`, then `setuid`. The
  launcher then re-reads the credentials from the kernel and requires
  that `seteuid(0)` *fails*, so a drop that did not actually take effect
  cannot be mistaken for one that did.
* **No user namespace is created in this mode.** The caller is already
  root, so `setup_namespace()` takes the pre-existing `outer_uid == 0`
  branch and unshares only `CLONE_NEWNS`. Containment here comes from
  the unprivileged uid, not from a uid map.

When both keys are **absent** -- the default, per-user shape, and the
only shape a default install emits -- none of the above executes and the
launcher behaves exactly as it did before M6.

> **Deployment hazard.** Unknown keys are tolerated (see *Forward
> compatibility* below). That tolerance means an **older launcher binary
> will silently ignore `build_uid=`** and run the build with whatever
> privilege it already holds -- as root, if the caller was root. The
> launcher binary and the component generating the manifest must
> therefore be upgraded together. Do not rely on a manifest key alone to
> enforce a privilege boundary across mixed launcher versions; check the
> launcher version at deploy time.

### Bind-mount lines

The default line form is:

    <source>:<target>:<flags>

* `source` — absolute path on the host (typically
  `<store-root>/prefixes/<dep-name>/<hash>/<subdir>`).
* `target` — absolute path inside the namespace where the bind will
  appear (typically an FHS-conventional path like `/lib`,
  `/usr/lib/x86_64-linux-gnu`, etc.).
* `flags` — comma-separated set, must include exactly one of
  `bind` or `rbind`. Optional flags: `ro` (apply `MS_RDONLY` via a
  second `MS_REMOUNT` mount(2) call).

If `target` does not exist inside the namespace, the launcher creates
it via `mkdir -p` semantics (tolerating `EROFS` on the read-only root).

## Example

```manifest
# Sandbox manifest for git 2.39.5 from debian/bookworm/20260601T000000Z
# Generated by libs/repro_local_store/.../sandbox_manifest.nim

exec=/store/prefixes/git/a1b2c3.../usr/bin/git

# Transitive dep closure (graph-walked from git.json):
/store/prefixes/libc6/0123abc.../lib:/lib:rbind,ro
/store/prefixes/libc6/0123abc.../lib:/lib64:rbind,ro
/store/prefixes/libcurl3-gnutls/cafe01.../usr/lib/x86_64-linux-gnu:/usr/lib/x86_64-linux-gnu:rbind,ro
/store/prefixes/libssl3/deadbe.../usr/lib/x86_64-linux-gnu:/usr/lib/x86_64-linux-gnu:rbind,ro

# Filesystem services
proc
sys
```

### Minimal `runtime=wine` example (W2)

```manifest
# WINE-runtime manifest for the gh Windows CLI.

runtime=wine
wine_prefix=/opt/reproos-foreign/wine-prefix
wine_exec=C:/repro-store/<gh-hash>/bin/gh.exe
wine_bin=/usr/bin/wine

# WINE binaries closure (apt-harvested; see W1 architecture doc).
/opt/reproos-foreign/wine-binaries:/opt/reproos-foreign/wine-binaries:rbind,ro

# Shared WINEPREFIX (read-write — wine writes to drive_c/users/...).
/opt/reproos-foreign/wine-prefix:/opt/reproos-foreign/wine-prefix:rbind

# wine needs procfs for process discovery.
proc
```

Notes:

* `exec=` is intentionally absent — the launcher exec()s `wine_bin`
  (defaulting to `/usr/bin/wine`) and passes `wine_exec` as the first
  argument.
* If a per-package payload subtree is also listed as an explicit bind
  with the same target as the prefix bind, the launcher silently
  skips the duplicate so manifest generators don't have to dedupe.
* The `proc` directive is required because `wine` and `wineserver`
  walk `/proc` to discover sibling processes.

### Minimal `runtime=darling` example (D2)

```manifest
# Darling-runtime manifest for the jq macOS CLI.

runtime=darling
darling_prefix=/opt/reproos-foreign/darling-prefix
darling_exec=/Applications/repro-store/<jq-hash>/bin/jq
darling_bin=/usr/bin/darling

# Darling binaries closure (.deb-harvested; see D1 architecture doc).
/opt/reproos-foreign/darling-binaries:/opt/reproos-foreign/darling-binaries:rbind,ro

# NOTE: do NOT add an identity rbind on darling_prefix here. Unlike
# WINEPREFIX, an identity rbind on darling_prefix breaks Darling's
# internal overlayfs setup and MUST NOT be added. The DPREFIX path is
# visible inside the mount namespace via inherited propagation.

# darlingserver needs procfs + /dev/fuse for the macOS-shaped overlay.
proc
/dev/fuse:/dev/fuse:rbind
```

Notes:

* `exec=` is intentionally absent — the launcher exec()s `darling_bin`
  (defaulting to `/usr/bin/darling`) with `shell <darling_exec>` as
  the first two arguments.
* Unlike WINEPREFIX, an identity rbind on `darling_prefix` (src == dest
  == darling_prefix) MUST NOT be added: Darling mounts overlayfs with
  upperdir/workdir under DPREFIX during `darling shell`, and overlay
  rejects a directory that is itself a bind-mount under `MS_PRIVATE`
  propagation. The DPREFIX is visible inside `CLONE_NEWNS` via inherited
  propagation without an explicit bind.
* The duplicate-target dedup table (originally added for W2) still
  covers other darling binds: if a manifest pairs `darling_binaries=`
  with an explicit bind to the same host path, the second bind silently
  no-ops.

## Determinism contract

The launcher manifest is part of the package's content-addressed
realization. The generator MUST emit lines in a stable total order
(typically `(target, source)` lex sort) so two manifests built from
identical inputs are byte-identical. The launcher does NOT sort or
canonicalize at parse time; it executes the listed operations in file
order.

## Forward compatibility

Unknown key=value lines are tolerated (logged at `--verbose`) so older
launcher binaries can run newer manifests with reduced fidelity instead
of crashing.

## Windows behavior

On Windows the launcher parses the manifest but does NOT perform any
mount operations -- Windows lacks Linux's bind-mount + user namespace
machinery. The launcher then `_execv()`s the target binary directly.
Reprobuild's foreign-package sandbox is a Linux-only feature; the
Windows stub exists so cross-platform tooling (CI / integration tests)
can exercise the parser path without a Linux build.

## Limitations

* No support for `tmpfs`, `overlay`, or any union-style FS. The bind
  set must be a flat union of per-dep prefixes.
* No setuid / file-capabilities preservation (unprivileged user
  namespaces strip these per kernel policy).
* No `/etc/resolv.conf` synthesis: if the wrapped binary needs DNS,
  the host's `/etc/resolv.conf` must be bind-mounted explicitly.
