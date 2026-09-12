## NF-3 shared fixture — the NF-2 workspace, plus the two things NF-3's
## consumers need from it: a PUBLISHED workspace (so the pre-push gate can be
## reached at all) and precise control over where each sibling stands relative
## to its `flake.lock` pin.
##
## Deliberately not a `t_*.nim` file, for the reason
## `nf2_flake_lock_fixture.nim` states: `scripts/generate_test_edges.nim` only
## discovers `t_*` / `test_*` stems, so this helper is never compiled as a test
## of its own.
##
## ## Test-double policy: NO mocks, doubles or fakes
##
## Everything below is the real thing, and this fixture adds no new script,
## stub or recorder to the ones `nf2_flake_lock_fixture.nim` already justifies
## in its own header:
##
##   * real bare git origins, real clones, real `git push` to those origins —
##     which is what makes the gate's "HEAD is published" stage pass honestly
##     rather than by being skipped;
##   * a real `flake.lock` in nix's on-disk format, rewritten through the same
##     `nf2FlakeLockText` the NF-2 cases use, so a pin is set by writing the
##     file nix writes rather than by patching an in-memory structure;
##   * the real `./build/bin/repro`, driven as a subprocess for both consumers
##     (`repro check --mode=pre-push` and `repro flake override-status`).
##
## The one thing NOT exercised end-to-end is `nix` itself: these cases assert
## on the REPORT and on the gate's refusal, which is what a developer and CI
## actually see. NF-2 already pins the nix-level half
## (`t_commit_records_the_sibling_revision_nix_resolves_to_it`,
## `t_a_refreshed_lock_does_not_churn_under_nix`).
##
## ## Why the pin is set by rewriting `flake.lock` rather than by committing
##
## `at`, `ahead by N` and `behind by N` have to be constructed exactly, and
## `behind` cannot be reached by moving a sibling forward at all — it needs a
## pin AHEAD of the checkout. `rewindSibling` produces it the way it occurs in
## the field: the sibling's history is created, the lock records it, and the
## checkout is then left at an older revision (a stale checkout, an aborted
## bisect, a `git checkout` of an older branch). The pinned commit stays in the
## sibling's object store, which is also true in the field and is what lets the
## report state the DISTANCE rather than only the disagreement.

import std/[json, os, strutils, unittest]

import nf2_flake_lock_fixture
export nf2_flake_lock_fixture

const ZeroSha* = "0000000000000000000000000000000000000000"

proc nf3Prerequisites*(caseName: string): bool =
  ## Same prerequisites as NF-2 (real `git`, a built `./build/bin/repro`), and
  ## the same LOUD announcement when they are missing.
  nf2Prerequisites(caseName)

proc publishRepo*(fx: Nf2Fixture; dir: string) =
  ## Push a checkout's HEAD to its origin, so the gate's stage-2
  ## ("HEAD is published") observation passes on it for real.
  discard gitIn(fx, dir, "push -q origin HEAD:main")

proc publishAll*(fx: Nf2Fixture) =
  for name in Nf2Repos:
    publishRepo(fx, fx.ws / name)

proc commitLockAndPublish*(fx: Nf2Fixture; message: string) =
  ## Commit whatever `flake.lock` currently says in `app` and publish it.
  ##
  ## The `pre-commit` dispatch is taken OUT first and put back afterwards: a
  ## case that is arranging a STALE lock must not have NF-2's refresh quietly
  ## repair it on the way in, which would leave the case asserting about a
  ## state it never reached.
  removePreCommitDispatch(fx)
  discard gitIn(fx, fx.app, "add -A")
  # `git commit` fails when the index matches HEAD, and "the lock already says
  # what this case needs" is a legitimate starting state (the fixture ships a
  # lock that names every sibling's seed revision). Committing only when there
  # is something to commit keeps the helper usable from both.
  if gitIn(fx, fx.app, "status --porcelain").strip().len > 0:
    discard gitIn(fx, fx.app, "commit -q -m " & q(message))
  publishRepo(fx, fx.app)
  installPreCommitDispatch(fx)

