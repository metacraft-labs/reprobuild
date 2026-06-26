## RA-17 — manifest provenance verification.
##
## `repro workspace init` MUST be able to verify the AUTHENTICITY of a manifest
## source before trusting it. When the host bootstrap config declares
## `[verify] require_signature = true` plus an allowed-signers trust anchor, the
## manifest source's HEAD commit must carry a VALID signature from an allowed
## key; otherwise init FAILS CLOSED and never materialises `.repo/manifests`
## from the unverified source. When verification is NOT configured, behavior is
## unchanged (no verification — existing init flows are unaffected).
##
## Cases (all hermetic: local bare repos + a freshly-generated ed25519 SSH
## signing key in a tempdir; git is driven with `gpg.format=ssh` so nothing
## reaches a system GPG keyring or the network):
##
##   A. HEAD signed by an ALLOWED key + `require_signature = true`        → init
##      PROCEEDS (manifest checkout materialised, participating repo cloned).
##   B. HEAD UNSIGNED + `require_signature = true`                        → init
##      REFUSES with a clear "provenance verification failed" diagnostic and
##      NO `.repo/manifests` is materialised.
##   C. HEAD signed by a key NOT in allowed-signers + `require_signature = true`
##      → init REFUSES (the allowed-signers check actually rejects a
##      non-allowed signer, not just an unsigned commit).
##   D. `require_signature` absent (no `[verify]` table) on the SAME unsigned
##      manifest as case B                                                → init
##      PROCEEDS (verification off ⇒ existing flow unchanged).
##
## Falsifiability:
##   - If verification were a no-op, case B and case C would PROCEED (init
##     exit 0, `.repo/manifests` present) — the test asserts they REFUSE.
##   - If verification rejected everything, case A and case D would FAIL — the
##     test asserts they PROCEED.
##   - If the allowed-signers check ignored the principal/key, case C (a
##     real signature by a DIFFERENT key) would pass — the test asserts it is
##     rejected, distinguishing "unsigned" from "wrong key".
##
## Skip rule: `git` or `ssh-keygen` missing on PATH, or the local git lacks SSH
## commit-signature verification (very old git).

import std/[os, osproc, strutils, tempfiles, unittest]

import repro_test_support

proc q(value: string): string = quoteShell(value)

proc runCmd(command: string; cwd = ""): tuple[code: int; output: string] =
  let res = execCmdEx(command, workingDir = cwd)
  (code: res.exitCode, output: res.output)

proc requireGit(command: string; cwd = ""): string =
  let res = runCmd(command, cwd)
  if res.code != 0:
    checkpoint("command failed: " & command & "\nexit=" & $res.code &
      "\n" & res.output)
    quit 1
  res.output

proc repoRoot(): string =
  result = currentSourcePath().parentDir.parentDir.parentDir

proc reproBinary(): string =
  requireBinary(repoRoot() / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

proc gitConfig(gitBin, repoPath: string) =
  discard requireGit(q(gitBin) & " -C " & q(repoPath) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(repoPath) &
    " config user.name \"RA17 Tester\"")

proc seedOrigin(gitBin, originPath, workPath: string): string =
  discard requireGit(q(gitBin) & " init --bare -b main " & q(originPath))
  discard requireGit(q(gitBin) & " init -b main " & q(workPath))
  gitConfig(gitBin, workPath)
  writeFile(workPath / "README.md", "RA17 fixture\n")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " add README.md")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " commit -m first")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " remote add origin " & q(originPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " push origin main")
  result = requireGit(q(gitBin) & " -C " & q(workPath) &
    " rev-parse HEAD").strip()

proc projectTomlBody(libUrl: string): string =
  "schema = \"reprobuild.workspace.project.v1\"\n\n" &
  "[project]\n" &
  "name = \"myproject\"\n" &
  "default_revision = \"main\"\n" &
  "trunk = \"main\"\n\n" &
  "[[remote]]\nname = \"lib-origin\"\nfetch = \"" & libUrl & "\"\n\n" &
  "includes = [\n  \"repos/lib-a.toml\",\n]\n"

const libATomlBody = """
schema = "reprobuild.workspace.repo.v1"

[repo]
name = "lib-a"
path = "lib-a"
remote = "lib-origin"
revision = "main"
"""

proc writeManifestFiles(workPath, libUrl: string) =
  createDir(workPath / "projects")
  createDir(workPath / "repos")
  writeFile(workPath / "projects" / "myproject.toml", projectTomlBody(libUrl))
  writeFile(workPath / "repos" / "lib-a.toml", libATomlBody)

