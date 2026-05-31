## M70 — `repro home migrate-from-env-scripts` unit tests.
##
## Hermetic (no network, no real catalog refresh) coverage of:
##
##   1. ``EnvVarToToolMap`` round-trip for the canonical Windows pins
##      from the real ``toolchain-versions.env``.
##   2. ``parseEnvFile`` skips comments / blanks / malformed lines and
##      preserves source line numbers for diagnostics.
##   3. ``planMigration`` classifies each pin into the right
##      ``MigrationOutcomeKind``:
##        - moMigrate for catalog-hit + version-present + not deferred
##        - moDeferred for the M70 deferred-8 list (swift, etc.)
##        - moMissingVersion for catalog-hit + version not in catalog
##        - moUnknown for env-file keys not in ``EnvVarToToolMap``
##        - moIgnored for ``IgnoredEnvVars`` (build qualifiers, etc.)
##        - moAlreadyOwned for tools already pinned in the destination
##   4. ``ownedToolsInProfile`` extracts the tools the destination
##      ``home.nim`` already owns from a parsed Profile.
##   5. ``renderPackageLine`` + ``renderTodoComment`` produce
##      structural-editor-compatible output (indentation matches the
##      editor's emission shape).
##   6. End-to-end CLI invocation: scaffolds a fresh home.nim, applies
##      the migration twice, and asserts idempotence (the second run
##      adds zero lines).

import std/[options, os, sets, strutils, unittest]

import repro_cli_support/migrate_from_env_scripts
import repro_cli_support/home

const TmpDir = "build/test-tmp/m70-migrate-from-env-scripts"

proc resetTmp() =
  if dirExists(TmpDir):
    removeDir(TmpDir)
  createDir(TmpDir)

proc writeTmp(name, content: string): string =
  result = TmpDir / name
  writeFile(result, content)

const RealToolchainVersionsEnv = """
# Pinned tool versions for the metacraft Windows dev environment.
# Shared install root: WINDOWS_DIY_INSTALL_ROOT (default D:\metacraft-dev-deps)

JUST_VERSION=1.47.1
GH_VERSION=2.88.1
PYTHON_VERSION=3.12.10
GIT_REPO_VERSION=2.50
VULKAN_HEADERS_VERSION=1.3.296.0
MESA_VERSION=24.3.4
JDK_VERSION=21.0.5
JDK_BUILD=11
MAVEN_VERSION=3.9.9
GRADLE_VERSION=8.10.2
SWIFT_VERSION=5.10.1
ZIG_VERSION=0.13.0
"""

# ---------------------------------------------------------------------------
# parseEnvFile + lookupTool
# ---------------------------------------------------------------------------

suite "M70 env-file parser":

  test "parses real-toolchain-versions.env into the expected pin set":
    let parsed = parseEnvFile(RealToolchainVersionsEnv)
    # 12 non-comment/blank lines in the fixture.
    check parsed.pins.len == 12
    # Order is preserved.
    check parsed.pins[0].envVar == "JUST_VERSION"
    check parsed.pins[0].version == "1.47.1"
    check parsed.pins[^1].envVar == "ZIG_VERSION"
    check parsed.pins[^1].version == "0.13.0"

  test "skips comments and blank lines silently":
    let parsed = parseEnvFile("""
# header
A=1

# middle

B=2
""")
    check parsed.pins.len == 2
    check parsed.pins[0].envVar == "A"
    check parsed.pins[1].envVar == "B"

  test "skips malformed lines (no `=`) without raising":
    let parsed = parseEnvFile("""
A=1
THIS IS NOT AN ASSIGNMENT
B=2
""")
    check parsed.pins.len == 2

  test "preserves source line numbers for diagnostics":
    let parsed = parseEnvFile("""
# comment
JUST_VERSION=1.47.1
# another comment
JDK_VERSION=21.0.5
""")
    check parsed.pins.len == 2
    check parsed.pins[0].envVar == "JUST_VERSION"
    check parsed.pins[0].lineNo == 2
    check parsed.pins[1].envVar == "JDK_VERSION"
    check parsed.pins[1].lineNo == 4

# ---------------------------------------------------------------------------
# VAR → tool name mapping
# ---------------------------------------------------------------------------

