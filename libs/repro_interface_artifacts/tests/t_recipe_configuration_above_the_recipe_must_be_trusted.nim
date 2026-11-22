## A recipe compile refuses a configuration file above or beside the recipe
## that another account wrote or can replace
## (`requireTrustedRecipeConfiguration`).
##
## Both compiles whose main module is the recipe -- the provider compile
## (`compileProviderBinary`) and the extraction's `nim dump`
## (`recipeConfigSearchPathFlags`) -- make Nim evaluate the `config.nims` of
## every directory above the recipe with this user's privileges. Each case
## plants a `config.nims` that writes a marker file when Nim evaluates it, so
## the test observes the evaluation itself rather than a proxy for it.
##
## An account other than this one cannot be created without privilege, so
## the directly observable cases are the ones this user can stage: a
## configuration file in a directory any account can write (and that is not
## sticky), one that any account can write itself, and a symbolic link to
## such a file -- above the recipe, and in the recipe's own directory. The
## other-account cases are covered against the pure decision
## (`recipeConfigEntryRefusal`) in `t_recipe_configuration_trust_decision.nim`.
## This file uses only entry points that predate the fix, so it builds -- and
## fails -- against the unfixed code. The positive controls show that the
## same chain IS evaluated when it is trustworthy -- including under a
## sticky, world-writable directory such as `/tmp` -- so a missing marker in
## the refusal cases is the refusal's doing.
##
## No mocks: a real directory tree with real modes, the real compiler, and
## the real provider compile and extraction entry points.

import std/[os, strutils, tempfiles, unittest]

when defined(posix):
  import std/posix

import repro_hash
import repro_interface_artifacts