proc generateSshKey(scratch, name, comment: string):
    tuple[priv, pub, pubLine: string] =
  ## Generate an ed25519 SSH keypair. Returns the private key path, the public
  ## key path, and the public key material (the `ssh-ed25519 AAAA...` token,
  ## stripped of any trailing comment) for an allowed-signers line.
  let priv = scratch / name
  removeFile(priv)
  removeFile(priv & ".pub")
  discard requireGit("ssh-keygen -t ed25519 -N \"\" -C " & q(comment) &
    " -f " & q(priv))
  let pubRaw = readFile(priv & ".pub").strip()
  # `<type> <base64> [comment]` — keep the first two fields for the
  # allowed-signers key material.
  let fields = pubRaw.splitWhitespace()
  let keyMaterial =
    if fields.len >= 2: fields[0] & " " & fields[1] else: pubRaw
  (priv: priv, pub: priv & ".pub", pubLine: keyMaterial)

proc seedSignedBare(gitBin, scratch, barePath, libUrl: string;
                    signKeyPriv: string) =
  ## Build a manifest work tree whose HEAD commit is SSH-signed with
  ## `signKeyPriv` (empty ⇒ an UNSIGNED commit), then mirror it into a bare
  ## repo. The signature lives on the commit object and survives the clone the
  ## bootstrap cache performs.
  let workPath = scratch / ("seed-" & extractFilename(barePath))
  removeDir(workPath)
  discard requireGit(q(gitBin) & " init -b main " & q(workPath))
  gitConfig(gitBin, workPath)
  writeManifestFiles(workPath, libUrl)
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " add -A")
  if signKeyPriv.len > 0:
    discard requireGit(q(gitBin) & " -C " & q(workPath) &
      " -c gpg.format=ssh -c user.signingkey=" & q(signKeyPriv & ".pub") &
      " commit -S -m \"signed manifest\"")
  else:
    discard requireGit(q(gitBin) & " -C " & q(workPath) &
      " commit -m \"unsigned manifest\"")
  removeDir(barePath)
  discard requireGit(q(gitBin) & " clone --bare " & q(workPath) & " " &
    q(barePath))

proc bootstrapConfigBody(manifestUrl: string; verifyTable: string): string =
  ## A `.repro-workspace.toml`. `verifyTable` is the raw `[verify]` body
  ## (empty string ⇒ no verification table at all).
  "schema = \"reprobuild.workspace.bootstrap.v1\"\n\n" &
  "[manifest]\n" &
  "url = \"" & manifestUrl & "\"\n" &
  "branch = \"main\"\n\n" &
  "[projects]\n" &
  "default = [\"myproject\"]\n" &
  verifyTable

proc supportsSshVerify(gitBin, scratch: string): bool =
  ## Probe: can this git sign + verify a commit via the SSH allowed-signers
  ## path? Older gits lack `verify-commit` SSH support; skip rather than fail.
  let probe = scratch / "ssh-probe"
  removeDir(probe)
  createDir(probe)
  let key = generateSshKey(probe, "probe", "probe@reprobuild")
  let allowed = probe / "allowed_signers"
  writeFile(allowed, "probe@reprobuild " & key.pubLine & "\n")
  let work = probe / "repo"
  if runCmd(q(gitBin) & " init -b main " & q(work)).code != 0: return false
  gitConfig(gitBin, work)
  writeFile(work / "f", "x\n")
  discard runCmd(q(gitBin) & " -C " & q(work) & " add f")
  let commit = runCmd(q(gitBin) & " -C " & q(work) &
    " -c gpg.format=ssh -c user.signingkey=" & q(key.pub) &
    " commit -S -m probe")
  if commit.code != 0: return false
  let verify = runCmd(q(gitBin) & " -C " & q(work) &
    " -c gpg.format=ssh -c gpg.ssh.allowedSignersFile=" & q(allowed) &
    " verify-commit HEAD")
  verify.code == 0