proc setFlakePins*(fx: Nf2Fixture; alphaRev, betaRev, gammaRev: string) =
  ## Rewrite `app/flake.lock` so alpha/beta/gamma are pinned exactly where the
  ## case needs them.
  writeFile(lockPath(fx), nf2FlakeLockText(fx, alphaRev, betaRev, gammaRev))

proc advanceSibling*(fx: Nf2Fixture; name: string; steps: int): string =
  ## Commit ``steps`` new revisions in a sibling checkout; returns its HEAD.
  for i in 1 .. steps:
    discard moveSibling(fx, name, "step-" & $i)
  headOf(fx, siblingDir(fx, name))

proc rewindSibling*(fx: Nf2Fixture; name: string; steps: int): string =
  ## Move the CHECKOUT back ``steps`` commits without discarding the objects,
  ## which is what leaves it BEHIND a pin that names the newer revision.
  discard gitIn(fx, siblingDir(fx, name), "reset --hard HEAD~" & $steps)
  headOf(fx, siblingDir(fx, name))

proc advanceOriginWithoutFetching*(fx: Nf2Fixture; name: string;
    steps: int): string =
  ## Add ``steps`` revisions to a sibling's ORIGIN, from a side clone, and leave
  ## ``ws/<name>`` completely untouched. Returns the origin's new tip.
  ##
  ## This is the state `rewindSibling` deliberately cannot produce, and the one
  ## the field kept producing: the checkout is genuinely BEHIND, but the pinned
  ## revision is **not in its object store**, so no distance can be computed
  ## from it and nothing local can say which direction the drift runs in. It
  ## arises from the ordinary sequence — a colleague pushes, the lock is
  ## refreshed on another machine or by CI, and this checkout has simply not
  ## fetched since.
  ##
  ## Measured in this workspace during the landing that motivated the fix:
  ## `io-mon` was really 5 commits behind its pin and was reported as `unknown`
  ## purely because the pinned revision had never been fetched.
  ##
  ## The side clone is REAL and is reused across calls, so a case can advance
  ## the same origin twice and get a linear history rather than two roots.
  let side = fx.scratch / ("side-" & name)
  if not dirExists(side):
    discard requireCmd(q(fx.gitBin) & " clone -q " & q(originUrl(fx, name)) &
      " " & q(side))
    discard requireCmd(q(fx.gitBin) & " -C " & q(side) &
      " config user.email tester@example.invalid")
    discard requireCmd(q(fx.gitBin) & " -C " & q(side) &
      " config user.name \"NF2 Tester\"")
  for i in 1 .. steps:
    # Distinct content per step, for the reason `seedOrigin` spells out: a
    # commit SHA hashes the tree as well as the message, and two steps with
    # identical content in the same clock second would collide.
    writeFile(side / "marker.txt", name & " unfetched step-" & $i & "\n")
    discard requireCmd(q(fx.gitBin) & " -C " & q(side) & " commit -q -a -m " &
      q("unfetched step-" & $i))
  discard requireCmd(q(fx.gitBin) & " -C " & q(side) & " push -q origin HEAD:main")
  requireCmd(q(fx.gitBin) & " -C " & q(side) & " rev-parse HEAD").strip()

proc pinIsFetched*(fx: Nf2Fixture; name, rev: string): bool =
  ## Is ``rev`` in ``ws/<name>``'s object store? Asked with git's own
  ## `cat-file -e`, which is the predicate the classifier uses, so a case can
  ## assert that its "not fetched" arrangement really is one rather than
  ## assuming it.
  run(q(fx.gitBin) & " -C " & q(siblingDir(fx, name)) & " cat-file -e " &
    rev & "^{commit}").code == 0

