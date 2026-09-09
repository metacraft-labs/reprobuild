## NF-1 (Nix-Flake-Coexistence.md §2, §3.3; Nix-Flake-Coexistence.milestones.org
## §NF-1) — **a repo the develop-set selection leaves out keeps its
## `flake.lock` revision, even though a checkout of it sits right beside the
## flake**.
##
## This is the other half of `t_emitted_overrides_match_the_develop_set`, and
## it is a separate test because it asserts a different KIND of thing. That one
## asserts what the command PRINTS; this one asserts what `nix` RESOLVES. Under
## `NIX_FLAKE_OVERRIDE_AUTO` the mere presence of a directory beside the repo
## is what substitutes an input:
##
##   > `AUTO` is all-or-nothing, while `repro develop` selects a set.
##
## So "a checkout exists beside it" is precisely the condition under which the
## old mechanism substitutes and the new one must not.
##
## ## Why this is asserted through `nix` and not through a string
##
## §5's failure is a mechanism that looked like it was working while doing
## nothing:
##
##   > a pinned plugin revision that did not implement
##   > `NIX_FLAKE_OVERRIDE_AUTO` made the knob **inert** … silently, for weeks.
##
## An implementation that emitted NOTHING AT ALL would satisfy "no override for
## `pinned`" trivially, and would be the very defect this campaign exists to
## remove. So the claim is made as a PAIR of resolved paths from one `nix flake
## metadata` run:
##
##   * `kept-src`   resolves to the SIBLING WORKING TREE  — the override is live;
##   * `pinned-src` resolves to its `flake.lock` PIN      — selection is honoured;
##
## and the two target directories are distinct, so no single answer can satisfy
## both by accident. An inert implementation fails the first; an `AUTO`-shaped
## implementation fails the second.
##
## ## Fixture
##
##   <scratch>/ws/
##     repro.lock              both repos, both develop-manageable
##     kept/     flake.nix     a real clone beside the flake
##     pinned/   flake.nix     a real clone beside the flake — NOT selected
##     pins/{kept,pinned}/     what `flake.lock` names; distinct content
##     app/ flake.nix flake.lock
##
## ## Asserts
##
##   1. the premise: `ws/pinned` really is a checkout, really is a flake, and
##      really is in the lock set — otherwise this test would be asserting that
##      an absent repo is absent;
##   2. the emitted arguments name `kept-src` and never mention `pinned-src`;
##   3. through real `nix`: `kept-src` → the sibling, `pinned-src` → the pin;
##   4. under `--all` the SAME workspace does substitute `pinned-src`, so (3)
##      is a property of the selection and not of the fixture.
##
## Test-double policy: NO mocks, doubles or fakes. Real git origins and clones,
## a real committed `repro.lock`, a real `flake.lock` written by `nix flake
## lock`, the real `./build/bin/repro`, real `nix` evaluation (offline).
##
## Hermetic: fresh tempdir; system/user/VCS-private configuration layers
## silenced. Skips are announced with their reason on stdout, never silent.

import std/[algorithm, json, os, osproc, strutils, tempfiles, unittest]

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

proc seedGitOrigin(gitBin, originPath, workPath: string): string =
  discard requireGit(q(gitBin) & " init --bare -b main " & q(originPath))
  createDir(workPath)
  discard requireGit(q(gitBin) & " init -b main " & q(workPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.name \"NF1 Selection Tester\"")
  writeFile(workPath / "flake.nix", "{ outputs = _: { }; }\n")
  writeFile(workPath / "which.txt",
    "sibling " & extractFilename(workPath) & "\n")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " add -A")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " commit -m seed")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " remote add origin " & q(originPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " push origin main")
  requireGit(q(gitBin) & " -C " & q(workPath) & " rev-parse HEAD").strip()

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
  "inputs_digest = \"nf1-not-substituted\"\n" &
  "variants = []\n" &
  "packages = []\n" &
  "deps = [" & deps.join(", ") & "]\n"

