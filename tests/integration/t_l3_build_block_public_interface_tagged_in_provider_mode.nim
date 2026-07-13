## L3 PUBLISH-SCOPE — PROVIDER-MODE tagging of hand-authored ``build:``
## block public-interface artifacts.
##
## The review REJECTED the first L3 cut because the public-interface
## tagging never fired in the REAL build path: a real ``repro build``
## compiles the recipe as a PROVIDER (``--define:reproProviderMode``),
## where the per-artifact ``build:`` body-splice is gated off and the
## flattened ``buildXxxPackage`` executor runs under only the M5 package
## frame — so the M4 per-artifact frame ``maybeTagPublicInterface`` keys
## off was never on the stack, and the tag only fired in unit tests
## (neither define). This test closes that gap: it compiles a fixture
## recipe WITH ``--define:reproProviderMode`` and drives the real
## provider fragment-build path, then asserts:
##
##   1. A DECLARED ``executable`` member built by a hand-authored
##      ``nim.c`` edge IS tagged (``publishToBinaryCache`` +
##      ``cacheEntryIdentity``) in provider mode.
##   2. The tag's identity matches the Nim-CONVENTION composition
##      byte-for-byte (member name as packageName, toolchain ``"nim"``,
##      providerRevision = BLAKE3 of the recipe file) — so a build-block
##      publish and a Nim-convention publish of the same member land
##      under one cache key.
##   3. A declared member with ``publish = some(false)`` stays UNTAGGED
##      (explicit opt-out honoured on the provider path).
##   4. A package-level ``build:`` edge (no owning public-interface
##      member) stays UNTAGGED.

import std/[os, osproc, sequtils, strutils, tables, unittest]

import repro_binary_cache_client/cache_key
import blake3

const FixtureDir = currentSourcePath().parentDir.parentDir /
  "fixtures" / "l3-build-block-publish"

proc q(value: string): string =
  "'" & value.replace("'", "'\\''") & "'"

proc runNim(args: openArray[string]): tuple[code: int; output: string] =
  let res = execCmdEx(args.mapIt(q(it)).join(" "))
  (code: res.exitCode, output: res.output)

proc recipeRevisionHex(recipeDir: string): string =
  ## Independently recompute the expected ``providerRevision`` the exact
  ## way ``from_source_identity.providerRevisionHex`` /
  ## ``nim.nim.nimRecipeRevisionHex`` do — BLAKE3 of the recipe bytes,
  ## truncated to 32 hex chars — so the key check is a genuine
  ## cross-path equivalence, not a tautology.
  let body = readFile(recipeDir / "repro.nim")
  let full = blake3.toHex(blake3.digest(body))
  if full.len >= 32: full[0 ..< 32] else: full

proc expectedPublicToolKeyHex(recipeDir: string): string =
  ## Compose the identity the NIM CONVENTION would stamp for member
  ## ``publicTool`` (member name as packageName, no version, toolchain
  ## ``"nim"``, recipe-hash providerRevision) and derive its key hex.
  let idy = publicInterfaceIdentity(
    packageName = "publicTool",
    packageVersion = "",
    toolchainName = "nim",
    providerRevision = recipeRevisionHex(recipeDir))
  deriveCacheEntryKeyHex(idy)

type RunnerRow = object
  publish: bool
  keyHex: string
  pkgName: string
  toolchain: string
  providerRev: string

proc parseRows(output: string): Table[string, RunnerRow] =
  ## Each runner line: ``<kind>|<publish>|<keyHex>|<pkg>|<tc>|<rev>``.
  result = initTable[string, RunnerRow]()
  for line in output.splitLines():
    let parts = line.split('|')
    if parts.len != 6:
      continue
    result[parts[0]] = RunnerRow(
      publish: parts[1] == "true",
      keyHex: parts[2],
      pkgName: parts[3],
      toolchain: parts[4],
      providerRev: parts[5])

suite "L3 PUBLISH-SCOPE — provider-mode public-interface tagging":

  test "declared build-block executable is tagged + keyed like the Nim convention":
    let tmp = getTempDir() / "l3-build-block-publish-runner"
    let nimcache = tmp / "nimcache"
    let outBin = tmp / "runner"
    createDir(nimcache)

    # Compile the runner WITH the provider define — the exact posture a
    # real ``repro build`` uses to compile a recipe.
    let compiled = runNim(@["nim", "c", "--verbosity:0", "--hints:off",
      "-d:reproProviderMode",
      "--nimcache:" & nimcache, "--out:" & outBin,
      FixtureDir / "runner.nim"])
    if compiled.code != 0:
      checkpoint(compiled.output)
    check compiled.code == 0

    # Run the provider fragment build against the fixture recipe dir.
    let ran = execCmdEx(q(outBin) & " " & q(FixtureDir))
    if ran.exitCode != 0:
      checkpoint(ran.output)
    check ran.exitCode == 0

    let rows = parseRows(ran.output)

    # (1) + (2): the declared executable's edge is tagged AND its key
    # matches the Nim-convention key byte-for-byte.
    check rows.hasKey("publicTool")
    let pub = rows["publicTool"]
    check pub.publish
    check pub.pkgName == "publicTool"
    check pub.toolchain == "nim"
    check pub.providerRev == recipeRevisionHex(FixtureDir)
    check pub.keyHex == expectedPublicToolKeyHex(FixtureDir)
    check pub.keyHex.len > 0

    # (3): explicit ``publish = some(false)`` on a declared member — the
    # edge stays UNTAGGED even though it is public interface.
    check rows.hasKey("optedOutTool")
    check (not rows["optedOutTool"].publish)

    # (4): a package-level ``build:`` edge with no owning public-interface
    # member stays UNTAGGED.
    check rows.hasKey("internalHelper")
    check (not rows["internalHelper"].publish)
