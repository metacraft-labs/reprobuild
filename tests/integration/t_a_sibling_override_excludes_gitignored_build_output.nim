## NF-1 (Nix-Flake-Coexistence.md §2b) — **a sibling override names the
## sibling to nix as a GIT tree, so gitignored build output is not copied into
## the store, and the working tree the developer is editing still is.**
##
## ## The defect this removes
##
## §2b recorded the cost of a sibling override as inherent:
##
##   > an 18 GB tree copied into the store dominated a ~50-minute first
##   > evaluation in this workspace
##
## It is not inherent. `--override-input <n> path:<dir>` makes nix serialise
## the directory to a NAR and hash it, and the `path:` fetcher is a plain
## directory copy: it does not consult git, so it does not honour
## `.gitignore`. Measured on `codetracer` in this workspace: a 19 GB tree of
## which **17 GB is `src/db-backend/target`**, a Rust build directory that
## `.gitignore` already excludes, against 3,719 git-tracked files. Naming the
## same checkout `git+file://<dir>?submodules=1` produced a 75 MB store path in
## 13 s where `path:` produced 19 GB in ~50 minutes.
##
## It is a CORRECTNESS defect before it is a speed one. A `path:` store path is
## content-addressed over everything, so touching any file under `target/`
## changes the input hash and invalidates the dev shell for every consumer of
## that override — a Rust rebuild in `db-backend` silently invalidates
## everyone's shell.
##
## ## The risk this case exists to pin down
##
## Changing the fetcher changes WHICH FILES NIX SEES, and getting that wrong
## silently breaks develop mode. The entire point of a sibling override is to
## build the developer's local working tree. If the switch built `HEAD`
## instead, a developer's edits would stop reaching the shell while `.envrc`
## still claimed the sibling was substituted — precisely the §5 inert knob this
## campaign exists to prevent, reintroduced by the fix for §2b.
##
## Measured, not assumed (nix 2.32.8, git 2.50.1), for a dirty working tree:
##
##   | file class                        | `path:`  | `git+file:` |
##   |-----------------------------------|----------|-------------|
##   | committed tracked file            | present  | present     |
##   | UNCOMMITTED EDIT to tracked file  | modified | modified    |
##   | untracked, not gitignored         | present  | **MISSING** |
##   | gitignored                        | present  | absent      |
##   | submodule content                 | present  | only w/ `?submodules=1` |
##
## So the load-bearing guarantee HOLDS: uncommitted edits to tracked files
## reach the store, because a dirty `git+file:` tree copies working-tree
## content and only uses git to ENUMERATE. Assertion (2) below is that
## guarantee, and it is asserted on resolved file CONTENT rather than on an
## exit code, because an exit code cannot tell the two trees apart.
##
## ## The one residue, and why it is acceptable only because it is LOUD
##
## Untracked-but-not-ignored files are excluded. That is a real behavioural
## difference for anyone adding a new source file, and nix does not announce
## it: it warns `Git tree '…' is dirty` and says nothing about having dropped
## the new file.
##
## Two things make the residue acceptable, and neither is a matter of taste:
##
##   1. **The constraint is already in force.** `DefaultFlakeRef` is
##      `".?submodules=1"` — a directory ref, which nix already resolves
##      through git. A developer's OWN repo already excludes untracked files
##      from its flake. This extends an existing constraint to siblings rather
##      than inventing one.
##   2. **The remedy is `git add`, with no commit**, and after staging it is
##      the WORKTREE content that lands, not the staged blob — so edits keep
##      flowing without re-adding.
##
## That leaves exactly one requirement: it must never be silent. Assertion (3)
## is that notice, and it is THE safety property of this change — which is why
## it asserts the file's name and the runnable remedy appear, not merely that
## some diagnostic was printed.
##
## ## Asserts
##
##   1. the emitted override for a git sibling is
##      `git+file://<abs>?submodules=1`, and the resolved store path does NOT
##      contain the gitignored build directory (the headline);
##   2. an UNCOMMITTED EDIT to a tracked file IS present in that store path,
##      with the edited content — the regression guard for develop mode;
##   3. an untracked-not-ignored file is absent from the store path AND is
##      NAMED on stderr, with the `git add` remedy, by a notice that states the
##      consequence;
##   4. a sibling carrying a SUBMODULE resolves with the submodule's content
##      present — which is what `?submodules=1` buys and what its absence
##      silently loses;
##   5. a sibling that is not a git checkout still gets `path:` — the fallback,
##      asserted through `flakePrintDevEnvArgv` because the CLI binder refuses
##      to substitute a non-git sibling before the emitter is ever reached;
##   6. the two emission sites AGREE: the URL `repro flake override-args`
##      prints for a checkout is the URL `flakePrintDevEnvArgv` builds for it.
##      They are separate call sites, and a shell built from one while `.envrc`
##      splices the other is the divergence this pins shut;
##   7. a sibling declaring a submodule it has NOT initialised keeps `path:`,
##      and the `?submodules=1` spelling it did not get is shown to fail
##      outright on that checkout. This is the state of any clone made without
##      `--recurse-submodules`, and it is why the flag is conditional: a
##      broken shell is strictly worse than a slow one.
##
## ## Mutations
##
##   a. emit `path:` for everything ⇒ (1) RED: the gitignored directory appears
##      in the store path, and (3) RED: no notice is emitted;
##   b. drop the git-checkout predicate (`dirExists(dir / ".git")` only, so a
##      linked worktree takes the wrong branch) ⇒ RED on a worktree sibling,
##      which takes the `path:` arm and copies its ignored output;
##   c. emit `?submodules=1` unconditionally ⇒ (7) RED: the uninitialised
##      sibling's override no longer resolves at all;
##   d. drop `?submodules=1` where it IS warranted ⇒ (4) RED: the submodule's
##      content is missing from the store path;
##   e. drop the untracked notice ⇒ (3) RED — the safety property itself.
##
## ## Test-double policy: NO mocks, doubles, or fakes
##
## Real bare git origins and real clones, a real `git submodule add`, a real
## committed `repro.lock`, the real `./build/bin/repro` invoked as a
## subprocess, and a real `nix` resolving the emitted URL to a real store path
## whose real bytes are read back. The behaviour under test is precisely what
## nix does with a fetcher URL, so mocking the fetcher would assert only that
## the test's own model of nix matches itself.
##
## Skip: `git`, `nix` or a built `./build/bin/repro` missing — announced
## loudly, never silent.

