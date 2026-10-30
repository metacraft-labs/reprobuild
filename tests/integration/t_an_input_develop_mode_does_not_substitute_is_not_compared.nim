## The managed hooks compare only the flake inputs develop mode actually
## substitutes (Unified-Locking-And-Hooks.md §16.5, amended 2026-10-18;
## §13.6 "the sibling revisions the overrides actually used";
## Nix-Flake-Coexistence.md §4, "overridden inputs").
##
## WHY. reprobuild-pm issue
## `2026-10-12-release-commit-pin-refused-by-commit-and-push-gates.md`. A
## floating flake input bound to a sibling checkout that has no lock record is
## NOT substituted by the shell: `repro flake override-args --all` leaves it
## at its `flake.lock` pin, so the shell builds the PIN. The hooks nevertheless
## compared it with the checkout:
##   * the `pre-commit` hook re-pinned it to whatever the checkout held — a
##     revision nobody built, and in the issue one that was not even on the
##     branch the input tracks — or, when the checkout had diverged, refused
##     the commit as a pin regression until `REPRO_ALLOW_PIN_REGRESSION`
##     named it;
##   * the push gate refused `flake_lock_stale`, naming `repro flake
##     refresh-lock`, which declines the same input as "NOT in the develop
##     set". So a workspace root, `infra` and a pm repo that each pin one
##     `nixos-modules` checkout at their own revision could not all push.
## And a sibling checkout whose commit-graph chain names a missing layer made
## git print `warning: unable to find all commit-graph files` on stderr; the
## distance parser read stderr with stdout and reported "distance UNKNOWN",
## so the hook, the refresh and the gate all failed closed with no remedy.
##
## Cases (one workspace, in order):
##   0. `repro flake override-args --all --json` does not substitute
##      `lib-src` (`lib` has no lock record) — the arrangement, asserted.
##   1. `lib` moves AHEAD of the pin and is published: a real `git commit`
##      through the managed `pre-commit` hook leaves `flake.lock`
##      byte-identical, and the hook's develop-set line names `lib-src=lib`
##      as not substituted.
##   2. the real pre-push gate has no `flake_lock_stale` — both before that
##      commit (the checkout ahead of the committed pin) and after it.
##   3. `lib` DIVERGES from the pin (published on another branch): the commit
##      is not refused, with no `REPRO_ALLOW_PIN_REGRESSION`, the lock is left
##      alone, and the gate still passes.
##   4. POSITIVE CONTROL. `lib` publishes a committed lock of its own (the
##      record `override-args` names as what enters a repo into the develop
##      set), so `override-args --all` now substitutes `lib-src`. With `lib`
##      back on `main` and ahead of the pin, the gate refuses
##      `flake_lock_stale` for it, and a commit re-pins it to `lib`'s HEAD —
##      the behaviour the rule keeps for a substituted input.
##   5. The commit-graph warning. `lib` moves ahead again and its local
##      commit-graph chain is made to name a layer that does not exist; git
##      is shown to print the warning on stderr (positive control). The gate
##      still classifies the row `relation=ahead ahead=1`, not "distance
##      UNKNOWN", and the commit re-pins it.
##
## Falsifiability (observed against reprobuild `agents` d9314ca874, the base
## this was written on, with its own `./build/bin/repro`): case 1 fails —
## the hook re-pinned `lib-src` to `lib`'s HEAD; case 2 fails before that
## commit — `flake_lock_stale` for `lib-src` (after it, the base's re-pin had
## already moved the pin to the checkout); case 3 fails — the commit was
## REFUSED as moving a pin backward; case 5 fails — the gate reported
## "distance UNKNOWN: `git rev-list --left-right --count` answered 'warning:
## unable to find all commit-graph files …', which is not two counts".
##
## Test-double policy: NO mocks, doubles or fakes. Real bare origins, real
## clones, a real workspace manifest read by the production resolver, a real
## `flake.lock` in nix's on-disk shape, the real `./build/bin/repro`, a REAL
## `.git/hooks/pre-commit` fired by a real `git commit`
## (`installPreCommitDispatch`), and the real `repro check --mode=pre-push`
## invoked as the managed `pre-push` hook invokes it. The corrupt commit-graph
## chain is git's own on-disk format, with one line naming a missing layer —
## the state the issue measured in a workspace checkout.

import std/[json, os, strutils, tempfiles, unittest]

import repro_test_support/reasoned_skip

import nf3_override_state_fixture

const
  Repos = ["app", "lib", "other", "third"]
    ## `lib` is app's only sibling input. `other` commits the workspace's only
    ## lock record (of `third`), so the lock set is not empty and `lib` is
    ## not in it.

