## `pkg.homebrewCask` driver — M83 step 9 Driver B.
##
## Wraps the `brew install --cask <name>` / `brew list --cask
## --versions <name>` / `brew uninstall --cask <name>` CLI for
## Homebrew Casks on macOS. Casks deliver GUI/binary applications
## (e.g. `iterm2`, `firefox`, `visual-studio-code`, `docker`) that
## install primarily under `/Applications/` rather than under the
## Homebrew prefix's `bin/`. Per-user; the driver runs unelevated
## as the owning account of the Homebrew install.
##
## Per the spec ("`pkg.homebrewCask`"):
##   - observe:   `brew list --cask --versions <name>` — empty
##                output (or exit != 0) means absent; non-empty
##                output's second whitespace-separated token is the
##                installed version.
##   - apply:     `brew install --cask [args...] <name>` when
##                absent. Cask version reconciliation is even more
##                limited than formula reconciliation: most casks
##                track LATEST only (Homebrew's cask DSL does not
##                model multiple historical versions). When a
##                mismatch is observed the driver issues
##                `brew upgrade --cask <name>` — Homebrew's tap
##                then determines the new version.
##   - destroy:   `brew uninstall --cask <name>`.
##
## ## Versioning limitations
##
## Casks generally do NOT support arbitrary version pinning.
## Homebrew's cask DSL ships ONE version per cask in the tap; some
## casks ship versioned variants under separate names (`firefox`
## vs. `firefox@developer-edition`, etc.) but otherwise the latest
## tap-declared version is what `brew install --cask` produces. A
## profile that sets `version` to a value that does not match the
## tap's declared version will plan an `update` on every apply
## (the digest mismatches and `brew upgrade` runs); operators
## should typically leave `version` empty for casks unless the
## tap genuinely has multi-version support.
##
## ## Platform binding
##
## The `when defined(macosx)` branch shells out; every other
## platform raises `ENotImplementedPlatform("pkg.homebrewCask",
## "macosx")`. Fail-closed: NOT a silent no-op.
##
## ## Pure logic for off-macOS unit testing
##
## `canonicalHomebrewCaskBytes` (the digest-input encoder) is a
## pure function exercised on every platform. The argv composers
## (`composeInstallArgs`, `composeUninstallArgs`,
## `composeListArgs`) live in `./common.nim` and are also pure;
## they take an `isCask` flag so formula and cask share one set of
## composers.

when defined(macosx):
  import std/[osproc, strutils]
  import repro_home_resources/manifest_record  # digestOfBytes/zeroDigest
  import ./common  # brewBinary / composeListArgs / parseBrewVersionsLine

import repro_home_resources/errors
import repro_home_resources/types

const HomebrewCaskKind* = "pkg.homebrewCask"
  ## The string form of the resource kind. The parser, the
  ## validation layer, the lifecycle digest, and the apply
  ## dispatcher all match against this constant.

# ---------------------------------------------------------------------------
# Canonical-bytes derivation (pure).
# ---------------------------------------------------------------------------

proc canonicalHomebrewCaskBytes*(name, version: string): seq[byte] =
  ## The canonical byte sequence the digest covers. The desired-
  ## state identity for a Homebrew cask is the (name, version) pair
  ## — the name pins which cask is installed, the version
  ## (typically empty, since most casks track LATEST only) pins
  ## which version is acceptable.
  ##
  ## Symmetry contract: identical to the formula driver. When
  ## `version` is empty the encoded form is `name + 0x1e` (no
  ## version bytes), and `observeHomebrewCask` passed
  ## `desiredVersion = ""` ALSO emits `name + 0x1e` — so a desired
  ## `caskVersion = ""` (track-latest) cache-hits against ANY
  ## installed version. When `version` is non-empty, the encoded
  ## form is `name + 0x1e + version`, and observe emits the literal
  ## installed-version bytes — a version mismatch then flips the
  ## digest and the lifecycle plans `update`.
  ##
  ## The 0x1e (record separator) byte cannot appear in either
  ## field (`isSafeHomebrewName` rejects it on the name; version
  ## comes from `brew list --versions` which never emits control
  ## bytes), so the boundary is unambiguous.
  let combined = name & "\x1e" & version
  result = newSeq[byte](combined.len)
  for i, ch in combined:
    result[i] = byte(ord(ch))

