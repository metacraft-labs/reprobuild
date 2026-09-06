## NF-1 (Nix-Flake-Coexistence.md §5; Nix-Flake-Coexistence.milestones.org
## §NF-1) — **an `.envrc` reduced to the single call resolves the same inputs as
## the six `NIX_FLAKE_OVERRIDE_*` variables it replaces**.
##
##   > The override machinery currently lives in an external `direnv` plugin
##   > loaded by content hash (`source_url` with a `sha256-…` pin) and configured
##   > through six environment variables … **Direction: absorb it into
##   > Reprobuild sub-commands** — a verb that **emits the override arguments**
##   > for the current workspace, so `.envrc` becomes a single call rather than
##   > six environment variables and a content-pinned dependency.
##
## ## The bug this test is shaped against
##
## §5 records why "it emitted something" is not the assertion to make:
##
##   > a pinned plugin revision that did not implement
##   > `NIX_FLAKE_OVERRIDE_AUTO` made the knob **inert**, so the shell built
##   > against pins while `.envrc` declared it was building against siblings,
##   > silently, for weeks.
##
## A test that only compared two ARGUMENT STRINGS could not tell an applied
## override from an inert one — both sides would simply be text. So the
## headline assertion here is made over the **resolved input set**: each
## flake input's `locked` node as `nix` itself reports it, with the arguments
## applied. An override that does not reach nix leaves the input on its
## `flake.lock` pin, and the pin and the sibling are DIFFERENT DIRECTORIES in
## this fixture, so inertness is visible as a wrong path rather than as an
## absence nobody notices.
##
## ## The two forms being compared
##
## **New form** — one call: `repro flake override-args --all`.
##
## **Old form** — the six variables. The plugin that reads them is loaded by
## `source_url` from the network and is not vendored here, so the old form is
## reproduced from **this repository's own shipped implementation of the same
## rule**: `scripts/lib/dev_shell_overrides.sh`, the library `.envrc` and
## `just lint` both source. Its `dev_shell_auto_strip_suffixes` reads the
## suffix list out of a real six-variable `.envrc`, `dev_shell_siblings_root`
## resolves `NIX_FLAKE_OVERRIDE_SIBLINGS_ROOT`, `dev_shell_flake_input_repos`
## enumerates the flake's inputs and `dev_shell_strip_input_suffix` performs
## the longest-suffix strip. Composing those four IS the auto arm.
##
## ### Test-double policy: this reference model is the ONE deliberate stand-in
##
## Repository policy requires every stand-in to be justified where it is used,
## so: the four bash functions above are **real shipped code**, not a fake —
## they are the functions `just lint` runs, and `scripts/check_dev_shell_env.sh`
## already treats them as the authority on what the auto arm resolves. What is
## synthesized is only the six-line *composition* of them, because the
## component that would otherwise compose them (`flake_override_args_quoted`)
## lives behind a `source_url` and cannot be fetched in an offline test.
##
## This is a genuine cross-check rather than a tautology: the model is bash
## reading a `.envrc`, the implementation under test is Nim reading a lock set,
## and they share no code. Consequently the model would NOT catch a defect
## that both `dev_shell_overrides.sh` and the new verb share — that is the
## residue, stated rather than papered over, and it is covered from the other
## side by the `nix`-resolved arm, which asks nix instead of asking either
## implementation.
##
## Everything else is real: real git origins and clones, a real committed
## `repro.lock`, a real `flake.lock` produced by `nix flake lock`, the real
## `./build/bin/repro`.
##
## ## Fixture
##
##   <scratch>/ws/
##     repro.lock                    three repos, all in the develop set
##     suffixed/    flake.nix        input `suffixed-src`  → needs the strip
##     plain/       flake.nix        input `plain`         → no strip needed
##     unflakeable/ (no flake.nix)   input `unflakeable-src` → both forms skip
##     pins/{suffixed,plain,unflakeable,absent}/  what `flake.lock` names
##     app/  flake.nix  flake.lock  .envrc   the consumer, six-variable form
##
## `absent-src` is an input with no repo and no sibling at all, so the answer
## "the develop set decides" is distinguishable from "every declared input is
## overridden".
##
## ## Asserts
##
##   1. the single call's `(input, path)` pairs equal the six-variable form's,
##      exactly — not a subset, not a superset;
##   2. through real `nix`: the resolved input set is identical under the two
##      forms;
##   3. …and it DIFFERS from the no-override baseline, so (2) is not two ways
##      of being inert;
##   4. the suffixed input really is resolved to its sibling and not to its
##      pin, which is the assertion the `*_STRIP_SUFFIXES` mutation breaks;
##   5. the new `.envrc` needs no `NIX_FLAKE_OVERRIDE_*` variable at all: the
##      call is made with every one of the six unset, and answers the same.
##
## ## Mutation (from the milestone): drop `*_STRIP_SUFFIXES` handling ⇒ RED
##
## `suffixed-src` then matches no repo, its override disappears, and (1) fails
## on the pair set while (2) and (4) fail on the resolved path — the input
## falls back to `pins/suffixed`.
##
## Hermetic: fresh tempdir; system/user/VCS-private configuration layers
## silenced. Skips are announced on stdout with the reason, never silent: the
## `nix` arm is skipped loudly when `nix` is unavailable, and the pair-set arm
## still runs.

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

