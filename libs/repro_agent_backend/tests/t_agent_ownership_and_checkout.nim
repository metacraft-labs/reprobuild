## ReproOS-Agent-Harbor-Integration M3 deliverables 1, 2 and 4 at library
## level: an installed file resolves to the recipe that produced it, the
## recipe is checked out into an isolated workspace, and the change is a
## diff against an exact copy of what was installed from.
##
## Real store, real install-mirror publish (the same function the
## `repro-install-mirror-publish` tool a recipe's install action runs),
## real git. Nothing is mocked. The end-to-end gate, which builds the
## fixture with `repro`, is `t_e2e_agent_harbor_modifies_installed_source_package`.

import std/[os, osproc, sequtils, strutils, tempfiles, unittest]

import repro_project_dsl/install_mirror_publish
import repro_agent_backend

proc install(catalog, store, pkg, version, binBody: string): string =
  ## Lay out a recipe and its install tree, then publish the tree the way
  ## a recipe's install action does. Returns the installed executable.
  createDir(catalog / pkg / "src")
  writeFile(catalog / pkg / "repro.nim", "## recipe of " & pkg & "\n")
  writeFile(catalog / pkg / "src" / "main.c",
            "int main(void) { return 0; }\n")
  let tree = catalog / pkg / "build" / ("install-" & version)
  createDir(tree / "bin")
  writeFile(tree / "bin" / pkg, binBody)
  setFilePermissions(tree / "bin" / pkg, {fpUserRead, fpUserWrite, fpUserExec})
  let r = publishInstallMirrorToStore(catalog, pkg, version, tree, store)
  r.absolutePath / "bin" / pkg

proc cleanup(dir: string) =
  ## Published prefixes are read-only by design; restore write access
  ## before deleting the scratch tree.
  discard execCmd("chmod -R u+w " & quoteShell(dir))
  removeDir(dir)

suite "M3 — ownership":
  let tmp = createTempDir("agent-own-", "")
  let catalog = tmp / "catalog"
  let store = tmp / "store"
  let hello = install(catalog, store, "hello", "1.0", "#!/bin/sh\necho hello\n")
  discard install(catalog, store, "other", "2.0", "#!/bin/sh\necho other\n")

  test "an installed executable resolves to its package, prefix and recipe":
    let r = resolveOwnership(store, @[catalog], hello)
    check r.package == "hello"
    check r.version == "1.0"
    check r.adapter == "install-mirror"
    check r.recipeName == "hello"
    check r.recipeDir == catalog / "hello"
    check r.prefixPath == hello.parentDir.parentDir
    check r.recipeTreeDigest == recipeTreeDigest(catalog / "hello")
    # Build state is not part of the definition.
    check "build/install/bin/hello" notin recipeFiles(catalog / "hello")
    check recipeFiles(catalog / "hello") == @["repro.nim", "src/main.c"]
    # What it cannot establish is named, not guessed.
    check r.pending.len == PendingFacts.len
    check r.pending.anyIt(it.startsWith("source-revision"))

  test "a launcher symlink resolves through to the prefix it points at":
    createDir(tmp / "profile" / "bin")
    createSymlink(hello, tmp / "profile" / "bin" / "hello")
    check resolveOwnership(store, @[catalog],
                           tmp / "profile" / "bin" / "hello").package == "hello"

  test "refusals: not installed, rebuilt since, ambiguous":
    proc reasonOf(path: string; roots: seq[string]): string =
      try:
        discard resolveOwnership(store, roots, path)
        "resolved"
      except OwnershipError as e:
        e.reason
    check reasonOf(catalog / "hello" / "src" / "main.c", @[catalog]) ==
      "not-installed"
    check reasonOf(hello, @[tmp / "empty-catalog"]) == "no-recipe"
    # A second catalog claiming the same output is ambiguous.
    copyDir(catalog / "hello", tmp / "fork" / "hello")
    check reasonOf(hello, @[catalog, tmp / "fork"]) == "ambiguous-recipe"
    # Rebuilding the recipe moves its sidecar to the new output: the old
    # prefix no longer has a recipe, and is refused rather than misattributed.
    let v2 = install(catalog, store, "hello", "1.1", "#!/bin/sh\necho v2\n")
    check reasonOf(hello, @[catalog]) == "no-recipe"
    check resolveOwnership(store, @[catalog], v2).version == "1.1"

  cleanup(tmp)

suite "M3 — checkout and diff":
  let tmp = createTempDir("agent-co-", "")
  let catalog = tmp / "catalog"
  let store = tmp / "store"
  let bin = install(catalog, store, "hello", "1.0", "#!/bin/sh\necho hello\n")
  createSymlink("main.c", catalog / "hello" / "src" / "alias.c")
  let rec = resolveOwnership(store, @[catalog], bin)

  test "the workspace is an exact copy of the recipe, tagged as the base":
    let co = createCheckout(rec, tmp / "ws1", storeRoot = store)
    check co.packageDir == tmp / "ws1" / "hello"
    check recipeTreeDigest(co.packageDir) == rec.recipeTreeDigest
    check symlinkExists(co.packageDir / "src" / "alias.c")
    check not dirExists(co.packageDir / "build")
    check co.baseCommit.len == 40
    check diffAgainstBase(co.root).len == 0
    # The base commit is a function of the recipe alone.
    let again = createCheckout(rec, tmp / "ws2", storeRoot = store)
    check again.baseCommit == co.baseCommit

  test "an edit is a diff against the base; build state is not":
    let co = createCheckout(rec, tmp / "ws3", storeRoot = store)
    writeFile(co.packageDir / "src" / "main.c",
              "int main(void) { return 1; }\n")
    createDir(co.packageDir / "build")
    writeFile(co.packageDir / "build" / "junk.o", "x")
    let d = diffAgainstBase(co.root)
    check "--- a/hello/src/main.c" in d
    check "+int main(void) { return 1; }" in d
    check "junk.o" notin d
    # The installed prefix and the catalog recipe are untouched.
    check readFile(catalog / "hello" / "src" / "main.c") ==
      "int main(void) { return 0; }\n"
    check readFile(bin) == "#!/bin/sh\necho hello\n"

  test "a checkout refuses a non-empty root and a recipe inside the store":
    createDir(tmp / "busy")
    writeFile(tmp / "busy" / "x", "")
    expect CheckoutError:
      discard createCheckout(rec, tmp / "busy", storeRoot = store)
    var inStore = rec
    inStore.recipeDir = rec.prefixPath
    expect CheckoutError:
      discard createCheckout(inStore, tmp / "ws4", storeRoot = store)

  test "a recipe that changes after resolution is refused":
    writeFile(catalog / "hello" / "repro.nim", "## edited behind our back\n")
    expect CheckoutError:
      discard createCheckout(rec, tmp / "ws5", storeRoot = store)
    check toSeq(walkDir(tmp / "ws5")).len == 0

  cleanup(tmp)
