## NDE0-S: native systemd-session package — Tier-1 native.
##
## Implements the spec at
## ``reprobuild-specs/ReproOS-Wayland-DEs-PoC.milestones.org`` §NDE0-S.
## This ``repro.nim`` is the user-facing package declaration; the
## actual implementation lives at
## ``libs/repro_dsl_stdlib/src/repro_dsl_stdlib/packages/de_foundation/
## systemd_session.nim`` (precedent: NDE0-A's apt-jammy package +
## ``apt_jammy.nim`` shim).
##
## ## NDE-B: DSL-port migration to typed fs.* surface
##
## NDE-B (foundation rewrite — the pattern NDE-C/D/F/G/H/I will copy)
## migrates this recipe from the previous "shim does everything, recipe is
## a config: shell" pattern to the spec'd typed surface:
##
##   files <artifactName>:
##     build:
##       fs.configFile(path = "/etc/...", content = ...)
##       fs.managedBlock(path = "/etc/...", scope = bsSystem, ...)
##       fs.symlink(path = "/etc/...", target = "...")
##
## Each emitted file is its own ``files:`` artifact so the cache-key
## isolation is visible at the DSL level (toggling ``defaultUser``
## invalidates only the artifacts whose render input changed). The shim
## module still owns the render procs verbatim — only the on-disk
## emitter procs (``configFile`` / ``managedBlock`` / ``symlinkUnmask``)
## stay deprecated in the shim while the recipe drives the DSL's M8 /
## M9.A / M9.B materialisation path.
##
## ## Configurables
##
## Per the spec NDE0-S section. Each maps to a field on
## ``SystemdSessionConfig`` in the impl module. Toggling any of them
## invalidates only the outputs that consume it (the DSL's per-artifact
## ``configFileSha256Of`` / ``managedBlockSha256Of`` hash propagates the
## change atomically through ``consumeConfigFile`` /
## ``consumeManagedBlock``; the unaffected artifacts stay cached).
##
##   * ``defaultUser`` — propagates to /etc/passwd, /etc/group, and the
##     serial-getty autologin drop-in (cascade-A fix).
##   * ``defaultUid`` / ``defaultGid`` — propagate to /etc/passwd + /etc/group.
##   * ``defaultHome`` / ``defaultShell`` — propagate to /etc/passwd only.
##   * ``aptSnapshot`` — the apt-jammy pin for the PAM .deb input. v1
##     of NDE0-S records this in the package fingerprint but does NOT
##     extract PAM .debs (no libpam fixtures are vendored under
##     ``recipes/reproos-mvp-config/vendored-archives/linux/`` — see
##     "Honest deferrals" below).
##
## ## Honest deferrals
##
## * **PAM .so file emission**: NDE0-S v1 emits the PAM stack TEXT
##   files (``/etc/pam.d/login`` + friends) but does NOT extract the
##   corresponding ``pam_unix.so`` / ``pam_systemd.so`` binaries from
##   apt-jammy. The Tier-2 shell script's stage 1 (plant PAM modules
##   under ``/lib/x86_64-linux-gnu/security/``) is deferred until
##   ``libpam0g`` + ``libpam-modules`` .debs are vendored under
##   ``recipes/reproos-mvp-config/vendored-archives/linux/``.
##
## * **Activation / system-generation switching** is the downstream
##   NDEM milestone — NDE0-S emits content-addressed store paths; the
##   apply step that hard-links / symlinks them into the live ``/etc/``
##   tree (and atomically rolls them back) is NDEM1.

import repro_project_dsl
import repro_project_dsl/fs as fs

# The stdlib impl module that owns the render* template procs +
# SystemdSessionConfig type. Imported under an alias so the recipe-side
# call sites stay readable (``sessionImpl.renderPamLogin()``). The shim's
# ``materializeSystemdSession`` orchestrator + ``configFile`` /
# ``managedBlock`` / ``symlinkUnmask`` on-disk emitters are still
# available to legacy callers but the recipe no longer invokes them —
# all on-disk materialisation now flows through the DSL's M8 / M9.A /
# M9.B path.
import repro_dsl_stdlib/packages/de_foundation/systemd_session as sessionImpl
export sessionImpl

