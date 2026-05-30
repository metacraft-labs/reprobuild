## `vscode.extension` driver — declarative VS Code extension set.
##
## The driver manages a SET of marketplace extension IDs (`ms-python.
## python`, `vscodevim.vim`, ...) installed via the `code` CLI:
##   * `code --list-extensions --show-versions` — observe the live set.
##   * `code --install-extension <id>` — install a missing extension.
##   * `code --uninstall-extension <id>` — uninstall an unwanted one.
##
## Lifecycle: ensures every declared extension is installed; if
## `removeUnknown == true`, also uninstalls any extension NOT in the
## desired set (strict declarative set semantics). When
## `removeUnknown == false` (the default), the resource only OWNS its
## declared subset and leaves any other extension installed by the
## user alone — the canonical observed set is the INTERSECTION of
## (installed ∩ desired), so a cache-hit means "every desired
## extension is installed" regardless of extras.
##
## Optional `@<version>` pin: `vscodevim.vim@1.27.0`. When omitted
## the driver installs whatever the marketplace serves at apply time
## and accepts any installed version as matching. When present, the
## pin participates in the canonical digest so a version drift
## triggers a reinstall.
##
## Cross-platform: the `code` CLI resolves the same way on Windows,
## Linux, and macOS — it is the marketplace's official interface. On
## a host where `code` is not on PATH the driver returns an absent
## observation (the resource will plan as `create` — VS Code itself
## is expected to be installed by a preceding profile resource or by
## the operator).

import std/[algorithm, os, osproc, sets, strutils]

import repro_home_generations

import ./../manifest_record
import ./../types

# ---------------------------------------------------------------------------
# Extension ID + version-pin parsing.
# ---------------------------------------------------------------------------

type
  ExtensionSpec* = object
    ## A parsed extension declaration. `id` is the marketplace ID
    ## (e.g. `vscodevim.vim`); `pinnedVersion` is the optional `@<v>`
    ## pin (empty string when unpinned).
    id*: string
    pinnedVersion*: string

proc isSafeExtensionId*(id: string): bool =
  ## True for an extension ID + optional version pin in the conservative
  ## charset the marketplace uses: letters, digits, `.`, `-`, `_`, and
  ## a single `@<version>` suffix where the version is the same
  ## charset plus `.`. A value with shell metacharacters is refused
  ## outright so it cannot escape the `code` CLI argument list.
  let s = id.strip()
  if s.len == 0:
    return false
  for ch in s:
    if ch notin {'A'..'Z', 'a'..'z', '0'..'9', '.', '-', '_', '@'}:
      return false
  # At most one `@` (the version pin separator).
  if s.count('@') > 1:
    return false
  return true

proc parseExtensionSpec*(raw: string): ExtensionSpec =
  ## Split a `name@version` declaration into its (id, version) pair.
  ## A spec without `@` yields an empty `pinnedVersion`.
  let s = raw.strip()
  let at = s.find('@')
  if at < 0:
    result.id = s
    result.pinnedVersion = ""
  else:
    result.id = s[0 ..< at]
    result.pinnedVersion = s[at + 1 .. ^1]

# ---------------------------------------------------------------------------
# `code --list-extensions --show-versions` output parsing.
#
# Output shape:
#   ms-python.python@2024.0.1
#   vscodevim.vim@1.27.0
# One extension per line; trailing CRLF stripped. Empty lines and
# `#`-style comments (some downstream wrappers emit them) are skipped.
# ---------------------------------------------------------------------------

proc parseCodeListExtensions*(rawOutput: string): seq[ExtensionSpec] =
  ## Parse the deterministic line-oriented output of
  ## `code --list-extensions --show-versions`. Returns the parsed
  ## ExtensionSpecs sorted by ID so two observations of the same live
  ## state are byte-equal.
  for line in rawOutput.splitLines():
    let t = line.strip()
    if t.len == 0 or t.startsWith("#"):
      continue
    # Defensive: a line that does not look like an extension ID (e.g.
    # an `code` CLI warning written to stdout in some builds) is
    # skipped rather than failing the parse.
    if not isSafeExtensionId(t):
      continue
    result.add(parseExtensionSpec(t))
  result.sort do (a, b: ExtensionSpec) -> int:
    cmp(a.id, b.id)

# ---------------------------------------------------------------------------
# Canonical-state digest.
#
# The canonical form is a deterministic line-oriented rendering of the
# extension set, sorted by ID. When a version pin is declared the pin
# participates; an unpinned desired entry matches any installed
# version of the same ID.
# ---------------------------------------------------------------------------

