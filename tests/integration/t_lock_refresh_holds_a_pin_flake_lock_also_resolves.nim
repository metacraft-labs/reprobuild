## `repro lock refresh` does not write a `repro.lock` that disagrees with the
## `flake.lock` resolving the same repository, and the pre-push gate's
## sibling-pin refusal names the command that clears it
## (Unified-Locking-And-Hooks.md §16.3 H2 / H3, "The explicit refresh").
##
## WHY. `repro lock refresh` re-pins every sibling to its checkout and writes
## `repro.lock` alone. For a repository both locks resolve, that wrote a state
## the push gate then refused (`cross_lock_revision_disagreement`, H2), while
## the gate's own sibling-pin refusal (`committed_lock_sibling_pin_stale`)
## named `repro lock refresh` as the remedy: a refusal whose remedy
## produced the next refusal. The commit hook held such a repository in both
## locks ("moved in NEITHER", H3); the explicit verb did not.
##
## Fixture: the NF-2 workspace (`nf2_flake_lock_fixture.nim`) with a committed
## `repro.lock` beside its `flake.lock`; `beta` is resolved by both
## (`beta` / `beta-src`), `epsilon` by `repro.lock` alone.
##
## Cases (all through the built `repro`):
##   * `beta` and `epsilon` move ahead and are published. `repro lock refresh`
##     exits 0, writes `epsilon`'s new pin, keeps `beta` at the pin it had,
##     leaves `flake.lock` byte-identical and says, on stderr, that `beta` was
##     moved in neither lock and which command moves both.
##   * The pre-push gate then refuses the stale `beta` pin and its remediation
##     names `repro lock update beta`, not `repro lock refresh`, for that
##     repository; the refreshed `repro.lock` carries no H2 disagreement
##     (`cross_lock_revision_disagreement` is absent).
##
## Falsifiability: before the change the refresh writes `beta`'s new pin (first
## case: `beta` moves, no warning) and the remediation names `repro lock
## refresh` (second case).
##
## NO MOCKS: real repositories, real bare origins, real lock documents, the
## built `repro`.

import std/[json, os, strutils, unittest]

import hl11_two_lock_fixture
import repro_lock/identity
import repro_test_support/reasoned_skip

proc appLock(fx: Nf2Fixture; betaRev, epsilonRev: string): string =
  reproLockText(fx, "app", headOf(fx, fx.app), [
    lockDepEntry(fx, "alpha", "../alpha", "alpha", fx.seedSha[0]),
    lockDepEntry(fx, "beta", "../beta", "beta", betaRev),
    lockDepEntry(fx, "epsilon", "../epsilon", "epsilon", epsilonRev)])

