## `pkg.homebrewFormula` driver — M83 step 9 Driver A.
##
## Wraps the `brew install` / `brew list --versions` / `brew uninstall`
## CLI for Homebrew CLI formulae on macOS. Per-user (Homebrew installs
## under `/usr/local` on Intel or `/opt/homebrew` on Apple Silicon —
## both are user-writable for the owning account; no `sudo`).
##
## Per the spec ("`pkg.homebrewFormula`"):
##   - observe:   `brew list --formula --versions <name>` — empty
##                output (or exit != 0) means absent; non-empty
##                output's second whitespace-separated token is the
##                installed version.
##   - apply:     `brew install [args...] <name>` when absent;
##                `brew upgrade <name>` when installed at a different
##                version (Homebrew's version pinning is awkward —
##                see the limitations note below).
##   - destroy:   `brew uninstall <name>`.
##
## ## Versioning limitations
##
## Homebrew's version model is "latest-from-the-tap": a formula in a
## tap declares ONE version and `brew install <name>` always selects
## that version. Pinning to a specific version requires either a
## `<name>@<version>` versioned-formula tap (e.g. `node@18`, `python@3.11`)
## OR an out-of-band `brew extract` + custom tap. We support the
## versioned-formula tap case naturally — the operator declares
## `name = "node@18"` and Homebrew handles the rest — but the driver
## does NOT attempt to pin an arbitrary version against a non-versioned
## tap. If `version` is non-empty and different from the installed
## version, the driver issues `brew upgrade <name>`; the formula's
## tap then determines what version is installed. An explicit
## `version` mismatch that cannot be satisfied surfaces as drift
## (observed != desired) on the next observation pass.
##
## ## Platform binding
##
## The `when defined(macosx)` branch shells out; every other platform
## raises `ENotImplementedPlatform("pkg.homebrewFormula", "macosx")`.
## Fail-closed: NOT a silent no-op.
##
## ## Pure logic for off-macOS unit testing
##
## `canonicalHomebrewFormulaBytes` (the digest-input encoder) is a
## pure function exercised on every platform. The argv composers
## (`composeInstallArgs`, `composeUninstallArgs`, `composeListArgs`)
## live in `./common.nim` and are also pure.

when defined(macosx):
  import std/[osproc, strutils]
  import repro_home_resources/manifest_record  # digestOfBytes/zeroDigest

import repro_home_resources/errors
import repro_home_resources/types

import ./common

export common

const HomebrewFormulaKind* = "pkg.homebrewFormula"
  ## The string form of the resource kind. The parser, the validation
  ## layer, the lifecycle digest, and the apply dispatcher all match
  ## against this constant.

# ---------------------------------------------------------------------------
# Canonical-bytes derivation (pure).
# ---------------------------------------------------------------------------

proc canonicalHomebrewFormulaBytes*(name, version: string): seq[byte] =
  ## The canonical byte sequence the digest covers. The desired-state
  ## identity for a Homebrew formula is the (name, version) pair —
  ## the name pins which package is installed, the version (possibly
  ## empty, meaning "track the tap's latest") pins which version is
  ## acceptable.
  ##
  ## Symmetry contract: when `version` is empty the encoded form is
  ## `name + 0x1e` (no version bytes), and `observeHomebrewFormula`
  ## passed `desiredVersion = ""` ALSO emits `name + 0x1e` — so a
  ## desired `formulaVersion = ""` (track-latest) cache-hits against
  ## ANY installed version. When `version` is non-empty, the encoded
  ## form is `name + 0x1e + version`, and observe emits the literal
  ## installed-version bytes — a version mismatch then flips the
  ## digest and the lifecycle plans `update`.
  ##
  ## The 0x1e (record separator) byte cannot appear in either field
  ## (`isSafeHomebrewName` rejects it on name; version comes from
  ## `brew list --versions` which never emits control bytes), so the
  ## boundary is unambiguous.
  let combined = name & "\x1e" & version
  result = newSeq[byte](combined.len)
  for i, ch in combined:
    result[i] = byte(ord(ch))

# ---------------------------------------------------------------------------
# Driver entry points (platform-bound shell-out).
# ---------------------------------------------------------------------------

