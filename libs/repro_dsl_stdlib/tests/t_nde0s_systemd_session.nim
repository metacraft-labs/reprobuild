## NDE0-S unit tests: native systemd-session package (NDE-B migrated).
##
## Exercises the spec'd public surface of
## ``recipes/packages/de-foundation/systemd-session/repro.nim`` through
## the DSL's M8 / M9.A / M9.B materialisation path
## (``fs.configFile`` / ``fs.managedBlock`` / ``fs.symlink`` registration
## + ``consumeConfigFile`` / ``consumeManagedBlock`` / ``consumeSymlink``
## materialisation) rather than the shim's deprecated
## ``materializeSystemdSession`` orchestrator. The recipe's render*
## procs still come from the shim verbatim — only the on-disk emission
## path moved.
##
## Required test surfaces (preserved verbatim from the pre-NDE-B test;
## hashHex literal values change because the M9.A cache-key composition
## differs from the shim's, but the structural assertions survive):
##
##   1. PAM stack generation — default config emits /etc/pam.d/login
##      with pam_unix.so + pam_systemd.so references.
##   2. Configurable binding: changing defaultUser propagates to
##      /etc/passwd (alice:x: instead of repro:x:).
##   3. Configurable binding: changing defaultUid propagates to
##      /etc/passwd (:2000: instead of :1000:).
##   4. Idempotency: same config produces same store paths.
##   5. Configurable invalidation: changing defaultUser produces a
##      DIFFERENT store path for the /etc/passwd block (proves the
##      cache key includes the configurable).
##   6. Determinism: byte-cmp emitted PAM stack file across two
##      independent roots.
##   7. Sentinel shape for the user block: verify the M8 spec'd triple-
##      form open + matching close sentinel.
##   8. Autologin drop-in carries the configurable user in the
##      ExecStart= override.
##   9. Logind un-mask records the real-unit target (NOT /dev/null).
##  10. Cache-key-isolation across artifacts (PAM hash != user-block
##      hash != drop-in hash).
##  11. defaultHome + defaultShell propagate to /etc/passwd.
##  12. Shim sentinel helpers' scope renders as the spec'd lowercase
##      string (the legacy ``BlockScope`` enum stays for shim
##      back-compat).
##  13. User-session targets render expected shape.
##
## Plus an additional NDE-B-surface coverage suite that pins the
## ``files <name>:`` artifact registration shape against the DSL's M3
## ``registeredArtifacts`` accessor, confirming the recipe genuinely
## exercises the typed surface rather than silently regressing to the
## legacy "configFile is a Nim proc the recipe calls directly" path.

import std/[os, strutils, tempfiles, unittest]

# The shim module — still owns the render* template procs + the legacy
# BlockScope/openSentinel/closeSentinel helpers the v1 test pinned.
# NDE-B does NOT remove the shim; the deprecated
# ``materializeSystemdSession`` + on-disk emitter procs stay reachable
# for any caller that still imports them.
import repro_dsl_stdlib/packages/de_foundation/systemd_session

# The recipe — registers the package's M2 configurables + module-init
# fires every ``files <name>: build:`` arm so the M8/M9.A/M9.B tables
# are pre-populated against the default configurables. The recipe also
# re-exports the per-artifact ``register*`` helpers the test fixture
# below uses to re-register after a configurable toggle.
import repro_project_dsl
import repro_project_dsl/fs as fs
import "../../../recipes/packages/de-foundation/systemd-session/repro" as recipe

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc readStoreFile(handle: DslManagedFiles): string =
  ## Read the bytes of the emitted file at
  ## ``handle.storePath/handle.relPath``.
  let p = handle.storePath / handle.relPath
  check fileExists(p)
  result = readFile(p)