suite "repro lock refresh holds a pin flake.lock also resolves":

  test "t_lock_refresh_holds_a_pin_flake_lock_also_resolves":
    if not nf3Prerequisites("t_lock_refresh_holds_a_pin_flake_lock_also_resolves"):
      skip("needs git on PATH and a built ./build/bin/repro (named above)")
    else:
      let catalog = getEnv("REPROBUILD_PACKAGES_ROOT",
        parentDir(getCurrentDir()) / "reprobuild-packages")
      if not dirExists(catalog) or findExe("nim").len == 0:
        echo "SKIPPED (loudly): needs nim on PATH and a reprobuild-packages " &
          "checkout (REPROBUILD_PACKAGES_ROOT); catalog=" & catalog
        skip("nim or the reprobuild-packages catalog is missing (named above)")
      putEnv("REPROBUILD_PACKAGES_ROOT", catalog)
      let fx = setupNf2Fixture("refresh-holds")
      defer: removeDir(fx.scratch)
      isolateNf2Config(fx)
      defer: releaseNf2Config()
      let betaSeed = fx.seedSha[1]
      let epsilonSeed = fx.seedSha[4]
      # A package with a real `nim.c` edge, so the solve has a package for the
      # targeted re-pin below to name (an empty solve has none). The plain
      # `nim` use resolves against the reprobuild-packages checkout.
      writeFile(fx.app / "repro.nim", """
import repro_project_dsl

package app:
  defaultToolProvisioning "path"
  uses:
    "nim >=1.6 <3.0"
  build:
    let main = nim.c(
      source = "src/app.nim",
      output = "build/app",
      actionId = "app.build.main",
      extraInputs = @["src"])
    discard collect("default", @[main])
""")
      createDir(fx.app / "src")
      writeFile(fx.app / "src" / "app.nim", "echo \"app\"\n")
      # Solved for THIS host's platform id, so the refresh is a full re-solve
      # and not the foreign-platform sibling re-pin (which already holds).
      writeFile(fx.app / "repro.lock", appLock(fx, betaSeed, epsilonSeed)
        .replace("platform = \"x86_64-linux\"",
                 "platform = \"" & currentPlatformId() & "\""))
      # One refresh at the seed moves no sibling and records the `nim` package
      # the targeted re-pin below names.
      let seedRefresh = run(q(fx.repro) & " lock refresh " & q(fx.app),
        cwd = fx.app)
      checkpoint(seedRefresh.output)
      check seedRefresh.code == 0
      publishAll(fx)
      commitLockAndPublish(fx, "app: locks at the seed")

      # Identity is the canonical repository URL, never the spelling: the lock
      # records `beta`'s origin as a plain URL and `flake.nix` declares the
      # same repository as `git+<url>?ref=main`, and the hold below only
      # happens because the two are recognised as one repository.
      let lockUrl = originUrl(fx, "beta")
      let flakeNix = readFile(fx.app / "flake.nix")
      check lockUrl in readFile(fx.app / "repro.lock")
      check ("git+" & lockUrl & "?ref=main") in flakeNix
      check ("url = \"" & lockUrl & "\"") notin flakeNix

      let betaNext = moveAndPublishSibling(fx, "beta", "beta moves")
      let epsilonNext = moveAndPublishSibling(fx, "epsilon", "epsilon moves")
      let flakeBefore = readFile(fx.app / "flake.lock")

      let refresh = run(q(fx.repro) & " lock refresh " & q(fx.app),
        cwd = fx.app)
      checkpoint(refresh.output)
      check refresh.code == 0
      let lock = readFile(fx.app / "repro.lock")
      # `epsilon` is resolved by repro.lock alone: it moves, as before.
      check reproLockRevisionOf(lock, "epsilon") == epsilonNext
      # `beta` is resolved by both locks and the verb writes only one.
      check reproLockRevisionOf(lock, "beta") == betaSeed
      check readFile(fx.app / "flake.lock") == flakeBefore
      check "moved in NEITHER" in refresh.output
      check "repro lock update beta" in refresh.output

      # A targeted re-pin carries sibling pins forward from the committed
      # lock, so `beta` stays too and `flake.lock` is untouched.
      let repin = run(q(fx.repro) & " lock refresh " & q(fx.app) &
        " --repin=nim", cwd = fx.app)
      checkpoint(repin.output)
      check repin.code == 0
      check reproLockRevisionOf(readFile(fx.app / "repro.lock"), "beta") ==
        betaSeed
      check readFile(fx.app / "flake.lock") == flakeBefore

      # The hold follows the lock the refresh writes, not only the committed
      # one: a refresh into another path (`--lock`) of a lock at the seed holds
      # `beta` as well.
      let otherLock = fx.scratch / "other.lock"
      writeFile(otherLock, appLock(fx, betaSeed, epsilonSeed)
        .replace("platform = \"x86_64-linux\"",
                 "platform = \"" & currentPlatformId() & "\""))
      let viaLock = run(q(fx.repro) & " lock refresh " & q(fx.app) &
        " --lock=" & q(otherLock), cwd = fx.app)
      checkpoint(viaLock.output)
      check viaLock.code == 0
      check reproLockRevisionOf(readFile(otherLock), "beta") == betaSeed
      check reproLockRevisionOf(readFile(otherLock), "epsilon") == epsilonNext

      # The gate still refuses the stale `beta` pin (the checkout is ahead of
      # it), but no longer through an H2 disagreement, and its remedy is the
      # command that moves both locks.
      commitLockAndPublish(fx, "app: refreshed")
      let gate = gatePrePush(fx)
      checkpoint(gate.output)
      check gate.code == 2
      check not hasGateFailure(gate.report, "cross_lock_revision_disagreement")
      let stale = gateFailureOf(gate.report, "committed_lock_sibling_pin_stale")
      check not stale.isNil
      if stale != nil:
        check betaNext in stale["evidence"].getStr()
        let remedy = stale["remediation"].getStr()
        check "repro lock update beta" in remedy
        check "run `repro lock refresh" notin remedy