proc fourInputFlakeLockText*(fx: Nf2Fixture;
    alphaRev, betaRev, gammaRev, deltaRev: string): string =
  ## `nf2FlakeLockText` plus a fourth sibling input, `delta-src`.
  ##
  ## A separate generator rather than a parameter on the shared one: every other
  ## NF-2/NF-3 case asserts BYTE-identity against the three-input document, so a
  ## shared generator that grew a node would move those assertions' subject.
  ## `nixpkgs` keeps its deliberately odd member order and indent here too — it
  ## is the witness that only overridden nodes are rewritten.
  "{\n" &
  "  \"nodes\": {\n" &
  lockedNode("alpha-src", originUrl(fx, "alpha"), alphaRev,
    "sha256-fv2PzTwKsfeBptF8u/G0w9eh6GDsib/62l5cyuKNGYM=", "    ") & ",\n" &
  lockedNode("beta-src", originUrl(fx, "beta"), betaRev,
    "sha256-EZvvEKnc/QXEXlosW7OiNDncXiBneXs4liR/64D3A90=", "    ") & ",\n" &
  lockedNode("gamma-src", originUrl(fx, "gamma"), gammaRev,
    "sha256-8CsSWf5teLoXzC7ay1QzNPN9tP204vk496y/wq+S/Lc=", "    ") & ",\n" &
  lockedNode("delta-src", originUrl(fx, "delta"), deltaRev,
    "sha256-Xk1hEBS0wWJRPBBTFy1TgP1kOaGMmnFdW1F5vUlN5UM=", "    ") & ",\n" &
  "    \"flake-utils\": {\n" &
  "      \"locked\": {\n" &
  "        \"lastModified\": 1731533236,\n" &
  "        \"narHash\": \"sha256-l0KFg5HjrsfsO/JpG+r7fRrqm12kzFHyUHqHCVpMMbI=\",\n" &
  "        \"owner\": \"numtide\",\n" &
  "        \"repo\": \"flake-utils\",\n" &
  "        \"rev\": \"11707dc2f618dd54ca8739b309ec4fc024de578b\",\n" &
  "        \"type\": \"github\"\n" &
  "      },\n" &
  "      \"original\": { \"owner\": \"numtide\", \"repo\": \"flake-utils\", \"type\": \"github\" }\n" &
  "    },\n" &
  "        \"nixpkgs\": {\n" &
  "            \"locked\": {\n" &
  "                \"type\": \"github\",\n" &
  "                \"rev\": \"5e4fbfb6b3de1aa2872b76d49fafc942626e2add\",\n" &
  "                \"owner\": \"NixOS\",\n" &
  "                \"narHash\": \"sha256-OZiZ3m8SCMfh3B6bfGC/Bm4x3qc1m2SVEAlkV6iY7Yg=\",\n" &
  "                \"repo\": \"nixpkgs\",\n" &
  "                \"lastModified\": 1735563628\n" &
  "            },\n" &
  "            \"original\": {\n" &
  "                \"id\": \"nixpkgs\",\n" &
  "                \"type\": \"indirect\"\n" &
  "            }\n" &
  "        },\n" &
  "    \"root\": {\n" &
  "      \"inputs\": {\n" &
  "        \"alpha-src\": \"alpha-src\",\n" &
  "        \"beta-src\": \"beta-src\",\n" &
  "        \"delta-src\": \"delta-src\",\n" &
  "        \"flake-utils\": \"flake-utils\",\n" &
  "        \"gamma-src\": \"gamma-src\",\n" &
  "        \"nixpkgs\": \"nixpkgs\"\n" &
  "      }\n" &
  "    }\n" &
  "  },\n" &
  "  \"root\": \"root\",\n" &
  "  \"version\": 7\n" &
  "}\n"

proc useFourInputFlake*(fx: Nf2Fixture;
    alphaRev, betaRev, gammaRev, deltaRev: string) =
  ## Re-declare `app`'s flake with FOUR sibling inputs and write the matching
  ## lock, so one refresh can carry a sibling in each of the four states the
  ## policy distinguishes. Opt-in: no other case sees it.
  writeFile(fx.app / "flake.nix",
    "{\n" &
    "  description = \"NF-2 fixture consumer\";\n" &
    "\n" &
    "  inputs = {\n" &
    "    alpha-src.url = \"git+" & originUrl(fx, "alpha") & "?ref=main\";\n" &
    "    beta-src.url = \"git+" & originUrl(fx, "beta") & "?ref=main\";\n" &
    "    gamma-src.url = \"git+" & originUrl(fx, "gamma") & "?ref=main\";\n" &
    "    delta-src.url = \"git+" & originUrl(fx, "delta") & "?ref=main\";\n" &
    "    nixpkgs.url = \"github:NixOS/nixpkgs\";\n" &
    "    flake-utils.url = \"github:numtide/flake-utils\";\n" &
    "  };\n" &
    "\n" &
    "  outputs = _: { };\n" &
    "}\n")
  writeFile(lockPath(fx),
    fourInputFlakeLockText(fx, alphaRev, betaRev, gammaRev, deltaRev))

