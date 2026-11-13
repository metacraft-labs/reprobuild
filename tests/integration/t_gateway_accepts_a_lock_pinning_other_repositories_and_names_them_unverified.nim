## The push gateway's public-tier lock gate checks the entries of a pushed
## `repro.lock` that designate the PUSHED repository, and names every entry
## that pins another repository as NOT verified server-side
## (Unified-Locking-And-Hooks.md §6 Decision 3 and its boundary statement).
##
## WHY. A sibling's commit lives in the sibling's repository; it never reaches
## the gateway bare of the repository being pushed. A gate that demanded every
## `git-sha*` locked revision be present in the received objects refused every
## repository whose lock pins a sibling (`locked-integrity-mismatch`), whatever
## its certificates. The server makes no claim about content it cannot see:
## those entries are the client pre-push gate's, and the gateway says so
## instead of either refusing them or silently counting them as checked.
##
## Fixture: `committed_lock_siblings_fixture.nim` (a real manifest workspace,
## app -> lib-b -> lib-c, each a real repository with its own bare origin).
## The lock is written by the real `repro lock refresh`. The gateways are
## wired by `wirePushGateway` and run the REAL installed `pre-receive` hook,
## which runs the built `repro`.
##
## Cases:
##   1. app's committed lock pins lib-b and lib-c. A push through app's
##      gateway is ACCEPTED and forwarded; the gate reports it read the pushed
##      lock blob, checked exactly the one self entry, and names lib-b and
##      lib-c as not verified server-side. app's own entry is not so named.
##   2. The self entry pins a revision the push did not carry (a real commit,
##      but lib-b's): REFUSED with `locked-integrity-mismatch`.
##   3. Smuggling the self pin past the check: the same absent revision under
##      an entry that drops the `self` marker and spells app's URL differently,
##      and under an extra unmarked entry beside a valid self entry. Both name
##      the pushed repository, so both are checked and REFUSED, as is (3d)
##      the marker dropped with the URL's `.git` suffix removed. (3c) An
##      unmarked entry with lib-b's URL and revision but app's name cannot
##      alias the self entry at all: the lock does not parse.
##   4. A closure of two repositories, each behind its own gateway: lib-b is
##      advanced through lib-b's gateway, app's lock is refreshed to pin it,
##      and app is pushed through app's gateway. Both ACCEPTED; app's gateway
##      names lib-b as not verified server-side.
##   5. (second test) `repro push` publishes the closure lib-c -> lib-b -> app
##      with every repository behind its own gateway and the real managed
##      hooks installed; lib-b's and app's new commits are unpublished, and
##      app's lock pins lib-b's. Every push is accepted and lands on both the
##      gateway and the upstream. `repro push` keeps each gateway's report
##      under the member it judged: app's names the lock blob its gateway read
##      and lib-b and lib-c as not verified server-side.
##
## Falsifiability (observed): with the gate checking every `git-sha*` entry
## against the received objects again (the gate before this test), cases 1
## and 4 and the second test are REFUSED with `locked-integrity-mismatch`
## naming lib-b. With the identity match dropped (the `self` marker alone
## deciding), cases 3a and 3d are accepted and forwarded and case 3b is
## refused for the wrong entry.
##
## Hermetic: local repositories and bare remotes only; no network, no mocks.

import std/[os, strutils, unittest]

import repro_test_support
import repro_cli_support
import ./committed_lock_siblings_fixture

proc originOf(fx: SiblingFixture; name: string): string =
  for (n, origin) in fx.origins:
    if n == name: return origin
  doAssert false, "no origin for " & name

proc wireGateway(fx: SiblingFixture; name: string): string =
  ## Route `name`'s pushes through a fresh gateway bare forwarding to its
  ## origin; return the gateway's path.
  result = fx.scratch / ("gateway-" & name & ".git")
  let wired = wirePushGateway(fx.gitBin, fx.ws / name, result,
    fileUrl(fx.originOf(name)), GatewayConfig())
  doAssert wired.ok, wired.diagnostic

proc pushThroughGateway(fx: SiblingFixture; name: string):
    tuple[code: int; output: string] =
  ## `--no-verify`: no client gate runs, so whatever the output says is the
  ## gateway's own verdict.
  runCmd(q(fx.gitBin) & " -C " & q(fx.ws / name) &
    " push --no-verify origin main")

proc originHas(fx: SiblingFixture; name, sha: string): bool =
  runCmd(q(fx.gitBin) & " -C " & q(fx.originOf(name)) & " merge-base " &
    "--is-ancestor " & q(sha) & " refs/heads/main").code == 0

