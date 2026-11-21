## Local-store root resolution and what an UNRESOLVED root does to a search
## and to a write (test-certificates Transport §2.1, §5; Conformance §5 "Root
## resolution"; Tooling §2 ``find`` exits 1 vs 3), at spec 9ebbcb3.
##
##   1. The resolver input matrix, per platform, for EVERY variable read —
##      ``TEST_CERTIFICATES_DIR``, ``XDG_STATE_HOME``, ``HOME``,
##      ``LOCALAPPDATA``, ``TEST_CERTIFICATES_SYSTEM_DIR``, ``ProgramData`` —
##      each absolute, relative, empty and unset: a relative value is
##      reported and ignored, an available absolute fallback is used,
##      exhausting the fallbacks leaves the root unresolved and reported
##      (never the current directory), a drive-relative ``C:state`` is
##      relative, and an absolute override works when its unused fallbacks
##      are relative.
##   2. The reader: an unresolved root contributes no candidates while the
##      other root is still searched, and the search is INCOMPLETE
##      (``searchIncomplete``, ``searchFailed``) — described as such, never
##      as "no certificate found". A completed empty search is described as
##      none found and is not incomplete. An unreadable system root makes it
##      incomplete too.
##   3. The writer, with this process's REAL environment: a user root that
##      cannot be resolved (``HOME`` relative, nothing else set) fails the
##      delivery, and nothing is created relative to the current directory.
##
## Falsifiability: honour a relative value → 1 fails on the relative rows;
## stop treating an unresolved system root as a hole in the search → 2's
## incomplete checks fail; resolve against the cwd → 3 finds a directory.
##
## The resolver is platform-independent (it takes the platform and the
## environment as inputs, as Conformance §5 permits); 2 and 3 run the native
## reader and writer. No mocks: the environment is a plain table.

import repro_test_support/reasoned_skip
import std/[os, sequtils, strutils, tables, tempfiles, unittest]

import repro_cli_support

type Env = Table[string, string]

proc lookup(env: Env): StoreEnvironment =
  result = proc(name: string): string = env.getOrDefault(name, "")

proc resolve(platform: StoreRootPlatform; env: Env;
             account = "1000"): CertificateStoreRoots =
  resolveCertificateStoreRoots(platform, lookup(env), account)

proc mentions(roots: CertificateStoreRoots; text: string): bool =
  roots.problems.anyIt(text in it)

const
  # One value per kind. ``""`` is the EMPTY value; a missing key is UNSET.
  posixAbs = "/abs/state"
  posixRel = "rel/state"
  winAbs = "C:\\abs\\state"
  winRel = "rel\\state"
  winDriveRel = "C:state"