proc initGitRepo(gitBin, path: string) =
  createDir(path)
  discard requireGit(q(gitBin) & " init -b main " & q(path))
  discard requireGit(q(gitBin) & " -C " & q(path) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(path) &
    " config user.name \"NF1 Parity Tester\"")

proc seedGitOrigin(gitBin, originPath, workPath: string;
                   withFlake: bool): string =
  discard requireGit(q(gitBin) & " init --bare -b main " & q(originPath))
  initGitRepo(gitBin, workPath)
  if withFlake:
    writeFile(workPath / "flake.nix", "{ outputs = _: { }; }\n")
  writeFile(workPath / "which.txt", "sibling " & extractFilename(workPath) & "\n")
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
  "inputs_digest = \"nf1-envrc-parity\"\n" &
  "variants = []\n" &
  "packages = []\n" &
  "deps = [" & deps.join(", ") & "]\n"

proc overridePairs(argLine: string): seq[string] =
  ## `<input>=<path>` for every `--override-input` triple, sorted.
  let words = argLine.strip().splitWhitespace()
  var i = 0
  while i < words.len:
    if words[i] == "--override-input" and i + 2 < words.len:
      result.add(words[i + 1] & "=" & words[i + 2])
      i += 3
    else:
      inc i
  result.sort()

proc resolvedInputs(nixBin, flakeDir, overrideArgs, scratch: string):
    tuple[ok: bool; pairs: seq[string]; diagnostic: string] =
  ## `input=<resolved store-or-working path>` for every non-root node, as NIX
  ## reports it. This is the "resolved input set" the milestone names, and the
  ## only observation in this file that can tell an APPLIED override from an
  ## INERT one without trusting either implementation.
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
  let nodes = doc["locks"]["nodes"]
  for name, node in nodes.pairs:
    if name == doc["locks"]["root"].getStr(): continue
    if not node.hasKey("locked"): continue
    let locked = node["locked"]
    if locked.hasKey("path"):
      pairs.add(name & "=" & locked["path"].getStr())
  pairs.sort()
  (ok: true, pairs: pairs, diagnostic: "")

