## The managed hooks consult the repo's OWN dependencies, never workspace
## membership (Unified-Locking-And-Hooks.md §16.5, CLI/develop.md DS-1
## applied to the hooks).
##
## WHY. A repo with no `repro.lock` and one sibling `flake.lock` input used to
## have its `pre-commit` refresh and its `pre-push` flake stage resolve the
## develop set of the WHOLE workspace (`repro develop --all`, every repo's
## lock records). Whether the repo's own input was consulted at all then
## depended on repos it does not depend on: a sibling with no lock record of
## its own was never substituted, and a workspace with no lock records
## anywhere refused the push as "develop set could not be resolved". And a
## sibling ahead of an input the recipe pins BY EXACT REVISION — an ordinary
## release pin — was refused at the push as stale, although the commit-time
## refresh had just declared that pin out of its reach (§16.1).
##
## The develop set the hooks use is now: the §14.2 union for a repo with a
## committed `repro.lock`, plus every repository the repo's `flake.lock`
## resolves that has a sibling checkout. A repository a recipe pins by exact
## revision, and that no explicit develop override substitutes, is not
## compared with its checkout at all.
##
## AMENDED 2026-10-18 (§16.5; reprobuild-pm issue
## `2026-10-12-release-commit-pin-refused-by-commit-and-push-gates.md`): of
## the flake inputs in that set, the hooks compare only those develop mode
## actually substitutes — the ones `repro flake override-args --all` binds. A
## sibling with no lock record is not substituted by the shell, which builds
## its PIN, so re-pinning it recorded a revision nobody built. Case 1 used to
## expect exactly that re-pin; it now expects the input to be named as not
## substituted and left alone, and then gives `lib` a lock record of its own
## and expects the re-pin — the same re-pin assertion as before, on an input
## the shell now does substitute. Case 4 gives `spare` a lock record for the
## same reason. `t_an_input_develop_mode_does_not_substitute_is_not_compared`
## covers the amended rule in full (ahead, diverged, push gate).
##
## Cases:
##   * `t_hooks_consult_only_the_repos_own_dependencies` — a manifest
##     workspace of five repos. `app` has NO `repro.lock` and ONE sibling
##     input (`lib-src` -> `lib`). The unrelated `other` commits a lock that
##     pins `third`, and `third` is BEHIND that pin; later it is DIVERGED, and
##     `other` is left dirty. `lib` carries no lock record of its own.
##       1. a commit after `lib` moved leaves `lib-src` alone and names it as
##          not substituted by develop mode (`lib` has no lock record); once
##          `lib` publishes a lock of its own, the next commit re-pins
##          `lib-src` to `lib`'s HEAD, and the hook records that it consulted
##          EXACTLY `lib-src` (nothing else, and nothing pinned by recipe);
##       2. the push gate passes with no flake or sibling-pin refusal;
##       3. `third` diverged and `other` dirty change nothing for `app`;
##       4. `app`'s flake then pins `lib-src` BY REVISION and `lib` moves
##          ahead of it: the commit neither re-pins nor refuses, leaves
##          `flake.lock` byte-identical, names the input as pinned by recipe
##          (with its `flake.nix` line), and the push gate does not refuse.
##   * `t_a_sibling_ahead_of_an_exact_pin_is_not_compared_at_push` — the same
##     exact-pin rule in the NF-2 workspace, where every sibling HAS a lock
##     record (the shape in which the push gate used to refuse
##     `flake_lock_stale`), with a floating input in the same flake still
##     re-pinned beside it.
##   * `t_an_exact_flake_pin_is_not_repinned_in_the_repro_lock` — the other
##     two sites §16.5 names: `app` also commits a `repro.lock` resolving
##     `lib`, its `flake.nix` pins `lib-src` by revision, and `lib` moves
##     ahead. The commit-time re-pin leaves `repro.lock` byte-identical (the
##     sibling is matched to the pin by checkout path and canonical URL, never
##     by name), and the pre-push `repro.lock` stage does not refuse.
##   * `t_a_same_named_input_of_another_repository_is_not_that_sibling` —
##     `app`'s input is called `lib-src` but fetches `spare`'s origin. It is
##     bound by canonical URL to `spare`: `lib` moving changes nothing, and
##     `spare` moving is examined against `spare` — but, since the 2026-10-18
##     amendment, not re-pinned, because develop mode does not substitute
##     `spare` for that input; nor is anything recorded once the shell
##     substitutes `lib` for it by name. A name never binds an input that
##     has a repository URL in the hooks.
##
## Falsifiability (observed against the base commit this was written on):
## case 1 fails at step 1 — `lib` has no lock record, so the workspace-wide
## develop set did not contain it and `lib-src` kept its old pin, and no
## develop-set line was logged; case 2 fails at the push, which refused
## `flake_lock_stale` for `beta-src`; case 3 fails because the re-pin moved
## `lib`'s `repro.lock` entry to the checkout's HEAD.
## Against reprobuild `agents` d9314ca874 (before the 2026-10-18 amendment),
## case 1's first commit re-pins `lib-src` although the shell does not
## substitute `lib`.
## The fourth case was checked against a mutant that binds an input by its
## suffix-stripped NAME before its URL: the commit after `lib` moved was
## refused, the hook named `lib-src=lib`, and `spare` moving did not re-pin
## the input.
##
## Test-double policy: NO mocks, doubles or fakes. Real bare origins, real
## clones, a real workspace manifest read by the production resolver, a real
## `flake.lock` in nix's on-disk shape, the real `./build/bin/repro`, and a
## REAL `.git/hooks/pre-commit` fired by a real `git commit`
## (`installPreCommitDispatch`; see `nf2_flake_lock_fixture.nim` for why the
## hook file is written rather than installed). The push gate is the real
## `repro check --mode=pre-push`, invoked exactly as the managed `pre-push`
## hook invokes it.

