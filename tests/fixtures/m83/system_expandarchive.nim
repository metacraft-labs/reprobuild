## Windows-System-Resources Phase F fixture: a standalone Nim program
## that exercises the ``expandArchive`` typed-tool wrapper across the
## load-bearing paths — explicit ``format =`` override + auto-detect
## from the archive filename — and emits the resulting build edges'
## load-bearing fields as JSON on stdout.
##
## The e2e gate (`tests/e2e/m83/t_e2e_repro_profile_compile.nim`)
## compiles + runs this fixture and asserts the emitted JSON carries
## the spec'd argv / outputs / requiresElevation shapes. Nothing is
## extracted — the archive paths are placeholders.
##
## Phase F is the stdlib-package layer only; the profile-DSL hand-off
## (Spec §2.3 Option A — typed-tool calls inside a profile's
## ``resources:`` block route through the build engine at apply time)
## is deferred to a later phase. So this fixture is a standalone
## program that imports the package + emits JSON, NOT a
## ``profile "..."`` block.

import std/[json, strutils]

import repro_project_dsl
import repro_dsl_stdlib/packages/expand_archive as expandArchive

proc argvOfAction(act: BuildActionDef): seq[string] =
  ## Extract the literal argv from a builtin-exec action's call. The
  ## ``inlineExecCall`` lowering stores argv as a single positional
  ## ``cliArgSeq("argv", ...)``; the values are joined with the ASCII
  ## unit-separator (``\x1f``) inside ``encodedValue``.
  for arg in act.call.arguments:
    if arg.name == "argv":
      if arg.encodedValue.len == 0:
        return @[]
      return arg.encodedValue.split("\x1f")
  @[]

proc actionToJson(act: BuildActionDef): JsonNode =
  result = newJObject()
  result["id"] = %act.id
  result["requiresElevation"] = %act.requiresElevation
  result["outputs"] = %act.outputs
  result["inputs"] = %act.inputs
  result["deps"] = %act.deps
  result["commandStatsId"] = %act.commandStatsId
  result["toolIdentityRefs"] = %act.toolIdentityRefs
  result["argv"] = %argvOfAction(act)
  result["callPackage"] = %act.call.packageName
  result["callExecutable"] = %act.call.executableName

# Build edges. Each one exercises a different code path through the
# typed-tool wrapper:
#
#   * ``runnerZip`` — Windows-style absolute paths, requiresElevation,
#     auto-detect zip from the filename suffix.
#   * ``runnerTarGz`` — explicit ``format = "tar.gz"`` override on an
#     ambiguous filename + non-zero ``stripComponents``.
#   * ``runnerTarXz`` — POSIX paths, auto-detect tar.xz from suffix.
#   * ``ambiguousZip`` — explicit ``format = "zip"`` override + custom
#     ``address`` so the action id is stable for the gate.

resetBuildActionRegistry()
let runnerZip = expandArchive.build(
  archive = "C:\\actions-runner-cache\\runner.zip",
  destination = "C:\\actions-runner",
  marker = "C:\\actions-runner\\config.cmd",
  requiresElevation = true,
  address = "extractRunnerZip")

let runnerTarGz = expandArchive.build(
  archive = "/var/cache/runner-bundle.dat",
  destination = "/opt/runner",
  marker = "/opt/runner/config.sh",
  format = "tar.gz",
  stripComponents = 1,
  address = "extractRunnerTarGz")

let runnerTarXz = expandArchive.build(
  archive = "/var/cache/runner.tar.xz",
  destination = "/opt/runner-xz",
  marker = "/opt/runner-xz/config.sh",
  address = "extractRunnerTarXz")

let ambiguousZip = expandArchive.build(
  archive = "/var/cache/blob.dat",
  destination = "/opt/blob",
  marker = "/opt/blob/manifest.json",
  format = "zip",
  address = "extractAmbiguousZip")

let doc = newJObject()
doc["runnerZip"] = actionToJson(runnerZip)
doc["runnerTarGz"] = actionToJson(runnerTarGz)
doc["runnerTarXz"] = actionToJson(runnerTarXz)
doc["ambiguousZip"] = actionToJson(ambiguousZip)
# Compile-time platform marker so the e2e gate knows which dispatch
# branch the host compiled into.
when defined(windows):
  doc["host"] = %"windows"
else:
  doc["host"] = %"posix"
echo doc.pretty().strip()