proc pushedRefsFile*(fx: Nf2Fixture): string =
  ## The stdin stream git hands a `pre-push` hook for one ordinary outgoing
  ## update of `main`.
  result = fx.scratch / "pushed-refs.txt"
  let sha = headOf(fx, fx.app)
  writeFile(result,
    "refs/heads/main " & sha & " refs/heads/main " & ZeroSha & "\n")

proc checkReportPath*(fx: Nf2Fixture): string =
  fx.ws / ".repro" / "build" / "reports" / "check-report.json"

proc gatePrePushIn*(fx: Nf2Fixture; repo: string): tuple[code: int;
    output: string; report: JsonNode] =
  ## Run the REAL pre-push gate over one of the fixture's repos and return both
  ## the console output and the structured report it wrote.
  let refs = fx.scratch / "pushed-refs.txt"
  writeFile(refs, "refs/heads/main " & headOf(fx, repo) &
    " refs/heads/main " & ZeroSha & "\n")
  let path = checkReportPath(fx)
  if fileExists(path): removeFile(path)
  let res = run(q(fx.repro) & " check --mode=pre-push --write-report" &
    " --workspace-root=" & q(fx.ws) &
    " --current-repo=" & q(repo) &
    " --pushed-refs=" & q(refs) &
    " --tool-provisioning=path", cwd = repo)
  var report = newJObject()
  if fileExists(path):
    try: report = parseJson(readFile(path))
    except CatchableError: report = newJObject()
  (code: res.code, output: res.output, report: report)

proc gatePrePush*(fx: Nf2Fixture): tuple[code: int; output: string;
    report: JsonNode] =
  ## The gate for the repo that carries the flake, which is what almost every
  ## case wants.
  gatePrePushIn(fx, fx.app)

proc gateFailureOf*(report: JsonNode; property: string): JsonNode =
  ## The first `CheckFailure` with the given `property`, or `nil`.
  if report.kind != JObject or not report.hasKey("failures"): return nil
  for f in report["failures"]:
    if f.hasKey("property") and f["property"].getStr() == property:
      return f
  nil

proc hasGateFailure*(report: JsonNode; property: string): bool =
  ## `check` over a BOOL rather than over the `JsonNode` itself, and that is
  ## not style: `unittest`'s `check` stringifies both operands when it fails,
  ## and `$` on a nil `JsonNode` segfaults — so `check gateFailureOf(…) != nil`
  ## takes the process down at exactly the moment it was supposed to print why.
  gateFailureOf(report, property) != nil

proc gateMentionsFlake*(report: JsonNode): bool =
  ## Did the gate say ANYTHING about the flake — a failure or a notice?
  ## `a_clean_workspace_pushes_without_a_diagnostic` is exactly this question.
  if report.kind != JObject: return false
  if report.hasKey("failures"):
    for f in report["failures"]:
      if ($f).toLowerAscii().contains("flake"): return true
  if report.hasKey("notices"):
    for n in report["notices"]:
      if n.getStr().toLowerAscii().contains("flake"): return true
  false

proc flakeStatus*(fx: Nf2Fixture; extra = ""; cwd = ""):
    tuple[code: int; stdout: string; stderr: string] =
  ## `repro flake override-status`, with the two streams kept APART.
  ##
  ## They carry different contracts — the ambient warnings are stderr, the
  ## `--json` document is stdout — and a helper that merged them could not tell
  ## a warning from a report, which is the distinction several cases below are
  ## entirely about.
  let errPath = fx.scratch / "override-status.err"
  let res = run(q(fx.repro) & " flake override-status" &
    " --workspace-root=" & q(fx.ws) &
    " --tool-provisioning=path " & extra & " 2>" & q(errPath),
    cwd = (if cwd.len > 0: cwd else: fx.app))
  let errText = if fileExists(errPath): readFile(errPath) else: ""
  (code: res.code, stdout: res.output, stderr: errText)

