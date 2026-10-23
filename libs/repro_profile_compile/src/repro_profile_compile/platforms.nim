## Target platforms of a home profile, and the platform probe.
##
## A compiled profile is evaluated on the platform that compiled it: Nim's
## `when defined(windows)` / `defined(macosx)` / `defined(arm64)` branches are
## decided by the compile and the unreached ones are gone from the binary.
## Runtime predicates (`when linux():`) are not -- they travel as data and the
## planner evaluates them for the target host. So an intent that uses only
## runtime predicates describes every platform, and one whose emitted content
## was changed by a compile-time branch describes only the platform it was
## compiled on.
##
## WHAT THE PROBE DECIDES, AND WHY IT IS A PROBE. Telling those two apart is
## not a property of the source text: a `when defined(...)` may change what is
## emitted or may only pick an import, it may sit in a helper module the
## profile reaches through three imports, or be produced by a macro. Nim does
## not report which definitions a compile consulted. What CAN be observed is
## the result: the `profile` macro builds the intent in a proc of its own,
## and `nim check --os:<os> --cpu:<cpu> -d:reproProfilePlatformProbe` makes
## the compiler evaluate that proc in its compile-time VM under the other
## platform's definitions and print the intent (`repro_profile/macros.nim`,
## `repro_profile/emit.nim` `platformProbeRecord`). `nim check` generates no
## code and links nothing, so any platform can be checked from any host.
## Comparing each platform's result with the exported intent answers "would
## this document describe that platform correctly" directly -- for compile-
## time branches anywhere in the profile, not only those the macro sees.
##
## The VM is not the native run, so the probe also evaluates the COMPILING
## platform and requires that result to equal the native intent; when it does
## not (a profile that calls into C, reads something the VM cannot), every
## other platform is reported unevaluated rather than trusted. A platform
## whose check fails (an import that does not exist there, a VM limitation)
## is unevaluated too. Unevaluated is treated like "differs" by consumers:
## the document is refused for that platform.

import std/[json, os, osproc, strtabs, strutils]
from repro_core/paths import extendedPath

import repro_profile
import repro_home_intent

import ./sources
import ./compile

type
  ProfileTargetPlatform* = object
    ## One platform a home profile can be evaluated for.
    system*: string
      ## The platform's name in exports and on the command line: the Nix
      ## system double (`aarch64-darwin`), since Nix is the first consumer.
    nimOs*, nimCpu*: string
      ## Nim's `--os:` / `--cpu:` names (`hostOS` / `hostCPU` on that
      ## platform), which decide every `defined(...)` platform symbol.
    platform*, arch*: string
      ## The predicate vocabulary (`repro_home_intent/predicate.nim`): what
      ## `macos()` / `arm64()` compare against.

const ProfileTargetPlatforms* = [
  ProfileTargetPlatform(system: "x86_64-linux", nimOs: "linux",
    nimCpu: "amd64", platform: "linux", arch: "x86_64"),
  ProfileTargetPlatform(system: "aarch64-linux", nimOs: "linux",
    nimCpu: "arm64", platform: "linux", arch: "arm64"),
  ProfileTargetPlatform(system: "x86_64-darwin", nimOs: "macosx",
    nimCpu: "amd64", platform: "macos", arch: "x86_64"),
  ProfileTargetPlatform(system: "aarch64-darwin", nimOs: "macosx",
    nimCpu: "arm64", platform: "macos", arch: "arm64"),
  ProfileTargetPlatform(system: "x86_64-windows", nimOs: "windows",
    nimCpu: "amd64", platform: "windows", arch: "x86_64"),
  ProfileTargetPlatform(system: "aarch64-windows", nimOs: "windows",
    nimCpu: "arm64", platform: "windows", arch: "arm64"),
]
  ## Every platform a home profile is probed for and an export can be
  ## evaluated for. The single table mapping platform names between Nix,
  ## Nim and the predicate grammar. `wsl` is not a separate platform: the
  ## `wsl` predicate is false for every target (a WSL host is an
  ## `x86_64-linux` host whose `wsl` fact only the planner on it knows).

const ProfilePlatformProbeVersion* = 2
  ## Version of the probe's output document (`runProfilePlatformProbes`,
  ## `encodeProbeOutcomes`). Part of the probe edge's weak fingerprint.

proc findTargetPlatform*(system: string): int =
  ## Index of `system` in `ProfileTargetPlatforms`, or -1.
  for i, t in ProfileTargetPlatforms:
    if t.system == system:
      return i
  -1

proc targetSystemNames*(): seq[string] =
  for t in ProfileTargetPlatforms:
    result.add t.system

proc compilingPlatformSystem*(): string =
  ## The platform this `repro` compiles profiles for (the compile is
  ## native): its `system` name, or `<cpu>-<os>` in Nim's names when it is
  ## not one of `ProfileTargetPlatforms`.
  for t in ProfileTargetPlatforms:
    if t.nimOs == hostOS and t.nimCpu == hostCPU:
      return t.system
  hostCPU & "-" & hostOS

