## Two profile resources that write one real-world object -- one file, one
## variable, one block -- under two addresses are refused at plan time,
## before anything is written, by `repro home facts`, `repro home apply
## --plan` and `repro home apply` alike (reprobuild-pm issue
## 2026-10-18-home-apply-applies-two-resources-for-one-path-or-variable;
## Home-Profile-Resource-Lifecycle.md §One Real-World Object, One Resource;
## Gradual-Nix-To-Reprobuild-Migration.md §Host facts, "A category holds
## each id once").
##
## Before the fix `collectProfileResources` refused only a duplicate
## ADDRESS. The apply wrote both resources, the last declaration won, and
## the next apply reported the first resource's "drift" against the second
## resource's write; `repro home facts` refused the same profiles, so facts
## and apply disagreed on whether the profile was valid.
##
## `e2e_pairs_on_one_target_are_refused_before_anything_is_written`, one
## fixture per pair:
##
## * two `envUserVariable` for `C1_EDITOR` (`nvim` / `emacs`): the refusal
##   names both addresses, the target `var:C1_EDITOR` and the differing
##   value;
## * two `fsUserFile` for `~/.c1-two` (`a\n` / `b\n`): the differing digest;
## * two `fsUserFile` for `~/.c1-two` with the same bytes but modes 0644 /
##   0600: the differing mode;
## * two `fsManagedBlock` for one `hostFile#blockId`: the differing digest;
## * two `fsUserFile` that AGREE (same bytes, same mode): refused too, as
##   "declare it once" -- each address is bound to what it writes, so
##   removing either would destroy the other's file;
## * (POSIX) two `envUserPath` sharing an entry: a profile-declared
##   `env.userPath` owns the rc file's one PATH block, so the pair are two
##   writers of that block. (On Windows the driver merges each resource's
##   entries into the user PATH value, so there the pair is not refused.)
##
## For each: `repro home facts` exits non-zero with the refusal, `repro home
## apply --plan` and `repro home apply` too, HOME is unchanged (tree
## fingerprint, which includes the rc files the env drivers write), and no
## generation is recorded.
##
## `e2e_distinct_targets_apply_and_stay_steady`: negative control. The same
## shapes with the second resource on another target (`C1_EDITOR2`,
## `~/.c1-three`) apply, write both, and a second apply is a no-op that
## reports no drift.
##
## Falsifying mutation (performed; see the issue's Resolution): with the
## identity check in `collectProfileResources` removed, every case of the
## first test goes red (facts refuses only the variable and file pairs, and
## with a different message; apply exits 0 and writes HOME).
##
## No mocks: the real `build/bin/repro`, profile compile edge, planner and
## env / file / block drivers, in the harness's isolated sandbox (its own
## HOME, state and store).

import std/[os, strutils, unittest]
from repro_core/paths import extendedPath

import repro_home_generations

import ../m83/profile_compile_edge_harness

proc profileWith(resources: string): string =
  "import repro_profile\n\nprofile \"c1TwoResources\":\n" &
    "  activity default:\n    discard\n\n  resources:\n" & resources

proc show(label: string; r: ReproRun) =
  checkpoint(label & " -> exit " & $r.exitCode & "\n--- stdout\n" &
    r.stdout & "\n--- stderr\n" & r.stderr)

type Pair = tuple[label, resources, needle: string]

