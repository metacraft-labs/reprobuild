## `repro home rollback` checks a resource it removes or updates against the
## current generation's record before anything is written (reprobuild-pm
## issue 2026-10-16-home-rollback-removes-and-updates-resources-without-a-
## drift-check; Home-Profile-Resource-Lifecycle.md §Drift Handling: "when
## observed state differs from recorded, do not overwrite").
##
## Generation A declares `fs.userFile` `~/.rb-x` ("a") and an
## `fs.managedBlock` in `~/.rb-rc` ("export RB=a"); B changes both and adds
## `fs.userFile` `~/.rb-only-b`. Rolling back from B to A therefore UPDATES the
## file and the block and REMOVES `~/.rb-only-b`. Through the real
## `build/bin/repro`:
##
## * `e2e_rollback_refuses_a_hand_edited_removed_resource`,
##   `..._updated_file`, `..._updated_block`: the user edits one object B
##   wrote; the rollback exits non-zero as a user edit naming the address and
##   `--accept-overwrite`, and changes nothing (the edit, the other objects,
##   the current generation). `--accept-overwrite` then rolls back.
## * `e2e_rollback_resource_positive_controls`: with no edit, with an edit that
##   already holds A's content, and with the removed object already gone, the
##   rollback runs without `--accept-overwrite` and leaves A's state.
## * `e2e_rollback_keeps_an_object_the_current_generation_destroyed`: A has no
##   `~/.rb-only-b`, B creates it, C (A plus `~/.rb-only-c`) destroys it, and
##   the user then puts their own file there. Rolling back from C to A has the
##   resource only in C's record, as destroyed; the current generation owns
##   nothing at the path, so the rollback leaves the user's file alone.
## * `e2e_rollback_to_a_generation_that_destroyed_a_resource_removes_it`:
##   rolling back to a generation that records a resource as destroyed
##   removes the object (checked against the current record) instead of
##   writing the bytes that generation destroyed (reprobuild-pm issue
##   2026-10-18-home-rollback-recreates-a-resource-the-target-generation-
##   records-as-destroyed).
## * `e2e_reapplying_an_earlier_profile_keeps_its_generation_usable`: A, B,
##   then A again re-activates A's content-addressed id; its pointer then
##   carries that apply (reprobuild-pm issue 2026-10-20-reapplying-an-
##   earlier-home-profile-rewrites-its-generation-pointer), history lists
##   each id once, and rollback between the two restores each state.
## * `e2e_rollback_never_restores_a_resource_the_target_records_as_destroyed`:
##   the restore form of the destroyed-record case, from a generation whose
##   host is narrowed so it records nothing of the resource (reprobuild-pm
##   issue 2026-10-20-home-rollback-restores-the-bytes-of-a-resource-the-
##   target-generation-destroyed): the path stays absent, and a user's file
##   there is kept. Before the fix the rollback wrote the destroyed bytes,
##   over the user's file too.
##
## Before the fix every refusal case below exited 0 and replaced or deleted
## the user's edit (the drift pass checked resources only on restore), and
## the destroyed-record case deleted the user's file; rolling back to the
## generation that destroyed `rbOnlyB` rewrote it with the destroyed bytes.
##
## No mocks: the real `build/bin/repro`, the real profile compile edge, the
## real planner and drivers, in the harness's isolated sandbox (its own HOME,
## state and store). Platforms: every host.

import std/[os, sequtils, strutils, unittest]
from repro_core/paths import extendedPath

import repro_home_generations

import ../m83/profile_compile_edge_harness

proc profileWith(resources: string): string =
  "import repro_profile\n\nprofile \"rollbackResourceDrift\":\n" &
    "  activity default:\n    discard\n\n  resources:\n" & resources