template runProvenanceCases(gitBin, scratch: string) =
    ## A template (not a proc) so the unittest `check`/`checkpoint` machinery
    ## inlines into the enclosing `test` scope where `testStatusIMPL` lives.
    let reproBin = reproBinary()

    # Participating repo origin (shared by all manifests).
    let libOrigin = scratch / "origin-lib-a.git"
    let libSeed = scratch / "seed-lib-a"
    discard seedOrigin(gitBin, libOrigin, libSeed)
    let libUrl = fileUrl(libOrigin)

    # Trusted signing key (its public key goes into allowed-signers) and a
    # DIFFERENT, untrusted key (NOT in allowed-signers) for the wrong-key case.
    let trusted = generateSshKey(scratch, "trusted", "reprobuild@manifest")
    let attacker = generateSshKey(scratch, "attacker", "attacker@evil")

    # Allowed-signers file: ONLY the trusted key.
    let allowedSigners = scratch / "allowed_signers"
    writeFile(allowedSigners,
      "reprobuild@manifest " & trusted.pubLine & "\n")

    # Manifest bares:
    #   signed   — HEAD signed by the trusted key (cases A).
    #   unsigned — HEAD not signed (cases B and D).
    #   attacker — HEAD signed by the attacker key, NOT in allowed-signers (C).
    let signedBare = scratch / "bare-signed.git"
    seedSignedBare(gitBin, scratch, signedBare, libUrl, trusted.priv)
    let unsignedBare = scratch / "bare-unsigned.git"
    seedSignedBare(gitBin, scratch, unsignedBare, libUrl, "")
    let attackerBare = scratch / "bare-attacker.git"
    seedSignedBare(gitBin, scratch, attackerBare, libUrl, attacker.priv)

    let verifyTable =
      "[verify]\nrequire_signature = true\n" &
      "allowed_signers = \"" & allowedSigners.replace("\\", "\\\\") & "\"\n"

    proc runInit(caseTag, manifestBare, verifyBody: string):
        tuple[code: int; output: string; wsRoot: string] =
      ## Run `repro workspace init` for one case against a fresh workspace dir
      ## and a fresh per-case manifest cache (so a prior case's cached clone
      ## never satisfies a later case). Returns the exit code/output + the
      ## workspace root for post-assertions.
      let configDir = scratch / ("host-" & caseTag)
      createDir(configDir)
      writeFile(configDir / ".repro-workspace.toml",
        bootstrapConfigBody(fileUrl(manifestBare), verifyBody))
      let workspaceRoot = scratch / ("ws-" & caseTag)
      createDir(workspaceRoot)
      let cacheRoot = scratch / ("cache-" & caseTag)
      let init = runShell(shellCommand(@[
        reproBin, "workspace", "init",
        "--workspace-root=" & workspaceRoot,
      ], env = @[
        (name: "REPRO_MANIFEST_CACHE", value: cacheRoot),
        (name: "REPRO_WORKSPACE_CONFIG",
          value: configDir / ".repro-workspace.toml"),
      ]))
      (code: init.code, output: init.output, wsRoot: workspaceRoot)

    # ---- Case A: signed by an allowed key + require_signature → PROCEEDS ----
    block caseA:
      let r = runInit("a-signed-allowed", signedBare, verifyTable)
      if r.code != 0:
        checkpoint("case A init output: " & r.output)
      check r.code == 0
      check fileExists(r.wsRoot / ".repo" / "manifests" / "projects" /
        "myproject.toml")
      check dirExists(r.wsRoot / "lib-a" / ".git")

    # ---- Case B: unsigned + require_signature → REFUSES, fail closed -------
    block caseB:
      let r = runInit("b-unsigned", unsignedBare, verifyTable)
      check r.code != 0
      check "provenance" in r.output.toLowerAscii()
      # Fail-closed: no manifest checkout materialised from the unverified
      # source.
      check not fileExists(r.wsRoot / ".repo" / "manifests" / "projects" /
        "myproject.toml")
      check not dirExists(r.wsRoot / "lib-a" / ".git")

    # ---- Case C: signed by a NON-allowed key + require_signature → REFUSES --
    block caseC:
      let r = runInit("c-wrong-key", attackerBare, verifyTable)
      check r.code != 0
      check "provenance" in r.output.toLowerAscii()
      check not fileExists(r.wsRoot / ".repo" / "manifests" / "projects" /
        "myproject.toml")

    # ---- Case D: no [verify] table on the SAME unsigned manifest → PROCEEDS -
    block caseD:
      let r = runInit("d-no-verify", unsignedBare, "")
      if r.code != 0:
        checkpoint("case D init output: " & r.output)
      check r.code == 0
      check fileExists(r.wsRoot / ".repo" / "manifests" / "projects" /
        "myproject.toml")
      check dirExists(r.wsRoot / "lib-a" / ".git")

suite "RA-17 — manifest provenance verification":

  test "t_manifest_init_rejects_unsigned_or_tampered_manifest":
    let gitBin = findExe("git")
    let sshKeygen = findExe("ssh-keygen")
    if gitBin.len == 0 or sshKeygen.len == 0:
      skip()
    else:
      let scratch = createTempDir("repro-ra17-provenance-", "")
      defer: removeDir(scratch)
      if not supportsSshVerify(gitBin, scratch):
        skip()
      else:
        runProvenanceCases(gitBin, scratch)
