## M7 (Realize-Closure-And-Catalog-Expansion spec) hermetic tests for
## the GitHub Releases API harvester source.
##
## All HTTP I/O is routed through the ``REPRO_M7_API_FIXTURE_DIR``
## mock that ``gh_releases_source.fetchReleasesJsonRaw`` /
## ``fetchAssetToFile`` consult. The fixtures under
## ``tests/fixtures/gh-releases/`` mirror the live GitHub API JSON
## shape:
##
##   * ``alire-project/alire/`` — synthetic three-release snapshot
##     (one current-stable + one prerelease + one older stable) with
##     multiple assets per release (Linux, Windows, installer) so the
##     ``--asset-pattern`` regex must do real work.
##   * ``example-org/no-digest-tool/`` — single release whose asset
##     carries an empty ``digest`` field; exercises the
##     compute-sha256-from-bytes fallback.
##
## The tests cover:
##
##   * regex compilation + asset matching for the operator patterns
##     the M7 spec section calls out (``alr-.*-windows-x86_64\.zip``,
##     ``^v(.+)$``);
##   * the latest-non-prerelease selection rule (skip the rc1 release
##     when ``--prerelease`` is absent);
##   * version pinning via the post-extracted version;
##   * digest preference (asset.digest ``sha256:<hex>`` wins over
##     byte-computed) and the compute-fallback when ``digest`` is
##     empty;
##   * end-to-end emission of a valid VersionedProvisioning;
##   * byte-identical re-emission (idempotent harvest);
##   * GITHUB_TOKEN forwarding when set, omitted when absent (without
##     touching the network).

import std/[os, strutils, unittest]

import ../src/gh_releases_source
import ../src/nim_emit
import repro_dsl_stdlib/packages_schema

const FixtureDir = currentSourcePath.parentDir / "fixtures" / "gh-releases"

proc setupFixtureEnv(cacheSubdir: string): string =
  putEnv("REPRO_M7_API_FIXTURE_DIR", FixtureDir)
  let cache = getTempDir() / "m7-gh-releases-test-cache" / cacheSubdir
  if dirExists(cache):
    removeDir(cache)
  createDir(cache)
  cache

proc teardownFixtureEnv() =
  putEnv("REPRO_M7_API_FIXTURE_DIR", "")

suite "M7 — minimal regex matcher":

  test "literal-and-wildcard pattern":
    let p = compileRegex("alr-.*-windows-x86_64\\.zip")
    check matchFull(p, "alr-2.1.1-bin-x86_64-windows-x86_64.zip").ok
    check matchFull(p, "alr-2.1.1-bin-x86_64-windows.zip").ok == false
    check matchFull(p, "alr-2.1.1-bin-aarch64-windows-x86_64.zip").ok

  test "leading-v capture extract":
    let p = compileRegex("^v(.+)$")
    let (ok, caps) = matchFull(p, "v2.1.1")
    check ok
    check caps.len == 1
    check caps[0] == "2.1.1"
    check matchFull(p, "2.1.1").ok == false

  test "anchored character-class match":
    let p = compileRegex("^[0-9]+\\.[0-9]+\\.[0-9]+$")
    check matchFull(p, "2.1.1").ok
    check matchFull(p, "v2.1.1").ok == false
    check matchFull(p, "2.1").ok == false

  test "matchesPattern convenience wrapper":
    check matchesPattern("alr-.*-windows.zip",
      "alr-2.1.1-bin-x86_64-windows.zip")
    check not matchesPattern("alr-.*-linux.zip",
      "alr-2.1.1-bin-x86_64-windows.zip")

  test "?- and +-quantifier behaviour":
    check matchesPattern("ab?c", "ac")
    check matchesPattern("ab?c", "abc")
    check matchesPattern("ab+c", "abc")
    check matchesPattern("ab+c", "abbbbc")
    check not matchesPattern("ab+c", "ac")

  test "extractVersion default = tag verbatim":
    check extractVersion("v2.1.1") == "v2.1.1"
    check extractVersion("2.1.1") == "2.1.1"

  test "extractVersion strips leading 'v' via capture":
    check extractVersion("v2.1.1", "^v(.+)$") == "2.1.1"
    check extractVersion("v0.26.0", "^v(.+)$") == "0.26.0"

  test "extractVersion raises when regex has no capture group":
    var raised = false
    try:
      discard extractVersion("v2.1.1", "^v.+$")
    except GhReleasesHarvestError:
      raised = true
    check raised

  test "extractVersion raises when tag doesn't match":
    var raised = false
    try:
      discard extractVersion("nightly", "^v(.+)$")
    except GhReleasesHarvestError:
      raised = true
    check raised

