## Installing the rustc wrapper into the environment of a cargo action.
##
## The build engine launches an action with a plain `KEY=VALUE` environment
## list. For an action that runs cargo it adds the entries below, at launch
## and not in the action's description: the wrapper is a measurement, so it
## changes neither the action's key nor what cargo writes.
##
## Cargo reads the wrapper from `RUSTC_WRAPPER`, then `build.rustc-wrapper`
## and its environment spelling `CARGO_BUILD_RUSTC_WRAPPER`
## (https://doc.rust-lang.org/cargo/reference/config.html#buildrustc-wrapper).
## A project that already has one (sccache, a logging shim) keeps it: ours
## runs it as the inner command, exactly where cargo would have run it, so the
## chain is `ours -> theirs -> rustc` and theirs sees the command line it
## always saw.

import std/[os, strutils]

const
  RustcWrapperEnv* = "RUSTC_WRAPPER"
  CargoWrapperEnv* = "CARGO_BUILD_RUSTC_WRAPPER"
  InnerWrapperEnv* = "REPRO_RUSTC_WRAPPER_INNER"
    ## The wrapper the project already had, run by ours in front of rustc.
  WrapperSwitchEnv* = "REPRO_RUSTC_WRAPPER"
    ## `on` or `off`, read by the engine. Anything else is the default.
  WrapperPathEnv* = "REPRO_RUSTC_WRAPPER_PATH"
    ## The wrapper executable, when it is not beside the engine.
  EdgeHelperFlag* = "--cargo-edge"
    ## The flag under which a helper binary (the standard provider) runs the
    ## thin cargo edge: `<helper> --cargo-edge -j 0 --products FILE -- cargo
    ## build ...`. The engine recognises an action that runs cargo this way.
  WrapperBinaryName* = "repro-rustc-wrapper"
  WrapperDefaultOn* = false
    ## Whether an unset `REPRO_RUSTC_WRAPPER` means on. See
    ## Build-Engine-And-Scheduler.md, Integration tiers, Cargo, for the
    ## overhead measurement this follows.

func isCargoProgram*(program: string): bool =
  ## Whether `program` (a path or a bare name) is cargo itself. `cargo-nextest`
  ## and other `cargo-*` tools are not: they start cargo through their own
  ## spelling, and the wrapper is for the cargo edge.
  let name = extractFilename(program.replace('\\', '/'))
  name == "cargo" or name == "cargo.exe"

proc wrapperEnabled*(switchValue: string): bool =
  case switchValue.strip().toLowerAscii()
  of "on", "1", "true", "yes": true
  of "off", "0", "false", "no": false
  else: WrapperDefaultOn

proc wrapperBinaryPath*(engineDir, override: string): string =
  ## The wrapper executable: `override` when it names a file, else the one
  ## beside the engine. "" when neither exists, which turns the wrapper off.
  if override.len > 0:
    return if fileExists(override): override else: ""
  let name = when defined(windows): WrapperBinaryName & ".exe"
             else: WrapperBinaryName
  let candidate = engineDir / name
  if fileExists(candidate): candidate else: ""

func envValue(env: openArray[string]; name: string): string =
  ## The last entry for `name`, as a process would see it.
  let prefix = name & "="
  for entry in env:
    if entry.startsWith(prefix):
      result = entry[prefix.len .. ^1]

func rustcWrapperEntries*(env: openArray[string];
                          wrapper: string): seq[string] =
  ## The entries to append to `env` so cargo runs `wrapper` in front of rustc.
  ## Empty when `wrapper` is empty or already installed.
  if wrapper.len == 0:
    return
  let current = envValue(env, RustcWrapperEnv)
  if current == wrapper:
    return
  let inherited =
    if current.len > 0: current else: envValue(env, CargoWrapperEnv)
  result.add RustcWrapperEnv & "=" & wrapper
  if inherited.len > 0:
    result.add InnerWrapperEnv & "=" & inherited
  # `CARGO_BUILD_RUSTC_WRAPPER` is ranked below `RUSTC_WRAPPER`, so it needs
  # no change; it is read above only to carry its value to the inner slot.