proc resetRecipeState(storeRoot: string) =
  ## Test-fixture reset: clear every M8/M9.A/M9.B registry + materialiser
  ## row, drop any pending configurable overrides for the systemdSession
  ## package, then re-register every fs.* output the recipe owns against
  ## the (now-default) configurables. ``registerStoreRoot`` runs LAST
  ## because ``resetDslPortMaterialiseState`` clears the store-root
  ## table along with the materialiser side-tables (the M9.A reset proc
  ## is "drop EVERY registered storeRoot + every materialisation side-
  ## table row" — see the proc's docstring).
  resetDslPortFsState()
  resetDslPortFsExtState()
  resetDslPortMaterialiseState()
  resetConfigurable("systemdSession.defaultUser")
  resetConfigurable("systemdSession.defaultUid")
  resetConfigurable("systemdSession.defaultGid")
  resetConfigurable("systemdSession.defaultHome")
  resetConfigurable("systemdSession.defaultShell")
  resetConfigurable("systemdSession.aptSnapshot")
  registerStoreRoot("systemdSession", storeRoot, dhaSha256)
  recipe.registerSystemdSessionFiles()

proc reregisterWithCurrentConfigurables(storeRoot: string) =
  ## After ``setConfigurable(...)`` has flipped one or more cells, the
  ## previously-recorded M8/M9 entries still carry the OLD content;
  ## drop them, re-register against the new cells, and re-bind the
  ## store-root (the M9.A reset call below also wipes it — see above).
  resetDslPortFsState()
  resetDslPortFsExtState()
  resetDslPortMaterialiseState()
  registerStoreRoot("systemdSession", storeRoot, dhaSha256)
  recipe.registerSystemdSessionFiles()

# ---------------------------------------------------------------------------
# Convenience consumers — one per artifact. Centralises the per-output
# path the recipe uses so the test reads identically to the v1 shape.
# ---------------------------------------------------------------------------

proc consumeLoginPam(): DslManagedFiles =
  consumeConfigFile("systemdSession", "/etc/pam.d/login")
proc consumeSuPam(): DslManagedFiles =
  consumeConfigFile("systemdSession", "/etc/pam.d/su")
proc consumeGdmLaunchPam(): DslManagedFiles =
  consumeConfigFile("systemdSession", "/etc/pam.d/gdm-launch-environment")
proc consumeSddmPam(): DslManagedFiles =
  consumeConfigFile("systemdSession", "/etc/pam.d/sddm")
proc consumePasswdBlock(): DslManagedFiles =
  consumeManagedBlock("/etc/passwd")
proc consumeGroupBlock(): DslManagedFiles =
  consumeManagedBlock("/etc/group")
proc consumeAutoLoginDropIn(): DslManagedFiles =
  consumeConfigFile(
    "systemdSession",
    "/etc/systemd/system/serial-getty@ttyS0.service.d/zz-repro-autologin.conf")
proc consumeLogindUnmask(): DslManagedFiles =
  consumeSymlink(
    "systemdSession", "/etc/systemd/system/systemd-logind.service")
proc consumeGraphicalSessionTarget(): DslManagedFiles =
  consumeConfigFile(
    "systemdSession", "/usr/lib/systemd/user/graphical-session.target")
proc consumeGraphicalSessionPreTarget(): DslManagedFiles =
  consumeConfigFile(
    "systemdSession", "/usr/lib/systemd/user/graphical-session-pre.target")
proc consumeDefaultTarget(): DslManagedFiles =
  consumeConfigFile(
    "systemdSession", "/usr/lib/systemd/user/default.target")

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