suite "local store roots: resolve or report unresolved":

  test "t_store_roots_resolve_or_report_unresolved":
    # ---- 1a. Unix user root: TEST_CERTIFICATES_DIR > XDG_STATE_HOME > HOME
    block unixUser:
      # Every combination of the three variables over {abs, rel, empty,
      # unset}: the first ABSOLUTE one in priority order wins; every relative
      # one is reported; with none absolute the root is unresolved.
      let kinds = @["abs", "rel", "empty", "unset"]
      for tcd in kinds:
        for xdg in kinds:
          for home in kinds:
            var env: Env
            proc put(name, kind, absValue: string) =
              case kind
              of "abs": env[name] = absValue
              of "rel": env[name] = posixRel
              of "empty": env[name] = ""
              else: discard
            put("TEST_CERTIFICATES_DIR", tcd, "/explicit")
            put("XDG_STATE_HOME", xdg, "/xdg")
            put("HOME", home, "/home/u")
            let roots = resolve(srpUnix, env)
            let label = "unix TCD=" & tcd & " XDG=" & xdg & " HOME=" & home
            checkpoint(label & " -> '" & roots.user & "' " &
              roots.problems.join(" | "))
            let expected =
              if tcd == "abs": "/explicit"
              elif xdg == "abs": "/xdg/test-certificates"
              elif home == "abs": "/home/u/.local/state/test-certificates"
              else: ""
            check roots.user == expected
            # A relative value is REPORTED whenever it was consulted — and an
            # absolute override means its fallbacks are never consulted.
            if tcd == "rel":
              check roots.mentions("$TEST_CERTIFICATES_DIR is set to the " &
                "relative path")
            if tcd != "abs" and xdg == "rel":
              check roots.mentions("$XDG_STATE_HOME is set to the relative path")
            if tcd != "abs" and xdg != "abs" and home == "rel":
              check roots.mentions("$HOME is set to the relative path")
            if tcd == "abs":
              check not roots.mentions("XDG_STATE_HOME")
              check not roots.mentions("$HOME")
            if expected.len == 0:
              check roots.mentions("the user root cannot be resolved")
            # Never the current directory, in any combination.
            check not roots.user.startsWith(posixRel)
            check not roots.user.startsWith(getCurrentDir())

    # ---- 1b. macOS user root: TEST_CERTIFICATES_DIR > HOME ---------------
    for (home, expected) in [("/Users/u", "/Users/u/Library/Application " &
                                "Support/test-certificates"),
                             (posixRel, ""), ("", "")]:
      let roots = resolve(srpMacos, {"HOME": home}.toTable)
      checkpoint("macos HOME='" & home & "' -> '" & roots.user & "'")
      check roots.user == expected
      if home == posixRel:
        check roots.mentions("$HOME is set to the relative path")
    check resolve(srpMacos, initTable[string, string]()).user == ""
    check resolve(srpMacos, {"TEST_CERTIFICATES_DIR": "/x",
      "HOME": posixRel}.toTable).user == "/x"

    # ---- 1c. Windows user root: TEST_CERTIFICATES_DIR > LOCALAPPDATA -----
    for (value, expected) in [(winAbs, winAbs & "\\test-certificates"),
                              ("\\\\server\\share", "\\\\server\\share\\" &
                                "test-certificates"),
                              (winRel, ""), (winDriveRel, ""),
                              ("/posix/abs", ""), ("", "")]:
      let roots = resolve(srpWindows, {"LOCALAPPDATA": value}.toTable,
        "S-1-5-21-1-2-3-1001")
      checkpoint("windows LOCALAPPDATA='" & value & "' -> '" & roots.user &
        "'")
      check roots.user == expected
      if value in [winRel, winDriveRel, "/posix/abs"]:
        check roots.mentions("%LOCALAPPDATA% is set to the relative path")
    check resolve(srpWindows, initTable[string, string](),
      "S-1-5-21-1-2-3-1001").user == ""
    # A drive-relative override is relative too; the fallback is used.
    let driveOverride = resolve(srpWindows, {"TEST_CERTIFICATES_DIR":
      winDriveRel, "LOCALAPPDATA": winAbs}.toTable, "S-1-5-21-1-2-3-1001")
    check driveOverride.user == winAbs & "\\test-certificates"
    check driveOverride.mentions("%TEST_CERTIFICATES_DIR% is set to the " &
      "relative path 'C:state'")

    # ---- 1d. System roots ------------------------------------------------
    # Unix and macOS: TEST_CERTIFICATES_SYSTEM_DIR when absolute, else the
    # fixed machine-wide directory — never relative, so never unresolved
    # for want of a variable.
    for (platform, fixed) in [(srpUnix, "/var/lib/test-certificates/1000"),
        (srpMacos, "/Library/Application Support/test-certificates/1000")]:
      check resolve(platform, initTable[string, string]()).system == fixed
      check resolve(platform, {"TEST_CERTIFICATES_SYSTEM_DIR": ""}.toTable).
        system == fixed
      let rel = resolve(platform,
        {"TEST_CERTIFICATES_SYSTEM_DIR": posixRel}.toTable)
      check rel.system == fixed
      check rel.mentions("$TEST_CERTIFICATES_SYSTEM_DIR is set to the " &
        "relative path")
      check resolve(platform, {"TEST_CERTIFICATES_SYSTEM_DIR":
        posixAbs}.toTable).system == posixAbs & "/1000"
    # Windows: TEST_CERTIFICATES_SYSTEM_DIR > ProgramData > unresolved.
    let sid = "S-1-5-21-1-2-3-1001"
    for (value, expected) in [(winAbs, winAbs & "\\test-certificates\\" & sid),
                              (winRel, ""), (winDriveRel, ""), ("", "")]:
      let roots = resolve(srpWindows, {"ProgramData": value}.toTable, sid)
      checkpoint("windows ProgramData='" & value & "' -> '" & roots.system &
        "'")
      check roots.system == expected
      if expected.len == 0:
        check roots.mentions("the system root cannot be resolved")
      if value in [winRel, winDriveRel]:
        check roots.mentions("%ProgramData% is set to the relative path")
    check resolve(srpWindows, {"TEST_CERTIFICATES_SYSTEM_DIR": winAbs,
      "ProgramData": winRel}.toTable, sid).system == winAbs & "\\" & sid
    # No account (or not an account id): the system root is unresolved and
    # reported, never a guessed partition.
    check resolve(srpUnix, initTable[string, string](), "").system == ""
    check resolve(srpUnix, initTable[string, string](), "").mentions(
      "the system root cannot be resolved")
    check resolve(srpUnix, initTable[string, string](), "../0").system == ""

    # ---- 2. the reader: unresolved and unreadable roots -----------------
    let scratch = createTempDir("repro-store-roots-", "")
    defer: removeDir(scratch)
    let content = "git-tree-sha1:" & "a".repeat(40)
    let cert = TestCertificate(schema: testCertificateSchemaV1,
      framework: reprobuildFrameworkId, project: "p",
      platform: "linux/amd64", targets: @["t"], result: tcrPassed,
      issuedAt: "2026-10-29T00:00:00Z", issuer: "roots",
      vcs: TestCertificateVcs(repo: "p", content: content),
      commands: @[TestCertificateCommand(argv: @["true"])])
    let systemRoot = scratch / "system" / "1000"
    check publishCertificateDocument(systemRoot,
      serializeCertificateToToml(cert)).error == ""
    let state = stateWithKnownContent(@[KnownContentId(
      algorithm: "git-tree-sha1", id: content)])
    # The user root is unresolved; the system root still yields its record.
    let userUnresolved = findCertificatesInLocalStore(state,
      CertificateStoreRoots(user: "", system: systemRoot,
        problems: @["the user root cannot be resolved: test"]))
    check userUnresolved.found.len == 1
    check userUnresolved.searchIncomplete
    check userUnresolved.searchFailed
    check userUnresolved.notSearched.anyIt("user root is unresolved" in it)
    # Both unresolved: nothing found, and that is NOT "none found".
    let neither = findCertificatesInLocalStore(state,
      CertificateStoreRoots(user: "", system: ""))
    check neither.found.len == 0
    check neither.searchIncomplete
    check neither.searchFailed
    check "INCOMPLETE" in describeLocalStoreSearch(neither)
    check "does not establish that none exists" in
      describeLocalStoreSearch(neither)
    # A completed empty search: both roots resolved, nothing stored.
    let empty = findCertificatesInLocalStore(state,
      CertificateStoreRoots(user: scratch / "empty-user",
        system: scratch / "empty-system"))
    check empty.found.len == 0
    check not empty.searchIncomplete
    check not empty.searchFailed
    check describeLocalStoreSearch(empty).startsWith(
      "no certificate found in the local store")
    check "INCOMPLETE" notin describeLocalStoreSearch(empty)
    # An unreadable system root is a hole in the search as well.
    when not defined(windows):
      let lockedSystem = scratch / "locked-system" / "1000"
      createDir(lockedSystem / "v1")
      setFilePermissions(lockedSystem, {})
      defer: setFilePermissions(lockedSystem,
        {fpUserRead, fpUserWrite, fpUserExec})
      var readable = true
      try:
        for _ in walkDir(lockedSystem, checkDir = true): discard
      except OSError:
        readable = false
      if readable:
        skip("this process can list a mode-000 directory (it runs as " &
          "root), so an unreadable system root cannot be constructed here")
      else:
        let unreadable = findCertificatesInLocalStore(state,
          CertificateStoreRoots(user: scratch / "empty-user",
            system: lockedSystem))
        check unreadable.found.len == 0
        check unreadable.searchIncomplete
        check unreadable.searchFailed
        check not unreadable.userRootUnreadable
        check unreadable.notSearched.anyIt("system root" in it and
          "could not be read" in it)

    # ---- 3. the native writer with an unresolvable user root -------------
    when not defined(windows):
      let work = scratch / "cwd"
      createDir(work)
      let savedDir = getCurrentDir()
      var saved: seq[(string, bool, string)]
      for name in ["TEST_CERTIFICATES_DIR", "XDG_STATE_HOME", "HOME"]:
        saved.add((name, existsEnv(name), getEnv(name)))
      setCurrentDir(work)
      try:
        delEnv("TEST_CERTIFICATES_DIR")
        delEnv("XDG_STATE_HOME")
        putEnv("HOME", "relative-home")
        let roots = nativeCertificateStoreRoots()
        check roots.user == ""
        check roots.problems.anyIt("$HOME is set to the relative path" in it)
        let delivered = publishCertificateToLocalStore(cert, "", roots)
        check not delivered.written
        check "could not be resolved" in delivered.error
        # Nothing was created relative to the current directory.
        check toSeq(walkDir(work)).len == 0
        # And the native reader reports the hole rather than an empty store.
        let found = findCertificatesInLocalStore(state, roots)
        check found.searchIncomplete
      finally:
        setCurrentDir(savedDir)
        for (name, existed, value) in saved:
          if existed: putEnv(name, value) else: delEnv(name)
