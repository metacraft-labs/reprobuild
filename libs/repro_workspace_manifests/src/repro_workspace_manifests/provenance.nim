## repro_workspace_manifests/provenance.nim
##
## RA-17 — Manifest provenance verification (Workspace-Manifests.md
## §"Manifest Provenance and Verification").
##
## Google's `repo` verifies the manifest repo against signed tags / a known
## key on `repo init` (GPG tag verification). Reprobuild reads manifests as
## plain TOML, so without this module a compromised or MITM'd manifest source
## could redirect every repo's `remote`/`revision` with nothing to detect it.
##
## This module verifies the AUTHENTICITY of a checked-out manifest source
## before the resolver is allowed to trust it:
##
## - **Signed manifest commits/tags.** When the host bootstrap config sets
##   `[verify] require_signature = true`, the manifest source's HEAD commit
##   (or the pinned `[manifest] revision` tag/commit) must carry a VALID
##   signature from a key in the configured allowed-signers set.
## - **Pinned manifest revision.** When `[manifest] revision` is set, the
##   manifest checkout's HEAD must resolve to exactly that commit/tag, so a
##   moved branch can't silently swap the manifest out.
## - **Fail closed when required.** Any failure (unsigned, wrong key, tampered,
##   moved-pin) raises `ManifestProvenanceError` so `init`/refresh refuse
##   rather than proceed. When `require_signature` is false AND no revision is
##   pinned, this module is a no-op — existing flows are entirely unaffected.
##
## Verification uses git's SSH-signature path (`gpg.format=ssh` +
## `gpg.ssh.allowedSignersFile`) via `git verify-commit` / `git verify-tag`.
## That makes it hermetically testable with a generated ed25519 key (no system
## GPG keyring) and gives a working verification story on every platform git
## ships SSH signing on — the cross-platform requirement the spec calls out.

import std/[options, os, osproc, strutils, tempfiles]

import types

type
  ManifestProvenanceError* = object of CatchableError
    ## Raised when a REQUIRED provenance check fails. The caller
    ## (`init`/refresh) must propagate this as a fail-closed refusal.
    manifestPath*: string
      ## The on-disk manifest checkout that failed verification.
    revision*: string
      ## The revision actually verified (HEAD, or the pinned commit/tag).

  ManifestVerifySpec* = object
    ## The resolved trust anchor for one verification run, distilled from the
    ## host bootstrap config (`[manifest] revision` + `[verify]`). Resolved
    ## once (paths made absolute against the config dir) so the verifier never
    ## reaches back into config-relative state.
    requireSignature*: bool
    allowedSignersFile*: string  ## absolute path, or "" if none configured
    inlineKeys*: seq[string]     ## inline allowed-signers lines
    signerIdentity*: string      ## principal to match (defaults below)
    pinnedRevision*: string      ## commit/tag pin, or "" if unpinned

const
  defaultSignerIdentity = "reprobuild@manifest"
    ## The wildcard principal the inline-key path stamps onto generated
    ## allowed-signers entries when the config does not name one. SSH
    ## allowed-signers match by principal; a stable default lets inline keys
    ## work without the operator inventing an identity string.

proc isVerificationActive*(spec: ManifestVerifySpec): bool =
  ## True iff this spec asks for ANY check (signature OR revision pin).
  ## When false, the verifier is a guaranteed no-op and the caller can skip
  ## it entirely — this is the "not configured → unchanged behavior" gate.
  spec.requireSignature or spec.pinnedRevision.len > 0

proc resolveVerifySpec*(cfg: WorkspaceBootstrap; configDir: string):
    ManifestVerifySpec =
  ## Build a `ManifestVerifySpec` from a parsed bootstrap config. `configDir`
  ## is the directory the `.repro-workspace.toml` lives in, used to resolve a
  ## relative `allowed_signers` path. A wildcard signer identity is chosen
  ## when the config does not name one.
  result.requireSignature = cfg.verify.require_signature
  result.inlineKeys = cfg.verify.allowed_keys
  result.signerIdentity =
    if cfg.verify.signer_identity.isSome and
        cfg.verify.signer_identity.get().len > 0:
      cfg.verify.signer_identity.get()
    else:
      defaultSignerIdentity
  if cfg.verify.allowed_signers.isSome and
      cfg.verify.allowed_signers.get().len > 0:
    let raw = cfg.verify.allowed_signers.get()
    result.allowedSignersFile =
      if isAbsolute(raw): raw
      elif configDir.len > 0: absolutePath(configDir / raw)
      else: absolutePath(raw)
  if cfg.manifest.revision.isSome and cfg.manifest.revision.get().len > 0:
    result.pinnedRevision = cfg.manifest.revision.get()

proc q(value: string): string = quoteShell(value)

proc runGit(gitBin: string; args: openArray[string]):
    tuple[code: int; output: string] =
  ## `execCmdEx` with stderr folded into stdout (signature diagnostics land on
  ## stderr). The allowed-signers file + format are threaded via `-c key=val`
  ## flags in `args`, so the call is self-contained and leaves no global git
  ## state behind.
  var cmd = q(gitBin)
  for a in args:
    cmd.add(" ")
    cmd.add(q(a))
  let res = execCmdEx(cmd, options = {poStdErrToStdOut, poUsePath})
  (code: res.exitCode, output: res.output)

proc resolveRev(gitBin, manifestPath, rev: string): string =
  let res = runGit(gitBin, ["-C", manifestPath, "rev-parse", "--verify",
    "--quiet", rev & "^{commit}"])
  if res.code == 0: res.output.strip() else: ""