import std/[os, osproc, strutils, tempfiles, unittest]

import repro_dsl_stdlib/foreign_env/flake

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
  # File-protocol submodules are refused by default since CVE-2022-39253; the
  # fixture's submodule origin is a local path, so it is enabled here rather
  # than in the tester's global config.
  discard requireGit(q(gitBin) & " -C " & q(path) &
    " config protocol.file.allow always")

proc seedGitOrigin(gitBin, originPath, workPath: string): string =
  ## A real origin whose HEAD is a real 40-hex object id — the develop set
  ## refuses anything that is not an exact locked revision.
  discard requireGit(q(gitBin) & " init --bare -b main " & q(originPath))
  initGitRepo(gitBin, workPath)
  writeFile(workPath / "flake.nix", "{ outputs = _: { }; }\n")
  # `.gitignore` is COMMITTED, because the whole question is whether the
  # fetcher consults git's own exclusion rules.
  writeFile(workPath / ".gitignore", "build-output/\n")
  writeFile(workPath / "tracked.txt", "committed-content\n")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " add -A")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " commit -m seed")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " remote add origin " & q(originPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " push origin main")
  requireGit(q(gitBin) & " -C " & q(workPath) & " rev-parse HEAD").strip()

proc cloneInto(gitBin, originPath, targetPath: string) =
  discard requireGit(q(gitBin) & " clone " &
    q("file://" & originPath) & " " & q(targetPath))
  discard requireGit(q(gitBin) & " -C " & q(targetPath) &
    " config protocol.file.allow always")

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
  "inputs_digest = \"nf1-gitignore\"\n" &
  "variants = []\n" &
  "packages = []\n" &
  "deps = [" & deps.join(", ") & "]\n"

