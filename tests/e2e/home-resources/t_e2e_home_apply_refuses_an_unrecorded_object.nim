## `repro home apply` does not overwrite an existing object no generation
## records the first time it applies a whole-object resource (reprobuild-pm
## issue 2026-10-16-home-apply-overwrites-an-unrecorded-object-when-it-first-
## applies-a-resource; Home-Profile-Resource-Lifecycle.md §Lifecycle Decision
## Algorithm, §Drift Handling).
##
## A whole-object resource (`fs.userFile`, `fs.managedBlock`, ...) is declared
## for an object that already exists, holds other content, and is recorded by
## no generation -- a dotfile the user wrote, a Home Manager link, a block a
## lost state directory once recorded. Through the real `build/bin/repro`:
##
## * `e2e_first_apply_refuses_an_unrecorded_file` -- `repro home apply` fails
##   as drift naming the address and both remedies, writes nothing (the file,
##   and a sibling resource that would have been created, untouched) and
##   records no generation; `apply --plan` shows the same drift. The same for
##   a symlink at the path (the shape Home Manager leaves): the link is kept.
##   `--reconcile-drift` then replaces the file with the declared content.
## * `e2e_first_apply_refuses_an_unrecorded_block` -- the same for an
##   `fs.managedBlock` whose sentinels are already in the host file with
##   another body; the text around the block is kept too.
## * `e2e_adopt_claims_an_unrecorded_file` -- `repro home adopt` records the
##   object as it is, without writing it; the next apply is then an ordinary
##   update of a recorded object.
## * `e2e_first_apply_positive_controls` -- an absent object is created, and
##   one already holding the declared bytes is recorded without a write, both
##   without any flag; the recorded object then updates when the declared
##   content changes, and is destroyed when the resource is removed. (A
##   first-apply no-op used to record nothing; with only the drift rule
##   above, the content change was then refused as an unrecorded object and
##   the removal left the file -- measured on home-pc before the no-op began
##   recording.)
## * `e2e_widening_over_an_agreeing_home_manager_link_needs_no_flag` (POSIX)
##   -- the GNM handover: a host's `applies:` widens to `files` over a Home
##   Manager link into its store that already holds the declared bytes. No
##   flag: the link is recorded as it is, untouched, and a later content
##   change replaces the link instead of writing through it into the store.
##
## Before the fix every refusal case below replaced the object and exited 0
## (`decideAction` converged every unrecorded object). The kinds whose
## observation of "nothing of ours yet" is not an object of someone else's
## (`env.userPath`, `vscode.extension`, `linux.gsettings`, the Homebrew kinds:
## `builtinResourceOwnership`) still converge;
## `libs/repro_home_resources/tests/t_smoke_home_resources.nim` pins the
## per-kind table.
##
## No mocks: the real `build/bin/repro`, the real profile compile edge, the
## real planner and the real drivers, in the harness's isolated sandbox (its
## own HOME, state and store). Platforms: every host.

import std/[os, strutils, unittest]
from repro_core/paths import extendedPath

import repro_home_generations

import ../m83/profile_compile_edge_harness

const
  Declared = "[user]\n\tname = declared\n"
  Theirs = "[user]\n\tname = someone else\n"
  SiblingContent = "sibling\n"

proc profileWith(resources: string): string =
  "import repro_profile\n\nprofile \"unrecordedObject\":\n" &
    "  activity default:\n    discard\n\n  resources:\n" & resources

const FileProfile = """    fsUserFile(hostFile = "~/.unrec-gitconfig", content = "[user]\n\tname = declared\n", address = "gitconfig")
    fsUserFile(hostFile = "~/.unrec-sibling", content = "sibling\n", address = "sibling")
"""

const BlockProfile = """    fsManagedBlock(hostFile = "~/.unrec-rc", blockId = "unrec", content = "export UNREC=declared", address = "rcBlock")
"""

proc show(label: string; r: ReproRun) =
  checkpoint(label & " -> exit " & $r.exitCode & "\n--- stdout\n" &
    r.stdout & "\n--- stderr\n" & r.stderr)

proc both(r: ReproRun): string = r.stdout & r.stderr

proc checkRefusedAsDrift(sb: ProfileSandbox; address: string;
                         homeBefore: seq[string]) =
  ## `apply --plan` reports the drift, `apply` refuses it naming the address
  ## and both remedies, and neither changes HOME or records a generation.
  let plan = sb.runRepro(["home", "apply", "--plan"])
  show("apply --plan", plan)
  check "1 drift(s)" in plan.both
  check ("DRIFT    " & address) in plan.both or
    (address in plan.both and "drift" in plan.both)
  let applied = sb.runRepro(["home", "apply"])
  show("apply", applied)
  check applied.exitCode != 0
  check "drift detected at " in applied.both
  check address in applied.both
  check "no generation records it" in applied.both
  check "--reconcile-drift" in applied.both
  check "repro home adopt" in applied.both
  check treeFingerprint(sb.homeDir) == homeBefore
  check readCurrentGenerationId(sb.stateDir).len == 0

