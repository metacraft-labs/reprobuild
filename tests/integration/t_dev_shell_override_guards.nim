## Dev-shell honesty guards — `scripts/lib/dev_shell_overrides.sh`.
##
## Three defects, one shape: a mechanism that looks authoritative while being
## ignored, so the shell a developer is standing in is built from something
## other than what `.envrc` says.
##
##   1. `.envrc` exported `NIX_FLAKE_OVERRIDE_AUTO=1` while pinning a
##      flake-overrides plugin revision that implements only
##      `NIX_FLAKE_OVERRIDE_INPUTS` / `_FLAKES`. The knob was inert:
##      `flake_override_args_quoted` printed nothing, `use flake` ran on the
##      PINNED inputs, and no diagnostic appeared anywhere. A developer with a
##      correct sibling checkout was building against something else entirely.
##
##   2. An input overridden to `path:../<sibling>` makes that working tree a
##      build input, but nix-direnv's watch set is exactly {`$HOME/.direnvrc`,
##      `$HOME/.config/direnv/direnvrc`, `flake.nix`, `flake.lock`,
##      `devshell.toml`} — none of which mentions a sibling. The cached
##      `.direnv/flake-profile-*.rc` therefore keeps exporting the store path
##      the sibling was copied to at write time, for as long as the profile
##      survives. Measured: `RUNQUOTA_SRC` fifteen days and fifty-nine commits
##      stale while direnv reported "using cached dev shell", which failed
##      `just lint` for everyone with a spurious `undeclared identifier:
##      'ExtensionCellWire'`.
##
##   3. The auto arm resolves a sibling by the STRIPPED INPUT NAME, so an
##      input whose name does not match its repository's directory is silently
##      never overridden at all — and defect 2's fingerprint reconciles only
##      the inputs that WERE overridden, so it cannot see one that never was.
##      `stackable-hooks-src` (repository `nim-stackable-hooks`) was the one
##      such input in this flake: it kept building from a lock pin 30 commits
##      behind, across the commit that added `WindowsInjectionResult.rootPid`
##      / `.monitoringSkipped` / `.skipReason` and `runWithMonitorShim`'s
##      `env` — all four read by io-mon's Windows arm — while every other
##      sibling-backed input tracked its working tree and every guard here
##      stayed green.
##
## What is exercised here is the real library, driven by `bash`, against real
## `git` checkouts on the real filesystem — no process, git, or filesystem
## boundary is stubbed.
##
## Mocks, and why (per the repository policy on justifying every mock):
##
##   * `fixtureOldPlugin` / `fixtureNewPlugin` are two-function stand-ins for
##     the flake-overrides plugin's ONE public entry point,
##     `flake_override_args_quoted`. They are not a convenience: the defect is
##     precisely "the plugin that gets loaded is not the plugin the file
##     assumes", and pinning the test to any single published revision would
##     make the test a test of that revision rather than of the contract. The
##     stand-ins model the two observable behaviours — honours the auto knob,
##     ignores it — which is the entire contract the guard probes for.
##   * `realPluginCandidates` closes the loop back to reality: when a genuine
##     plugin build is on this machine (a `../direnv-nix-flake-overrides`
##     checkout, or a copy in direnv's `source_url` CAS whose sha256 matches
##     the pin in `.envrc`), the guard is run against it too and must agree
##     with what that build actually implements. That case is skipped only
##     when no such artifact exists, and it announces the skip.
##
## Skip rules: `bash` or `git` missing on PATH.

import std/[base64, os, sequtils, strutils, tempfiles, times, unittest]

import repro_test_support

proc repoRoot(): string =
  currentSourcePath().parentDir.parentDir.parentDir

proc libPath(): string =
  repoRoot() / "scripts" / "lib" / "dev_shell_overrides.sh"

proc checkScript(): string =
  repoRoot() / "scripts" / "check_dev_shell_env.sh"

proc runBash(script: string; cwd: string): CmdResult =
  let bash = findExe("bash")
  runShell(shellCommand(@[bash, "-c", script]), cwd = cwd)

## A plugin that translates only the explicit `NIX_FLAKE_OVERRIDE_INPUTS`
## list — the observable behaviour of the `sha256-bqkW…` revision `.envrc`
## used to pin, and the whole of defect 1.
const fixtureOldPlugin = """
flake_override_args_quoted() {
  local raw="${NIX_FLAKE_OVERRIDE_INPUTS:-}"
  [[ -z "$raw" ]] && return 0
  printf "'--override-input' '%s' '%s' " "${raw%%=*}" "${raw#*=}"
}
"""

## A plugin that also honours the sibling/auto arms, including the `-src`
## suffix stripping every input in this repository's flake depends on — the
## observable behaviour of the revision the published URL serves today.
const fixtureNewPlugin = """
flake_override_args_quoted() {
  local raw="${NIX_FLAKE_OVERRIDE_INPUTS:-}"
  if [[ -n "$raw" ]]; then
    printf "'--override-input' '%s' '%s' " "${raw%%=*}" "${raw#*=}"
  fi
  local fk="${NIX_FLAKE_OVERRIDE_FLAKES:-}"
  if [[ -n "$fk" ]]; then
    printf "'--override-flake' '%s' '%s' " "${fk%%=*}" "${fk#*=}"
  fi
  local sibs="${NIX_FLAKE_OVERRIDE_SIBLINGS:-}"
  local root="${NIX_FLAKE_OVERRIDE_SIBLINGS_ROOT:-..}"
  local name
  if [[ -n "$sibs" ]]; then
    for name in ${sibs//|/ }; do
      [[ -d "$root/$name" && -f "$root/$name/flake.nix" ]] || continue
      printf "'--override-input' '%s' 'path:%s' " "$name" "$root/$name"
    done
  fi
  case "${NIX_FLAKE_OVERRIDE_AUTO:-}" in
    1 | true | yes | on) ;;
    *) return 0 ;;
  esac
  local sfx="${NIX_FLAKE_OVERRIDE_AUTO_STRIP_SUFFIXES:-}"
  local input dir
  while IFS= read -r input; do
    [[ -z "$input" ]] && continue
    dir="$input"
    if [[ -n "$sfx" && "$input" == *"$sfx" ]]; then
      [[ -d "$root/$input" ]] || dir="${input%"$sfx"}"
    fi
    [[ -d "$root/$dir" && -f "$root/$dir/flake.nix" ]] || continue
    printf "'--override-input' '%s' 'path:%s' " "$input" "$root/$dir"
  done < <(_nfo_flake_input_names)
}
"""

proc guardScript(plugin, knobs: string): string =
  ## A bash program that loads `plugin`, loads the library, sets `knobs`, and
  ## reports the guard's verdict on the last line as `guard_exit=<n>`.
  "set -uo pipefail\n" &
  "log_status() { :; }\n" &
  plugin & "\n" &
  "source " & quoteShell(libPath()) & "\n" &
  knobs & "\n" &
  "dev_shell_guard_override_knobs\n" &
  "printf 'guard_exit=%s\\n' \"$?\"\n"