import std/[json, os, strutils, tempfiles, unittest]

import nf3_override_state_fixture
import repro_test_support/reasoned_skip

const
  OwnRepos = ["app", "lib", "other", "third", "spare"]
    ## `lib` is app's only sibling input; `other`, `third` and `spare` are
    ## unrelated to `app`.

proc fragment(name: string): string =
  "schema = \"reprobuild.workspace.repo.v1\"\n\n[repo]\n" &
    "name = \"" & name & "\"\npath = \"" & name & "\"\n" &
    "remote = \"" & name & "-origin\"\nrevision = \"main\"\n"

proc seed(fx: Nf2Fixture; name: string): string =
  ## A bare origin and a published clone at `ws/<name>`. Every repo carries a
  ## `flake.nix`: a sibling without one cannot be substituted, and that would
  ## make "it was not consulted" true for the wrong reason.
  let origin = originUrl(fx, name)
  discard requireCmd(q(fx.gitBin) & " init --bare -q -b main " &
    q(fx.scratch / ("origin-" & name & ".git")))
  let work = fx.ws / name
  discard requireCmd(q(fx.gitBin) & " clone -q " & q(origin) & " " & q(work))
  discard gitIn(fx, work, "config user.email tester@example.invalid")
  discard gitIn(fx, work, "config user.name \"Own Deps Tester\"")
  discard gitIn(fx, work, "config commit.gpgsign false")
  writeFile(work / "flake.nix", "{ outputs = _: { }; }\n")
  writeFile(work / "marker.txt", name & " revision 1\n")
  discard gitIn(fx, work, "add -A")
  discard gitIn(fx, work, "commit -q -m " & q("seed " & name))
  discard gitIn(fx, work, "push -q origin main")
  headOf(fx, work)

proc appFlakeNix(fx: Nf2Fixture; pinnedRev = ""; target = "lib"): string =
  ## `lib-src` floats on `main` unless ``pinnedRev`` pins it by revision. It
  ## fetches ``target``'s origin, which is `lib` except in the case about a
  ## same-named input of ANOTHER repository.
  "{\n" &
  "  description = \"own-dependencies fixture consumer\";\n" &
  "  inputs = {\n" &
  "    lib-src.url = \"git+" & originUrl(fx, target) & "?ref=main" &
    (if pinnedRev.len > 0: "&rev=" & pinnedRev else: "") & "\";\n" &
  "    nixpkgs.url = \"github:NixOS/nixpkgs\";\n" &
  "  };\n" &
  "  outputs = _: { };\n" &
  "}\n"

