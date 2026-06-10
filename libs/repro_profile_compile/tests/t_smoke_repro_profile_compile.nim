## M83 Phase C smoke tests for `libs/repro_profile_compile/`.
##
## Covers the pure, fast-to-test surface of the new library:
##
##   - Source-discovery (regex walk of `import ./...`).
##   - Source-digest determinism + sensitivity to one-byte changes.
##   - JSON->RBPI round-trip from a known `ProfileIntent`.
##   - Cache-layout helpers (paths nest under
##     `<state-dir>/profile-cache/`).
##   - `compileProfileToRbpi` returns the cached artifact on the
##     fast-path when a valid `.rbpi` is already present.
##   - `profileCompileBuildAction` shape: argv, inputs, outputs,
##     fingerprint binding.
##
## The unit-level coverage uses an in-process flow; the real
## library-API end-to-end test (driving `repro.exe` from a tempdir as
## the helper subprocess) lives at
## `tests/e2e/m83/t_e2e_repro_profile_compile_via_action.nim`.

import std/[os, strutils, tempfiles, unittest]
from repro_core/paths import extendedPath

import repro_build_engine
import repro_profile
import repro_profile_intent
import repro_profile_compile

# ---------------------------------------------------------------------------
# Test helpers.
# ---------------------------------------------------------------------------

proc writeProfileFile(dir, name, body: string): string =
  result = dir / name
  let parent = result.parentDir
  if not dirExists(extendedPath(parent)):
    createDir(extendedPath(parent))
  writeFile(extendedPath(result), body)

const RootProfileBody = """
import repro_profile
import ./sibling_helpers

profile "smokeBasic":
  activity default:
    neovim
    tmux
"""

const SiblingBody = """
import std/tables

import repro_profile

template extraResources*(targetResources: var seq[ResourceIntent]) =
  envUserVariable(targetResources, name = "FOO", value = "bar")
"""

# ---------------------------------------------------------------------------
# Source-discovery + digest.
# ---------------------------------------------------------------------------

suite "M83 Phase C: source-discovery + digest":

  test "parseSiblingImports finds `import ./sibling` lines":
    let body = "import std/os\n" &
      "import repro_profile\n" &
      "import ./sibling_helpers\n" &
      "import \"./other_helper\"\n" &
      "  import ./deep/nested/util  \n"
    let imports = parseSiblingImports(body)
    check imports.len == 3
    check "./sibling_helpers" in imports
    check "./other_helper" in imports
    check "./deep/nested/util" in imports

  test "parseSiblingImports ignores non-relative imports":
    let body = "import std/os\n" &
      "import repro_profile\n" &
      "import repro_profile/types\n" &
      "import some_other_pkg\n"
    let imports = parseSiblingImports(body)
    check imports.len == 0

  test "discoverProfileSources walks transitive ./ imports":
    let dir = createTempDir("repro-profile-discover-", "")
    defer: removeDir(dir)
    discard writeProfileFile(dir, "home.nim", RootProfileBody)
    discard writeProfileFile(dir, "sibling_helpers.nim", SiblingBody)
    let sources = discoverProfileSources(dir / "home.nim")
    check sources.len == 2
    var rels: seq[string]
    for s in sources:
      rels.add s.relativePath(dir).replace('\\', '/')
    check "home.nim" in rels
    check "sibling_helpers.nim" in rels

  test "computeProfileDigest is deterministic for the same inputs":
    let dir = createTempDir("repro-profile-digest-", "")
    defer: removeDir(dir)
    discard writeProfileFile(dir, "home.nim", RootProfileBody)
    discard writeProfileFile(dir, "sibling_helpers.nim", SiblingBody)
    let sources = discoverProfileSources(dir / "home.nim")
    let d1 = computeProfileDigest(sources, dir)
    let d2 = computeProfileDigest(sources, dir)
    check d1.digestHex == d2.digestHex
    check d1.manifest == d2.manifest
    check d1.digestHex.len == 64  # 32-byte BLAKE3 hex.

  test "computeProfileDigest changes when one byte changes":
    let dir = createTempDir("repro-profile-digest-change-", "")
    defer: removeDir(dir)
    discard writeProfileFile(dir, "home.nim", RootProfileBody)
    discard writeProfileFile(dir, "sibling_helpers.nim", SiblingBody)
    let sources = discoverProfileSources(dir / "home.nim")
    let before = computeProfileDigest(sources, dir)
    let mutatedSibling = SiblingBody.replace("FOO", "FoO")
    writeFile(extendedPath(dir / "sibling_helpers.nim"), mutatedSibling)
    let after = computeProfileDigest(sources, dir)
    check before.digestHex != after.digestHex

  test "computeProfileDigest manifest tracks paths + per-file digests":
    let dir = createTempDir("repro-profile-digest-manifest-", "")
    defer: removeDir(dir)
    discard writeProfileFile(dir, "home.nim", RootProfileBody)
    discard writeProfileFile(dir, "sibling_helpers.nim", SiblingBody)
    let sources = discoverProfileSources(dir / "home.nim")
    let digest = computeProfileDigest(sources, dir)
    let lines = digest.manifest.strip().splitLines()
    # Schema-version prefix line + one line per discovered source file.
    check lines.len == 3
    var paths: seq[string]
    for line in lines:
      let parts = line.split('\t')
      check parts.len == 2
      paths.add parts[0]
      # Schema-version line carries the version literal; file lines
      # carry the 64-char BLAKE3 hex digest.
      if parts[0] == "schema-version":
        check parts[1].len > 0
      else:
        check parts[1].len == 64
    check "schema-version" in paths
    check "home.nim" in paths
    check "sibling_helpers.nim" in paths

  test "resolveProfileRoot prefers explicit path over directory probes":
    let dir = createTempDir("repro-profile-resolve-", "")
    defer: removeDir(dir)
    let explicit = writeProfileFile(dir, "custom.nim", RootProfileBody)
    let resolved = resolveProfileRoot(dir, explicit)
    check resolved.endsWith("custom.nim")
    check fileExists(extendedPath(resolved))

  test "resolveProfileRoot probes home.nim then system.nim":
    let dir = createTempDir("repro-profile-resolve-probe-", "")
    defer: removeDir(dir)
    # Empty directory: nothing to find.
    check resolveProfileRoot(dir).len == 0
    discard writeProfileFile(dir, "system.nim", RootProfileBody)
    check resolveProfileRoot(dir).endsWith("system.nim")
    discard writeProfileFile(dir, "home.nim", RootProfileBody)
    check resolveProfileRoot(dir).endsWith("home.nim")