proc targetHostContext*(t: ProfileTargetPlatform; host: string): HostContext =
  ## The facts predicates are evaluated against for host `host` running
  ## platform `t`. `isWsl` is false (see `ProfileTargetPlatforms`).
  HostContext(platform: t.platform, arch: t.arch, host: host, isWsl: false)

type
  ProfileNimConfig* = object
    ## The module search paths a profile compile resolves on THIS host, as
    ## `nim dump` reports them after reading the profile's (staged)
    ## `config.nims` and every other configuration file.
    searchPaths*: seq[string]
      ## The explicit search paths (`nim dump`'s `lib_paths`), never the
      ## lazy Nimble package paths.

proc resolveProfileNimConfig*(nimExe, profileRoot, repoRootAbs: string;
                              env: StringTableRef): ProfileNimConfig =
  ## Run `nim dump` over the profile for the compiling platform with the
  ## compile's own arguments and return the search paths it resolved.
  ##
  ## WHY THE PROBES NEED THE HOST'S SEARCH PATHS. Nim runs `config.nims`
  ## under the TARGET's definitions: checked with `--os:windows`,
  ## reprobuild's config.nims joins its candidate paths with `\` and
  ## compiles out its POSIX fallbacks, so on a Linux host it resolves none
  ## of the sibling packages and the check fails on an import (measured:
  ## `undeclared identifier: 'buildAction'`). Where to find modules is a
  ## fact about the host, not the target, so the paths are resolved once,
  ## here, and added to every probe (`profileProbeArgv`). Everything else
  ## the configuration decides -- above all the `-d:` symbols a
  ## `config.nims` defines per platform -- the probe leaves to the
  ## configuration files themselves, evaluated under the target.
  ##
  ## Raises `CompileFailure` when the dump fails or prints no JSON.
  var argv = @[nimExe, "dump", "--dump.format:json", "--hints:off",
    "--warnings:off"]
  for define in ProfileCompileDefines:
    argv.add "-d:" & define
  for path in profileNimPaths(repoRootAbs):
    argv.add "--path:" & path
  argv.add profileRoot
  let (output, exitCode) = finishProfileNim(
    startProfileNim(argv, repoRootAbs, env))
  # NimScript's `echo` shares stdout with the document; the document is the
  # one line that is a JSON object with the dump's `version` key.
  var doc: JsonNode = nil
  for line in output.splitLines():
    if line.startsWith("{\"version\""):
      try:
        doc = parseJson(line)
      except JsonParsingError:
        doc = nil
  if exitCode != 0 or doc.isNil or doc.kind != JObject:
    var err = new CompileFailure
    err.msg = "nim dump of " & profileRoot & " failed (exit " & $exitCode &
      ")"
    err.stderrText = output
    raise err
  # Only the explicit search paths (`lib_paths`). `lazyPaths` are Nimble
  # package directories (`~/.nimble/pkgs2/*`, ...), which Nim searches only
  # after every explicit path. Passing them to the probe as `--path:` would
  # promote them above the profile's own paths -- Nim searches the newest
  # `--path` first -- so a stale package in the user's Nimble directory
  # would shadow a module the compile resolves elsewhere, and the probe
  # would report the platform `unevaluated` where the compile succeeds. The
  # probe's `nim check` still finds them lazily, as the compile does: it
  # reads the same configuration files and the same Nimble directories.
  if doc.hasKey("lib_paths"):
    for path in doc["lib_paths"]:
      result.searchPaths.add path.getStr

proc profileProbeArgv*(nimExe, profileRoot, nimcacheDir: string;
                       config: ProfileNimConfig;
                       t: ProfileTargetPlatform): seq[string] =
  ## `nim check` of the profile under `t`'s platform definitions with the
  ## probe define set: the compile's own arguments (`profileCompileArgv`),
  ## the configuration files read as the compile reads them, plus the
  ## search paths the compile resolves on this host
  ## (`resolveProfileNimConfig`).
  ##
  ## The configuration files are NOT skipped: Nim evaluates them under the
  ## target's definitions, exactly as a compile on that platform would, so
  ## a `config.nims` that defines a symbol only `when defined(macosx)`
  ## defines it in the darwin probes and nowhere else (with its value). An
  ## earlier version skipped them and passed the host's resolved `-d:`
  ## symbols instead; a profile `config.nims` with a per-platform define
  ## then evaluated identically everywhere and was reported `same` for a
  ## platform it did not describe. The host's search paths are added on top
  ## so that a configuration that resolves paths wrongly for a foreign
  ## platform (above) still finds the profile's modules; a path that does
  ## not exist on this host resolves nothing.
  result = @[nimExe, "check", "--hints:off", "--warnings:off",
    "--os:" & t.nimOs, "--cpu:" & t.nimCpu,
    "--nimcache:" & nimcacheDir,
    "-d:" & ProfilePlatformProbeDefine]
  for define in ProfileCompileDefines:
    result.add "-d:" & define
  for path in config.searchPaths:
    result.add "--path:" & path
  result.add profileRoot

