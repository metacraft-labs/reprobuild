## `repro deploy-agent` records the host identity the ONE resolver gives,
## never an invented one (reprobuild-pm issue
## 2026-10-18-deploy-agent-invents-a-host-identity-instead-of-resolving-one;
## Home-Profile-Intent-Layer.md §Host Identity; CLI/infra/README.md §Host
## identity; Deploy-Agent.md §CLI surface).
##
## Before the fix the agent passed the literal `reprobuild-deploy-agent` as
## the host of every generation it committed when no `--host` was given --
## which is how the NixOS `services.mcl-repro-deploy-agent` unit runs it. A
## second defect sat behind that one: on POSIX the resolver's last resort
## was the `hostname` COMMAND, and the unit's `PATH` holds only a compiler
## while `$HOSTNAME` is a non-exported bash variable, so simply calling the
## resolver would have refused every tick. The resolver now asks
## gethostname(2).
##
## Cases, all against the real `build/bin/repro deploy-agent` with a real
## signed manifest:
##
## * `the_os_hostname_is_recorded_lower_cased`: no `--host`, no
##   `$REPRO_HOST`, the platform's hostname variable (`$HOSTNAME` on POSIX,
##   `%COMPUTERNAME%` on Windows) set to `GM-Deploy-Host`. The report's
##   `host :` line and `repro system history`'s `host=` both say
##   `gm-deploy-host`, and `reprobuild-deploy-agent` appears nowhere.
## * `a_unit_environment_resolves_through_the_os_call`: what the NixOS unit
##   gives the process -- no hostname variable, no `$REPRO_HOST`, and a
##   `PATH` holding no `hostname` binary (an empty directory). The tick
##   applies and records the OS call's answer, lower-cased: on POSIX
##   gethostname(2), read here independently through `std/nativesockets`;
##   on Windows `GetComputerNameW`, read through the resolver's own probe
##   with the variable cleared.
## * `repro_host_wins_and_a_contradicting_host_is_refused`: `$REPRO_HOST`
##   names the host when no `--host` is given; `$REPRO_HOST=A --host B` is
##   refused with exit 2 and the resolver's diagnostic, nothing is committed,
##   and the refusal is in the tick record (`host_unresolved`), since a
##   timer-run agent's stderr is discarded. An empty `--host=` is refused the
##   same way.
##
## Falsifying mutations (performed; see the issue's Resolution): the CLI
## reverted to its pre-fix source (the `reprobuild-deploy-agent` fallback)
## turns all three cases red; the resolver's `hostname`-command probe
## restored turns the second red; dropping `hostGiven` (so an empty
## `--host=` reads as "no flag") turns the third red.
##
## Nothing is mocked: real keys, a real signed manifest, the shipped binary,
## a real state directory. On POSIX the manifest carries one build action
## that takes the in-process broker fast path (`requiresElevation = true`),
## writes only inside the temp dir, and uses shell builtins only, so it runs
## under the empty `PATH` of the second case. On Windows (no `/bin/sh`) the
## manifest carries no action: the tick still commits a generation, which
## is what records the host. Platforms: every host; the Windows run is not
## measured on home-pc (eli-pc runs it with the rest of the suite).

import std/[os, osproc, streams, strtabs, strutils, tempfiles, unittest]
when not defined(windows):
  from std/nativesockets import getHostname

import repro_deploy_agent
import repro_home_intent/host_identity
import ../../repro_peer_cache/src/repro_peer_cache/auth as peerAuth
import repro_profile

const
  Target = "deploy-agent-host-target"
  RepoRoot = currentSourcePath.parentDir.parentDir.parentDir.parentDir
  Invented = "reprobuild-deploy-agent"
  HostnameVar = when defined(windows): "COMPUTERNAME" else: "HOSTNAME"
    ## The variable the platform's hostname rule reads first.
  RunsAction = not defined(windows)
    ## The manifest's build action is `/bin/sh`; see the header.

proc reproBinary(): string =
  result = RepoRoot / "build" / "bin" / addFileExt("repro", ExeExt)
  doAssert fileExists(result),
    "repro binary not found at " & result & "; build with `just build` first"

proc writeManifestFile(path: string; m: DeployManifest) =
  let bytes = encodeManifest(m)
  var s = newString(bytes.len)
  for i, b in bytes:
    s[i] = char(b)
  createDir(parentDir(path))
  writeFile(path, s)

type
  Fixture = object
    root, stateDir, cacheRoot, applyCwd, manifestPath, signersPath: string

  AgentRun = object
    exitCode: int
    output: string

proc newFixture(): Fixture =
  result.root = createTempDir("deploy-agent-host-", "")
  result.stateDir = result.root / "agent-state"
  result.cacheRoot = result.root / "apply-cache"
  result.applyCwd = result.root / "target"
  result.manifestPath = result.root / "manifests" / "latest.rdm"
  result.signersPath = result.root / "allowed-signers"
  createDir(result.stateDir)
  createDir(result.cacheRoot)
  createDir(result.applyCwd)
  let signer = peerAuth.generateKeypair()
  peerAuth.writeTrustAnchors(result.signersPath,
    anchorsFromKeypairs(@[signer.publicKey]))
  var m = DeployManifest(
    target: Target,
    sequence: 1'u64,
    deploymentId: "deploy-host-identity",
    profileText: "",
    buildActions: @[])
  when RunsAction:
    # Shell builtins only, so it runs under an empty PATH as well.
    m.buildActions.add ProfileBuildAction(
      id: "host-identity-edge",
      argv: @["/bin/sh", "-c", "printf '%s' converged > converged.txt"],
      cwd: result.applyCwd,
      outputs: @["converged.txt"],
      commandStatsId: "deploy.host.identity.write",
      requiresElevation: true,
      cacheable: true)
  signManifest(signer, m)
  writeManifestFile(result.manifestPath, m)