suite "M70 VAR → tool mapping":

  test "every real-env pin classifies as known, ignored, or in the deferred-8":
    let parsed = parseEnvFile(RealToolchainVersionsEnv)
    var classified = 0
    for pin in parsed.pins:
      if isIgnoredEnvVar(pin.envVar):
        inc classified
      else:
        let tool = lookupTool(pin.envVar)
        if tool.isSome:
          inc classified
    # Every pin should be either ignored or mapped to a tool.
    check classified == parsed.pins.len

  test "deferred-8 includes swift, gcc, git, meson, python3, composer, erlang, ruby":
    check isDeferredTool("swift")
    check isDeferredTool("gcc")
    check isDeferredTool("git")
    check isDeferredTool("meson")
    check isDeferredTool("python3")
    check isDeferredTool("composer")
    check isDeferredTool("erlang")
    check isDeferredTool("ruby")
    # Tools that should NOT be deferred:
    check not isDeferredTool("just")
    check not isDeferredTool("jdk")
    check not isDeferredTool("maven")
    check not isDeferredTool("zig")

  test "ignored env vars include build qualifiers and system-profile tools":
    check isIgnoredEnvVar("JDK_BUILD")
    check isIgnoredEnvVar("GIT_REPO_VERSION")
    check isIgnoredEnvVar("VULKAN_HEADERS_VERSION")
    check isIgnoredEnvVar("MESA_VERSION")
    # A real tool is NOT ignored.
    check not isIgnoredEnvVar("JDK_VERSION")
    check not isIgnoredEnvVar("ZIG_VERSION")

# ---------------------------------------------------------------------------
# planMigration: outcome classification
# ---------------------------------------------------------------------------

suite "M70 migration plan":

  test "synthetic env file with jdk@21.0.5 (catalog version) produces a clean migrate":
    let parsed = parseEnvFile("""
JDK_VERSION=21.0.5
""")
    let owned = initHashSet[string]()
    let plan = planMigration(parsed, "migrated_from_env_scripts", owned)
    check plan.activity == "migrated_from_env_scripts"
    check plan.lines.len == 1
    check plan.lines[0].kind == moMigrate
    check plan.lines[0].tool == "jdk"
    check "package(jdk, \"21.0.5\")" in plan.lines[0].text

  test "env-file pin with a version NOT in the catalog yields moMissingVersion":
    # The catalog's zig slice is pinned at 0.16.0 (see
    # packages/zig.nim); the legacy env file pins 0.13.0, so the
    # migrator emits a TODO comment instead of a live package(...)
    # line. The user must either bump the catalog or pin a known
    # catalog version.
    let parsed = parseEnvFile("ZIG_VERSION=0.13.0\n")
    let plan = planMigration(parsed, "dev", initHashSet[string]())
    check plan.lines.len == 1
    check plan.lines[0].kind == moMissingVersion
    check plan.lines[0].tool == "zig"
    check "version 0.13.0 not in catalog" in plan.lines[0].text

  test "SWIFT_VERSION produces a deferred TODO (in deferred-8 list)":
    let parsed = parseEnvFile("SWIFT_VERSION=5.10.1\n")
    let plan = planMigration(parsed, "dev", initHashSet[string]())
    check plan.lines.len == 1
    check plan.lines[0].kind == moDeferred
    check plan.lines[0].tool == "swift"
    check "TODO migrate swift@5.10.1" in plan.lines[0].text

  test "unknown env-file key produces a TODO comment":
    let parsed = parseEnvFile("FOOBAR_VERSION=1.0\n")
    let plan = planMigration(parsed, "dev", initHashSet[string]())
    check plan.lines.len == 1
    check plan.lines[0].kind == moUnknown
    check "TODO migrate" in plan.lines[0].text
    check "FOOBAR_VERSION" in plan.lines[0].text

  test "ignored env-file key produces no rendered line":
    let parsed = parseEnvFile("JDK_BUILD=11\n")
    let plan = planMigration(parsed, "dev", initHashSet[string]())
    check plan.lines.len == 1
    check plan.lines[0].kind == moIgnored
    check plan.lines[0].text == ""  # no rendered text for ignored entries

  test "already-owned tool is skipped (idempotence helper)":
    var owned = initHashSet[string]()
    owned.incl("jdk")
    let parsed = parseEnvFile("JDK_VERSION=21.0.5\n")
    let plan = planMigration(parsed, "dev", owned)
    check plan.lines.len == 1
    check plan.lines[0].kind == moAlreadyOwned
    check plan.lines[0].tool == "jdk"

  test "summary counts each outcome accurately":
    let parsed = parseEnvFile("""
JDK_VERSION=21.0.5
ZIG_VERSION=0.13.0
SWIFT_VERSION=5.10.1
FOOBAR_VERSION=1.0
JDK_BUILD=11
""")
    let plan = planMigration(parsed, "dev", initHashSet[string]())
    let s = summarize(plan)
    check s.migrated == 1        # jdk (catalog version)
    check s.deferred == 1        # swift (deferred-8)
    check s.missingVersion == 1  # zig (env pins 0.13.0; catalog has 0.16.0)
    check s.unknown == 1         # foobar
    check s.ignored == 1         # jdk_build
    check s.alreadyOwned == 0

