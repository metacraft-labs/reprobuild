## A lock conflict over a range that a cross-repo producer's CHECKOUT declares,
## while that checkout is not at the revision the consumer's lock pins, names
## the checkout and both revisions and leads with bringing the checkout to the
## pin, ahead of the targeted re-pin.
##
## WHAT WENT WRONG. codetracer's lock pinned codetracer-ruby-recorder at a
## revision whose recipe no longer declares `ruby >=3.1`, but the build read
## the producer's recipe from a checkout 36 commits behind that pin, which
## still did. The provider's range check then reported that the LOCK
## contradicts the producer, and its first remedy, `--repin=ruby`, would have
## changed a correct lock to fit a stale checkout.
##
## HOW THE FIXTURE MODELS IT. The producer is a real git repository with two
## commits: the older one declares the range, the newer one (the lock's pin)
## does not. The checkout is left at the OLDER commit, so its recipe's range
## is what the registry receives, registered exactly as the `package` macro
## emits it for an imported sibling recipe (`sdsSiblingRecipe` plus the
## recipe's file). The CLI's hand-off is the real `LockProducerCheckoutsEnvVar`
## grammar, rendered by the real `renderLockProducerCheckouts`.
##
## Test-double policy: NO mocks, doubles, or fakes. Real git repositories, a
## real lock written by the real `repro_lock` writer and read back through the
## `parseSolvedGraphLock` / `lockToSolution` pair the CLI loader uses, and the
## real registration entry point.

import std/[os, osproc, strutils, tables, tempfiles, unittest]

import repro_dsl_stdlib/configurables/variants
import repro_lock
import repro_solver
import repro_test_support/reasoned_skip

const Ruby = "ruby"
const LockedVersion = "0.0.0"
const ProducerRange = ">=3.1"
const Consumer = "codetracer"
const ProducerPackage = "ruby_recorder"
  ## Deliberately NOT the repository's name spelled with underscores: a
  ## producer's package need not be named after its repo, and the checkout is
  ## found from the declaring recipe's file, not from the name.
const ProducerRepo = "codetracer-ruby-recorder"
const RepinRemedy = "repro lock refresh --repin=ruby"

proc gitOut(dir: string; args: varargs[string]): string =
  var cmd = "git -C " & quoteShell(dir)
  for a in args: cmd.add(" " & quoteShell(a))
  let (output, code) = execCmdEx(cmd)
  doAssert code == 0, cmd & " failed: " & output
  output.strip()

proc initProducer(dir: string): tuple[older, pinned: string] =
  ## Two commits: the older recipe declares the range, the pinned one does
  ## not. Returns both object ids.
  createDir(dir)
  discard gitOut(dir, "init", "-q", "-b", "main")
  discard gitOut(dir, "config", "user.email", "t@example.invalid")
  discard gitOut(dir, "config", "user.name", "Tester")
  writeFile(dir / "repro.nim", "uses: \"ruby " & ProducerRange & "\"\n")
  discard gitOut(dir, "add", "-A")
  discard gitOut(dir, "commit", "-q", "-m", "declare ruby")
  result.older = gitOut(dir, "rev-parse", "HEAD")
  writeFile(dir / "repro.nim", "# ruby dropped\n")
  discard gitOut(dir, "commit", "-q", "-am", "drop ruby")
  result.pinned = gitOut(dir, "rev-parse", "HEAD")

proc writeLock(path: string; packages: openArray[(string, string)]) =
  var sol = UnifiedSolution(
    variants: initTable[string, string](),
    packages: initTable[string, string](),
    optimal: true)
  for (name, version) in packages: sol.packages[name] = version
  let solved = solutionToLock(sol, currentPlatformId(), "")
  writeFile(path, serializeLockedDependencies(lockedDepsFromSolved(solved)))

proc governWith(lockPath, checkoutDir, pinned: string) =
  let solution = lockToSolution(parseSolvedGraphLock(readFile(lockPath)))
  putEnv(LockPinsEnvVar, renderLockPins(solution.packages, solution.variants))
  putEnv(LockPathEnvVar, lockPath)
  putEnv(LockProducerCheckoutsEnvVar, renderLockProducerCheckouts([
    LockProducerCheckout(name: ProducerRepo, checkoutDir: checkoutDir,
      pinnedRevision: pinned)]))

proc ungovern() =
  delEnv(LockPinsEnvVar)
  delEnv(LockPathEnvVar)
  delEnv(LockProducerCheckoutsEnvVar)

proc conflictMessage(): string =
  try:
    discard currentSolverPackageDecls()
  except ELockConflict as err:
    return err.msg
  ""

template withScenario(body: untyped) =
  let scratch {.inject.} = createTempDir("repro-stale-producer-", "")
  ungovern()
  resetVariantState()
  try:
    body
  finally:
    resetVariantState()
    ungovern()
    removeDir(scratch)

