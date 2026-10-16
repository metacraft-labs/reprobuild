## GM6: `repro home facts` -- the Reprobuild side of the equivalence report
## -- reports what an apply would write, planned against a private home.
##
## `e2e_home_facts_from_isolated_plan` runs the real `build/bin/repro home
## facts` on a profile that declares something in every host-facts category
## (packages in two activities, a stow package, `fs.userFile` resources, an
## environment variable, PATH entries in three spellings, a shell-integration block, a systemd
## user unit and a launchd agent behind platform guards, a dconf key and a
## Homebrew cask that no category covers) and checks the document entry by
## entry, with content digests computed independently (`sha256sum` of the
## literal bytes, recorded below).
##
## Isolation: `HOME` points at a directory holding a file at a path the stow
## package also targets, with OTHER bytes. A producer that looked at the real
## home would either report those bytes or report drift; the facts must carry
## the stow source's digest, every path must be home-relative (`~/...`) with
## no trace of either the real home or the private one, and the real home's
## tree must be byte-for-byte unchanged afterwards.
##
## The second run plans the same profile for `aarch64-darwin` from this
## (Linux) host -- the platform-probe path, as `repro home export --target`:
## the guarded systemd unit gives way to the launchd agent and the cask
## becomes an unmapped package. On a darwin host the roles swap (the darwin
## run is native and the Linux run goes through the probe), so the gate runs
## on Linux and macOS alike.
##
## Vacuity: every category has at least one entry in the native run, and
## both runs differ exactly where the guards say.
##
## No mocks: the real `repro`, the real Nim compiler and profile compile edge
## (through the shared harness), a real filesystem. Windows: not compiled in
## -- the gate's targets are the two Nix platforms, where the comparison is
## made (spec §Platforms); home-pc and m1 run it.

import std/[json, os, sequtils, strutils, unittest]
from repro_core/paths import extendedPath

import ./profile_compile_edge_harness

const
  Host = "gm6-host"
  HomeNim = """
import repro_profile

profile "gm6Facts":
  activity default:
    bash
    package("jq", "1.7.1")

  activity desktop:
    ripgrep

  activity unused:
    `gm6-not-selected`

  hosts:
    "gm6-host": [desktop]

  resources:
    fsUserFile(hostFile = "~/.config/gm6/app.conf", content = "answer = 42\n")
    fsUserFile(hostFile = "~/.local/bin/gm6-run",
      content = "#!/bin/sh\nexit 0\n", mode = "0755", executable = true)
    envUserVariable(name = "GM6_EDITOR", value = "nvim")
    envUserPath(entries = "~/.local/bin, $HOME/gm6/bin, /opt/gm6/bin")
    shellIntegration(hostFile = "~/.zshrc", blockId = "gm6",
      content = "eval \"$(gm6 hook)\"")
    when linux():
      systemdUserUnit(name = "gm6.service",
        content = "[Unit]\nDescription=gm6\n")
      linuxDconfKey(key = "/org/gm6/answer", value = "42")
    when macos():
      launchdUserAgent(label = "org.gm6.agent",
        programArgs = @["/bin/echo", "gm6"])
      homebrewCask(name = "gm6-cask")
"""
  # sha256sum of the literal bytes (computed with coreutils, 2026-10-15).
  AppConfDigest = "sha256:0a775022744f64c352863f165f2e125898419999bc57c83204772036d0ef6b2e"
  RunScriptDigest = "sha256:306c6ca7407560340797866e077e053627ad409277d1b9da58106fce4cf717cb"
  HookDigest = "sha256:ed4a5af2d8e0210b520d203f4ff471677081cfc476e1a12b809ef21c3dd9d804"
  UnitDigest = "sha256:1f454cdbf5f38f97748d61574f646163e50943b9678ed5c015398c757497ce16"
  RcDigest = "sha256:e3dd696969b6447bd5031b34bececc6bc6d0113fbbef48ae1ae2c2a0351dcf27"
  ToolDigest = "sha256:bf664cf84f00f6ed76164c8457fdeaf8e4dee547226e9ffcf8274e2d2246fed9"

proc ids(doc: JsonNode; category: string): seq[string] =
  for e in doc["categories"][category]:
    result.add e["id"].getStr

proc entryOf(doc: JsonNode; category, id: string): JsonNode =
  for e in doc["categories"][category]:
    if e["id"].getStr == id:
      return e
  nil

proc listIds(doc: JsonNode; key: string): seq[string] =
  for e in doc[key]:
    result.add e["id"].getStr

