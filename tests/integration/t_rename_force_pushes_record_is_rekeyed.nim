## Declared-Repository-Renames.md §3.5 — `.repro/workspace/force-pushes.json`
## is RE-KEYED by a relocation, merging rather than replacing.
##
## This is not bookkeeping. The file is the recovery record for a rewritten
## remote — what the superseded revision was, and where the pre-rewrite state
## can be found — and the key is the CHECKOUT PATH, which is precisely why a
## path change strands it. The loader degrades silently to "no records", so
## nothing reports that it stopped being found.
##
## THE SHAPE IS THE RICHER ONE, deliberately. The file this workspace actually
## carries is a JSON ARRAY of records with `repo`, `branch`, `superseded`,
## `new`, `backup_ref` and `migrated_at`; the writer used to emit a flat
## `{path: [sha…]}` object. Re-keying the poorer one would discard the fields
## that make the richer one a recovery record, and `backup_ref` cannot be
## reconstructed once dropped — fields can be removed later, they cannot be
## recovered. So the array is read and written, and the flat form is MIGRATED.
##
## Asserted:
##   1. A record under the prior key is readable under the new one.
##   2. Every field survives, `backup_ref` and `migrated_at` included.
##   3. A record already present under the NEW key is kept — merged, not
##      replaced.
##   4. The re-key is FUNCTIONAL, not cosmetic: the relocated repo's
##      observation finds the recorded superseded commit, which it could only
##      do through the new key.
##   5. The poorer flat shape is migrated into the richer one rather than
##      discarded or re-keyed in place.

import std/[json, os, strutils, unittest]
import declared_rename_fixture

proc forcePushesFile(fx: RenameFixture): string =
  fx.workspaceRoot / ".repro" / "workspace" / "force-pushes.json"

proc readRecords(fx: RenameFixture): JsonNode =
  check fileExists(fx.forcePushesFile())
  parseFile(fx.forcePushesFile())

proc recordsFor(records: JsonNode; key: string): seq[JsonNode] =
  check records.kind == JArray
  for record in records:
    if record.kind == JObject and "repo" in record and
        record["repo"].getStr() == key:
      result.add(record)