suite "a lock conflict from a producer checkout that is not at its pin":

  test "a checkout behind its pin is named, with the checkout remedy first":
    if findExe("git").len == 0:
      skip("git not on PATH; the fixture is a real git repository")
    else:
      withScenario:
        let checkout = scratch / ProducerRepo
        let (older, pinned) = initProducer(checkout)
        discard gitOut(checkout, "checkout", "-q", "--detach", older)
        let lockPath = scratch / "repro.lock"
        writeLock(lockPath, {Ruby: LockedVersion, Consumer: "0.1.0",
                             ProducerPackage: "0.1.0"})
        governWith(lockPath, checkout, pinned)
        registerSolverDependency(ProducerPackage, Ruby,
          Ruby & " " & ProducerRange, declarationSite = sdsSiblingRecipe,
          declarationFile = checkout / "repro.nim")
        let message = conflictMessage()
        checkpoint(message)
        check message.len > 0
        check "'" & ProducerPackage & "'" in message
        check "cross-repo producer" in message
        # The checkout and BOTH revisions.
        check checkout in message
        check older in message
        check pinned in message
        # It does not say the lock is wrong.
        check "does not show the lock is wrong" in message
        # The first remedy is bringing the checkout to the pin; the re-pin is
        # still named, after it, and conditioned.
        let checkoutRemedy = "checkout --detach " & pinned
        check checkoutRemedy in message
        check RepinRemedy in message
        check message.find(checkoutRemedy) < message.find(RepinRemedy)
        check "only if the conflict remains" in message
        # The whole-lock regeneration is not offered for a stale checkout.
        check "Regenerate the lock with `repro lock refresh`" notin message

  test "the same checkout on a branch, refs packed, is still read":
    # `git checkout <branch>` leaves HEAD a symbolic ref; `git pack-refs`
    # moves the branch out of its loose file. Both are the ordinary state of a
    # long-lived workspace checkout.
    if findExe("git").len == 0:
      skip("git not on PATH; the fixture is a real git repository")
    else:
      withScenario:
        let checkout = scratch / ProducerRepo
        let (older, pinned) = initProducer(checkout)
        discard gitOut(checkout, "branch", "-q", "stale", older)
        discard gitOut(checkout, "checkout", "-q", "stale")
        discard gitOut(checkout, "pack-refs", "--all")
        check not fileExists(checkout / ".git" / "refs" / "heads" / "stale")
        check checkoutHeadRevision(checkout) == older
        let lockPath = scratch / "repro.lock"
        writeLock(lockPath, {Ruby: LockedVersion, ProducerPackage: "0.1.0"})
        governWith(lockPath, checkout, pinned)
        registerSolverDependency(ProducerPackage, Ruby,
          Ruby & " " & ProducerRange, declarationSite = sdsSiblingRecipe,
          declarationFile = checkout / "repro.nim")
        let message = conflictMessage()
        checkpoint(message)
        check older in message
        check "checkout --detach " & pinned in message

  test "a linked worktree's HEAD is read through its gitdir and commondir":
    # The issue's build ran in a linked worktree layout; a producer checkout
    # placed with `git worktree add` keeps HEAD in its own git dir and its
    # refs in the main repository's.
    if findExe("git").len == 0:
      skip("git not on PATH; the fixture is a real git repository")
    else:
      withScenario:
        let main = scratch / "main-clone"
        let (older, pinned) = initProducer(main)
        let worktree = scratch / ProducerRepo
        discard gitOut(main, "worktree", "add", "-q", "-b", "wt", worktree,
          older)
        check fileExists(worktree / ".git")
        check checkoutHeadRevision(worktree) == older
        discard gitOut(worktree, "checkout", "-q", "--detach", pinned)
        check checkoutHeadRevision(worktree) == pinned

  test "control: a checkout AT its pin is not called stale":
    if findExe("git").len == 0:
      skip("git not on PATH; the fixture is a real git repository")
    else:
      withScenario:
        let checkout = scratch / ProducerRepo
        let (_, pinned) = initProducer(checkout)
        # The checkout is at the pin, and the range is registered anyway (the
        # pinned revision declares it too): the conflict is the lock's, and
        # the message keeps its targeted re-pin as the first remedy.
        let lockPath = scratch / "repro.lock"
        writeLock(lockPath, {Ruby: LockedVersion, ProducerPackage: "0.1.0"})
        governWith(lockPath, checkout, pinned)
        registerSolverDependency(ProducerPackage, Ruby,
          Ruby & " " & ProducerRange, declarationSite = sdsSiblingRecipe,
          declarationFile = checkout / "repro.nim")
        let message = conflictMessage()
        checkpoint(message)
        check message.len > 0
        check RepinRemedy in message
        check "cross-repo producer" in message
        check "checkout --detach" notin message
        check "does not show the lock is wrong" notin message

  test "control: the project's own package never consults the checkouts":
    if findExe("git").len == 0:
      skip("git not on PATH; the fixture is a real git repository")
    else:
      withScenario:
        let checkout = scratch / ProducerRepo
        let (older, pinned) = initProducer(checkout)
        discard gitOut(checkout, "checkout", "-q", "--detach", older)
        let lockPath = scratch / "repro.lock"
        writeLock(lockPath, {Ruby: LockedVersion, Consumer: "0.1.0"})
        governWith(lockPath, checkout, pinned)
        registerSolverDependency(Consumer, Ruby, Ruby & " " & ProducerRange,
          declarationSite = sdsRootRecipe)
        let message = conflictMessage()
        checkpoint(message)
        check message.len > 0
        check RepinRemedy in message
        check "checkout --detach" notin message

  test "control: an unreadable checkout claims nothing":
    withScenario:
      let checkout = scratch / ProducerRepo
      createDir(checkout)  # no .git at all
      let lockPath = scratch / "repro.lock"
      writeLock(lockPath, {Ruby: LockedVersion, ProducerPackage: "0.1.0"})
      governWith(lockPath, checkout, "0123456789abcdef0123456789abcdef01234567")
      registerSolverDependency(ProducerPackage, Ruby,
        Ruby & " " & ProducerRange, declarationSite = sdsSiblingRecipe,
        declarationFile = checkout / "repro.nim")
      let message = conflictMessage()
      checkpoint(message)
      check message.len > 0
      check RepinRemedy in message
      check "checkout --detach" notin message

  test "control: a recipe read from outside every checkout claims nothing":
    # The declaring recipe's file is known and lies under none of the
    # checkouts (a develop override's tree, say), so a checkout that merely
    # shares the producer's name is not the tree the range came from, however
    # far behind its pin it is.
    if findExe("git").len == 0:
      skip("git not on PATH; the fixture is a real git repository")
    else:
      withScenario:
        let checkout = scratch / ProducerRepo
        let (older, pinned) = initProducer(checkout)
        discard gitOut(checkout, "checkout", "-q", "--detach", older)
        let elsewhere = scratch / "elsewhere"
        createDir(elsewhere)
        writeFile(elsewhere / "repro.nim", "uses: \"ruby " & ProducerRange &
          "\"\n")
        let lockPath = scratch / "repro.lock"
        # The package is named like the repository, so a name match WOULD
        # find the stale checkout.
        let namedLikeRepo = ProducerRepo.replace('-', '_')
        writeLock(lockPath, {Ruby: LockedVersion, namedLikeRepo: "0.1.0"})
        governWith(lockPath, checkout, pinned)
        registerSolverDependency(namedLikeRepo, Ruby,
          Ruby & " " & ProducerRange, declarationSite = sdsSiblingRecipe,
          declarationFile = elsewhere / "repro.nim")
        let message = conflictMessage()
        checkpoint(message)
        check message.len > 0
        check RepinRemedy in message
        check "checkout --detach" notin message
        check older notin message

  test "control: a pin that is not an object id is not compared":
    if findExe("git").len == 0:
      skip("git not on PATH; the fixture is a real git repository")
    else:
      withScenario:
        let checkout = scratch / ProducerRepo
        discard initProducer(checkout)
        let lockPath = scratch / "repro.lock"
        writeLock(lockPath, {Ruby: LockedVersion, ProducerPackage: "0.1.0"})
        governWith(lockPath, checkout, "main")
        registerSolverDependency(ProducerPackage, Ruby,
          Ruby & " " & ProducerRange, declarationSite = sdsSiblingRecipe,
          declarationFile = checkout / "repro.nim")
        let message = conflictMessage()
        checkpoint(message)
        check message.len > 0
        check RepinRemedy in message
        check "checkout --detach" notin message

  test "the hand-off grammar round-trips and drops unrepresentable entries":
    let entries = [
      LockProducerCheckout(name: "b", checkoutDir: "/w/b,with comma",
        pinnedRevision: "bbbb"),
      LockProducerCheckout(name: "a", checkoutDir: "/w/a",
        pinnedRevision: "aaaa"),
      LockProducerCheckout(name: "c", checkoutDir: "/w/c\tbad",
        pinnedRevision: "cccc")]
    let rendered = renderLockProducerCheckouts(entries)
    let parsed = parseLockProducerCheckouts(rendered)
    check parsed.len == 2
    check parsed[0].name == "a"
    check parsed[1].checkoutDir == "/w/b,with comma"
    check parseLockProducerCheckouts("garbage\n\tx\t\n").len == 0
