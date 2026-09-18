## An empty provider-revision component is refused, not returned.
##
## ## The defect
##
## `sourceCacheEntryIdentity` derives its provider-revision component by
## digesting the recipe file under the project root it is handed. Given an
## EMPTY root, `resolveProjectFile("")` resolves relative to the process'
## current working directory. That produced two outcomes and announced
## neither:
##
##   * with the cwd standing in the recipe's own directory it found that
##     recipe and returned the *correct* digest — so the call appeared to
##     work, and appeared to work for a reason that has nothing to do with
##     its arguments;
##   * from anywhere else it returned the empty string, and the identity
##     came back with an empty provider revision.
##
## The second is the one that matters. That component is what distinguishes
## one recipe's entry from another's in a content-addressed store. Empty is
## a value every package reaching this path shares, so two unrelated recipes
## agree on a cache key — which is the precise failure the identity exists
## to prevent.
##
## ## What is asserted
##
## That the refusal happens, that it happens for BOTH ways of producing an
## empty component (no root at all; a root with no recipe in it), that it
## names which one, and — the half that keeps this from being a test of a
## function that refuses everything — that a real root still yields a real
## identity, with a provider revision that CHANGES when the recipe changes.
##
## ## Mocking
##
## None. Real directories, real files on disk, the production function.

import std/[os, strutils, tempfiles, unittest]

import repro_binary_cache_client/cache_key
import repro_project_dsl/source_cache_identity

proc refusalFor(root, name: string): string =
  try:
    discard sourceCacheEntryIdentity(root, name, "1", "cmake")
    ""
  except CacheKeyError as e:
    e.msg

suite "source cache identity refuses an empty provider revision":

  test "an empty project root is refused, and the message says why":
    ## Run from a directory that is NOT a recipe directory, which is the
    ## arm that used to return an empty component. The other arm — cwd
    ## standing in a recipe directory — is the case below.
    let elsewhere = createTempDir("source-cache-cwd-", "")
    defer: removeDir(elsewhere)
    let previous = getCurrentDir()
    setCurrentDir(elsewhere)
    defer: setCurrentDir(previous)
    let msg = refusalFor("", "probe")
    checkpoint("refusal: " & msg)
    check msg.len > 0
    check "no project root was given" in msg
    check "probe" in msg

  test "an empty root is refused even when the cwd WOULD have rescued it":
    ## The arm that made this defect survive review twice: standing in the
    ## recipe's own directory, the empty root silently resolved to the
    ## right recipe and produced a correct-looking identity. Correct by
    ## accident is still an identity nothing in the call decided, and the
    ## same call one directory over produces a different one.
    let recipeDir = createTempDir("source-cache-cwd-recipe-", "")
    defer: removeDir(recipeDir)
    writeFile(recipeDir / "repro.nim", "const implementation = 1\n")
    let previous = getCurrentDir()
    setCurrentDir(recipeDir)
    defer: setCurrentDir(previous)
    let msg = refusalFor("", "probe")
    checkpoint("refusal: " & msg)
    check "no project root was given" in msg
    # And the control that gives this case its point: from this same
    # directory, the root spelled out explicitly DOES work. So the refusal
    # above is about the argument and not about the surroundings.
    let identity = sourceCacheEntryIdentity(recipeDir, "probe", "1", "cmake")
    check identity.providerRevision.len == 32

  test "a root with no recipe in it is refused, by the OTHER clause":
    ## Two ways to reach an empty component, and a message that cannot
    ## tell them apart is a message that has not identified either.
    let empty = createTempDir("source-cache-norecipe-", "")
    defer: removeDir(empty)
    let msg = refusalFor(empty, "probe")
    checkpoint("refusal: " & msg)
    check "no non-empty recipe file was found" in msg
    check empty in msg
    check "no project root was given" notin msg

  test "an empty recipe file is refused too":
    ## `sourceProviderRevisionHex` returns "" for a zero-byte recipe as
    ## well as for a missing one. Both are the same hole.
    let root = createTempDir("source-cache-emptyrecipe-", "")
    defer: removeDir(root)
    writeFile(root / "repro.nim", "")
    let msg = refusalFor(root, "probe")
    checkpoint("refusal: " & msg)
    check "no non-empty recipe file was found" in msg

  test "a real root still yields a real identity that tracks the recipe":
    ## The negative control. Without it every case above is satisfied by a
    ## function that refuses unconditionally, and a refusal that fires on
    ## everything decides nothing.
    let root = createTempDir("source-cache-real-", "")
    defer: removeDir(root)
    writeFile(root / "repro.nim", "const implementation = 1\n")
    let before = sourceCacheEntryIdentity(root, "probe", "1", "cmake")
    check before.providerRevision.len == 32
    check before.packageName == "probe"

    writeFile(root / "repro.nim", "const implementation = 2\n")
    let after = sourceCacheEntryIdentity(root, "probe", "1", "cmake")
    check after.providerRevision.len == 32
    # The component is a digest OF the recipe, so a changed recipe is a
    # changed component. If it were not, "empty is a shared value" would
    # be the smaller of this function's two problems.
    check after.providerRevision != before.providerRevision

  test "two different recipes do not share a provider revision":
    ## The collision the refusal exists to prevent, stated positively.
    let a = createTempDir("source-cache-a-", "")
    let b = createTempDir("source-cache-b-", "")
    defer: removeDir(a)
    defer: removeDir(b)
    writeFile(a / "repro.nim", "const which = \"a\"\n")
    writeFile(b / "repro.nim", "const which = \"b\"\n")
    let ia = sourceCacheEntryIdentity(a, "probe", "1", "cmake")
    let ib = sourceCacheEntryIdentity(b, "probe", "1", "cmake")
    check ia.providerRevision != ib.providerRevision
    # Same package name, same version, same convention, same platform —
    # the provider revision is the ONLY thing keeping these two apart, and
    # an empty one would have made them equal.
    check ia.packageName == ib.packageName
    check ia.packageVersion == ib.packageVersion

  test "the identity still may not authorise a substitute":
    ## The pre-existing rule, re-asserted here because this change touches
    ## the constructor that stamps it. A refusal added on one axis must not
    ## quietly remove one on another.
    let root = createTempDir("source-cache-pending-", "")
    defer: removeDir(root)
    writeFile(root / "repro.nim", "const implementation = 1\n")
    let identity = sourceCacheEntryIdentity(root, "probe", "1", "cmake")
    expect CacheKeyError:
      discard deriveCacheEntryKeyHex(identity)
