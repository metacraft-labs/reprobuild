## A stow file and an `fs.userFile` resource that name one `$HOME` path
## (reprobuild-pm spec Home-Profile-Intent-Layer.md §Stow-Style Dotfile
## Support, "A stow file and an `fs.userFile` on one path";
## Gradual-Nix-To-Reprobuild-Migration.md §Host facts; issue
## 2026-10-17-home-facts-refuses-a-stow-file-and-a-resource-that-agree).
##
## The fixture mirrors the case zah/dotfiles hit. The stow package `c1` holds
## `.config/c1/caches.conf` and a second file, `.c1-control`; a second stow
## package, `c2`, holds an unrelated `.c2-unrelated`. The profile's
## `fsUserFile` for `~/.config/c1/caches.conf` either reads the stow file's
## bytes (`staticRead`) or carries other bytes or another mode.
##
## `e2e_agreeing_stow_and_resource_accepted`, through the real
## `build/bin/repro`:
##
## * `repro home facts` succeeds and lists the path once, from the resource,
##   with the digest computed independently (`sha256sum` of the literal
##   bytes). Two `envUserPath` resources sharing an entry list that entry
##   once on Windows, where the driver merges them; on POSIX they write one
##   rc block and facts refuses them as the apply does (issue
##   2026-10-18-home-apply-applies-two-resources-for-one-path-or-variable).
## * `repro home apply` succeeds and reports `IStowSameAsResource`. The path
##   is a regular file written by the resource, while the package's other
##   file is linked as usual (negative control). The stow source is
##   byte-identical afterwards (sha256 before and after), and a second apply
##   is a verified no-op.
## * Transition (`e2e_agreeing_resource_added_to_and_removed_from_a_linked_home`):
##   a home first applied without the resource holds the stow link. Adding
##   the agreeing resource replaces the link with the resource's file and
##   leaves the source untouched. Removing the resource again brings the
##   link back. The binding is released rather than destroyed, so the new
##   link is not deleted. A later edit to the stow source then reaches the
##   home, so the stow file owns the path again. After each step one more
##   apply is a no-op that reports no drift (steady state in both owners).
## * `e2e_removed_resource_keeps_a_file_the_user_edited`: the handover
##   removes the resource's file only while it still holds what the resource
##   wrote. A file the user edited is left, the stow step refuses it as it
##   refuses any pre-existing target, and the user's bytes survive.
##
## `e2e_conflicting_stow_and_resource_refused`: other bytes, another mode
## (POSIX only: Windows applies no mode, so there the same bytes under
## another mode are checked to agree instead), and content from a command
## (bytes unknown before apply) are each refused
## by `repro home facts`, `repro home apply --plan` and `repro home apply`.
## The refusal names the path, both sources and the differing field. HOME is
## unchanged by the apply (tree fingerprint): neither `c1`'s other file nor
## the unrelated package `c2` is linked, no generation is recorded, and the
## stow source keeps its sha256.
##
## Falsifying mutation, run by the test on every run: the conflicting
## profile with the resource removed applies cleanly and links the stow
## file. So the refusal comes from the pair, not from anything else in the
## fixture. Code mutations made when this gate was written are recorded in
## the GM11 milestone entry.
##
## No mocks: the real `build/bin/repro`, profile compile edge, planner, stow
## materializer and `fs.userFile` driver, all in the harness's isolated
## sandbox (its own HOME, state and store). Platforms: every host. On Windows
## a stow file may be materialized as a copy, so the link-specific checks
## are POSIX-only and every host checks the bytes.

import std/[json, os, strutils, unittest]
from repro_core/paths import extendedPath

import nimcrypto/sha2

import repro_home_generations
from repro_home_apply/host_facts import differingComparedFields

import ../m83/profile_compile_edge_harness

