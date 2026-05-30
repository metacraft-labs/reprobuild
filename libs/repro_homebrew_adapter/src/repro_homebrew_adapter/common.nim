## Shared helpers for the macOS Homebrew adapter — backs both the
## `pkg.homebrewFormula` and `pkg.homebrewCask` drivers (the M83 step 9
## migration backends).
##
## Both backends shell out to the same `brew` CLI but with different
## flags: formulae use `brew install <name>`, casks use `brew install
## --cask <name>`. The verbs (`list`, `install`, `uninstall`) and the
## query shape (`brew list --versions <name>`) are otherwise symmetric,
## so we centralize:
##
##   * Brew binary discovery — honors `REPRO_HOMEBREW_BREW_BINARY`
##     (an absolute path test seam) before falling back to PATH search
##     for `brew`. Mirrors the Scoop adapter's
##     `REPROBUILD_SCOOP_BINARY` shape — same seam name pattern, same
##     fail-open-to-PATH behaviour.
##
##   * Brew prefix lookup (`brew --prefix`). The realized prefix is
##     a host-derived path (`/usr/local` on Intel macOS,
##     `/opt/homebrew` on Apple Silicon, anywhere the user installed
##     the tarball). The adapter records this so the cross-platform
##     test path can mock it via `REPRO_HOMEBREW_PREFIX`.
##
##   * Pure name validation: a Homebrew package name (formula or
##     cask) is a lowercase identifier matching `[a-z0-9][a-z0-9._+-]*`.
##     This is the defence-in-depth layer 1 (the drivers also
##     `quoteShell` every interpolated field as layer 2).
##
##   * Pure version-string parsing of `brew list --versions <name>`
##     output. The line is either empty (not installed) or starts
##     with the formula name followed by one or more version tokens
##     separated by whitespace. We return the FIRST token (the
##     primary keg/cask version Homebrew reports).
##
## Everything here is PURE EXCEPT the platform-bound `brewBinary` /
## `brewPrefix` helpers, which read env vars and run shell-outs. The
## binary-name / argv composers are pure and exercised on every
## platform by the smoke suite.

import std/[os, osproc, strutils]

const
  BrewBinaryEnvVar* = "REPRO_HOMEBREW_BREW_BINARY"
    ## Test seam: an absolute path to a `brew` binary stub. When set
    ## AND the file exists, `brewBinary()` returns it verbatim. The
    ## sandboxed-fixture test suite uses this to drive the adapter
    ## without a real Homebrew install. Same shape as the Scoop
    ## adapter's `REPROBUILD_SCOOP_BINARY` seam.

  BrewPrefixEnvVar* = "REPRO_HOMEBREW_PREFIX"
    ## Test seam: an absolute path returned in lieu of running
    ## `brew --prefix`. Lets cross-platform tests assert on the
    ## prefix without a real Homebrew install.

  HomebrewAbsentVersion* = ""
    ## The version sentinel `brew list --versions <name>` returns
    ## (an empty line) when `<name>` is not installed. The pure
    ## parser maps any unparseable output to this sentinel.

# ---------------------------------------------------------------------------
# Pure: name validation (defence-in-depth layer 1).
# ---------------------------------------------------------------------------

proc isSafeHomebrewName*(name: string): bool =
  ## A Homebrew package name (formula or cask) must be lowercase and
  ## match `[a-z0-9][a-z0-9._+@-]*`. The `@` is allowed (and common)
  ## because versioned-formula taps like `node@18`, `python@3.11`,
  ## `openssl@3` embed it. Rejecting anything else closes the
  ## shell-injection surface (defence-in-depth layer 1; the drivers
  ## also `quoteShell` the name as layer 2) and aligns with
  ## Homebrew's own naming conventions (Homebrew rejects formulae
  ## with uppercase letters or spaces at audit time).
  if name.len == 0:
    return false
  let first = name[0]
  if first notin {'a'..'z', '0'..'9'}:
    return false
  for ch in name:
    if ch notin {'a'..'z', '0'..'9', '.', '_', '+', '-', '@'}:
      return false
  return true

proc isSafeHomebrewArg*(arg: string): bool =
  ## Conservative allowlist for the `args` extra-flag list. Homebrew
  ## install flags are all `--flag` or `--flag=value` (e.g.
  ## `--build-from-source`, `--HEAD`, `--ignore-dependencies`). Any
  ## shell metacharacter, whitespace, or control byte is rejected
  ## here so the apply path never interpolates an attacker-controlled
  ## argv element into the brew command line.
  if arg.len == 0:
    return false
  for ch in arg:
    if ch in {';', '&', '|', '$', '`', '\\', '"', '\'', '<', '>',
              '(', ')', '{', '}', '[', ']', '*', '?', '~', '!', '#',
              '\n', '\r', '\t', ' '}:
      return false
    if ord(ch) < 0x20:
      return false
  return true