proc fragment(name: string): string =
  "schema = \"reprobuild.workspace.repo.v2\"\n\n[repo]\n" &
    "name = \"" & name & "\"\npath = \"" & name & "\"\n" &
    "remote = \"" & name & "-origin\"\nmainline = \"main\"\n"

proc seed(fx: Nf2Fixture; name: string): string =
  ## A bare origin and a published clone at `ws/<name>`, carrying a
  ## `flake.nix` so a sibling is substitutable in principle.
  let origin = originUrl(fx, name)
  discard requireCmd(q(fx.gitBin) & " init --bare -q -b main " &
    q(fx.scratch / ("origin-" & name & ".git")))
  let work = fx.ws / name
  discard requireCmd(q(fx.gitBin) & " clone -q " & q(origin) & " " & q(work))
  discard gitIn(fx, work, "config user.email tester@example.invalid")
  discard gitIn(fx, work, "config user.name \"Not Substituted Tester\"")
  discard gitIn(fx, work, "config commit.gpgsign false")
  writeFile(work / "flake.nix", "{ outputs = _: { }; }\n")
  writeFile(work / "marker.txt", name & " revision 1\n")
  discard gitIn(fx, work, "add -A")
  discard gitIn(fx, work, "commit -q -m " & q("seed " & name))
  discard gitIn(fx, work, "push -q origin main")
  headOf(fx, work)

proc appFlakeNix(fx: Nf2Fixture): string =
  ## `lib-src` floats on `main`: no revision is stated in the recipe.
  "{\n" &
  "  description = \"not-substituted fixture consumer\";\n" &
  "  inputs = {\n" &
  "    lib-src.url = \"git+" & originUrl(fx, "lib") & "?ref=main\";\n" &
  "    nixpkgs.url = \"github:NixOS/nixpkgs\";\n" &
  "  };\n" &
  "  outputs = _: { };\n" &
  "}\n"

proc appFlakeLock(fx: Nf2Fixture; libRev: string): string =
  "{\n  \"nodes\": {\n" &
  lockedNode("lib-src", originUrl(fx, "lib"), libRev,
    "sha256-fv2PzTwKsfeBptF8u/G0w9eh6GDsib/62l5cyuKNGYM=", "    ") & ",\n" &
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

proc otherLock(fx: Nf2Fixture; otherRev: string;
    pins: openArray[tuple[name, rev: string]]): string =
  ## `other`'s committed `repro.lock` in the shipped
  ## `reprobuild.solved-graph-lock.v2` shape: its root entry and one entry per
  ## pinned sibling. These entries are the workspace's lock records.
  proc dep(name, path, sha, depends: string): string =
    "{ name = \"" & name & "\", path = \"" & path &
    "\", coord_kind = \"vcs\", url = \"" & originUrl(fx, name) &
    "\", ref = \"main\", revision = \"" & sha &
    "\", integrity = \"git-sha1:" & sha &
    "\", version = \"\", visibility = \"public\", participation = \"\"" &
    ", depends = \"" & depends & "\", groups = \"\" }"
  var names: seq[string]
  for p in pins: names.add(p.name)
  var deps = @[dep("other", ".", otherRev, names.join(","))]
  for p in pins: deps.add(dep(p.name, "../" & p.name, p.rev, ""))
  "schema = \"reprobuild.solved-graph-lock.v2\"\n\n[lock]\n" &
  "platform = \"x86_64-linux\"\noptimal = true\n" &
  "inputs_digest = \"not-substituted-fixture\"\nvariants = []\n" &
  "packages = []\ndeps = [" & deps.join(", ") & "]\n"

proc ownLock(fx: Nf2Fixture; name, rev: string): string =
  ## A repo's own committed `repro.lock`: just its root entry.
  "schema = \"reprobuild.solved-graph-lock.v2\"\n\n[lock]\n" &
  "platform = \"x86_64-linux\"\noptimal = true\n" &
  "inputs_digest = \"not-substituted-fixture\"\nvariants = []\n" &
  "packages = []\ndeps = [{ name = \"" & name & "\", path = \".\", " &
  "coord_kind = \"vcs\", url = \"" & originUrl(fx, name) &
  "\", ref = \"main\", revision = \"" & rev & "\", integrity = " &
  "\"git-sha1:" & rev & "\", version = \"\", visibility = \"public\", " &
  "participation = \"\", depends = \"\", groups = \"\" }]\n"

proc commitOtherLock(fx: Nf2Fixture;
    pins: openArray[tuple[name, rev: string]]) =
  let dir = fx.ws / "other"
  writeFile(dir / "repro.lock", otherLock(fx, headOf(fx, dir), pins))
  discard gitIn(fx, dir, "add -A")
  discard gitIn(fx, dir, "commit -q -m " & q("lock other"))
  discard gitIn(fx, dir, "push -q origin main")

