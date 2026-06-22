## M2 — env.ps1 pin reconciliation gate.
##
## Drives ``planMigration`` against the *real*
## ``windows/toolchain-versions.env`` (located at
## ``$METACRAFT_ROOT/windows/toolchain-versions.env`` if set, or the
## canonical ``D:/metacraft/windows/toolchain-versions.env`` fallback
## the M70 CLI uses on Windows hosts) and asserts the post-M2 outcome
## distribution per the M2 spec table:
##
##   - 10 env-file lines total
##   - 3 moIgnored from the M70 ``IgnoredEnvVars`` list
##     (JDK_BUILD, VULKAN_HEADERS_VERSION, MESA_VERSION)
##   - 7 catalog-eligible
##     - 6 moMigrate (jdk, maven, gradle, zig, go, fpc)
##     - 1 moDeferred (swift — the M70 deferred-8 contract;
##       a TODO comment IS the clean outcome for these tools until
##       M3-M5 closes the realize-time gap)
##   - 0 moMissingVersion (the M2 scope-exit gate — every
##     catalog-eligible pin either matches catalog HEAD or is one of
##     the post-M2 backfilled slices in packages/<tool>.nim)
##   - 0 moUnknown
##
## Honest scope: this test deliberately walks the real env.ps1, NOT
## a synthetic fixture. The M70 unit tests
## (``test_m70_migrate_from_env_scripts.nim``) cover the synthetic-
## fixture behaviour of every classifier separately; M2's gate is
## that the *actual* operator-facing file reconciles cleanly. The
## test is hermetic in the sense that it never touches the user's
## ``home.nim`` (it builds an empty ``ownedTools`` set + only
## inspects the in-memory plan).
##
## The test ALSO asserts the M70 ``IgnoredEnvVars`` constant matches
## the agreed M2 non-catalog set byte-for-byte — guards against an
## accidental future widening that would silently drop a catalog-
## eligible pin into the ignored bucket.

import std/[os, sets, strutils, tables, unittest]

import repro_cli_support/migrate_from_env_scripts

# ---------------------------------------------------------------------------
# Locate the real env.ps1 the same way the CLI does (so this test fails
# loudly if the file moves rather than silently testing nothing).
# ---------------------------------------------------------------------------

proc resolveRealEnvFilePath(): string =
  ## Precedence: explicit $METACRAFT_ROOT (set by env.ps1 on Windows
  ## hosts) → Windows fallback path → walk up from this test source
  ## to discover the workspace root. The walk-up branch covers
  ## Linux/macOS dev shells, where no env script auto-exports
  ## METACRAFT_ROOT — the test repo lives at <workspace>/reprobuild,
  ## so we ascend until we hit a directory carrying the canonical
  ## windows/toolchain-versions.env file.
  let root = getEnv("METACRAFT_ROOT")
  if root.len > 0:
    return root / "windows" / "toolchain-versions.env"
  when defined(windows):
    return "D:/metacraft/windows/toolchain-versions.env"
  else:
    var dir = currentSourcePath().parentDir
    while dir.len > 0 and dir != "/":
      let candidate = dir / "windows" / "toolchain-versions.env"
      if fileExists(candidate):
        return candidate
      let parent = dir.parentDir
      if parent == dir:
        break
      dir = parent
    return ""

const ExpectedIgnoredSet = [
  "JDK_BUILD",
  "GIT_REPO_VERSION",
  "VULKAN_HEADERS_VERSION",
  "MESA_VERSION",
  "MSYS2_AUTOTOOLS_VERSION",  # future system-profile track per M70
]

# Catalog-eligible, non-deferred tools the current
# ``windows/toolchain-versions.env`` pins. ``just`` / ``gh`` / ``python``
# were delegated to the framework (dropped from the env file); ``go``
# was added with a versioned catalog entry (packages/go.nim), so it
# migrates cleanly. ``fpc`` (Free Pascal Compiler) was added to
# provision the pascal survey fixture and carries a catalog entry
# (packages/fpc.nim), so it migrates cleanly too.
const ExpectedCleanMigrateTools = [
  "jdk", "maven", "gradle", "zig", "go", "fpc",
]

# M70 deferred tools that still appear in the env file. ``python3`` left
# the env file with the framework-delegation change, so ``swift`` is the
# only deferred pin the file now carries.
const ExpectedDeferredTools = [
  "swift",
]

# ---------------------------------------------------------------------------

