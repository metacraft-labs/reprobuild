## NDE0-S unit tests: native systemd-session package.
##
## Exercises the spec'd public surface of
## ``libs/repro_dsl_stdlib/src/repro_dsl_stdlib/packages/de_foundation/
## systemd_session.nim`` against synthetic configurations.
##
## Required test surfaces (per the NDE0-S sub-agent prompt §"Write unit
## tests"):
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
##      independent materialize calls into separate roots.
##   7. Sentinel shape for the user block: verify the
##      ``# >>> repro:system:systemd-session:system-user-<user> >>>``
##      open + matching close sentinel.
##   8. Autologin drop-in carries the configurable user in the
##      ExecStart= override.
##   9. Logind un-mask records the real-unit target (NOT /dev/null).
##
## Plus a handful of additional invariants that catch common regressions
## (cache-key-isolation across outputs, hash hex length, scope rendering).
##
## No try/except swallows. Failure paths use ``expect`` (not in this
## file as all of NDE0-S's primitives are infallible by design — the
## impl module's helpers do not raise unless the host filesystem itself
## fails). All assertions use ``check`` so failures stack diagnostics.

import std/[os, strutils, tempfiles, unittest]

import repro_dsl_stdlib/packages/de_foundation/systemd_session

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc readStoreFile(handle: ManagedFiles): string =
  ## Read the bytes of the emitted file at ``handle.storePath/handle.relPath``.
  let p = handle.storePath / handle.relPath
  check fileExists(p)
  result = readFile(p)

proc configWithRoot(storeRoot: string): SystemdSessionConfig =
  result = defaultSystemdSessionConfig()
  result.storeRoot = storeRoot

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