# ---------------------------------------------------------------------------
# Driver entry points (platform-bound shell-out).
# ---------------------------------------------------------------------------

proc observeHomebrewCask*(name, desiredVersion: string): ObservedState =
  ## `brew list --cask --versions <name>`. Exit != 0 = absent;
  ## exit 0 with empty output = absent (defensive); exit 0 with
  ## non-empty output = present at the parsed first-version token.
  ##
  ## The encoded bytes mirror `canonicalHomebrewCaskBytes(name, v)`
  ## where `v` is the OBSERVED version when `desiredVersion` is
  ## non-empty (so a version-pin mismatch surfaces as drift) AND
  ## the EMPTY string when `desiredVersion` is empty (so a
  ## track-latest desired cache-hits against any installed version).
  when defined(macosx):
    let brewExe = brewBinary()
    if brewExe.len == 0:
      # No brew on PATH and no override set — treat as absent. A
      # subsequent apply raises EResourceDriver naming the missing
      # binary, so the operator gets a clean diagnostic instead of
      # a silent no-op.
      result.present = false
      result.digest = zeroDigest()
      return
    let argv = composeListArgs(isCask = true, name = name)
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
    let raw = canonicalHomebrewCaskBytes(name, encodedVersion)
    result.present = true
    result.rawBytes = raw
    result.digest = digestOfBytes(raw)
  else:
    raiseNotImplementedPlatform(HomebrewCaskKind, "macosx")

proc applyHomebrewCask*(name, desiredVersion: string;
                       extraArgs: openArray[string]): seq[byte] =
  ## `brew install --cask [args...] <name>` when the cask is not
  ## installed; `brew upgrade --cask <name>` when installed at a
  ## different version. Returns the post-write canonical bytes —
  ## the (name, observed-version) pair AFTER the install — so the
  ## manifest record carries the actual installed version.
  when defined(macosx):
    let brewExe = brewBinary()
    if brewExe.len == 0:
      raiseResourceDriver("homebrew:cask:" & name, HomebrewCaskKind,
        "brew",
        "no brew binary found on PATH or via $" & BrewBinaryEnvVar)
    let listArgv = composeListArgs(isCask = true, name = name)
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
        composeInstallArgs(isCask = true, name = name,
          extraArgs = extraArgs)
      elif needUpgrade:
        @["upgrade", "--cask", name]
      else:
        # Already installed at a satisfying version — should have
        # taken the cache-hit no-op upstream. Defensive: run a
        # no-op `brew list --versions` so the post-write observation
        # below still works.
        composeListArgs(isCask = true, name = name)
    let (output, exitCode) = execCmdEx(
      composeBrewCommand(brewExe, argv))
    if exitCode != 0:
      raiseResourceDriver("homebrew:cask:" & name,
        HomebrewCaskKind, "brew " & argv[0],
        "exit " & $exitCode & ": " & output.strip())
    # Re-observe to record the actually-installed version.
    let (postOutput, postExit) = execCmdEx(
      composeBrewCommand(brewExe, listArgv))
    let postVersion =
      if postExit == 0: parseBrewVersionsLine(postOutput)
      else: desiredVersion
    result = canonicalHomebrewCaskBytes(name, postVersion)
  else:
    raiseNotImplementedPlatform(HomebrewCaskKind, "macosx")

proc destroyHomebrewCask*(name: string) =
  ## `brew uninstall --cask <name>`. Tolerates non-zero exit (a
  ## cask already absent is the common destroy case; only the final
  ## state matters). Does NOT use `--force` — the operator must
  ## explicitly resolve dependency conflicts (rare for casks since
  ## they typically have no dependencies).
  when defined(macosx):
    let brewExe = brewBinary()
    if brewExe.len == 0:
      # No brew on PATH — nothing to do. A cask cannot be installed
      # via a brew we cannot reach, so a silent no-op is correct
      # for the destroy direction.
      return
    let argv = composeUninstallArgs(isCask = true, name = name)
    discard execCmd(composeBrewCommand(brewExe, argv))
  else:
    raiseNotImplementedPlatform(HomebrewCaskKind, "macosx")
