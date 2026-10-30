## DSL-port M9.K acceptance — fetch-action emission against the
## ``fetch:`` block registry.
##
## Pins the M9.K bridge from the M9.H ``registeredFetchSpec`` registry
## to the BuildActionDef the convention layer prepends to its emitted
## action list. The test:
##
##   1. Declares a ``fetch:`` block on a package so the M9.H runtime
##      populates ``dslPortFetchSpecs[<pkg>]`` at module init.
##   2. Reads the spec back via ``registeredFetchSpec``.
##   3. Hands the spec to ``emitFetchAction`` (the shared helper the
##      four c-cpp-* Tier 2b conventions consume) and verifies the
##      resulting BuildActionDef carries the URL + hash + dest path
##      in its argv.
##
## This is the dsl_port test gate for M9.K — the convention-side tests
## live alongside their convention test files
## (``libs/repro_standard_provider/tests/test_c_cpp_*_convention.nim``)
## and exercise the same emitFetchAction path through the full
## emitFragment shape.

import std/[os, strutils, unittest]

import repro_project_dsl
import repro_provider_runtime
import repro_standard_provider/conventions/fetch_action
import repro_project_dsl/shell_fetch

package fetchActionPkg:
  fetch:
    url: "https://example.com/fetchActionPkg-1.0.tar.gz"
    sha256: "abc" & repeat("0", 61)
    extractStrip: 1
    extractedRoot: "src"

package dataFileActionPkg:
  fetch:
    url: "https://example.com/roots.pem"
    sha256: "def" & repeat("0", 61)
    dataFile: true
    extractStrip: 0

proc inlineArgvOf(action: BuildActionDef): seq[string] =
  for arg in action.call.arguments:
    if arg.name == "argv":
      if arg.encodedValue.len == 0:
        return @[]
      return arg.encodedValue.split("\x1f")
  @[]

