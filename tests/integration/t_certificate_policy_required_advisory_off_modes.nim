## TC-6 — the gateway honours the project's certificate policy MODE on the
## RECEIVING side: ``required`` REJECTS an uncovered push at ``pre-receive``;
## ``advisory`` ACCEPTS + records (forwards) without blocking; ``off`` ACCEPTS
## unconditionally (no cert check at all).
##
## This drives the SAME real gateway bare + installed ``pre-receive`` /
## ``post-receive`` hooks as the key test, but flips ONLY the gateway config's
## ``gate_mode`` and asserts the receiving-side outcome per mode against a real
## second "upstream" bare:
##
##   - off      : an uncovered push is ACCEPTED and FORWARDED (upstream gets it).
##   - advisory : an uncovered push is ACCEPTED and FORWARDED (upstream gets it),
##                but the gateway emits an advisory diagnostic.
##   - required : an uncovered push is REJECTED at pre-receive (upstream does
##                NOT get it).
##
## Falsifiability:
##   - make ``required`` behave like ``off`` → the required case wrongly
##     forwards → its "upstream does NOT have the commit" assertion fails.
##   - make ``advisory`` block → its accept/forward assertion fails.
##
## Hermetic: only local ``git init`` / ``git init --bare`` repos + the REAL
## installed hooks; no network. Skip rule: ``git`` missing on PATH.

import std/[os, osproc, strutils, tempfiles, unittest]

import repro_test_support
import repro_cli_support
import repro_workspace_manifests

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

type
  ModeFixture = object
    scratch: string
    reproBin: string
    upstreamBare: string
    gatewayBare: string
    clone: string

proc setupModeFixture(gitBin, slug: string): ModeFixture =
  ## A fresh upstream bare + gateway bare + a developer clone wired so the
  ## clone PUSHES through the gateway and FETCHES from the upstream.
  result.scratch = createTempDir("repro-tc6-modes-" & slug & "-", "")
  result.reproBin = reproBinary()
  result.upstreamBare = result.scratch / "upstream.git"
  result.gatewayBare = result.scratch / "gateway.git"
  result.clone = result.scratch / "clone"

  discard requireGit(q(gitBin) & " init --bare -b main " &
    q(result.upstreamBare))
  let seed = result.scratch / "seed"
  discard requireGit(q(gitBin) & " init -b main " & q(seed))
  discard requireGit(q(gitBin) & " -C " & q(seed) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(seed) &
    " config user.name \"TC6 Seeder\"")
  writeFile(seed / "README.md", "seed\n")
  discard requireGit(q(gitBin) & " -C " & q(seed) & " add README.md")
  discard requireGit(q(gitBin) & " -C " & q(seed) & " commit -m seed")
  discard requireGit(q(gitBin) & " -C " & q(seed) &
    " remote add origin " & q(result.upstreamBare))
  discard requireGit(q(gitBin) & " -C " & q(seed) & " push origin main")

  discard requireGit(q(gitBin) & " clone " & q(fileUrl(result.upstreamBare)) &
    " " & q(result.clone))
  discard requireGit(q(gitBin) & " -C " & q(result.clone) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(result.clone) &
    " config user.name \"TC6 Tester\"")

proc wire(gitBin: string; fx: ModeFixture; mode: CertificateGateMode) =
  let cfg = GatewayConfig(
    gateMode: mode,
    requiredTargets: @["t-unit"],
    requiredPlatforms: @[currentPlatformTag()],
    lockDigest: "blake3:irrelevant-no-cert-attached",
    registeredKeysPath: "")  # empty registry: every cert would be untrusted
  let wired = wirePushGateway(gitBin, fx.clone, fx.gatewayBare,
    fileUrl(fx.upstreamBare), cfg)
  check wired.ok

proc makeNewCommit(gitBin: string; fx: ModeFixture; content: string): string =
  writeFile(fx.clone / "change.txt", content)
  discard requireGit(q(gitBin) & " -C " & q(fx.clone) & " add change.txt")
  discard requireGit(q(gitBin) & " -C " & q(fx.clone) & " commit -m change")
  result = requireGit(q(gitBin) & " -C " & q(fx.clone) &
    " rev-parse HEAD").strip()

proc upstreamTip(gitBin, upstreamBare: string): string =
  let tip = runCmd(q(gitBin) & " -C " & q(upstreamBare) &
    " rev-parse refs/heads/main")
  if tip.code != 0: "" else: tip.output.strip()

proc pushThroughGateway(gitBin: string; fx: ModeFixture):
    tuple[code: int; output: string] =
  runShell(shellCommand(@[
    gitBin, "-C", fx.clone, "push", "origin", "main"],
    @[(name: "REPROBUILD_REPRO", value: fx.reproBin)]))

suite "TC-6 — certificate policy required/advisory/off modes (receiving side)":

  test "t_certificate_policy_required_advisory_off_modes":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      # ---- off: uncovered push ACCEPTED + FORWARDED unconditionally -------
      block:
        let fx = setupModeFixture(gitBin, "off")
        defer: removeDir(fx.scratch)
        wire(gitBin, fx, cgmOff)
        let newSha = makeNewCommit(gitBin, fx, "off-mode change\n")
        let pushed = pushThroughGateway(gitBin, fx)
        checkpoint("off push output: " & pushed.output)
        check pushed.code == 0
        # No cert anywhere, yet ``off`` forwards: the upstream tip advances.
        check upstreamTip(gitBin, fx.upstreamBare) == newSha

      # ---- advisory: uncovered push ACCEPTED + FORWARDED, never blocks -----
      block:
        let fx = setupModeFixture(gitBin, "advisory")
        defer: removeDir(fx.scratch)
        wire(gitBin, fx, cgmAdvisory)
        let newSha = makeNewCommit(gitBin, fx, "advisory-mode change\n")
        let pushed = pushThroughGateway(gitBin, fx)
        checkpoint("advisory push output: " & pushed.output)
        # Falsifiable: if advisory blocked, this would be a non-zero push.
        check pushed.code == 0
        check upstreamTip(gitBin, fx.upstreamBare) == newSha
        # The gateway records an advisory diagnostic (recorded, not blocking).
        check "advisory" in pushed.output

      # ---- required: uncovered push REJECTED at pre-receive ---------------
      block:
        let fx = setupModeFixture(gitBin, "required")
        defer: removeDir(fx.scratch)
        let seedTip = upstreamTip(gitBin, fx.upstreamBare)
        wire(gitBin, fx, cgmRequired)
        let newSha = makeNewCommit(gitBin, fx, "required-mode change\n")
        let pushed = pushThroughGateway(gitBin, fx)
        checkpoint("required push output: " & pushed.output)
        # Falsifiable: if required behaved like off, this would succeed and the
        # upstream tip would advance to ``newSha``.
        check pushed.code != 0
        check ("REJECTED" in pushed.output or "rejected" in pushed.output)
        # The upstream tip must NOT have advanced — the push never reached it.
        check upstreamTip(gitBin, fx.upstreamBare) == seedTip
        check upstreamTip(gitBin, fx.upstreamBare) != newSha