proc guardExit(output: string): int =
  ## Parse the trailing `guard_exit=<n>` marker. Returns -1 when the marker is
  ## absent, so a script that died before reaching it can never be mistaken
  ## for a pass.
  result = -1
  for line in output.splitLines():
    let stripped = line.strip()
    if stripped.startsWith("guard_exit="):
      try: result = parseInt(stripped["guard_exit=".len .. ^1])
      except ValueError: result = -1

proc seedGitTree(gitBin, path, content: string) =
  createDir(path)
  writeFile(path / "flake.nix", "{ outputs = _: { }; }\n")
  writeFile(path / "src.txt", content)
  for args in [
      @["init", "-q", "-b", "main", path],
      @["-C", path, "config", "user.email", "tester@example.invalid"],
      @["-C", path, "config", "user.name", "Dev Shell Tester"],
      @["-C", path, "add", "-A"],
      @["-C", path, "commit", "-q", "-m", "seed"]]:
    let res = runShell(shellCommand(gitBin & args))
    if res.code != 0:
      checkpoint("git " & args.join(" ") & " failed:\n" & res.output)
      doAssert false

proc gitCommitAll(gitBin, path, message: string) =
  for args in [@["-C", path, "add", "-A"],
               @["-C", path, "commit", "-q", "-m", message]]:
    discard runShell(shellCommand(gitBin & args))

proc realPluginCandidates(): seq[string] =
  ## Genuine flake-overrides plugin builds present on this machine: a sibling
  ## checkout, plus every `source_url` CAS entry whose sha256 matches a pin in
  ## `.envrc`.
  let sibling = repoRoot().parentDir / "direnv-nix-flake-overrides" /
    "plugin" / "flake-overrides.bash"
  if fileExists(sibling):
    result.add(sibling)
  var pinned: seq[string]
  if fileExists(repoRoot() / ".envrc"):
    for line in readFile(repoRoot() / ".envrc").splitLines():
      let idx = line.find("sha256-")
      if idx >= 0:
        var stop = idx + "sha256-".len
        while stop < line.len and line[stop] notin {'"', '\'', ' '}:
          inc stop
        pinned.add(line[idx + "sha256-".len ..< stop])
  let casDir = getEnv("XDG_CACHE_HOME", getHomeDir() / ".cache") / "direnv" /
    "cas"
  if pinned.len > 0 and dirExists(casDir):
    for kind, path in walkDir(casDir):
      if kind != pcFile: continue
      var raw: string
      try: raw = readFile(path)
      except CatchableError: continue
      # direnv names CAS entries by hex sha256; the pin is the same digest in
      # base64, so decoding the pin and re-encoding the file name compares
      # them without hashing anything here.
      let name = path.extractFilename
      var matched = false
      for pin in pinned:
        var decoded: string
        try: decoded = base64.decode(pin)
        except CatchableError: continue
        var hex = ""
        for ch in decoded: hex.add(toHex(ord(ch), 2).toLowerAscii)
        if hex == name: matched = true
      if matched and raw.contains("flake_override_args_quoted"):
        result.add(path)

