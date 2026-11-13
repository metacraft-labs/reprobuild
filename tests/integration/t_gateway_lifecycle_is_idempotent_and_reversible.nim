## Wiring a checkout to its push gateway can be repeated and undone, and never
## takes a push URL that is not its own.
##
## Cases (real ``git``, real bares; no ``repro`` binary is needed because no
## push is made):
##
##   - ``rewiring_is_a_no_op`` -- a second ``ensureGatewayForRepo`` reports
##     ``already wired`` and leaves every file in the gateway as it was.
##   - ``a_missing_gateway_is_rebuilt_not_reported_as_wired`` -- the push URL
##     still names the gateway but the gateway directory is gone (deleted by
##     hand, or by a cache wipe). Every push would fail, so wiring rebuilds it
##     instead of answering ``already wired``.
##   - ``unwire_restores_the_direct_push_and_is_idempotent`` -- ``unwire``
##     leaves ``remote.origin.pushurl`` UNSET, deletes the gateway, keeps the
##     pool, and a second ``unwire`` changes nothing.
##   - ``a_foreign_push_url_is_never_taken_or_removed`` -- a developer's own
##     mirror in ``remote.origin.pushurl`` is reported as foreign by wiring and
##     by unwiring, and survives both byte for byte.
##
## Test doubles: none.
##
## Skip rule: ``git`` missing on PATH.

import std/[algorithm, os, osproc, strutils, tempfiles, times, unittest]

import repro_test_support
import repro_test_support/reasoned_skip
import repro_cli_support
import shared_clones

proc q(value: string): string = quoteShell(value)

proc sh(command: string): tuple[code: int; output: string] =
  let res = execCmdEx(command)
  (code: res.exitCode, output: res.output.strip())

proc must(command: string): string =
  let res = sh(command)
  if res.code != 0:
    checkpoint("command failed: " & command & "\n" & res.output)
  doAssert res.code == 0, "fixture command failed: " & command
  res.output

type Fixture = object
  gitBin, scratch, upstream, ws, clone, cacheRoot: string

proc setup(gitBin, slug: string): Fixture =
  result.gitBin = gitBin
  result.scratch = createTempDir("repro-pg4-life-" & slug & "-", "")
  result.upstream = result.scratch / "upstream.git"
  result.ws = result.scratch / "ws"
  result.clone = result.ws / "lib"
  result.cacheRoot = result.scratch / "cache" / "clones"
  discard must(q(gitBin) & " init -q --bare -b main " & q(result.upstream))
  let seed = result.scratch / "seed"
  discard must(q(gitBin) & " init -q -b main " & q(seed))
  discard must(q(gitBin) & " -C " & q(seed) &
    " -c user.email=t@example.invalid -c user.name=T commit -q " &
    "--allow-empty -m seed")
  discard must(q(gitBin) & " -C " & q(seed) & " push -q " &
    q(result.upstream) & " main")
  createDir(result.ws)
  discard must(q(gitBin) & " clone -q " & q(fileUrl(result.upstream)) & " " &
    q(result.clone))

proc pushurl(fx: Fixture): string =
  sh(q(fx.gitBin) & " -C " & q(fx.clone) &
    " config --get remote.origin.pushurl").output

proc snapshot(dir: string): seq[string] =
  ## Every file under ``dir`` with its size and mtime.
  for path in walkDirRec(dir):
    result.add(path & " " & $getFileSize(path) & " " &
      $getLastModificationTime(path).toUnixFloat)
  result.sort()

proc wire(fx: Fixture): GatewayWireResult =
  ensureGatewayForRepo(fx.gitBin, fx.ws, "lib", fx.clone, fx.cacheRoot)

suite "push gateway lifecycle":

  test "rewiring_is_a_no_op":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git is not on PATH")
    else:
      let fx = setup(gitBin, "noop")
      defer: removeDir(fx.scratch)
      let first = wire(fx)
      check first.outcome == gwoWired
      check pushurl(fx) == absolutePath(first.gatewayDir)
      let before = snapshot(first.gatewayDir)
      sleep(20)
      let second = wire(fx)
      check second.outcome == gwoAlreadyWired
      check snapshot(first.gatewayDir) == before

  test "a_missing_gateway_is_rebuilt_not_reported_as_wired":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git is not on PATH")
    else:
      let fx = setup(gitBin, "rebuild")
      defer: removeDir(fx.scratch)
      let first = wire(fx)
      check first.outcome == gwoWired
      removeDir(first.gatewayDir)
      let again = wire(fx)
      check again.outcome == gwoWired
      check gatewayIsComplete(first.gatewayDir)
      check pushurl(fx) == absolutePath(first.gatewayDir)

  test "unwire_restores_the_direct_push_and_is_idempotent":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git is not on PATH")
    else:
      let fx = setup(gitBin, "unwire")
      defer: removeDir(fx.scratch)
      let wired = wire(fx)
      check wired.outcome == gwoWired
      let pool = sharedBarePath(fx.cacheRoot, fileUrl(fx.upstream))
      check dirExists(pool)
      let u1 = unwireGatewayForRepo(gitBin, fx.ws, fx.clone, fx.cacheRoot)
      check u1.outcome == guoUnwired
      check pushurl(fx) == ""
      check not dirExists(wired.gatewayDir)
      check dirExists(pool)
      let u2 = unwireGatewayForRepo(gitBin, fx.ws, fx.clone, fx.cacheRoot)
      check u2.outcome == guoNotWired
      check pushurl(fx) == ""

  test "a_foreign_push_url_is_never_taken_or_removed":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git is not on PATH")
    else:
      let fx = setup(gitBin, "foreign")
      defer: removeDir(fx.scratch)
      let mirror = fx.scratch / "my-mirror.git"
      discard must(q(gitBin) & " -C " & q(fx.clone) &
        " config remote.origin.pushurl " & q(mirror))
      let w = wire(fx)
      check w.outcome == gwoForeignPushurl
      check pushurl(fx) == mirror
      check not dirExists(w.gatewayDir)
      let u = unwireGatewayForRepo(gitBin, fx.ws, fx.clone, fx.cacheRoot)
      check u.outcome == guoForeignPushurl
      check pushurl(fx) == mirror
