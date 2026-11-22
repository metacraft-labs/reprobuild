## NPC-M7 verification `test_npc_m7_mirrors_config_order_and_refusals`
## (operator ruling M5-P4, NPC-AREQ13, CLI/nimble.md § Configuration).
##
## `[nimble] mirrors` set in the user's Reprobuild configuration, the
## system's, and the shared `repro-workspace.toml` yields ONE list: the
## user's entries, then the system's, then the workspace's, a location that
## appears twice kept at its first place. A malformed entry is refused
## naming the file and the entry; the key in `repro-workspace.local.toml`
## is refused naming the file. The workspace's strict settings reader
## accepts the table (and the local file's refuses it), so declaring it
## breaks no other command.
##
## Every file is under a private root: the user's and the system's paths
## are handed to the reader (``MirrorConfigPaths``) or named through
## `REPROBUILD_USER_CONFIG` / `REPROBUILD_SYSTEM_CONFIG`; the real `/etc`
## and `~/.config` are neither read nor written.
##
## Falsifying mutation (recorded in the plan): reading the workspace file
## before the user file changes the list's order and fails the test.

import std/[os, strutils, tempfiles, unittest]

import repro_cli_support
import repro_workspace_manifests

proc write(path, text: string) =
  createDir(parentDir(path))
  writeFile(path, text)

proc mirrorsToml(entries: seq[string]): string =
  var q: seq[string]
  for e in entries: q.add "\"" & e & "\""
  "schema = \"reprobuild.config.v1\"\n\n[nimble]\nmirrors = [" &
    q.join(", ") & "]\n"

const WorkspaceHead = "schema = \"reprobuild.workspace.settings.v1\"\n"

proc refusalOf(paths: MirrorConfigPaths): string =
  try:
    discard configuredNimbleMirrors(paths)
  except NimbleMirrorConfigError as e:
    return e.msg
  ""

suite "NPC-M7: the configured Nimble mirrors":
  let root = createTempDir("npc-m7-mirrors-", "")
  let user = root / "user" / "reprobuild" / "config.toml"
  let system = root / "etc" / "repro" / "config.toml"
  let ws = root / "ws"
  let settings = ws / "repro-workspace.toml"
  let local = ws / "repro-workspace.local.toml"
  createDir(ws / "project")

  test "user, then system, then workspace; a repeat keeps its first place":
    write(user, mirrorsToml(@["https://host.example/m", "/srv/host-mirror"]))
    write(system, mirrorsToml(@["https://it.example/nimble/",
      "https://host.example/m/"]))
    write(settings, WorkspaceHead & "\n[nimble]\nmirrors = [" &
      "\"https://org.example/nimble\", \"/srv/host-mirror\"]\n")
    let got = configuredNimbleMirrors(MirrorConfigPaths(user: user,
      system: system, workspace: settings))
    var locations, sources: seq[string]
    for m in got:
      locations.add m.location
      sources.add m.source
    check locations == @["https://host.example/m", "/srv/host-mirror",
      "https://it.example/nimble/", "https://org.example/nimble"]
    check sources == @[user, user, system, settings]
    # As the fetch takes them: in that order, ahead of anything else.
    var fetchOrder: seq[string]
    for m in fetchMirrorsOf(got): fetchOrder.add m.location
    check fetchOrder[0] == "https://host.example/m/"
    check fetchOrder[^1] == "https://org.example/nimble/"

  test "the host's files are found where the reader looks for them":
    # The environment names the user's and the system's file, and the
    # workspace is the one owning the project: the same three files.
    let env = proc (name: string): string =
      case name
      of "REPROBUILD_USER_CONFIG": user
      of "REPROBUILD_SYSTEM_CONFIG": system
      else: ""
    let p = mirrorConfigPathsFor(ws / "project", env)
    check p.user == user
    check p.system == system
    check p.workspace == settings
    check p.workspaceLocal == ""
    # Without the override the system file is the documented one, and the
    # user file follows XDG_CONFIG_HOME, then HOME.
    let xdg = proc (name: string): string =
      case name
      of "XDG_CONFIG_HOME": root / "xdg"
      of "HOME": root / "home"
      else: ""
    let q = mirrorConfigPathsFor(ws / "project", xdg)
    check q.user == root / "xdg" / "reprobuild" / "config.toml"
    check q.system == "/etc/repro/config.toml"
    let home = proc (name: string): string =
      if name == "HOME": root / "home" else: ""
    check mirrorConfigPathsFor(ws / "project", home).user ==
      root / "home" / ".config" / "reprobuild" / "config.toml"

  test "a malformed entry is refused naming the file and the entry":
    write(system, mirrorsToml(@["https://it.example/ok", "relative/dir"]))
    let msg = refusalOf(MirrorConfigPaths(user: user, system: system,
      workspace: settings))
    checkpoint msg
    check system in msg
    check "nimble.mirrors[1]" in msg
    check "relative/dir" in msg
    write(system, "schema = \"reprobuild.config.v1\"\n[nimble]\n" &
      "mirrors = [\"https://it.example/ok\", 7]\n")
    let typed = refusalOf(MirrorConfigPaths(system: system))
    check system in typed and "nimble.mirrors[1]" in typed
    write(system, "schema = \"reprobuild.config.v1\"\n[nimble]\n" &
      "mirrors = \"https://it.example/ok\"\n")
    check "must be an array" in refusalOf(MirrorConfigPaths(system: system))
    write(system, "schema = \"reprobuild.config.v1\"\n[nimble]\n" &
      "mirror = [\"https://it.example/ok\"]\n")
    check "nimble.mirror" in refusalOf(MirrorConfigPaths(system: system))
    write(system, mirrorsToml(@["https://it.example/nimble/"]))

  test "the key in repro-workspace.local.toml is refused naming the file":
    write(local, "schema = \"reprobuild.workspace.settings-local.v1\"\n\n" &
      "[nimble]\nmirrors = [\"https://mine.example/\"]\n")
    let p = mirrorConfigPathsFor(ws / "project", proc (n: string): string = "")
    check p.workspaceLocal == local
    let msg = refusalOf(p)
    checkpoint msg
    check local in msg
    check "[nimble]" in msg
    # The workspace's own reader of the local file refuses it too, naming
    # the file, so no other command takes it silently.
    var localRefusal = ""
    try:
      discard readLocalSettingsLayers(local, settings, @[])
    except CatchableError as e:
      localRefusal = e.msg
    checkpoint localRefusal
    check local in localRefusal
    check "nimble" in localRefusal
    removeFile(local)

  test "the strict readers of the shared files accept the table":
    let s = readWorkspaceSettings(settings)
    check s.nimble.mirrors == @["https://org.example/nimble",
      "/srv/host-mirror"]
    # The settings editor writes the table back.
    check "[nimble]" in workspaceSettingsText(s)
    # The layered configuration reader (`reprobuild.config.v1`) of the
    # user's and the system's file accepts it as well.
    check readReprobuildConfig(user).nimble.mirrors.len == 2