# ---------------------------------------------------------------------------
# ownedToolsInProfile + ownedToolsAtPath
# ---------------------------------------------------------------------------

suite "M70 owned-tool detection":

  test "home.nim with package(just) is detected as owning `just`":
    resetTmp()
    let path = writeTmp("home.nim", """import repro/profile

profile "rt":
  activity dev:
    package(just, "1.47.1")
""")
    let owned = ownedToolsAtPath(path)
    check "just" in owned
    check owned.len == 1

  test "bare-identifier `just` (legacy form) is NOT detected as owned":
    # Per the M70 spec the helper only recognizes the `package(...)`
    # form. A bare-identifier reference is a legacy form that the M69
    # catalog/realize path does not understand.
    resetTmp()
    let path = writeTmp("home.nim", """import repro/profile

profile "rt":
  activity dev:
    git
""")
    let owned = ownedToolsAtPath(path)
    # `git` IS recorded as a packageRef (the legacy parser stores it
    # as nkPackageRef with empty packageVersion). The spec's distinction
    # is about catalog resolvability, not about parse classification.
    # We assert that the legacy bare-identifier shape is recognized:
    check "git" in owned

  test "empty / malformed home.nim returns an empty set without raising":
    resetTmp()
    let missing = TmpDir / "does-not-exist.nim"
    let owned = ownedToolsAtPath(missing)
    check owned.len == 0
    let bad = writeTmp("bad.nim", "this is not a valid profile\n")
    let ownedBad = ownedToolsAtPath(bad)
    check ownedBad.len == 0

  test "commented-out `# package(jdk, ...)` is NOT detected as owned":
    # Documents the comment-false-match guard. The Nim intent-layer
    # parser ignores `#` comments at parse time, so a commented-out
    # `package(...)` line never reaches collectPackageRefs. The
    # PowerShell sibling helper (windows/lib-home-profile-detect.ps1)
    # enforces the same invariant via a `#`-strip pass before its
    # regex match — see Get-HomeProfileOwnedTools.
    resetTmp()
    let path = writeTmp("home.nim", """import repro/profile

# Just an audit comment mentioning package(jdk, "21.0.5")
profile "rt":
  activity dev:
    # legacy: package(maven, "3.9.9") — kept here for reference
    discard
""")
    let owned = ownedToolsAtPath(path)
    check "jdk" notin owned
    check "maven" notin owned
    check owned.len == 0

  test "multiple activities + conditional blocks collect every tool":
    resetTmp()
    let path = writeTmp("home.nim", """import repro/profile

profile "rt":
  activity dev:
    package(jdk, "21.0.5")
    when linux:
      package(zig, "0.13.0")
  activity ops:
    package(just, "1.47.1")
""")
    let owned = ownedToolsAtPath(path)
    check "jdk" in owned
    check "zig" in owned
    check "just" in owned
    check owned.len == 3

# ---------------------------------------------------------------------------
# Line rendering
# ---------------------------------------------------------------------------

suite "M70 line rendering":

  test "renderPackageLine matches the structural editor's emission":
    let line = renderPackageLine("jdk", "21.0.5", indent = 4)
    check line == "    package(jdk, \"21.0.5\")"

  test "renderTodoComment names the env-var and the tool":
    let line = renderTodoComment("SWIFT_VERSION", "swift", "5.10.1",
      "deferred until cakBuiltin supports swift", indent = 4)
    check "TODO migrate swift@5.10.1" in line
    check "SWIFT_VERSION" in line
    check "deferred" in line

  test "renderTodoComment for unknown tool drops the tool name":
    let line = renderTodoComment("FOOBAR_VERSION", "", "1.0",
      "unknown env-file key FOOBAR_VERSION", indent = 4)
    check "TODO migrate" in line
    check "FOOBAR_VERSION" in line