suite "declared rename — force-pushes.json is re-keyed":

  test "t_rename_force_pushes_record_is_rekeyed":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = newRenameFixture(gitBin, "forcepush")
      defer: removeDir(fx.scratch)

      discard fx.seedOrigin(gitBin, "widget-pm")
      fx.writeFragment("widget-pm", "widget-pm", "widget-pm",
        previously = "[{ name = \"widget-specs\", path = \"widget-specs\" }]")
      fx.writeProject(["widget-pm"])

      let oldPath = fx.workspaceRoot / "widget-specs"
      fx.cloneInto(gitBin, "widget-pm", oldPath)
      discard requireGit(q(gitBin) & " -C " & q(oldPath) &
        " remote set-url origin " & q(fx.originUrl("widget-specs")))
      # A local commit standing in for work the operator carried across a
      # rewrite: it is on HEAD and on no remote, which is what makes it
      # matchable against a recorded superseded sha.
      writeFile(oldPath / "carried.txt", "work carried across the rewrite\n")
      discard requireGit(q(gitBin) & " -C " & q(oldPath) & " add carried.txt")
      discard requireGit(q(gitBin) & " -C " & q(oldPath) &
        " commit -m \"carried across\"")
      let carriedSha = requireGit(q(gitBin) & " -C " & q(oldPath) &
        " rev-parse HEAD").strip()

      # The recovery record, in the shape this workspace really carries, with
      # one entry under the PRIOR key and one already under the NEW key.
      createDir(fx.workspaceRoot / ".repro" / "workspace")
      writeFile(fx.forcePushesFile(), pretty(%*[
        {
          "repo": "widget-specs",
          "branch": "main",
          "superseded": carriedSha,
          "new": "0000000000000000000000000000000000000000",
          "backup_ref": "refs/pre-rewrite/2026-09-21T-migration",
          "migrated_at": "2026-09-21T-migration"
        },
        {
          "repo": "widget-pm",
          "branch": "release",
          "superseded": "1111111111111111111111111111111111111111",
          "new": "2222222222222222222222222222222222222222",
          "backup_ref": "refs/pre-rewrite/already-under-the-new-key",
          "migrated_at": "2026-09-30T-earlier"
        },
        {
          "repo": "unrelated-repo",
          "branch": "dev",
          "superseded": "3333333333333333333333333333333333333333",
          "new": "4444444444444444444444444444444444444444",
          "backup_ref": "refs/pre-rewrite/not-ours",
          "migrated_at": "2026-09-21T-migration"
        }
      ], indent = 2) & "\n")

      let res = fx.invokeSync()
      checkpoint("sync output:\n" & res.output)
      check fx.readReport().entryFor("widget-pm").field("relocation") ==
        "relocated"

      let records = fx.readRecords()
      checkpoint("records:\n" & pretty(records, indent = 2))

      # 1. The prior key is gone and the record is under the new one.
      check records.recordsFor("widget-specs").len == 0
      let moved = records.recordsFor("widget-pm")
      # 3. MERGED: the record already under the new key was kept.
      check moved.len == 2
      var carriedRecord = newJNull()
      var preexistingRecord = newJNull()
      for record in moved:
        if record["superseded"].getStr() == carriedSha:
          carriedRecord = record
        elif record["branch"].getStr() == "release":
          preexistingRecord = record
      check carriedRecord.kind == JObject
      check preexistingRecord.kind == JObject

      # 2. Every field survived the re-key.
      check carriedRecord["branch"].getStr() == "main"
      check carriedRecord["backup_ref"].getStr() ==
        "refs/pre-rewrite/2026-09-21T-migration"
      check carriedRecord["migrated_at"].getStr() == "2026-09-21T-migration"
      check carriedRecord["new"].getStr() ==
        "0000000000000000000000000000000000000000"
      check preexistingRecord["backup_ref"].getStr() ==
        "refs/pre-rewrite/already-under-the-new-key"

      # Another repo's record was not touched.
      check records.recordsFor("unrelated-repo").len == 1

      # 4. The re-key is FUNCTIONAL, not cosmetic. The observation for the
      #    relocated repo found the recorded superseded commit on HEAD, which
      #    it can only do by looking the record up under the NEW key.
      #
      #    `force_push_rebase` is reached by exactly two routes:
      #    `hasForcePushedCommits` (a RECORDED superseded sha found on HEAD)
      #    and `remoteHistoryDisjoint` (no merge-base with the remote trunk).
      #    The second is excluded by construction here — HEAD descends from
      #    `origin/main`, asserted below — so the verdict is attributable to
      #    the re-keyed record and to nothing else. Without the re-key this
      #    checkout classifies `locally_unpublished` instead.
      let newPath = fx.workspaceRoot / "widget-pm"
      check run(q(gitBin) & " -C " & q(newPath) &
        " merge-base --is-ancestor origin/main HEAD").code == 0
      let entry = fx.readReport().entryFor("widget-pm")
      check entry.field("syncCase") == "force_push_rebase"
      check entry.field("syncCase") != "locally_unpublished"

  test "t_rename_force_pushes_flat_shape_is_migrated_not_discarded":
    ## §3.5's settled schema question. The poorer `{path: [sha…]}` form is the
    ## one the writer used to emit; it is migrated into the richer shape with
    ## the two facts it held preserved and the unknown fields left EMPTY rather
    ## than invented.
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = newRenameFixture(gitBin, "flatshape")
      defer: removeDir(fx.scratch)

      discard fx.seedOrigin(gitBin, "widget-pm")
      fx.writeFragment("widget-pm", "widget-pm", "widget-pm",
        previously = "[{ name = \"widget-specs\", path = \"widget-specs\" }]")
      fx.writeProject(["widget-pm"])

      let oldPath = fx.workspaceRoot / "widget-specs"
      fx.cloneInto(gitBin, "widget-pm", oldPath)
      discard requireGit(q(gitBin) & " -C " & q(oldPath) &
        " remote set-url origin " & q(fx.originUrl("widget-specs")))

      createDir(fx.workspaceRoot / ".repro" / "workspace")
      writeFile(fx.forcePushesFile(), pretty(%*{
        "widget-specs": ["5555555555555555555555555555555555555555"],
        "someone-else": ["6666666666666666666666666666666666666666"]
      }, indent = 2) & "\n")

      let res = fx.invokeSync()
      checkpoint("sync output:\n" & res.output)
      check fx.readReport().entryFor("widget-pm").field("relocation") ==
        "relocated"

      let records = fx.readRecords()
      checkpoint("records:\n" & pretty(records, indent = 2))
      check records.kind == JArray
      let moved = records.recordsFor("widget-pm")
      check moved.len == 1
      check moved[0]["superseded"].getStr() ==
        "5555555555555555555555555555555555555555"
      # Unknown fields are EMPTY, not invented: the poorer shape never knew
      # them and a fabricated `backup_ref` would be worse than none.
      check moved[0]["backup_ref"].getStr() == ""
      check moved[0]["branch"].getStr() == ""
      # The other key survived the migration untouched.
      let other = records.recordsFor("someone-else")
      check other.len == 1
      check other[0]["superseded"].getStr() ==
        "6666666666666666666666666666666666666666"