type
  ProbeOutcome* = object
    ## The probe's result for one platform.
    system*: string
    evaluated*: bool
      ## The check completed and printed an intent.
    intentJson*: string
      ## The intent as `emitProfileIntentJson` rendered it in the VM
      ## (canonical, so it compares byte-for-byte with the native intent
      ## re-encoded by the same encoder). Empty unless `evaluated`.
    diagnostic*: string
      ## Why the platform could not be evaluated: the tail of the checker's
      ## output. Empty when `evaluated`.

const ProbeDiagnosticLines = 12

proc diagnosticTail(output: string; exitCode: int): string =
  var lines: seq[string]
  for line in output.splitLines():
    if line.strip().len > 0:
      lines.add line
  if lines.len > ProbeDiagnosticLines:
    lines = lines[lines.len - ProbeDiagnosticLines .. ^1]
  "nim check exited " & $exitCode &
    (if lines.len > 0: ": " & lines.join("\n") else: " with no output")

proc runProfilePlatformProbes*(profileRoot, nimcacheDir, repoRoot: string):
    seq[ProbeOutcome] =
  ## Evaluate the profile for every platform in `ProfileTargetPlatforms`,
  ## in parallel batches of at most the processor count. Never raises for
  ## a platform that fails: its outcome is unevaluated with the checker's
  ## diagnostic. Raises `CompileFailure` only when no check can be started
  ## at all (no compiler, no reprobuild sources).
  let nimExe = resolveProfileNimCompiler()
  let repoRootAbs = absolutePath(repoRoot)
  requireReprobuildSources(repoRootAbs)
  let childEnv = profileCompileEnvAdditions(repoRootAbs)
  let staged = stageProfileFiles(profileRoot, repoRootAbs)
  try:
    var config: ProfileNimConfig
    try:
      config = resolveProfileNimConfig(nimExe, profileRoot, repoRootAbs,
        childEnv)
    except CompileFailure as err:
      # Nothing can be checked without the configuration; every platform is
      # unevaluated, with the reason.
      for t in ProfileTargetPlatforms:
        result.add ProbeOutcome(system: t.system,
          diagnostic: err.msg & ": " & diagnosticTail(err.stderrText, 1))
      return
    let width = max(1, min(ProfileTargetPlatforms.len, countProcessors()))
    var next = 0
    while next < ProfileTargetPlatforms.len:
      var batch: seq[(int, Process)]
      while next < ProfileTargetPlatforms.len and batch.len < width:
        let t = ProfileTargetPlatforms[next]
        let dir = nimcacheDir / t.system
        createDir(extendedPath(dir))
        let argv = profileProbeArgv(nimExe, profileRoot, dir, config, t)
        batch.add (next, startProfileNim(argv, repoRootAbs, childEnv))
        inc next
      # Drain in start order. A check whose output does not fit its pipe
      # waits until its turn; none waits on another, so this cannot
      # deadlock.
      for (index, process) in batch:
        let (output, exitCode) = finishProfileNim(process)
        var outcome = ProbeOutcome(system: ProfileTargetPlatforms[index].system)
        var intentJson = ""
        if exitCode == 0 and parsePlatformProbeRecord(output, intentJson):
          outcome.evaluated = true
          outcome.intentJson = intentJson
        else:
          outcome.diagnostic = diagnosticTail(output, exitCode)
        result.add outcome
  finally:
    unstageProfileFiles(staged)

proc encodeProbeOutcomes*(outcomes: openArray[ProbeOutcome]): string =
  ## The probe edge's published document.
  var targets = newJArray()
  for o in outcomes:
    if o.evaluated:
      targets.add %*{"system": o.system, "evaluated": true,
        "intent": o.intentJson}
    else:
      targets.add %*{"system": o.system, "evaluated": false,
        "diagnostic": o.diagnostic}
  $(%*{"probeVersion": ProfilePlatformProbeVersion, "targets": targets})

proc decodeProbeOutcomes*(text: string): seq[ProbeOutcome] =
  ## Inverse of `encodeProbeOutcomes`. Raises `ValueError` on a document of
  ## another probe version or shape.
  let doc = parseJson(text)
  if doc.kind != JObject or doc.getOrDefault("probeVersion").isNil or
      doc["probeVersion"].getInt != ProfilePlatformProbeVersion:
    raise newException(ValueError,
      "platform probe document is not probe version " &
      $ProfilePlatformProbeVersion)
  for t in doc["targets"]:
    var o = ProbeOutcome(system: t["system"].getStr,
      evaluated: t["evaluated"].getBool)
    if o.evaluated:
      o.intentJson = t["intent"].getStr
    else:
      o.diagnostic = t["diagnostic"].getStr
    result.add o
