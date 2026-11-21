## A push through the local push gateway reports what the UPSTREAM did with it.
##
## The gateway forwards a push to the real upstream. When the upstream refuses
## that forward -- the everyday case of a teammate having pushed first -- the
## developer's ``git push`` must fail, the gateway must not record the refused
## ref as published, and nothing may land upstream. A forward run after the
## gateway accepted (from ``post-receive``) cannot do this: git ignores a
## ``post-receive`` exit status, so the push reported success while nothing
## reached the upstream.
##
## Cases (each against real bares, the real installed hooks and the real
## ``repro`` binary; no network):
##
##   - ``accepted_forward_publishes_and_the_gateway_keeps_its_ref`` -- two
##     pushes in a row: each exits 0 and lands upstream, and the SECOND is
##     reported by git as a fast-forward of the gateway's existing ref
##     (``old..new``), not as ``[new branch]``. That is the observable form of
##     "the gateway kept the ref it published": a gateway that pruned it after
##     each forward hands every push ``<old> = 0000...`` and git prints
##     ``[new branch]`` every time.
##   - ``upstream_refusal_fails_the_push_and_names_the_upstream`` -- the
##     upstream moved under the developer (a direct push from another clone).
##     The push through the gateway exits non-zero, the message names the
##     repository that refused, the upstream still holds the other clone's
##     commit, and the gateway's ref did not move.
##   - ``partial_refusal_leaves_the_upstream_untouched`` -- one push of two
##     refs, one of which the upstream refuses. The push fails and the
##     upstream holds NEITHER: the ref it would have accepted was not applied
##     either, so "rejected" means rejected.
##   - ``upstream_receive_side_never_borrows_the_gateways_objects`` -- the
##     forward reads the gateway's quarantine (and the gateway's own object
##     store, which git names alongside it) through a read-only alternate. On
##     a local-path upstream the receiving ``git receive-pack`` is a child of
##     that forward; were it to inherit the alternate, its connectivity check
##     could be satisfied by objects that exist only in the gateway, and it
##     would advertise the gateway's refs as ``.have`` so the sender omits
##     them. The case makes that observable: the upstream loses a commit the
##     gateway still holds, the next push builds on it, and the upstream must
##     end up self-contained (it received the commit again), and its
##     ``pre-receive`` must see no path inside the gateway.
##
## Test doubles: none.
##
## Skip rule: ``git`` missing on PATH.

import std/[os, osproc, strutils, tempfiles, unittest]

import repro_test_support
import repro_test_support/reasoned_skip
import repro_cli_support

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
  gitBin, scratch, reproBin, upstream, gateway, clone, other: string

proc gitC(fx: Fixture; repo: string; args: string): string =
  must(q(fx.gitBin) & " -C " & q(repo) & " " & args)

proc tip(fx: Fixture; repo, refName: string): string =
  sh(q(fx.gitBin) & " -C " & q(repo) & " rev-parse --verify -q " &
    refName).output

proc newClone(fx: Fixture; dest: string) =
  discard must(q(fx.gitBin) & " clone -q " & q(fileUrl(fx.upstream)) & " " &
    q(dest))
  discard gitC(fx, dest, "config user.email t@example.invalid")
  discard gitC(fx, dest, "config user.name T")

proc commit(fx: Fixture; repo, body: string): string =
  writeFile(repo / "f.txt", body)
  discard gitC(fx, repo, "add f.txt")
  discard gitC(fx, repo, "commit -q -m " & q(body))
  gitC(fx, repo, "rev-parse HEAD")

proc setup(gitBin, slug: string): Fixture =
  result.gitBin = gitBin
  result.scratch = createTempDir("repro-pg3-" & slug & "-", "")
  result.reproBin = reproBinary()
  result.upstream = result.scratch / "upstream.git"
  result.gateway = result.scratch / "gateway.git"
  result.clone = result.scratch / "clone"
  result.other = result.scratch / "other"
  discard must(q(gitBin) & " init -q --bare -b main " & q(result.upstream))
  let seed = result.scratch / "seed"
  discard must(q(gitBin) & " init -q -b main " & q(seed))
  discard must(q(gitBin) & " -C " & q(seed) &
    " config user.email t@example.invalid")
  discard must(q(gitBin) & " -C " & q(seed) & " config user.name T")
  writeFile(seed / "f.txt", "seed\n")
  discard must(q(gitBin) & " -C " & q(seed) & " add f.txt")
  discard must(q(gitBin) & " -C " & q(seed) & " commit -q -m seed")
  discard must(q(gitBin) & " -C " & q(seed) & " branch side")
  discard must(q(gitBin) & " -C " & q(seed) & " push -q " &
    q(result.upstream) & " main side")
  newClone(result, result.clone)
  newClone(result, result.other)
  let wired = wirePushGateway(gitBin, result.clone, result.gateway,
    fileUrl(result.upstream), GatewayConfig())
  doAssert wired.ok, wired.diagnostic

proc pushThroughGateway(fx: Fixture; refspecs: varargs[string]):
    tuple[code: int; output: string] =
  var argv = @[fx.gitBin, "-C", fx.clone, "push", "origin"]
  for r in refspecs:
    argv.add(r)
  runShell(shellCommand(argv,
    @[(name: "REPROBUILD_REPRO", value: fx.reproBin)]))

