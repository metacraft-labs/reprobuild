## DS-7 (CLI/develop.md §"Membership axis") — **the membership axis and its
## FIXED composition order**.
##
##   > Selectors compose in a **fixed order**, so the result never depends on
##   > argv order. Each stage narrows the previous one:
##   >
##   > 1. **mode** — `--all` (default) | `--direct` | `--indirect` |
##   >    `--transitive-of=<pkg>`
##   > 2. **`--project=<list>`** … 3. **`--tag=<list>`** …
##   > 4. **`--filter=<glob>`** … 5. **`--only=<list>`** …
##   > 6. **`--except=<list>`**
##
## Why this is not cosmetic. Three of the six stages did not exist:
## `--indirect` was specified in the V1 proposal from the beginning and never
## implemented (the parser rejected it outright), and `--project`, `--tag`
## and `--except` had no implementation at all. `--filter` existed but was a
## SUBSTRING test rather than a glob, so `--filter=lib` silently also selected
## `zlib-extra` — a selector that matches more than it looks like it matches is
## how a bulk mutation reaches a repo nobody named.
##
## The ORDER is the load-bearing property, and this test asserts it as a
## PROPERTY, not one arrangement: the same selector set is passed in several
## argv permutations and every byte of the answer — including the per-stage
## `kept` counts — must be identical. The counts are what make the order
## observable at all: swapping any two stages changes them even when the final
## set does not.
##
## Fixture (built ``./build/bin/repro``, black-box, fully offline): a
## MULTI-PROJECT workspace, because `--project` is meaningless without one —
##
##   <scratch>/
##     origin-<repo>.git × 5
##     ws/
##       .repro/manifests/projects/alpha.toml   — contributes: lib-core,
##                                                lib-extra, tool-a, shared
##                 projects/beta.toml           — contributes: tool-b, shared
##                 repos/*.toml                 — `tags` declared per repo
##       .repro/workspace.toml                  — projects = ["alpha", "beta"]
##       .repro-workspace.toml                  — layer 4 route: team ->
##                                                git-checkout
##
## Asserts:
##   1. every stage narrows on its own: `--project`, `--tag`, `--filter`
##      (as a GLOB, anchored at both ends), `--only`, `--except`;
##   2. `--indirect` exists and selects the closure minus the root repo's
##      direct edges;
##   3. ARGV-ORDER INDEPENDENCE: six permutations of the same five selectors
##      produce byte-identical output, per-stage counts included;
##   3b. …and the case where that rule has real content: a REPEATED
##      single-valued selector, or two mode flags together, is a LOUD refusal
##      rather than a silent last-one-wins. Stages 2..6 are all set
##      intersections or subtractions over one universe, so they COMMUTE —
##      permuting distinct stages cannot change the result set however the
##      pipeline is written, and (3) alone would pass against a pipeline with
##      no fixed order at all. `--all --direct` vs `--direct --all` is where
##      argv order actually decided the answer;
##   4. the per-stage counts show the stages executing in the spec's order,
##      including dedicated witnesses where `--only` and `--except` each
##      narrow. They cannot both narrow in ONE accepted pipeline: DS-7's loud
##      exact-name rule rejects any name present in both sets, and a disjoint
##      `--except` set cannot remove a member retained by `--only`.
##
## Falsifiability / pre-fix failure: against ``391a892a`` this test fails at
## (1) with
##
##   repro develop: error: unsupported `repro develop --all` argument:
##   --project=alpha
##
## Mutation check: swapping stages in ``developSetFromLock`` (e.g. applying
## `--filter` before `--tag`) changes the reported `kept` counts in the
## witnesses below and fails (4); restoring the last-one-wins parse for the
## mode flags, `--filter` or `--at` fails (3b); restoring `--filter` to a
## substring test fails (1)'s anchored-glob assertions. Note that NO mutation
## of the stage pipeline can fail (3) on its own — that is what the count
## witnesses and (3b) exist to cover.
##
## Mocks: NONE. Real git repositories, a real multi-project manifest checkout,
## the real ``repro`` binary, the real git-checkout lock backend.
##
## Hermetic: fresh tempdir; every configuration layer except the fixture's own
## layer 4 is silenced. Skip: ``git`` missing or ``repro`` unbuilt.

