## Removing a managed block -- by `repro home apply` of a profile that no
## longer declares it, or by `repro home rollback` to a generation that never
## had it -- takes away the block and its two sentinel lines and nothing
## else. Every byte the user wrote around the block survives, including edits
## made after the block was first written; a host file is deleted only when
## nothing is left in it once the block is gone
## (Generated-Configuration-Files.md §"Deletion semantics" and §"Unmanaged
## content preservation"; reprobuild-pm issue 2026-11-12-managed-block-
## removal-and-rollback-discard-user-edits-the-spec-promises-to-keep).
##
## Profile `With` declares one `fs.managedBlock` in `~/.mb-pre` (a file the
## user already had) and one in `~/.mb-new` (a file Reprobuild creates);
## `Without` declares neither. Through the real `build/bin/repro`:
##
## * `e2e_block_removal_keeps_what_the_user_wrote_around_it`: after `With`
##   is applied the user rewrites a line they had before the first write and
##   adds lines to both files, including the one Reprobuild created. Applying
##   `Without`, rolling back to `With`, and rolling back to `Without` again
##   each leave the user's bytes exactly as the user left them: nothing
##   reverts `~/.mb-pre` to its state at first write, and nothing deletes
##   `~/.mb-new` while it still holds the user's lines.
## * `e2e_block_removal_deletes_a_host_file_it_leaves_empty`: with no user
##   edits, removing the last block from a file that held nothing else
##   deletes the file -- on apply and on rollback alike -- instead of
##   leaving a zero-byte file behind. Rolling back to `With` re-creates it.
##
## Before the fix both removal paths left `~/.mb-new` and `~/.mb-pre` behind
## as empty files in the second case.
##
## No mocks: the real `build/bin/repro`, the real profile compile edge, the
## real planner, drivers and rollback, in the harness's isolated sandbox (its
## own HOME, state and store). Platforms: every host.

import std/[os, unittest]
from repro_core/paths import extendedPath

import repro_home_generations

import ../m83/profile_compile_edge_harness

proc profileWith(resources: string): string =
  "import repro_profile\n\nprofile \"managedBlockRemoval\":\n" &
    "  activity default:\n    discard\n\n  resources:\n" & resources

const
  ProfileWith = profileWith("""    fsManagedBlock(hostFile = "~/.mb-pre", blockId = "pre", content = "export PRE=1", address = "preBlock")
    fsManagedBlock(hostFile = "~/.mb-new", blockId = "new", content = "export NEW=1", address = "newBlock")
    fsUserFile(hostFile = "~/.mb-marker", content = "with\n", address = "marker")
""")
  ProfileWithout = profileWith("""    fsUserFile(hostFile = "~/.mb-marker", content = "without\n", address = "marker")
""")
    ## The marker keeps `Without` a generation with a resource of its own;
    ## its content differs so the two generation ids differ too.
  PreBlock = "# >>> repro-managed:pre >>>\nexport PRE=1\n" &
    "# <<< repro-managed:pre <<<\n"
  NewBlock = "# >>> repro-managed:new >>>\nexport NEW=1\n" &
    "# <<< repro-managed:new <<<\n"

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

proc rollbackTo(sb: ProfileSandbox; id: string) =
  let r = sb.runRepro(["home", "rollback", id])
  show("rollback " & id, r)
  check r.exitCode == 0
  check readCurrentGenerationId(sb.stateDir) == id

proc contentOf(path: string): string =
  ## The file's bytes, or a marker naming its absence, so a `check` failure
  ## prints what the host actually holds.
  if fileExists(extendedPath(path)): readFile(extendedPath(path))
  else: "<absent>"

suite "managed-block removal keeps the user's content":

  test "e2e_block_removal_keeps_what_the_user_wrote_around_it":
    let sb = newProfileSandbox("mb-keep", ProfileWith)
    defer: sb.dispose()
    let pre = sb.homeDir / ".mb-pre"
    let created = sb.homeDir / ".mb-new"
    # The user's file before Reprobuild first writes into it.
    writeFile(extendedPath(pre), "alias a=1\n")
    let withId = sb.apply(ProfileWith, "With")
    check contentOf(pre) == "alias a=1\n" & PreBlock
    check contentOf(created) == NewBlock

    # Edits made after the first write: one to a line that predates it, and
    # new lines on both sides of the block -- also in the file Reprobuild
    # created.
    writeFile(extendedPath(pre), "alias a=2\n" & PreBlock & "alias b=1\n")
    writeFile(extendedPath(created), "# mine above\n" & NewBlock &
      "alias c=1\n")
    let userPre = "alias a=2\nalias b=1\n"
    let userNew = "# mine above\nalias c=1\n"

    # Apply removes the blocks only.
    let withoutId = sb.apply(ProfileWithout, "Without")
    check withoutId != withId
    check contentOf(pre) == userPre
    check contentOf(created) == userNew

    # Rollback restores the blocks around the user's current lines.
    sb.rollbackTo(withId)
    check contentOf(pre) == userPre & PreBlock
    check contentOf(created) == userNew & NewBlock

    # Rollback removes them again, still keeping the user's lines.
    sb.rollbackTo(withoutId)
    check contentOf(pre) == userPre
    check contentOf(created) == userNew

  test "e2e_block_removal_deletes_a_host_file_it_leaves_empty":
    let sb = newProfileSandbox("mb-empty", ProfileWith)
    defer: sb.dispose()
    let pre = sb.homeDir / ".mb-pre"
    let created = sb.homeDir / ".mb-new"
    # `~/.mb-pre` exists but holds nothing of the user's: once its block is
    # gone nothing is left to keep, as for the file Reprobuild created.
    writeFile(extendedPath(pre), "")
    let withId = sb.apply(ProfileWith, "With")
    check contentOf(pre) == PreBlock
    check contentOf(created) == NewBlock

    # Apply: the last block goes, and with it the file it leaves empty.
    let withoutId = sb.apply(ProfileWithout, "Without")
    check contentOf(pre) == "<absent>"
    check contentOf(created) == "<absent>"

    # Rollback re-creates both, then deletes them again.
    sb.rollbackTo(withId)
    check contentOf(pre) == PreBlock
    check contentOf(created) == NewBlock
    sb.rollbackTo(withoutId)
    check contentOf(pre) == "<absent>"
    check contentOf(created) == "<absent>"
