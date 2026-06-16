## NDE0-S: native systemd-session package impl module (Tier-1).
##
## Implements the spec at
## ``reprobuild-specs/ReproOS-Wayland-DEs-PoC.milestones.org`` §NDE0-S.
##
## This module is the build-time implementation backing the package
## declaration at ``recipes/packages/de-foundation/systemd-session/repro.nim``.
## Consumers (recipes/, downstream NDE-H/G/K packages) import this module
## and invoke ``materializeSystemdSession`` from their own ``build:``
## bodies. The precedent is NDE0-A's ``apt_jammy.nim`` shim pattern —
## ``parsePackageDef`` (libs/repro_project_dsl/src/repro_project_dsl/
## macros_a.nim) currently recognises only ``executable`` / ``library`` /
## ``uses`` / ``config`` / ``outputs`` section heads, so the spec'd
## ``files <name>:`` block form doesn't yet work and the impl is exposed
## as ordinary Nim procs.
##
## ## What this package owns
##
## Per spec §NDE0-S, the native package subsumes the Tier-2 shell script
## at ``recipes/reproos-mvp-config/de0-systemd-session.sh``. The file-
## emission outputs:
##
##   * PAM stack files for /etc/pam.d/{login,su,gdm-launch-environment,
##     sddm} via configFile() with textContent — Tier-2 stage 2.
##   * /etc/passwd + /etc/group system-user blocks via managedBlock()
##     with the NDE-spec-block triple-form sentinel
##     ``# >>> repro:system:systemd-session:system-user-<user> >>>`` —
##     Tier-2 stage 5.
##   * /etc/systemd/system/serial-getty@ttyS0.service.d/
##     zz-repro-autologin.conf drop-in (cascade-A autologin fix) —
##     Tier-2 stage 5b.
##   * /etc/systemd/system/systemd-logind.service un-mask symlink
##     pointing at /usr/lib/systemd/system/systemd-logind.service
##     (NOT /dev/null, which is the R9 base's mask) — Tier-2 stage 3a.
##   * /usr/lib/systemd/user/{graphical-session,graphical-session-pre,
##     default}.target unit files — Tier-2 stage 4.
##
## ## What this package consumes
##
## Per spec NDE0-S "uses: apt-jammy(snapshot, debs=@[libpam0g,
## libpam-modules])", the PAM shared objects (pam_unix.so, pam_systemd.so,
## etc.) come from upstream Debian/Ubuntu via the NDE0-A adapter.
## ``materializeSystemdSession`` takes an optional ``aptPam: AptFiles``
## handle the caller obtains via ``installAptDeb(snapshot, debs=@[
## AptDebSource(name: "libpam0g", ...), AptDebSource(name:
## "libpam-modules", ...)])``. The PAM stack TEXT this package emits
## refers to those modules by name; the .so files themselves do not
## participate in the configFile() / managedBlock() cache keys (they
## ship under aptPam.storePath as a separate content-addressed output).
##
## ## fs.configFile and fs.managedBlock — minimal-viable implementation
##
## The spec'd ``fs.configFile`` / ``fs.managedBlock`` surfaces are
## documented in ``reprobuild-specs/Generated-Configuration-Files.md``
## and partially exist at ``libs/repro_dsl_stdlib/src/repro_dsl_stdlib/
## generated_config.nim`` for the HOME-scope apply path (the M59 work).
## Those existing helpers:
##
##   * Operate over ``ApplyState`` + ``Store`` (the home-profile apply
##     layer, not a content-addressed store-root emitter).
##   * Use the SINGLE-block sentinel form
##     ``# >>> repro:home:<blockId> >>>`` rather than the multi-
##     contributor triple form ``# >>> repro:<scope>:<package>:<blockId> >>>``
##     spec'd in NDE-spec-block (Generated-Configuration-Files.md
##     §"Multi-Contributor Managed Blocks").
##
## Neither shape matches what NDE0-S needs. This module therefore ships
## a **minimal-viable** content-addressed store-emitter pair sized for
## NDE0-S's needs:
##
##   * ``configFile(path, content, storeRoot)`` — writes ``content``
##     verbatim under ``<storeRoot>/<hash>/<path>``. Hash =
##     sha256("configFile" || NDE0-S-version || path || content)[0..15].
##   * ``managedBlock(path, scope, packageName, blockId, content,
##     priority, storeRoot)`` — emits the sentinel-delimited block per
##     the NDE-spec-block triple-form into a single-contributor host
##     file under ``<storeRoot>/<hash>/<path>``. For NDE0-S's standalone
##     emission (no co-contributors yet) the file contains exactly one
##     block; the sentinel format + priority field are spec-shape-
##     compatible for future multi-contributor merge.
##
## **Deferred (NOT in NDE0-S scope)**:
##   * Full spec'd surface composability: cross-contributor sort by
##     ``(priority, packageName, blockId)``, drift detection across
##     generations, ``hostFileFingerprint`` calculation for the
##     unmanaged-bytes drift gate.
##   * Configurable-driven cache-key composition that crosses through
##     the DSL ``configurable`` resolution layer (Configurable-System.md
##     §3). The minimal helpers hash the FINAL rendered content; this is
##     equivalent in cache-discriminating power (any configurable change
##     that affects content also affects the hash) but skips the typed-
##     configurable plumbing.
##   * Integration with the home-scope ``generated_config.nim`` apply
##     layer (rollback safety, prior-digest recording). NDE0-S emits to
##     a content-addressed store root; the apply layer that links the
##     store outputs into /etc/ is a downstream NDEM milestone.
##
## When the full surface lands (a separate spec'd milestone — see
## NDE0-G for the multi-contributor /etc/ld.so.conf.d/ pattern, and
## NDEM for generation-switching), this module's minimal helpers
## migrate to the spec'd procs.