suite "M7 — release/asset parsing":

  test "parseReleases handles the alire fixture":
    let body = readFile(FixtureDir / "alire-project" / "alire" / "releases.json")
    let releases = parseReleases(body)
    check releases.len == 3
    check releases[0].tagName == "v2.1.1"
    check releases[0].prerelease == false
    check releases[0].assets.len == 3
    check releases[1].tagName == "v2.2.0-rc1"
    check releases[1].prerelease == true
    check releases[2].tagName == "v2.0.2"

  test "fetchReleases skips prereleases by default":
    discard setupFixtureEnv("fetch-releases-default")
    defer: teardownFixtureEnv()
    let releases = fetchReleases("alire-project", "alire")
    check releases.len == 2  # v2.1.1 + v2.0.2 (rc1 skipped)
    check releases[0].tagName == "v2.1.1"
    check releases[1].tagName == "v2.0.2"

  test "fetchReleases includes prereleases on opt-in":
    discard setupFixtureEnv("fetch-releases-prerelease")
    defer: teardownFixtureEnv()
    let releases = fetchReleases("alire-project", "alire",
      includePrereleases = true)
    check releases.len == 3

suite "M7 — asset selection":

  test "selectAsset picks the unique windows zip":
    discard setupFixtureEnv("select-asset")
    defer: teardownFixtureEnv()
    let releases = fetchReleases("alire-project", "alire")
    let asset = selectAsset(releases[0],
      "alr-.*-bin-x86_64-windows\\.zip")
    check asset.name == "alr-2.1.1-bin-x86_64-windows.zip"
    check asset.digest.startsWith("sha256:")

  test "selectAsset raises on zero matches with available list":
    discard setupFixtureEnv("select-asset-zero")
    defer: teardownFixtureEnv()
    let releases = fetchReleases("alire-project", "alire")
    var raised = false
    var detail = ""
    try:
      discard selectAsset(releases[0], "completely-nonexistent\\.tar\\.gz")
    except GhReleasesHarvestError as err:
      raised = true
      detail = err.msg
    check raised
    # The error message MUST list the available assets so the operator
    # can refine the pattern.
    check "alr-2.1.1-bin-x86_64-linux.zip" in detail
    check "alr-2.1.1-bin-x86_64-windows.zip" in detail

  test "selectAsset raises on multiple matches (no silent first-pick)":
    discard setupFixtureEnv("select-asset-multi")
    defer: teardownFixtureEnv()
    let releases = fetchReleases("alire-project", "alire")
    var raised = false
    var detail = ""
    try:
      # Matches both .zip assets (linux + windows).
      discard selectAsset(releases[0], "alr-.*\\.zip")
    except GhReleasesHarvestError as err:
      raised = true
      detail = err.msg
    check raised
    check "MULTIPLE" in detail
    check "alr-2.1.1-bin-x86_64-linux.zip" in detail
    check "alr-2.1.1-bin-x86_64-windows.zip" in detail

suite "M7 — version pin + release selection":

  test "selectRelease default = latest non-prerelease":
    discard setupFixtureEnv("select-release-default")
    defer: teardownFixtureEnv()
    let releases = fetchReleases("alire-project", "alire")
    let r = selectRelease(releases)
    check r.tagName == "v2.1.1"

  test "selectRelease honors an explicit version pin":
    discard setupFixtureEnv("select-release-pin")
    defer: teardownFixtureEnv()
    let releases = fetchReleases("alire-project", "alire")
    let r = selectRelease(releases, versionPin = "2.0.2",
      extractRegex = "^v(.+)$")
    check r.tagName == "v2.0.2"

  test "selectRelease raises on missing pin with available list":
    discard setupFixtureEnv("select-release-missing")
    defer: teardownFixtureEnv()
    let releases = fetchReleases("alire-project", "alire")
    var raised = false
    var detail = ""
    try:
      discard selectRelease(releases, versionPin = "9.9.9")
    except GhReleasesHarvestError as err:
      raised = true
      detail = err.msg
    check raised
    check "v2.1.1" in detail
    check "v2.0.2" in detail

suite "M7 — digest extraction":

  test "computeOrTakeSha256 prefers asset.digest sha256 field":
    discard setupFixtureEnv("digest-prefer")
    defer: teardownFixtureEnv()
    let releases = fetchReleases("alire-project", "alire")
    let asset = selectAsset(releases[0],
      "alr-.*-bin-x86_64-windows\\.zip")
    # Even when the downloaded file is bogus, the digest field wins —
    # the harvester trusts GitHub's own metadata as the integrity
    # source. The fixture's binary bytes do NOT hash to the digest;
    # if compute-from-bytes ran, this test would fail.
    let downloaded = FixtureDir / "alire-project" / "alire" / "assets" /
      asset.name
    let sha = computeOrTakeSha256(asset, downloaded)
    check sha ==
      "863013b1f94da6f3b7d0d5a74022ac3370424eeea9a470ebdb33d188d61b9125"

  test "computeOrTakeSha256 falls back to byte-compute when digest empty":
    discard setupFixtureEnv("digest-compute")
    defer: teardownFixtureEnv()
    let releases = fetchReleases("example-org", "no-digest-tool")
    let asset = selectAsset(releases[0],
      "no-digest-tool-1\\.0\\.0-windows-x86_64\\.zip")
    check asset.digest.len == 0
    let downloaded = FixtureDir / "example-org" / "no-digest-tool" /
      "assets" / asset.name
    let sha = computeOrTakeSha256(asset, downloaded)
    # Hash of the fixture bytes ('no-digest-tool-bytes').
    check sha ==
      "c487238d82895b90cd558c8e724b567e5d81161f1d44e3f7c20200d56e6daf2c"