suite "NDE0-S systemd-session package":

  test "PAM stack: /etc/pam.d/login content has pam_unix.so + pam_systemd.so":
    let root = createTempDir("nde0s_pam_login_", "")
    defer: removeDir(root)
    resetRecipeState(root)

    let loginPam = consumeLoginPam()
    let bytes = readStoreFile(loginPam)

    # The Tier-2 stage 2 block contract: auth + account + session via
    # pam_unix, plus a session-tier pam_systemd so logind creates the
    # XDG_RUNTIME_DIR.
    check "pam_unix.so" in bytes
    check "pam_systemd.so" in bytes
    check "auth     required pam_unix.so" in bytes
    check "session  required pam_systemd.so" in bytes
    # Sanity: the store path is rooted under the override.
    check loginPam.storePath.startsWith(root)
    # M9.A sha256 hashes are 64 lower-hex chars (the shim's 16-char
    # truncated form is gone; the structural check is "non-empty hex").
    check loginPam.hashHex.len == 64

  test "configurable: changing defaultUser propagates to /etc/passwd":
    let root = createTempDir("nde0s_user_alice_", "")
    defer: removeDir(root)
    resetRecipeState(root)
    setConfigurable("systemdSession.defaultUser", "alice")
    # Re-register so the configurable change feeds into the recorded
    # content. (resetRecipeState's registration used the defaults.)
    reregisterWithCurrentConfigurables(root)

    let passwdBlock = consumePasswdBlock()
    let bytes = readStoreFile(passwdBlock)

    # Block content: the rendered passwd entry uses alice, NOT repro.
    check "alice:x:1000:1000" in bytes
    check "repro:x:" notin bytes
    # The sentinel itself ALSO names the user (blockId =
    # "system-user-" & defaultUser) — verifies the configurable plumbs
    # through the sentinel layer.
    check "system-user-alice" in bytes
    check "system-user-repro" notin bytes

  test "configurable: changing defaultUid propagates to /etc/passwd":
    let root = createTempDir("nde0s_uid_2000_", "")
    defer: removeDir(root)
    resetRecipeState(root)
    setConfigurable("systemdSession.defaultUid", 2000)
    setConfigurable("systemdSession.defaultGid", 2000)
    reregisterWithCurrentConfigurables(root)

    let passwdBlock = consumePasswdBlock()
    let bytes = readStoreFile(passwdBlock)

    check ":2000:2000:" in bytes
    check ":1000:1000:" notin bytes

  test "idempotency: same config produces same store paths":
    let root = createTempDir("nde0s_idem_", "")
    defer: removeDir(root)
    resetRecipeState(root)

    # First materialisation pass — every consume call writes the file +
    # records the handle in the M9 idempotency side-table.
    let lpA = consumeLoginPam()
    let suA = consumeSuPam()
    let gdmA = consumeGdmLaunchPam()
    let sddmA = consumeSddmPam()
    let pwA = consumePasswdBlock()
    let grA = consumeGroupBlock()
    let aldA = consumeAutoLoginDropIn()
    let lgA = consumeLogindUnmask()
    let gstA = consumeGraphicalSessionTarget()
    let gsptA = consumeGraphicalSessionPreTarget()
    let dtA = consumeDefaultTarget()

    # Second materialisation pass — every consume call returns the
    # cached handle (the M9 side-tables short-circuit on the second
    # call). Every output should land at exactly the same store path.
    let lpB = consumeLoginPam()
    let suB = consumeSuPam()
    let gdmB = consumeGdmLaunchPam()
    let sddmB = consumeSddmPam()
    let pwB = consumePasswdBlock()
    let grB = consumeGroupBlock()
    let aldB = consumeAutoLoginDropIn()
    let lgB = consumeLogindUnmask()
    let gstB = consumeGraphicalSessionTarget()
    let gsptB = consumeGraphicalSessionPreTarget()
    let dtB = consumeDefaultTarget()

    check lpA.storePath   == lpB.storePath
    check suA.storePath   == suB.storePath
    check gdmA.storePath  == gdmB.storePath
    check sddmA.storePath == sddmB.storePath
    check pwA.storePath   == pwB.storePath
    check grA.storePath   == grB.storePath
    check aldA.storePath  == aldB.storePath
    check lgA.storePath   == lgB.storePath
    check gstA.storePath  == gstB.storePath
    check gsptA.storePath == gsptB.storePath
    check dtA.storePath   == dtB.storePath

  test "configurable invalidation: defaultUser change → different /etc/passwd store path":
    # This is the load-bearing cache-key test the spec calls out
    # ("Toggling config.defaultUser from 'repro' to 'alice' rebuilds
    # only the affected files"). If the cache key didn't include the
    # configurable, both calls would land at the same store path and
    # the second call would never re-emit the user block.
    let root = createTempDir("nde0s_invalidation_", "")
    defer: removeDir(root)

    # Pass A — default configurables.
    resetRecipeState(root)
    let lpA   = consumeLoginPam()
    let suA   = consumeSuPam()
    let pwA   = consumePasswdBlock()
    let grA   = consumeGroupBlock()
    let aldA  = consumeAutoLoginDropIn()
    let lgA   = consumeLogindUnmask()
    let gstA  = consumeGraphicalSessionTarget()

    # Pass B — defaultUser flipped to alice. ``reregisterWith
    # CurrentConfigurables`` resets every M8/M9.A/M9.B side table AND
    # re-binds the store-root (the M9.A reset wipes it as part of the
    # symmetric "drop EVERY registered storeRoot" contract).
    setConfigurable("systemdSession.defaultUser", "alice")
    reregisterWithCurrentConfigurables(root)
    let lpB   = consumeLoginPam()
    let suB   = consumeSuPam()
    let pwB   = consumePasswdBlock()
    let grB   = consumeGroupBlock()
    let aldB  = consumeAutoLoginDropIn()
    let lgB   = consumeLogindUnmask()
    let gstB  = consumeGraphicalSessionTarget()

    # The user blocks MUST land at different store paths.
    check pwA.storePath  != pwB.storePath
    check grA.storePath  != grB.storePath
    check aldA.storePath != aldB.storePath
    # And the PAM stacks (which DON'T depend on defaultUser) MUST stay
    # at the same store path — that's the "rebuilds only the affected
    # files" half of the spec contract.
    check lpA.storePath  == lpB.storePath
    check suA.storePath  == suB.storePath
    check lgA.storePath  == lgB.storePath
    check gstA.storePath == gstB.storePath

  test "determinism: PAM stacks byte-identical across two independent roots":
    # The idempotency test catches re-entry into the same store root
    # (a side-table cache hit could mask a non-deterministic writer);
    # this test forces a fresh write into a SECOND root and byte-
    # compares the result.
    let rootA = createTempDir("nde0s_detA_", "")
    let rootB = createTempDir("nde0s_detB_", "")
    defer:
      removeDir(rootA)
      removeDir(rootB)

    # Pass A.
    resetRecipeState(rootA)
    let lpA   = consumeLoginPam()
    let suA   = consumeSuPam()
    let gdmA  = consumeGdmLaunchPam()
    let sddmA = consumeSddmPam()
    let pwA   = consumePasswdBlock()
    let grA   = consumeGroupBlock()
    let aldA  = consumeAutoLoginDropIn()

    # Pass B — fully fresh state, fresh root, same default configurables.
    resetRecipeState(rootB)
    let lpB   = consumeLoginPam()
    let suB   = consumeSuPam()
    let gdmB  = consumeGdmLaunchPam()
    let sddmB = consumeSddmPam()
    let pwB   = consumePasswdBlock()
    let grB   = consumeGroupBlock()
    let aldB  = consumeAutoLoginDropIn()

    # The basenames (the content-addressed hash segment) must match.
    check extractFilename(lpA.storePath) == extractFilename(lpB.storePath)
    check extractFilename(suA.storePath) == extractFilename(suB.storePath)
    check extractFilename(pwA.storePath) == extractFilename(pwB.storePath)

    # And every file's bytes are byte-identical.
    check readStoreFile(lpA)   == readStoreFile(lpB)
    check readStoreFile(suA)   == readStoreFile(suB)
    check readStoreFile(gdmA)  == readStoreFile(gdmB)
    check readStoreFile(sddmA) == readStoreFile(sddmB)
    check readStoreFile(pwA)   == readStoreFile(pwB)
    check readStoreFile(grA)   == readStoreFile(grB)
    check readStoreFile(aldA)  == readStoreFile(aldB)

  test "sentinel shape: user block uses NDE-spec-block triple form":
    # Per Generated-Configuration-Files.md §"Sentinel uniqueness":
    #   # >>> repro:<scope>:<packageName>:<blockId> >>>
    #   ...
    #   # <<< repro:<scope>:<packageName>:<blockId> <<<
    # scope = system, packageName = systemdSession (the M8/M9.A path
    # uses the DSL package identifier verbatim, not the kebab-cased
    # shim alias), blockId = system-user-<user>.
    let root = createTempDir("nde0s_sentinel_", "")
    defer: removeDir(root)
    resetRecipeState(root)

    let passwdBlock = consumePasswdBlock()
    let bytes = readStoreFile(passwdBlock)

    let expectOpen =
      "# >>> repro:system:systemdSession:system-user-repro >>>"
    let expectClose =
      "# <<< repro:system:systemdSession:system-user-repro <<<"

    check expectOpen in bytes
    check expectClose in bytes
    # The open MUST come before the close.
    check bytes.find(expectOpen) < bytes.find(expectClose)
    # And the rendered passwd line sits between them.
    let openIdx = bytes.find(expectOpen)
    let closeIdx = bytes.find(expectClose)
    let between = bytes[openIdx + expectOpen.len ..< closeIdx]
    check "repro:x:1000:1000" in between

  test "autologin drop-in: ExecStart override carries the configurable user":
    let root = createTempDir("nde0s_autologin_", "")
    defer: removeDir(root)
    resetRecipeState(root)
    setConfigurable("systemdSession.defaultUser", "alice")
    reregisterWithCurrentConfigurables(root)

    let aldHandle = consumeAutoLoginDropIn()
    let bytes = readStoreFile(aldHandle)

    # The cascade-A fix shape: ExecStart= (reset) followed by a
    # second ExecStart= with --autologin <user>.
    check "[Service]" in bytes
    check "ExecStart=\nExecStart=-/sbin/agetty --autologin alice" in bytes
    # And the file lives at the spec'd path (M9.A's canonicalisePath
    # strips the leading "/").
    check aldHandle.relPath ==
      "etc/systemd/system/serial-getty@ttyS0.service.d/zz-repro-autologin.conf"

  test "logind un-mask: target is the real unit, NOT /dev/null":
    # The R9 base masks systemd-logind by symlinking
    # /etc/systemd/system/systemd-logind.service -> /dev/null.
    # NDE0-S un-masks by pointing at the real /usr/lib/... unit. On
    # POSIX hosts M9.B materialises a real OS-level symlink; on
    # Windows the recipe-side ``fs.symlink`` falls back to a regular
    # file with a ``# repro-symlink-intent`` header + the target string.
    # Either way the recorded target is the real unit, NEVER /dev/null.
    let root = createTempDir("nde0s_logind_", "")
    defer: removeDir(root)
    resetRecipeState(root)

    let logindHandle = consumeLogindUnmask()
    let expectedTarget = "/usr/lib/systemd/system/systemd-logind.service"

    when defined(windows):
      # Windows fallback: regular file with the intent header.
      let raw = readStoreFile(logindHandle)
      let bytes = raw.strip()
      check expectedTarget in bytes
      check "/dev/null" notin bytes
      check "# repro-symlink-intent" in raw
    else:
      # POSIX: real symlink. ``expandSymlink`` reads the target string.
      let linkPath = logindHandle.storePath / logindHandle.relPath
      let target = expandSymlink(linkPath)
      check target == expectedTarget
      check target != "/dev/null"
    # The recorded relPath is the canonicalised host path (NO trailing
    # ``.unmask-target`` suffix — that was a shim-emitter artefact the
    # M9.B materialiser drops in favour of the real link).
    check logindHandle.relPath ==
      "etc/systemd/system/systemd-logind.service"

  test "cache-key isolation: PAM stack hash != user block hash != drop-in hash":
    # A regression guard: if two emission helpers ever shared a hash
    # namespace, an accidental collision would alias their store paths
    # and the caller would silently get the wrong bytes. The M9.A
    # configFile + managedBlock + M9.B symlink digests each mix a
    # discriminator prefix into the sha256 input.
    let root = createTempDir("nde0s_isolation_", "")
    defer: removeDir(root)
    resetRecipeState(root)

    let lp   = consumeLoginPam()
    let su   = consumeSuPam()
    let pw   = consumePasswdBlock()
    let gr   = consumeGroupBlock()
    let ald  = consumeAutoLoginDropIn()
    let lg   = consumeLogindUnmask()
    let gst  = consumeGraphicalSessionTarget()
    let gspt = consumeGraphicalSessionPreTarget()
    let dt   = consumeDefaultTarget()

    # Distinct per-output hashes.
    check lp.hashHex   != su.hashHex
    check lp.hashHex   != pw.hashHex
    check lp.hashHex   != ald.hashHex
    check lp.hashHex   != lg.hashHex
    check pw.hashHex   != gr.hashHex
    check ald.hashHex  != lg.hashHex
    check gst.hashHex  != gspt.hashHex
    check gst.hashHex  != dt.hashHex

  test "configurable: defaultHome + defaultShell propagate to /etc/passwd":
    # The 7-field passwd line shape: <user>:x:<uid>:<gid>:<gecos>:<home>:<shell>
    let root = createTempDir("nde0s_home_shell_", "")
    defer: removeDir(root)
    resetRecipeState(root)
    setConfigurable("systemdSession.defaultHome", "/var/home/repro")
    setConfigurable("systemdSession.defaultShell", "/usr/bin/zsh")
    reregisterWithCurrentConfigurables(root)

    let passwdBlock = consumePasswdBlock()
    let bytes = readStoreFile(passwdBlock)

    check "/var/home/repro" in bytes
    check "/usr/bin/zsh" in bytes
    # The original defaults must NOT bleed through.
    check "/home/repro:/bin/sh" notin bytes

  test "sentinel helpers: scope renders as the spec'd lowercase string":
    # The shim's legacy ``BlockScope`` enum + ``openSentinel`` /
    # ``closeSentinel`` helpers stay reachable for back-compat (the M8
    # ``ManagedBlockScope`` is a distinct type with the same wire-
    # format string output). This is a direct check against the shim's
    # surface, no DSL involvement.
    check openSentinel(systemd_session.bsSystem, "systemd-session",
                       "system-user-repro") ==
      "# >>> repro:system:systemd-session:system-user-repro >>>"
    check closeSentinel(systemd_session.bsHome, "shell", "bashrc") ==
      "# <<< repro:home:shell:bashrc <<<"

  test "user-session targets: render expected shape":
    let root = createTempDir("nde0s_targets_", "")
    defer: removeDir(root)
    resetRecipeState(root)

    let gstHandle = consumeGraphicalSessionTarget()
    let gst = readStoreFile(gstHandle)
    check "[Unit]" in gst
    check "Description=Current graphical user session" in gst
    check "RefuseManualStart=yes" in gst

    let gsptHandle = consumeGraphicalSessionPreTarget()
    let gspt = readStoreFile(gsptHandle)
    check "[Unit]" in gspt
    check "graphical session is up" in gspt

    let dtHandle = consumeDefaultTarget()
    let dt = readStoreFile(dtHandle)
    check "[Unit]" in dt
    check "Requires=basic.target" in dt

    # And the store paths embed the /usr/lib/systemd/user/ layout (with
    # the M9.A canonicalisePath leading-/ strip).
    check gstHandle.relPath  == "usr/lib/systemd/user/graphical-session.target"
    check gsptHandle.relPath == "usr/lib/systemd/user/graphical-session-pre.target"
    check dtHandle.relPath   == "usr/lib/systemd/user/default.target"