const
  CachesRel = ".config/c1/caches.conf"
  CachesId = "~/" & CachesRel
  CachesStowPath = "stow/c1/" & CachesRel
  CachesBytes = "trusted-public-keys = c1-a:AAAA c1-b:BBBB\n"
  # `printf 'trusted-public-keys = c1-a:AAAA c1-b:BBBB\n' | sha256sum`
  # (coreutils, 2026-10-18).
  CachesDigest =
    "sha256:d3434e01488eb031114b3b00df586a1e94eaaef5db29a561c959d43be36ea885"
  # The resource's bytes in the conflicting profile:
  # `printf 'trusted-public-keys = c1-a:AAAA\n' | sha256sum`.
  OtherDigest =
    "sha256:f3d0fb86f30778908a2156892d9fd4b172b6cd9df6f75195ef90881d71042903"
  ControlRel = ".c1-control"
  ControlBytes = "control = 1\n"
  # A second, unrelated stow package: refused applies must not link it either
  # (the refusal is atomic across packages, not only within `c1`).
  UnrelatedRel = ".c2-unrelated"
  UnrelatedBytes = "unrelated = 1\n"

proc profileWith(resource: string; sharedPath = false): string =
  ## The fixture profile; `resource` is the `fsUserFile` line(s) for
  ## `~/.config/c1/caches.conf` ("" for none). `sharedPath` adds two
  ## `envUserPath` resources sharing an entry (a facts-only fixture: a
  ## POSIX plan refuses that pair, issue
  ## 2026-10-18-home-apply-applies-two-resources-for-one-path-or-variable).
  # The stow file's bytes, read at profile compile time the way
  # zah/dotfiles' Windows `caches.conf` resource reads its stow file.
  result = "import repro_profile\n\nconst c1CachesConf = staticRead(\"" &
    CachesStowPath & "\")\n"
  result.add """

profile "c1OnePath":
  activity default:
    discard

  resources:
    fsUserFile(hostFile = "~/.c1-resource", content = "r\n",
      address = "c1Other")
"""
  if sharedPath:
    result.add "    envUserPath(entries = \"~/.c1/bin, /opt/c1a\", " &
      "address = \"c1PathA\")\n"
    result.add "    envUserPath(entries = \"~/.c1/bin, /opt/c1b\", " &
      "address = \"c1PathB\")\n"
  if resource.len > 0:
    result.add "    " & resource & "\n"

const
  AgreeingResource = "fsUserFile(hostFile = \"~/" & CachesRel &
    "\", content = c1CachesConf, address = \"c1Caches\")"
  OtherBytesResource = "fsUserFile(hostFile = \"~/" & CachesRel &
    "\", content = \"trusted-public-keys = c1-a:AAAA\\n\", " &
    "address = \"c1Caches\")"
  OtherModeResource = "fsUserFile(hostFile = \"~/" & CachesRel &
    "\", content = c1CachesConf, mode = \"0600\", address = \"c1Caches\")"
  CommandResource = "fsUserFile(hostFile = \"~/" & CachesRel &
    "\", contentFromCommand = @[\"cat\", \"/dev/null\"], " &
    "address = \"c1Caches\")"

proc show(label: string; r: ReproRun) =
  checkpoint(label & " -> exit " & $r.exitCode & "\n--- stdout\n" &
    r.stdout & "\n--- stderr\n" & r.stderr)

proc fileSha256(path: string): string =
  $sha256.digest(readFile(extendedPath(path)))

proc newFixture(label, resource: string; sharedPath = false):
    ProfileSandbox =
  result = newProfileSandbox(label, profileWith(resource, sharedPath))
  result.writeProfileFile(CachesStowPath, CachesBytes)
  result.writeProfileFile("stow/c1/" & ControlRel, ControlBytes)
  result.writeProfileFile("stow/c2/" & UnrelatedRel, UnrelatedBytes)

proc entriesFor(doc: JsonNode; category, id: string): seq[JsonNode] =
  for e in doc["categories"][category]:
    if e["id"].getStr == id:
      result.add e

proc checkLinkedOrCopied(sb: ProfileSandbox; rel, bytes: string) =
  let path = sb.homeDir / rel
  check fileExists(extendedPath(path))
  if fileExists(extendedPath(path)):
    check readFile(extendedPath(path)) == bytes
  when not defined(windows):
    check symlinkExists(path)