when defined(posix):
  const Checkout = currentSourcePath().parentDir().parentDir().parentDir().
    parentDir()
    ## This reprobuild checkout: the provider compile's library root.

  proc setMode(path: string; mode: int) =
    ## `chmod`, exactly (`setFilePermissions` cannot set the sticky bit).
    doAssert chmod(path.cstring, Mode(mode)) == 0, "chmod " & path

  proc plantConfig(dir, marker: string): string =
    ## A `config.nims` in `dir` that writes `marker` when Nim evaluates it.
    result = dir / "config.nims"
    writeFile(result, "writeFile(" & marker.escape & ", \"evaluated\")\n")
    setMode(result, 0o644)

  proc recipeUnder(dir: string): string =
    ## A recipe two levels below `dir`, so `dir` is strictly above the
    ## recipe's own directory.
    let recipeDir = dir / "workspace" / "project"
    createDir(recipeDir)
    result = recipeDir / "repro.nim"
    writeFile(result, "discard\n")

  proc compileProvider(recipe, scratch: string) =
    discard compileProviderBinary(recipe, scratch / "out" / "project-provider",
      default(ContentDigest), workDir = Checkout,
      scratchDir = scratch / "scratch", useFreshnessCache = false)

  template expectRefusal(planted: string; body: untyped) =
    ## `body` raises the refusal, naming the planted file and its mode.
    var message = ""
    try:
      body
    except IOError as error:
      message = error.msg
    checkpoint(message)
    check message.contains("refusing to compile the recipe")
    check message.contains(planted)
    check message.contains("owned by uid " & $geteuid())
    check message.contains("mode 0")

  suite "a configuration file above the recipe that another account can replace is not evaluated":
    var root, marker: string
    setup:
      root = createTempDir("repro-recipe-config-trust-", "")
      marker = root / "evaluated.marker"
    teardown:
      setMode(root, 0o700)
      for kind, path in walkDir(root):
        if kind == pcDir: setMode(path, 0o755)
      removeDir(root)

    test "in a directory any account can write: the extraction's nim dump refuses it":
      let shared = root / "shared"
      createDir(shared)
      let planted = plantConfig(shared, marker)
      setMode(shared, 0o777)
      let recipe = recipeUnder(shared)
      expectRefusal(planted):
        discard recipeConfigSearchPathFlags(recipe, cwd = root)
      check not fileExists(marker)

    test "in a directory any account can write: the provider compile refuses it":
      let shared = root / "shared"
      createDir(shared)
      let planted = plantConfig(shared, marker)
      setMode(shared, 0o777)
      let recipe = recipeUnder(shared)
      expectRefusal(planted):
        compileProvider(recipe, root)
      check not fileExists(marker)

    test "a configuration file any account can write is refused":
      let parent = root / "parent"
      createDir(parent)
      let planted = plantConfig(parent, marker)
      setMode(planted, 0o666)
      let recipe = recipeUnder(parent)
      expectRefusal(planted):
        discard recipeConfigSearchPathFlags(recipe, cwd = root)
      expectRefusal(planted):
        compileProvider(recipe, root)
      check not fileExists(marker)

    test "a nim.cfg is held to the same rule as a config.nims":
      let parent = root / "parent"
      createDir(parent)
      let planted = parent / "nim.cfg"
      writeFile(planted, "--define:plantedByAnotherAccount\n")
      setMode(planted, 0o646)
      let recipe = recipeUnder(parent)
      expectRefusal(planted):
        discard recipeConfigSearchPathFlags(recipe, cwd = root)
      # Refused, not repaired: the file is left exactly as it was found.
      check fileExists(planted)
      check getFilePermissions(planted) ==
        {fpUserRead, fpUserWrite, fpGroupRead, fpOthersRead, fpOthersWrite}

    test "a symbolic link is followed to the file it names":
      let shared = root / "shared"
      createDir(shared)
      let target = plantConfig(shared, marker)
      setMode(shared, 0o777)
      let parent = root / "parent"
      createDir(parent)
      createSymlink(target, parent / "config.nims")
      let recipe = recipeUnder(parent)
      expectRefusal(target):
        discard recipeConfigSearchPathFlags(recipe, cwd = root)
      expectRefusal(target):
        compileProvider(recipe, root)
      check not fileExists(marker)

    test "a recipe reached through a symbolic link is held to its real directory's chain":
      # Nim resolves the main module with `expandFilename` before taking its
      # directory (`setFromProjectName`), so the chain it reads is that of
      # the file the link names, not of the directory holding the link.
      let shared = root / "shared"
      createDir(shared)
      let planted = plantConfig(shared, marker)
      setMode(shared, 0o777)
      let real = recipeUnder(shared)
      let linkDir = root / "parent" / "workspace" / "project"
      createDir(linkDir)
      let recipe = linkDir / "repro.nim"
      createSymlink(real, recipe)
      expectRefusal(planted):
        discard recipeConfigSearchPathFlags(recipe, cwd = root)
      expectRefusal(planted):
        compileProvider(recipe, root)
      check not fileExists(marker)

    test "a configuration file directly in the Nix store directory is held to the rule":
      # Only the Nix daemon creates store objects, but the store directory
      # itself is group-writable by the build users; a file there that is
      # not inside a store object is examined like any other.
      let store = root / "store"
      createDir(store)
      let planted = plantConfig(store, marker)
      setMode(planted, 0o666)
      let recipe = recipeUnder(store / "0000000000000000000000000000000a-src")
      putEnv("NIX_STORE_DIR", store)
      defer: delEnv("NIX_STORE_DIR")
      expectRefusal(planted):
        discard recipeConfigSearchPathFlags(recipe, cwd = root)
      check not fileExists(marker)

    test "control: a configuration file inside a Nix store object is evaluated":
      # Inside the Nix build sandbox, store objects show the overflow uid
      # (65534), not root, because root is not mapped into the sandbox's user
      # namespace. A store object is immutable once registered and written
      # only by the Nix daemon, so its files are trusted whatever owner they
      # show. Staged here as a world-writable file in a stand-in store: the
      # owner check is what the sandbox would trip, and the mode check is
      # the one this user can make fail.
      let store = root / "store"
      let storeObject = store / "0000000000000000000000000000000a-src"
      createDir(storeObject)
      let planted = plantConfig(storeObject, marker)
      setMode(planted, 0o666)
      let recipe = recipeUnder(storeObject)
      putEnv("NIX_STORE_DIR", store)
      defer: delEnv("NIX_STORE_DIR")
      discard recipeConfigSearchPathFlags(recipe, cwd = root)
      check fileExists(marker)

    test "a symbolic link inside a Nix store object is followed out of the store":
      # The link is part of an immutable store object, but the file it names
      # outside the store is not, and is held to the rule.
      let shared = root / "shared"
      createDir(shared)
      let target = plantConfig(shared, marker)
      setMode(target, 0o666)
      let store = root / "store"
      let storeObject = store / "0000000000000000000000000000000a-src"
      createDir(storeObject)
      createSymlink(target, storeObject / "config.nims")
      let recipe = recipeUnder(storeObject)
      putEnv("NIX_STORE_DIR", store)
      defer: delEnv("NIX_STORE_DIR")
      expectRefusal(target):
        discard recipeConfigSearchPathFlags(recipe, cwd = root)
      check not fileExists(marker)

    test "control: this user's own file in a sticky world-writable directory is evaluated":
      # `/tmp`'s shape: anyone may create an entry, only its owner may replace
      # it. The chain is evaluated, by both compiles, so the refusals above
      # are what kept their markers from appearing.
      let sticky = root / "sticky"
      createDir(sticky)
      discard plantConfig(sticky, marker)
      setMode(sticky, 0o1777)
      let recipe = recipeUnder(sticky)
      discard recipeConfigSearchPathFlags(recipe, cwd = root)
      check fileExists(marker)
      removeFile(marker)
      try:
        compileProvider(recipe, root)
      except CatchableError as error:
        # Whether the trivial recipe links as a provider is not the subject;
        # that its configuration chain was evaluated is. A refusal would be.
        checkpoint(error.msg)
        check not error.msg.contains("refusing to compile the recipe")
      check fileExists(marker)

    test "control: a configuration file in this user's own directory is evaluated":
      let parent = root / "parent"
      createDir(parent)
      discard plantConfig(parent, marker)
      let recipe = recipeUnder(parent)
      discard recipeConfigSearchPathFlags(recipe, cwd = root)
      check fileExists(marker)

    test "beside a recipe in a directory any account can write: the recipe's <name>.nims is refused":
      # Nim also reads the configuration in the recipe's own directory --
      # `nim.cfg`, `config.nims`, and the recipe's `<name>.nim.cfg` and
      # `<name>.nims`, which `nim c` and `nim dump` both evaluate. A recipe
      # written straight into a shared directory would otherwise have a
      # neighbour's file evaluated without a check.
      let shared = root / "shared"
      createDir(shared)
      let recipe = shared / "repro.nim"
      writeFile(recipe, "discard\n")
      let planted = shared / "repro.nims"
      writeFile(planted, "writeFile(" & marker.escape & ", \"evaluated\")\n")
      setMode(planted, 0o644)
      setMode(shared, 0o777)
      expectRefusal(planted):
        discard recipeConfigSearchPathFlags(recipe, cwd = root)
      expectRefusal(planted):
        compileProvider(recipe, root)
      check not fileExists(marker)

    test "a configuration file in the recipe's own directory that any account can write is refused":
      let recipe = recipeUnder(root)
      let planted = plantConfig(recipe.parentDir, marker)
      setMode(planted, 0o666)
      expectRefusal(planted):
        discard recipeConfigSearchPathFlags(recipe, cwd = root)
      check not fileExists(marker)

    test "control: this user's own configuration beside a recipe in a sticky world-writable directory is evaluated":
      let sticky = root / "sticky"
      createDir(sticky)
      let recipe = sticky / "repro.nim"
      writeFile(recipe, "discard\n")
      discard plantConfig(sticky, marker)
      setMode(sticky, 0o1777)
      discard recipeConfigSearchPathFlags(recipe, cwd = root)
      check fileExists(marker)
