## NPC-M9 verification `test_npc_m9_override_file_v2_replaces`
## (Workspace-Manifests.md §"Develop-Mode Override File", schema v2;
## Workspace-And-Develop-Mode.md §"Source Override Semantics").
##
## A project locks `nimble:results`. Then:
##
## 1. `repro nimble develop results --source=<fork>` records the override
##    with `replaces`, the lock row it replaces (`<origin>#<commit>
##    blake3:<tree>`), in a file labelled schema v2, and says that a `repro`
##    reading only v1 of the file refuses it.
## 2. A file whose entries carry no `replaces` is written as v1, byte for
##    byte what the writer wrote before schema v2 existed.
## 3. A v1 file and the v2 file read back to the same entries, `replaces`
##    aside; the writer keeps a v2 file v2 and a v1 file v1.
## 4. A file labelled with another schema (`v3`) is refused, naming the
##    file, the schema found and the schemas read; so is a v1-labelled file
##    that carries `replaces`, a key of v2.
##
## Falsifying mutation (recorded in the plan): writing `replaces` into a
## file labelled v1 leaves the schema check of step 1 unmet.
##
## The verbs run in process against a real index repository and shared
## clone; nothing is fetched or built.

import std/[options, os, osproc, sequtils, strutils, unittest]

import ./nimble_m6_fixtures
import repro_workspace_manifests
import repro_cli_support/nimble_develop

const PreV2Text = """schema = "reprobuild.workspace.develop-overrides.v1"

[[override]]
package = "cairo"
local_path = "../cairo"
state = "editable"
created_at = "2026-06-02T10:14:33Z"
provenance = "repro develop cairo"
"""
  ## A file as the writer wrote it before schema v2 (reprobuild
  ## `ed186bfec`'s serializer, the same keys in the same order).

proc git(args: openArray[string]) =
  let r = execCmdEx("git " & args.mapIt(quoteShell(it)).join(" "))
  doAssert r.exitCode == 0, args.join(" ") & ": " & r.output

proc refusal(path: string): string =
  try:
    discard readDevelopOverrides(path)
    ""
  except WorkspaceManifestParseError as e:
    e.msg

suite "NPC-M9: the develop override file's replaces key is schema v2":
  test "replaces is written as v2; v1 stays byte-identical; others refused":
    var w = newWorld("m9-v2")
    let gen = w.publish(@[package("results", @[record("results", "1.0.0")])],
      daysAgo(1), "generation 1")
    discard gen
    let dir = w.newProject(@[("results", "")])
    let refreshed = refreshProvisioning(dir)
    checkpoint refreshed.output
    check refreshed.rc == 0
    let row = nimbleRows(dir)["nimble:results"]

    # 1. A fork recorded with --source: v2, with the row it replaces.
    let fork = parentDir(dir) / "results-fork"
    createDir(fork / "src")
    git(["init", "-q", "-b", "main", fork])
    git(["-C", fork, "remote", "add", "origin",
      "https://example.invalid/someone/results-fork"])
    writeFile(fork / "results.nimble", "version = \"1.0.0\"\nsrcDir = \"src\"\n")
    writeFile(fork / "src" / "results.nim", "proc stamp*(): string = \"FORK\"\n")
    let recorded = captured(proc (): int =
      runNimbleDevelopCommand("results", fork, dir / "repro.lock", "", false))
    checkpoint recorded.output
    check recorded.rc == 0
    let file = dir / ".repro" / "develop-overrides.toml"
    let text = readFile(file)
    checkpoint text
    check text.startsWith("schema = \"reprobuild.workspace.develop-overrides.v2\"\n")
    let replaces = row.coordinates.url & "#" & row.coordinates.revision &
      " " & row.integrity
    check ("replaces = \"" & replaces & "\"") in text
    check "is now schema reprobuild.workspace.develop-overrides.v2" in
      recorded.output
    check "refuses it" in recorded.output
    let v2 = readDevelopOverrides(file)
    check v2.schema == schemaDevelopOverridesV2
    check v2.`override`.len == 1
    check v2.`override`[0].replaces == some(replaces)

    # 2. No `replaces`: v1, byte-identical to the pre-v2 writer's bytes.
    let plainRoot = parentDir(dir) / "plain"
    createDir(plainRoot)
    let entry = DevelopOverrideEntry(package: "cairo", local_path: "../cairo",
      state: "editable", created_at: "2026-06-02T10:14:33Z",
      provenance: some("repro develop cairo"))
    writeDevelopOverridesFile(plainRoot,
      addOverride(newDevelopOverrides(), entry))
    let plainFile = developOverridesPath(plainRoot)
    check readFile(plainFile) == PreV2Text

    # 3. v1 and v2 read back equal, `replaces` aside; each stays its schema.
    let v1 = readDevelopOverrides(plainFile)
    check v1.schema == schemaDevelopOverridesV1
    var withReplaces = entry
    withReplaces.replaces = some("https://example.invalid/nim/cairo#" &
      "0123456789abcdef0123456789abcdef01234567 blake3:" & repeat('0', 64))
    let bothRoot = parentDir(dir) / "both"
    createDir(bothRoot)
    writeDevelopOverridesFile(bothRoot,
      addOverride(newDevelopOverrides(), withReplaces))
    let both = readDevelopOverrides(developOverridesPath(bothRoot))
    check both.schema == schemaDevelopOverridesV2
    var stripped = both.`override`[0]
    stripped.replaces = none(string)
    check stripped == v1.`override`[0]
    # A v1 file gaining an entry with `replaces` becomes v2; dropping that
    # entry makes it v1 again, with its old bytes.
    let grown = addOverride(v1, DevelopOverrideEntry(package: "nimble:x",
      local_path: "../x", state: "editable",
      created_at: "2026-11-24T00:00:00Z", replaces: some("o#c blake3:t")))
    check developOverridesSchemaFor(grown) == schemaDevelopOverridesV2
    writeDevelopOverridesFile(plainRoot, removeOverride(grown, "nimble:x"))
    check readFile(plainFile) == PreV2Text

    # 4. Another schema id is refused, naming the file, the schema found
    # and the schemas this reader reads.
    let v3Root = parentDir(dir) / "v3"
    createDir(v3Root / ".repro")
    let v3File = developOverridesPath(v3Root)
    writeFile(v3File, PreV2Text.replace("develop-overrides.v1",
      "develop-overrides.v3"))
    let v3Why = refusal(v3File)
    checkpoint v3Why
    check v3File in v3Why
    check "reprobuild.workspace.develop-overrides.v3" in v3Why
    check "reprobuild.workspace.develop-overrides.v2" in v3Why
    check "reprobuild.workspace.develop-overrides.v1" in v3Why
    # A v1-labelled file that carries `replaces` is refused as well.
    let mislabelled = parentDir(dir) / "mislabelled"
    createDir(mislabelled / ".repro")
    let mFile = developOverridesPath(mislabelled)
    writeFile(mFile, PreV2Text & "replaces = \"o#c blake3:t\"\n")
    let mWhy = refusal(mFile)
    checkpoint mWhy
    check mFile in mWhy
    check "replaces" in mWhy
    check "reprobuild.workspace.develop-overrides.v2" in mWhy