proc appFlakeLock(fx: Nf2Fixture; libRev: string; pinned = false;
    target = "lib"): string =
  "{\n  \"nodes\": {\n" &
  lockedNode("lib-src", originUrl(fx, target), libRev,
    "sha256-fv2PzTwKsfeBptF8u/G0w9eh6GDsib/62l5cyuKNGYM=", "    ",
    originalRev = (if pinned: libRev else: "")) & ",\n" &
  "    \"nixpkgs\": {\n" &
  "      \"locked\": { \"lastModified\": 1735563628, \"narHash\": " &
    "\"sha256-OZiZ3m8SCMfh3B6bfGC/Bm4x3qc1m2SVEAlkV6iY7Yg=\", \"owner\": " &
    "\"NixOS\", \"repo\": \"nixpkgs\", \"rev\": " &
    "\"5e4fbfb6b3de1aa2872b76d49fafc942626e2add\", \"type\": \"github\" },\n" &
  "      \"original\": { \"id\": \"nixpkgs\", \"type\": \"indirect\" }\n" &
  "    },\n" &
  "    \"root\": { \"inputs\": { \"lib-src\": \"lib-src\", " &
    "\"nixpkgs\": \"nixpkgs\" } }\n" &
  "  },\n  \"root\": \"root\",\n  \"version\": 7\n}\n"

proc twoEntryLock(fx: Nf2Fixture; owner, ownerRev, sibling,
    siblingPin: string): string =
  ## A committed `repro.lock` for ``owner`` in the shipped
  ## `reprobuild.solved-graph-lock.v2` shape: its root entry and one sibling
  ## entry pinning ``sibling`` at ``siblingPin``.
  proc dep(name, path, sha, depends, origin: string): string =
    "{ name = \"" & name & "\", path = \"" & path &
    "\", coord_kind = \"vcs\", url = \"" & originUrl(fx, origin) &
    "\", ref = \"main\", revision = \"" & sha &
    "\", integrity = \"git-sha1:" & sha &
    "\", version = \"\", visibility = \"public\", participation = \"\"" &
    ", depends = \"" & depends & "\", groups = \"\" }"
  "schema = \"reprobuild.solved-graph-lock.v2\"\n\n[lock]\n" &
  "platform = \"x86_64-linux\"\noptimal = true\n" &
  "inputs_digest = \"own-deps-fixture\"\nvariants = []\npackages = []\n" &
  "deps = [" & dep(owner, ".", ownerRev, sibling, owner) & ", " &
    dep(sibling, "../" & sibling, siblingPin, "", sibling) & "]\n"

proc recordOwnLock(fx: Nf2Fixture; name: string): string =
  ## Give ``name`` a committed, published `repro.lock` of its own (just its
  ## root entry) — the lock record that puts a repo into the develop set
  ## `repro flake override-args --all` substitutes. Returns the new HEAD.
  let dir = fx.ws / name
  let rev = headOf(fx, dir)
  writeFile(dir / "repro.lock",
    "schema = \"reprobuild.solved-graph-lock.v2\"\n\n[lock]\n" &
    "platform = \"x86_64-linux\"\noptimal = true\n" &
    "inputs_digest = \"own-deps-fixture\"\nvariants = []\n" &
    "packages = []\ndeps = [{ name = \"" & name & "\", path = \".\", " &
    "coord_kind = \"vcs\", url = \"" & originUrl(fx, name) &
    "\", ref = \"main\", revision = \"" & rev & "\", integrity = " &
    "\"git-sha1:" & rev & "\", version = \"\", visibility = \"public\", " &
    "participation = \"\", depends = \"\", groups = \"\" }]\n")
  discard gitIn(fx, dir, "add -A")
  discard gitIn(fx, dir, "commit -q -m " & q("lock " & name))
  discard gitIn(fx, dir, "push -q origin main")
  headOf(fx, dir)