when defined(linux) or defined(macosx):
  suite "GM6: repro home facts plans against a private home":

    test "e2e_home_facts_from_isolated_plan":
      var sb = newProfileSandbox("gm6-facts", HomeNim)
      defer: sb.dispose()
      sb.writeProfileFile("stow/gm6/.gm6rc", "rc = 1\n")
      sb.writeProfileFile("stow/gm6/.local/share/gm6/tool",
        "#!/bin/sh\necho tool\n")
      setFilePermissions(sb.profileDir / "stow/gm6/.local/share/gm6/tool",
        {fpUserRead, fpUserWrite, fpUserExec, fpGroupRead, fpOthersRead})
      # The "real" home of this run: a file where the stow package links,
      # with other bytes.
      writeFile(extendedPath(sb.homeDir / ".gm6rc"), "REAL HOME, NOT THE PLAN\n")
      let homeBefore = treeFingerprint(sb.homeDir)

      let native = when defined(macosx): "aarch64-darwin" else: "x86_64-linux"
      let other = when defined(macosx): "x86_64-linux" else: "aarch64-darwin"

      let run = sb.runRepro(["home", "facts", "--host", Host,
        "--target", native], host = "")
      check run.exitCode == 0
      if run.exitCode != 0:
        echo run.stderr
      let doc = parseJson(run.stdout)
      check doc["format"].getStr == "repro.host-facts"
      check doc["schemaVersion"].getInt == 1
      check doc["side"].getStr == "reprobuild"
      check doc["host"].getStr == Host
      check doc["system"].getStr == native

      # Vacuity: every category reported something.
      for c in ["packages", "files", "environment", "services"]:
        check doc["categories"][c].len > 0

      # Packages: `default` + the host's `desktop`, by canonical name; the
      # unselected activity contributes nothing; the version is carried.
      check doc.ids("packages") == @["bash", "jq", "ripgrep"]
      check doc.entryOf("packages", "jq")["version"].getStr == "1.7.1"

      # Files: stow (the source's bytes, not the real home's), userFile
      # resources with their declared modes.
      check doc.ids("files") == @["~/.config/gm6/app.conf", "~/.gm6rc",
        "~/.local/bin/gm6-run", "~/.local/share/gm6/tool"]
      check doc.entryOf("files", "~/.gm6rc")["digest"].getStr == RcDigest
      check doc.entryOf("files", "~/.gm6rc")["mode"].getStr == "0644"
      check doc.entryOf("files", "~/.local/share/gm6/tool")["digest"].getStr ==
        ToolDigest
      check doc.entryOf("files", "~/.local/share/gm6/tool")["mode"].getStr ==
        "0755"
      check doc.entryOf("files", "~/.config/gm6/app.conf")["digest"].getStr ==
        AppConfDigest
      check doc.entryOf("files", "~/.local/bin/gm6-run")["digest"].getStr ==
        RunScriptDigest
      check doc.entryOf("files", "~/.local/bin/gm6-run")["mode"].getStr ==
        "0755"

      # Environment: the variable, the PATH entry, the shell block.
      # PATH entries under the home are named `~/...` however they spell it
      # (the Nix producer names `home.sessionPath` the same way); others as
      # written.
      check doc.ids("environment") == @["block:~/.zshrc#gm6",
        "path:/opt/gm6/bin", "path:~/.local/bin", "path:~/gm6/bin",
        "var:GM6_EDITOR"]
      check doc.entryOf("environment", "var:GM6_EDITOR")["value"].getStr ==
        "nvim"
      check doc.entryOf("environment", "block:~/.zshrc#gm6")["digest"].getStr ==
        HookDigest

      # Services and the uncategorized/unmapped lists, per platform.
      proc checkServices(d: JsonNode; system: string) =
        if system.endsWith("-linux"):
          check d.ids("services") == @["systemd:gm6.service"]
          let u = d.entryOf("services", "systemd:gm6.service")
          check u["enabled"].getBool
          check u["digest"].getStr == UnitDigest
          check d.listIds("uncategorized").len == 1
          check d.listIds("uncategorized")[0].contains("/org/gm6/answer")
          check d["unmapped"].len == 0
        else:
          check d.ids("services") == @["launchd:org.gm6.agent"]
          let a = d.entryOf("services", "launchd:org.gm6.agent")
          check a["programArguments"] == %["/bin/echo", "gm6"]
          check a["runAtLoad"].getBool
          check not a["keepAlive"].getBool
          check d["uncategorized"].len == 0
          check d["unmapped"].len == 1
          check d["unmapped"][0]["category"].getStr == "packages"
          check d["unmapped"][0]["id"].getStr.contains("gm6-cask")
      checkServices(doc, native)

      # Isolation: nothing about either home directory is in the document,
      # and the real home was not touched.
      check not run.stdout.contains(sb.homeDir)
      check not run.stdout.contains("repro-home-facts-")
      check treeFingerprint(sb.homeDir) == homeBefore

      # The other platform, through the platform probe.
      let cross = sb.runRepro(["home", "facts", "--host", Host,
        "--target", other], host = "")
      check cross.exitCode == 0
      if cross.exitCode != 0:
        echo cross.stderr
      let crossDoc = parseJson(cross.stdout)
      check crossDoc["system"].getStr == other
      check crossDoc.ids("packages") == doc.ids("packages")
      check crossDoc.ids("files") == doc.ids("files")
      checkServices(crossDoc, other)
      check treeFingerprint(sb.homeDir) == homeBefore

      # --host is the planned host: another host selects other activities.
      let defaultOnly = sb.runRepro(["home", "facts", "--host", "gm6-other",
        "--target", native], host = "")
      check defaultOnly.exitCode == 0
      check parseJson(defaultOnly.stdout).ids("packages") == @["bash", "jq"]