suite "DSL-port M9.K — fetch action emission from registry":

  test "registered tarball fetch spec lowers to a fetch action":
    let spec = registeredFetchSpec("fetchActionPkg")
    # Registry round-trip — exact bytes the M9.H emit test (sibling
    # ``t_dsl_fetch_tarball.nim``) already pins, but verified again
    # here so a regression in the M9.K consumer surface fails this
    # test independently of the M9.H gate.
    check spec.packageName == "fetchActionPkg"
    check spec.url == "https://example.com/fetchActionPkg-1.0.tar.gz"
    check spec.kind == dfkTarball
    check spec.hashAlg == dshaSha256
    check spec.hashHex.len == 64
    check spec.extractStrip == 1
    check spec.extractedRoot == "src"

    let scratch = getTempDir() / "t_dsl_fetch_action_emission_scratch"
    if dirExists(scratch):
      removeDir(scratch)
    createDir(scratch)
    defer:
      removeDir(scratch)
    let action = emitFetchAction(scratch, "fetchActionPkg", spec)

    # Action id is the per-package stable id — same shape the
    # conventions use as the configure-action dep.
    check action.id == fetchActionId("fetchActionPkg")
    check action.id == "ccpp-fetch-fetchActionPkg"
    # The action's output is the per-spec stamp file. A second invocation
    # with the same spec hits the engine's content-addressed cache and
    # short-circuits the network I/O.
    check action.outputs.len == 1
    let expectedStamp = scratch / ".repro" / "fetch" / (spec.hashHex & ".stamp")
    check action.outputs[0].replace('\\', '/') ==
      expectedStamp.replace('\\', '/')

    # The argv carries the URL + hash + extract dest verbatim so the
    # engine's content-addressing fingerprints uniquely identify the
    # fetch operation. The exact spelling depends on whether sh is on
    # PATH; both shapes embed the URL + hash + dest as substrings.
    let argv = inlineArgvOf(action)
    let argvJoined = argv.join(" ")
    check argvJoined.contains(spec.url)
    check argvJoined.contains(spec.hashHex)
    let extractedRel = "src"
    check argvJoined.contains(extractedRel)
    check argvJoined.contains(".repro-extract-" & spec.hashHex)
    check argvJoined.contains("mv ")
    check argvJoined.contains(CurlFetchRetryArgs)
    check argvJoined.contains("--retry-all-errors")
    check argvJoined.contains("--max-time 300")
    check argvJoined.contains("[ -s")
    check argvJoined.contains(".tar.part")
    check argvJoined.contains("mv -f")
    check argvJoined.contains("rm -f")
    check action.toolIdentityRefs ==
      @["sh", "rm", "mkdir", "curl", "mv", "sha256sum", "tar", "gzip"]
    when defined(windows):
      check argvJoined.count("tar --force-local -xf") == 2
      check argvJoined.contains("if ! tar --force-local -xf")
    else:
      check argvJoined.count("tar -xf") == 1
      check not argvJoined.contains("--force-local")

  test "registered data file lowers to a copy action":
    let spec = registeredFetchSpec("dataFileActionPkg")
    check spec.kind == dfkDataFile

    let scratch = getTempDir() / "t_dsl_fetch_data_action_emission_scratch"
    if dirExists(scratch):
      removeDir(scratch)
    createDir(scratch)
    defer:
      removeDir(scratch)

    let action = emitFetchAction(scratch, "dataFileActionPkg", spec)
    let argvJoined = inlineArgvOf(action).join(" ")
    check argvJoined.contains(spec.url)
    check argvJoined.contains(spec.hashHex)
    check argvJoined.contains("cp ")
    check argvJoined.contains("/source")
    check argvJoined.contains(CurlFetchRetryArgs)
    check argvJoined.contains(".tar.part")
    check not argvJoined.contains("tar -xf")
    check action.toolIdentityRefs ==
      @["sh", "rm", "mkdir", "curl", "mv", "sha256sum", "cp"]

  test "a git archive pinned to a commit id fetches the object, not a branch":
    # `gitRevision` was documented as "tag / commit", but the emitted script
    # only ever spelled `git clone --branch <rev>`, which no git accepts for
    # a commit id. A private repository has no archive URL, so a commit id
    # is the one spelling that pins its revision; the script must fetch
    # exactly that object.
    let scratch = getTempDir() / "t_dsl_fetch_git_commit_emission_scratch"
    if dirExists(scratch):
      removeDir(scratch)
    createDir(scratch)
    defer:
      removeDir(scratch)
    const commit = "23960db5e22b46357ffb93c71db141e3414bbd63"
    let byCommit = DslFetchSpec(
      packageName: "gitCommitPkg", kind: dfkGitArchive,
      url: "https://github.com/example/private",
      gitRevision: commit, hashAlg: dshaSha256,
      hashHex: "f36aacc95d23cd8cd8205ed200901aec82e730c1a552d74d1b6d8961f1a5fdb1",
      extractStrip: 0)
    let script = inlineArgvOf(emitFetchAction(scratch, "gitCommitPkg",
      byCommit)).join(" ")
    check script.contains("git init -q")
    check script.contains("fetch -q --depth 1 origin \"" & commit & "\"")
    check script.contains("checkout -q FETCH_HEAD")
    check script.contains("git archive --format=tar HEAD")
    check not script.contains("--branch")
    # A tag keeps the clone form: the two spellings are distinguished by
    # shape (40 hex digits), so a tag that happens to be 40 characters of
    # other text still clones.
    var byTag = byCommit
    byTag.gitRevision = "v1.2.3"
    let tagScript = inlineArgvOf(emitFetchAction(scratch, "gitCommitPkg",
      byTag)).join(" ")
    check tagScript.contains("git clone --depth 1 --branch \"v1.2.3\"")
    check not tagScript.contains("FETCH_HEAD")
    check isCommitId(commit)
    check not isCommitId("v1.2.3")
    check not isCommitId("23960db5e22b46357ffb93c71db141e3414bbd6g")
