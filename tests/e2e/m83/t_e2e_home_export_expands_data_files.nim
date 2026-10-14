## GM4: `repro home export` carries plan-time data EXPANDED, with the data
## files' digests in provenance.
##
## `e2e_home_export_expands_data_files`:
##
## * `intent.activities` holds every row as an ordinary activity element —
##   files in `data:` order, rows in file order, appended after the
##   activity's compiled body; a row with `when` becomes a `whenGuard`
##   element; a row naming an activity no block declares creates it — and
##   the intent carries NO `dataFiles` key, so a consumer can never expand
##   twice;
## * `[[resource]]` rows are in `intent.resources`, built by their
##   constructors (auto-address, default fields) with the row's `when` as
##   `guard`, and `--target` selects them by guard;
## * `provenance.dataFiles` lists each file (`path`, the BLAKE3 of the bytes
##   expanded, `rows`), and the compile's observed inputs do not include them;
## * the rows are platform-neutral data: every platform is `same`, and
##   `--target` evaluates their guards per target (macOS-only row present
##   for aarch64-darwin and absent for x86_64-linux, and the reverse);
## * `--check` treats a row edit as an intent change (exit 1, the package is
##   named) and a comment-only data edit as provenance (exit 0, a
##   `provenance.dataFiles` note).
##
## Falsifying mutation (performed when this gate was written, see the
## milestone file): `buildHomeExport` emitting the unexpanded intent — red:
## `dataFiles` present in the intent and no row elements in `desktop`.
##
## No mocks: real `build/bin/repro`, real Nim, real filesystem.
##
## Platforms: every host.

import std/[json, os, strutils, unittest]

import blake3

import ./profile_compile_edge_harness

const ProfileText = """
import repro_profile

profile "gm4DataExport":
  data:
    "data/apps.toml"
    "data/cli.toml"

  activity default:
    `gm4-base`

  activity desktop:
    `gm4-desktop-base`

  hosts:
    "gm4-host": [desktop, cli_tools]
"""

const Apps = """
[[package]]
name = "gm4-mac-app"
activity = "desktop"
when = "macos"

[[package]]
name = "gm4-linux-app"
activity = "desktop"
when = "linux"
"""

const Cli = """
[[package]]
name = "gm4-jq"
activity = "cli_tools"
version = "1.7.1"
binaries = ["jq"]

[[resource]]
kind = "fs.userFile"
when = "linux"
hostFile = "~/.config/gm4/linux.conf"
content = "linux = true\n"

[[resource]]
kind = "env.userVariable"
name = "GM4_EDITOR"
value = "nvim"
"""

proc elementNames(body: JsonNode): seq[string] =
  ## Package names in an activity body, guards flattened, in order.
  for e in body:
    if e["kind"].getStr == "packageRef":
      result.add e["name"].getStr
    else:
      for inner in e["body"]:
        result.add inner["name"].getStr

proc activity(intent: JsonNode; name: string): JsonNode =
  for a in intent["activities"]:
    if a["name"].getStr == name:
      return a
  nil

suite "GM4: export of plan-time data":

  test "e2e_home_export_expands_data_files":
    let sb = newProfileSandbox("gm4-data-export", ProfileText)
    defer: sb.dispose()
    sb.writeProfileFile("data/apps.toml", Apps)
    sb.writeProfileFile("data/cli.toml", Cli)

    proc exportDoc(args: openArray[string]): ReproRun =
      result = sb.runRepro(@["home", "export", "--format", "json"] & @args,
        host = "gm4-host")
      checkpoint("export " & args.join(" ") & " -> " & $result.exitCode &
        "\n" & result.stderr)

    let plain = exportDoc([])
    require plain.exitCode == 0
    let doc = parseJson(plain.stdout)
    let intent = doc["intent"]
    check not intent.hasKey("dataFiles")
    let desktop = intent.activity("desktop")
    require not desktop.isNil
    check elementNames(desktop["body"]) ==
      @["gm4-desktop-base", "gm4-mac-app", "gm4-linux-app"]
    check desktop["body"][1]["kind"].getStr == "whenGuard"
    check desktop["body"][1]["predicate"].getStr == "macos"
    let cli = intent.activity("cli_tools")
    require not cli.isNil
    check cli["body"][0]["name"].getStr == "gm4-jq"
    check cli["body"][0]["version"].getStr == "1.7.1"
    check cli["body"][0]["binaries"] == %["jq"]
    check doc["selection"]["activities"] ==
      %["default", "desktop", "cli_tools"]
    check doc["selection"]["unknownActivities"].len == 0

    # Resource rows: the constructors' resources, after the compiled ones
    # (there are none here), guard attached, in file order.
    let resources = intent["resources"]
    require resources.len == 2
    check resources[0]["kind"].getStr == "fs.userFile"
    check resources[0]["address"].getStr == "fs.userFile:~/.config/gm4/linux.conf"
    check resources[0]["guard"].getStr == "linux"
    check resources[0]["fields"]["mode"]["value"].getStr == "0644"
    check resources[1]["address"].getStr == "env.userVariable:GM4_EDITOR"
    check resources[1]["guard"].kind == JNull
    let files = doc["provenance"]["dataFiles"]
    require files.len == 2
    check files[0]["path"].getStr == "data/apps.toml"
    check files[0]["blake3"].getStr == blake3.toHex(blake3.digest(Apps))
    check files[0]["rows"].getInt == 2
    check files[1]["path"].getStr == "data/cli.toml"
    check files[1]["blake3"].getStr == blake3.toHex(blake3.digest(Cli))
    check files[1]["rows"].getInt == 3
    for input in doc["provenance"]["profile"]["inputs"]:
      check not input["path"].getStr.startsWith("data/")
    for system, status in doc["platforms"]:
      checkpoint(system)
      check status.getStr == "same"

    proc evaluated(target: string): seq[string] =
      ## Package names, then `@` + resource addresses, the target selects.
      let r = exportDoc(["--target", target])
      require r.exitCode == 0
      let evaluation = parseJson(r.stdout)["evaluation"]
      for p in evaluation["packages"]:
        result.add p["name"].getStr
      for res in evaluation["resources"]:
        result.add "@" & res["address"].getStr
    let mac = evaluated("aarch64-darwin")
    check "gm4-mac-app" in mac
    check "gm4-linux-app" notin mac
    check "gm4-jq" in mac
    check "@env.userVariable:GM4_EDITOR" in mac
    check "@fs.userFile:~/.config/gm4/linux.conf" notin mac
    let linux = evaluated("x86_64-linux")
    check "gm4-linux-app" in linux
    check "gm4-mac-app" notin linux
    check "@env.userVariable:GM4_EDITOR" in linux
    check "@fs.userFile:~/.config/gm4/linux.conf" in linux

    # --check: a row edit is stale, a comment-only edit is not.
    let snapshot = sb.root / "export.json"
    writeFile(snapshot, plain.stdout)
    sb.writeProfileFile("data/cli.toml", "# tools on every host\n" & Cli)
    let commentOnly = exportDoc(["--check", snapshot])
    check commentOnly.exitCode == 0
    check commentOnly.stderr.contains("provenance.dataFiles")
    sb.writeProfileFile("data/cli.toml", Cli &
      "\n[[package]]\nname = \"gm4-yq\"\nactivity = \"cli_tools\"\n")
    let stale = exportDoc(["--check", snapshot])
    check stale.exitCode == 1
    check stale.stderr.contains("gm4-yq")