# ---------------------------------------------------------------------------
# NDE-B DSL-surface coverage. Pins that the rewritten
# ``recipes/packages/de-foundation/systemd-session/repro.nim`` actually
# exercises the new DSL surface (M3 ``files <name>:`` blocks + M8/M9.A
# ``fs.configFile`` / ``fs.managedBlock`` + M9.B ``fs.symlink``) rather
# than silently regressing to the legacy "shim does everything" shape.
# These are extra assertions on top of the v1 surface — the v1
# structural assertions above stay intact.
# ---------------------------------------------------------------------------

suite "NDE0-S systemd-session DSL surface":

  test "recipe registers exactly 11 files: artifacts":
    let arts = registeredArtifacts("systemdSession")
    check arts.len == 11

  test "every recipe artifact is dakFiles":
    let arts = registeredArtifacts("systemdSession")
    for a in arts:
      check a.kind == dakFiles

  test "recipe artifact names cover every emitted file":
    let arts = registeredArtifacts("systemdSession")
    var names: seq[string] = @[]
    for a in arts:
      names.add(a.artifactName)
    check "loginPam"                  in names
    check "suPam"                     in names
    check "gdmLaunchPam"              in names
    check "sddmPam"                   in names
    check "userAccount"               in names
    check "userGroup"                 in names
    check "autoLoginDropIn"           in names
    check "graphicalSessionTarget"    in names
    check "graphicalSessionPreTarget" in names
    check "defaultTarget"             in names
    check "logindUnmask"              in names