suite "NDE0-S systemd-session package":

  test "PAM stack: /etc/pam.d/login content has pam_unix.so + pam_systemd.so":
    let root = createTempDir("nde0s_pam_login_", "")
    defer: removeDir(root)

    let outs = materializeSystemdSession(configWithRoot(root))
    let bytes = readStoreFile(outs.pamLogin)

    # The Tier-2 stage 2 block contract: auth + account + session via
    # pam_unix, plus a session-tier pam_systemd so logind creates the
    # XDG_RUNTIME_DIR.
    check "pam_unix.so" in bytes
    check "pam_systemd.so" in bytes
    check "auth     required pam_unix.so" in bytes
    check "session  required pam_systemd.so" in bytes
    # Sanity: the store path is rooted under the override.
    check outs.pamLogin.storePath.startsWith(root)
    # Each per-output hash is 16 hex chars (mirrors NDE0-A).
    check outs.pamLogin.hashHex.len == 16

  test "configurable: changing defaultUser propagates to /etc/passwd":
    let root = createTempDir("nde0s_user_alice_", "")
    defer: removeDir(root)

    var cfg = configWithRoot(root)
    cfg.defaultUser = "alice"
    let outs = materializeSystemdSession(cfg)
    let bytes = readStoreFile(outs.passwdBlock)

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

    var cfg = configWithRoot(root)
    cfg.defaultUid = 2000
    cfg.defaultGid = 2000
    let outs = materializeSystemdSession(cfg)
    let bytes = readStoreFile(outs.passwdBlock)

    check ":2000:2000:" in bytes
    check ":1000:1000:" notin bytes

  test "idempotency: same config produces same store paths":
    let root = createTempDir("nde0s_idem_", "")
    defer: removeDir(root)

    let outsA = materializeSystemdSession(configWithRoot(root))
    let outsB = materializeSystemdSession(configWithRoot(root))

    # Every output should land at exactly the same store path on a
    # second invocation (content-addressed hash is a pure function of
    # the inputs).
    check outsA.pamLogin.storePath              == outsB.pamLogin.storePath
    check outsA.pamSu.storePath                 == outsB.pamSu.storePath
    check outsA.pamGdmLaunch.storePath          == outsB.pamGdmLaunch.storePath
    check outsA.pamSddm.storePath               == outsB.pamSddm.storePath
    check outsA.passwdBlock.storePath           == outsB.passwdBlock.storePath
    check outsA.groupBlock.storePath            == outsB.groupBlock.storePath
    check outsA.autoLoginDropIn.storePath       == outsB.autoLoginDropIn.storePath
    check outsA.logindUnmask.storePath          == outsB.logindUnmask.storePath
    check outsA.graphicalSessionTarget.storePath ==
          outsB.graphicalSessionTarget.storePath
    check outsA.graphicalSessionPreTarget.storePath ==
          outsB.graphicalSessionPreTarget.storePath
    check outsA.defaultTarget.storePath         == outsB.defaultTarget.storePath

  test "configurable invalidation: defaultUser change → different /etc/passwd store path":
    # This is the load-bearing cache-key test the spec calls out
    # ("Toggling config.defaultUser from 'repro' to 'alice' rebuilds
    # only the affected files"). If the cache key didn't include the
    # configurable, both calls would land at the same store path and
    # the second call would never re-emit the user block.
    let root = createTempDir("nde0s_invalidation_", "")
    defer: removeDir(root)

    var cfgA = configWithRoot(root)
    cfgA.defaultUser = "repro"
    let outsA = materializeSystemdSession(cfgA)

    var cfgB = configWithRoot(root)
    cfgB.defaultUser = "alice"
    let outsB = materializeSystemdSession(cfgB)

    # The user blocks MUST land at different store paths.
    check outsA.passwdBlock.storePath != outsB.passwdBlock.storePath
    check outsA.groupBlock.storePath  != outsB.groupBlock.storePath
    check outsA.autoLoginDropIn.storePath != outsB.autoLoginDropIn.storePath
    # And the PAM stacks (which DON'T depend on defaultUser) MUST stay
    # at the same store path — that's the "rebuilds only the affected
    # files" half of the spec contract.
    check outsA.pamLogin.storePath == outsB.pamLogin.storePath
    check outsA.pamSu.storePath    == outsB.pamSu.storePath
    check outsA.logindUnmask.storePath == outsB.logindUnmask.storePath
    check outsA.graphicalSessionTarget.storePath ==
          outsB.graphicalSessionTarget.storePath

  test "determinism: PAM stacks byte-identical across two independent roots":
    # The idempotency test catches re-entry into the same store root
    # (a marker-file short-circuit could mask a non-deterministic
    # writer); this test forces a fresh write into a SECOND root and
    # byte-compares the result.
    let rootA = createTempDir("nde0s_detA_", "")
    let rootB = createTempDir("nde0s_detB_", "")
    defer:
      removeDir(rootA)
      removeDir(rootB)

    let outsA = materializeSystemdSession(configWithRoot(rootA))
    let outsB = materializeSystemdSession(configWithRoot(rootB))

    # The basenames (the content-addressed hash segment) must match.
    check extractFilename(outsA.pamLogin.storePath) ==
          extractFilename(outsB.pamLogin.storePath)
    check extractFilename(outsA.pamSu.storePath) ==
          extractFilename(outsB.pamSu.storePath)
    check extractFilename(outsA.passwdBlock.storePath) ==
          extractFilename(outsB.passwdBlock.storePath)

    # And every file's bytes are byte-identical.
    check readStoreFile(outsA.pamLogin)       == readStoreFile(outsB.pamLogin)
    check readStoreFile(outsA.pamSu)          == readStoreFile(outsB.pamSu)
    check readStoreFile(outsA.pamGdmLaunch)   == readStoreFile(outsB.pamGdmLaunch)
    check readStoreFile(outsA.pamSddm)        == readStoreFile(outsB.pamSddm)
    check readStoreFile(outsA.passwdBlock)    == readStoreFile(outsB.passwdBlock)
    check readStoreFile(outsA.groupBlock)     == readStoreFile(outsB.groupBlock)
    check readStoreFile(outsA.autoLoginDropIn) ==
          readStoreFile(outsB.autoLoginDropIn)

  test "sentinel shape: user block uses NDE-spec-block triple form":
    # Per Generated-Configuration-Files.md §"Sentinel uniqueness":
    #   # >>> repro:<scope>:<packageName>:<blockId> >>>
    #   ...
    #   # <<< repro:<scope>:<packageName>:<blockId> <<<
    # scope = system, packageName = systemd-session, blockId =
    # system-user-<user>.
    let root = createTempDir("nde0s_sentinel_", "")
    defer: removeDir(root)

    let outs = materializeSystemdSession(configWithRoot(root))
    let bytes = readStoreFile(outs.passwdBlock)

    let expectOpen =
      "# >>> repro:system:systemd-session:system-user-repro >>>"
    let expectClose =
      "# <<< repro:system:systemd-session:system-user-repro <<<"

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

    var cfg = configWithRoot(root)
    cfg.defaultUser = "alice"
    let outs = materializeSystemdSession(cfg)
    let bytes = readStoreFile(outs.autoLoginDropIn)

    # The cascade-A fix shape: ExecStart= (reset) followed by a
    # second ExecStart= with --autologin <user>.
    check "[Service]" in bytes
    check "ExecStart=\nExecStart=-/sbin/agetty --autologin alice" in bytes
    # And the file lives at the spec'd path.
    check outs.autoLoginDropIn.relPath ==
      "etc/systemd/system/serial-getty@ttyS0.service.d/zz-repro-autologin.conf"

  test "logind un-mask: target is the real unit, NOT /dev/null":
    # The R9 base masks systemd-logind by symlinking
    # /etc/systemd/system/systemd-logind.service -> /dev/null.
    # NDE0-S un-masks by recording the real /usr/lib/... unit as the
    # target. The acceptance asserts the recorded target is the real
    # unit path.
    let root = createTempDir("nde0s_logind_", "")
    defer: removeDir(root)

    let outs = materializeSystemdSession(configWithRoot(root))
    let bytes = readStoreFile(outs.logindUnmask).strip()

    check bytes == "/usr/lib/systemd/system/systemd-logind.service"
    check bytes != "/dev/null"
    # The manifest file's relative path encodes both the source and
    # the .unmask-target suffix so the activation layer can find it.
    check outs.logindUnmask.relPath ==
      "etc/systemd/system/systemd-logind.service.unmask-target"

  test "cache-key isolation: PAM stack hash != user block hash != drop-in hash":
    # A regression guard: if two emission helpers ever shared a hash
    # namespace (e.g. both used the same composed string prefix), an
    # accidental collision would alias their store paths and the
    # caller would silently get the wrong bytes. The hashes are 16-
    # hex-char truncations of sha256 — collisions are astronomically
    # unlikely but the test catches "I forgot to vary the prefix"
    # mistakes at code-review time.
    let root = createTempDir("nde0s_isolation_", "")
    defer: removeDir(root)

    let outs = materializeSystemdSession(configWithRoot(root))

    # Distinct per-output hashes.
    check outs.pamLogin.hashHex          != outs.pamSu.hashHex
    check outs.pamLogin.hashHex          != outs.passwdBlock.hashHex
    check outs.pamLogin.hashHex          != outs.autoLoginDropIn.hashHex
    check outs.pamLogin.hashHex          != outs.logindUnmask.hashHex
    check outs.passwdBlock.hashHex       != outs.groupBlock.hashHex
    check outs.autoLoginDropIn.hashHex   != outs.logindUnmask.hashHex
    check outs.graphicalSessionTarget.hashHex !=
          outs.graphicalSessionPreTarget.hashHex
    check outs.graphicalSessionTarget.hashHex != outs.defaultTarget.hashHex

  test "configurable: defaultHome + defaultShell propagate to /etc/passwd":
    # The 7-field passwd line shape: <user>:x:<uid>:<gid>:<gecos>:<home>:<shell>
    let root = createTempDir("nde0s_home_shell_", "")
    defer: removeDir(root)

    var cfg = configWithRoot(root)
    cfg.defaultHome = "/var/home/repro"
    cfg.defaultShell = "/usr/bin/zsh"
    let outs = materializeSystemdSession(cfg)
    let bytes = readStoreFile(outs.passwdBlock)

    check "/var/home/repro" in bytes
    check "/usr/bin/zsh" in bytes
    # The original defaults must NOT bleed through.
    check "/home/repro:/bin/sh" notin bytes

  test "sentinel helpers: scope renders as the spec'd lowercase string":
    # The BlockScope enum's stringification feeds directly into the
    # sentinel format; a regression here would corrupt every emitted
    # block. Cheap direct check.
    check openSentinel(bsSystem, "systemd-session", "system-user-repro") ==
      "# >>> repro:system:systemd-session:system-user-repro >>>"
    check closeSentinel(bsHome, "shell", "bashrc") ==
      "# <<< repro:home:shell:bashrc <<<"

  test "user-session targets: render expected shape":
    let root = createTempDir("nde0s_targets_", "")
    defer: removeDir(root)

    let outs = materializeSystemdSession(configWithRoot(root))

    let gst = readStoreFile(outs.graphicalSessionTarget)
    check "[Unit]" in gst
    check "Description=Current graphical user session" in gst
    check "RefuseManualStart=yes" in gst

    let gspt = readStoreFile(outs.graphicalSessionPreTarget)
    check "[Unit]" in gspt
    check "graphical session is up" in gspt

    let dt = readStoreFile(outs.defaultTarget)
    check "[Unit]" in dt
    check "Requires=basic.target" in dt

    # And the store paths embed the /usr/lib/systemd/user/ layout.
    check outs.graphicalSessionTarget.relPath ==
      "usr/lib/systemd/user/graphical-session.target"
    check outs.graphicalSessionPreTarget.relPath ==
      "usr/lib/systemd/user/graphical-session-pre.target"
    check outs.defaultTarget.relPath ==
      "usr/lib/systemd/user/default.target"