suite "dev-shell override guards":

  test "t_dev_shell_guard_rejects_a_plugin_that_ignores_the_auto_knob":
    ## Defect 1, red first: this is the configuration `.envrc` shipped —
    ## `NIX_FLAKE_OVERRIDE_AUTO=1` against a plugin that has never heard of it.
    if findExe("bash").len == 0:
      skip()
    else:
      let res = runBash(guardScript(fixtureOldPlugin,
        "export NIX_FLAKE_OVERRIDE_AUTO=1\n" &
        "export NIX_FLAKE_OVERRIDE_AUTO_STRIP_SUFFIXES=-src"), repoRoot())
      checkpoint("output:\n" & res.output)
      check guardExit(res.output) == 1
      # The diagnostic must name the knob that is inert and the remedy, or it
      # is just a different flavour of silence.
      check res.output.contains("NIX_FLAKE_OVERRIDE_AUTO")
      check res.output.contains("PINNED inputs")
      check res.output.contains("direnv-flake-overrides.blocksense.network")

  test "t_dev_shell_guard_accepts_a_plugin_that_honours_every_declared_knob":
    if findExe("bash").len == 0:
      skip()
    else:
      let res = runBash(guardScript(fixtureNewPlugin,
        "export NIX_FLAKE_OVERRIDE_AUTO=1\n" &
        "export NIX_FLAKE_OVERRIDE_AUTO_STRIP_SUFFIXES=-src\n" &
        "export NIX_FLAKE_OVERRIDE_INPUTS=explicit=github:x/y\n" &
        "export NIX_FLAKE_OVERRIDE_FLAKES=fk=github:x/y"), repoRoot())
      checkpoint("output:\n" & res.output)
      check guardExit(res.output) == 0
      check not res.output.contains("ignores")

  test "t_dev_shell_guard_reports_a_missing_plugin_differently":
    ## "The plugin never loaded" and "the plugin is too old" want different
    ## remedies, so they must not share an exit code.
    if findExe("bash").len == 0:
      skip()
    else:
      let res = runBash(guardScript("",
        "export NIX_FLAKE_OVERRIDE_AUTO=1"), repoRoot())
      checkpoint("output:\n" & res.output)
      check guardExit(res.output) == 2
      check res.output.contains("did not load")

  test "t_dev_shell_guard_probes_offered_knobs_even_when_unset":
    ## The knobs `.envrc` OFFERS are checked whether or not anybody has set
    ## one. Without this, a plugin pin that has gone stale stays undetected
    ## until the day a developer first puts a sibling in `.env` — and on that
    ## day they get the pinned input and no diagnostic, which is defect 1
    ## again with a longer fuse.
    if findExe("bash").len == 0:
      skip()
    else:
      let old = runBash(guardScript(fixtureOldPlugin,
        "dev_shell_guard_override_knobs NIX_FLAKE_OVERRIDE_SIBLINGS\n" &
        "printf 'offered_exit=%s\\n' \"$?\"\ntrue"), repoRoot())
      checkpoint("old plugin, offered:\n" & old.output)
      check old.output.contains("offered_exit=1")
      check old.output.contains("NIX_FLAKE_OVERRIDE_SIBLINGS")

      let fresh = runBash(guardScript(fixtureNewPlugin,
        "dev_shell_guard_override_knobs NIX_FLAKE_OVERRIDE_SIBLINGS\n" &
        "printf 'offered_exit=%s\\n' \"$?\"\ntrue"), repoRoot())
      checkpoint("current plugin, offered:\n" & fresh.output)
      check fresh.output.contains("offered_exit=0")

  test "t_dev_shell_guard_is_silent_when_no_knob_is_set":
    ## A repository that does not ask for overrides must not be nagged about a
    ## plugin it never needed.
    if findExe("bash").len == 0:
      skip()
    else:
      let res = runBash(guardScript(fixtureOldPlugin, "true"), repoRoot())
      checkpoint("output:\n" & res.output)
      check guardExit(res.output) == 0
      check not res.output.contains("dev-shell:")

  test "t_dev_shell_guard_agrees_with_a_real_plugin_build_when_one_is_present":
    ## The stand-ins above model a contract; this checks the contract against
    ## whatever genuine plugin builds this machine actually has, so a guard
    ## that only ever satisfies its own fixtures cannot pass. And it checks
    ## the thing the whole defect was about: the revision `.envrc` PINS must
    ## implement the knobs `.envrc` OFFERS. Reverting the pin to a build that
    ## does not — which is the state this repository shipped in — fails here.
    if findExe("bash").len == 0:
      skip()
    else:
      let candidates = realPluginCandidates()
      if candidates.len == 0:
        checkpoint("no real flake-overrides plugin build on this machine " &
          "(no ../direnv-nix-flake-overrides checkout and no matching " &
          "direnv source_url CAS entry); contract check skipped")
        skip()
      else:
        let offered = runBash(
          "set -uo pipefail\n" &
          "source " & quoteShell(libPath()) & "\n" &
          "dev_shell_declared_override_knobs " &
          quoteShell(repoRoot() / ".envrc"), repoRoot())
          .output.splitLines().filterIt(it.strip().len > 0)
        check offered.len > 0
        for candidate in candidates:
          let plugin = "source " & quoteShell(candidate)
          # First: does the guard's verdict match what that build contains?
          let auto = runBash(guardScript(plugin,
            "export NIX_FLAKE_OVERRIDE_AUTO=1\n" &
            "export NIX_FLAKE_OVERRIDE_AUTO_STRIP_SUFFIXES=-src"), repoRoot())
          checkpoint(candidate & " (auto) ->\n" & auto.output)
          let verdict = guardExit(auto.output)
          # Whatever the verdict, it must be a verdict — never a crash — and
          # it must agree with what that build actually contains.
          check verdict in [0, 1]
          let implementsAuto =
            readFile(candidate).contains("NIX_FLAKE_OVERRIDE_AUTO")
          check (verdict == 0) == implementsAuto

          # Second: this build is one `.envrc` names. It must satisfy every
          # knob `.envrc` offers, or `.envrc` is once again describing a
          # configuration the plugin will not deliver.
          let pinned = runBash(guardScript(plugin,
            "dev_shell_guard_override_knobs " & offered.join(" ") & "\n" &
            "printf 'offered_exit=%s\\n' \"$?\"\ntrue"), repoRoot())
          checkpoint(candidate & " (offered: " & offered.join(" ") & ") ->\n" &
            pinned.output)
          check pinned.output.contains("offered_exit=0")

  test "t_dev_shell_declaration_scan_ignores_knobs_that_are_only_mentioned":
    ## A knob named in a comment is not a knob that is set. The scan has to
    ## tell them apart, or the lint gate's "every declared knob is probed"
    ## becomes a grep for a substring and stops meaning anything.
    if findExe("bash").len == 0:
      skip()
    else:
      let scratch = createTempDir("repro-devshell-scan-", "")
      defer: removeDirEventually(scratch)
      writeFile(scratch / "fixture.envrc",
        "# NIX_FLAKE_OVERRIDE_AUTO=1 was removed; see the note below.\n" &
        "#   export NIX_FLAKE_OVERRIDE_FLAKES='a=b'\n" &
        "export NIX_FLAKE_OVERRIDE_SIBLINGS=\"${NIX_FLAKE_OVERRIDE_SIBLINGS:-}\"\n" &
        "NIX_FLAKE_OVERRIDE_INPUTS=x=y\n")
      let res = runBash(
        "set -uo pipefail\n" &
        "source " & quoteShell(libPath()) & "\n" &
        "dev_shell_declared_override_knobs " &
        quoteShell(scratch / "fixture.envrc"), scratch)
      let found = res.output.splitLines().filterIt(it.strip().len > 0)
      checkpoint("found: " & found.join(", "))
      check found == @["NIX_FLAKE_OVERRIDE_SIBLINGS",
        "NIX_FLAKE_OVERRIDE_INPUTS"]

  test "t_dev_shell_envrc_declares_only_knobs_the_guard_can_probe":
    ## The static half of defect 1, and the half `just lint` can answer
    ## without a network or a nix evaluation: a knob added to `.envrc` without
    ## a probe is a knob that can go inert unnoticed.
    if findExe("bash").len == 0:
      skip()
    else:
      let res = runBash(
        "set -uo pipefail\n" &
        "source " & quoteShell(libPath()) & "\n" &
        "dev_shell_declared_override_knobs " &
        quoteShell(repoRoot() / ".envrc"), repoRoot())
      checkpoint("declared:\n" & res.output)
      var declared = res.output.splitLines().filterIt(it.strip().len > 0)
      # Positive assertion: this repository states its relationship to the
      # workspace siblings in the file, so finding nothing is a failure and
      # not a pass. (A knob may legitimately be EMPTY — "none by default" is
      # a statement; a missing knob is not.)
      check declared.len > 0
      check "NIX_FLAKE_OVERRIDE_AUTO" in declared
      # Every declared knob is one the library knows how to probe.
      let known = runBash(
        "set -uo pipefail\n" &
        "source " & quoteShell(libPath()) & "\n" &
        "printf '%s\\n' \"${DEV_SHELL_KNOWN_OVERRIDE_KNOBS[@]}\"",
        repoRoot()).output.splitLines().filterIt(it.strip().len > 0)
      for knob in declared:
        check knob in known
      # ...and the file runs the guard over the knobs it OFFERS, naming them,
      # rather than over whatever happens to be set. The distinction is the
      # difference between catching a stale plugin pin on the day it goes
      # stale and catching it the day somebody first uses the feature.
      let envrcBody = readFile(repoRoot() / ".envrc")
      check envrcBody.contains("dev_shell_guard_override_knobs")
      for knob in declared:
        check envrcBody.contains("dev_shell_guard_override_knobs") and
          envrcBody.split("dev_shell_guard_override_knobs")[1]
            .split("fi")[0].contains(knob)

  test "t_dev_shell_fingerprint_moves_when_an_overridden_source_moves":
    ## Defect 2's cause, stated as a property: an input overridden to a local
    ## working tree is invisible to direnv's watch set, so the fingerprint is
    ## the thing that has to move when the tree does.
    if findExe("bash").len == 0 or findExe("git").len == 0:
      skip()
    else:
      let scratch = createTempDir("repro-devshell-fp-", "")
      defer: removeDirEventually(scratch)
      let gitBin = findExe("git")
      let sibling = scratch / "runquota"
      seedGitTree(gitBin, sibling, "one\n")

      let args = "'--override-input' 'runquota-src' 'path:" & sibling & "' "
      let render =
        "set -uo pipefail\n" &
        "source " & quoteShell(libPath()) & "\n" &
        "printf '%s' " & quoteShell(args) &
        " | dev_shell_override_path_pairs_from_args" &
        " | dev_shell_render_fingerprint\n"

      let first = runBash(render, scratch)
      checkpoint("first:\n" & first.output)
      # Positive: the pair must actually be found, or every later comparison
      # would be comparing two empty files and passing vacuously.
      check first.output.contains("runquota-src")
      check first.output.contains(sibling)

      # Same tree, unchanged: byte-identical, so the file's mtime does not
      # churn and the dev shell is not rebuilt on every directory entry.
      let repeat = runBash(render, scratch)
      check repeat.output == first.output

      # A commit in the sibling — the reported failure, exactly.
      writeFile(sibling / "src.txt", "two\n")
      gitCommitAll(gitBin, sibling, "advance")
      let moved = runBash(render, scratch)
      checkpoint("moved:\n" & moved.output)
      check moved.output != first.output

      # An uncommitted edit is just as much a different input, because
      # `path:` copies the working tree and not the commit.
      writeFile(sibling / "src.txt", "two-dirty\n")
      let dirty = runBash(render, scratch)
      check dirty.output != moved.output

      # The file's mtime is the signal direnv acts on, so writing it must be
      # a no-op when nothing moved. A fingerprint rewritten on every load
      # would rebuild the dev shell on every directory entry — the opposite
      # failure, and just as expensive.
      let stability = runBash(
        "set -uo pipefail\n" &
        "source " & quoteShell(libPath()) & "\n" &
        "body=$(printf '%s' " & quoteShell(args) &
        " | dev_shell_override_path_pairs_from_args" &
        " | dev_shell_render_fingerprint)\n" &
        "dev_shell_write_fingerprint stable.txt \"$body\"\n" &
        "before=$(stat -c %Y stable.txt 2>/dev/null || stat -f %m stable.txt)\n" &
        "sleep 1\n" &
        "dev_shell_write_fingerprint stable.txt \"$body\"\n" &
        "after=$(stat -c %Y stable.txt 2>/dev/null || stat -f %m stable.txt)\n" &
        "dev_shell_write_fingerprint stable.txt \"$body moved\"\n" &
        "changed=$(stat -c %Y stable.txt 2>/dev/null || stat -f %m stable.txt)\n" &
        "printf 'unchanged=%s\\n' \"$([[ $before == $after ]] && echo yes || echo no)\"\n" &
        "printf 'rewritten=%s\\n' \"$([[ $after != $changed ]] && echo yes || echo no)\"\n",
        scratch)
      checkpoint("write stability:\n" & stability.output)
      check stability.output.contains("unchanged=yes")
      check stability.output.contains("rewritten=yes")

  test "t_dev_shell_drift_check_names_the_source_that_moved":
    if findExe("bash").len == 0 or findExe("git").len == 0:
      skip()
    else:
      let scratch = createTempDir("repro-devshell-drift-", "")
      defer: removeDirEventually(scratch)
      let gitBin = findExe("git")
      let stable = scratch / "io-mon"
      let moving = scratch / "runquota"
      seedGitTree(gitBin, stable, "stable\n")
      seedGitTree(gitBin, moving, "one\n")

      let args =
        "'--override-input' 'io-mon-src' 'path:" & stable & "' " &
        "'--override-input' 'runquota-src' 'path:" & moving & "' "
      let record =
        "set -uo pipefail\n" &
        "source " & quoteShell(libPath()) & "\n" &
        "printf '%s' " & quoteShell(args) &
        " | dev_shell_override_path_pairs_from_args" &
        " | dev_shell_render_fingerprint > fp.txt\n" &
        "grep -c . fp.txt\n"
      let recorded = runBash(record, scratch)
      checkpoint("recorded:\n" & recorded.output)
      # Header plus two pairs. Asserted so a parse that silently dropped the
      # pairs cannot make the drift check pass by having nothing to compare.
      check recorded.output.strip() == "3"

      let drift =
        "set -uo pipefail\n" &
        "source " & quoteShell(libPath()) & "\n" &
        "dev_shell_fingerprint_drift fp.txt\n" &
        "printf 'drift_exit=%s\\n' \"$?\"\n"

      let quiet = runBash(drift, scratch)
      checkpoint("no drift:\n" & quiet.output)
      check quiet.output.contains("drift_exit=0")
      check not quiet.output.contains("runquota-src\t")

      writeFile(moving / "src.txt", "two\n")
      gitCommitAll(gitBin, moving, "advance")
      let loud = runBash(drift, scratch)
      checkpoint("drift:\n" & loud.output)
      check loud.output.contains("drift_exit=1")
      # It names the source that moved...
      check loud.output.contains("runquota-src")
      # ...and stays quiet about the one that did not, so the report points at
      # the culprit instead of listing everything.
      check not loud.output.contains("io-mon-src")

  test "t_dev_shell_lint_gate_fails_on_a_cache_of_unknown_provenance":
    ## `scripts/check_dev_shell_env.sh` is the surface `just lint` runs. A
    ## `.direnv/flake-profile-*.rc` with no fingerprint beside it is the exact
    ## state the workspace was in: a cached shell nothing can account for.
    if findExe("bash").len == 0:
      skip()
    else:
      let scratch = createTempDir("repro-devshell-lint-", "")
      defer: removeDirEventually(scratch)
      # A stand-in repo root carrying this repository's real scripts, so the
      # gate under test is the shipped one.
      createDir(scratch / "scripts" / "lib")
      copyFile(libPath(), scratch / "scripts" / "lib" /
        "dev_shell_overrides.sh")
      copyFile(checkScript(), scratch / "scripts" / "check_dev_shell_env.sh")
      copyFile(repoRoot() / ".envrc", scratch / ".envrc")
      createDir(scratch / ".direnv")
      writeFile(scratch / ".direnv" / "flake-profile-deadbeef.rc",
        "export RUNQUOTA_SRC='/nix/store/stale-source'\n")

      let bash = findExe("bash")
      let orphan = runShell(shellCommand(@[bash,
        scratch / "scripts" / "check_dev_shell_env.sh"]), cwd = scratch)
      checkpoint("orphan cache:\n" & orphan.output)
      check orphan.code != 0
      check orphan.output.contains("no flake-override-sources.fingerprint")

      # With a fingerprint that still matches, the same gate passes — so the
      # failure above is about provenance and not about the gate refusing
      # everything.
      writeFile(scratch / ".direnv" / "flake-override-sources.fingerprint",
        "# reprobuild dev-shell override-source fingerprint v1\n")
      let clean = runShell(shellCommand(@[bash,
        scratch / "scripts" / "check_dev_shell_env.sh"]), cwd = scratch)
      checkpoint("accounted cache:\n" & clean.output)
      check clean.code == 0
      check clean.output.contains("check_dev_shell_env: ok")

  test "t_dev_shell_lint_gate_requires_the_flake_files_to_be_watched":
    ## nix-direnv adds `flake.nix` / `flake.lock` to the watch set only when
    ## the flake expression names a DIRECTORY. This repository's expression is
    ## `.?submodules=1`, which is not one — so for as long as `.envrc` did not
    ## watch them itself, an edit to either left the cached dev shell in place
    ## and the shell kept serving the previous environment. The `watch_file`
    ## lines that fix that are load-bearing, and this is what says so if one
    ## is ever removed.
    if findExe("bash").len == 0:
      skip()
    else:
      let scratch = createTempDir("repro-devshell-watch-", "")
      defer: removeDirEventually(scratch)
      createDir(scratch / "scripts" / "lib")
      copyFile(libPath(), scratch / "scripts" / "lib" /
        "dev_shell_overrides.sh")
      copyFile(checkScript(), scratch / "scripts" / "check_dev_shell_env.sh")
      let bash = findExe("bash")

      proc gate(): CmdResult =
        runShell(shellCommand(@[bash,
          scratch / "scripts" / "check_dev_shell_env.sh"]), cwd = scratch)

      let knob = "export NIX_FLAKE_OVERRIDE_AUTO=1\n" &
        "dev_shell_guard_override_knobs\n" &
        "dev_shell_write_fingerprint x y\n" &
        "watch_file \".direnv/flake-override-sources.fingerprint\"\n"

      # A query-string expression with both files watched: accepted.
      writeFile(scratch / ".envrc", knob &
        "watch_file flake.nix\nwatch_file flake.lock\n" &
        "eval \"use flake '.?submodules=1' $args\"\n")
      let watched = gate()
      checkpoint("watched:\n" & watched.output)
      check watched.code == 0

      # The same expression with flake.lock no longer watched: refused, and
      # the diagnostic names the file and the reason.
      writeFile(scratch / ".envrc", knob &
        "watch_file flake.nix\n" &
        "eval \"use flake '.?submodules=1' $args\"\n")
      let unwatched = gate()
      checkpoint("unwatched:\n" & unwatched.output)
      check unwatched.code != 0
      check unwatched.output.contains("does not add flake.lock")
      check unwatched.output.contains("not a\n      bare directory")

      # A file with no `use flake` at all is not silently accepted either: the
      # check would have nothing to say, and saying nothing would read exactly
      # like a pass.
      writeFile(scratch / ".envrc", knob)
      let absent = gate()
      checkpoint("no use flake:\n" & absent.output)
      check absent.code != 0
      check absent.output.contains("no `use flake` invocation found")

  test "t_dev_shell_lint_gate_fails_when_the_lock_is_newer_than_the_cache":
    ## The half of the staleness problem that needs no overrides. nix-direnv
    ## does watch `flake.lock`, but only compares it when direnv re-evaluates
    ## `.envrc` — which a `just lint` fired from a git hook, or a shell that
    ## was already inside the directory, never triggers. Measured across this
    ## workspace: caches six to twenty-seven days behind their own watched
    ## files, still in use.
    if findExe("bash").len == 0:
      skip()
    else:
      let scratch = createTempDir("repro-devshell-lock-", "")
      defer: removeDirEventually(scratch)
      createDir(scratch / "scripts" / "lib")
      copyFile(libPath(), scratch / "scripts" / "lib" /
        "dev_shell_overrides.sh")
      copyFile(checkScript(), scratch / "scripts" / "check_dev_shell_env.sh")
      copyFile(repoRoot() / ".envrc", scratch / ".envrc")
      createDir(scratch / ".direnv")
      writeFile(scratch / "flake.lock", "{ \"nodes\": {} }\n")
      writeFile(scratch / ".direnv" / "flake-override-sources.fingerprint",
        "# reprobuild dev-shell override-source fingerprint v1\n")
      writeFile(scratch / ".direnv" / "flake-profile-deadbeef.rc",
        "export RUNQUOTA_SRC='/nix/store/stale-source'\n")

      let bash = findExe("bash")
      let current = runShell(shellCommand(@[bash,
        scratch / "scripts" / "check_dev_shell_env.sh"]), cwd = scratch)
      checkpoint("cache newer than lock:\n" & current.output)
      check current.code == 0

      # Now let the lock overtake the cached profile, exactly as a `git pull`
      # does. `git` sets the mtime of a file it rewrites to now.
      let later = getLastModificationTime(
        scratch / ".direnv" / "flake-profile-deadbeef.rc") + initDuration(
          seconds = 60)
      setLastModificationTime(scratch / "flake.lock", later)

      let stale = runShell(shellCommand(@[bash,
        scratch / "scripts" / "check_dev_shell_env.sh"]), cwd = scratch)
      checkpoint("lock newer than cache:\n" & stale.output)
      check stale.code != 0
      check stale.output.contains("flake.lock is newer than the cached")
      check stale.output.contains("direnv reload")

  test "t_dev_shell_lint_gate_refuses_an_envrc_that_states_no_knob_at_all":
    ## Deleting the knob is not the same as scoping it. "None by default" is a
    ## statement a reader can act on; a missing knob leaves the dev shell's
    ## relationship to the workspace siblings to be inferred from an absence,
    ## which is how the setting stayed inert and unexamined for as long as it
    ## did.
    if findExe("bash").len == 0:
      skip()
    else:
      let scratch = createTempDir("repro-devshell-silent-", "")
      defer: removeDirEventually(scratch)
      createDir(scratch / "scripts" / "lib")
      copyFile(libPath(), scratch / "scripts" / "lib" /
        "dev_shell_overrides.sh")
      copyFile(checkScript(), scratch / "scripts" / "check_dev_shell_env.sh")
      writeFile(scratch / ".envrc", "use flake\n")

      let bash = findExe("bash")
      let res = runShell(shellCommand(@[bash,
        scratch / "scripts" / "check_dev_shell_env.sh"]), cwd = scratch)
      checkpoint("knobless .envrc:\n" & res.output)
      check res.code != 0
      check res.output.contains("names no NIX_FLAKE_OVERRIDE_* knob at all")

  test "t_dev_shell_lint_gate_fails_when_a_recorded_source_has_moved":
    if findExe("bash").len == 0 or findExe("git").len == 0:
      skip()
    else:
      let scratch = createTempDir("repro-devshell-lint-drift-", "")
      defer: removeDirEventually(scratch)
      let gitBin = findExe("git")
      let sibling = scratch / "runquota"
      seedGitTree(gitBin, sibling, "one\n")

      let root = scratch / "repo"
      createDir(root / "scripts" / "lib")
      copyFile(libPath(), root / "scripts" / "lib" / "dev_shell_overrides.sh")
      copyFile(checkScript(), root / "scripts" / "check_dev_shell_env.sh")
      copyFile(repoRoot() / ".envrc", root / ".envrc")
      createDir(root / ".direnv")
      writeFile(root / ".direnv" / "flake-profile-deadbeef.rc",
        "export RUNQUOTA_SRC='/nix/store/stale-source'\n")

      let args = "'--override-input' 'runquota-src' 'path:" & sibling & "' "
      discard runBash(
        "set -uo pipefail\n" &
        "source " & quoteShell(libPath()) & "\n" &
        "printf '%s' " & quoteShell(args) &
        " | dev_shell_override_path_pairs_from_args" &
        " | dev_shell_render_fingerprint" &
        " > .direnv/flake-override-sources.fingerprint\n", root)

      let bash = findExe("bash")
      let fresh = runShell(shellCommand(@[bash,
        root / "scripts" / "check_dev_shell_env.sh"]), cwd = root)
      checkpoint("fresh:\n" & fresh.output)
      check fresh.code == 0
      check fresh.output.contains("matches all 1 overridden source")

      writeFile(sibling / "src.txt", "fifty-nine commits later\n")
      gitCommitAll(gitBin, sibling, "advance")

      let stale = runShell(shellCommand(@[bash,
        root / "scripts" / "check_dev_shell_env.sh"]), cwd = root)
      checkpoint("stale:\n" & stale.output)
      check stale.code != 0
      check stale.output.contains("runquota-src")
      check stale.output.contains("built from sources that have since moved")
      check stale.output.contains("direnv reload")

  test "t_dev_shell_lint_gate_fails_when_the_auto_arm_cannot_reach_a_sibling":
    ## Defect 3, and the one the two checks above were structurally unable to
    ## see. The auto arm strips `-src` off an input name and overrides the
    ## input when a sibling DIRECTORY OF THAT NAME exists — so an input called
    ## `stackable-hooks-src` whose repository is `nim-stackable-hooks` matches
    ## nothing, is never overridden, and therefore never appears in the
    ## fingerprint the drift check reconciles. It sat 30 commits behind its
    ## sibling while every neighbouring input tracked its working tree, across
    ## the commit that added the `WindowsInjectionResult` fields io-mon's
    ## Windows arm reads, and `just lint` was green throughout.
    ##
    ## The three assertions are the three states that must be distinguishable:
    ## a name that matches (accepted), a name that does not while the
    ## repository IS checked out beside us (refused, by input name), and a
    ## matching name whose sibling is not a flake so the plugin will not take
    ## it either (refused, for the other reason).
    if findExe("bash").len == 0:
      skip()
    else:
      let scratch = createTempDir("repro-devshell-reach-", "")
      defer: removeDirEventually(scratch)
      let root = scratch / "repo"
      createDir(root / "scripts" / "lib")
      copyFile(libPath(), root / "scripts" / "lib" / "dev_shell_overrides.sh")
      copyFile(checkScript(), root / "scripts" / "check_dev_shell_env.sh")
      copyFile(repoRoot() / ".envrc", root / ".envrc")

      # The sibling is named after the REPOSITORY, which is the whole point.
      createDir(scratch / "nim-widget")
      writeFile(scratch / "nim-widget" / "flake.nix", "{ outputs = _: { }; }\n")

      proc writeFlake(inputName: string) =
        writeFile(root / "flake.nix",
          "{\n  inputs = {\n    " & inputName & " = {\n" &
          "      url = \"github:metacraft-labs/nim-widget/deadbeef\";\n" &
          "      flake = false;\n    };\n  };\n" &
          "  outputs = _: { };\n}\n")

      let bash = findExe("bash")
      proc gate(): CmdResult =
        runShell(shellCommand(@[bash,
          root / "scripts" / "check_dev_shell_env.sh"]), cwd = root)

      # 1. Input named after the repository: the arm reaches `../nim-widget`.
      writeFlake("nim-widget-src")
      let reachable = gate()
      checkpoint("reachable:\n" & reachable.output)
      check reachable.code == 0
      check reachable.output.contains("1 flake input(s) examined")
      check reachable.output.contains("0 unreached")

      # 2. The defect verbatim: the input strips to a directory that is not
      #    there, while the repository's checkout sits beside it unreached.
      writeFlake("widget-src")
      let unreachable = gate()
      checkpoint("unreachable:\n" & unreachable.output)
      check unreachable.code != 0
      check unreachable.output.contains("'widget-src' is pinned")
      check unreachable.output.contains("nim-widget")
      check unreachable.output.contains("rename the input to 'nim-widget-src'")
      # The remedy points at the declaration FILE, which is deliberately not
      # copied into this tree: the exceptions describe one flake, and a list
      # compiled into the script would excuse inputs a synthetic tree never
      # had. Case 1 above is what says the absent file is not a blanket pass.
      check unreachable.output.contains("dev-shell-pinned-siblings.tsv")

      # 3. Names agree, but the sibling is not a flake, so the plugin emits no
      #    --override-input for it. Same outcome — a pinned input beside a
      #    moving checkout — reported as the different cause it is.
      removeFile(scratch / "nim-widget" / "flake.nix")
      writeFlake("nim-widget-src")
      let unflakeable = gate()
      checkpoint("unflakeable:\n" & unflakeable.output)
      check unflakeable.code != 0
      check unflakeable.output.contains("has no flake.nix")
      check unflakeable.output.contains("nim-widget-src")

      # 4. The declaration file is the gate's own escape hatch, so it has to
      #    cost something to use. A row that names an input and a kind but no
      #    REASON is a suppression wearing a declaration's clothes: it turns
      #    the check off for that input and leaves nobody to ask why. Checked
      #    here because it is the one way to make this gate pass while the
      #    defect it names is still present — and it did, until this assertion.
      let declFile = root / "scripts" / "dev-shell-pinned-siblings.tsv"
      writeFlake("widget-src")
      writeFile(declFile, "widget-src\tunreachable\n")
      let noReason = gate()
      checkpoint("declared without a reason:\n" & noReason.output)
      check noReason.code != 0
      check noReason.output.contains("gives no reason")

      # A kind the check does not recognise cannot match a finding either, so
      # it excuses nothing while looking like it does.
      writeFile(declFile, "widget-src\tunknown-kind\tbecause I said so\n")
      let badKind = gate()
      checkpoint("declared with an unknown kind:\n" & badKind.output)
      check badKind.code != 0
      check badKind.output.contains("neither 'unreachable' nor 'unflakeable'")

      # And a complete row is accepted — otherwise the two refusals above
      # would be satisfied by a file that can never be written correctly.
      writeFile(declFile,
        "widget-src\tunreachable\tthe sibling is pinned on purpose here\n")
      let declared = gate()
      checkpoint("declared properly:\n" & declared.output)
      check declared.code == 0
      check declared.output.contains("1 unreached (1 declared, 0 NOT declared)")

  test "t_dev_shell_lint_gate_declaration_arm_is_workspace_shape_aware":
    ## Defect 4, and the reason this gate could not be satisfied at all.
    ##
    ## Every finding the reachability check produces begins with "the sibling
    ## exists", so the finding set is a function of WHICH REPOSITORIES A GIVEN
    ## WORKSPACE HAPPENS TO HAVE CHECKED OUT. The declaration file is one file
    ## for all of them, and the stale-declaration arm demanded an exact match in
    ## both directions — so a row for a sibling CI does not clone failed in CI,
    ## and deleting it failed in the workspace that does clone it. Same row,
    ## opposite polarities, no possible content. `nim-stew-src` /
    ## `nim-results-src` were deleted on 2026-09-01 for the CI half, and from
    ## that day a workspace carrying `../nim-stew` and `../nim-results` failed
    ## on two undeclared findings; since the pre-commit hook runs `just lint`,
    ## which runs this gate, reprobuild accepted NO COMMIT AT ALL there.
    ##
    ## Both polarities are asserted here, because a fix verified in one shape
    ## is just a different one-shape gate. And the two ways the arm must still
    ## bite are asserted with them: a row whose sibling IS present and DOES
    ## resolve is genuinely stale, and a row naming an input the flake no longer
    ## declares is stale in every shape, sibling or no sibling. The shape
    ## question is allowed to excuse a row only when the thing the row is about
    ## is absent — never when it is present and fixed.
    if findExe("bash").len == 0:
      skip()
    else:
      let scratch = createTempDir("repro-devshell-shape-", "")
      defer: removeDirEventually(scratch)
      let root = scratch / "repo"
      createDir(root / "scripts" / "lib")
      copyFile(libPath(), root / "scripts" / "lib" / "dev_shell_overrides.sh")
      copyFile(checkScript(), root / "scripts" / "check_dev_shell_env.sh")
      copyFile(repoRoot() / ".envrc", root / ".envrc")
      writeFile(root / "flake.nix",
        "{\n  inputs = {\n    nim-widget-src = {\n" &
        "      url = \"github:metacraft-labs/nim-widget/deadbeef\";\n" &
        "      flake = false;\n    };\n" &
        # A url that names no repository, for case 5 below.
        "    local-thing-src = {\n" &
        "      url = \"path:/nowhere/local-thing\";\n" &
        "      flake = false;\n    };\n  };\n" &
        "  outputs = _: { };\n}\n")

      let declFile = root / "scripts" / "dev-shell-pinned-siblings.tsv"
      let sibling = scratch / "nim-widget"

      let bash = findExe("bash")
      proc gate(): CmdResult =
        runShell(shellCommand(@[bash,
          root / "scripts" / "check_dev_shell_env.sh"]), cwd = root)

      # 1. THE SHAPE THAT USED TO FAIL: the row is present, the sibling it
      #    describes is not checked out here. It describes another workspace,
      #    which is not evidence of decay — and the rows it passed over are
      #    named in the output rather than dropped, so a file that has become
      #    inapplicable everywhere is still visible to a reader.
      writeFile(declFile,
        "nim-widget-src\tunflakeable\t../nim-widget has no flake.nix where it is cloned\n")
      let absent = gate()
      checkpoint("sibling absent:\n" & absent.output)
      check absent.code == 0
      check absent.output.contains(
        "declared row(s) describe siblings not checked out in this workspace")
      check absent.output.contains("nim-widget-src")

      # 2. THE OTHER POLARITY, same file: the sibling IS here and still cannot
      #    be reached, so the row is doing its job and the gate is green.
      createDir(sibling)
      let present = gate()
      checkpoint("sibling present, unflakeable:\n" & present.output)
      check present.code == 0
      check present.output.contains("1 unreached (1 declared, 0 NOT declared)")

      # 3. The detection this arm exists for, unblunted: the sibling is present
      #    AND now resolves, so the row has genuinely stopped describing
      #    anything and must fail. This is the case the shape question must
      #    never excuse.
      writeFile(sibling / "flake.nix", "{ outputs = _: { }; }\n")
      let resolved = gate()
      checkpoint("sibling present and resolving:\n" & resolved.output)
      check resolved.code != 0
      check resolved.output.contains("still excuses flake input")
      check resolved.output.contains("IS checked out beside this repository")

      # 4. Decay that no workspace shape can excuse: the row names an input
      #    `flake.nix` does not declare. Asserted with the sibling ABSENT —
      #    the shape in which the arm is most permissive — because folding this
      #    case into the shape question would have let a row outlive a rename
      #    in every workspace that does not clone the sibling.
      removeDir(sibling)
      writeFile(declFile,
        "renamed-away-src\tunflakeable\ta row that outlived its input\n")
      let renamed = gate()
      checkpoint("input no longer declared:\n" & renamed.output)
      check renamed.code != 0
      check renamed.output.contains("flake.nix declares no such input")

      # 5. The hole the shape question opens if "declared" is read as "appears
      #    in flake.nix" rather than "appears with a repository url". A
      #    `path:`/`file:` input names no repository, so
      #    `dev_shell_unreached_siblings` skips it and NO workspace can ever
      #    produce a finding for it — a row excusing one describes nothing
      #    anywhere. Asserted in the shape where the shape question is most
      #    willing to forgive (no directory of that name on disk), because that
      #    is the shape in which such a row would otherwise be waved through as
      #    "describes another workspace". Review found this passing; it is the
      #    one place the shape fix had removed detection instead of adding it.
      writeFile(declFile,
        "local-thing-src\tunflakeable\ta row for an input that names no repository\n")
      let pathUrl = gate()
      checkpoint("path: url input, no such directory:\n" & pathUrl.output)
      check pathUrl.code != 0
      check pathUrl.output.contains("flake.nix declares no such input")

      # And it stays a failure when a directory of that name IS present, so the
      # verdict does not turn on workspace shape at all.
      createDir(scratch / "local-thing")
      let pathUrlPresent = gate()
      checkpoint("path: url input, directory present:\n" & pathUrlPresent.output)
      check pathUrlPresent.code != 0
      check pathUrlPresent.output.contains("flake.nix declares no such input")

  test "t_dev_shell_source_state_ignores_an_ambient_git_environment":
    ## The gate ran from a git hook and manufactured a failure no edit could
    ## clear.
    ##
    ## `git -C <dir>` sets the working directory, and the working directory is
    ## the last thing git consults when it decides which repository a command
    ## is about. `GIT_DIR` is consulted first and wins. Git exports it — with
    ## `GIT_INDEX_FILE`, `GIT_PREFIX`, sometimes `GIT_WORK_TREE` — to every
    ## hook it runs, so `just lint` fired from `pre-commit` asked eight
    ## siblings for their revision and got the HOOKING repository's back eight
    ## times. Every row mismatched at once and the gate demanded a `direnv
    ## reload` that could not change a single one of those answers.
    ##
    ## The cost was never the noise. A gate that cannot be satisfied is a gate
    ## developers learn to pass with `--no-verify`, and `--no-verify` does not
    ## skip one check — it skips all of them, including the deterministic ones
    ## that were doing real work. This test is what keeps the answer a question
    ## about the directory named.
    ##
    ## Constructed so that a leak is a visibly WRONG answer rather than merely
    ## a different one: the two checkouts are at different commits, and the
    ## sibling additionally carries an uncommitted edit. A query that resolves
    ## the wrong repository reports the wrong commit; a query that survives
    ## into the wrong tree or the wrong index reports the wrong dirty state;
    ## and a query that simply DIES reports empty output, whose digest is the
    ## digest of "clean" — which is why the expected answer is asserted to be
    ## neither the other repository's nor a clean one before it is used.
    if findExe("bash").len == 0 or findExe("git").len == 0:
      skip()
    else:
      let scratch = createTempDir("repro-devshell-gitenv-", "")
      defer: removeDirEventually(scratch)
      let gitBin = findExe("git")
      let bash = findExe("bash")

      # Stands in for reprobuild: the repository whose hook is running.
      let hooking = scratch / "hooking-repo"
      # Stands in for `../runquota`: the sibling the fingerprint is about.
      let sibling = scratch / "runquota"
      seedGitTree(gitBin, hooking, "hooking\n")
      seedGitTree(gitBin, sibling, "one\n")
      # Move the sibling off the seed commit so the two HEADs differ, then
      # leave an uncommitted edit behind so its dirty digest is non-empty.
      writeFile(sibling / "src.txt", "two\n")
      gitCommitAll(gitBin, sibling, "advance")
      writeFile(sibling / "src.txt", "two-dirty\n")

      proc headOf(path: string): string =
        runShell(shellCommand(@[gitBin, "-C", path,
          "rev-parse", "HEAD"])).output.strip()

      let hookingHead = headOf(hooking)
      let siblingHead = headOf(sibling)
      # If these ever coincided the whole test would be vacuous.
      check hookingHead.len == 40
      check siblingHead.len == 40
      check hookingHead != siblingHead

      # Exactly what git puts in a hook's environment. `GIT_PREFIX` is in the
      # list although the fix does not clear it: it is what a hook really
      # carries, and including it says the fix does not depend on removing it.
      let hookEnv = @[
        ("GIT_DIR", hooking / ".git"),
        ("GIT_WORK_TREE", hooking),
        ("GIT_INDEX_FILE", hooking / ".git" / "index"),
        ("GIT_PREFIX", "")]

      proc sourceState(dir: string;
                       env: seq[tuple[name, value: string]]): string =
        runShell(shellCommand(@[bash, "-c",
          "set -uo pipefail\n" &
          "source " & quoteShell(libPath()) & "\n" &
          "dev_shell_source_state " & quoteShell(dir) & "\n"], env),
          cwd = scratch).output.strip()

      # The digest of no output at all, computed by the same helper that
      # digests `git status`, so the "it only passes because everything
      # errored" case has a name to be compared against instead of a
      # hard-coded constant that would rot with the hash choice.
      let emptyDigest = runShell(shellCommand(@[bash, "-c",
        "set -uo pipefail\n" &
        "source " & quoteShell(libPath()) & "\n" &
        "printf '' | _dev_shell_digest\n"]), cwd = scratch).output.strip()
      check emptyDigest.len > 0

      let expected = sourceState(sibling, @[])
      checkpoint("sibling state, clean environment: " & expected)
      check expected.contains(siblingHead)
      check not expected.contains(hookingHead)
      # A dirty tree, so a dead `git status` cannot pass for the right answer.
      check not expected.endsWith("+" & emptyDigest)

      let underHook = sourceState(sibling, hookEnv)
      checkpoint("sibling state, hook environment: " & underHook)
      check not underHook.contains(hookingHead)
      check underHook == expected

      # The same question about the hooking repository still answers about the
      # hooking repository, under both environments — the fix removes a
      # redirection, it does not make every directory report the same thing.
      let hookingState = sourceState(hooking, @[])
      check hookingState.contains(hookingHead)
      check sourceState(hooking, hookEnv) == hookingState
      check hookingState != expected

      # And the whole gate path, which is where the spurious failure surfaced:
      # a fingerprint recorded outside a hook, reconciled from inside one.
      let args =
        "'--override-input' 'runquota-src' 'path:" & sibling & "' "
      let record = runShell(shellCommand(@[bash, "-c",
        "set -uo pipefail\n" &
        "source " & quoteShell(libPath()) & "\n" &
        "printf '%s' " & quoteShell(args) &
        " | dev_shell_override_path_pairs_from_args" &
        " | dev_shell_render_fingerprint > fp.txt\n" &
        "grep -c . fp.txt\n"]), cwd = scratch)
      checkpoint("recorded:\n" & record.output)
      # Header plus the one pair: a fingerprint that recorded nothing would
      # have nothing to drift.
      check record.output.strip() == "2"

      let driftScript =
        "set -uo pipefail\n" &
        "source " & quoteShell(libPath()) & "\n" &
        "dev_shell_fingerprint_drift fp.txt\n" &
        "printf 'drift_exit=%s\\n' \"$?\"\n"

      let quiet = runShell(shellCommand(@[bash, "-c", driftScript], hookEnv),
        cwd = scratch)
      checkpoint("drift under a hook environment:\n" & quiet.output)
      check quiet.output.contains("drift_exit=0")
      check not quiet.output.contains("runquota-src\t")

      # The other direction, and the reason this is not a test that the drift
      # check has simply been switched off inside hooks: with the sibling
      # genuinely moved, the same hook environment must still catch it.
      writeFile(sibling / "src.txt", "three\n")
      gitCommitAll(gitBin, sibling, "really advance")
      let loud = runShell(shellCommand(@[bash, "-c", driftScript], hookEnv),
        cwd = scratch)
      checkpoint("real drift under a hook environment:\n" & loud.output)
      check loud.output.contains("drift_exit=1")
      check loud.output.contains("runquota-src")

  test "t_dev_shell_git_queries_go_through_the_one_guarded_entry_point":
    ## The guard above is only as good as the next call site to remember it,
    ## and "remember it at every call site" is the shape of the defect it
    ## fixes. So the library is required to reach git through exactly one
    ## door, and the script that asks the same question about four checkouts
    ## is required to clear the same variables on the way in.
    ##
    ## Static, and deliberately so: the failure being prevented is a NEW `git
    ## -C` written next to the old ones, which no runtime test of today's call
    ## sites can see.
    let lib = readFile(libPath())

    # The variable names actually passed to `unset`, read out of the body
    # rather than out of the prose around it — a comment naming six
    # variables and an `unset` clearing one must not read as agreement.
    proc unsetNames(text, marker: string): seq[string] =
      let start = text.find(marker)
      if start < 0: return
      var i = start
      while i < text.len:
        let stop = text.find('\n', i)
        let line = if stop < 0: text[i .. ^1] else: text[i ..< stop]
        for word in line.split():
          if word.startsWith("GIT_"):
            result.add(word)
        if not line.strip().endsWith("\\"): break
        if stop < 0: break
        i = stop + 1

    let guarded = unsetNames(lib, "unset GIT_DIR")
    checkpoint("cleared by dev_shell_git: " & guarded.join(" "))
    # Every variable that redirects which repository, tree, index or object
    # store git answers from. `GIT_PREFIX` and `GIT_NAMESPACE` are absent on
    # purpose: neither steers repository resolution, and clearing a hook's
    # variables that do no harm is scope this function has not earned.
    for name in ["GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE",
                 "GIT_COMMON_DIR", "GIT_OBJECT_DIRECTORY",
                 "GIT_ALTERNATE_OBJECT_DIRECTORIES"]:
      checkpoint("dev_shell_git must clear " & name)
      check guarded.contains(name)

    proc codeLines(text: string): seq[string] =
      ## Lines that run, as opposed to lines that talk about lines that run.
      for line in text.splitLines():
        let bare = line.strip()
        if bare.len > 0 and not bare.startsWith("#"):
          result.add(bare)

    # Exactly one door in the library.
    var offenders: seq[string]
    for bare in codeLines(lib):
      if bare.contains("git -C") and not bare.contains("dev_shell_git -C"):
        offenders.add(bare)
    checkpoint("unguarded git -C call sites:\n" & offenders.join("\n"))
    check offenders.len == 0
    # ...and the door is actually used, so a library that had simply stopped
    # asking git anything could not satisfy the line above.
    check lib.contains("dev_shell_git -C")

    # The acceptance runner asks the same question about four checkouts. It is
    # a script and not a library, so it clears the redirection once on the way
    # in instead of per call site — but it must clear the SAME set, or the two
    # places that answer "which revision is that sibling at" answer differently
    # under a hook.
    let acceptance = readFile(repoRoot() / "scripts" / "run-m24-acceptance.sh")
    # It still asks the question — a runner that had stopped querying git
    # would satisfy the clearing assertions below for the wrong reason.
    check codeLines(acceptance).filterIt(it.contains("git -C")).len > 0
    let cleared = unsetNames(acceptance, "unset GIT_DIR")
    checkpoint("cleared by run-m24-acceptance.sh: " & cleared.join(" "))
    for name in guarded:
      checkpoint("acceptance runner must clear " & name)
      check cleared.contains(name)