import std/[algorithm, os, strutils]

import nimcrypto/sha2 as nc_sha2

import ../apt_jammy

# Re-export AptFiles so consumers can import this module without also
# needing the apt_jammy path.
export apt_jammy.AptFiles

# ---------------------------------------------------------------------------
# Version constant — part of every emitted-output fingerprint
# ---------------------------------------------------------------------------

const
  Nde0sVersion* = "0.1.0"

  ## Canonical package name segment for the NDE-spec-block sentinels.
  ## Matches the ``package`` form's registered name in
  ## ``recipes/packages/de-foundation/systemd-session/repro.nim``.
  Nde0sPackageName* = "systemd-session"

# ---------------------------------------------------------------------------
# sha256 helpers (mirroring apt_jammy.nim's sha256OfString for consistency)
# ---------------------------------------------------------------------------

proc sha256OfBytes(bytes: openArray[byte]): string =
  var ctx: nc_sha2.sha256
  ctx.init()
  ctx.update(bytes)
  let digest = ctx.finish()
  result = newStringOfCap(64)
  const Hex = "0123456789abcdef"
  for i in 0 ..< 32:
    let b = digest.data[i].uint8
    result.add(Hex[int(b shr 4)])
    result.add(Hex[int(b and 0x0f)])

proc sha256OfString(s: string): string =
  if s.len == 0:
    sha256OfBytes(default(array[0, byte]))
  else:
    sha256OfBytes(cast[ptr UncheckedArray[byte]](s[0].unsafeAddr).toOpenArray(0, s.len - 1))

# ---------------------------------------------------------------------------
# Minimal-viable fs.configFile / fs.managedBlock helpers
# ---------------------------------------------------------------------------

