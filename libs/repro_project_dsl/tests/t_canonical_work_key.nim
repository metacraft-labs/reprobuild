## A step's canonical work key is location-independent, and it survives
## registration and the build-action payload codec.
##
## reprobuild-pm `spec/Hermetic-Builds-And-Path-Independence.md`
## §"Canonical work trees": the key hashes the recipe's logical identity --
## role, package, and the project directory relative to the repository that
## contains it -- so every checkout of one repository computes the same key,
## and the engine places the step's work tree at the same path in each.
##
## No mocks: two real repository checkouts (a `.git` directory is what marks
## the root) at different paths, the real registry, the real v37 codec.

import std/[os, strutils, tempfiles, unittest]

import repro_project_dsl

proc checkoutAt(dir: string): string =
  ## A repository checkout at `dir` holding a recipe at
  ## `packages/source/gemini-cli`; returns the recipe's directory.
  createDir(dir / ".git")
  result = dir / "packages" / "source" / "gemini-cli"
  createDir(result)

suite "canonical work keys":
  test "two checkouts of one repository compute the same key":
    let base = createTempDir("canonical-key-", "")
    defer: removeDir(base)
    let a = checkoutAt(base / "reprobuild-packages")
    let b = checkoutAt(base / "elsewhere" / "portable-b" / "reprobuild-packages")
    check logicalRecipePath(a) == "packages/source/gemini-cli"
    check logicalRecipePath(b) == "packages/source/gemini-cli"
    let ka = canonicalWorkKeyFor("node-build", "geminiCliSource",
      logicalRecipePath(a))
    let kb = canonicalWorkKeyFor("node-build", "geminiCliSource",
      logicalRecipePath(b))
    check ka == kb
    check ka.startsWith("node-build-")
    check ka.len == "node-build-".len + 16
    check isValidCanonicalWorkKeyText(ka)
    # The checkout's path is nowhere in it.
    check "reprobuild-packages" notin ka

  test "another recipe, package or role gets another key":
    let k = canonicalWorkKeyFor("node-build", "geminiCliSource",
      "packages/source/gemini-cli")
    check k != canonicalWorkKeyFor("node-build", "geminiCliSource",
      "packages/source/other-cli")
    check k != canonicalWorkKeyFor("node-build", "otherSource",
      "packages/source/gemini-cli")
    check k != canonicalWorkKeyFor("cmake-build", "geminiCliSource",
      "packages/source/gemini-cli")

  test "a recipe at a repository's root, and one outside any repository":
    let base = createTempDir("canonical-key-root-", "")
    defer: removeDir(base)
    createDir(base / "repo" / ".git")
    check logicalRecipePath(base / "repo") == "."
    # No `.git` anywhere above (the temporary directory is not a checkout on
    # a test host): the directory's own name.
    createDir(base / "loose" / "my-recipe")
    let loose = logicalRecipePath(base / "loose" / "my-recipe")
    checkpoint(loose)
    check loose == "my-recipe" or loose.endsWith("/my-recipe")

  test "an invalid key is refused at declaration":
    resetBuildActionRegistry()
    expect ValueError:
      discard buildAction(id = "bad", call = inlineExecCall(@["sh"]),
        canonicalWorkKey = "../escape")
    check registeredBuildActions().len == 0
    expect ValueError:
      discard canonicalWorkKeyFor("bad role", "p", "x")

  test "the payload round-trips the key; a v36 payload carries none":
    resetBuildActionRegistry()
    let action = buildAction(id = "node-build-x",
      call = inlineExecCall(@["sh", "-c", "true"]),
      canonicalWorkKey = "node-build-0123456789abcdef")
    check registeredBuildActions()[0].canonicalWorkKey ==
      "node-build-0123456789abcdef"
    let decoded = decodeBuildActionPayload(encodeBuildActionPayload(action))
    check decoded.canonicalWorkKey == "node-build-0123456789abcdef"
    check buildActionPayloadVersion(encodeBuildActionPayload(action)) == 37'u16
    let v36 = decodeBuildActionPayload(
      encodeBuildActionPayloadAtVersion(action, 36'u16))
    check v36.canonicalWorkKey == ""
    # The key is in the payload bytes the lowering keys the edge on.
    var unkeyed = action
    unkeyed.canonicalWorkKey = ""
    check encodeBuildActionPayload(action) != encodeBuildActionPayload(unkeyed)