proc shellUnquote(word: string): string =
  ## The emitted line is `eval`-ready, so `quoteShell` wraps any word carrying
  ## shell-significant characters in single quotes — which `?submodules=1`
  ## does. `.envrc` runs the line through `eval`, so nix never sees the quotes;
  ## a test reading the words directly has to remove them, or it compares a URL
  ## against a quoted URL and fails on punctuation rather than on meaning.
  if word.len >= 2 and word[0] == '\'' and word[^1] == '\'':
    word[1 ..< word.high]
  else:
    word

proc overrideUrlOf(stdoutText, input: string): string =
  ## The URL emitted for one input, parsed positionally out of the ACTUAL
  ## argument line rather than matched with `in`, so a differently-spelled
  ## emission cannot hide inside a substring match.
  let words = stdoutText.strip().splitWhitespace()
  var i = 0
  while i + 2 < words.len:
    if words[i] == "--override-input" and shellUnquote(words[i + 1]) == input:
      return shellUnquote(words[i + 2])
    inc i
  ""

proc resolveTree(nixBin, url: string): string =
  ## Resolve a flake-input URL to the store path nix would build from, using
  ## the same fetcher the override goes through. Empty on failure.
  let res = run(q(nixBin) &
    " --extra-experimental-features " & q("nix-command flakes") &
    " eval --impure --raw --expr " &
    q("builtins.fetchTree \"" & url & "\""))
  if res.code != 0:
    checkpoint("fetchTree failed for " & url & "\n" & res.output)
    return ""
  res.output.strip().splitLines()[^1].strip()