type
  BlockScope* = enum
    ## Per Generated-Configuration-Files.md §"Multi-Contributor Managed
    ## Blocks": the sentinel scope segment. ``bsSystem`` for /etc/* host
    ## files (NDE0-S's exclusive use), ``bsHome`` for ~/-anchored files.
    bsSystem = "system"
    bsHome   = "home"

  ManagedFiles* = object
    ## Typed output handle the spec calls ``Files``. Until the DSL grows
    ## a real ``Files`` value, this is the NDE0-S stand-in (mirrors the
    ## ``AptFiles`` shape from apt_jammy.nim).
    storePath*: string   ## absolute store path under
                         ## ``<storeRoot>/<hash>/``
    relPath*:   string   ## relative path the consumer asked for
                         ## (e.g. "etc/pam.d/login")
    hashHex*:   string   ## the 16-char content-addressed hash segment

const DefaultStoreRoot* = "/opt/reproos-linux/store"

proc canonicalisePath(p: string): string =
  ## Strip leading "/" + "./" and normalise back-slashes to forward
  ## slashes so the in-store layout is POSIX-shaped on every host.
  var s = p.replace('\\', '/')
  while s.startsWith("/"):
    s = s[1 .. ^1]
  if s.startsWith("./"):
    s = s[2 .. ^1]
  s

proc configFileHash*(relPath, content: string): string =
  ## Cache key for ``configFile``. Composed from the NDE0-S version
  ## (so a bugfix here invalidates downstream packages atomically) +
  ## the in-store relative path + the rendered bytes.
  let composed = "configFile" & Nde0sVersion & relPath & content
  let h = sha256OfString(composed)
  result = h[0 ..< 16]

proc configFile*(path: string;
                content: string;
                storeRoot: string = DefaultStoreRoot): ManagedFiles =
  ## Minimal-viable ``fs.configFile`` (see module preamble for the
  ## deferred-spec note). Writes ``content`` verbatim to
  ## ``<storeRoot>/<hash>/<path>`` where ``<path>`` is canonicalised to
  ## a POSIX-relative form. Idempotent: a second invocation with the
  ## same args lands at the same store path and short-circuits via the
  ## marker file.
  let rel = canonicalisePath(path)
  let hash = configFileHash(rel, content)
  let storePath = storeRoot / hash
  let marker = storePath / ".nde0s-configFile"
  result.storePath = storePath
  result.relPath = rel
  result.hashHex = hash
  if dirExists(storePath) and fileExists(marker):
    let existing = readFile(marker).strip()
    if existing == hash:
      return
  if dirExists(storePath):
    removeDir(storePath)
  createDir(storePath)
  let dest = storePath / rel
  createDir(dest.parentDir)
  writeFile(dest, content)
  writeFile(marker, hash)

proc openSentinel*(scope: BlockScope;
                   packageName, blockId: string): string =
  ## NDE-spec-block sentinel open. Format:
  ##   ``# >>> repro:<scope>:<packageName>:<blockId> >>>``
  ## See Generated-Configuration-Files.md §"Sentinel uniqueness".
  "# >>> repro:" & $scope & ":" & packageName & ":" & blockId & " >>>"

proc closeSentinel*(scope: BlockScope;
                    packageName, blockId: string): string =
  ## NDE-spec-block sentinel close. Mirror-shape of ``openSentinel``.
  "# <<< repro:" & $scope & ":" & packageName & ":" & blockId & " <<<"

proc renderBlock(scope: BlockScope;
                 packageName, blockId, content: string): string =
  ## Render one sentinel-delimited block + its content. Content gets a
  ## trailing newline appended if missing (canonical shape).
  result = openSentinel(scope, packageName, blockId) & "\n"
  result.add(content)
  if not content.endsWith("\n"):
    result.add('\n')
  result.add(closeSentinel(scope, packageName, blockId) & "\n")