proc resolvedInputs(nixBin, flakeDir, overrideArgs, scratch: string):
    tuple[ok: bool; pairs: seq[string]; diagnostic: string] =
  let cmd = q(nixBin) &
    " --extra-experimental-features 'nix-command flakes'" &
    " flake metadata --json --no-write-lock-file --offline " &
    overrideArgs & " " & q("path:" & flakeDir)
  # stdout and stderr are captured SEPARATELY. `nix flake metadata` writes a
  # "not writing modified lock file" notice to stderr on every run with an
  # override, and `execCmdEx` merges the two streams by default — which makes
  # the JSON document unparseable for a reason that has nothing to do with the
  # overrides under test.
  let jsonFile = scratch / "nix-metadata.json"
  let errFile = scratch / "nix-metadata.err"
  let res = execCmdEx(cmd & " >" & q(jsonFile) & " 2>" & q(errFile))
  if res.exitCode != 0:
    return (ok: false, pairs: @[],
            diagnostic: cmd & "\n" & readFile(errFile))
  var doc: JsonNode
  try:
    doc = parseJson(readFile(jsonFile))
  except CatchableError as err:
    return (ok: false, pairs: @[], diagnostic: "unparseable metadata: " & err.msg)
  var pairs: seq[string]
  let rootName = doc["locks"]["root"].getStr()
  for name, node in doc["locks"]["nodes"].pairs:
    if name == rootName: continue
    if not node.hasKey("locked"): continue
    # Two spellings reach nix for the same working tree — `path:<dir>` sets
    # `locked.path`, `git+file://<dir>[?query]` sets `locked.type = "git"` and
    # `locked.url = file://<dir>`. Both are reduced to the directory, because
    # the subject here is WHICH tree an input resolved to. Reading only
    # `locked.path` would silently shrink the set instead of failing, making
    # "not substituted" and "substituted as a git tree" indistinguishable.
    let locked = node["locked"]
    if locked.hasKey("path"):
      pairs.add(name & "=" & locked["path"].getStr())
    elif locked.hasKey("url") and locked{"type"}.getStr() == "git":
      var url = locked["url"].getStr()
      if url.startsWith("file://"):
        url = url[len("file://") .. ^1]
        let q = url.find('?')
        if q >= 0: url = url[0 ..< q]
        pairs.add(name & "=" & url)
  pairs.sort()
  (ok: true, pairs: pairs, diagnostic: "")