proc canonicalExtensionSet*(specs: openArray[ExtensionSpec]): string =
  ## Sorted line-oriented rendering of an extension set. An empty
  ## input yields the empty string.
  var copy: seq[ExtensionSpec]
  for s in specs:
    copy.add(s)
  copy.sort do (a, b: ExtensionSpec) -> int:
    cmp(a.id, b.id)
  for s in copy:
    if s.pinnedVersion.len > 0:
      result.add(s.id & "@" & s.pinnedVersion)
    else:
      result.add(s.id)
    result.add("\n")

proc parseDesiredExtensions*(desired: openArray[string]): seq[ExtensionSpec] =
  ## Parse a list of marketplace declarations (each `name` or
  ## `name@version`) into their typed `ExtensionSpec` forms.
  for raw in desired:
    result.add(parseExtensionSpec(raw))

# ---------------------------------------------------------------------------
# Observed-canonical computation.
#
# The driver's canonical-observed depends on the lifecycle policy:
#   * `removeUnknown = true`: the full installed set is the observed
#     canonical (extras are drift).
#   * `removeUnknown = false`: only the SUBSET of installed extensions
#     that match a desired ID is the observed canonical (extras the
#     user installed out-of-band do not register as drift).
# ---------------------------------------------------------------------------

proc observedCanonical*(installed, desired: openArray[ExtensionSpec];
                        removeUnknown: bool): string =
  ## Compute the canonical observed-state string against the desired
  ## set and the `removeUnknown` policy. The returned string is the
  ## input to BLAKE3 over the resource's `payloadBytes`.
  if removeUnknown:
    return canonicalExtensionSet(installed)
  # Subset semantics: filter the installed list down to the desired
  # IDs. For unpinned desired entries, keep the installed-version
  # spelling but record under the desired form (no pin) so a cache-hit
  # compares equal across version bumps. For pinned desired entries,
  # keep the live pin (a version mismatch becomes drift).
  var desiredIdsUnpinned: HashSet[string]
  var desiredIdsPinned: HashSet[string]
  for d in desired:
    if d.pinnedVersion.len > 0:
      desiredIdsPinned.incl(d.id)
    else:
      desiredIdsUnpinned.incl(d.id)
  var kept: seq[ExtensionSpec]
  for i in installed:
    if i.id in desiredIdsPinned:
      kept.add(i)                      # pinned: keep the live version
    elif i.id in desiredIdsUnpinned:
      kept.add(ExtensionSpec(id: i.id, pinnedVersion: ""))
        # unpinned: drop the version so a version bump is not drift
  return canonicalExtensionSet(kept)

# ---------------------------------------------------------------------------
# `code` CLI resolution + shell-out helpers.
# ---------------------------------------------------------------------------

proc findCodeCli*(): string =
  ## Locate the `code` CLI on PATH. Returns the absolute path or "" if
  ## the CLI cannot be found. On Windows the binary is `code.cmd`; on
  ## POSIX it is `code`. We probe both forms so the driver works under
  ## any vendor-specific layout.
  for cand in ["code", "code.cmd"]:
    let p = findExe(cand)
    if p.len > 0:
      return p
  return ""

# ---------------------------------------------------------------------------
# Observation.
# ---------------------------------------------------------------------------

proc digestOfText(text: string): Digest256 =
  var buf = newSeq[byte](text.len)
  for i, ch in text:
    buf[i] = byte(ord(ch))
  digestOfBytes(buf)

proc observeVscodeExtensions*(desired: openArray[string];
                              removeUnknown: bool): ObservedState =
  ## Observe the current set of installed VS Code extensions via
  ## `code --list-extensions --show-versions` and compute the canonical
  ## observed form against the desired set. `present` is true when the
  ## `code` CLI is on PATH and returns exit 0; an unavailable CLI
  ## yields an absent observation (the resource will plan as `create`).
  let cli = findCodeCli()
  if cli.len == 0:
    result.present = false
    result.digest = zeroDigest()
    return
  let (output, code) = execCmdEx(quoteShell(cli) &
    " --list-extensions --show-versions")
  if code != 0:
    result.present = false
    result.digest = zeroDigest()
    return
  let installed = parseCodeListExtensions(output)
  let want = parseDesiredExtensions(desired)
  let canon = observedCanonical(installed, want, removeUnknown)
  result.present = true
  result.rawBytes = newSeq[byte](canon.len)
  for i, ch in canon:
    result.rawBytes[i] = byte(ord(ch))
  result.digest = digestOfText(canon)

# ---------------------------------------------------------------------------
# Apply.
# ---------------------------------------------------------------------------