# ---------------------------------------------------------------------------
# Configurable accessor
# ---------------------------------------------------------------------------

const SystemdSessionPackageId* = "systemdSession"
  ## The Nim identifier the ``package`` macro registers. Shared between
  ## the recipe's fs.* call sites + the test fixtures so a future rename
  ## (``systemdSession`` → ``systemd-session``) propagates in one place.

proc currentSystemdSessionCfg*(): sessionImpl.SystemdSessionConfig =
  ## Read every configurable cell into a ``SystemdSessionConfig`` record
  ## the shim's render* procs can consume. Uses the M9.D fallback-flavour
  ## of ``readConfigurable`` so this proc is callable even when the
  ## package has not yet registered its defaults (e.g. from a unit test
  ## that imported the recipe but is exercising the helper in isolation).
  result = sessionImpl.SystemdSessionConfig(
    defaultUser:  readConfigurable[string]("systemdSession.defaultUser", "repro"),
    defaultUid:   readConfigurable[int]("systemdSession.defaultUid", 1000),
    defaultGid:   readConfigurable[int]("systemdSession.defaultGid", 1000),
    defaultHome:  readConfigurable[string]("systemdSession.defaultHome", "/home/repro"),
    defaultShell: readConfigurable[string]("systemdSession.defaultShell", "/bin/sh"),
    aptSnapshot:  readConfigurable[string]("systemdSession.aptSnapshot",
                                           "ubuntu/jammy/20260615T000000Z"),
    storeRoot:    sessionImpl.DefaultStoreRoot)

# ---------------------------------------------------------------------------
# Per-artifact registration helpers
# ---------------------------------------------------------------------------
#
# Each helper records one fs.* declaration against the recipe's
# packageName + artifactName. The ``files:`` arms below call these so the
# M4 ``beginBuildContext`` push covers the artifact name. Tests that
# want to re-register after toggling a configurable call
# ``registerSystemdSessionFiles()`` (below) directly with explicit
# packageName + artifactName so the call works outside a build:
# context.
# ---------------------------------------------------------------------------

proc registerLoginPam*() =
  let cfg = currentSystemdSessionCfg()
  fs.configFile(
    path = "/etc/pam.d/login",
    content = sessionImpl.renderPamLogin(),
    packageName = SystemdSessionPackageId,
    artifactName = "loginPam")

proc registerSuPam*() =
  let cfg = currentSystemdSessionCfg()
  fs.configFile(
    path = "/etc/pam.d/su",
    content = sessionImpl.renderPamSu(),
    packageName = SystemdSessionPackageId,
    artifactName = "suPam")

proc registerGdmLaunchPam*() =
  let cfg = currentSystemdSessionCfg()
  fs.configFile(
    path = "/etc/pam.d/gdm-launch-environment",
    content = sessionImpl.renderPamGdmLaunch(),
    packageName = SystemdSessionPackageId,
    artifactName = "gdmLaunchPam")

proc registerSddmPam*() =
  let cfg = currentSystemdSessionCfg()
  fs.configFile(
    path = "/etc/pam.d/sddm",
    content = sessionImpl.renderPamSddm(),
    packageName = SystemdSessionPackageId,
    artifactName = "sddmPam")

proc registerUserAccount*() =
  ## /etc/passwd contribution via fs.managedBlock — the M8 sentinel
  ## format (``# >>> repro:system:systemd-session:system-user-<user> >>>``)
  ## is identical to the shim's standalone-contributor emission so
  ## downstream consumers see a spec-shape-compatible block.
  let cfg = currentSystemdSessionCfg()
  fs.managedBlock(
    path = "/etc/passwd",
    blockId = "system-user-" & cfg.defaultUser,
    scope = bsSystem,
    content = sessionImpl.renderPasswdBlock(
      cfg.defaultUser, cfg.defaultUid, cfg.defaultGid,
      cfg.defaultHome, cfg.defaultShell),
    priority = 100,  # foundation packages — earliest in the merge
    packageName = SystemdSessionPackageId,
    artifactName = "userAccount")

