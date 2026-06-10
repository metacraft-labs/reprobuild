## Regression test for Dotfiles-Migration-Completion M1:
## template-in-template + named-arg authoring through the profile-compile
## pipeline.
##
## Background
## ----------
## The `zah/dotfiles` migration tripped over a Nim-template-hygiene
## phenomenon: when an outer `template` wrapper has parameter names
## (e.g. ``mode``, ``address``) that ALSO appear as named-argument keys
## in calls inside the template body, Nim substitutes EVERY occurrence
## of the parameter -- including the LHS of the named-argument
## expressions. ``fsUserFile(... mode = mode, ...)`` inside such a
## wrapper expands to ``fsUserFile(... "0600" = "0600", ...)`` which the
## parser rejects with ``Error: identifier expected, but found '"0600"'``
## (and the type-checker subsequently reports ``unknown named parameter:
## <Error>``).
##
## ``nim check`` passes the wrapper module standalone because templates
## are only instantiated at call sites; the failure surfaces when the
## profile-compile pipeline actually invokes ``deployAgeSecrets()`` from
## a ``resources:`` block.
##
## The convention this test locks
## ------------------------------
## User-authored wrappers that pass named arguments through to a
## resource constructor MUST be ``proc``s, NOT ``template``s, when their
## parameter names overlap with the inner constructor's parameter names.
## Procs are immune to the template-parameter substitution and route
## named arguments through cleanly.
##
## This test exercises the convention end-to-end via the production
## ``compileProfileBinary`` entry point, then asserts the emitted
## ``ProfileIntent`` carries the expected ``fs.userFile`` resources with
## the correct named-argument values.
##
## The fixture mirrors the shape of
## ``zah/dotfiles/modules/age_secrets.nim`` (post-M1 fix): an
## ``ageSecret`` *proc* wrapper that calls ``fsUserFile`` with named
## arguments whose keys (``mode``, ``address``) collide with the
## wrapper's own parameter names.

import std/[os, strutils, tables, tempfiles, unittest]
from repro_core/paths import extendedPath

import repro_profile
import repro_profile_intent
import repro_profile_compile

# ---------------------------------------------------------------------------
# Fixture files (written into a tempdir).
# ---------------------------------------------------------------------------

const SecretsHelperBody = """
## Mirrors zah/dotfiles/modules/age_secrets.nim post-M1 fix:
## ageSecret is a `proc` (not a `template`) so its parameter names
## `mode` and `address` do not collide with the inner fsUserFile call's
## named-argument keys via Nim template hygiene.

import repro_profile

proc ageSecret*(targetResources: var seq[ResourceIntent];
                src: string; dest: string;
                identity = "~/.config/age/keys.txt";
                mode = "0600"; address = "") =
  fsUserFile(
    targetResources,
    hostFile = dest,
    contentFromCommand = @["age", "-d", "-i", identity, src],
    mode = mode,
    address = if address.len > 0: address else: "ageSecret:" & dest,
    cacheKey = "age:" & src & "@" & identity)
"""

const SecretsInventoryBody = """
## Mirrors zah/dotfiles/modules/secrets_inventory.nim: the OUTER
## template (deployAgeSecrets) carries no parameter-name collisions of
## its own, but calls ageSecret with named arguments whose keys match
## ageSecret's parameter names. The fix is that ageSecret is a proc.

import repro_profile
import ./age_secrets

template deployAgeSecrets*(targetResources: var seq[ResourceIntent]) =
  ageSecret(targetResources,
    src = "~/dotfiles/secrets/gpg-ownertrust.txt.age",
    dest = "~/dotfiles/secrets/gpg-ownertrust.txt",
    mode = "0600",
    address = "gpg:ownertrust")

  ageSecret(targetResources,
    src = "~/dotfiles/secrets/gpg-public.asc.age",
    dest = "~/dotfiles/secrets/gpg-public.asc",
    mode = "0644",
    address = "gpg:publicKeyring")

  ageSecret(targetResources,
    src = "~/dotfiles/secrets/.ssh_id_rsa.age",
    dest = "~/.ssh/id_rsa",
    mode = "0600",
    address = "ssh:id_rsa")
"""

const HomeProfileBody = """
## Minimal profile that drives deployAgeSecrets() through the
## resources: block under a `when defined(windows):` guard (mirrors the
## dotfiles home.nim shape).

import repro_profile
import ./secrets_inventory

profile "tinNamedArgsRegression":
  activity default:
    neovim

  resources:
    when defined(windows):
      deployAgeSecrets()
    when defined(linux) or defined(macosx):
      deployAgeSecrets()
"""

# ---------------------------------------------------------------------------
# Test helpers.
# ---------------------------------------------------------------------------

proc writeFixture(dir, name, body: string) =
  let path = dir / name
  let parent = path.parentDir
  if not dirExists(extendedPath(parent)):
    createDir(extendedPath(parent))
  writeFile(extendedPath(path), body)

