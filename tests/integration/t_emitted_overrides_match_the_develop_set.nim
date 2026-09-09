## NF-1 (Nix-Flake-Coexistence.md §2, §5; Nix-Flake-Coexistence.milestones.org
## §NF-1) — **the emitted flake override arguments are the DEVELOP SET, not
## every sibling on disk**.
##
##   > | choosing which pins to substitute | `repro develop --all` / `--only` /
##   > `--except` / `--tier` | `NIX_FLAKE_OVERRIDE_AUTO=1` (all-or-nothing) |
##   >
##   > Note the third row is a real difference, not just a gap: `AUTO` is
##   > all-or-nothing, while `repro develop` selects a set. A project
##   > mid-transition usually wants a *subset* overridden, which is the shape
##   > the plugin cannot express today.
##
## and NF-1's own statement of it:
##
##   > Selection reuses `repro develop`'s composed, order-independent flag
##   > surface rather than inventing a second vocabulary. That is not tidiness:
##   > it is what closes the all-or-nothing gap in §2 … **The develop set is the
##   > override set.**
##
## ## Why this is the load-bearing case
##
## `NIX_FLAKE_OVERRIDE_AUTO=1` substitutes **every** flake input whose stripped
## name matches a directory beside the repo. There is no way to say "these
## three, not those two" — the plugin's vocabulary has no per-repo selector at
## all. A project mid-transition that wants exactly one dependency taken from a
## working tree has to either take all of them or hand-maintain a
## `NIX_FLAKE_OVERRIDE_INPUTS` list that duplicates, in a second spelling, a
## selection `repro develop` already expresses.
##
## So the assertion here is a DIFFERENCE, not a similarity: five sibling
## checkouts exist on disk, all five are flakes, all five are named by a flake
## input — and exactly the three the develop-set selection names are
## overridden. A verb that emitted five would be `AUTO` with a new name.
##
## ## Fixture (real, offline, no network)
##
##   <scratch>/
##     origin-<repo>.git × 5          real bare git origins
##     ws/                            the workspace root (a committed
##       repro.lock                   `repro.lock` IS the workspace marker,
##       alpha/ beta/ gamma/          MO-2 `isInitializedWorkspace`)
##       delta/ epsilon/              five real checkouts, each a flake
##       app/flake.nix                the consumer flake, five `-src` inputs
##
## The verb is run FROM `ws/app` — where `.envrc` runs — so the workspace-root
## ascent is exercised the way production reaches it, not handed in by a back
## door.
##
## ## Asserts
##
##   1. `--only=alpha,beta,gamma` emits exactly three `--override-input`
##      arguments, each pointing at that repo's checkout;
##   2. the two unselected repos appear NOWHERE in the output — not as an
##      input name, not as a path;
##   3. `--except=delta,epsilon` (the same set, written the other way round)
##      produces byte-identical output — the composed, order-independent flag
##      surface, reused rather than re-invented;
##   4. `--all` DOES emit all five, so (1) is a selection result and not a
##      mechanism that can only ever emit three;
##   5. a repo in the develop set whose checkout is absent is not substituted
##      and is NAMED on stderr — `path:` to a directory that is not there is
##      not an override, it is a broken flake, and skipping it silently is the
##      failure mode this whole campaign exists to remove;
##   6. the develop set is the OUTER workspace's, even when the repo holding
##      the flake carries a committed `repro.lock` of its own — the regression
##      test for a defect this milestone's own implementation had, in which the
##      workspace-root ascent stopped at the repo and reported an empty
##      override set for a 138-repo workspace;
##   7. **NF-1 writes no lock.** A `flake.lock` sitting beside the flake is
##      byte-identical, and unmodified, after every emission above — "This
##      milestone changes no lock" is the sentence that separates NF-1 from
##      NF-2, and it is the kind of sentence that stays true only while
##      something checks it. Refreshing the lock is NF-2's job and doing it
##      here would move a write onto a path `.envrc` runs on every directory
##      entry.
##
## ## Mutation (from the milestone): emit for every sibling on disk ⇒ RED
##
## That mutation is exactly the `AUTO` behaviour. It fails (1) with five
## `--override-input` arguments where three were asked for, and (2) by naming
## `delta` and `epsilon`.
##
## ## Test-double policy: NO mocks, doubles, or fakes
##
## Real bare git origins and real clones; a real committed `repro.lock` in the
## shipped `reprobuild.solved-graph-lock.v2` shape; the real `./build/bin/repro`
## binary invoked as a subprocess; the real filesystem. Nothing about the
## develop-set composition, the membership axis or the flake-input parse is
## stubbed.
##
## Hermetic: fresh tempdir; the system and user configuration layers are
## silenced so the host's own routing cannot reach the fixture.
## Skip: `git` missing or `./build/bin/repro` unbuilt — announced, not silent.