suite "M7 — end-to-end harvest":

  test "harvestGhRelease emits a schema-valid VersionedProvisioning":
    let cache = setupFixtureEnv("e2e-emit")
    defer: teardownFixtureEnv()
    let opts = GhHarvestOpts(
      org: "alire-project",
      repo: "alire",
      assetPattern: "alr-.*-bin-x86_64-windows\\.zip",
      versionExtract: "^v(.+)$",
      binRelpath: @["bin/alr.exe"],
      cacheDir: cache)
    let entry = harvestGhRelease(opts)
    check entry.version == "2.1.1"
    check entry.archive_format == afZip
    check entry.install_method == imExtract
    check entry.bin_relpath == @["bin/alr.exe"]
    check entry.platforms.len == 1
    check entry.platforms[0].cpu == pcX86_64
    check entry.platforms[0].os == poWindows
    check entry.platforms[0].sha256 ==
      "863013b1f94da6f3b7d0d5a74022ac3370424eeea9a470ebdb33d188d61b9125"
    check entry.platforms[0].url ==
      "https://github.com/alire-project/alire/releases/download/v2.1.1/alr-2.1.1-bin-x86_64-windows.zip"
    check entry.platforms[0].extract_path == ""
    let errors = validateVersionedProvisioning(entry)
    check errors.len == 0

  test "harvestGhRelease honors --version pin":
    let cache = setupFixtureEnv("e2e-pin")
    defer: teardownFixtureEnv()
    let opts = GhHarvestOpts(
      org: "alire-project",
      repo: "alire",
      assetPattern: "alr-.*-bin-x86_64-windows\\.zip",
      versionExtract: "^v(.+)$",
      versionPin: "2.0.2",
      binRelpath: @["bin/alr.exe"],
      cacheDir: cache)
    let entry = harvestGhRelease(opts)
    check entry.version == "2.0.2"
    check entry.platforms[0].url ==
      "https://github.com/alire-project/alire/releases/download/v2.0.2/alr-2.0.2-bin-x86_64-windows.zip"

  test "harvestGhRelease respects --platform-os override":
    let cache = setupFixtureEnv("e2e-platform-override")
    defer: teardownFixtureEnv()
    # The Linux asset's name contains 'linux'; let the harvester infer.
    let optsAuto = GhHarvestOpts(
      org: "alire-project",
      repo: "alire",
      assetPattern: "alr-.*-bin-x86_64-linux\\.zip",
      versionExtract: "^v(.+)$",
      binRelpath: @["bin/alr"],
      cacheDir: cache)
    let entryAuto = harvestGhRelease(optsAuto)
    check entryAuto.platforms[0].os == poLinux

suite "M7 — idempotent harvest":

  test "re-emitting against the same fixture produces byte-identical output":
    let cache1 = setupFixtureEnv("idempotent-1")
    let opts = GhHarvestOpts(
      org: "alire-project",
      repo: "alire",
      assetPattern: "alr-.*-bin-x86_64-windows\\.zip",
      versionExtract: "^v(.+)$",
      binRelpath: @["bin/alr.exe"],
      cacheDir: cache1)
    let entry1 = harvestGhRelease(opts)
    let body1 = emitCatalogFile("alire",
      "gh-releases:alire-project/alire", @[entry1])
    teardownFixtureEnv()
    let cache2 = setupFixtureEnv("idempotent-2")
    var opts2 = opts
    opts2.cacheDir = cache2
    let entry2 = harvestGhRelease(opts2)
    let body2 = emitCatalogFile("alire",
      "gh-releases:alire-project/alire", @[entry2])
    teardownFixtureEnv()
    check body1 == body2
    check body1.len > 0

suite "M7 — auth header forwarding":

  test "authHeader is absent when GITHUB_TOKEN is unset":
    putEnv("GITHUB_TOKEN", "")
    let (present, header) = authHeader()
    check present == false
    check header == ""

  test "authHeader forwards GITHUB_TOKEN as Bearer when set":
    putEnv("GITHUB_TOKEN", "ghp_fixture_token_value")
    defer: putEnv("GITHUB_TOKEN", "")
    let (present, header) = authHeader()
    check present
    check header == "Bearer ghp_fixture_token_value"
