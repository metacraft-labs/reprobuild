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