# ---------------------------------------------------------------------------
# Pure: `brew list --versions <name>` output parsing.
# ---------------------------------------------------------------------------

proc parseBrewVersionsLine*(output: string): string =
  ## `brew list --versions <name>` emits either:
  ##   * nothing (exit 1, package not installed), or
  ##   * `<name> <version1> [<version2> ...]` on a single line.
  ##
  ## Return the FIRST version token. Empty input or input that fails
  ## to match the shape returns `HomebrewAbsentVersion` so callers
  ## can treat "no output" and "unparseable output" identically.
  let stripped = output.strip()
  if stripped.len == 0:
    return HomebrewAbsentVersion
  # The first line carries the result (homebrew sometimes prints
  # extra diagnostic lines after; we ignore them).
  var firstLine = stripped
  let nl = stripped.find('\n')
  if nl >= 0:
    firstLine = stripped[0 ..< nl].strip()
  if firstLine.len == 0:
    return HomebrewAbsentVersion
  # Split on whitespace; first token is the formula/cask name, the
  # remaining tokens are versions. We accept "name v1 v2 ..." and
  # also "v1 v2 ..." (a defensive fallback for any future Homebrew
  # output shape that drops the name prefix).
  let parts = firstLine.splitWhitespace()
  if parts.len == 0:
    return HomebrewAbsentVersion
  if parts.len == 1:
    # Single token: could be either the name (no versions known) or
    # a bare version. Treat as bare version when it does not match
    # the safe-name charset (i.e. carries a `.` digit-prefix and so
    # is unambiguously a version like `1.2.3`); otherwise treat as
    # the name with no installed versions => absent.
    let t = parts[0]
    if t.len > 0 and t[0] in {'0'..'9'}:
      return t
    return HomebrewAbsentVersion
  # First token is the name; second is the primary version.
  parts[1]

# ---------------------------------------------------------------------------
# Pure: argv composition.
# ---------------------------------------------------------------------------

proc composeListArgs*(isCask: bool; name: string): seq[string] =
  ## `brew list [--cask | --formula] --versions <name>` — the safe
  ## query shape. `--versions` makes the output deterministic across
  ## Homebrew versions (older versions printed only the name on a hit;
  ## modern Homebrew always prints `name version`).
  result = @["list"]
  if isCask:
    result.add("--cask")
  else:
    result.add("--formula")
  result.add("--versions")
  result.add(name)

proc composeInstallArgs*(isCask: bool; name: string;
                         extraArgs: openArray[string]): seq[string] =
  ## `brew install [--cask] [extra-args ...] <name>`. The user's
  ## extra args land BEFORE the name so flags like
  ## `--build-from-source` (formula) or `--no-quarantine` (cask)
  ## attach to the install verb rather than the package name. The
  ## caller must have validated each extra arg via
  ## `isSafeHomebrewArg`.
  result = @["install"]
  if isCask:
    result.add("--cask")
  for a in extraArgs:
    result.add(a)
  result.add(name)

proc composeUninstallArgs*(isCask: bool; name: string): seq[string] =
  ## `brew uninstall [--cask] <name>`. No `--force` — the destroy
  ## path is conservative; if a dependency or pinned state blocks
  ## removal the operator must resolve it explicitly.
  result = @["uninstall"]
  if isCask:
    result.add("--cask")
  result.add(name)

proc composeBrewCommand*(brewExe: string; argv: openArray[string]): string =
  ## Assemble the shell command line. Every component is `quoteShell`'d
  ## so an argv element with whitespace (defensively — the validator
  ## already refuses such names) is still passed as a single argument.
  result = quoteShell(brewExe)
  for a in argv:
    result.add(' ')
    result.add(quoteShell(a))

# ---------------------------------------------------------------------------
# Platform-bound helpers (brew discovery + prefix lookup).
# ---------------------------------------------------------------------------

proc brewBinary*(): string =
  ## Discover the `brew` executable. Preference order:
  ##   1. `$REPRO_HOMEBREW_BREW_BINARY` (absolute path; test seam).
  ##   2. `findExe("brew")` (PATH lookup).
  ## Returns `""` when no brew is reachable; callers raise a
  ## structured error.
  let override = getEnv(BrewBinaryEnvVar)
  if override.len > 0 and fileExists(override):
    return override
  findExe("brew")

proc brewPrefix*(brewExe: string): string =
  ## Run `brew --prefix` to discover the install prefix. Returns the
  ## empty string when the lookup fails (caller decides whether that's
  ## fatal). The test seam `$REPRO_HOMEBREW_PREFIX` short-circuits
  ## the shell-out.
  let override = getEnv(BrewPrefixEnvVar)
  if override.len > 0:
    return override
  if brewExe.len == 0:
    return ""
  let (output, exitCode) = execCmdEx(
    composeBrewCommand(brewExe, ["--prefix"]))
  if exitCode != 0:
    return ""
  output.strip()