proc applyVscodeExtensions*(desired: openArray[string];
                            removeUnknown: bool): seq[byte] =
  ## Reconcile the live set of installed extensions to the desired
  ## set. Returns the recorded payload bytes (the canonical-observed
  ## rendering after the apply) so the manifest record is complete.
  ##
  ## POST-APPLY RE-PROBE (M82 Phase A contract): the apply re-observes
  ## after each install/uninstall and asserts the final canonical
  ## matches the desired canonical. A genuine mismatch raises `IOError`
  ## naming the unresolved extensions.
  let cli = findCodeCli()
  if cli.len == 0:
    raise newException(IOError,
      "vscode.extension: the `code` CLI is not on PATH; install VS Code " &
      "before declaring this resource (the apply pipeline expects a " &
      "preceding `vscode` package or a host-level install)")
  let want = parseDesiredExtensions(desired)
  let (initOutput, initCode) = execCmdEx(quoteShell(cli) &
    " --list-extensions --show-versions")
  if initCode != 0:
    raise newException(IOError,
      "vscode.extension: `code --list-extensions` failed: " &
      initOutput.strip())
  let initialInstalled = parseCodeListExtensions(initOutput)
  var installedIds: HashSet[string]
  var installedById: seq[ExtensionSpec]
  for spec in initialInstalled:
    installedIds.incl(spec.id)
    installedById.add(spec)
  # Install missing-from-desired.
  for d in want:
    if d.id notin installedIds:
      let arg =
        if d.pinnedVersion.len > 0: d.id & "@" & d.pinnedVersion
        else: d.id
      let (output, code) = execCmdEx(quoteShell(cli) &
        " --install-extension " & quoteShell(arg))
      if code != 0:
        raise newException(IOError,
          "vscode.extension: `code --install-extension " & arg &
          "` failed: " & output.strip())
    elif d.pinnedVersion.len > 0:
      # The extension is installed; verify the version matches the
      # pin. A mismatch reinstalls at the pinned version.
      var currentVersion = ""
      for spec in installedById:
        if spec.id == d.id:
          currentVersion = spec.pinnedVersion
          break
      if currentVersion != d.pinnedVersion:
        let arg = d.id & "@" & d.pinnedVersion
        let (output, code) = execCmdEx(quoteShell(cli) &
          " --install-extension " & quoteShell(arg))
        if code != 0:
          raise newException(IOError,
            "vscode.extension: `code --install-extension " & arg &
            "` (version pin update) failed: " & output.strip())
  # Optionally uninstall extras.
  if removeUnknown:
    var desiredIds: HashSet[string]
    for d in want:
      desiredIds.incl(d.id)
    for spec in initialInstalled:
      if spec.id notin desiredIds:
        let (output, code) = execCmdEx(quoteShell(cli) &
          " --uninstall-extension " & quoteShell(spec.id))
        if code != 0:
          raise newException(IOError,
            "vscode.extension: `code --uninstall-extension " & spec.id &
            "` failed: " & output.strip())
  # Post-apply re-probe.
  let (postOutput, postCode) = execCmdEx(quoteShell(cli) &
    " --list-extensions --show-versions")
  if postCode != 0:
    raise newException(IOError,
      "vscode.extension: post-apply `code --list-extensions` failed: " &
      postOutput.strip())
  let finalInstalled = parseCodeListExtensions(postOutput)
  let canon = observedCanonical(finalInstalled, want, removeUnknown)
  let desiredCanon = canonicalExtensionSet(want)
  if canon != desiredCanon:
    var missing: seq[string]
    var finalIds: HashSet[string]
    for spec in finalInstalled:
      finalIds.incl(spec.id)
    for d in want:
      if d.id notin finalIds:
        missing.add(d.id)
    raise newException(IOError,
      "vscode.extension: post-apply observation disagrees with desired " &
      "state. The `code --install-extension` calls returned exit 0 but " &
      "the live set does not reflect the change. Missing extensions: " &
      missing.join(", "))
  result = newSeq[byte](canon.len)
  for i, ch in canon:
    result[i] = byte(ord(ch))

# ---------------------------------------------------------------------------
# Destroy.
# ---------------------------------------------------------------------------

proc destroyVscodeExtensions*(declared: openArray[string]) =
  ## Uninstall every extension the resource declared (the destroy
  ## direction). Other extensions the user installed out-of-band are
  ## left alone — destroy is symmetric to the resource's ownership
  ## boundary. A `code` CLI not on PATH is a no-op (nothing to
  ## destroy).
  let cli = findCodeCli()
  if cli.len == 0:
    return
  for raw in declared:
    let spec = parseExtensionSpec(raw)
    if spec.id.len == 0:
      continue
    discard execCmd(quoteShell(cli) &
      " --uninstall-extension " & quoteShell(spec.id))