suite "NF-1: the single call replaces the six override variables":

  test "t_envrc_needs_no_override_env_vars":
    let gitBin = findExe("git")
    if gitBin.len == 0 or not fileExists(reproBinary):
      echo "SKIPPED (loudly): t_envrc_needs_no_override_env_vars needs " &
        "`git` on PATH and a built ./build/bin/repro; git=" &
        (if gitBin.len == 0: "MISSING" else: gitBin) & " repro=" &
        (if fileExists(reproBinary): "present" else: "UNBUILT")
      skip()
    else:
      let repro = absolutePath(reproBinary)
      let overridesLib = absolutePath("scripts/lib/dev_shell_overrides.sh")
      check fileExists(overridesLib)
      let scratch = createTempDir("nf1-envrc-parity-", "")
      defer: removeDir(scratch)

      let ws = scratch / "ws"
      createDir(ws)
      let app = ws / "app"
      createDir(app)

      # Three repos in the lock. `unflakeable` deliberately has NO flake.nix:
      # a `path:` input must be a flake, so BOTH forms have to skip it, and a
      # form that emitted it would produce a flake that does not evaluate.
      var deps: seq[string]
      for (name, withFlake) in [("suffixed", true), ("plain", true),
                                ("unflakeable", false)]:
        let origin = scratch / ("origin-" & name & ".git")
        let sha = seedGitOrigin(gitBin, origin, scratch / ("seed-" & name),
          withFlake)
        discard requireGit(q(gitBin) & " clone " & q("file://" & origin) &
          " " & q(ws / name))
        deps.add(lockDep(name, "file://" & origin, sha))
      writeFile(ws / "repro.lock", committedLock(deps))

      # What `flake.lock` names: a DIFFERENT directory per input, so "the
      # override was applied" and "the input stayed on its pin" are two
      # distinguishable observations rather than one.
      let pins = ws / "pins"
      for name in ["suffixed", "plain", "unflakeable", "absent"]:
        createDir(pins / name)
        writeFile(pins / name / "flake.nix", "{ outputs = _: { }; }\n")
        writeFile(pins / name / "which.txt", "pin " & name & "\n")

      # The consumer flake. The indentation is the one
      # `dev_shell_flake_input_repos` parses, because the six-variable
      # reference model below reads the inputs through that real function.
      proc inputLine(name, pinDir: string): string =
        "    " & name & ".url = " & '"' & "path:" & pinDir & '"' & ";\n"
      writeFile(app / "flake.nix",
        "{\n" &
        "  description = " & '"' & "NF-1 parity fixture" & '"' & ";\n\n" &
        "  inputs = {\n" &
        inputLine("suffixed-src", pins / "suffixed") &
        inputLine("plain", pins / "plain") &
        inputLine("unflakeable-src", pins / "unflakeable") &
        inputLine("absent-src", pins / "absent") &
        "  };\n\n" &
        "  outputs = _: { };\n" &
        "}\n")

      # The OLD `.envrc`: the six variables, verbatim in the shape this
      # repository ships. `dev_shell_auto_strip_suffixes` reads the suffix
      # list out of THIS file, so the reference model is configured the way a
      # real project configures the plugin.
      writeFile(app / ".envrc", """# shellcheck shell=bash
source scripts/lib/dev_shell_overrides.sh
export NIX_FLAKE_OVERRIDE_AUTO=1
export NIX_FLAKE_OVERRIDE_AUTO_STRIP_SUFFIXES=-src
export NIX_FLAKE_OVERRIDE_INPUTS=
export NIX_FLAKE_OVERRIDE_FLAKES=
export NIX_FLAKE_OVERRIDE_SIBLINGS=
export NIX_FLAKE_OVERRIDE_SIBLINGS_ROOT=
dev_shell_guard_override_knobs NIX_FLAKE_OVERRIDE_AUTO
dev_shell_write_fingerprint "$_fo_fingerprint" ""
eval "use flake . $(flake_override_args_quoted)"
""")

      putEnv("REPROBUILD_SYSTEM_CONFIG", scratch / "no-system.toml")
      putEnv("REPROBUILD_USER_CONFIG", scratch / "no-user.toml")
      putEnv("REPROBUILD_VCS_PRIVATE_CONFIG", scratch / "no-vcs.toml")
      defer:
        delEnv("REPROBUILD_SYSTEM_CONFIG")
        delEnv("REPROBUILD_USER_CONFIG")
        delEnv("REPROBUILD_VCS_PRIVATE_CONFIG")

      # ---- the OLD form, through this repository's shipped implementation --
      let modelScript = scratch / "six-variable-form.sh"
      writeFile(modelScript, """#!/usr/bin/env bash
# The auto arm of the six-variable form, composed from the four real
# functions scripts/lib/dev_shell_overrides.sh ships for exactly this rule.
set -uo pipefail
lib="$1"; flake="$2"; envrc="$3"; repo_root="$4"
# shellcheck disable=SC1090
source "$lib"
mapfile -t suffixes < <(dev_shell_auto_strip_suffixes "$envrc")
if [[ ${#suffixes[@]} -eq 0 ]]; then
  echo "the auto arm is not enabled in $envrc" >&2
  exit 3
fi
root="$(dev_shell_siblings_root "$repo_root")"
found=0
while IFS=$'\t' read -r input _repo; do
  [[ -n "$input" ]] || continue
  stripped="$(dev_shell_strip_input_suffix "$input" "${suffixes[@]}")"
  # The plugin refuses a sibling that is not a flake; `_dev_shell_probe_root`
  # in the same library documents that requirement.
  [[ -d "$root/$stripped" && -f "$root/$stripped/flake.nix" ]] || continue
  printf -- '--override-input %s path:%s\n' "$input" "$root/$stripped"
  found=1
done < <(dev_shell_flake_input_repos "$flake")
# Positive by construction, like every check in check_dev_shell_env.sh: a
# model that resolved nothing would agree with an inert implementation.
if [[ "$found" -ne 1 ]]; then
  echo "the six-variable model resolved NO override at all" >&2
  exit 4
fi
""")
      let modelRes = run("bash " & q(modelScript) & " " & q(overridesLib) &
        " " & q(app / "flake.nix") & " " & q(app / ".envrc") & " " & q(app))
      if modelRes.code != 0:
        checkpoint("six-variable model failed: " & modelRes.output)
      check modelRes.code == 0
      let oldArgs = modelRes.output.splitLines().join(" ").strip()
      check overridePairs(oldArgs) == @[
        "plain=path:" & (ws / "plain"),
        "suffixed-src=path:" & (ws / "suffixed"),
      ]

      # ---- the NEW form: one call, no NIX_FLAKE_OVERRIDE_* anywhere. ------
      # (5) Every one of the six is explicitly cleared for the invocation, so
      # a verb that had quietly grown a dependency on one of them would fail
      # here rather than in somebody's shell six weeks later.
      let clearSix = "env -u NIX_FLAKE_OVERRIDE_AUTO " &
        "-u NIX_FLAKE_OVERRIDE_AUTO_STRIP_SUFFIXES " &
        "-u NIX_FLAKE_OVERRIDE_INPUTS -u NIX_FLAKE_OVERRIDE_FLAKES " &
        "-u NIX_FLAKE_OVERRIDE_SIBLINGS -u NIX_FLAKE_OVERRIDE_SIBLINGS_ROOT "
      let outFile = scratch / "new.out"
      let errFile = scratch / "new.err"
      let newRes = run(clearSix & repro &
        " flake override-args --all --tool-provisioning=path >" & q(outFile) &
        " 2>" & q(errFile), cwd = app)
      let newArgs = readFile(outFile).strip()
      if newRes.code != 0:
        checkpoint("stdout: " & newArgs & "\nstderr: " & readFile(errFile))
      check newRes.code == 0

      # ---- (1) the two forms agree, pair for pair. ------------------------
      check overridePairs(newArgs) == overridePairs(oldArgs)

      # ---- the nix-resolved arm -------------------------------------------
      let nixBin = findExe("nix")
      if nixBin.len == 0:
        echo "SKIPPED (loudly): the resolved-input-set assertions of " &
          "t_envrc_needs_no_override_env_vars need `nix` on PATH to ask what " &
          "the arguments actually resolve to; nix=MISSING. The pair-set " &
          "assertions above still ran, but 'the override was applied' and " &
          "'the override was inert' were NOT distinguished by this run."
      else:
        let lockRes = run(q(nixBin) &
          " --extra-experimental-features 'nix-command flakes'" &
          " flake lock --offline " & q("path:" & app))
        if lockRes.code != 0 or not fileExists(app / "flake.lock"):
          echo "SKIPPED (loudly): `nix flake lock` could not produce a " &
            "flake.lock for the fixture, so the resolved-input-set " &
            "assertions cannot run. Output:\n" & lockRes.output
        else:
          let baseline = resolvedInputs(nixBin, app, "", scratch)
          let underNew = resolvedInputs(nixBin, app, newArgs, scratch)
          let underOld = resolvedInputs(nixBin, app, oldArgs, scratch)
          if not (baseline.ok and underNew.ok and underOld.ok):
            checkpoint("baseline: " & baseline.diagnostic &
              "\nnew: " & underNew.diagnostic &
              "\nold: " & underOld.diagnostic)
          check baseline.ok
          check underNew.ok
          check underOld.ok

          # (2) THE HEADLINE: the same resolved input set.
          check underNew.pairs == underOld.pairs

          # (3) …and not by both being inert. Without any override every
          # input sits on its `flake.lock` pin, and the pins are different
          # directories, so this comparison is what makes (2) mean
          # "the overrides were applied".
          check underNew.pairs != baseline.pairs

          # (4) the suffixed input specifically: resolved to the SIBLING, not
          # to the pin. This is the assertion the `*_STRIP_SUFFIXES` mutation
          # breaks, and it is stated as a path so the failure names the wrong
          # directory rather than a missing string.
          check ("suffixed-src=" & (ws / "suffixed")) in underNew.pairs
          check ("plain=" & (ws / "plain")) in underNew.pairs
          # The two inputs neither form overrides keep their pins under BOTH.
          check ("unflakeable-src=" & (pins / "unflakeable")) in underNew.pairs
          check ("absent-src=" & (pins / "absent")) in underNew.pairs
          # …and the baseline really did leave the suffixed input pinned, so
          # (3) is a difference in the right place.
          check ("suffixed-src=" & (pins / "suffixed")) in baseline.pairs