import std/[algorithm, os, osproc, strutils, tempfiles, times, unittest]

const reproBinary = "./build/bin/repro"

proc q(value: string): string = quoteShell(value)

proc run(command: string; cwd = ""): tuple[code: int; output: string] =
  let res = execCmdEx(command, workingDir = cwd)
  (code: res.exitCode, output: res.output)

proc requireGit(command: string; cwd = ""): string =
  let res = run(command, cwd)
  if res.code != 0:
    checkpoint("command failed: " & command & "\nexit=" & $res.code &
      "\n" & res.output)
    quit 1
  res.output

proc initGitRepo(gitBin, path: string) =
  createDir(path)
  discard requireGit(q(gitBin) & " init -b main " & q(path))
  discard requireGit(q(gitBin) & " -C " & q(path) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(path) &
    " config user.name \"NF1 Tester\"")

proc seedGitOrigin(gitBin, originPath, workPath: string): string =
  ## A real origin whose HEAD is a real 40-hex object id — the develop set
  ## refuses anything that is not an exact locked revision, so the lock below
  ## has to name one that actually exists.
  discard requireGit(q(gitBin) & " init --bare -b main " & q(originPath))
  initGitRepo(gitBin, workPath)
  # Every sibling is a FLAKE. `--override-input <n> path:<dir>` requires the
  # directory to be a flake; a sibling without one is a different case, and it
  # has its own witness below.
  writeFile(workPath / "flake.nix", "{ outputs = _: { }; }\n")
  writeFile(workPath / "seed.txt", extractFilename(workPath) & "\n")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " add -A")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " commit -m seed")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " remote add origin " & q(originPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " push origin main")
  requireGit(q(gitBin) & " -C " & q(workPath) & " rev-parse HEAD").strip()

proc cloneInto(gitBin, originPath, targetPath: string) =
  discard requireGit(q(gitBin) & " clone " &
    q("file://" & originPath) & " " & q(targetPath))

proc lockDep(name, url, sha: string): string =
  "{ name = \"" & name & "\", path = \"" & name & "\", coord_kind = \"vcs\"" &
  ", url = \"" & url & "\", ref = \"main\", revision = \"" & sha &
  "\", integrity = \"git-sha1:" & sha &
  "\", version = \"\", visibility = \"public\", participation = \"\"" &
  ", depends = \"\", groups = \"\" }"

proc committedLock(deps: seq[string]): string =
  "schema = \"reprobuild.solved-graph-lock.v2\"\n\n" &
  "[lock]\n" &
  "platform = \"x86_64-linux\"\n" &
  "optimal = true\n" &
  "inputs_digest = \"nf1-develop-set\"\n" &
  "variants = []\n" &
  "packages = []\n" &
  "deps = [" & deps.join(", ") & "]\n"

proc overridePairs(stdoutText: string): seq[string] =
  ## The `<input>=<path>` pairs of an emitted argument line, sorted. Parsed
  ## from the ACTUAL output rather than matched with `in`, so an argument the
  ## test did not expect cannot hide inside a substring match.
  let words = stdoutText.strip().splitWhitespace()
  var i = 0
  while i < words.len:
    if words[i] == "--override-input" and i + 2 < words.len:
      result.add(words[i + 1] & "=" & words[i + 2])
      i += 3
    else:
      inc i
  result.sort()

