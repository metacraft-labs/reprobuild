## NF-3 — **the no-op case stays quiet.**
##
## Spec: the milestone's own justification —
##
##   > `a_clean_workspace_pushes_without_a_diagnostic` — the no-op case stays
##   > quiet, or the warning becomes noise people learn to scroll past.
##
## This is not a politeness requirement. Every failure this campaign exists to
## remove is a mechanism that spoke while doing nothing, and the counterpart
## risk is a mechanism that speaks on every clean run: after the twentieth
## push whose flake stage says something, the twenty-first — which says
## something DIFFERENT — is scrolled past with the rest.
##
## ## What is asserted
##
##   1. with every substituted sibling exactly at its pin, the gate emits NO
##      `flake_lock_stale` failure and NO flake-related notice at all;
##   2. `repro flake override-status` emits no WARNING, and still emits its one
##      accounting line — quiet is not the same as silent, and the accounting
##      line is what keeps "2 inputs, both at pin" distinguishable from
##      "nothing was examined";
##   3. a repo with NO flake at all is quieter still: `examined` is false, the
##      gate says nothing, and the verb says so explicitly rather than
##      reporting a clean state it never checked. This is NF-1's rule — an
##      empty result and a failure must not look alike — applied to the third
##      case, "there was nothing here to look at";
##   4. the SKIP INVENTORY stays out of a clean push. `gamma` is named by a
##      flake input and checked out beside this repo, but carries no
##      `flake.nix`, so nix cannot take it as an input and it keeps its pin.
##      The shell-entry report NAMES that (it is §5's inert knob in miniature —
##      one input has quietly gone back to its pin); the gate does NOT, because
##      an input nothing substitutes cannot disagree with the pin it kept, and
##      a gate that says so on every push is the noise this case forbids.
##
##      The negative is proved non-vacuous TWICE in this same case, over this
##      same workspace: the string is present in `override-status`'s output
##      (arm 4), and present in the gate's OWN report the moment the gate has
##      something to refuse (arm 10). "Absent" here therefore means
##      "suppressed because the verdict is clean", not "never produced".
##
## ## Mutations
##
##   * announce the verified-and-agreeing verdict as a gate notice (the natural
##     "be helpful" edit) ⇒ RED on assert (1);
##   * surface the skip inventory unconditionally (move `for n in skipped` above
##     the clean return) ⇒ RED on assert (4).
##
## Test-double policy: NO mocks, doubles or fakes. See the headers of
## `nf2_flake_lock_fixture.nim` and `nf3_override_state_fixture.nim`.

import std/[json, os, strutils, unittest]

import nf3_override_state_fixture

