## A push gateway borrows the shared clone pool's objects; it does not hold a
## second copy of the repository's history.
##
## Each workspace gets its own gateway per upstream, so a gateway that copied
## history would cost one full repository per (workspace, upstream). Wiring
## therefore points the gateway's ``objects/info/alternates`` at the pool and
## seeds its branches from the pool's.
##
## Cases (real ``git``, real bares, the real installed gateway hooks and the
## real ``repro`` binary; the "upstream" is a local bare):
##
##   - ``gateway_holds_no_history_and_a_push_sends_only_new_objects`` -- after
##     ``ensureGatewayForRepo`` the gateway names the pool as its alternate,
##     holds no pack of its own, carries the pool's ``main``, and the first push
##     of one new commit over a long history transfers exactly that commit's
##     three objects. A gateway that does not borrow makes the client send the
##     whole history.
##   - ``kept_gateway_ref_saves_objects_once_the_pool_falls_behind`` -- the
##     reason a gateway KEEPS its published refs. After a push the pool is
##     behind the upstream (nothing refreshed it); a second push is compared
##     between a gateway that kept its ``main`` and one whose ``main`` was
##     deleted. The one that kept it receives fewer objects. A first push into a
##     fresh gateway cannot show this -- its anchor is the pool either way --
##     which is why the case is the second push.
##
## Test doubles: none.
##
## Skip rule: ``git`` missing on PATH.

import std/[os, osproc, re, strutils, tempfiles, unittest]

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

proc reproBinary(): string =
  let root = currentSourcePath().parentDir.parentDir.parentDir
  requireBinary(root / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

type Fixture = object
  gitBin, scratch, reproBin, upstream, ws, clone, cacheRoot: string
  gateway, pool: string

proc g(fx: Fixture; repo, args: string): string =
  must(q(fx.gitBin) & " -C " & q(repo) & " " & args)

proc commit(fx: Fixture; repo, body: string): string =
  writeFile(repo / "f.txt", body)
  discard g(fx, repo, "add f.txt")
  discard g(fx, repo, "commit -q -m " & q(body))
  g(fx, repo, "rev-parse HEAD")

proc setup(gitBin, slug: string; history = 60): Fixture =
  result.gitBin = gitBin
  result.scratch = createTempDir("repro-pg4-" & slug & "-", "")
  result.reproBin = reproBinary()
  result.upstream = result.scratch / "upstream.git"
  result.ws = result.scratch / "ws"
  result.clone = result.ws / "lib"
  result.cacheRoot = result.scratch / "cache" / "clones"
  discard must(q(gitBin) & " init -q --bare -b main " & q(result.upstream))
  let seed = result.scratch / "seed"
  discard must(q(gitBin) & " init -q -b main " & q(seed))
  discard must(q(gitBin) & " -C " & q(seed) &
    " config user.email t@example.invalid")
  discard must(q(gitBin) & " -C " & q(seed) & " config user.name T")
  for i in 1 .. history:
    writeFile(seed / "f.txt", "history " & $i & "\n")
    writeFile(seed / ("h" & $i & ".txt"), $i & "\n")
    discard must(q(gitBin) & " -C " & q(seed) & " add -A")
    discard must(q(gitBin) & " -C " & q(seed) & " commit -q -m h" & $i)
  discard must(q(gitBin) & " -C " & q(seed) & " push -q " &
    q(result.upstream) & " main")
  createDir(result.ws)
  discard must(q(gitBin) & " clone -q " & q(fileUrl(result.upstream)) & " " &
    q(result.clone))
  discard must(q(gitBin) & " -C " & q(result.clone) &
    " config user.email t@example.invalid")
  discard must(q(gitBin) & " -C " & q(result.clone) & " config user.name T")
  let wired = ensureGatewayForRepo(gitBin, result.ws, "lib", result.clone,
    result.cacheRoot)
  checkpoint("wire: " & $wired.outcome & " " & wired.diagnostic)
  doAssert wired.outcome == gwoWired
  result.gateway = wired.gatewayDir
  result.pool = sharedBarePath(result.cacheRoot, fileUrl(result.upstream))

proc push(fx: Fixture): tuple[code: int; output: string; sent: int] =
  ## Push ``main`` through the gateway; ``sent`` is the object count git
  ## reports writing (-1 when it wrote no pack).
  let res = runShell(shellCommand(@[fx.gitBin, "-C", fx.clone, "push",
    "--progress", "origin", "main"],
    @[(name: "REPROBUILD_REPRO", value: fx.reproBin)]))
  var sent = -1
  var m: array[1, string]
  for line in res.output.split({'\r', '\n'}):
    if line.find(re"Writing objects: 100% \((\d+)/", m) >= 0:
      sent = parseInt(m[0])
  (res.code, res.output, sent)

proc ownPacks(gateway: string): int =
  for kind, path in walkDir(gateway / "objects" / "pack"):
    if path.endsWith(".pack"):
      inc result

suite "push gateway borrows the shared pool":

  test "gateway_holds_no_history_and_a_push_sends_only_new_objects":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git is not on PATH")
    else:
      let fx = setup(gitBin, "borrow")
      defer: removeDir(fx.scratch)
      check readAlternates(fx.gateway).len == 1
      check readAlternates(fx.gateway)[0] == fx.pool / "objects"
      check ownPacks(fx.gateway) == 0
      check g(fx, fx.gateway, "rev-parse refs/heads/main") ==
        g(fx, fx.pool, "rev-parse refs/heads/main")
      # The pool knows the gateway borrows from it.
      check fx.gateway in readBorrowers(fx.pool).join("\n")

      let tip = commit(fx, fx.clone, "new work")
      let p = push(fx)
      checkpoint("push: " & p.output)
      check p.code == 0
      check p.sent == 3
      check g(fx, fx.upstream, "rev-parse refs/heads/main") == tip

  test "kept_gateway_ref_saves_objects_once_the_pool_falls_behind":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git is not on PATH")
    else:
      var sentKept, sentDeleted = 0
      for variant in ["kept", "deleted"]:
        let fx = setup(gitBin, variant, history = 30)
        defer: removeDir(fx.scratch)
        discard commit(fx, fx.clone, "n1")
        discard commit(fx, fx.clone, "n2")
        check push(fx).code == 0
        # The upstream moved; the pool did not (nothing refreshed it).
        check g(fx, fx.pool, "rev-parse refs/heads/main") !=
          g(fx, fx.upstream, "rev-parse refs/heads/main")
        if variant == "deleted":
          discard g(fx, fx.gateway, "update-ref -d refs/heads/main")
        discard commit(fx, fx.clone, "n3")
        let p = push(fx)
        checkpoint(variant & " push: " & p.output)
        check p.code == 0
        if variant == "kept": sentKept = p.sent
        else: sentDeleted = p.sent
      checkpoint("kept=" & $sentKept & " deleted=" & $sentDeleted)
      check sentKept == 3
      check sentKept < sentDeleted