# ---------------------------------------------------------------------------
# RBPI bytes-from-JSON round-trip (the JSON->RBPI bridge used by the
# helper subcommand).
# ---------------------------------------------------------------------------

suite "M83 Phase C: RBPI emission":

  test "rbpiBytesFromJson round-trips a known ProfileIntent":
    var p: ProfileIntent
    p.name = "smokeRoundTrip"
    p.activities.add ActivityIntent(name: "default", body: @[
      ActivityElement(kind: aekPackageRef, pkgName: "neovim")])
    let js = emitProfileIntentJson(p)
    let rbpi = rbpiBytesFromJson(js)
    let recovered = decodeRbpi(rbpi)
    check recovered.name == "smokeRoundTrip"
    check recovered.activities.len == 1
    check recovered.activities[0].body[0].pkgName == "neovim"

  test "rbpiBytesFromJson is deterministic":
    var p: ProfileIntent
    p.name = "det"
    p.activities.add ActivityIntent(name: "default", body: @[
      ActivityElement(kind: aekPackageRef, pkgName: "tmux")])
    let js = emitProfileIntentJson(p)
    let a = rbpiBytesFromJson(js)
    let b = rbpiBytesFromJson(js)
    check a == b

# ---------------------------------------------------------------------------
# Cache-layout helpers.
# ---------------------------------------------------------------------------

suite "M83 Phase C: cache layout":

  test "cache paths nest under <state-dir>/profile-cache":
    let stateDir = "/tmp/repro-fake-state".replace('/', DirSep)
    let digest = "abcdef1234"
    let rbpi = cachedRbpiPath(stateDir, digest)
    let sources = cachedSourcesPath(stateDir, digest)
    let nimcache = cachedNimcacheDir(stateDir, digest)
    check rbpi.endsWith(digest & ".rbpi")
    check sources.endsWith(digest & ".source.txt")
    check nimcache.endsWith(digest)
    check "profile-cache" in rbpi
    check "profile-cache" in sources
    check "profile-cache" in nimcache

# ---------------------------------------------------------------------------
# BuildAction shape.
# ---------------------------------------------------------------------------