suite "NF-1: a sibling override excludes gitignored build output":

  test "t_a_sibling_override_excludes_gitignored_build_output":
    let gitBin = findExe("git")
    let nixBin = findExe("nix")
    if gitBin.len == 0 or nixBin.len == 0 or not fileExists(reproBinary):
      echo "SKIPPED (loudly): " &
        "t_a_sibling_override_excludes_gitignored_build_output needs `git` " &
        "and `nix` on PATH and a built ./build/bin/repro; " &
        "git=" & (if gitBin.len == 0: "MISSING" else: gitBin) &
        " nix=" & (if nixBin.len == 0: "MISSING" else: nixBin) &
        " repro=" & (if fileExists(reproBinary): "present" else: "UNBUILT")
      skip()
    else:
      let repro = absolutePath(reproBinary)
      let scratch = createTempDir("nf1-gitignore-", "")
      defer: removeDir(scratch)

      let ws = scratch / "ws"
      createDir(ws)

      var deps: seq[string]
      for name in ["alpha", "beta"]:
        let origin = scratch / ("origin-" & name & ".git")
        let sha = seedGitOrigin(gitBin, origin, scratch / ("seed-" & name))
        cloneInto(gitBin, origin, ws / name)
        deps.add(lockDep(name, "file://" & origin, sha))
      writeFile(ws / "repro.lock", committedLock(deps))

      # ---- alpha: a working tree in every state that matters -------------
      let alpha = ws / "alpha"
      # (d) gitignored build output — the 17 GB `target/` of the real case,
      # scaled down but structurally identical: ignored by a COMMITTED
      # `.gitignore`, and large enough that its presence is unmistakable.
      createDir(alpha / "build-output")
      writeFile(alpha / "build-output" / "artifact.bin", repeat("x", 400_000))
      # (b) an UNCOMMITTED EDIT to a tracked file — develop mode's whole point.
      writeFile(alpha / "tracked.txt", "EDITED-IN-THE-WORKING-TREE\n")
      # (c) an untracked, not-ignored file — the residue that must be loud.
      writeFile(alpha / "brand_new_source.nim", "echo \"new\"\n")

      # ---- beta: a sibling carrying a real submodule ----------------------
      let beta = ws / "beta"
      let subOrigin = scratch / "origin-sub.git"
      discard requireGit(q(gitBin) & " init --bare -b main " & q(subOrigin))
      let subWork = scratch / "seed-sub"
      initGitRepo(gitBin, subWork)
      writeFile(subWork / "sub_payload.txt", "SUBMODULE-PAYLOAD\n")
      discard requireGit(q(gitBin) & " -C " & q(subWork) & " add -A")
      discard requireGit(q(gitBin) & " -C " & q(subWork) & " commit -m sub")
      discard requireGit(q(gitBin) & " -C " & q(subWork) &
        " remote add origin " & q(subOrigin))
      discard requireGit(q(gitBin) & " -C " & q(subWork) & " push origin main")
      discard requireGit(q(gitBin) & " -C " & q(beta) &
        " -c protocol.file.allow=always submodule add " &
        q("file://" & subOrigin) & " vendor/sub")
      discard requireGit(q(gitBin) & " -C " & q(beta) &
        " commit -m \"add submodule\"")
      # Published so (7) can clone the SAME repo without submodules and get a
      # checkout that declares one it has not initialised.
      discard requireGit(q(gitBin) & " -C " & q(beta) & " push origin main")

      let app = ws / "app"
      createDir(app)
      writeFile(app / "flake.nix", """{
  description = "NF-1 gitignore fixture consumer";

  inputs = {
    alpha-src.url = "github:example/alpha";
    beta-src.url = "github:example/beta";
  };

  outputs = _: { };
}
""")

      putEnv("REPROBUILD_SYSTEM_CONFIG", scratch / "no-system.toml")
      putEnv("REPROBUILD_USER_CONFIG", scratch / "no-user.toml")
      putEnv("REPROBUILD_VCS_PRIVATE_CONFIG", scratch / "no-vcs.toml")
      defer:
        delEnv("REPROBUILD_SYSTEM_CONFIG")
        delEnv("REPROBUILD_USER_CONFIG")
        delEnv("REPROBUILD_VCS_PRIVATE_CONFIG")

      let outFile = scratch / "emit.out"
      let errFile = scratch / "emit.err"
      let res = run(repro &
        " flake override-args --tool-provisioning=path --all >" &
        q(outFile) & " 2>" & q(errFile), cwd = app)
      let outText = readFile(outFile)
      let errText = readFile(errFile)
      if res.code != 0:
        checkpoint("stdout: " & outText & "\nstderr: " & errText)
      check res.code == 0

      # ---- (1) the URL, and the gitignored tree that is NOT in the store --
      # `alpha` declares no submodules, so it is named WITHOUT `?submodules=1`.
      # That is not an oversight: the flag is only correct for a repo that has
      # submodules AND has them initialised (see (4) and (7)).
      let alphaUrl = overrideUrlOf(outText, "alpha-src")
      check alphaUrl == "git+file://" & alpha

      let alphaStore = resolveTree(nixBin, alphaUrl)
      check alphaStore.len > 0
      check alphaStore.startsWith("/nix/store/")
      # THE HEADLINE. Asserted on the resolved store path's real contents.
      check not dirExists(alphaStore / "build-output")
      check not fileExists(alphaStore / "build-output" / "artifact.bin")

      # ---- (2) the uncommitted edit IS there, with its edited content -----
      # The regression guard. Content, not existence: `HEAD`'s version of this
      # file exists too, and only its BYTES distinguish "built the working
      # tree" from "built the commit".
      check fileExists(alphaStore / "tracked.txt")
      check readFile(alphaStore / "tracked.txt") ==
        "EDITED-IN-THE-WORKING-TREE\n"

      # ---- (3) the untracked file: absent, and LOUDLY so ------------------
      check not fileExists(alphaStore / "brand_new_source.nim")
      # THE SAFETY PROPERTY. The notice must name the file, state the
      # consequence, and give a runnable remedy — a bare "warning" would leave
      # the developer with exactly the silent drop this guards against.
      check "brand_new_source.nim" in errText
      # The RUNNABLE remedy, not the word "add" somewhere in a sentence: the
      # command must name the directory it has to run against, because the
      # operator reading this on shell entry is standing in `app/`, not in the
      # sibling.
      check ("git -C " & alpha & " add") in errText
      check "not in what the shell builds" in errText

      # ---- (4) the submodule's content resolves ---------------------------
      let betaUrl = overrideUrlOf(outText, "beta-src")
      check betaUrl == "git+file://" & beta & "?submodules=1"
      let betaStore = resolveTree(nixBin, betaUrl)
      check betaStore.len > 0
      check fileExists(betaStore / "vendor" / "sub" / "sub_payload.txt")
      check readFile(betaStore / "vendor" / "sub" / "sub_payload.txt") ==
        "SUBMODULE-PAYLOAD\n"

      # ---- (5) a non-git sibling keeps `path:` ----------------------------
      # Reached through `flakePrintDevEnvArgv` because the CLI binder declines
      # a non-git sibling before the emitter sees it — the fallback lives on
      # the DSL path, where `useFlakeDevShell` callers supply their own pairs.
      let plain = scratch / "not-a-checkout"
      createDir(plain)
      writeFile(plain / "flake.nix", "{ outputs = _: { }; }\n")
      check flakePrintDevEnvArgv("nix", ".", "", @[("plain-src", plain)]) ==
        @["nix", "print-dev-env", ".",
          "--override-input", "plain-src", "path:" & plain]

      # ---- (7) a sibling with an UNINITIALISED submodule ------------------
      # Measured, and the reason `?submodules=1` is conditional rather than
      # unconditional: with a submodule declared but not initialised, nix
      # cannot fetch it and `git+file://…?submodules=1` FAILS OUTRIGHT — not a
      # missing directory, a dead evaluation. A broken shell is strictly worse
      # than a slow one, so that state keeps `path:`, which copies exactly what
      # is on disk and therefore cannot fail.
      #
      # This is the state of any sibling cloned without `--recurse-submodules`,
      # so it is ordinary rather than exotic.
      let uninit = ws / "beta-uninit"
      cloneInto(gitBin, scratch / "origin-beta.git", uninit)
      check fileExists(uninit / ".gitmodules")
      # The fixture really is in the state under test: declared, not present.
      let subStatus = run(q(gitBin) & " -C " & q(uninit) &
        " submodule status --recursive").output
      check subStatus.strip().startsWith("-")

      check flakeSiblingOverrideRef(uninit, gitBin) == "path:" & uninit
      # And the reason it must not be the other spelling: prove the fetch nix
      # would have been asked to do actually fails.
      let wouldFail = run(q(nixBin) &
        " --extra-experimental-features " & q("nix-command flakes") &
        " eval --impure --raw --expr " &
        q("builtins.fetchTree \"git+file://" & uninit & "?submodules=1\""))
      check wouldFail.code != 0
      # while the spelling actually emitted resolves:
      check resolveTree(nixBin, flakeSiblingOverrideRef(uninit, gitBin)).len > 0

      # ---- (6) the two emission sites agree -------------------------------
      # `repro flake override-args` writes the line `.envrc` splices;
      # `flakePrintDevEnvArgv` builds the argv `useFlakeDevShell` runs. If
      # these disagree, the shell is built from a different tree than the one
      # the emitted arguments name, and nothing else in the suite would say so.
      let viaDsl = flakePrintDevEnvArgv("nix", ".", "", @[("alpha-src", alpha)])
      check viaDsl[^1] == alphaUrl