proc setupFixture(label: string): tuple[fx: Nf2Fixture; pin: string] =
  var fx: Nf2Fixture
  fx.gitBin = findExe("git")
  fx.repro = absolutePath(reproBinaryPath())
  fx.scratch = createTempDir("not-substituted-" & label & "-", "")
  fx.ws = fx.scratch / "ws"
  fx.app = fx.ws / "app"
  createDir(fx.ws)
  for i, name in Repos: fx.seedSha[i] = seed(fx, name)

  createDir(fx.ws / "projects")
  createDir(fx.ws / "repos")
  var project = "schema = \"reprobuild.workspace.project.v1\"\n\n" &
    "[project]\nname = \"own\"\n" &
    "\n"
  for name in Repos:
    project.add("[[remote]]\nname = \"" & name & "-origin\"\nfetch = \"" &
      originUrl(fx, name) & "\"\n\n")
    writeFile(fx.ws / "repos" / (name & ".toml"), fragment(name))
  project.add("includes = [\n")
  for name in Repos: project.add("  \"repos/" & name & ".toml\",\n")
  project.add("]\n")
  writeFile(fx.ws / "projects" / "own.toml", project)
  createDir(fx.ws / ".repro")
  writeFile(fx.ws / ".repro" / "workspace-state.toml",
    "schema = \"reprobuild.workspace.state.v1\"\n\n" &
    "[workspace]\nproject = \"own\"\nbranch = \"main\"\n")

  commitOtherLock(fx, [(name: "third", rev: fx.seedSha[3])])

  # The pin is `lib`'s SECOND revision, so the checkout can later diverge
  # from it (from the root commit nothing can).
  let pin = moveAndPublishSibling(fx, "lib", "revision 2")
  writeFile(fx.app / "flake.nix", appFlakeNix(fx))
  writeFile(lockPath(fx), appFlakeLock(fx, pin))
  writeFile(fx.app / ".gitignore", ".repro/\n")
  discard gitIn(fx, fx.app, "add -A")
  discard gitIn(fx, fx.app, "commit -q -m " & q("add flake"))
  publishRepo(fx, fx.app)
  installPreCommitDispatch(fx)
  (fx: fx, pin: pin)

proc developSetLine(fx: Nf2Fixture): string =
  ## The most recent `hook-develop-set` line of the pre-commit log, without
  ## its leading timestamp.
  for line in preCommitLog(fx).splitLines():
    if " hook-develop-set " in line:
      let sp = line.find(' ')
      result = if sp < 0: line else: line[sp + 1 .. ^1]

proc lockedRevIn(lockText, node: string): string =
  parseJson(lockText)["nodes"][node]["locked"]{"rev"}.getStr()

proc substitutedInputs(fx: Nf2Fixture): seq[string] =
  ## The inputs `repro flake override-args --all` binds — what the shell
  ## substitutes.
  let res = flakeArgs(fx, "--all --json")
  checkpoint("override-args stderr:\n" & res.stderr)
  check res.code == 0
  for o in parseJson(res.stdout)["overrides"]: result.add(o["input"].getStr())