suite "NF-1: the emitted overrides are the develop set":

  test "t_emitted_overrides_match_the_develop_set":
    let gitBin = findExe("git")
    if gitBin.len == 0 or not fileExists(reproBinary):
      echo "SKIPPED (loudly): t_emitted_overrides_match_the_develop_set " &
        "needs `git` on PATH and a built ./build/bin/repro; " &
        "git=" & (if gitBin.len == 0: "MISSING" else: gitBin) &
        " repro=" & (if fileExists(reproBinary): "present" else: "UNBUILT")
      skip()
    else:
      let repro = absolutePath(reproBinary)
      let scratch = createTempDir("nf1-develop-set-", "")
      defer: removeDir(scratch)

      let repos = ["alpha", "beta", "gamma", "delta", "epsilon"]
      let ws = scratch / "ws"
      createDir(ws)

      var deps: seq[string]
      for name in repos:
        let origin = scratch / ("origin-" & name & ".git")
        let sha = seedGitOrigin(gitBin, origin, scratch / ("seed-" & name))
        cloneInto(gitBin, origin, ws / name)
        deps.add(lockDep(name, "file://" & origin, sha))
      writeFile(ws / "repro.lock", committedLock(deps))

      # The consumer flake, in a member repo — the topology `.envrc` actually
      # runs in: the flake is in a repo, the siblings are beside it under the
      # workspace root.
      let app = ws / "app"
      createDir(app)
      writeFile(app / "flake.nix", """{
  description = "NF-1 fixture consumer";

  inputs = {
    alpha-src.url = "github:example/alpha";
    beta-src.url = "github:example/beta";
    gamma-src.url = "github:example/gamma";
    delta-src.url = "github:example/delta";
    epsilon-src.url = "github:example/epsilon";
    nowhere-src.url = "github:example/nowhere";
  };

  outputs = _: { };
}
""")

      # (7)'s witness, placed BEFORE the first emission: a `flake.lock` whose
      # content is recognisable, so "unchanged" is a comparison rather than an
      # absence. The bytes are deliberately not a lock a NF-2 refresh would
      # find nothing to do in — every node names a revision that disagrees
      # with the sibling checkouts below, so an implementation that had
      # started refreshing would rewrite them.
      let lockPath = app / "flake.lock"
      let lockBytes = """{
  "nodes": {
    "alpha-src": {
      "locked": { "type": "github", "owner": "example", "repo": "alpha",
                  "rev": "0000000000000000000000000000000000000000" }
    },
    "root": { "inputs": { "alpha-src": "alpha-src" } }
  },
  "root": "root",
  "version": 7
}
"""
      writeFile(lockPath, lockBytes)
      let lockMtimeBefore = getLastModificationTime(lockPath)

      putEnv("REPROBUILD_SYSTEM_CONFIG", scratch / "no-system.toml")
      putEnv("REPROBUILD_USER_CONFIG", scratch / "no-user.toml")
      putEnv("REPROBUILD_VCS_PRIVATE_CONFIG", scratch / "no-vcs.toml")
      defer:
        delEnv("REPROBUILD_SYSTEM_CONFIG")
        delEnv("REPROBUILD_USER_CONFIG")
        delEnv("REPROBUILD_VCS_PRIVATE_CONFIG")

      proc emit(flags: string): tuple[code: int; outText, errText: string] =
        ## STDOUT is the eval-able argument line and STDERR is the report;
        ## they are captured separately because `.envrc` splices only the
        ## former into `use flake`, and a test that merged them could not tell
        ## a diagnostic from an argument.
        let outFile = scratch / "emit.out"
        let errFile = scratch / "emit.err"
        let res = run(repro & " flake override-args --tool-provisioning=path " &
          flags & " >" & q(outFile) & " 2>" & q(errFile), cwd = app)
        (code: res.code, outText: readFile(outFile),
         errText: readFile(errFile))

      # ---- (1) three in develop mode, two out. ---------------------------
      let three = emit("--only=alpha,beta,gamma")
      if three.code != 0:
        checkpoint("stdout: " & three.outText & "\nstderr: " & three.errText)
      check three.code == 0
      check overridePairs(three.outText) == @[
        "alpha-src=git+file://" & (ws / "alpha"),
        "beta-src=git+file://" & (ws / "beta"),
        "gamma-src=git+file://" & (ws / "gamma"),
      ]

      # ---- (2) the unselected repos appear NOWHERE. -----------------------
      # The `AUTO` mutation makes both of these fail, and they are asserted
      # over the raw text as well as the parsed pairs so a differently-spelled
      # emission (e.g. `--override-flake`) cannot slip past the parser.
      check "delta-src" notin three.outText
      check (ws / "delta") notin three.outText
      check "epsilon-src" notin three.outText
      check (ws / "epsilon") notin three.outText

      # ---- (3) the same set written the other way round. ------------------
      # `--only` and `--except` are two stages of ONE composed surface; the
      # answer is a set, so the two spellings of that set must agree byte for
      # byte.
      let complement = emit("--except=delta,epsilon")
      check complement.code == 0
      check complement.outText == three.outText

      # ---- (4) the mechanism CAN emit five; three was a selection. --------
      # Without this, an implementation that hardcoded a smaller answer — or
      # one that silently dropped repos it could not resolve — would pass (1).
      let all = emit("--all")
      check all.code == 0
      check overridePairs(all.outText) == @[
        "alpha-src=git+file://" & (ws / "alpha"),
        "beta-src=git+file://" & (ws / "beta"),
        "delta-src=git+file://" & (ws / "delta"),
        "epsilon-src=git+file://" & (ws / "epsilon"),
        "gamma-src=git+file://" & (ws / "gamma"),
      ]
      # `nowhere-src` is declared by the flake and has no repo at all, so it
      # keeps its pin under every selection. It is in the fixture so that "the
      # develop set decides" is distinguishable from "every input the flake
      # declares gets an override".
      check "nowhere-src" notin all.outText

      # ---- (5) a selected repo with no checkout is NAMED, not skipped. ----
      # A `path:` override onto a directory that is not there is not an
      # override; it is a flake that fails to evaluate. Dropping it quietly is
      # precisely the shape of §5's inert knob, so the emission excludes it
      # AND says so.
      removeDir(ws / "gamma")
      let missing = emit("--only=alpha,beta,gamma")
      check missing.code == 0
      check overridePairs(missing.outText) == @[
        "alpha-src=git+file://" & (ws / "alpha"),
        "beta-src=git+file://" & (ws / "beta"),
      ]
      check "gamma" in missing.errText
      check (ws / "gamma") in missing.errText

      # ---- (6) the workspace is the OUTER one, not the repo the flake is in.
      #
      # A participating repo of a multi-repo workspace normally carries a
      # committed `repro.lock` of its own — the build solve for that repo —
      # and by MO-2 a directory carrying one satisfies `isInitializedWorkspace`.
      # An ascent that stops at the nearest such directory therefore stops at
      # the REPO, resolves the repo's own lock (whose only entry is the repo
      # itself) and answers "the develop set is empty".
      #
      # That is not a hypothetical: run in this repository before the fix, the
      # command reported `0 override(s) … 0 repo(s) selected` for a workspace
      # whose lock set holds 138 repos and whose flake declares 23 inputs.
      # Emitting nothing while the workspace is full of develop-mode siblings
      # is §5's inert knob reached from a different direction, so the shell
      # marker (`.repro/workspace.toml`) has to win over the repo's own lock.
      createDir(ws / ".repro")
      writeFile(ws / ".repro" / "workspace.toml",
        "schema = \"reprobuild.workspace.local.v1\"\n\n" &
        "[workspace]\n" &
        "project = \"nf1\"\n" &
        "branch = \"main\"\n")
      writeFile(app / "repro.lock",
        committedLock(@["{ name = \"app\", path = \".\", coord_kind = \"vcs\"" &
          ", url = \"\", ref = \"\", revision = \"\", integrity = \"\"" &
          ", version = \"\", visibility = \"public\", participation = \"\"" &
          ", depends = \"\", groups = \"\" }"]))
      let nested = emit("--all")
      if nested.code != 0:
        checkpoint("nested stdout: " & nested.outText &
          "\nstderr: " & nested.errText)
      check nested.code == 0
      # Still the OUTER workspace's develop set: `gamma` is gone from disk (5),
      # the other four are unchanged.
      check overridePairs(nested.outText) == @[
        "alpha-src=git+file://" & (ws / "alpha"),
        "beta-src=git+file://" & (ws / "beta"),
        "delta-src=git+file://" & (ws / "delta"),
        "epsilon-src=git+file://" & (ws / "epsilon"),
      ]

      # ---- (7) NF-1 wrote no lock. ---------------------------------------
      # Six emissions have now run against a flake whose `flake.lock` names a
      # revision no sibling is at. Both halves are asserted: the BYTES, so a
      # refresh cannot hide behind a rewrite that happens to round-trip, and
      # the MTIME, so a rewrite-to-identical-content — which is what an
      # unconditional serializer does, and what would make every rebase a
      # lock-churn event once NF-2 lands — is still visible as a touch.
      check readFile(lockPath) == lockBytes
      check getLastModificationTime(lockPath) == lockMtimeBefore