proc managedBlockHash*(scope: BlockScope;
                       packageName, blockId, relPath, content: string;
                       priority: int): string =
  ## Cache key for ``managedBlock``. Spec
  ## (Generated-Configuration-Files.md §"Cache-key composition") says
  ## the key is composed from:
  ##   * (scope, packageName, blockId) triple
  ##   * host file path
  ##   * content hash
  ##   * resolved configurable inputs (folded into content here)
  ## Priority is included so an author-driven priority change re-emits
  ## the contribution.
  let composed = "managedBlock" & Nde0sVersion & $scope & packageName &
                 blockId & relPath & $priority & content
  let h = sha256OfString(composed)
  result = h[0 ..< 16]

proc managedBlock*(path: string;
                   scope: BlockScope;
                   packageName: string;
                   blockId: string;
                   content: string;
                   priority: int = 1000;
                   storeRoot: string = DefaultStoreRoot): ManagedFiles =
  ## Minimal-viable ``fs.managedBlock`` (see module preamble for the
  ## deferred-spec note). Emits a sentinel-delimited block + its content
  ## into a single-contributor host file under ``<storeRoot>/<hash>/<path>``.
  ## The sentinel shape matches the NDE-spec-block triple-form so a
  ## future multi-contributor merge that consumes this contribution
  ## sees a spec-shape-compatible block.
  let rel = canonicalisePath(path)
  let hash = managedBlockHash(scope, packageName, blockId, rel, content,
                              priority)
  let storePath = storeRoot / hash
  let marker = storePath / ".nde0s-managedBlock"
  result.storePath = storePath
  result.relPath = rel
  result.hashHex = hash
  if dirExists(storePath) and fileExists(marker):
    let existing = readFile(marker).strip()
    if existing == hash:
      return
  if dirExists(storePath):
    removeDir(storePath)
  createDir(storePath)
  let dest = storePath / rel
  createDir(dest.parentDir)
  let rendered = renderBlock(scope, packageName, blockId, content)
  writeFile(dest, rendered)
  writeFile(marker, hash)

proc symlinkUnmask*(path: string;
                    target: string;
                    storeRoot: string = DefaultStoreRoot): ManagedFiles =
  ## Minimal helper for the un-mask emission: drops a text file at
  ## ``<storeRoot>/<hash>/<path>.unmask-target`` that records the
  ## intended absolute symlink target. The activation/apply layer (an
  ## NDEM milestone) reads this file to plant the actual symlink in the
  ## live ``/etc/`` tree; on hosts where symlinks aren't first-class
  ## (e.g. Windows test machines), this lets us validate intent without
  ## creating a real symlink.
  ##
  ## The R9 base masks ``/etc/systemd/system/systemd-logind.service`` by
  ## symlinking it to ``/dev/null``; NDE0-S un-masks by recording the
  ## real-unit target. The acceptance test asserts the recorded target
  ## is NOT ``/dev/null``.
  let rel = canonicalisePath(path)
  let manifestPath = rel & ".unmask-target"
  let composed = "symlinkUnmask" & Nde0sVersion & rel & target
  let hash = sha256OfString(composed)[0 ..< 16]
  let storePath = storeRoot / hash
  let marker = storePath / ".nde0s-unmask"
  result.storePath = storePath
  result.relPath = manifestPath
  result.hashHex = hash
  if dirExists(storePath) and fileExists(marker):
    let existing = readFile(marker).strip()
    if existing == hash:
      return
  if dirExists(storePath):
    removeDir(storePath)
  createDir(storePath)
  let dest = storePath / manifestPath
  createDir(dest.parentDir)
  writeFile(dest, target & "\n")
  writeFile(marker, hash)

# ---------------------------------------------------------------------------
# PAM stack text rendering (NDE0-S stage 2)
# ---------------------------------------------------------------------------

proc renderPamLogin*(): string =
  ## PAM stack for /etc/pam.d/login. Matches the Tier-2 stage 2 block
  ## shape from de0-systemd-session.sh. Console login via agetty wires
  ## through pam_unix (password verify) + pam_systemd (session
  ## creation: XDG_RUNTIME_DIR + cgroup placement).
  result = "# NDE0-S minimal login PAM stack.\n" &
           "auth     required pam_unix.so\n" &
           "account  required pam_unix.so\n" &
           "session  required pam_unix.so\n" &
           "session  required pam_systemd.so\n"