suite "M83 Phase C: profileCompileBuildAction":

  test "argv includes the internal helper subcommand + flag pairs":
    let weak = weakFingerprintFromText("smoke.weak")
    let act = profileCompileBuildAction(
      profileRoot = "/profile/home.nim",
      rbpiPath = "/cache/abc.rbpi",
      manifestPath = "/cache/abc.source.txt",
      nimcacheDir = "/cache/nimcache/abc",
      publicCliPath = "/bin/repro",
      workDir = "/profile",
      repoRoot = "/repo",
      inputSources = @["/profile/home.nim", "/profile/modules/foo.nim"],
      weak = weak,
      verbose = false)
    check act.id == "__repro_profile_compile"
    check act.kind == bakProcess
    check act.cacheable
    check act.weakFingerprint == weak
    check act.argv[0] == "/bin/repro"
    check act.argv[1] == "__repro-compile-profile"
    check "--profile" in act.argv
    check "--rbpi" in act.argv
    check "--manifest" in act.argv
    check "--nimcache" in act.argv
    check "--repo-root" in act.argv
    check "/profile/home.nim" in act.argv
    check "/cache/abc.rbpi" in act.argv
    check act.outputs == @["/cache/abc.rbpi", "/cache/abc.source.txt"]
    check act.inputs.len == 2

  test "verbose=true adds --verbose argv element":
    let weak = weakFingerprintFromText("smoke.weak.v")
    let act = profileCompileBuildAction(
      profileRoot = "/p/home.nim",
      rbpiPath = "/c/a.rbpi",
      manifestPath = "/c/a.source.txt",
      nimcacheDir = "/c/nc",
      publicCliPath = "/bin/repro",
      workDir = "",
      repoRoot = "/repo",
      inputSources = @["/p/home.nim"],
      weak = weak,
      verbose = true)
    check "--verbose" in act.argv

# ---------------------------------------------------------------------------
# Library-API fast-path: pre-populating the cache with a hand-rolled
# `.rbpi` makes compileProfileToRbpi return without invoking the build
# engine. The slow (cache-miss) path exercises `runBuild` which needs
# the public `repro` binary; that lives in the e2e gate.
# ---------------------------------------------------------------------------

suite "M83 Phase C: compileProfileToRbpi cache fast-path":

  test "structural cache hit short-circuits without invoking nim":
    let stateDir = createTempDir("repro-profile-state-", "")
    defer: removeDir(stateDir)
    let profileSrcDir = createTempDir("repro-profile-src-", "")
    defer: removeDir(profileSrcDir)
    discard writeProfileFile(profileSrcDir, "home.nim", RootProfileBody)
    discard writeProfileFile(profileSrcDir, "sibling_helpers.nim",
      SiblingBody)
    let root = profileSrcDir / "home.nim"

    # Hand-roll an RBPI envelope and place it where the digest will look.
    let sources = discoverProfileSources(root)
    let digest = computeProfileDigest(sources, profileSrcDir)
    var p: ProfileIntent
    p.name = "smokeFastPath"
    let bytes = encodeRbpi(p)
    createDir(extendedPath(profileCacheDir(stateDir)))
    writeBytesAtomic(cachedRbpiPath(stateDir, digest.digestHex), bytes)

    let opts = ProfileCompileOptions(
      stateDir: stateDir,
      publicCliPath: "/nonexistent/repro",  # Not invoked on fast-path.
      repoRoot: reprobuildRepoRoot())
    let artifact = compileProfileToRbpi(root, opts)
    check artifact.digestHex == digest.digestHex
    check artifact.rbpiBytes == bytes
    let recovered = decodeRbpi(artifact.rbpiBytes)
    check recovered.name == "smokeFastPath"

  test "compileProfileToRbpi rejects missing profile root":
    let stateDir = createTempDir("repro-profile-state-missing-", "")
    defer: removeDir(stateDir)
    let opts = ProfileCompileOptions(
      stateDir: stateDir,
      publicCliPath: "/nonexistent/repro")
    expect ProfileCompileError:
      discard compileProfileToRbpi(stateDir / "does_not_exist.nim", opts)

  test "compileProfileToRbpi requires stateDir + publicCliPath":
    var opts = ProfileCompileOptions(publicCliPath: "/x/repro")
    expect ProfileCompileError:
      discard compileProfileToRbpi("/p/home.nim", opts)
    opts = ProfileCompileOptions(stateDir: "/state")
    expect ProfileCompileError:
      discard compileProfileToRbpi("/p/home.nim", opts)