proc observeHomebrewFormula*(name, desiredVersion: string): ObservedState =
  ## `brew list --formula --versions <name>`. Exit != 0 = absent;
  ## exit 0 with empty output = absent (defensive); exit 0 with
  ## non-empty output = present at the parsed first-version token.
  ##
  ## The encoded bytes mirror `canonicalHomebrewFormulaBytes(name,
  ## v)` where `v` is the OBSERVED version when `desiredVersion` is
  ## non-empty (so a version-pin mismatch surfaces as drift) AND
  ## the EMPTY string when `desiredVersion` is empty (so a
  ## track-latest desired cache-hits against any installed
  ## version). The desired-side `digestOfResource` encodes
  ## `(name, desiredVersion)`; this symmetry produces equal digests
  ## exactly when the lifecycle should report a cache-hit.
  when defined(macosx):
    let brewExe = brewBinary()
    if brewExe.len == 0:
      # No brew on PATH and no override set — treat as absent. A
      # subsequent apply will raise EResourceDriver naming the missing
      # binary, so the operator gets a clean diagnostic instead of a
      # silent no-op.
      result.present = false
      result.digest = zeroDigest()
      return
    let argv = composeListArgs(isCask = false, name = name)
    let (output, exitCode) = execCmdEx(composeBrewCommand(brewExe, argv))
    if exitCode != 0:
      result.present = false
      result.digest = zeroDigest()
      return
    let installedVersion = parseBrewVersionsLine(output)
    if installedVersion == HomebrewAbsentVersion:
      result.present = false
      result.digest = zeroDigest()
      return
    let encodedVersion =
      if desiredVersion.len == 0: "" else: installedVersion
    let raw = canonicalHomebrewFormulaBytes(name, encodedVersion)
    result.present = true
    result.rawBytes = raw
    result.digest = digestOfBytes(raw)
  else:
    raiseNotImplementedPlatform(HomebrewFormulaKind, "macosx")

proc applyHomebrewFormula*(name, desiredVersion: string;
                           extraArgs: openArray[string]): seq[byte] =
  ## `brew install [args...] <name>` when the formula is not
  ## installed; `brew upgrade <name>` when installed at a different
  ## version (or unconditionally when `desiredVersion` is empty and
  ## the operator wants the tap's latest — but that case is the
  ## cache-hit no-op above, so we only reach this path on a real
  ## delta).
  ##
  ## Returns the post-write canonical bytes (the (name, observed-version)
  ## pair AFTER the install) so the manifest record carries the
  ## actual installed version, not the desired one.
  when defined(macosx):
    let brewExe = brewBinary()
    if brewExe.len == 0:
      raiseResourceDriver("homebrew:formula:" & name, HomebrewFormulaKind,
        "brew",
        "no brew binary found on PATH or via $" & BrewBinaryEnvVar)
    # First, read the current installed version (if any). This drives
    # the install-vs-upgrade decision.
    let listArgv = composeListArgs(isCask = false, name = name)
    let (listOutput, listExit) = execCmdEx(
      composeBrewCommand(brewExe, listArgv))
    let installedVersion =
      if listExit == 0: parseBrewVersionsLine(listOutput)
      else: HomebrewAbsentVersion
    let isInstalled = installedVersion != HomebrewAbsentVersion
    let needUpgrade = isInstalled and desiredVersion.len > 0 and
      installedVersion != desiredVersion
    let argv =
      if not isInstalled:
        composeInstallArgs(isCask = false, name = name,
          extraArgs = extraArgs)
      elif needUpgrade:
        # `brew upgrade <name>` — Homebrew picks the tap's latest;
        # see the module-level "Versioning limitations" note.
        @["upgrade", name]
      else:
        # Already installed at a satisfying version — should have
        # taken the cache-hit no-op upstream. Defensive: run a no-op
        # `brew list --versions` so the post-write observation below
        # still works.
        composeListArgs(isCask = false, name = name)
    let (output, exitCode) = execCmdEx(
      composeBrewCommand(brewExe, argv))
    if exitCode != 0:
      raiseResourceDriver("homebrew:formula:" & name,
        HomebrewFormulaKind, "brew " & argv[0],
        "exit " & $exitCode & ": " & output.strip())
    # Re-observe to record the actually-installed version.
    let (postOutput, postExit) = execCmdEx(
      composeBrewCommand(brewExe, listArgv))
    let postVersion =
      if postExit == 0: parseBrewVersionsLine(postOutput)
      else: desiredVersion
    result = canonicalHomebrewFormulaBytes(name, postVersion)
  else:
    raiseNotImplementedPlatform(HomebrewFormulaKind, "macosx")

proc destroyHomebrewFormula*(name: string) =
  ## `brew uninstall <name>`. Tolerates non-zero exit (a formula
  ## already absent is the common destroy case; only the final
  ## state matters). Does NOT use `--force` — the operator must
  ## explicitly resolve dependency conflicts.
  when defined(macosx):
    let brewExe = brewBinary()
    if brewExe.len == 0:
      # No brew on PATH — nothing to do. A formula cannot be
      # installed via a brew we cannot reach, so treating this as a
      # silent no-op is correct for the destroy direction.
      return
    let argv = composeUninstallArgs(isCask = false, name = name)
    discard execCmd(composeBrewCommand(brewExe, argv))
  else:
    raiseNotImplementedPlatform(HomebrewFormulaKind, "macosx")