const
  ProfileA = profileWith("""    fsUserFile(hostFile = "~/.rb-x", content = "a\n", address = "rbX")
    fsManagedBlock(hostFile = "~/.rb-rc", blockId = "rb", content = "export RB=a", address = "rbBlock")
""")
  ProfileB = profileWith("""    fsUserFile(hostFile = "~/.rb-x", content = "b\n", address = "rbX")
    fsManagedBlock(hostFile = "~/.rb-rc", blockId = "rb", content = "export RB=b", address = "rbBlock")
    fsUserFile(hostFile = "~/.rb-only-b", content = "only-b\n", address = "rbOnlyB")
""")
  ProfileC = profileWith("""    fsUserFile(hostFile = "~/.rb-x", content = "a\n", address = "rbX")
    fsManagedBlock(hostFile = "~/.rb-rc", blockId = "rb", content = "export RB=a", address = "rbBlock")
    fsUserFile(hostFile = "~/.rb-only-c", content = "only-c\n", address = "rbOnlyC")
""")
    ## A plus one resource of its own, so C is a generation of its own (a
    ## home generation id follows the profile) that records B's `rbOnlyB`
    ## as destroyed. Re-applying A itself would re-activate A's id (by
    ## design; `e2e_reapplying_an_earlier_profile_keeps_its_generation_
    ## usable`), leaving no earlier generation without `rbOnlyB` to roll
    ## back to.
  ProfileD = profileWith("""    fsUserFile(hostFile = "~/.rb-x", content = "a\n", address = "rbX")
    fsManagedBlock(hostFile = "~/.rb-rc", blockId = "rb", content = "export RB=a", address = "rbBlock")
    fsUserFile(hostFile = "~/.rb-only-b", content = "only-d\n", address = "rbOnlyB")
""")
    ## A with B's `rbOnlyB` back, holding other content.
  Mine = "the user's own content\n"

proc show(label: string; r: ReproRun) =
  checkpoint(label & " -> exit " & $r.exitCode & "\n--- stdout\n" &
    r.stdout & "\n--- stderr\n" & r.stderr)

proc both(r: ReproRun): string = r.stdout & r.stderr

proc apply(sb: ProfileSandbox; profile, label: string): string =
  ## Apply `profile`; returns the new current generation id.
  writeFile(extendedPath(sb.profilePath), profile)
  let r = sb.runRepro(["home", "apply"])
  show("apply " & label, r)
  doAssert r.exitCode == 0, "apply " & label & " failed: " & r.both
  result = readCurrentGenerationId(sb.stateDir)
  doAssert result.len > 0

type Gens = tuple[a, b: string]

proc twoGenerations(sb: ProfileSandbox): Gens =
  result.a = sb.apply(ProfileA, "A")
  doAssert readFile(extendedPath(sb.homeDir / ".rb-x")) == "a\n"
  doAssert not fileExists(extendedPath(sb.homeDir / ".rb-only-b"))
  result.b = sb.apply(ProfileB, "B")
  doAssert result.b != result.a
  doAssert readFile(extendedPath(sb.homeDir / ".rb-x")) == "b\n"
  doAssert readFile(extendedPath(sb.homeDir / ".rb-only-b")) == "only-b\n"
  doAssert "export RB=b" in readFile(extendedPath(sb.homeDir / ".rb-rc"))

proc rollback(sb: ProfileSandbox; args: varargs[string]): ReproRun =
  result = sb.runRepro(@["home", "rollback"] & @args)
  show("rollback " & args.join(" "), result)

proc checkInA(sb: ProfileSandbox; gens: Gens) =
  ## The state A recorded, and A is current.
  check readCurrentGenerationId(sb.stateDir) == gens.a
  check readFile(extendedPath(sb.homeDir / ".rb-x")) == "a\n"
  check not fileExists(extendedPath(sb.homeDir / ".rb-only-b"))
  let rc = readFile(extendedPath(sb.homeDir / ".rb-rc"))
  check "export RB=a" in rc
  check "export RB=b" notin rc

proc checkRefused(sb: ProfileSandbox; gens: Gens; address: string;
                  homeBefore: seq[string]) =
  let refused = sb.rollback()
  check refused.exitCode != 0
  check "user edit detected" in refused.both
  check address in refused.both
  check "--accept-overwrite" in refused.both
  # Nothing was written: not the edit, not the objects the rollback would
  # have changed next, not the current pointer.
  check treeFingerprint(sb.homeDir) == homeBefore
  check readCurrentGenerationId(sb.stateDir) == gens.b
  # The explicit override rolls back.
  let accepted = sb.rollback("--accept-overwrite")
  check accepted.exitCode == 0
  sb.checkInA(gens)