proc otherLock(fx: Nf2Fixture; otherRev, thirdPin: string): string =
  ## `other`'s committed `repro.lock`, pinning `third` at ``thirdPin``.
  twoEntryLock(fx, "other", otherRev, "third", thirdPin)

proc setupOwnDepsFixture(label: string): Nf2Fixture =
  result.gitBin = findExe("git")
  result.repro = absolutePath(reproBinaryPath())
  result.scratch = createTempDir("own-deps-" & label & "-", "")
  result.ws = result.scratch / "ws"
  result.app = result.ws / "app"
  createDir(result.ws)
  var shas: seq[string]
  for name in OwnRepos: shas.add(seed(result, name))
  for i in 0 ..< OwnRepos.len: result.seedSha[i] = shas[i]

  # The workspace MANIFEST is the membership. No repo has a `depends` edge on
  # another: `app`'s only relation to `lib` is the flake input.
  createDir(result.ws / "projects")
  createDir(result.ws / "repos")
  var project = "schema = \"reprobuild.workspace.project.v1\"\n\n" &
    "[project]\nname = \"own\"\ndefault_revision = \"main\"\n" &
    "trunk = \"main\"\n\n"
  for name in OwnRepos:
    project.add("[[remote]]\nname = \"" & name & "-origin\"\nfetch = \"" &
      originUrl(result, name) & "\"\n\n")
    writeFile(result.ws / "repos" / (name & ".toml"), fragment(name))
  project.add("includes = [\n")
  for name in OwnRepos: project.add("  \"repos/" & name & ".toml\",\n")
  project.add("]\n")
  writeFile(result.ws / "projects" / "own.toml", project)
  createDir(result.ws / ".repro")
  writeFile(result.ws / ".repro" / "workspace.toml",
    "schema = \"reprobuild.workspace.local.v1\"\n\n" &
    "[workspace]\nproject = \"own\"\nbranch = \"main\"\n")

  # `third` gets a second published commit, `other` pins it there, and the
  # `third` checkout goes back one commit: BEHIND the pin of a repo `app`
  # does not depend on.
  let thirdNext = moveAndPublishSibling(result, "third", "revision 2")
  writeFile(result.ws / "other" / "repro.lock",
    otherLock(result, shas[2], thirdNext))
  discard gitIn(result, result.ws / "other", "add -A")
  discard gitIn(result, result.ws / "other", "commit -q -m " &
    q("lock other against third"))
  discard gitIn(result, result.ws / "other", "push -q origin main")
  discard rewindSibling(result, "third", 1)

  writeFile(result.app / "flake.nix", appFlakeNix(result))
  writeFile(lockPath(result), appFlakeLock(result, shas[1]))
  writeFile(result.app / ".gitignore", ".repro/\n")
  discard gitIn(result, result.app, "add -A")
  discard gitIn(result, result.app, "commit -q -m " & q("add flake"))
  publishRepo(result, result.app)
  installPreCommitDispatch(result)

proc developSetLine(fx: Nf2Fixture): string =
  ## The most recent `hook-develop-set` line of the pre-commit log.
  for line in preCommitLog(fx).splitLines():
    if " hook-develop-set " in line: result = line

proc afterTimestamp(line: string): string =
  ## The line without its leading timestamp.
  let sp = line.find(' ')
  if sp < 0: line else: line[sp + 1 .. ^1]

proc lockedRevIn(lockText, node: string): string =
  let doc = parseJson(lockText)
  doc["nodes"][node]["locked"]{"rev"}.getStr()

proc lineNumberOf(text, needle: string): int =
  var n = 0
  for line in text.splitLines():
    inc n
    if needle in line: return n
  0

proc noSiblingRefusal(fx: Nf2Fixture; gate: tuple[code: int; output: string;
    report: JsonNode]) =
  checkpoint("gate output:\n" & gate.output)
  check not hasGateFailure(gate.report, "flake_lock_stale")
  check not hasGateFailure(gate.report, "committed_lock_sibling_pin_stale")
  check gate.code == 0