proc checkNoOp(sb: ProfileSandbox; label: string) =
  ## One more apply changes nothing and reports no drift against what the
  ## previous apply wrote (steady state).
  let r = sb.runRepro(["home", "apply"])
  show(label, r)
  require r.exitCode == 0
  check r.stdout.contains("no-op")
  check not (r.stdout & r.stderr).contains("drift")

proc checkResourceFile(sb: ProfileSandbox; rel, bytes: string) =
  let path = sb.homeDir / rel
  check fileExists(extendedPath(path))
  check not symlinkExists(path)
  if fileExists(extendedPath(path)):
    check readFile(extendedPath(path)) == bytes

suite "A stow file and an fs.userFile resource on one path":

  test "e2e_agreeing_stow_and_resource_accepted":
    let sb = newFixture("c1-agree", AgreeingResource)
    defer: sb.dispose()
    let sourcePath = sb.profileDir / CachesStowPath
    let sourceSha = fileSha256(sourcePath)

    # --- facts: one entry per id ------------------------------------------
    let facts = sb.runRepro(["home", "facts"])
    show("facts", facts)
    require facts.exitCode == 0
    let doc = parseJson(facts.stdout)
    let caches = doc.entriesFor("files", CachesId)
    check caches.len == 1
    if caches.len == 1:
      check caches[0]["origin"].getStr == "resource c1Caches"
      check caches[0]["mode"].getStr == "0644"
      check caches[0]["digest"].getStr == CachesDigest
    # Negative control: the package's other file is still a stow fact.
    let control = doc.entriesFor("files", "~/" & ControlRel)
    check control.len == 1
    if control.len == 1:
      check control[0]["origin"].getStr == "stow stow/c1/" & ControlRel
      # A non-executable stow source is `0644` on every host. On Windows,
      # where Nim reports every file as executable, this read `0755`
      # (issue 2026-10-23-windows-stow-file-reads-as-0755-...).
      check control[0]["mode"].getStr == "0644"
    # Two profile PATH resources write the rc file's one PATH block, so
    # facts refuses them exactly as the apply does (issue
    # 2026-10-18-home-apply-applies-two-resources-for-one-path-or-variable;
    # t_e2e_two_resources_on_one_target). On Windows the driver merges each
    # resource's entries into the user PATH value instead, so there the pair
    # is one fact per entry, listed once from the first origin.
    block:
      let pathSb = newFixture("c1-agree-path", AgreeingResource,
        sharedPath = true)
      defer: pathSb.dispose()
      let pathFacts = pathSb.runRepro(["home", "facts"])
      show("facts with a shared PATH entry", pathFacts)
      when defined(windows):
        require pathFacts.exitCode == 0
        let pathDoc = parseJson(pathFacts.stdout)
        let shared = pathDoc.entriesFor("environment", "path:~/.c1/bin")
        check shared.len == 1
        if shared.len == 1:
          check shared[0]["origin"].getStr == "resource c1PathA"
        check pathDoc.entriesFor("environment", "path:/opt/c1a").len == 1
        check pathDoc.entriesFor("environment", "path:/opt/c1b").len == 1
      else:
        check pathFacts.exitCode != 0
        check "and `c1PathB` both write `the PATH block of " in
          pathFacts.stderr
        # The fixture above no longer reaches the facts builder on POSIX, so
        # the rule it exercised there -- two entries for one id that differ
        # only in their informational `origin` are one fact -- is checked
        # here against the builder's own comparison, which every host's
        # facts document goes through.
        let fromA = %*{"id": "path:~/.c1/bin", "origin": "resource c1PathA"}
        let fromB = %*{"id": "path:~/.c1/bin", "origin": "resource c1PathB"}
        check differingComparedFields(fromA, fromB).len == 0
        var withMode = fromB.copy()
        withMode["mode"] = %"0600"
        check differingComparedFields(fromA, withMode) == @["mode"]

    # --- apply: the resource is the one writer ----------------------------
    let applied = sb.runRepro(["home", "apply"])
    show("apply", applied)
    require applied.exitCode == 0
    check applied.stderr.contains("IStowSameAsResource: stow stow/c1/" &
      CachesRel & " is not linked at `" & CachesId &
      "`: resource c1Caches writes the same file")
    sb.checkResourceFile(CachesRel, CachesBytes)
    sb.checkLinkedOrCopied(UnrelatedRel, UnrelatedBytes)
    sb.checkLinkedOrCopied(ControlRel, ControlBytes)
    check fileSha256(sourcePath) == sourceSha
    check readFile(extendedPath(sourcePath)) == CachesBytes

    let again = sb.runRepro(["home", "apply"])
    show("apply again", again)
    require again.exitCode == 0
    check again.stdout.contains("no-op")
    sb.checkResourceFile(CachesRel, CachesBytes)
    check fileSha256(sourcePath) == sourceSha

  test "e2e_agreeing_resource_added_to_and_removed_from_a_linked_home":
    let sb = newFixture("c1-transition", "")
    defer: sb.dispose()
    let sourcePath = sb.profileDir / CachesStowPath
    let sourceSha = fileSha256(sourcePath)

    let first = sb.runRepro(["home", "apply"])
    show("apply without the resource", first)
    require first.exitCode == 0
    sb.checkLinkedOrCopied(CachesRel, CachesBytes)

    writeFile(extendedPath(sb.profilePath), profileWith(AgreeingResource))
    let second = sb.runRepro(["home", "apply"])
    show("apply with the agreeing resource", second)
    require second.exitCode == 0
    sb.checkResourceFile(CachesRel, CachesBytes)
    sb.checkLinkedOrCopied(ControlRel, ControlBytes)
    check fileSha256(sourcePath) == sourceSha
    # Steady state: the resource does not report drift against its own
    # write, and the stow step does not take the path back.
    sb.checkNoOp("apply again with the agreeing resource")
    sb.checkResourceFile(CachesRel, CachesBytes)

    # The resource removed: the unedited file it wrote is removed and the
    # stow file linked again; its binding is released, not destroyed (a
    # destroy would delete the new link).
    writeFile(extendedPath(sb.profilePath), profileWith(""))
    let third = sb.runRepro(["home", "apply"])
    show("apply with the resource removed", third)
    require third.exitCode == 0
    sb.checkLinkedOrCopied(CachesRel, CachesBytes)
    check fileSha256(sourcePath) == sourceSha
    sb.checkNoOp("apply again with the resource removed")
    sb.checkLinkedOrCopied(CachesRel, CachesBytes)
    # The stow file owns the path again: a change to its source reaches it.
    let cachesPath = sb.homeDir / CachesRel
    const Edited = "trusted-public-keys = c1-a:AAAA c1-b:BBBB c1-c:CCCC\n"
    sb.writeProfileFile(CachesStowPath, Edited)
    let fourth = sb.runRepro(["home", "apply"])
    show("apply after editing the stow source", fourth)
    require fourth.exitCode == 0
    check fileExists(extendedPath(cachesPath))
    if fileExists(extendedPath(cachesPath)):
      check readFile(extendedPath(cachesPath)) == Edited
    sb.checkNoOp("apply again after editing the stow source")

  test "e2e_removed_resource_keeps_a_file_the_user_edited":
    # The handover removes the resource's file only while it holds what the
    # resource wrote. Here the user edited it: the apply leaves it (the stow
    # step then refuses the pre-existing target, as for any other file) and
    # the user's bytes survive.
    let sb = newFixture("c1-edited", AgreeingResource)
    defer: sb.dispose()
    let sourcePath = sb.profileDir / CachesStowPath
    let sourceSha = fileSha256(sourcePath)
    let first = sb.runRepro(["home", "apply"])
    show("apply with the agreeing resource", first)
    require first.exitCode == 0
    sb.checkResourceFile(CachesRel, CachesBytes)
    const UserBytes = "edited by the user\n"
    writeFile(extendedPath(sb.homeDir / CachesRel), UserBytes)
    writeFile(extendedPath(sb.profilePath), profileWith(""))
    let second = sb.runRepro(["home", "apply"])
    show("apply with the resource removed", second)
    check second.exitCode != 0
    check (second.stdout & second.stderr).contains(
      "refused to clobber pre-existing target")
    sb.checkResourceFile(CachesRel, UserBytes)
    check fileSha256(sourcePath) == sourceSha

  test "e2e_conflicting_stow_and_resource_refused":
    var conflicts = @[
        ("bytes", OtherBytesResource,
         "digest (" & CachesDigest & " vs " & OtherDigest & ")"),
        ("command", CommandResource,
         "digest (" & CachesDigest &
         " vs unknown until apply (content from a command))")]
    # A mode is a difference only where it is applied. Windows files carry
    # no permission bits and the `fs.userFile` driver does not apply `mode`
    # there, so on Windows the same bytes under another mode agree; that
    # case is checked after this loop.
    when not defined(windows):
      conflicts.add ("mode", OtherModeResource, "mode (0644 vs 0600)")
    for (label, resource, field) in conflicts:
      checkpoint("conflict: " & label)
      let sb = newFixture("c1-conflict-" & label, resource)
      defer: sb.dispose()
      let sourcePath = sb.profileDir / CachesStowPath
      let sourceSha = fileSha256(sourcePath)
      let homeBefore = treeFingerprint(sb.homeDir)
      let needle = "`" & CachesId & "` is written by stow " & CachesStowPath &
        " and by resource c1Caches, which disagree on " & field

      let facts = sb.runRepro(["home", "facts"])
      show(label & ": facts", facts)
      check facts.exitCode == 1
      check facts.stderr.contains(needle)

      let plan = sb.runRepro(["home", "apply", "--plan"])
      show(label & ": apply --plan", plan)
      check plan.exitCode != 0
      check (plan.stdout & plan.stderr).contains(needle)

      let applied = sb.runRepro(["home", "apply"])
      show(label & ": apply", applied)
      check applied.exitCode != 0
      check (applied.stdout & applied.stderr).contains(needle)
      # Refused before anything was written.
      check treeFingerprint(sb.homeDir) == homeBefore
      check not fileExists(extendedPath(sb.homeDir / CachesRel))
      check not fileExists(extendedPath(sb.homeDir / ControlRel))
      check not fileExists(extendedPath(sb.homeDir / UnrelatedRel))
      check readCurrentGenerationId(sb.stateDir).len == 0
      check fileSha256(sourcePath) == sourceSha

    when defined(windows):
      # The same bytes under another mode: one writer, the resource.
      block:
        let modeSb = newFixture("c1-mode-agrees", OtherModeResource)
        defer: modeSb.dispose()
        let facts = modeSb.runRepro(["home", "facts"])
        show("mode only: facts", facts)
        require facts.exitCode == 0
        let caches = parseJson(facts.stdout).entriesFor("files", CachesId)
        check caches.len == 1
        if caches.len == 1:
          check caches[0]["origin"].getStr == "resource c1Caches"
        let applied = modeSb.runRepro(["home", "apply"])
        show("mode only: apply", applied)
        require applied.exitCode == 0
        check applied.stderr.contains("IStowSameAsResource: stow stow/c1/" &
          CachesRel & " is not linked at `" & CachesId &
          "`: resource c1Caches writes the same file (same digest)")
        modeSb.checkResourceFile(CachesRel, CachesBytes)

    # Falsifying mutation: the same fixture without the resource applies and
    # links the stow file, so the pair is what was refused.
    let sb = newFixture("c1-conflict-mutation", "")
    defer: sb.dispose()
    let applied = sb.runRepro(["home", "apply"])
    show("mutation: apply without the resource", applied)
    require applied.exitCode == 0
    sb.checkLinkedOrCopied(CachesRel, CachesBytes)
    check readCurrentGenerationId(sb.stateDir).len > 0