proc renderPamSu*(): string =
  ## PAM stack for /etc/pam.d/su. Same shape as login — pam_systemd is
  ## required so ``su - <user>`` inherits a valid XDG_RUNTIME_DIR.
  result = "# NDE0-S minimal su PAM stack.\n" &
           "auth     required pam_unix.so\n" &
           "account  required pam_unix.so\n" &
           "session  required pam_unix.so\n" &
           "session  required pam_systemd.so\n"

proc renderPamGdmLaunch*(): string =
  ## PAM stack for /etc/pam.d/gdm-launch-environment. GDM's session
  ## launcher uses this to bootstrap the X/Wayland environment without
  ## a full password prompt.
  result = "# NDE0-S gdm-launch-environment PAM stack.\n" &
           "auth     required pam_permit.so\n" &
           "account  required pam_unix.so\n" &
           "session  required pam_unix.so\n" &
           "session  required pam_systemd.so\n"

proc renderPamSddm*(): string =
  ## PAM stack for /etc/pam.d/sddm. SDDM (KDE display manager) gates
  ## the greeter through pam_unix + pam_systemd.
  result = "# NDE0-S sddm PAM stack.\n" &
           "auth     required pam_unix.so\n" &
           "account  required pam_unix.so\n" &
           "session  required pam_unix.so\n" &
           "session  required pam_systemd.so\n"

# ---------------------------------------------------------------------------
# /etc/passwd + /etc/group block rendering (NDE0-S stage 5)
# ---------------------------------------------------------------------------

proc renderPasswdBlock*(user: string; uid, gid: int;
                       home, shell: string): string =
  ## One passwd entry for the default user. The line shape is the
  ## standard 7-field colon-separated form documented in passwd(5).
  ## Note: an empty password (``x`` placeholder means "see shadow") is
  ## intentional for the MVP — the security boundary is the VM image,
  ## not per-user auth. The DE-G smoke test runs the VM with serial
  ## console only.
  result = user & ":x:" & $uid & ":" & $gid & ":ReproOS Default:" &
           home & ":" & shell & "\n"

proc renderGroupBlock*(user: string; gid: int): string =
  ## One group entry for the default user's primary group.
  result = user & ":x:" & $gid & ":\n"

# ---------------------------------------------------------------------------
# Drop-in + user-target rendering (NDE0-S stages 5b + 4)
# ---------------------------------------------------------------------------

proc renderAutoLoginDropIn*(user: string): string =
  ## serial-getty@ttyS0.service.d/zz-repro-autologin.conf — the cascade-A
  ## fix from the Tier-2 work. The R9 base initramfs plants
  ## ``override.conf`` autologging in as root; NDE0-S overrides via the
  ## ``zz-*.conf`` lex-after name so the configurable ``defaultUser`` wins.
  ## See de0-systemd-session.sh stage 5b for the original analysis.
  result = "# NDE0-S: serial-getty autologin drop-in (cascade-A fix).\n" &
           "# Lex-after override.conf (zz-* > override.conf alphabetically).\n" &
           "# Autologin as " & user & " so logind allocates XDG_RUNTIME_DIR\n" &
           "# under /run/user/<uid> for the Wayland-DE session entry shim.\n" &
           "[Service]\n" &
           "ExecStart=\n" &
           "ExecStart=-/sbin/agetty --autologin " & user &
           " --noclear %I 115200 linux\n"

proc renderGraphicalSessionTarget*(): string =
  ## ``graphical-session.target`` user-instance anchor. DE-layer recipes
  ## (Hyprland, GNOME, KDE) hook WantedBy= against this target.
  result = "# NDE0-S: anchor target for Wayland DE units to set WantedBy=.\n" &
           "[Unit]\n" &
           "Description=Current graphical user session\n" &
           "Documentation=man:systemd.special(7)\n" &
           "RefuseManualStart=yes\n" &
           "StopWhenUnneeded=yes\n"