proc lockBlobAt(fx: SiblingFixture; commit: string): string =
  fx.git(fx.app, "rev-parse " & q(commit & ":repro.lock")).strip()

proc fieldOf(entry, key: string): string =
  ## The value of `key = "..."` inside one inline lock entry.
  let marker = key & " = \""
  let at = entry.find(marker)
  if at < 0: return ""
  let start = at + marker.len
  entry[start ..< entry.find('"', start)]

proc commitLockBody(fx: SiblingFixture; body: string): string =
  writeFile(fx.app / "repro.lock", body)
  discard fx.git(fx.app, "add repro.lock")
  discard fx.git(fx.app, "commit -q -m " & q("edit lock"))
  fx.headOf(fx.app)

proc memberReport(output, name: string): string =
  ## What `repro push` printed for closure member ``name``: its outcome line
  ## and the indented lines under it.
  var inside = false
  for line in output.splitLines():
    if line.startsWith("repro push: "):
      inside = ("(" & name & ") → ") in line
      if inside: result.add(line & "\n")
    elif inside and line.startsWith("    "):
      result.add(line & "\n")
    else:
      inside = false

proc unverifiedLine(name: string): string =
  "public-tier lock gate: '" & name & "' NOT verified server-side"

suite "gateway lock gate: entries pinning other repositories are named, " &
    "not refused":

  test "a lock pinning siblings is accepted and the siblings are named " &
      "unverified, while an absent or disguised self pin is refused":
    let fx = setupSiblingFixture("gateway-siblings")
    defer: removeDir(fx.scratch)
    # The gateway hook runs `repro` from REPROBUILD_REPRO: the built binary,
    # never a dev-shell one on PATH.
    putEnv("REPROBUILD_REPRO", fx.repro)
    defer: delEnv("REPROBUILD_REPRO")

    fx.refreshAndPublishLock()
    let lockBody = readFile(fx.app / "repro.lock")
    let selfEntry = depEntry(lockBody, ".")
    let libB = depEntry(lockBody, "lib-b")
    let libC = depEntry(lockBody, "lib-c")
    checkpoint("committed lock:\n" & lockBody)
    # The fixture must actually pin siblings, or case 1 proves nothing.
    doAssert selfEntry.len > 0 and libB.len > 0 and libC.len > 0,
      "the refreshed lock does not carry app, lib-b and lib-c"
    doAssert selfEntry.fieldOf("integrity").startsWith("git-sha") and
      libB.fieldOf("integrity").startsWith("git-sha") and
      libC.fieldOf("integrity").startsWith("git-sha"),
      "the fixture's entries carry no git-native integrity"
    let selfName = selfEntry.fieldOf("name")
    let selfRev = selfEntry.fieldOf("revision")
    let libBRev = libB.fieldOf("revision")
    doAssert libBRev == fx.headOf(fx.ws / "lib-b")

    discard fx.wireGateway("app")

    # ---- 1. siblings pinned: ACCEPTED, siblings named unverified ----------
    let tip = fx.headOf(fx.app)
    let accepted = fx.pushThroughGateway("app")
    checkpoint("case 1 push output:\n" & accepted.output)
    check accepted.code == 0
    check "locked-integrity-mismatch" notin accepted.output
    check ("read repro.lock blob " & fx.lockBlobAt(tip)) in accepted.output
    check "deps=3 integrity-checked=1 verdict=ACCEPTED" in accepted.output
    check unverifiedLine("lib-b") in accepted.output
    check unverifiedLine("lib-c") in accepted.output
    check "pins another repository" in accepted.output
    check unverifiedLine(selfName) notin accepted.output
    check fx.originHas("app", tip)

    # ---- 2. the self pin names a revision this push did not carry ---------
    # lib-b's HEAD is a real commit with a well-formed integrity; it is just
    # not app's. The gate must not mistake it for a sibling's pin.
    block selfPinAbsent:
      let forged = selfEntry.replace(selfRev, libBRev)
      let bad = fx.commitLockBody(lockBody.replace(selfEntry, forged))
      let refused = fx.pushThroughGateway("app")
      checkpoint("case 2 push output:\n" & refused.output)
      check refused.code != 0
      check "locked-integrity-mismatch" in refused.output
      check ("'" & selfName & "'") in refused.output
      check "of the pushed repository is not present" in refused.output
      check not fx.originHas("app", bad)
      discard fx.git(fx.app, "reset -q --hard " & q(tip))

    # ---- 3a. the self marker dropped, the URL spelled another way ---------
    block unmarkedSelf:
      let url = selfEntry.fieldOf("url")
      doAssert url.startsWith("file://"), "unexpected self url " & url
      # The plain path spells the same repository as its file:// URL.
      let disguised = selfEntry
        .replace("self = \"true\", ", "")
        .replace("url = \"" & url & "\"",
          "url = \"" & url["file://".len .. ^1] & "/\"")
        .replace(selfRev, libBRev)
      doAssert "self = " notin disguised
      let bad = fx.commitLockBody(lockBody.replace(selfEntry, disguised))
      let refused = fx.pushThroughGateway("app")
      checkpoint("case 3a push output:\n" & refused.output)
      check refused.code != 0
      check "locked-integrity-mismatch" in refused.output
      check "of the pushed repository is not present" in refused.output
      check not fx.originHas("app", bad)
      discard fx.git(fx.app, "reset -q --hard " & q(tip))

    # ---- 3b. a valid self entry plus an unmarked alias of it --------------
    block aliasBesideSelf:
      let url = selfEntry.fieldOf("url")
      let alias = selfEntry
        .replace("name = \"" & selfName & "\"", "name = \"app-alias\"")
        .replace("self = \"true\", ", "")
        .replace("url = \"" & url & "\"", "url = \"" & url & "/\"")
        .replace(selfRev, libBRev)
      let withAlias = lockBody.replace(selfEntry, selfEntry & ", " & alias)
      let bad = fx.commitLockBody(withAlias)
      let refused = fx.pushThroughGateway("app")
      checkpoint("case 3b push output:\n" & refused.output)
      check refused.code != 0
      check "locked-integrity-mismatch: 'app-alias'" in refused.output
      check not fx.originHas("app", bad)
      discard fx.git(fx.app, "reset -q --hard " & q(tip))

    # ---- 3c. the self entry's name on an entry that looks like lib-b's ----
    # lib-b's URL and lib-b's real revision, unmarked: only the name says it
    # is app. A name cannot alias the self entry: the lock does not parse.
    block selfNameOnSiblingShape:
      let impostor = libB
        .replace("name = \"" & libB.fieldOf("name") & "\"",
          "name = \"" & selfName & "\"")
      doAssert "self = " notin impostor and impostor != libB
      let bad = fx.commitLockBody(lockBody.replace(libB, libB & ", " &
        impostor))
      let refused = fx.pushThroughGateway("app")
      checkpoint("case 3c push output:\n" & refused.output)
      check refused.code != 0
      check ("lock-parse-failed: the pushed repro.lock does not parse " &
        "(duplicate locked dependency name '" & selfName & "')") in
        refused.output
      check not fx.originHas("app", bad)
      discard fx.git(fx.app, "reset -q --hard " & q(tip))

    # ---- 3d. the self marker dropped, the URL without its `.git` ----------
    block unmarkedSelfWithoutGitSuffix:
      let url = selfEntry.fieldOf("url")
      doAssert url.endsWith(".git"), "unexpected self url " & url
      let disguised = selfEntry
        .replace("self = \"true\", ", "")
        .replace("url = \"" & url & "\"",
          "url = \"" & url[0 ..< url.len - ".git".len] & "\"")
        .replace(selfRev, libBRev)
      let bad = fx.commitLockBody(lockBody.replace(selfEntry, disguised))
      let refused = fx.pushThroughGateway("app")
      checkpoint("case 3d push output:\n" & refused.output)
      check refused.code != 0
      check "locked-integrity-mismatch" in refused.output
      check "of the pushed repository is not present" in refused.output
      check not fx.originHas("app", bad)
      discard fx.git(fx.app, "reset -q --hard " & q(tip))

    # ---- 4. a closure of two repositories, each behind its gateway --------
    block closureThroughGateways:
      discard fx.wireGateway("lib-b")
      # `advance` pushes lib-b through its gateway (lib-b carries no lock:
      # nothing to gate, and it is forwarded).
      let newLibB = fx.advance("lib-b")
      check fx.originHas("lib-b", newLibB)
      let refreshed = runCmd(q(fx.repro) & " lock refresh " & q(fx.app))
      checkpoint(refreshed.output)
      check refreshed.code == 0
      discard fx.git(fx.app, "add repro.lock")
      discard fx.git(fx.app, "commit -q -m " & q("repin lib-b"))
      let repinned = fx.headOf(fx.app)
      check depEntry(readFile(fx.app / "repro.lock"), "lib-b")
        .fieldOf("revision") == newLibB
      let pushed = fx.pushThroughGateway("app")
      checkpoint("case 4 push output:\n" & pushed.output)
      check pushed.code == 0
      check "locked-integrity-mismatch" notin pushed.output
      check ("read repro.lock blob " & fx.lockBlobAt(repinned)) in
        pushed.output
      check unverifiedLine("lib-b") in pushed.output
      check fx.originHas("app", repinned)

  test "repro push publishes a closure through each repository's gateway " &
      "and the dependent's gateway accepts its lock pinning siblings":
    let fx = setupSiblingFixture("gateway-closure")
    defer: removeDir(fx.scratch)
    putEnv("REPROBUILD_REPRO", fx.repro)
    defer: delEnv("REPROBUILD_REPRO")

    fx.refreshAndPublishLock()
    for name in ["app", "lib-b", "lib-c"]:
      discard fx.wireGateway(name)
    let ensured = runCmd(q(fx.repro) & " hooks ensure --vcs " &
      q("--workspace-root=" & fx.ws))
    checkpoint("hooks ensure:\n" & ensured.output)
    check ensured.code == 0

    # An unpublished commit in lib-b, and app re-pinned to it, also
    # unpublished: the closure `repro push` must publish dependency first.
    let libB = fx.ws / "lib-b"
    writeFile(libB / "closure.txt", "closure\n")
    discard fx.git(libB, "add closure.txt")
    discard fx.git(libB, "commit -q -m closure")
    let newLibB = fx.headOf(libB)
    let refreshed = runCmd(q(fx.repro) & " lock refresh " & q(fx.app))
    checkpoint(refreshed.output)
    check refreshed.code == 0
    discard fx.git(fx.app, "add repro.lock")
    discard fx.git(fx.app, "commit -q -m " & q("repin lib-b"))
    let appTip = fx.headOf(fx.app)
    let committedLock = fx.git(fx.app, "show " & q(appTip & ":repro.lock"))
    check depEntry(committedLock, "lib-b").fieldOf("revision") == newLibB
    check not fx.originHas("lib-b", newLibB)

    let pushed = runCmd(q(fx.repro) & " push --no-certify " &
      q("--workspace-root=" & fx.ws) & " " & q("--current-repo=" & fx.app))
    checkpoint("repro push output:\n" & pushed.output)
    check pushed.code == 0
    check "locked-integrity-mismatch" notin pushed.output
    check fx.originHas("lib-b", newLibB)
    check fx.originHas("app", appTip)
    # They reached the upstreams THROUGH the gateways: each gateway's own
    # branch sits at the commit it accepted, which its pre-receive (the lock
    # gate included, reading app's lock that pins lib-b and lib-c) let in.
    proc gatewayTip(name: string): string =
      runCmd(q(fx.gitBin) & " -C " & q(fx.scratch / ("gateway-" & name &
        ".git")) & " rev-parse refs/heads/main").output.strip()
    check gatewayTip("lib-b") == newLibB
    check gatewayTip("app") == appTip
    # And `repro push` says what app's gateway reported, under app, without
    # git's `remote:` prefix: the lock blob it read, and the siblings it did
    # not verify.
    let appReport = memberReport(pushed.output, "app")
    checkpoint("app's report:\n" & appReport)
    check ("(app) → pushed") in appReport
    check ("    reprobuild gateway: refs/heads/main: public-tier lock gate: " &
      "read repro.lock blob " & fx.lockBlobAt(appTip)) in appReport
    check ("    reprobuild gateway: refs/heads/main: " &
      unverifiedLine("lib-b")) in appReport
    check ("    reprobuild gateway: refs/heads/main: " &
      unverifiedLine("lib-c")) in appReport
    check "remote: reprobuild gateway:" notin pushed.output
    # lib-b's push carries lib-b's own lock, which pins lib-c (lib-b's
    # repro.nim uses it; every repo whose recipe derives a dependency carries
    # the lock that records it, owner decision 2026-11-05). Its gateway
    # therefore names lib-c — and only lib-c — as not verified server-side:
    # each gateway reports on the lock of the repository it receives.
    let libBReport = memberReport(pushed.output, "lib-b")
    check "(lib-b) → pushed" in libBReport
    check ("    reprobuild gateway: refs/heads/main: " &
      unverifiedLine("lib-c")) in libBReport
    check unverifiedLine("lib-b") notin libBReport
    check unverifiedLine("app") notin libBReport