suite "push gateway forward outcome":

  test "accepted_forward_publishes_and_the_gateway_keeps_its_ref":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git is not on PATH")
    else:
      let fx = setup(gitBin, "accept")
      defer: removeDir(fx.scratch)
      let first = commit(fx, fx.clone, "one")
      let p1 = pushThroughGateway(fx, "main")
      checkpoint("push 1: " & p1.output)
      check p1.code == 0
      check tip(fx, fx.upstream, "refs/heads/main") == first
      check tip(fx, fx.gateway, "refs/heads/main") == first

      let second = commit(fx, fx.clone, "two")
      let p2 = pushThroughGateway(fx, "main")
      checkpoint("push 2: " & p2.output)
      check p2.code == 0
      check tip(fx, fx.upstream, "refs/heads/main") == second
      check tip(fx, fx.gateway, "refs/heads/main") == second
      # The gateway still held ``main`` when push 2 arrived, so git reports a
      # fast-forward from it rather than a new branch.
      check (first[0 ..< 7] & "..") in p2.output
      check "[new branch]" notin p2.output

  test "upstream_refusal_fails_the_push_and_names_the_upstream":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git is not on PATH")
    else:
      let fx = setup(gitBin, "reject")
      defer: removeDir(fx.scratch)
      let base = commit(fx, fx.clone, "mine-1")
      check pushThroughGateway(fx, "main").code == 0
      check tip(fx, fx.gateway, "refs/heads/main") == base
      # A teammate publishes first, directly upstream.
      discard gitC(fx, fx.other, "pull -q --ff-only")
      let theirs = commit(fx, fx.other, "theirs")
      discard gitC(fx, fx.other, "push -q origin main")
      let mine = commit(fx, fx.clone, "mine-2")

      let p = pushThroughGateway(fx, "main")
      checkpoint("push: " & p.output)
      check p.code != 0
      check fx.upstream in p.output
      check tip(fx, fx.upstream, "refs/heads/main") == theirs
      check tip(fx, fx.gateway, "refs/heads/main") == base
      check tip(fx, fx.gateway, "refs/heads/main") != mine

  test "partial_refusal_leaves_the_upstream_untouched":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git is not on PATH")
    else:
      let fx = setup(gitBin, "atomic")
      defer: removeDir(fx.scratch)
      let mainBefore = tip(fx, fx.upstream, "refs/heads/main")
      # ``side`` moves upstream under the developer; ``main`` does not.
      discard gitC(fx, fx.other, "checkout -q side")
      let theirs = commit(fx, fx.other, "theirs-side")
      discard gitC(fx, fx.other, "push -q origin side")
      let mainNew = commit(fx, fx.clone, "main-change")
      discard gitC(fx, fx.clone, "checkout -q -b side origin/side")
      discard commit(fx, fx.clone, "my-side")

      let p = pushThroughGateway(fx, "main", "side")
      checkpoint("push: " & p.output)
      check p.code != 0
      # ``main`` alone would have been accepted. It must not be upstream.
      check tip(fx, fx.upstream, "refs/heads/main") == mainBefore
      check tip(fx, fx.upstream, "refs/heads/main") != mainNew
      check tip(fx, fx.upstream, "refs/heads/side") == theirs
      check tip(fx, fx.gateway, "refs/heads/main") == ""

  test "upstream_receive_side_never_borrows_the_gateways_objects":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git is not on PATH")
    else:
      let fx = setup(gitBin, "selfcontained")
      defer: removeDir(fx.scratch)
      let seedTip = tip(fx, fx.upstream, "refs/heads/main")
      let first = commit(fx, fx.clone, "kept-by-the-gateway")
      check pushThroughGateway(fx, "main").code == 0
      check tip(fx, fx.gateway, "refs/heads/main") == first
      # The upstream forgets ``first`` (a rewind plus an aggressive prune);
      # the gateway still holds it, in its own object store.
      discard gitC(fx, fx.upstream, "update-ref refs/heads/main " & seedTip)
      discard gitC(fx, fx.upstream, "reflog expire --expire=now --all")
      discard gitC(fx, fx.upstream, "gc -q --prune=now")
      check sh(q(fx.gitBin) & " -C " & q(fx.upstream) & " cat-file -e " &
        first & "^{commit}").code != 0
      # Record what the upstream's receive side sees.
      let envLog = fx.scratch / "upstream-hook-env.txt"
      let hook = fx.upstream / "hooks" / "pre-receive"
      writeFile(hook, "#!/bin/sh\n" &
        "printf 'ALT=%s\\nOBJ=%s\\n' " &
        "\"$GIT_ALTERNATE_OBJECT_DIRECTORIES\" \"$GIT_OBJECT_DIRECTORY\" > " &
        q(envLog) & "\n")
      setFilePermissions(hook, {fpUserRead, fpUserWrite, fpUserExec})

      let second = commit(fx, fx.clone, "builds-on-it")
      let p = pushThroughGateway(fx, "main")
      checkpoint("push: " & p.output)
      check p.code == 0
      check tip(fx, fx.upstream, "refs/heads/main") == second
      let seen = readFile(envLog)
      checkpoint("upstream pre-receive env:\n" & seen)
      check fx.gateway notin seen
      # Self-contained: with no inherited environment the upstream has every
      # object it now references, ``first`` included.
      let gatewayReal = expandFilename(fx.gateway)
      check gatewayReal notin seen
      check sh(q(fx.gitBin) & " -C " & q(fx.upstream) & " cat-file -e " &
        first & "^{commit}").code == 0
      let fsck = sh(q(fx.gitBin) & " -C " & q(fx.upstream) &
        " fsck --connectivity-only --no-dangling")
      checkpoint("fsck: " & fsck.output)
      check fsck.code == 0
