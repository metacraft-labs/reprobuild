## Shared vocabulary of the cargo target-directory janitor.
##
## Cargo never prunes a target directory: a renamed crate, a changed feature
## set, a profile or flag change and every toolchain upgrade each leave the
## previous build units behind. The janitor bounds the directory by
## remembering which units the last few cargo invocations actually used (the
## *live sets*) and deleting the rest once they are also old enough.

import std/[os, strutils]

const
  DefaultKeepSets* = 3
    ## PROVISIONAL. How many of the most recent live sets, per profile
    ## directory, protect their units. Not yet tuned against real workloads;
    ## this is a conservative default and every caller can override it (flag,
    ## environment, user config).

  DefaultMinAgeSeconds* = 14 * 24 * 3600
    ## PROVISIONAL. A unit outside the retained live sets is only deleted
    ## once nothing in it has been written for this long (14 days). Same
    ## status as `DefaultKeepSets`.

  UnitHashLen* = 16
    ## Cargo names a unit's files `<name>-<hash>[.<ext>]` with a 16-digit
    ## lowercase hexadecimal metadata hash.

  StoreDirName* = ".repro-cargo-gc"
    ## Where the live sets live, directly under the target directory. The
    ## leading dot keeps it out of cargo's own naming; `cargo clean` removes
    ## it with everything else, which is correct (nothing is left to prune).

type
  UnitKind* = enum
    ## What a live unit is, as far as the janitor cares. It only affects how
    ## the unit is reported; every kind is retained and deleted the same way.
    ukCompile = "compile" ## a `compiler-artifact` (lib, bin, test, ...)
    ukBuildScript = "build-script" ## a compiled build script (`custom-build`)
    ukBuildScriptRun = "build-script-run"
      ## a `build-script-executed` out dir

  LiveUnit* = object
    ## One build unit a cargo invocation used (compiled or found fresh).
    profileDir*: string
      ## The profile directory relative to the target directory, with `/`
      ## separators: `debug`, `release`, `x86_64-unknown-linux-gnu/debug`.
      ## The (profile, target triple) key of the design, read off the paths
      ## cargo itself printed rather than guessed from `profile` fields that
      ## do not carry the profile's name.
    hash*: string
    kind*: UnitKind
    packageId*: string
    targetName*: string
    targetKind*: string
    crateName*: string
    profile*: string
      ## `opt-level=0 debuginfo=2 test=false`: the profile as cargo reported it.
    triple*: string
      ## The target triple, empty for a host build (no `--target`).
    rustcFingerprint*: string
      ## The `rustc` field of the unit's cargo fingerprint, which cargo
      ## derives from `rustc -vV`; empty if it could not be read. Two units
      ## with different values were built by different toolchains.
    fresh*: bool

  LiveSet* = object
    ## Everything one cargo invocation used.
    id*: string
      ## Orders sets: the recording time in nanoseconds, zero padded, and the
      ## recording process id. Also the file name in the store.
    recordedAt*: int64
      ## Unix seconds.
    units*: seq[LiveUnit]

  GcConfig* = object
    keepSets*: int
    minAgeSeconds*: int64
    dryRun*: bool

  ConfigSource* = enum
    csDefault = "default", csUserConfig = "user config",
        csEnvironment = "environment",
    csFlag = "flag"

  GcBusyError* = object of CatchableError
    ## A cargo build (or another janitor) holds a target-directory lock.
    lockPath*: string

  GcSetupError* = object of CatchableError
    ## The target directory is not something the janitor may operate on.

proc defaultGcConfig*(): GcConfig =
  GcConfig(keepSets: DefaultKeepSets, minAgeSeconds: DefaultMinAgeSeconds,
    dryRun: false)

proc toSlash*(path: string): string =
  ## Forward-slash form, so keys are identical on every platform.
  path.replace('\\', '/')

proc isLowerHex*(text: string): bool =
  if text.len == 0: return false
  for c in text:
    if c notin {'0'..'9', 'a'..'f'}: return false
  true

proc isUnitHash*(text: string): bool =
  text.len == UnitHashLen and text.isLowerHex

proc storeDir*(targetDir: string): string = targetDir / StoreDirName