proc registerUserGroup*() =
  let cfg = currentSystemdSessionCfg()
  fs.managedBlock(
    path = "/etc/group",
    blockId = "system-user-" & cfg.defaultUser,
    scope = bsSystem,
    content = sessionImpl.renderGroupBlock(cfg.defaultUser, cfg.defaultGid),
    priority = 100,
    packageName = SystemdSessionPackageId,
    artifactName = "userGroup")

proc registerAutoLoginDropIn*() =
  let cfg = currentSystemdSessionCfg()
  fs.configFile(
    path = "/etc/systemd/system/serial-getty@ttyS0.service.d/zz-repro-autologin.conf",
    content = sessionImpl.renderAutoLoginDropIn(cfg.defaultUser),
    packageName = SystemdSessionPackageId,
    artifactName = "autoLoginDropIn")

proc registerGraphicalSessionTarget*() =
  fs.configFile(
    path = "/usr/lib/systemd/user/graphical-session.target",
    content = sessionImpl.renderGraphicalSessionTarget(),
    packageName = SystemdSessionPackageId,
    artifactName = "graphicalSessionTarget")

proc registerGraphicalSessionPreTarget*() =
  fs.configFile(
    path = "/usr/lib/systemd/user/graphical-session-pre.target",
    content = sessionImpl.renderGraphicalSessionPreTarget(),
    packageName = SystemdSessionPackageId,
    artifactName = "graphicalSessionPreTarget")

proc registerDefaultTargetUnit*() =
  fs.configFile(
    path = "/usr/lib/systemd/user/default.target",
    content = sessionImpl.renderDefaultTargetUnit(),
    packageName = SystemdSessionPackageId,
    artifactName = "defaultTarget")

proc registerLogindUnmask*() =
  ## The R9 base masks ``/etc/systemd/system/systemd-logind.service`` by
  ## symlinking it to ``/dev/null``; NDE0-S un-masks by recording the
  ## real /usr/lib/... unit as the symlink target. On POSIX hosts the
  ## M9.B ``consumeSymlink`` materialiser plants a real OS-level
  ## symlink; on Windows it writes a ``# repro-symlink-intent`` regular
  ## file the apply layer will translate.
  fs.symlink(
    path = "/etc/systemd/system/systemd-logind.service",
    target = "/usr/lib/systemd/system/systemd-logind.service",
    packageName = SystemdSessionPackageId,
    artifactName = "logindUnmask")

proc registerSystemdSessionFiles*() =
  ## Register every fs.* output the recipe owns. Idempotent at the
  ## per-call level only — call ``resetDslPortFsState`` +
  ## ``resetDslPortFsExtState`` before re-invoking, otherwise each
  ## ``fs.configFile`` / ``fs.managedBlock`` / ``fs.symlink`` call
  ## appends a fresh row to the registry.
  ##
  ## Used by the unit-test fixture to re-register after a configurable
  ## toggle. The recipe's ``files <name>: build:`` arms below each
  ## invoke a single per-artifact helper so the M4 ``beginBuildContext``
  ## push carries the spec'd artifact name; the per-artifact helpers'
  ## ``packageName = SystemdSessionPackageId`` argument keeps the
  ## registration well-formed when called outside a build: context (as
  ## the test fixture does).
  registerLoginPam()
  registerSuPam()
  registerGdmLaunchPam()
  registerSddmPam()
  registerUserAccount()
  registerUserGroup()
  registerAutoLoginDropIn()
  registerGraphicalSessionTarget()
  registerGraphicalSessionPreTarget()
  registerDefaultTargetUnit()
  registerLogindUnmask()

# ---------------------------------------------------------------------------
# Package declaration
# ---------------------------------------------------------------------------