proc objectType(gitBin, manifestPath, rev: string): string =
  let res = runGit(gitBin, ["-C", manifestPath, "cat-file", "-t", rev])
  if res.code == 0: res.output.strip() else: ""

proc fail(manifestPath, revision, msg: string) {.noreturn.} =
  var e = newException(ManifestProvenanceError, msg)
  e.manifestPath = manifestPath
  e.revision = revision
  raise e

proc buildAllowedSignersFile(spec: ManifestVerifySpec; scratchDir: string):
    string =
  ## Compose the effective allowed-signers file: the configured file's
  ## contents (if any) plus one line per inline key (each prefixed with the
  ## signer identity when the inline entry is a bare key, i.e. starts with a
  ## key-type token like `ssh-ed25519`). Returns the path of a freshly written
  ## temp file under `scratchDir`. Returns "" when no trust material exists.
  var lines: seq[string]
  if spec.allowedSignersFile.len > 0:
    if not fileExists(spec.allowedSignersFile):
      fail("", "", "configured allowed_signers file does not exist: " &
        spec.allowedSignersFile)
    for line in readFile(spec.allowedSignersFile).splitLines:
      if line.strip().len > 0:
        lines.add(line)
  for key in spec.inlineKeys:
    let trimmed = key.strip()
    if trimmed.len == 0:
      continue
    # A bare public key ("ssh-ed25519 AAAA...") has no principal column; the
    # allowed-signers format REQUIRES a leading principal, so stamp the
    # configured identity. An entry that already names a principal (anything
    # not starting with a key-type token) is taken verbatim.
    if trimmed.startsWith("ssh-") or trimmed.startsWith("sk-") or
        trimmed.startsWith("ecdsa-"):
      lines.add(spec.signerIdentity & " " & trimmed)
    else:
      lines.add(trimmed)
  if lines.len == 0:
    return ""
  let path = scratchDir / "allowed_signers"
  writeFile(path, lines.join("\n") & "\n")
  path

proc verifyManifestProvenance*(gitBin, manifestPath: string;
                               spec: ManifestVerifySpec) =
  ## Verify the manifest checkout at `manifestPath` against `spec`. Raises
  ## `ManifestProvenanceError` (fail-closed) on any required-check failure.
  ## A no-op when `isVerificationActive(spec)` is false.
  if not isVerificationActive(spec):
    return

  # (1) Determine the revision under scrutiny: the pinned revision when set,
  # else HEAD. When a revision is pinned we ALSO assert the checkout's HEAD
  # actually resolves to it (a moved branch can't smuggle a different tree).
  var verifyRef = "HEAD"
  var pinnedTagRef = ""
  if spec.pinnedRevision.len > 0:
    let pinnedCommit = resolveRev(gitBin, manifestPath, spec.pinnedRevision)
    if pinnedCommit.len == 0:
      fail(manifestPath, spec.pinnedRevision,
        "pinned manifest revision '" & spec.pinnedRevision &
          "' does not resolve in the manifest source")
    let headCommit = resolveRev(gitBin, manifestPath, "HEAD")
    if headCommit.len == 0 or headCommit != pinnedCommit:
      fail(manifestPath, spec.pinnedRevision,
        "manifest source HEAD (" & headCommit & ") does not match the " &
          "pinned revision '" & spec.pinnedRevision & "' (" & pinnedCommit &
          "); the manifest branch may have moved")
    # Verify the signature on the pinned object itself. When the pin names a
    # tag object, verify the TAG signature (repo's signed-tag model); when it
    # names a commit, verify that commit.
    verifyRef = spec.pinnedRevision
    if objectType(gitBin, manifestPath, spec.pinnedRevision) == "tag":
      pinnedTagRef = spec.pinnedRevision

  if not spec.requireSignature:
    # Revision pin satisfied and no signature required: done.
    return

  # (2) Signature verification via git's SSH allowed-signers path. We pass the
  # allowed-signers file + format via `-c` so no global/user git config is
  # touched and the check is hermetic.
  let scratchDir = createTempDir("repro-manifest-verify-", "")
  defer:
    try: removeDir(scratchDir)
    except OSError, IOError: discard

  let allowedSigners = buildAllowedSignersFile(spec, scratchDir)
  if allowedSigners.len == 0:
    fail(manifestPath, verifyRef,
      "signature verification is required but no allowed signers are " &
        "configured (set [verify] allowed_signers or allowed_keys)")

  let cfgFlags = @[
    "-c", "gpg.format=ssh",
    "-c", "gpg.ssh.allowedSignersFile=" & allowedSigners,
  ]
  var verifyCmd: seq[string]
  if pinnedTagRef.len > 0:
    verifyCmd = @["-C", manifestPath] & cfgFlags &
      @["verify-tag", "--raw", pinnedTagRef]
  else:
    verifyCmd = @["-C", manifestPath] & cfgFlags &
      @["verify-commit", "--raw", verifyRef]
  let res = runGit(gitBin, verifyCmd)
  if res.code != 0:
    # git verify-* exits non-zero for: no signature, bad signature, or signer
    # not in allowed-signers. All three are fail-closed for us; surface git's
    # own diagnostic so the operator can tell them apart.
    fail(manifestPath, verifyRef,
      "manifest signature verification FAILED for '" & verifyRef &
        "' in '" & manifestPath & "': " &
        (if res.output.strip().len > 0: res.output.strip()
         else: "no valid signature from an allowed signer"))