proc dispose(f: Fixture) =
  try: removeDir(f.root)
  except CatchableError: discard

proc baseEnv(f: Fixture): StringTableRef =
  ## The developer's environment minus every host-identity input, so each
  ## case sets exactly the ones it is about.
  result = newStringTable(modeCaseSensitive)
  for k, v in envPairs():
    result[k] = v
  result.del("REPRO_HOST")
  result.del("HOSTNAME")
  result.del("COMPUTERNAME")
  result.del("REPRO_BINARY_CACHE_URL")
  result["REPROBUILD_ACTION_CACHE_ROOT"] = f.cacheRoot / "action-cache"

proc runRepro(f: Fixture; args: seq[string]; env: StringTableRef): AgentRun =
  var p = startProcess(reproBinary(), args = args, env = env,
    options = {poStdErrToStdOut})
  result.output = p.outputStream.readAll()
  result.exitCode = p.waitForExit()
  p.close()
  checkpoint("repro " & args.join(" ") & " -> " & $result.exitCode & "\n" &
    result.output)

proc tick(f: Fixture; env: StringTableRef; extra: seq[string] = @[]):
    AgentRun =
  f.runRepro(@["deploy-agent", "--target", Target,
    "--manifest", f.manifestPath, "--allowed-signers", f.signersPath,
    "--state-dir", f.stateDir, "--cache-root", f.cacheRoot] & extra, env)

proc history(f: Fixture): AgentRun =
  f.runRepro(@["system", "history", "--state-dir", f.stateDir], f.baseEnv)

proc field(output, label: string): string =
  for line in output.splitLines():
    let s = line.strip()
    if s.startsWith(label):
      let rest = s[label.len .. ^1].strip()
      if rest.startsWith(":"):
        return rest[1 .. ^1].strip()
  ""

proc tickRecords(f: Fixture): string =
  ## Every tick-record file the agent left, concatenated.
  let dir = f.stateDir / "deploy-agent"
  if dirExists(dir):
    for kind, path in walkDir(dir):
      if kind == pcFile and (path.endsWith(".json") or
          path.endsWith(".jsonl")):
        result.add readFile(path)

proc checkActionRan(f: Fixture) =
  when RunsAction:
    check fileExists(f.applyCwd / "converged.txt")
    if fileExists(f.applyCwd / "converged.txt"):
      check readFile(f.applyCwd / "converged.txt") == "converged"

proc osCallHostname(): string =
  ## The OS call's answer, lower-cased: what the resolver must fall back to
  ## when no variable names the host.
  when defined(windows):
    var s = currentOsHostnameSources()
    s.computerName = ""
    s.hostnameEnv = ""
    osHostnameFrom(s)
  else:
    getHostname().strip().toLowerAscii()

suite "repro deploy-agent records the resolved host identity":

  test "the_os_hostname_is_recorded_lower_cased":
    let f = newFixture()
    defer: f.dispose()
    let env = f.baseEnv
    env[HostnameVar] = "GM-Deploy-Host"
    let r = f.tick(env)
    check r.exitCode == 0
    check "outcome      : aoApplied" in r.output
    check r.output.field("host") == "gm-deploy-host"
    check Invented notin r.output
    f.checkActionRan()
    let h = f.history()
    check h.exitCode == 0
    check h.output.field("generations") == "1"
    check "host=gm-deploy-host" in h.output
    check Invented notin h.output

  test "a_unit_environment_resolves_through_the_os_call":
    let f = newFixture()
    defer: f.dispose()
    let expected = osCallHostname()
    require expected.len > 0
    let emptyBin = f.root / "empty-bin"
    createDir(emptyBin)
    let env = f.baseEnv
    env["PATH"] = emptyBin
    let r = f.tick(env)
    check "could not determine the host name" notin r.output
    check r.exitCode == 0
    check r.output.field("host") == expected
    f.checkActionRan()
    let h = f.history()
    check ("host=" & expected) in h.output
    check Invented notin h.output

  test "repro_host_wins_and_a_contradicting_host_is_refused":
    let f = newFixture()
    defer: f.dispose()
    let env = f.baseEnv
    env[HostnameVar] = "gm-deploy-decoy"
    env["REPRO_HOST"] = "gm-deploy-env-host"
    # A contradicting --host: refused, nothing committed, recorded.
    let refused = f.tick(env, @["--host", "gm-deploy-other"])
    check refused.exitCode == 2
    check ("repro deploy-agent: --host gm-deploy-other conflicts with " &
      "$REPRO_HOST=gm-deploy-env-host (which takes precedence); unset " &
      "one of them") in refused.output
    check "host_unresolved" in f.tickRecords()
    check f.history().output.field("generations") == "0"
    when RunsAction:
      check not fileExists(f.applyCwd / "converged.txt")
    # An empty --host= is refused too, not read as "no --host".
    let empty = f.tick(env, @["--host="])
    check empty.exitCode == 2
    check "repro deploy-agent: --host needs a non-empty name" in empty.output
    check f.history().output.field("generations") == "0"
    # $REPRO_HOST alone names the host.
    let ok = f.tick(env)
    check ok.exitCode == 0
    check ok.output.field("host") == "gm-deploy-env-host"
    let h = f.history()
    check "host=gm-deploy-env-host" in h.output
    check Invented notin h.output
    check "gm-deploy-decoy" notin h.output