package systemdSession:
  ## NDE0-S native systemd-session package.
  ##
  ## Downstream Tier-1 packages (NDE-H/G/K) ``uses:`` this and consume
  ## the recipe's fs.* artifacts through the DSL's ``consumeConfigFile``
  ## / ``consumeManagedBlock`` / ``consumeSymlink`` materialiser. The
  ## ``files <name>:`` arms below each register one emission so the
  ## per-artifact cache key isolates the downstream invalidation surface.

  defaultToolProvisioning "path"

  config:
    ## The default unprivileged user account NDE0-S creates. Propagates
    ## to /etc/passwd, /etc/group, and the serial-getty autologin
    ## drop-in.
    defaultUser: string = "repro"

    ## User-namespace ID for the default user account. Spec'd as 1000
    ## per the Tier-2 ``de0-systemd-session.sh`` stage 5 contract.
    defaultUid: int = 1000

    ## Primary group ID for the default user account.
    defaultGid: int = 1000

    ## Home directory for the default user account. ``/etc/tmpfiles.d/``
    ## creates this on first boot with the right ownership (Tier-2
    ## stage 5 emits the tmpfiles.d snippet; NDE0-S v1 does NOT — see
    ## the Tier-2 fallback note in the module preamble).
    defaultHome: string = "/home/repro"

    ## Login shell. The R9 base ships busybox ash as /bin/sh; DE-H may
    ## overlay-replace with a real bash via its own package.
    defaultShell: string = "/bin/sh"

    ## The apt-jammy snapshot pin for the (deferred) PAM .deb
    ## consumption. Format: ``ubuntu/jammy/YYYYMMDDTHHMMSSZ``. Part of
    ## every cache key so a snapshot bump invalidates the whole
    ## package's emissions atomically — even when the .deb extraction
    ## is deferred, the fingerprint hygiene is preserved.
    aptSnapshot: string = "ubuntu/jammy/20260615T000000Z"

  uses:
    ## NDE0-A apt-jammy native catalog adapter — supplies the PAM .deb
    ## input for the deferred stage 1 (.so file emission). v1 of NDE0-S
    ## records this dependency for fingerprint purposes but does not
    ## yet exercise ``installAptDeb()`` for libpam0g/libpam-modules
    ## (those .debs are not vendored).
    "apt-jammy >=0.1.0"

  # -------------------------------------------------------------------------
  # files: artifacts — one per emitted file. Each ``build:`` body calls
  # the matching per-artifact helper proc declared at module top level;
  # the helper handles the configurable read + the fs.* registration so
  # the recipe stays declarative.
  # -------------------------------------------------------------------------

  files loginPam:
    ## PAM stack for /etc/pam.d/login.
    build:
      registerLoginPam()

  files suPam:
    ## PAM stack for /etc/pam.d/su.
    build:
      registerSuPam()

  files gdmLaunchPam:
    ## PAM stack for /etc/pam.d/gdm-launch-environment (GDM hook).
    build:
      registerGdmLaunchPam()

  files sddmPam:
    ## PAM stack for /etc/pam.d/sddm (SDDM hook).
    build:
      registerSddmPam()

  files userAccount:
    ## /etc/passwd contribution — managedBlock with the NDE-spec-block
    ## triple-form sentinel ``# >>> repro:system:systemd-session:
    ## system-user-<user> >>>``.
    build:
      registerUserAccount()

  files userGroup:
    ## /etc/group contribution — symmetric with userAccount.
    build:
      registerUserGroup()

  files autoLoginDropIn:
    ## /etc/systemd/system/serial-getty@ttyS0.service.d/
    ## zz-repro-autologin.conf — the cascade-A autologin fix.
    build:
      registerAutoLoginDropIn()

  files graphicalSessionTarget:
    ## /usr/lib/systemd/user/graphical-session.target — anchor target
    ## DE units hook WantedBy= against.
    build:
      registerGraphicalSessionTarget()

  files graphicalSessionPreTarget:
    ## /usr/lib/systemd/user/graphical-session-pre.target — pre-DE
    ## initialisation anchor.
    build:
      registerGraphicalSessionPreTarget()

  files defaultTarget:
    ## /usr/lib/systemd/user/default.target — basic-default anchor.
    build:
      registerDefaultTargetUnit()

  files logindUnmask:
    ## /etc/systemd/system/systemd-logind.service un-mask symlink
    ## pointing at the real unit (NOT /dev/null).
    build:
      registerLogindUnmask()