proc flakeArgs*(fx: Nf2Fixture; extra = ""; cwd = ""):
    tuple[code: int; stdout: string; stderr: string] =
  ## `repro flake override-args`, with the two streams kept APART — for the
  ## same reason `flakeStatus` keeps them apart, and one more: this verb's
  ## whole contract is that stdout carries ONLY `eval`-able arguments while the
  ## §3.2 drift report goes to stderr, so a helper that merged them could not
  ## witness the contract at all.
  let errPath = fx.scratch / "override-args.err"
  let res = run(q(fx.repro) & " flake override-args" &
    " --workspace-root=" & q(fx.ws) &
    " --tool-provisioning=path " & extra & " 2>" & q(errPath),
    cwd = (if cwd.len > 0: cwd else: fx.app))
  let errText = if fileExists(errPath): readFile(errPath) else: ""
  (code: res.code, stdout: res.output, stderr: errText)

proc makeSiblingALinkedWorktree*(fx: Nf2Fixture; name: string): string =
  ## Replace ``ws/<name>`` — an ordinary clone, whose `.git` is a DIRECTORY —
  ## with a LINKED WORKTREE of the same repository, whose `.git` is a regular
  ## FILE holding a `gitdir:` pointer. This is the shape
  ## `repro branch ../<name>` produces, so it is not an exotic case: it is how
  ## a second workspace on the same repos is normally made.
  ##
  ## Returns the worktree's HEAD.
  let host = fx.scratch / ("worktree-host-" & name)
  discard requireCmd(q(fx.gitBin) & " clone -q " & q(originUrl(fx, name)) &
    " " & q(host))
  discard requireCmd(q(fx.gitBin) & " -C " & q(host) &
    " config user.email tester@example.invalid")
  discard requireCmd(q(fx.gitBin) & " -C " & q(host) &
    " config user.name \"NF2 Tester\"")
  removeDir(siblingDir(fx, name))
  discard requireCmd(q(fx.gitBin) & " -C " & q(host) &
    " worktree add -q --detach " & q(siblingDir(fx, name)) & " HEAD")
  headOf(fx, siblingDir(fx, name))

proc statusRow*(doc: JsonNode; input: string): JsonNode =
  if doc.kind != JObject or not doc.hasKey("rows"): return nil
  for row in doc["rows"]:
    if row["input"].getStr() == input: return row
  nil

proc backtickedCommands*(text: string): seq[string] =
  ## Every `…`-quoted command in a message. The refusal contract is that at
  ## least one of them RUNS from the directory the message names, and the only
  ## way to assert that is to take it out of the text and run it.
  var i = 0
  while true:
    let open = text.find('`', i)
    if open < 0: break
    let close = text.find('`', open + 1)
    if close < 0: break
    result.add(text[(open + 1) ..< close])
    i = close + 1

proc directoryNamedForRunning*(text: string): string =
  ## The directory a refusal tells the operator to run its command FROM.
  ## Extracted from the message rather than assumed, so a message that stops
  ## naming one fails the case instead of silently passing against a directory
  ## the test picked itself.
  const marker = "From "
  let at = text.find(marker)
  if at < 0: return ""
  let rest = text[(at + marker.len) .. ^1]
  let stop = rest.find(" run:")
  if stop < 0: return ""
  rest[0 ..< stop].strip()

proc runNamedCommand*(fx: Nf2Fixture; command, cwd: string):
    tuple[code: int; output: string] =
  ## Execute a command lifted out of a refusal, in the directory the refusal
  ## named, with `repro` resolved to the binary under test.
  ##
  ## The substitution of the leading `repro` is the ONLY edit made to the
  ## printed string, and it is not a weakening: a stale `repro` on `PATH`
  ## fails this workspace's contract handshake, which would make every arm of
  ## this assertion vacuous (the campaign has already produced one such arm).
  ## Everything after the verb — every flag the refusal spelled out, which is
  ## the part under test — is passed through untouched.
  var cmd = command.strip()
  if cmd.startsWith("repro "):
    cmd = q(fx.repro) & cmd[len("repro") .. ^1]
  run(cmd, cwd = cwd)