import std/[os, osproc, strutils, tempfiles, unittest]

const reproBinary = "./build/bin/" & addFileExt("repro", ExeExt)

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
    " config user.name \"DS7 Tester\"")

proc seedGitOrigin(gitBin, originPath, workPath: string): string =
  discard requireGit(q(gitBin) & " init --bare -b main " & q(originPath))
  initGitRepo(gitBin, workPath)
  writeFile(workPath / "seed.txt", extractFilename(workPath) & "\n")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " add -A")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " commit -m seed")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " remote add origin " & q(originPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " push origin main")
  requireGit(q(gitBin) & " -C " & q(workPath) & " rev-parse HEAD").strip()

proc repoFragment(name, remote: string; tags: seq[string]): string =
  result = "schema = \"reprobuild.workspace.repo.v1\"\n\n" &
    "[repo]\n" &
    "name = \"" & name & "\"\n" &
    "path = \"" & name & "\"\n" &
    "remote = \"" & remote & "\"\n" &
    "revision = \"main\"\n"
  if tags.len > 0:
    result.add("tags = [\"" & tags.join("\", \"") & "\"]\n")

proc selectedRepos(output: string): seq[string] =
  ## The repo names of a ``--list`` table, in the order printed.
  var inTable = false
  for line in output.splitLines():
    if line.startsWith("REPO "):
      inTable = true
      continue
    if not inTable: continue
    if line.startsWith("repro develop"): continue
    let name = line.split(' ')[0].strip()
    if name.len > 0: result.add(name)

proc stageLines(output: string): seq[string] =
  for line in output.splitLines():
    if line.startsWith("selection: "): result.add(line)