suite "NF-1: selection decides substitution, presence on disk does not":

  test "t_a_repo_not_in_develop_mode_is_not_substituted":
    let gitBin = findExe("git")
    if gitBin.len == 0 or not fileExists(reproBinary):
      echo "SKIPPED (loudly): t_a_repo_not_in_develop_mode_is_not_substituted " &
        "needs `git` on PATH and a built ./build/bin/repro; git=" &
        (if gitBin.len == 0: "MISSING" else: gitBin) & " repro=" &
        (if fileExists(reproBinary): "present" else: "UNBUILT")
      skip()
    else:
      let repro = absolutePath(reproBinary)
      let scratch = createTempDir("nf1-not-substituted-", "")
      defer: removeDir(scratch)

      let ws = scratch / "ws"
      createDir(ws)
      let app = ws / "app"
      createDir(app)

      var deps: seq[string]
      for name in ["kept", "pinned"]:
        let origin = scratch / ("origin-" & name & ".git")
        let sha = seedGitOrigin(gitBin, origin, scratch / ("seed-" & name))
        discard requireGit(q(gitBin) & " clone " & q("file://" & origin) &
          " " & q(ws / name))
        deps.add(lockDep(name, "file://" & origin, sha))
      writeFile(ws / "repro.lock", committedLock(deps))

      let pins = ws / "pins"
      for name in ["kept", "pinned"]:
        createDir(pins / name)
        writeFile(pins / name / "flake.nix", "{ outputs = _: { }; }\n")
        writeFile(pins / name / "which.txt", "pin " & name & "\n")

      proc inputLine(name, pinDir: string): string =
        "    " & name & ".url = " & '"' & "path:" & pinDir & '"' & ";\n"
      writeFile(app / "flake.nix",
        "{\n" &
        "  inputs = {\n" &
        inputLine("kept-src", pins / "kept") &
        inputLine("pinned-src", pins / "pinned") &
        "  };\n\n" &
        "  outputs = _: { };\n" &
        "}\n")

      putEnv("REPROBUILD_SYSTEM_CONFIG", scratch / "no-system.toml")
      putEnv("REPROBUILD_USER_CONFIG", scratch / "no-user.toml")
      putEnv("REPROBUILD_VCS_PRIVATE_CONFIG", scratch / "no-vcs.toml")
      defer:
        delEnv("REPROBUILD_SYSTEM_CONFIG")
        delEnv("REPROBUILD_USER_CONFIG")
        delEnv("REPROBUILD_VCS_PRIVATE_CONFIG")

      # ---- (1) the premise. ----------------------------------------------
      # Without these, a green run could mean "the excluded repo was never
      # there", which is a different (and uninteresting) fact.
      check dirExists(ws / "pinned" / ".git")
      check fileExists(ws / "pinned" / "flake.nix")
      # `repro develop --list` takes the cwd as the workspace root verbatim,
      # so the root is named explicitly here. (The emitter under test ASCENDS
      # to it instead, because `.envrc` runs in the repo rather than at the
      # workspace root — that difference is exercised by every `emit` call
      # below, which passes no `--workspace-root` at all.)
      let listed = run(repro & " develop --list --workspace-root=" & q(ws) &
        " --tool-provisioning=path 2>/dev/null", cwd = app)
      check listed.code == 0
      check "pinned" in listed.output
      check "kept" in listed.output

      proc emit(flags: string): tuple[code: int; outText, errText: string] =
        let outFile = scratch / "emit.out"
        let errFile = scratch / "emit.err"
        let res = run(repro & " flake override-args --tool-provisioning=path " &
          flags & " >" & q(outFile) & " 2>" & q(errFile), cwd = app)
        (code: res.code, outText: readFile(outFile).strip(),
         errText: readFile(errFile))

      # ---- (2) what is printed. ------------------------------------------
      let selective = emit("--only=kept")
      if selective.code != 0:
        checkpoint("stdout: " & selective.outText &
          "\nstderr: " & selective.errText)
      check selective.code == 0
      check ("--override-input kept-src git+file://" & (ws / "kept")) in
        selective.outText
      check "pinned-src" notin selective.outText
      check (ws / "pinned") notin selective.outText

      let everything = emit("--all")
      check everything.code == 0

      # ---- (3)/(4) what nix RESOLVES. ------------------------------------
      let nixBin = findExe("nix")
      if nixBin.len == 0:
        echo "SKIPPED (loudly): the resolved-input assertions of " &
          "t_a_repo_not_in_develop_mode_is_not_substituted need `nix` on " &
          "PATH; nix=MISSING. The printed-argument assertions above ran, but " &
          "'the surviving input kept its LOCKED revision' was NOT verified " &
          "against nix by this run, and neither was 'the selected input's " &
          "override actually reached nix'."
      else:
        let lockRes = run(q(nixBin) &
          " --extra-experimental-features 'nix-command flakes'" &
          " flake lock --offline " & q("path:" & app))
        if lockRes.code != 0 or not fileExists(app / "flake.lock"):
          echo "SKIPPED (loudly): `nix flake lock` could not produce a " &
            "flake.lock for the fixture, so the resolved-input assertions " &
            "cannot run. Output:\n" & lockRes.output
        else:
          let underSelection = resolvedInputs(nixBin, app, selective.outText, scratch)
          if not underSelection.ok:
            checkpoint(underSelection.diagnostic)
          check underSelection.ok
          # (3a) the override IS live — this is what an inert mechanism fails.
          check ("kept-src=" & (ws / "kept")) in underSelection.pairs
          # (3b) …and the unselected repo kept the revision `flake.lock` names,
          # with its checkout sitting right there beside the flake.
          check ("pinned-src=" & (pins / "pinned")) in underSelection.pairs
          check ("pinned-src=" & (ws / "pinned")) notin underSelection.pairs

          # (4) the same workspace, the whole develop set: now it IS
          # substituted. Without this, (3b) could be explained by the input
          # being unreachable rather than by the selection.
          let underAll = resolvedInputs(nixBin, app, everything.outText, scratch)
          check underAll.ok
          check ("pinned-src=" & (ws / "pinned")) in underAll.pairs
          check ("kept-src=" & (ws / "kept")) in underAll.pairs