suite "an input develop mode does not substitute is not compared":

  test "t_an_input_develop_mode_does_not_substitute_is_not_compared":
    if not nf2RecordingPrerequisites(
        "t_an_input_develop_mode_does_not_substitute_is_not_compared"):
      skip("needs git and nix on PATH and a built ./build/bin/repro")
    else:
      let (fx, pin) = setupFixture("main")
      defer: removeDir(fx.scratch)
      isolateNf2Config(fx)
      defer: releaseNf2Config()
      delEnv("REPRO_ALLOW_PIN_REGRESSION")

      # ---- 0. the arrangement: the shell does not substitute `lib-src`. --
      check not fileExists(fx.ws / "lib" / "repro.lock")
      check "lib-src" notin substitutedInputs(fx)

      # ---- 1. `lib` ahead of the pin: not re-pinned. --------------------
      let libAhead = moveAndPublishSibling(fx, "lib", "revision 3")
      check libAhead != pin
      let lockBefore = readFile(lockPath(fx))
      # The gate first, while `app` is clean and published with the OLD pin:
      # this is the state a push meets before any commit could re-pin it, so
      # it does not depend on what step 1's commit does.
      let g1 = gatePrePush(fx)
      checkpoint("gate output (before the commit):\n" & g1.output)
      check not hasGateFailure(g1.report, "flake_lock_stale")
      check g1.code == 0
      let c1 = tryCommitInApp(fx, "lib moved ahead")
      checkpoint(c1.output)
      checkpoint("pre-commit log:\n" & preCommitLog(fx))
      check c1.code == 0
      check readFile(lockPath(fx)) == lockBefore
      check lockInCommit(fx) == lockBefore
      check developSetLine(fx) ==
        "hook-develop-set consulted: (none); pinned by recipe, not " &
        "compared: (none); not substituted by develop mode, not compared: " &
        "lib-src=lib"

      # ---- 2. the push gate does not compare it. ------------------------
      publishRepo(fx, fx.app)
      let g2 = gatePrePush(fx)
      checkpoint("gate output:\n" & g2.output)
      check not hasGateFailure(g2.report, "flake_lock_stale")
      check g2.code == 0

      # ---- 3. `lib` diverged from the pin: not a regression to refuse. --
      discard gitIn(fx, fx.ws / "lib", "reset -q --hard " & fx.seedSha[1])
      let fork = moveSibling(fx, "lib", "a fork of revision 1")
      discard gitIn(fx, fx.ws / "lib", "push -q origin HEAD:fork")
      let rel = gitIn(fx, fx.ws / "lib",
        "rev-list --left-right --count " & pin & "..." & fork).strip()
      check rel.splitWhitespace() == @["1", "1"]
      let c3 = tryCommitInApp(fx, "lib diverged")
      checkpoint(c3.output)
      check c3.code == 0
      check "REFUSED" notin c3.output
      check readFile(lockPath(fx)) == lockBefore
      check lockInCommit(fx) == lockBefore
      publishRepo(fx, fx.app)
      let g3 = gatePrePush(fx)
      checkpoint("gate output:\n" & g3.output)
      check not hasGateFailure(g3.report, "flake_lock_stale")
      check g3.code == 0

      # ---- 4. positive control: substituted, so compared. ---------------
      # `lib` publishes a committed lock of its own — the record
      # `override-args` names as what puts a repo into the develop set.
      let lib = fx.ws / "lib"
      discard gitIn(fx, lib, "reset -q --hard " & libAhead)
      writeFile(lib / "repro.lock", ownLock(fx, "lib", libAhead))
      discard gitIn(fx, lib, "add -A")
      discard gitIn(fx, lib, "commit -q -m " & q("lock lib"))
      publishSibling(fx, "lib")
      let libRecorded = headOf(fx, lib)
      check "lib-src" in substitutedInputs(fx)
      let g4 = gatePrePush(fx)
      checkpoint("gate output:\n" & g4.output)
      check hasGateFailure(g4.report, "flake_lock_stale")
      check g4.code != 0
      let c4 = tryCommitInApp(fx, "lib is developed now")
      checkpoint(c4.output)
      checkpoint("pre-commit log:\n" & preCommitLog(fx))
      check c4.code == 0
      check lockedRevIn(lockInCommit(fx), "lib-src") == libRecorded
      check developSetLine(fx) ==
        "hook-develop-set consulted: flake.lock:lib-src=lib; pinned by " &
        "recipe, not compared: (none)"
      publishRepo(fx, fx.app)

      # ---- 5. a commit-graph warning on stderr is not part of the answer.
      let libNext = moveAndPublishSibling(fx, "lib", "revision 4")
      discard gitIn(fx, lib, "commit-graph write --split --reachable")
      let chain = lib / ".git" / "objects" / "info" / "commit-graphs" /
        "commit-graph-chain"
      check fileExists(chain)
      # git writes the chain read-only; a missing BASE layer is the state the
      # issue measured (the shared clone's graph was rewritten under it).
      let layers = readFile(chain)
      removeFile(chain)
      writeFile(chain, "0123456789abcdef0123456789abcdef01234567\n" & layers)
      # Positive control: git really does warn, on stderr only, and still
      # answers on stdout.
      let errPath = fx.scratch / "rev-list.err"
      let probe = run(q(fx.gitBin) & " -C " & q(lib) &
        " rev-list --left-right --count " & libRecorded & "..." & libNext &
        " 2>" & q(errPath))
      check probe.code == 0
      check probe.output.strip().splitWhitespace() == @["0", "1"]
      check "unable to find all commit-graph files" in readFile(errPath)
      let g5 = gatePrePush(fx)
      checkpoint("gate output:\n" & g5.output)
      check hasGateFailure(g5.report, "flake_lock_stale")
      let evidence = $gateFailureOf(g5.report, "flake_lock_stale")
      check "relation=ahead ahead=1 behind=0" in evidence
      check "UNKNOWN" notin g5.output
      check "not two counts" notin g5.output
      let c5 = tryCommitInApp(fx, "lib moved under a stale commit-graph")
      checkpoint(c5.output)
      checkpoint("pre-commit log:\n" & preCommitLog(fx))
      check c5.code == 0
      check lockedRevIn(lockInCommit(fx), "lib-src") == libNext