suite "rollback: resource removes and updates respect drift":

  test "e2e_rollback_refuses_a_hand_edited_removed_resource":
    let sb = newProfileSandbox("rb-remove", ProfileA)
    defer: sb.dispose()
    let gens = sb.twoGenerations()
    writeFile(extendedPath(sb.homeDir / ".rb-only-b"), Mine)
    let before = treeFingerprint(sb.homeDir)
    sb.checkRefused(gens, "rbOnlyB", before)
    # After `--accept-overwrite`: A is current again.
    check readCurrentGenerationId(sb.stateDir) == gens.a

  test "e2e_rollback_refuses_a_hand_edited_updated_file":
    let sb = newProfileSandbox("rb-update-file", ProfileA)
    defer: sb.dispose()
    let gens = sb.twoGenerations()
    writeFile(extendedPath(sb.homeDir / ".rb-x"), Mine)
    let before = treeFingerprint(sb.homeDir)
    sb.checkRefused(gens, "rbX", before)
    # After `--accept-overwrite`: A is current again.
    check readCurrentGenerationId(sb.stateDir) == gens.a

  test "e2e_rollback_refuses_a_hand_edited_updated_block":
    let sb = newProfileSandbox("rb-update-block", ProfileA)
    defer: sb.dispose()
    let gens = sb.twoGenerations()
    let rc = sb.homeDir / ".rb-rc"
    writeFile(extendedPath(rc), readFile(extendedPath(rc)).replace(
      "export RB=b", "export RB=mine"))
    let before = treeFingerprint(sb.homeDir)
    sb.checkRefused(gens, "rbBlock", before)
    # After `--accept-overwrite`: A is current again.
    check readCurrentGenerationId(sb.stateDir) == gens.a

  test "e2e_rollback_resource_positive_controls":
    block noEdit:
      let sb = newProfileSandbox("rb-control-clean", ProfileA)
      defer: sb.dispose()
      let gens = sb.twoGenerations()
      let ok = sb.rollback()
      check ok.exitCode == 0
      sb.checkInA(gens)
    block alreadyTarget:
      # The updated file already holds A's bytes, and the removed one is
      # already gone: neither is someone else's object.
      let sb = newProfileSandbox("rb-control-target", ProfileA)
      defer: sb.dispose()
      let gens = sb.twoGenerations()
      writeFile(extendedPath(sb.homeDir / ".rb-x"), "a\n")
      removeFile(extendedPath(sb.homeDir / ".rb-only-b"))
      let ok = sb.rollback()
      check ok.exitCode == 0
      sb.checkInA(gens)

  test "e2e_rollback_keeps_an_object_the_current_generation_destroyed":
    let sb = newProfileSandbox("rb-destroyed", ProfileA)
    defer: sb.dispose()
    let gens = sb.twoGenerations()
    let c = sb.apply(ProfileC, "C")
    check c != gens.a and c != gens.b
    check not fileExists(extendedPath(sb.homeDir / ".rb-only-b"))
    check readFile(extendedPath(sb.homeDir / ".rb-only-c")) == "only-c\n"
    # The user's own file where B's resource was.
    writeFile(extendedPath(sb.homeDir / ".rb-only-b"), Mine)
    let r = sb.rollback(gens.a)
    check r.exitCode == 0
    check readCurrentGenerationId(sb.stateDir) == gens.a
    let mine = sb.homeDir / ".rb-only-b"
    check fileExists(extendedPath(mine))
    if fileExists(extendedPath(mine)):
      check readFile(extendedPath(mine)) == Mine
    check readFile(extendedPath(sb.homeDir / ".rb-x")) == "a\n"
    # C's own resource, which the current generation does own, is removed.
    check not fileExists(extendedPath(sb.homeDir / ".rb-only-c"))

  test "e2e_rollback_to_a_generation_that_destroyed_a_resource_removes_it":
    # reprobuild-pm issue 2026-10-18-home-rollback-recreates-a-resource-the-
    # target-generation-records-as-destroyed. C records B's `rbOnlyB` as
    # destroyed (its record's payload is the bytes C destroyed, "only-b");
    # D declares it again with "only-d". Rolling back from D to C must leave
    # `~/.rb-only-b` absent, as C recorded it -- before the fix it was
    # rewritten with "only-b". The removal is checked against D's record
    # like any other remove.
    for edited in [false, true]:
      checkpoint("user edit: " & $edited)
      let sb = newProfileSandbox("rb-to-destroyed", ProfileA)
      defer: sb.dispose()
      discard sb.twoGenerations()
      let c = sb.apply(ProfileC, "C")
      let d = sb.apply(ProfileD, "D")
      check d != c
      let onlyB = sb.homeDir / ".rb-only-b"
      check readFile(extendedPath(onlyB)) == "only-d\n"
      if edited:
        writeFile(extendedPath(onlyB), Mine)
        let before = treeFingerprint(sb.homeDir)
        let refused = sb.rollback(c)
        check refused.exitCode != 0
        check "user edit detected" in refused.both
        check "rbOnlyB" in refused.both
        check treeFingerprint(sb.homeDir) == before
        check readCurrentGenerationId(sb.stateDir) == d
      else:
        let r = sb.rollback(c)
        check r.exitCode == 0
        check readCurrentGenerationId(sb.stateDir) == c
        check not fileExists(extendedPath(onlyB))
        # C's own resource, which D destroyed, is restored.
        check readFile(extendedPath(sb.homeDir / ".rb-only-c")) == "only-c\n"

  test "e2e_reapplying_an_earlier_profile_keeps_its_generation_usable":
    # A -> B -> A again. A home generation id is content-addressed
    # (Home-Profile-Generations-And-State.md §Generation Identity: "two
    # identical applies ... produce the same id"), so the third apply
    # re-activates A's id. Its pointer then carries that apply's activation
    # time and manifest (§Pointer Envelope): the update of `rbX` from B's
    # bytes and the destruction of B's `rbOnlyB`, which the first apply of A
    # never saw. History lists each id once, A newest, and rolling back and
    # forth between the two still restores each one's state with no flag.
    let sb = newProfileSandbox("rb-a-b-a", ProfileA)
    defer: sb.dispose()
    let gens = sb.twoGenerations()
    let again = sb.apply(ProfileA, "A again")
    check again == gens.a
    sb.checkInA(gens)
    let history = sb.runRepro(["home", "history"])
    show("history", history)
    check history.exitCode == 0
    let lines = history.stdout.splitLines.filterIt(
      it.startsWith("  ") and "host=" in it)
    check lines.len == 2
    if lines.len == 2:
      check lines[0].strip.startsWith(gens.b[0 ..< 12])
      check lines[1].strip.startsWith(gens.a[0 ..< 12])
      check "[active]" in lines[1]
    # The default target, the generation before the current one, is B.
    let toB = sb.rollback()
    check toB.exitCode == 0
    check readCurrentGenerationId(sb.stateDir) == gens.b
    check readFile(extendedPath(sb.homeDir / ".rb-x")) == "b\n"
    check readFile(extendedPath(sb.homeDir / ".rb-only-b")) == "only-b\n"
    # And to A again: A's state, B's resource removed.
    let toA = sb.rollback(gens.a)
    check toA.exitCode == 0
    sb.checkInA(gens)

  test "e2e_rollback_never_restores_a_resource_the_target_records_as_destroyed":
    # The restore form of reprobuild-pm issue 2026-10-18-home-rollback-
    # recreates-a-resource-the-target-generation-records-as-destroyed
    # (reprobuild-pm issue 2026-10-20-home-rollback-restores-the-bytes-of-a-
    # resource-the-target-generation-destroyed). C applies every concern
    # and records B's `rbOnlyB` as destroyed. N is C with the host narrowed
    # to `applies: [packages]` (Gradual-Nix-To-Reprobuild-Migration.md
    # §Concern-scoped apply), so N records nothing of the `files` concern.
    # Rolling back from N to C is then a RESTORE of C's destroy record: it
    # must leave `~/.rb-only-b` as C recorded it -- absent -- and never write
    # the bytes C destroyed; and a file the user put there since is not
    # Reprobuild's to touch.
    proc narrowed(profile: string): string =
      profile.replace("  resources:\n",
        "  hosts:\n    \"" & DefaultSandboxHost & "\":\n" &
        "      activities: [default]\n      applies: [packages]\n\n" &
        "  resources:\n")
    for userFile in [false, true]:
      checkpoint("user file at the path: " & $userFile)
      let sb = newProfileSandbox("rb-restore-destroyed", ProfileA)
      defer: sb.dispose()
      let gens = sb.twoGenerations()
      let c = sb.apply(ProfileC, "C")
      let onlyB = sb.homeDir / ".rb-only-b"
      check not fileExists(extendedPath(onlyB))
      let n = sb.apply(narrowed(ProfileC), "N (narrowed)")
      check n != c and n != gens.b
      if userFile:
        writeFile(extendedPath(onlyB), Mine)
      let r = sb.rollback(c)
      check r.exitCode == 0
      check readCurrentGenerationId(sb.stateDir) == c
      if userFile:
        check fileExists(extendedPath(onlyB))
        if fileExists(extendedPath(onlyB)):
          check readFile(extendedPath(onlyB)) == Mine
      else:
        check not fileExists(extendedPath(onlyB))
      check readFile(extendedPath(sb.homeDir / ".rb-x")) == "a\n"
      check readFile(extendedPath(sb.homeDir / ".rb-only-c")) == "only-c\n"