suite "the managed hooks consult only the repo's own dependencies":

  test "t_hooks_consult_only_the_repos_own_dependencies":
    if not nf2Prerequisites("t_hooks_consult_only_the_repos_own_dependencies"):
      skip("needs git on PATH and a built ./build/bin/repro (named above)")
    else:
      let fx = setupOwnDepsFixture("main")
      defer: removeDir(fx.scratch)
      isolateNf2Config(fx)
      defer: releaseNf2Config()

      # The arrangement, asserted before anything is concluded from it.
      check not fileExists(fx.app / "repro.lock")
      check not fileExists(fx.ws / "lib" / "repro.lock")
      check not fileExists(fx.ws / "repro.lock")
      let thirdHead = headOf(fx, fx.ws / "third")
      let otherLockText = readFile(fx.ws / "other" / "repro.lock")
      check thirdHead notin otherLockText
      check run(q(fx.gitBin) & " -C " & q(fx.ws / "third") &
        " merge-base --is-ancestor HEAD origin/main").code == 0

      # ---- 1. the one sibling input is consulted, and only it. -----------
      # `lib` has no lock record, so the shell does not substitute it and the
      # hook leaves its pin alone (§16.5, amended 2026-10-18).
      let libMoved = moveAndPublishSibling(fx, "lib", "revision 2")
      let lockBefore1 = readFile(lockPath(fx))
      let c0 = tryCommitInApp(fx, "lib moved but is not developed")
      checkpoint(c0.output)
      checkpoint("pre-commit log:\n" & preCommitLog(fx))
      check c0.code == 0
      check lockInCommit(fx) == lockBefore1
      check libMoved notin lockInCommit(fx)
      check afterTimestamp(developSetLine(fx)) ==
        "hook-develop-set consulted: (none); pinned by recipe, not " &
        "compared: (none); not substituted by develop mode, not compared: " &
        "lib-src=lib"
      # `lib` publishes a lock of its own: now the shell substitutes it, and
      # the commit re-pins it — the assertion this step always made.
      let libNext = recordOwnLock(fx, "lib")
      let c1 = tryCommitInApp(fx, "work against the newer lib")
      checkpoint(c1.output)
      checkpoint("pre-commit log:\n" & preCommitLog(fx))
      check c1.code == 0
      check lockedRevIn(lockInCommit(fx), "lib-src") == libNext
      check afterTimestamp(developSetLine(fx)) ==
        "hook-develop-set consulted: flake.lock:lib-src=lib; " &
        "pinned by recipe, not compared: (none)"
      # The unrelated repos were left exactly as they were.
      check readFile(fx.ws / "other" / "repro.lock") == otherLockText
      check headOf(fx, fx.ws / "third") == thirdHead

      # ---- 2. the push gate verifies the same set and passes. -----------
      publishRepo(fx, fx.app)
      noSiblingRefusal(fx, gatePrePush(fx))

      # ---- 3. an unrelated sibling diverged, an unrelated repo dirty. ----
      discard moveSibling(fx, "third", "a fork of revision 1")
      writeFile(fx.ws / "other" / "marker.txt", "other: uncommitted work\n")
      let libThird = moveAndPublishSibling(fx, "lib", "revision 3")
      let c3 = tryCommitInApp(fx, "unrelated repos are untidy")
      checkpoint(c3.output)
      check c3.code == 0
      check "REFUSED" notin c3.output
      check "third" notin c3.output
      check lockedRevIn(lockInCommit(fx), "lib-src") == libThird
      check afterTimestamp(developSetLine(fx)) ==
        "hook-develop-set consulted: flake.lock:lib-src=lib; " &
        "pinned by recipe, not compared: (none)"
      publishRepo(fx, fx.app)
      noSiblingRefusal(fx, gatePrePush(fx))

      # ---- 4. an exact recipe pin with the sibling ahead of it. ---------
      # `flake.nix` now pins `lib-src` at the revision the lock names, and
      # `lib` moves ahead of it. Nothing substitutes the input explicitly.
      removePreCommitDispatch(fx)
      writeFile(fx.app / "flake.nix", appFlakeNix(fx, pinnedRev = libThird))
      writeFile(lockPath(fx), appFlakeLock(fx, libThird, pinned = true))
      discard gitIn(fx, fx.app, "add -A")
      discard gitIn(fx, fx.app, "commit -q -m " & q("pin lib by revision"))
      publishRepo(fx, fx.app)
      installPreCommitDispatch(fx)
      let pinLine = lineNumberOf(readFile(fx.app / "flake.nix"), "lib-src.url")
      check pinLine > 0
      let libAhead = moveAndPublishSibling(fx, "lib", "revision 4")
      check libAhead != libThird
      let lockBefore = readFile(lockPath(fx))
      let c4 = tryCommitInApp(fx, "lib is ahead of the release pin")
      checkpoint(c4.output)
      checkpoint("pre-commit log:\n" & preCommitLog(fx))
      check c4.code == 0
      check readFile(lockPath(fx)) == lockBefore
      check lockInCommit(fx) == lockBefore
      check "skipped-unrecordable-sibling" notin c4.output
      check "pinned BY REVISION" notin c4.output
      check afterTimestamp(developSetLine(fx)) ==
        "hook-develop-set consulted: (none); pinned by recipe, not " &
        "compared: lib-src=lib@" & fx.app / "flake.nix" & ":" & $pinLine &
        " (rev " & libThird & ")"
      publishRepo(fx, fx.app)
      noSiblingRefusal(fx, gatePrePush(fx))

  test "t_a_sibling_ahead_of_an_exact_pin_is_not_compared_at_push":
    if not nf3Prerequisites(
        "t_a_sibling_ahead_of_an_exact_pin_is_not_compared_at_push"):
      skip("needs git on PATH and a built ./build/bin/repro (named above)")
    else:
      # `beta-src` is pinned BY REVISION in `flake.nix`; `alpha-src` floats.
      # Every sibling has a lock record here (the workspace's committed lock
      # names all six repos), which is the shape in which the push used to
      # refuse the pinned input as a stale sibling.
      let fx = setupNf2Fixture("own-exact-pin", revPinned = ["beta-src"])
      defer: removeDir(fx.scratch)
      isolateNf2Config(fx)
      defer: releaseNf2Config()
      let seedBeta = fx.seedSha[1]
      let newAlpha = moveAndPublishSibling(fx, "alpha", "revision 2")
      let newBeta = moveAndPublishSibling(fx, "beta", "revision 2")
      check newBeta != seedBeta
      publishAll(fx)
      let betaNodeBefore = nodeText(readFile(lockPath(fx)), "beta-src")

      let c = tryCommitInApp(fx, "work against both siblings")
      checkpoint(c.output)
      checkpoint("pre-commit log:\n" & preCommitLog(fx))
      check c.code == 0
      let carried = lockInCommit(fx)
      # The floating input is re-pinned; the pinned one is left byte-identical
      # and is not announced as a declined refresh.
      check lockedRevIn(carried, "alpha-src") == newAlpha
      check nodeText(carried, "beta-src") == betaNodeBefore
      check "skipped-unrecordable-sibling" notin preCommitLog(fx)
      let betaLine = lineNumberOf(readFile(fx.app / "flake.nix"), "beta-src.url")
      check afterTimestamp(developSetLine(fx)) ==
        "hook-develop-set consulted: flake.lock:alpha-src=alpha, " &
        "flake.lock:gamma-src=gamma; pinned by recipe, not compared: " &
        "beta-src=beta@" & fx.app / "flake.nix" & ":" & $betaLine &
        " (rev " & seedBeta & ")"

      publishRepo(fx, fx.app)
      let gate = gatePrePush(fx)
      checkpoint("gate output:\n" & gate.output)
      if hasGateFailure(gate.report, "flake_lock_stale"):
        checkpoint("refused: " &
          $gateFailureOf(gate.report, "flake_lock_stale"))
      check not hasGateFailure(gate.report, "flake_lock_stale")
      check gate.code == 0

  test "t_an_exact_flake_pin_is_not_repinned_in_the_repro_lock":
    if not nf2Prerequisites(
        "t_an_exact_flake_pin_is_not_repinned_in_the_repro_lock"):
      skip("needs git on PATH and a built ./build/bin/repro (named above)")
    else:
      # `app` now ALSO commits a `repro.lock` that resolves `lib`, and its
      # `flake.nix` pins `lib-src` by revision. The re-pin and the pre-push
      # `repro.lock` stage are the other two sites §16.5 names: neither may
      # compare `lib` with its checkout while the recipe pins it exactly.
      let fx = setupOwnDepsFixture("repro-lock")
      defer: removeDir(fx.scratch)
      isolateNf2Config(fx)
      defer: releaseNf2Config()
      let libSeed = fx.seedSha[1]
      removePreCommitDispatch(fx)
      writeFile(fx.app / "flake.nix", appFlakeNix(fx, pinnedRev = libSeed))
      writeFile(lockPath(fx), appFlakeLock(fx, libSeed, pinned = true))
      writeFile(fx.app / "repro.lock",
        twoEntryLock(fx, "app", headOf(fx, fx.app), "lib", libSeed))
      # Committed THROUGH the hook, while `lib` is still at the pinned
      # revision: the hand-written lock is brought into the exact byte shape
      # the re-pin writes (its `deps` line is re-serialised once), so the
      # byte comparison below measures a re-pin and not a reformatting.
      installPreCommitDispatch(fx)
      discard gitIn(fx, fx.app, "add -A")
      discard gitIn(fx, fx.app, "commit -q -m " &
        q("pin lib by revision in both locks"))
      publishRepo(fx, fx.app)
      check gitIn(fx, fx.app, "status --porcelain").strip() == ""
      check libSeed in readFile(fx.app / "repro.lock")
      let pinLine = lineNumberOf(readFile(fx.app / "flake.nix"), "lib-src.url")
      check pinLine > 0

      let libAhead = moveAndPublishSibling(fx, "lib", "revision 2")
      check libAhead != libSeed
      let reproLockBefore = readFile(fx.app / "repro.lock")
      let flakeLockBefore = readFile(lockPath(fx))
      let c = tryCommitInApp(fx, "lib is ahead of the release pin")
      checkpoint(c.output)
      checkpoint("pre-commit log:\n" & preCommitLog(fx))
      check c.code == 0
      check readFile(fx.app / "repro.lock") == reproLockBefore
      check readFile(lockPath(fx)) == flakeLockBefore
      check libAhead notin readFile(fx.app / "repro.lock")
      # `lib` is named ONCE, as pinned by recipe, and is not consulted by
      # either lock.
      check afterTimestamp(developSetLine(fx)) ==
        "hook-develop-set consulted: (none); pinned by recipe, not " &
        "compared: lib-src=lib@" & fx.app / "flake.nix" & ":" & $pinLine &
        " (rev " & libSeed & ")"

      publishRepo(fx, fx.app)
      let gate = gatePrePush(fx)
      checkpoint("gate output:\n" & gate.output)
      if hasGateFailure(gate.report, "committed_lock_sibling_pin_stale"):
        checkpoint("refused: " &
          $gateFailureOf(gate.report, "committed_lock_sibling_pin_stale"))
      check not hasGateFailure(gate.report, "committed_lock_sibling_pin_stale")
      check not hasGateFailure(gate.report, "flake_lock_stale")

  test "t_a_same_named_input_of_another_repository_is_not_that_sibling":
    if not nf2Prerequisites(
        "t_a_same_named_input_of_another_repository_is_not_that_sibling"):
      skip("needs git on PATH and a built ./build/bin/repro (named above)")
    else:
      # `app`'s input is still CALLED `lib-src`, but it fetches `spare`'s
      # origin. A repository is identified by its canonical URL, never by a
      # name (§16.3), so the input is `spare`'s, and the workspace's `lib` —
      # whose name the input happens to spell — is not its sibling.
      let fx = setupOwnDepsFixture("same-name")
      defer: removeDir(fx.scratch)
      isolateNf2Config(fx)
      defer: releaseNf2Config()
      let spareSeed = fx.seedSha[4]
      removePreCommitDispatch(fx)
      writeFile(fx.app / "flake.nix", appFlakeNix(fx, target = "spare"))
      writeFile(lockPath(fx), appFlakeLock(fx, spareSeed, target = "spare"))
      discard gitIn(fx, fx.app, "add -A")
      discard gitIn(fx, fx.app, "commit -q -m " &
        q("lib-src fetches another repository"))
      publishRepo(fx, fx.app)
      installPreCommitDispatch(fx)

      # ---- 1. `lib` moves: nothing is consulted, nothing moves. ----------
      let libNext = moveAndPublishSibling(fx, "lib", "revision 2")
      let lockBefore = readFile(lockPath(fx))
      let c1 = tryCommitInApp(fx, "the same-named lib moved")
      checkpoint(c1.output)
      checkpoint("pre-commit log:\n" & preCommitLog(fx))
      check c1.code == 0
      check readFile(lockPath(fx)) == lockBefore
      check lockInCommit(fx) == lockBefore
      check libNext notin lockInCommit(fx)
      check afterTimestamp(developSetLine(fx)) ==
        "hook-develop-set consulted: flake.lock:lib-src=spare; " &
        "pinned by recipe, not compared: (none)"
      publishRepo(fx, fx.app)
      noSiblingRefusal(fx, gatePrePush(fx))

      # ---- 2. `spare` moves: the input follows the repository it names. --
      # The hook binds `lib-src` to `spare` (the log names `lib-src=spare`).
      # Before the §16.5 amendment of 2026-10-18 it then re-pinned the input
      # to `spare`'s HEAD. It no longer does: develop mode does not
      # substitute `spare` for this input (`repro flake override-args` binds a
      # `git+` URL input by its stripped NAME, `lib`, which has no lock
      # record), so the shell builds the pin and the hook leaves it there.
      let spareNext = moveAndPublishSibling(fx, "spare", "revision 2")
      let c2 = tryCommitInApp(fx, "the repository the input names moved")
      checkpoint(c2.output)
      checkpoint("pre-commit log:\n" & preCommitLog(fx))
      check c2.code == 0
      check lockInCommit(fx) == lockBefore
      check spareNext notin lockInCommit(fx)
      check libNext notin lockInCommit(fx)
      check afterTimestamp(developSetLine(fx)) ==
        "hook-develop-set consulted: (none); pinned by recipe, not " &
        "compared: (none); not substituted by develop mode, not compared: " &
        "lib-src=spare"
      publishRepo(fx, fx.app)
      noSiblingRefusal(fx, gatePrePush(fx))

      # ---- 3. the shell substitutes a DIFFERENT checkout: not compared. --
      # `lib` publishes a lock of its own, so the shell now substitutes `lib`
      # for `lib-src` (by name). The hook's member is `spare`, by URL. The
      # hook compares only a member the shell substitutes AT ITS checkout, so
      # neither `spare`'s nor `lib`'s revision is recorded, and the push is
      # not refused over a checkout the comparison would have misattributed.
      let libRecorded = recordOwnLock(fx, "lib")
      let c3 = tryCommitInApp(fx, "the same-named lib is developed")
      checkpoint(c3.output)
      checkpoint("pre-commit log:\n" & preCommitLog(fx))
      check c3.code == 0
      check lockInCommit(fx) == lockBefore
      check libRecorded notin lockInCommit(fx)
      check spareNext notin lockInCommit(fx)
      check afterTimestamp(developSetLine(fx)) ==
        "hook-develop-set consulted: (none); pinned by recipe, not " &
        "compared: (none); not substituted by develop mode, not compared: " &
        "lib-src=spare"
      publishRepo(fx, fx.app)
      let g3 = gatePrePush(fx)
      checkpoint("gate output:\n" & g3.output)
      check not hasGateFailure(g3.report, "flake_lock_stale")