suite "DS-7: the membership axis composes in a fixed order":

  test "t_develop_selectors_compose_in_fixed_order":
    let gitBin = findExe("git")
    if gitBin.len == 0 or not fileExists(reproBinary):
      skip()
    else:
      let repro = absolutePath(reproBinary)
      let scratch = createTempDir("ds7-order-", "")
      defer: removeDir(scratch)

      let repos = ["lib-core", "lib-extra", "tool-a", "tool-b", "shared"]
      var origins: seq[string]
      for name in repos:
        let origin = scratch / ("origin-" & name & ".git")
        discard seedGitOrigin(gitBin, origin, scratch / ("seed-" & name))
        origins.add(origin)

      let ws = scratch / "workspace"
      createDir(ws)
      let manifestsRoot = ws / ".repro" / "manifests"
      createDir(manifestsRoot / "projects")
      createDir(manifestsRoot / "repos")

      var remoteBlock = ""
      for i, name in repos:
        remoteBlock.add("[[remote]]\nname = \"" & name & "-origin\"\n" &
          "fetch = \"file://" & origins[i] & "\"\n\n")

      # `tags`: lib-core + lib-extra are `libs`; tool-a + tool-b are `tools`;
      # `shared` declares NO tags, so it is in the implicit `default` tag
      # ONLY (a repo that lists tags without naming `default` is not in it).
      writeFile(manifestsRoot / "repos" / "lib-core.toml",
        repoFragment("lib-core", "lib-core-origin", @["libs"]))
      writeFile(manifestsRoot / "repos" / "lib-extra.toml",
        repoFragment("lib-extra", "lib-extra-origin", @["libs"]))
      writeFile(manifestsRoot / "repos" / "tool-a.toml",
        repoFragment("tool-a", "tool-a-origin", @["tools"]))
      writeFile(manifestsRoot / "repos" / "tool-b.toml",
        repoFragment("tool-b", "tool-b-origin", @["tools"]))
      writeFile(manifestsRoot / "repos" / "shared.toml",
        repoFragment("shared", "shared-origin", @[]))

      proc projectToml(name: string; includes: seq[string]): string =
        "schema = \"reprobuild.workspace.project.v1\"\n\n" &
        "[project]\n" &
        "name = \"" & name & "\"\n" &
        "default_revision = \"main\"\n" &
        "trunk = \"main\"\n\n" &
        remoteBlock &
        "includes = [\n  \"repos/" & includes.join(".toml\",\n  \"repos/") &
        ".toml\",\n]\n"

      writeFile(manifestsRoot / "projects" / "alpha.toml",
        projectToml("alpha", @["lib-core", "lib-extra", "tool-a", "shared"]))
      writeFile(manifestsRoot / "projects" / "beta.toml",
        projectToml("beta", @["tool-b", "shared"]))
      initGitRepo(gitBin, manifestsRoot)
      discard requireGit(q(gitBin) & " -C " & q(manifestsRoot) & " add -A")
      discard requireGit(q(gitBin) & " -C " & q(manifestsRoot) &
        " commit -m manifests")

      for name in repos:
        discard requireGit(q(gitBin) & " clone " &
          q("file://" & scratch / ("origin-" & name & ".git")) & " " &
          q(ws / name))

      createDir(ws / ".repro")
      writeFile(ws / ".repro" / "workspace.toml",
        "schema = \"reprobuild.workspace.local.v1\"\n\n" &
        "[workspace]\n" &
        "project = \"alpha\"\n" &
        "projects = [\"alpha\", \"beta\"]\n" &
        "branch = \"main\"\n")
      writeFile(ws / ".repro-workspace.toml",
        "schema = \"reprobuild.workspace.bootstrap.v1\"\n\n" &
        "[manifest]\n" &
        "url = \"https://example.invalid/manifests.git\"\n\n" &
        "[locking]\n" &
        "route = [{ visibility = \"team\", backend = \"git-checkout\", " &
        "path = \".repro/manifests\", repos = [\"lib-core\", \"lib-extra\", " &
        "\"tool-a\", \"tool-b\", \"shared\"] }]\n")

      putEnv("REPROBUILD_SYSTEM_CONFIG", scratch / "no-system.toml")
      putEnv("REPROBUILD_USER_CONFIG", scratch / "no-user.toml")
      putEnv("REPROBUILD_VCS_PRIVATE_CONFIG", scratch / "no-vcs.toml")
      defer:
        delEnv("REPROBUILD_SYSTEM_CONFIG")
        delEnv("REPROBUILD_USER_CONFIG")
        delEnv("REPROBUILD_VCS_PRIVATE_CONFIG")

      let lockRes = run(repro & " workspace lock --workspace-root=" & q(ws),
        cwd = ws)
      if lockRes.code != 0:
        checkpoint("workspace lock output: " & lockRes.output)
      check lockRes.code == 0

      proc list(flags: string): tuple[code: int; output: string] =
        ## STDOUT only. The argv-order property below compares the answer BYTE
        ## FOR BYTE, and stdout (block-buffered into the pipe) and stderr
        ## (unbuffered) would interleave nondeterministically if merged. The
        ## notices are asserted by the DS-5 / DS-6 tests that own them.
        run(repro & " develop --list --tool-provisioning=path " & flags &
          " 2>/dev/null", cwd = ws)

      # ---- baseline: the whole lock set. ---------------------------------
      let all = list("")
      if all.code != 0:
        checkpoint("develop --list output: " & all.output)
      check all.code == 0
      check selectedRepos(all.output) ==
        @["lib-core", "lib-extra", "shared", "tool-a", "tool-b"]

      # ---- (1) each stage narrows on its own. ----------------------------
      # --project: only what `beta` contributes.
      let beta = list("--project=beta")
      check beta.code == 0
      check selectedRepos(beta.output) == @["shared", "tool-b"]

      # --tag: the manifest fragments' declared tags.
      let libs = list("--tag=libs")
      check libs.code == 0
      check selectedRepos(libs.output) == @["lib-core", "lib-extra"]
      # `shared` declares no tags, so it is in `default` and nothing else.
      let defaults = list("--tag=default")
      check defaults.code == 0
      check selectedRepos(defaults.output) == @["shared"]

      # --filter is a GLOB, anchored at both ends. The substring test it
      # replaced would have matched `lib-core` and `lib-extra` for `lib`;
      # the glob matches neither, and `lib-*` matches both.
      let filterExact = list("--filter=lib")
      check filterExact.code == 0
      check selectedRepos(filterExact.output).len == 0
      check "the selection is empty" in filterExact.output
      let filterGlob = list("--filter='lib-*'")
      check filterGlob.code == 0
      check selectedRepos(filterGlob.output) == @["lib-core", "lib-extra"]
      let filterQ = list("--filter='tool-?'")
      check filterQ.code == 0
      check selectedRepos(filterQ.output) == @["tool-a", "tool-b"]

      # --only / --except, exact names.
      let only = list("--only=tool-a,shared")
      check only.code == 0
      check selectedRepos(only.output) == @["shared", "tool-a"]
      let exceptOne = list("--except=shared")
      check exceptOne.code == 0
      check selectedRepos(exceptOne.output) ==
        @["lib-core", "lib-extra", "tool-a", "tool-b"]

      # ---- (2) --indirect exists. ----------------------------------------
      # No manifest repo declares `depends`, so the root has no direct edges
      # and `--indirect` is the whole closure; the point is that the flag is
      # ACCEPTED and routes to a mode of its own rather than being rejected.
      let indirect = list("--indirect")
      check indirect.code == 0
      check "selection: mode --indirect" in indirect.output
      check selectedRepos(indirect.output) == selectedRepos(all.output)
      let direct = list("--direct")
      check direct.code == 0
      check "selection: mode --direct" in direct.output

      # ---- (3) ARGV-ORDER INDEPENDENCE. ----------------------------------
      # One selector per stage, in six different argv arrangements. `--only`
      # and `--except` deliberately name DISJOINT sets: the loudness contract
      # tested by `t_develop_only_except_refuse_unknown_names` rejects even a
      # partial overlap as contradictory. `--only=lib-core` is the narrowing
      # witness in this all-stage pipeline; the dedicated `exceptCounted`
      # witness below proves that `--except` narrows at its fixed stage too.
      let permutations = [
        "--all --project=alpha --tag=libs --filter='lib-*' " &
          "--only=lib-core --except=tool-a",
        "--except=tool-a --only=lib-core --filter='lib-*' " &
          "--tag=libs --project=alpha --all",
        "--tag=libs --except=tool-a --all --filter='lib-*' " &
          "--project=alpha --only=lib-core",
        "--only=lib-core --all --except=tool-a --project=alpha " &
          "--filter='lib-*' --tag=libs",
        "--filter='lib-*' --tag=libs --project=alpha --all " &
          "--except=tool-a --only=lib-core",
        "--project=alpha --filter='lib-*' --except=tool-a --tag=libs " &
          "--only=lib-core --all",
      ]
      let reference = list(permutations[0])
      if reference.code != 0:
        checkpoint("develop --list output: " & reference.output)
      check reference.code == 0
      check selectedRepos(reference.output) == @["lib-core"]
      for perm in permutations:
        let got = list(perm)
        check got.code == reference.code
        if got.output != reference.output:
          checkpoint("argv order changed the answer for: " & perm &
            "\n--- reference ---\n" & reference.output &
            "\n--- got ---\n" & got.output)
        check got.output == reference.output

      # ---- (3b) the argv-order rule also binds the SINGLE-VALUED flags. ---
      #
      # The permutations above only rearrange DISTINCT stages, and every stage
      # is a set intersection or subtraction over the same universe, so they
      # commute: rearranging them cannot change the result set no matter how
      # the pipeline is written. The rule "the result never depends on argv
      # order" therefore has real content only where the same flag appears
      # TWICE, or where two mode flags appear together — and there the
      # last-one-wins parse DID depend on argv order:
      #
      #   repro develop --list --all --direct   -> mode --direct, 0 repo(s)
      #   repro develop --list --direct --all   -> mode --all,    5 repo(s)
      #
      # …the same flag set, two argv orders, two different answers. The
      # list-valued selectors (`--only` / `--except` / `--project` / `--tag`)
      # accumulate and were always order-free; the single-valued ones now
      # REFUSE rather than silently pick one.
      let twoModes = list("--all --direct")
      check twoModes.code != 0
      let twoModesErr = run(repro &
        " develop --list --all --direct --tool-provisioning=path", cwd = ws)
      check twoModesErr.code != 0
      check "two different selection modes" in twoModesErr.output
      check "--all" in twoModesErr.output and "--direct" in twoModesErr.output
      let twoModesFlipped = run(repro &
        " develop --list --direct --all --tool-provisioning=path", cwd = ws)
      check twoModesFlipped.code == twoModesErr.code

      let twoFilters = run(repro &
        " develop --list --filter='lib-*' --filter='tool-*'" &
        " --tool-provisioning=path", cwd = ws)
      check twoFilters.code != 0
      check "--filter was given twice with different values" in
        twoFilters.output

      let twoAts = run(repro &
        " develop --list --at=HEAD --at=main --tool-provisioning=path",
        cwd = ws)
      check twoAts.code != 0
      check "--at was given twice with different values" in twoAts.output

      # Repeating the SAME value is harmless — a script assembling argv from
      # several fragments legitimately does that — and stays accepted.
      let sameTwice = list("--all --all --filter='lib-*' --filter='lib-*'")
      check sameTwice.code == 0
      check selectedRepos(sameTwice.output) == @["lib-core", "lib-extra"]

      # ---- (4) the per-stage counts show the FIXED order narrowing. ------
      # 5 repos in the closure; alpha contributes 4 of them; `libs` keeps 2;
      # the glob keeps those 2; `--only=lib-core` keeps 1; the disjoint
      # `--except=tool-a` correctly keeps that 1. Overlapping the sets merely
      # to make the final stage narrow would violate the loud-failure contract.
      check stageLines(reference.output) == @[
        "selection: mode --all -> 5 repo(s)",
        "selection: project --project=alpha -> 4 repo(s)",
        "selection: tag --tag=libs -> 2 repo(s)",
        "selection: filter --filter=lib-* -> 2 repo(s)",
        "selection: only --only=lib-core -> 1 repo(s)",
        "selection: except --except=tool-a -> 1 repo(s)",
      ]

      # A separate accepted pipeline is required to observe `--except`
      # narrowing: after a disjoint `--only` has run, it is mathematically
      # impossible for `--except` to remove anything. Here no `--only` is
      # given, so `--except=tool-a` removes exactly one alpha repo at stage 6.
      let exceptCounted = list("--all --project=alpha --except=tool-a")
      check exceptCounted.code == 0
      check selectedRepos(exceptCounted.output) ==
        @["lib-core", "lib-extra", "shared"]
      check stageLines(exceptCounted.output) == @[
        "selection: mode --all -> 5 repo(s)",
        "selection: project --project=alpha -> 4 repo(s)",
        "selection: tag (not given) -> 4 repo(s)",
        "selection: filter (not given) -> 4 repo(s)",
        "selection: only (not given) -> 4 repo(s)",
        "selection: except --except=tool-a -> 3 repo(s)",
      ]

      # …and the counts themselves, not only the labels, depend on the order.
      # `--tag=libs` keeps 2 of 5; `--filter='*-a'` then keeps 0 of those 2.
      # Run the other way round the filter would keep 1 of 5 (`tool-a`) and the
      # tag would then keep 0 — same empty answer, different narrowing. A
      # report that cannot tell those apart cannot show a fixed order at all.
      let counted = list("--all --tag=libs --filter='*-a'")
      check counted.code == 0
      check stageLines(counted.output) == @[
        "selection: mode --all -> 5 repo(s)",
        "selection: project (not given) -> 5 repo(s)",
        "selection: tag --tag=libs -> 2 repo(s)",
        "selection: filter --filter=*-a -> 0 repo(s)",
        "selection: only (not given) -> 0 repo(s)",
        "selection: except (not given) -> 0 repo(s)",
      ]