suite "NF-3: a clean workspace pushes without a diagnostic":

  test "t_a_clean_workspace_pushes_without_a_diagnostic":
    const caseName = "t_a_clean_workspace_pushes_without_a_diagnostic"
    if not nf3Prerequisites(caseName):
      skip()
    else:
      let fx = setupNf2Fixture("clean")
      defer: removeDir(fx.scratch)
      isolateNf2Config(fx)
      defer: releaseNf2Config()
      removePreCommitDispatch(fx)

      # The fixture's starting state already has every sibling at its pin.
      # Assert that rather than trusting it, or the case would be quiet about
      # a workspace it never made clean.
      let lockText = readFile(lockPath(fx))
      for i in 0 ..< 3:
        check lockText.contains(fx.seedSha[i])
        check headOf(fx, siblingDir(fx, Nf2Repos[i])) == fx.seedSha[i]

      # `gamma` loses its `flake.nix`, which is what assert (4) is about: an
      # input that COULD have been substituted and is not. Committed and
      # published, so the only thing it changes about this workspace is the
      # substituted set.
      removeFile(siblingDir(fx, "gamma") / "flake.nix")
      discard gitIn(fx, siblingDir(fx, "gamma"), "add -A")
      discard gitIn(fx, siblingDir(fx, "gamma"),
        "commit -q -m " & q("gamma stops being a flake"))
      publishAll(fx)
      commitLockAndPublish(fx, "clean starting state")

      # ---- (1) the gate says nothing about the flake ----------------------
      let gate = gatePrePush(fx)
      checkpoint("gate output:\n" & gate.output)
      checkpoint("report:\n" & pretty(gate.report, indent = 2))
      check not hasGateFailure(gate.report, "flake_lock_stale")
      check not gateMentionsFlake(gate.report)
      check not gate.output.toLowerAscii().contains("flake.lock")

      # ---- (4) …and the skip inventory stayed out of it -------------------
      check not ($gate.report).contains("NOT substituted")
      # Non-vacuity, half one: the string IS what this workspace produces, from
      # the verb that is supposed to carry it. Half two is arm (10).
      let inventory = flakeStatus(fx)
      checkpoint("override-status stderr (inventory):\n" & inventory.stderr)
      check inventory.code == 0
      check inventory.stderr.contains(
        "NOT substituted: flake input 'gamma-src'")
      check inventory.stderr.contains("has no flake.nix")

      # ---- (2) the ambient report is quiet, but not silent ----------------
      check not inventory.stderr.contains("WARNING")
      check not inventory.stderr.contains("BEHIND")
      check not inventory.stderr.contains("AHEAD")
      check inventory.stderr.contains("2 substituted input(s)")
      check inventory.stderr.contains("2 at pin, 0 ahead, 0 behind")

      # ---- (3) a repo with no flake at all --------------------------------
      # `delta` is a workspace sibling that carries a `flake.nix` and no
      # `flake.lock` — it pins nothing. Run the verb THERE and it must say
      # there is nothing to compare, rather than report a clean state it never
      # established (or refuse, which is what a flake with no parseable inputs
      # rightly does; three answers, kept apart).
      let noFlake = flakeStatus(fx, "--flake=" & q(siblingDir(fx, "delta")),
        cwd = siblingDir(fx, "delta"))
      checkpoint("no-flake stderr:\n" & noFlake.stderr)
      check noFlake.code == 0
      check noFlake.stderr.contains("no flake.nix + flake.lock pair")
      check not noFlake.stderr.contains("substituted input(s)")
      let noFlakeJson = flakeStatus(fx,
        "--json --flake=" & q(siblingDir(fx, "delta")),
        cwd = siblingDir(fx, "delta"))
      check noFlakeJson.code == 0
      check not parseJson(noFlakeJson.stdout)["examined"].getBool()

      # ---- (5) an `unpinned` input is not drift, so the gate stays quiet ----
      # A `follows`-routed input resolves to another input's node and carries
      # no pin of its own, so "the pin disagrees with the sibling" is not a
      # proposition that can be false about it. Refusing here would produce a
      # gate no command can satisfy — `repro flake refresh-lock` deliberately
      # declines to move a `follows` input, because following it is a re-solve
      # rather than an observation. The decision is recorded in
      # `flakeOverrideStateReport`'s header.
      var lock = parseJson(readFile(lockPath(fx)))
      lock["nodes"]["root"]["inputs"]["beta-src"] = %*["alpha-src"]
      writeFile(lockPath(fx), pretty(lock, indent = 2))
      commitLockAndPublish(fx, "route beta-src through a follows path")
      let followsStatus = flakeStatus(fx, "--json")
      check followsStatus.code == 0
      check parseJson(followsStatus.stdout)["counts"]["unpinned"].getInt() == 1
      let followsGate = gatePrePush(fx)
      checkpoint("follows gate output:\n" & followsGate.output)
      check not hasGateFailure(followsGate.report, "flake_lock_stale")
      check not gateMentionsFlake(followsGate.report)

      # ---- (6) …but "could not determine" is NOT quiet ---------------------
      # There is exactly one derivation of the override set — `repro develop`'s
      # composed selection — so the one way this report can fail to know what
      # is substituted is that the develop set could not be resolved at all.
      # That must refuse, loudly: a report that answered "nothing is
      # substituted" for a workspace it could not read would be the campaign's
      # motivating bug wearing this command's uniform.
      let notAWorkspace = fx.scratch / "not-a-workspace"
      createDir(notAWorkspace)
      let unknownErr = fx.scratch / "unknown.err"
      let unknown = run(q(fx.repro) & " flake override-status" &
        " --workspace-root=" & q(notAWorkspace) &
        " --tool-provisioning=path 2>" & q(unknownErr), cwd = fx.app)
      let unknownText = readFile(unknownErr)
      checkpoint("unresolvable-workspace stderr:\n" & unknownText)
      check unknown.code == 2
      check unknownText.contains("REFUSING")
      # And it does NOT look like the quiet answer above.
      check not unknownText.contains("substituted input(s)")

      # ---- (7) the ambient line runs AS DOCUMENTED -------------------------
      # `.envrc` calls these with no `--tool-provisioning` at all. Every other
      # assertion in the NF-3 suite spells it out, which is exactly the shape
      # that hides "the documented invocation cannot run" — and it DID hide it
      # once already in this campaign: `repro flake refresh-lock` seeded
      # `tpmUnspecified` and exited 2 with "no provisioning mode was selected
      # before resolving git" for every invocation that omitted the flag, while
      # its own tests all passed it. So this arm passes NOTHING but the verb
      # and its selector — for BOTH shell-entry verbs, since `override-args` now
      # resolves git too.
      let bare = run(q(fx.repro) & " flake override-status 2>" &
        q(fx.scratch / "bare.err"), cwd = fx.app)
      let bareErr = readFile(fx.scratch / "bare.err")
      checkpoint("bare override-status stderr:\n" & bareErr)
      check bare.code == 0
      check bareErr.contains("substituted input(s)")
      let bareArgs = run(q(fx.repro) & " flake override-args --all 2>" &
        q(fx.scratch / "bare-args.err"), cwd = fx.app)
      let bareArgsErr = readFile(fx.scratch / "bare-args.err")
      checkpoint("bare override-args stdout: " & bareArgs.output)
      checkpoint("bare override-args stderr:\n" & bareArgsErr)
      check bareArgs.code == 0
      check bareArgs.output.contains("--override-input alpha-src")
      check bareArgsErr.contains("substituted input(s)")

      # ---- (8) a flake that genuinely declares NO inputs -------------------
      # NF-1 makes "the scan found no input" a REFUSAL, because a parse that
      # matched nothing looks exactly like a flake with nothing to override.
      # That rule is right for a verb somebody invoked and wrong for a gate:
      # applied blind it refuses the push of any repo whose flake really has no
      # inputs, with a remedy no command can satisfy. The LOCK settles it
      # without guessing — a root node that declares no inputs and a flake.nix
      # that declares none are the same statement made twice — so both
      # consumers stay quiet here. `delta` is that repo: a real flake with no
      # inputs, and now a real lock to match.
      writeFile(siblingDir(fx, "delta") / "flake.lock",
        "{\n  \"nodes\": {\n    \"root\": {}\n  },\n" &
        "  \"root\": \"root\",\n  \"version\": 7\n}\n")
      discard gitIn(fx, siblingDir(fx, "delta"), "add -A")
      discard gitIn(fx, siblingDir(fx, "delta"),
        "commit -q -m " & q("lock the input-less flake"))
      publishRepo(fx, siblingDir(fx, "delta"))
      let inputless = flakeStatus(fx,
        "--flake=" & q(siblingDir(fx, "delta")), cwd = siblingDir(fx, "delta"))
      checkpoint("input-less stderr:\n" & inputless.stderr)
      check inputless.code == 0
      check inputless.stderr.contains("root node declares no inputs")
      check not inputless.stderr.contains("REFUSING")
      let inputlessGate = gatePrePushIn(fx, siblingDir(fx, "delta"))
      checkpoint("input-less gate output:\n" & inputlessGate.output)
      check not hasGateFailure(inputlessGate.report, "flake_lock_stale")
      check not gateMentionsFlake(inputlessGate.report)

      # ---- (10) non-vacuity, half two: a REFUSING gate DOES carry it -------
      # The same sentence, from the same gate, over the same workspace — the
      # only difference being that this push has something to refuse. So assert
      # (4)'s `not … contains` measures suppression on a clean verdict rather
      # than a string the gate never emits.
      discard advanceSibling(fx, "alpha", 1)
      publishAll(fx)
      commitLockAndPublish(fx, "a lock that predates alpha's commit")
      let stale = gatePrePush(fx)
      checkpoint("stale gate report:\n" & pretty(stale.report, indent = 2))
      check stale.code == 2
      check hasGateFailure(stale.report, "flake_lock_stale")
      check ($stale.report).contains("NOT substituted")
      check ($stale.report).contains("gamma-src")