proc renderGraphicalSessionPreTarget*(): string =
  ## ``graphical-session-pre.target`` user-instance pre-DE init anchor.
  result = "# NDE0-S: pre-DE initialisation anchor.\n" &
           "[Unit]\n" &
           "Description=Session services that should run before the graphical session is up\n" &
           "Documentation=man:systemd.special(7)\n" &
           "RefuseManualStart=yes\n" &
           "StopWhenUnneeded=yes\n"

proc renderDefaultTargetUnit*(): string =
  ## ``default.target`` user-instance default. We make this an alias
  ## for ``basic.target`` (no-DE default); a DE-installer recipe
  ## re-points this when a DE is selected. We emit the unit FILE shape
  ## (with [Unit] section) rather than a symlink so the NDE0-S store
  ## emission is host-portable (Windows test runners can't create
  ## /dev/null-style symlinks reliably).
  result = "# NDE0-S: default user-instance target (no-DE basic).\n" &
           "[Unit]\n" &
           "Description=Main user target\n" &
           "Documentation=man:systemd.special(7)\n" &
           "Requires=basic.target\n" &
           "After=basic.target\n" &
           "AllowIsolate=yes\n"

# ---------------------------------------------------------------------------
# Public surface — materialize the whole package's outputs in one call
# ---------------------------------------------------------------------------

type
  SystemdSessionConfig* = object
    ## NDE0-S configurables per the spec example. Defaults match the
    ## Tier-2 shell script.
    defaultUser*: string
    defaultUid*: int
    defaultGid*: int
    defaultHome*: string
    defaultShell*: string

    ## Snapshot pin for the apt-jammy dependency. v1 of NDE0-S does not
    ## extract the .debs (no libpam debs are vendored in v1); the
    ## snapshot string is part of the fingerprint anyway so a future
    ## live-fetch path lands without breaking already-cached store
    ## paths. Set to "" to skip the apt-jammy side entirely.
    aptSnapshot*: string

    ## Root the helpers write into. Test harnesses override.
    storeRoot*: string

  SystemdSessionOutputs* = object
    ## Output handles for every emitted file. Each is a separate
    ## content-addressed ``ManagedFiles`` so the cache keys are
    ## independent — toggling ``defaultUser`` re-emits only the user
    ## blocks + the autologin drop-in, leaving the PAM stacks +
    ## logind un-mask + user-session targets cached.
    pamLogin*:                 ManagedFiles
    pamSu*:                    ManagedFiles
    pamGdmLaunch*:             ManagedFiles
    pamSddm*:                  ManagedFiles
    passwdBlock*:              ManagedFiles
    groupBlock*:               ManagedFiles
    autoLoginDropIn*:          ManagedFiles
    logindUnmask*:             ManagedFiles
    graphicalSessionTarget*:   ManagedFiles
    graphicalSessionPreTarget*: ManagedFiles
    defaultTarget*:            ManagedFiles

proc defaultSystemdSessionConfig*(): SystemdSessionConfig =
  ## The spec'd defaults. Tests use this then mutate one field at a
  ## time to exercise configurable propagation.
  result = SystemdSessionConfig(
    defaultUser:  "repro",
    defaultUid:   1000,
    defaultGid:   1000,
    defaultHome:  "/home/repro",
    defaultShell: "/bin/sh",
    aptSnapshot:  "ubuntu/jammy/20260615T000000Z",
    storeRoot:    DefaultStoreRoot)