proc pairs(): seq[Pair] =
  result = @[
    ("variable",
     "    envUserVariable(name = \"C1_EDITOR\", value = \"nvim\", " &
       "address = \"editorA\")\n" &
     "    envUserVariable(name = \"C1_EDITOR\", value = \"emacs\", " &
       "address = \"editorB\")\n",
     "and `editorB` both write `var:C1_EDITOR` (env.userVariable) and " &
       "disagree on value (\"nvim\" vs \"emacs\"); one object has one " &
       "writer: remove one of them"),
    ("file-bytes",
     "    fsUserFile(hostFile = \"~/.c1-two\", content = \"a\\n\", " &
       "address = \"twoA\")\n" &
     "    fsUserFile(hostFile = \"~/.c1-two\", content = \"b\\n\", " &
       "address = \"twoB\")\n",
     # `printf 'a\n' | sha256sum`, `printf 'b\n' | sha256sum` (coreutils).
     "and `twoB` both write `~/.c1-two` (fs.userFile) and disagree on " &
       "digest (sha256:87428fc522803d31065e7bce3cf03fe475096631e5e07bbd7a0" &
       "fde60c4cf25c7 vs sha256:0263829989b6fd954f72baaf2fc64bc2e2f01d692d" &
       "4de72986ea808f6e99813f)"),
    ("file-mode",
     "    fsUserFile(hostFile = \"~/.c1-two\", content = \"a\\n\", " &
       "address = \"twoA\")\n" &
     "    fsUserFile(hostFile = \"~/.c1-two\", content = \"a\\n\", " &
       "mode = \"0600\", address = \"twoB\")\n",
     "and `twoB` both write `~/.c1-two` (fs.userFile) and disagree on " &
       "mode (0644 vs 0600)"),
    ("block",
     "    fsManagedBlock(hostFile = \"~/.c1rc\", blockId = \"c1\", " &
       "content = \"one\", address = \"blockA\")\n" &
     "    fsManagedBlock(hostFile = \"~/.c1rc\", blockId = \"c1\", " &
       "content = \"two\", address = \"blockB\")\n",
     "and `blockB` both write `block:~/.c1rc#c1` (fs.managedBlock) and " &
       "disagree on digest"),
    ("file-agree",
     "    fsUserFile(hostFile = \"~/.c1-two\", content = \"a\\n\", " &
       "address = \"twoA\")\n" &
     "    fsUserFile(hostFile = \"~/.c1-two\", content = \"a\\n\", " &
       "address = \"twoB\")\n",
     "and `twoB` both write `~/.c1-two` (fs.userFile); they agree, but " &
       "each resource owns what it writes, so removing either would " &
       "destroy the other's: declare it once")]
  when not defined(windows):
    result.add ("path",
     "    envUserPath(entries = \"~/.c1/bin, /opt/c1a\", " &
       "address = \"c1PathA\")\n" &
     "    envUserPath(entries = \"~/.c1/bin, /opt/c1b\", " &
       "address = \"c1PathB\")\n",
     "and `c1PathB` both write `the PATH block of ")

suite "Two profile resources on one target":

  test "e2e_pairs_on_one_target_are_refused_before_anything_is_written":
    for (label, resources, needle) in pairs():
      checkpoint("pair: " & label)
      let sb = newProfileSandbox("two-res-" & label, profileWith(resources))
      defer: sb.dispose()
      let homeBefore = treeFingerprint(sb.homeDir)

      let facts = sb.runRepro(["home", "facts"])
      show(label & ": facts", facts)
      check facts.exitCode != 0
      check needle in facts.stderr

      let plan = sb.runRepro(["home", "apply", "--plan"])
      show(label & ": apply --plan", plan)
      check plan.exitCode != 0
      check needle in (plan.stdout & plan.stderr)

      let applied = sb.runRepro(["home", "apply"])
      show(label & ": apply", applied)
      check applied.exitCode != 0
      check needle in (applied.stdout & applied.stderr)
      # Refused before anything was written.
      check treeFingerprint(sb.homeDir) == homeBefore
      check readCurrentGenerationId(sb.stateDir).len == 0

  test "e2e_distinct_targets_apply_and_stay_steady":
    let sb = newProfileSandbox("two-res-distinct", profileWith(
      "    envUserVariable(name = \"C1_EDITOR\", value = \"nvim\", " &
        "address = \"editorA\")\n" &
      "    envUserVariable(name = \"C1_EDITOR2\", value = \"emacs\", " &
        "address = \"editorB\")\n" &
      "    fsUserFile(hostFile = \"~/.c1-two\", content = \"a\\n\", " &
        "address = \"twoA\")\n" &
      "    fsUserFile(hostFile = \"~/.c1-three\", content = \"b\\n\", " &
        "address = \"twoB\")\n"))
    defer: sb.dispose()
    let facts = sb.runRepro(["home", "facts"])
    show("facts", facts)
    check facts.exitCode == 0
    let applied = sb.runRepro(["home", "apply"])
    show("apply", applied)
    require applied.exitCode == 0
    check readFile(extendedPath(sb.homeDir / ".c1-two")) == "a\n"
    check readFile(extendedPath(sb.homeDir / ".c1-three")) == "b\n"
    let again = sb.runRepro(["home", "apply"])
    show("apply again", again)
    check again.exitCode == 0
    check "drift" notin (again.stdout & again.stderr).toLowerAscii
    check again.stdout.contains("no-op")