suite "M2 — IgnoredEnvVars matches the agreed non-catalog set":

  test "IgnoredEnvVars matches the M2 spec table byte-for-byte":
    # Constant-array semantics: order-insensitive set comparison so a
    # future re-ordering in migrate_from_env_scripts.nim doesn't break
    # this assertion. The membership check is the load-bearing part —
    # a silent widening that swept a catalog tool into the ignored
    # bucket would mis-report the M2 closure gate.
    var actual = initHashSet[string]()
    for v in IgnoredEnvVars: actual.incl(v)
    var expected = initHashSet[string]()
    for v in ExpectedIgnoredSet: expected.incl(v)
    check actual == expected

# ---------------------------------------------------------------------------

suite "M2 — real toolchain-versions.env reconciles per the decision table":

  setup:
    let envFilePath = resolveRealEnvFilePath()
    check envFilePath.len > 0
    check fileExists(envFilePath)

  test "real env file parses to the expected 10 pins":
    let parsed = loadEnvFile(envFilePath)
    # Pin count tracks the current ``windows/toolchain-versions.env``:
    # 10 lines after just/gh/python/git_repo were delegated to the
    # framework and go/vulkan/mesa/fpc were added.
    check parsed.pins.len == 10

  test "post-M2 migrator reports the expected outcome distribution":
    let parsed = loadEnvFile(envFilePath)
    let plan = planMigration(parsed, "migrated_from_env_scripts",
      initHashSet[string]())
    let s = summarize(plan)
    check s.ignored == 3
    check s.migrated == 6
    check s.deferred == 1
    check s.missingVersion == 0
    check s.unknown == 0
    check s.alreadyOwned == 0

  test "every catalog-eligible non-deferred pin classifies as moMigrate":
    let parsed = loadEnvFile(envFilePath)
    let plan = planMigration(parsed, "migrated_from_env_scripts",
      initHashSet[string]())
    var migratedTools = initHashSet[string]()
    for line in plan.lines:
      if line.kind == moMigrate:
        migratedTools.incl(line.tool)
    var expected = initHashSet[string]()
    for t in ExpectedCleanMigrateTools: expected.incl(t)
    check migratedTools == expected

  test "every M70 deferred-8 pin classifies as moDeferred (TODO is intended)":
    let parsed = loadEnvFile(envFilePath)
    let plan = planMigration(parsed, "migrated_from_env_scripts",
      initHashSet[string]())
    var deferredTools = initHashSet[string]()
    for line in plan.lines:
      if line.kind == moDeferred:
        deferredTools.incl(line.tool)
    var expected = initHashSet[string]()
    for t in ExpectedDeferredTools: expected.incl(t)
    check deferredTools == expected

  test "no pin classifies as moMissingVersion (the M2 scope-exit gate)":
    # The load-bearing M2 assertion. Pre-M2 the gradle/zig/maven/just/gh
    # pins were moMissingVersion (catalog HEAD ≠ env.ps1 pin); post-M2
    # the bump-env + backfill decisions land every pin on either the
    # catalog HEAD (matching the env file) or one of the catalog's
    # backfilled slices.
    let parsed = loadEnvFile(envFilePath)
    let plan = planMigration(parsed, "migrated_from_env_scripts",
      initHashSet[string]())
    for line in plan.lines:
      check line.kind != moMissingVersion

  test "no pin classifies as moUnknown (the M70 mapping table is complete)":
    let parsed = loadEnvFile(envFilePath)
    let plan = planMigration(parsed, "migrated_from_env_scripts",
      initHashSet[string]())
    for line in plan.lines:
      check line.kind != moUnknown

  test "every migrated package(...) line renders with the env.ps1 version":
    # Cross-checks the rendered text against the parsed env-file pin
    # so a future regression that picked a non-pinned catalog slice
    # (e.g. defaulting to HEAD when the pin is a backfilled older
    # slice) would fail here.
    let parsed = loadEnvFile(envFilePath)
    var envVersionFor = initTable[string, string]()
    for pin in parsed.pins:
      envVersionFor[pin.envVar] = pin.version
    let plan = planMigration(parsed, "migrated_from_env_scripts",
      initHashSet[string]())
    for line in plan.lines:
      if line.kind == moMigrate:
        let envVersion = envVersionFor[line.envVar]
        check line.version == envVersion
        check ("\"" & envVersion & "\"") in line.text