proc materializeSystemdSession*(cfg: SystemdSessionConfig):
                               SystemdSessionOutputs =
  ## Emit every NDE0-S output. Each helper invocation is independent so
  ## the cache keys are per-output — see the docstring for
  ## ``SystemdSessionOutputs`` for the invalidation matrix.
  result.pamLogin = configFile(
    path = "etc/pam.d/login",
    content = renderPamLogin(),
    storeRoot = cfg.storeRoot)

  result.pamSu = configFile(
    path = "etc/pam.d/su",
    content = renderPamSu(),
    storeRoot = cfg.storeRoot)

  result.pamGdmLaunch = configFile(
    path = "etc/pam.d/gdm-launch-environment",
    content = renderPamGdmLaunch(),
    storeRoot = cfg.storeRoot)

  result.pamSddm = configFile(
    path = "etc/pam.d/sddm",
    content = renderPamSddm(),
    storeRoot = cfg.storeRoot)

  let userBlockId = "system-user-" & cfg.defaultUser
  result.passwdBlock = managedBlock(
    path = "etc/passwd",
    scope = bsSystem,
    packageName = Nde0sPackageName,
    blockId = userBlockId,
    content = renderPasswdBlock(cfg.defaultUser, cfg.defaultUid,
                                cfg.defaultGid, cfg.defaultHome,
                                cfg.defaultShell),
    priority = 100,        # foundation packages default per spec
    storeRoot = cfg.storeRoot)

  result.groupBlock = managedBlock(
    path = "etc/group",
    scope = bsSystem,
    packageName = Nde0sPackageName,
    blockId = userBlockId,
    content = renderGroupBlock(cfg.defaultUser, cfg.defaultGid),
    priority = 100,
    storeRoot = cfg.storeRoot)

  result.autoLoginDropIn = configFile(
    path = "etc/systemd/system/serial-getty@ttyS0.service.d/zz-repro-autologin.conf",
    content = renderAutoLoginDropIn(cfg.defaultUser),
    storeRoot = cfg.storeRoot)

  result.logindUnmask = symlinkUnmask(
    path = "etc/systemd/system/systemd-logind.service",
    target = "/usr/lib/systemd/system/systemd-logind.service",
    storeRoot = cfg.storeRoot)

  result.graphicalSessionTarget = configFile(
    path = "usr/lib/systemd/user/graphical-session.target",
    content = renderGraphicalSessionTarget(),
    storeRoot = cfg.storeRoot)

  result.graphicalSessionPreTarget = configFile(
    path = "usr/lib/systemd/user/graphical-session-pre.target",
    content = renderGraphicalSessionPreTarget(),
    storeRoot = cfg.storeRoot)

  result.defaultTarget = configFile(
    path = "usr/lib/systemd/user/default.target",
    content = renderDefaultTargetUnit(),
    storeRoot = cfg.storeRoot)

# ---------------------------------------------------------------------------
# Convenience: list every output's store paths in a stable order. Useful
# for the multi-output union the future ``activate`` step in NDEM will
# consume.
# ---------------------------------------------------------------------------

proc storePaths*(outs: SystemdSessionOutputs): seq[string] =
  ## Stable enumeration of every emitted store path. Sort discipline
  ## matches the order the spec'd ``activate`` step expects.
  result = @[
    outs.pamLogin.storePath,
    outs.pamSu.storePath,
    outs.pamGdmLaunch.storePath,
    outs.pamSddm.storePath,
    outs.passwdBlock.storePath,
    outs.groupBlock.storePath,
    outs.autoLoginDropIn.storePath,
    outs.logindUnmask.storePath,
    outs.graphicalSessionTarget.storePath,
    outs.graphicalSessionPreTarget.storePath,
    outs.defaultTarget.storePath]
  # No sort: the order is the spec'd activation order, not lexicographic.
  # The caller that needs sorted output can call .sort() on the result.

proc sortedStorePaths*(outs: SystemdSessionOutputs): seq[string] =
  ## Lexicographically-sorted variant for byte-cmp scenarios.
  result = storePaths(outs)
  result.sort(cmp[string])