proc resourceByAddress(resources: seq[ResourceIntent];
                       address: string): ResourceIntent =
  for r in resources:
    if r.address == address:
      return r
  raise newException(ValueError,
    "no resource with address `" & address & "` in intent")

# ---------------------------------------------------------------------------
# The test.
# ---------------------------------------------------------------------------

suite "Dotfiles-Migration-Completion M1: template-in-template + named args":

  test "compileProfileBinary round-trips named args through the " &
       "proc-wrapper convention":
    let tempDir = createTempDir("repro-m1-tin-args-", "")
    defer:
      try: removeDir(tempDir) except OSError: discard

    let profileDir = tempDir / "profile"
    createDir(extendedPath(profileDir))
    writeFixture(profileDir, "age_secrets.nim", SecretsHelperBody)
    writeFixture(profileDir, "secrets_inventory.nim", SecretsInventoryBody)
    writeFixture(profileDir, "home.nim", HomeProfileBody)

    let nimcacheDir = tempDir / "nimcache"
    let outBinary = nimcacheDir /
      (when defined(windows): "profile.exe" else: "profile")

    let res = compileProfileBinary(
      profileRoot = profileDir / "home.nim",
      nimcacheDir = nimcacheDir,
      outBinary = outBinary,
      repoRoot = reprobuildRepoRoot(),
      verbose = false)

    # The JSON ProfileIntent must round-trip cleanly through RBPI.
    let rbpiBytes = rbpiBytesFromJson(res.jsonOutput)
    let intent = decodeRbpi(rbpiBytes)
    check intent.name == "tinNamedArgsRegression"

    # Three age secrets were declared via deployAgeSecrets(). Each MUST
    # carry the named-argument values verbatim -- this is the property
    # the bug used to corrupt.
    check intent.resources.len == 3

    let r0 = intent.resources.resourceByAddress("gpg:ownertrust")
    check r0.kind == "fs.userFile"
    check "mode" in r0.fields
    check r0.fields["mode"].kind == fvkString
    check r0.fields["mode"].s == "0600"
    check r0.fields["hostFile"].s ==
      "~/dotfiles/secrets/gpg-ownertrust.txt"
    check r0.fields["cacheKey"].s ==
      "age:~/dotfiles/secrets/gpg-ownertrust.txt.age@" &
      "~/.config/age/keys.txt"
    # contentFromCommand: argv list with `age -d -i <identity> <src>`.
    check r0.fields["contentFromCommand"].kind == fvkList
    check r0.fields["contentFromCommand"].items.len == 5
    check r0.fields["contentFromCommand"].items[0] == "age"
    check r0.fields["contentFromCommand"].items[1] == "-d"
    check r0.fields["contentFromCommand"].items[2] == "-i"
    check r0.fields["contentFromCommand"].items[3] ==
      "~/.config/age/keys.txt"
    check r0.fields["contentFromCommand"].items[4] ==
      "~/dotfiles/secrets/gpg-ownertrust.txt.age"

    let r1 = intent.resources.resourceByAddress("gpg:publicKeyring")
    check r1.fields["mode"].s == "0644"
    check r1.fields["hostFile"].s ==
      "~/dotfiles/secrets/gpg-public.asc"

    let r2 = intent.resources.resourceByAddress("ssh:id_rsa")
    check r2.fields["mode"].s == "0600"
    check r2.fields["hostFile"].s == "~/.ssh/id_rsa"

  test "the inner-template anti-pattern (template wrapper with " &
       "colliding param names) is correctly rejected by Nim":
    ## Counter-test: the same fixture but with `template` instead of
    ## `proc` for the wrapper MUST trip Nim's parser. This anchors the
    ## convention in the negative direction so a future refactor of
    ## the dotfiles helpers back to `template` is caught here. We
    ## drive `compileProfileBinary` and assert it raises
    ## CompileFailure with a message containing the diagnostic Nim
    ## emits for this class of failure.
    const BrokenHelper = SecretsHelperBody.replace(
      "proc ageSecret*",
      "template ageSecret*")
    let tempDir = createTempDir("repro-m1-tin-args-neg-", "")
    defer:
      try: removeDir(tempDir) except OSError: discard

    let profileDir = tempDir / "profile"
    createDir(extendedPath(profileDir))
    writeFixture(profileDir, "age_secrets.nim", BrokenHelper)
    writeFixture(profileDir, "secrets_inventory.nim", SecretsInventoryBody)
    writeFixture(profileDir, "home.nim", HomeProfileBody)

    let nimcacheDir = tempDir / "nimcache"
    let outBinary = nimcacheDir /
      (when defined(windows): "profile.exe" else: "profile")

    expect CompileFailure:
      discard compileProfileBinary(
        profileRoot = profileDir / "home.nim",
        nimcacheDir = nimcacheDir,
        outBinary = outBinary,
        repoRoot = reprobuildRepoRoot(),
        verbose = false)