suite "home apply: an unrecorded object is drift on first apply":

  test "e2e_first_apply_refuses_an_unrecorded_file":
    let sb = newProfileSandbox("unrec-file", profileWith(FileProfile))
    defer: sb.dispose()
    let target = sb.homeDir / ".unrec-gitconfig"
    writeFile(extendedPath(target), Theirs)
    let before = treeFingerprint(sb.homeDir)
    sb.checkRefusedAsDrift("gitconfig", before)
    check readFile(extendedPath(target)) == Theirs
    # The sibling resource the same apply would have created was not either.
    check not fileExists(extendedPath(sb.homeDir / ".unrec-sibling"))

    # `--reconcile-drift` is the explicit override.
    let reconciled = sb.runRepro(["home", "apply", "--reconcile-drift"])
    show("apply --reconcile-drift", reconciled)
    require reconciled.exitCode == 0
    check readFile(extendedPath(target)) == Declared
    check readFile(extendedPath(sb.homeDir / ".unrec-sibling")) ==
      SiblingContent
    check readCurrentGenerationId(sb.stateDir).len > 0

  when not defined(windows):
    test "e2e_first_apply_refuses_an_unrecorded_symlink":
      # The shape Home Manager leaves: a link into a store path the profile
      # does not own.
      let sb = newProfileSandbox("unrec-link", profileWith(FileProfile))
      defer: sb.dispose()
      let foreign = sb.root / "foreign-store" / "gitconfig"
      createDir(extendedPath(foreign.parentDir))
      writeFile(extendedPath(foreign), Theirs)
      let target = sb.homeDir / ".unrec-gitconfig"
      createSymlink(foreign, target)
      let before = treeFingerprint(sb.homeDir)
      sb.checkRefusedAsDrift("gitconfig", before)
      check symlinkExists(extendedPath(target))
      check expandSymlink(target) == foreign
      check readFile(extendedPath(foreign)) == Theirs

  test "e2e_first_apply_refuses_an_unrecorded_block":
    let sb = newProfileSandbox("unrec-block", profileWith(BlockProfile))
    defer: sb.dispose()
    let rc = sb.homeDir / ".unrec-rc"
    let original = "# the user's own line\n" &
      "# >>> repro-managed:unrec >>>\nexport UNREC=theirs\n" &
      "# <<< repro-managed:unrec <<<\n" & "# another line\n"
    writeFile(extendedPath(rc), original)
    let before = treeFingerprint(sb.homeDir)
    sb.checkRefusedAsDrift("rcBlock", before)
    check readFile(extendedPath(rc)) == original

    let reconciled = sb.runRepro(["home", "apply", "--reconcile-drift"])
    show("apply --reconcile-drift", reconciled)
    require reconciled.exitCode == 0
    let after = readFile(extendedPath(rc))
    check "export UNREC=declared" in after
    check "export UNREC=theirs" notin after
    check "# the user's own line" in after
    check "# another line" in after

  test "e2e_adopt_claims_an_unrecorded_file":
    let sb = newProfileSandbox("unrec-adopt", profileWith(FileProfile))
    defer: sb.dispose()
    let target = sb.homeDir / ".unrec-gitconfig"
    writeFile(extendedPath(target), Theirs)
    let adopted = sb.runRepro(["home", "adopt", "gitconfig"])
    show("adopt gitconfig", adopted)
    require adopted.exitCode == 0
    # Adopt records, it does not write.
    check readFile(extendedPath(target)) == Theirs
    let adoptedGen = readCurrentGenerationId(sb.stateDir)
    check adoptedGen.len > 0
    # The object is now recorded, so the next apply is an ordinary update of
    # what the generation holds, with no flag.
    let next = sb.runRepro(["home", "apply"])
    show("apply after adopt", next)
    require next.exitCode == 0
    check readFile(extendedPath(target)) == Declared
    check readCurrentGenerationId(sb.stateDir) != adoptedGen

  test "e2e_first_apply_positive_controls":
    let sb = newProfileSandbox("unrec-controls", profileWith(FileProfile))
    defer: sb.dispose()
    # `.unrec-gitconfig` already holds the declared bytes; the sibling is
    # absent.
    let target = sb.homeDir / ".unrec-gitconfig"
    writeFile(extendedPath(target), Declared)
    let mtimeBefore = getLastModificationTime(extendedPath(target))
    let applied = sb.runRepro(["home", "apply"])
    show("apply", applied)
    require applied.exitCode == 0
    check readFile(extendedPath(target)) == Declared
    check getLastModificationTime(extendedPath(target)) == mtimeBefore
    check readFile(extendedPath(sb.homeDir / ".unrec-sibling")) ==
      SiblingContent
    check readCurrentGenerationId(sb.stateDir).len > 0

    # The object that already held the declared bytes is now this
    # generation's: a change of the declared content is an ordinary update
    # (no drift, no flag), and removing the resource destroys it.
    writeFile(extendedPath(sb.profilePath), profileWith(
      FileProfile.replace("name = declared", "name = changed")))
    let changed = sb.runRepro(["home", "apply"])
    show("apply with changed content", changed)
    check changed.exitCode == 0
    check readFile(extendedPath(target)) == Declared.replace("declared",
      "changed")
    writeFile(extendedPath(sb.profilePath), profileWith(
      "    fsUserFile(hostFile = \"~/.unrec-sibling\", " &
      "content = \"sibling\\n\", address = \"sibling\")\n"))
    let removed = sb.runRepro(["home", "apply"])
    show("apply without the gitconfig resource", removed)
    check removed.exitCode == 0
    check not fileExists(extendedPath(target))

  when not defined(windows):
    test "e2e_widening_over_an_agreeing_home_manager_link_needs_no_flag":
      # The GNM handover (Gradual-Nix-To-Reprobuild-Migration.md
      # §Concern-scoped apply, "Widening is an ordinary apply"): the host
      # first applies only `packages`, Home Manager has placed
      # `~/.unrec-gitconfig` as a link into its store holding exactly the
      # bytes the profile declares, and the host's `applies:` then widens to
      # `files`. The object already holds the declared content, so the
      # widening apply needs no flag: it records the link as it is (no
      # write, the link and the store file untouched) and creates the absent
      # sibling. The record makes the object this generation's, so a later
      # change of the declared content is an ordinary update, which replaces
      # the link with a file and never writes through it into the store.
      proc hostsProfile(applies: string; name = "declared"): string =
        "import repro_profile\n\nprofile \"unrecordedObject\":\n" &
          "  activity default:\n    discard\n\n  hosts:\n" &
          "    \"" & DefaultSandboxHost & "\":\n" &
          "      activities: [default]\n      applies: [" & applies & "]\n" &
          "\n  resources:\n" &
          FileProfile.replace("name = declared", "name = " & name)
      let sb = newProfileSandbox("unrec-widen",
        hostsProfile("packages"))
      defer: sb.dispose()
      let store = sb.root / "foreign-store" / "hm-files" / "gitconfig"
      createDir(extendedPath(store.parentDir))
      writeFile(extendedPath(store), Declared)
      let target = sb.homeDir / ".unrec-gitconfig"
      createSymlink(store, target)
      let sibling = sb.homeDir / ".unrec-sibling"

      # Before widening: `files` is not applied, nothing is written.
      let narrow = sb.runRepro(["home", "apply"])
      show("apply, applies: [packages]", narrow)
      require narrow.exitCode == 0
      check not fileExists(extendedPath(sibling))
      let narrowGen = readCurrentGenerationId(sb.stateDir)

      # Widening: --plan shows no drift, and the apply needs no flag.
      writeFile(extendedPath(sb.profilePath),
        hostsProfile("packages, files"))
      let plan = sb.runRepro(["home", "apply", "--plan"])
      show("apply --plan, widened", plan)
      check plan.exitCode == 0
      check "0 drift(s)" in plan.both
      let widened = sb.runRepro(["home", "apply"])
      show("apply, widened", widened)
      require widened.exitCode == 0
      let widenedGen = readCurrentGenerationId(sb.stateDir)
      check widenedGen.len > 0 and widenedGen != narrowGen
      check symlinkExists(extendedPath(target))
      check expandSymlink(target) == store
      check readFile(extendedPath(store)) == Declared
      check readFile(extendedPath(sibling)) == SiblingContent

      # Recorded: a content change is an ordinary update, and it replaces the
      # link instead of writing through it.
      writeFile(extendedPath(sb.profilePath),
        hostsProfile("packages, files", "changed"))
      let changed = sb.runRepro(["home", "apply"])
      show("apply, changed content", changed)
      check changed.exitCode == 0
      check not symlinkExists(extendedPath(target))
      check readFile(extendedPath(target)) ==
        Declared.replace("declared", "changed")
      check readFile(extendedPath(store)) == Declared
