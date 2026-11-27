## Shared pieces of the cases that build a crates.io workspace with
## `repro build`, where its graph-production edges run: the fetch edges, the
## plan edge, the units edge and the actions the units edge's fragment
## creates (`repro_standard_provider/conventions/rust_plan_mode`).
##
## Everything is real: the `repro` CLI built from this tree, the Rust
## convention, the engine with its monitor, cargo and rustc. The registry
## crates are real `.crate` files made by `cargo package`
## (`rqe_cg5_plan_fixture.setupRegistry`) and put in a store root of the
## case's own before the build, so the fetch edges find every prefix there
## and contact nothing: no case reaches the network.

import std/[json, os, osproc, strtabs, strutils]

import repro_core/process_streams
import repro_test_support

import ./rqe_cg5_plan_fixture

type ReproBuildEnv* = object
  ## What one case's `repro build` runs with.
  repro*: string
  vars*: seq[(string, string)]

proc reproBuildEnv*(work: string; reg: RegistrySetup;
                    lift = true): ReproBuildEnv =
  ## The environment of a case's builds: the registry lift's switch, the
  ## record wrapper built from this tree, a `PATH` of Nix store directories
  ## only (the convention resolves cargo, rustc and the C driver there), the
  ## case's store root holding the fixture's crates, and an action cache,
  ## `HOME` and `CARGO_HOME` of the case's own. ``lift`` false leaves the
  ## switch off.
  let repoRoot = currentSourcePath().parentDir.parentDir.parentDir
  result.repro = requireBinary(reproBinaryPath(repoRoot, "repro"),
    "reprobuild.apps.repro")
  let wrapper = requireBinary(reproBinaryPath(repoRoot, "repro-rustc-wrapper"),
    "reprobuild.apps.repro-rustc-wrapper")
  for dir in ["home", "cargo-home", "xdg-cache", "actions"]:
    createDir(work / dir)
  result.vars = @[
    ("PATH", storeOnlyPath()),
    ("HOME", work / "home"),
    ("XDG_CACHE_HOME", work / "xdg-cache"),
    ("CARGO_HOME", work / "cargo-home"),
    ("REPRO_STORE_ROOT", reg.store),
    ("REPROBUILD_STORE_ROOT", work / "actions"),
    ("REPRO_RUSTC_WRAPPER_PATH", wrapper)]
  if lift:
    result.vars.add ("REPRO_CARGO_MODE_A_REGISTRY", "on")

type BuildOutcome* = object
  code*: int
  output*: string
  report*: JsonNode

proc reproBuild*(env: ReproBuildEnv; ws: string): BuildOutcome =
  ## `repro build` of the workspace's default target, with an action log and
  ## a build report, without a resident daemon (which would run in another
  ## environment). The tools come from `PATH` (`--tool-provisioning=path`):
  ## the fixture's `uses: rust` is resolved there, where the convention
  ## finds cargo and rustc too.
  var e = newStringTable(modeCaseSensitive)
  for (k, v) in env.vars: e[k] = v
  let p = startProcess(env.repro, workingDir = ws,
    args = ["build", ws, "--daemon=off", "--log=actions", "--write-report",
      "--tool-provisioning=path"],
    env = e, options = {poStdErrToStdOut})
  result.output = drainStream(p.outputStream)
  result.code = p.waitForExit()
  p.close()
  for line in result.output.splitLines:
    if line.startsWith("buildReport:"):
      let path = line["buildReport:".len .. ^1].strip()
      if fileExists(path):
        result.report = parseFile(path)
  if result.report.isNil:
    result.report = newJObject()

proc actions*(o: BuildOutcome): seq[JsonNode] =
  for item in o.report{"actions"}.getElems():
    result.add item

proc action*(o: BuildOutcome; id: string): JsonNode =
  for item in o.actions:
    if item{"id"}.getStr() == id: return item
  newJNull()

proc idsWithPrefix*(o: BuildOutcome; prefix: string): seq[string] =
  for item in o.actions:
    let id = item{"id"}.getStr()
    if id.startsWith(prefix): result.add id

proc launchedIds*(o: BuildOutcome; prefix: string): seq[string] =
  for item in o.actions:
    let id = item{"id"}.getStr()
    if id.startsWith(prefix) and item{"launched"}.getBool(): result.add id

proc describe*(o: BuildOutcome): string =
  ## Every action's id, status and decision, and the build's output, for a
  ## failing check's checkpoint.
  result = "exit " & $o.code & "\n"
  for item in o.actions:
    result.add "  " & item{"id"}.getStr() & " " & item{"status"}.getStr() &
      " launched=" & $item{"launched"}.getBool() & " " &
      item{"cacheDecision"}.getStr() & " " & item{"reason"}.getStr() &
      " miss=" & item{"cacheMissReason"}.getStr() &
      " skip=" & item{"cachePublishSkipReason"}.getStr() & "\n"
  result.add o.output

proc vendorCargoHome*(work: string; reg: RegistrySetup) =
  ## Configure the builds' own `CARGO_HOME` (`reproBuildEnv`) to find the
  ## fixture's crates offline, as a user's cargo configured with a vendored
  ## source would: Mode B's `cargo build --offline` reads it. The record run
  ## reads none of it (its `CARGO_HOME` is edge-private), so the plan is the
  ## same with or without it.
  createDir(work / "cargo-home")
  writeFile(work / "cargo-home" / "config.toml",
    "[source.crates-io]\nreplace-with = \"test-vendor\"\n\n" &
    "[source.test-vendor]\ndirectory = \"" & reg.testVendor & "\"\n")
