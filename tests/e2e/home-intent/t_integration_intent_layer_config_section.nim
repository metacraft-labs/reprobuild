## M60 gate: `integration_intent_layer_config_section`.
##
## Normative description (from `Reprobuild-Development.milestones.org`):
##
##   `repro home set git.userName "Zahary"` creates `config:` if absent,
##   `git:` if absent, and writes the line; subsequent `repro home set
##   git.userEmail "..."` appends within the same `git:` sub-block.
##   Overrides for packages not enabled by any active activity have no
##   effect on resolved state; a configurable name not declared by the
##   package produces a clear diagnostic.
##
## The gate drives `setConfigurable` (the library function the M61 CLI
## will land on top of) and `resolveEffectiveConfig` (the seam for the
## M63 apply pipeline). The package-schema lookup is injected as a
## simple proc — the actual Configurable-system integration is wired
## in by the apply pipeline; M60 just provides the seam.

import std/[os, sets, strutils, tables, unittest]

import repro_home_intent

const FixtureRoot = currentSourcePath().parentDir().parentDir().parentDir() /
  "fixtures" / "home-intent"

proc tmpDir(name: string): string =
  result = getTempDir() / "repro-home-intent-cfg" / name
  if dirExists(result):
    removeDir(result)
  createDir(result)

proc copyFixture(name, intoDir: string): string =
  result = intoDir / "home.nim"
  let src = FixtureRoot / name
  doAssert fileExists(src), "missing fixture: " & src
  copyFile(src, result)

# Fixture configurable schema: hard-coded knowledge of which
# configurables each package declares. The real apply pipeline will
# consult the package registry; the gate only needs the lookup
# contract.
proc fixtureLookup(pkg, key: string): bool {.gcsafe.} =
  case pkg
  of "git":
    key in ["userName", "userEmail", "defaultBranch"]
  of "neovim":
    key in ["installLanguageServers", "defaultColorScheme"]
  of "darktable":
    key in ["thumbnailCacheSize"]
  of "nginx":
    key in ["installSystemdService", "defaultPort"]
  else:
    false

suite "M60 config-section gate":

  test "set git.userName creates config:, git:, and writes the line":
    let dir = tmpDir("cfg-create")
    let path = copyFixture("config_seed.nim", dir)
    # Sanity: fixture has no `config:` block.
    let before = readFile(path)
    check "config:" notin before
    setConfigurable(path, "git.userName", "Zahary", fixtureLookup)
    let after = readFile(path)
    check "  config:" in after
    check "    git:" in after
    check "      userName = \"Zahary\"" in after
    # The git: sub-block sits inside config: at the right indent.
    let cfgIdx = after.find("  config:")
    let gitIdx = after.find("    git:", cfgIdx)
    let nameIdx = after.find("      userName = \"Zahary\"", gitIdx)
    check cfgIdx >= 0
    check gitIdx > cfgIdx
    check nameIdx > gitIdx

  test "subsequent set git.userEmail appends inside the same git: sub-block":
    let dir = tmpDir("cfg-append")
    let path = copyFixture("config_seed.nim", dir)
    setConfigurable(path, "git.userName", "Zahary", fixtureLookup)
    setConfigurable(path, "git.userEmail", "zahary@example.com",
                    fixtureLookup)
    let after = readFile(path)
    let gitIdx = after.find("    git:")
    let nameIdx = after.find("      userName = \"Zahary\"", gitIdx)
    let emailIdx = after.find(
      "      userEmail = \"zahary@example.com\"", gitIdx)
    check gitIdx >= 0
    check nameIdx > gitIdx
    check emailIdx > nameIdx
    # Insertion order is preserved: only one `git:` sub-block exists.
    check after.count("    git:") == 1
    # The two entries are consecutive — there's no other content
    # between them.
    let between = after[nameIdx + len("      userName = \"Zahary\"") ..< emailIdx]
    for c in between:
      check c in {' ', '\t', '\r', '\n'}

  test "set against the same configurable updates in place":
    let dir = tmpDir("cfg-update")
    let path = copyFixture("config_seed.nim", dir)
    setConfigurable(path, "git.userName", "First", fixtureLookup)
    setConfigurable(path, "git.userName", "Second", fixtureLookup)
    let after = readFile(path)
    check "      userName = \"Second\"" in after
    check after.count("userName") == 1

  test "override for inactive package is silently inert in effective config":
    # On `personal-laptop` (not listed under `hosts:`), only `default`
    # is enabled. `default` contains `git`; `photography` is NOT
    # active, so the `darktable` override is inert.
    let dir = tmpDir("cfg-inert")
    let path = copyFixture("config_seed.nim", dir)
    setConfigurable(path, "darktable.thumbnailCacheSize", "1024",
                    fixtureLookup)
    setConfigurable(path, "git.userName", "Z", fixtureLookup)
    let prof = loadProfile(path)
    let ctx = HostContext(platform: "linux", arch: "x86_64",
      host: "personal-laptop")
    let resolved = resolveEffectiveConfig(prof, "personal-laptop", ctx)
    check "git" in resolved.enabledPackages
    check "darktable" notin resolved.enabledPackages
    # `git` override is live.
    check "git" in resolved.overrides
    check resolved.overrides["git"]["userName"] == "\"Z\""
    # `darktable` override is bucketed as inert and NOT merged into
    # the live overrides.
    check "darktable" notin resolved.overrides
    check "darktable" in resolved.inertOverrides
    check resolved.inertOverrides["darktable"]["thumbnailCacheSize"] ==
      "1024"

  test "override for active package on the matching host is live":
    let dir = tmpDir("cfg-active-host")
    let path = copyFixture("config_seed.nim", dir)
    setConfigurable(path, "darktable.thumbnailCacheSize", "2048",
                    fixtureLookup)
    let prof = loadProfile(path)
    let ctx = HostContext(platform: "linux", arch: "x86_64",
      host: "dev-laptop")
    let resolved = resolveEffectiveConfig(prof, "dev-laptop", ctx)
    check "git" in resolved.enabledPackages         # via default
    check "darktable" in resolved.enabledPackages   # via photography
    check "darktable" in resolved.overrides
    check resolved.overrides["darktable"]["thumbnailCacheSize"] == "2048"
    check resolved.inertOverrides.len == 0

  test "unknown configurable raises EUnknownConfigurable":
    let dir = tmpDir("cfg-unknown")
    let path = copyFixture("config_seed.nim", dir)
    var raised = false
    var raisedPkg = ""
    var raisedKey = ""
    try:
      setConfigurable(path, "git.notADeclaredKey", "x", fixtureLookup)
    except EUnknownConfigurable as e:
      raised = true
      raisedPkg = e.package
      raisedKey = e.configurable
    check raised
    check raisedPkg == "git"
    check raisedKey == "notADeclaredKey"
    # The profile must be untouched after the rejected edit.
    let after = readFile(path)
    check "notADeclaredKey" notin after

  test "invalid `pkg.key` form raises EInvalidConfigurable":
    let dir = tmpDir("cfg-invalid-form")
    let path = copyFixture("config_seed.nim", dir)
    var raised = false
    try:
      setConfigurable(path, "noDotHere", "x", fixtureLookup)
    except EInvalidConfigurable:
      raised = true
    check raised
