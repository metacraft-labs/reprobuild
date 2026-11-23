## The platform probe resolves the profile's modules the way the native
## compile does: a package in the invoking user's Nimble directory never
## shadows a module reprobuild's own search paths provide.
##
## `e2e_platform_probe_ignores_user_nimble_packages`: the sandbox `HOME`
## holds `~/.nimble/pkgs2/repro_profile-99.0.0-<hash>/repro_profile.nim`, a
## module that is a compile error, beside a profile that uses only runtime
## predicates (so every platform declares the same intent). Nim lists such a
## directory among its LAZY paths, searched only after every explicit path,
## so the native compile still finds reprobuild's own `repro_profile`. The
## probe must too:
##
## * `repro home export` succeeds and the probe reports every target
##   platform `same`;
## * `repro home export --target <another platform>` and `repro home facts
##   --target <another platform>` are evaluated (exit 0), not refused.
##
## The defect this gates (recorded 2026-10-15): the probe read both
## `lib_paths` and `lazyPaths` from `nim dump` and passed all of them as
## explicit `--path:` options, which Nim searches newest-first, so a stale
## Nimble package took precedence over the profile's own search paths and
## every platform came back `unevaluated` (exit 3 for every `--target`).
##
## Vacuity guard: `nim dump` in the sandbox environment lists the fake
## package directory among its `lazyPaths` -- the shadow is really on the
## search path, so the green result is the probe keeping it lazy, not Nim
## ignoring the directory.
##
## Falsifying mutation (performed when this gate was written): add
## `lazyPaths` back to the paths `resolveProfileNimConfig` returns. Every
## platform is then `unevaluated` (the profile imports the fake module, so
## `macos` is undeclared), and both `--target` runs exit 3.
##
## No mocks: real `build/bin/repro`, real Nim, real filesystem; the `nim`
## spy is a pass-through counter (harness header). Nothing is applied.
##
## Platforms: every host (the sandbox sets `USERPROFILE` as well as `HOME`);
## the "other" platform is chosen relative to the compiling one.

import std/[json, os, osproc, strtabs, strutils, unittest]
from repro_core/paths import extendedPath

import repro_profile_compile

import ./profile_compile_edge_harness

const
  Host = "probe-nimble-host"
  NeutralProfile = """
import repro_profile

profile "probeNimble":
  activity default:
    ripgrep
    when macos():
      `probe-mac-app`

  resources:
    when linux():
      fsUserFile(hostFile = "~/.config/probe/linux.conf", content = "linux\n")
    elif macos():
      fsUserFile(hostFile = "~/Library/Preferences/probe.conf",
        content = "macos\n")
    else:
      fsUserFile(hostFile = "~/probe.conf", content = "other\n")

  hosts:
    "probe-nimble-host": [default]
"""
  ShadowDir = ".nimble/pkgs2/" &
    "repro_profile-99.0.0-0123456789abcdef0123456789abcdef01234567"
  ShadowModule = "{.error: \"probe-nimble-shadow: the user's Nimble " &
    "package was imported instead of reprobuild's repro_profile\".}\n"

suite "GM3: the platform probe ignores the user's Nimble packages":

  test "e2e_platform_probe_ignores_user_nimble_packages":
    let compiling = compilingPlatformSystem()
    require compiling in targetSystemNames()
    let other = if compiling.endsWith("-darwin"): "x86_64-linux"
                else: "aarch64-darwin"
    var sb = newProfileSandbox("probe-nimble", NeutralProfile)
    defer: sb.dispose()
    let shadow = sb.homeDir / ShadowDir
    createDir(extendedPath(shadow))
    writeFile(extendedPath(shadow / "repro_profile.nim"), ShadowModule)

    # Vacuity: Nim really sees the shadow from this HOME, as a lazy path.
    let env = sb.sandboxEnv(Host)
    let probeFile = sb.root / "probe_vacuity.nim"
    writeFile(extendedPath(probeFile), "discard\n")
    let dump = execCmdEx(quoteShell(findExe("nim")) &
      " dump --dump.format:json --hints:off " & quoteShell(probeFile),
      env = env, workingDir = sb.root)
    var lazy: seq[string]
    for line in dump.output.splitLines():
      if line.startsWith("{\"version\""):
        for p in parseJson(line)["lazyPaths"]:
          lazy.add p.getStr.strip(leading = false, chars = {'/', '\\'})
    checkpoint("nim dump lazyPaths: " & $lazy)
    require shadow in lazy

    # The export: compiled natively, probed for every platform.
    let run = sb.runRepro(["home", "export", "--host", Host], host = "")
    checkpoint(run.stderr)
    require run.exitCode == 0
    let doc = parseJson(run.stdout)
    checkpoint("platforms: " & $doc["platforms"] & "\nprobe: " &
      $doc["provenance"]["compile"]["probe"])
    for system in targetSystemNames():
      checkpoint(system)
      check doc["platforms"][system].getStr == "same"
    check not run.stdout.contains("probe-nimble-shadow")

    # Another platform is described, through the probe, by both commands.
    let exported = sb.runRepro(["home", "export", "--host", Host,
      "--target", other], host = "")
    checkpoint(exported.stderr)
    check exported.exitCode == 0
    if exported.exitCode == 0:
      check parseJson(exported.stdout)["evaluation"]["target"].getStr == other
    let facts = sb.runRepro(["home", "facts", "--host", Host,
      "--target", other], host = "")
    checkpoint(facts.stderr)
    check facts.exitCode == 0
    if facts.exitCode == 0:
      check parseJson(facts.stdout)["system"].getStr == other