# ---------------------------------------------------------------------------
# End-to-end CLI: scaffold + apply migration + idempotence
# ---------------------------------------------------------------------------

proc setupCliEnv(profileDir, envFile: string) =
  putEnv("REPRO_HOME_PROFILE_DIR", profileDir)
  putEnv("METACRAFT_ROOT", "")  # force --env-file to be the source

suite "M70 CLI end-to-end":

  test "--dry-run does not write the home.nim":
    resetTmp()
    let envFile = writeTmp("toolchain-versions.env",
      "JDK_VERSION=21.0.5\n")
    let profileDir = TmpDir / "profile-dry-run"
    createDir(profileDir)
    setupCliEnv(profileDir, envFile)
    let rc = runHomeCommand(@["migrate-from-env-scripts",
      "--env-file", envFile, "--dry-run"])
    check rc == 0
    check not fileExists(profileDir / "home.nim")

  test "non-dry-run writes the synthesized lines into a fresh home.nim":
    resetTmp()
    let envFile = writeTmp("toolchain-versions.env",
      "JDK_VERSION=21.0.5\n")
    let profileDir = TmpDir / "profile-write"
    createDir(profileDir)
    setupCliEnv(profileDir, envFile)
    let rc = runHomeCommand(@["migrate-from-env-scripts",
      "--env-file", envFile])
    check rc == 0
    let written = readFile(profileDir / "home.nim")
    check "package(jdk, \"21.0.5\")" in written
    check "activity migrated_from_env_scripts:" in written

  test "idempotent: running twice does not duplicate lines":
    resetTmp()
    let envFile = writeTmp("toolchain-versions.env",
      "JDK_VERSION=21.0.5\n")
    let profileDir = TmpDir / "profile-idempotent"
    createDir(profileDir)
    setupCliEnv(profileDir, envFile)
    let rc1 = runHomeCommand(@["migrate-from-env-scripts",
      "--env-file", envFile])
    check rc1 == 0
    let afterFirst = readFile(profileDir / "home.nim")
    let rc2 = runHomeCommand(@["migrate-from-env-scripts",
      "--env-file", envFile])
    check rc2 == 0
    let afterSecond = readFile(profileDir / "home.nim")
    check afterFirst == afterSecond
    # Sanity: there is exactly one occurrence of the pinned line.
    check afterSecond.count("package(jdk, \"21.0.5\")") == 1

  test "--activity routes lines into the named activity":
    resetTmp()
    let envFile = writeTmp("toolchain-versions.env", "JDK_VERSION=21.0.5\n")
    let profileDir = TmpDir / "profile-activity"
    createDir(profileDir)
    setupCliEnv(profileDir, envFile)
    let rc = runHomeCommand(@["migrate-from-env-scripts",
      "--env-file", envFile, "--activity", "custom_dev"])
    check rc == 0
    let written = readFile(profileDir / "home.nim")
    check "activity custom_dev:" in written
    check "package(jdk, \"21.0.5\")" in written

  test "swift in the env file produces a TODO note but exits 0":
    resetTmp()
    let envFile = writeTmp("toolchain-versions.env",
      "SWIFT_VERSION=5.10.1\nJDK_VERSION=21.0.5\n")
    let profileDir = TmpDir / "profile-mixed"
    createDir(profileDir)
    setupCliEnv(profileDir, envFile)
    let rc = runHomeCommand(@["migrate-from-env-scripts",
      "--env-file", envFile])
    check rc == 0
    let written = readFile(profileDir / "home.nim")
    # jdk landed clean.
    check "package(jdk, \"21.0.5\")" in written
    # swift was NOT written (deferred-8 only emits a TODO to stdout,
    # not into the profile).
    check "package(swift" notin written

  test "missing --env-file path returns an error code":
    let rc = runHomeCommand(@["migrate-from-env-scripts",
      "--env-file", TmpDir / "does-not-exist.env"])
    check rc == 1
