## The compile of a manifest's source profile on an add-on host, as a
## verified cache of the producer's (ReproOS Add-On Mode §9.1; Deploy-Agent
## §"The compiled-profile pin").
##
## A manifest may ship its profile as Nim source. Compiling it runs code the
## profile chooses (its macros, its `staticExec`s), so it never runs as root,
## and what it emits is untrusted: the producer compiled the same source with
## the same compiler revision for the facts the manifest names, and signed
## the digest of the result (``DeployManifest.compiledProfile``). An agent
## applies a compiled profile only when its own compile reproduces that
## digest; anything else -- a compromised compiler, a compiler of another
## revision, a profile whose compile is not deterministic -- is refused
## before a byte of it is planned.
##
## Two places compile:
##
## - the add-on agent's fetch unit (``agent_split``), already unprivileged:
##   it runs the configured compiler with ``compileFactArgs``;
## - the full engine's ``repro deploy-agent`` on an add-on host, which runs
##   as root: it has the compile done by a transient unit of PID 1 under a
##   dynamic user, with no capabilities and no network
##   (``unprivilegedCompile``), and reads the result back on the unit's
##   stdout.
##
## Either way ``compiledProfileRefusal`` decides.

import std/[base64, json, os, strutils]

import repro_deploy_agent/manifest
import repro_deploy_agent/agent_mutations

import repro_infra/host_base

import ./host_exec
from ./generation0 import AgentCompileMemoryMax, AgentCompileNice,
  AgentCompileWeight, AgentCompileOomScoreAdjust

const
  CompiledProfileStdioMarker* = "REPRO-COMPILED-PROFILE "
    ## Mirrors ``repro_cli_support/deploy_agent.CompiledProfileStdioMarker``
    ## (the engine prints it; this module, linked into the static add-on
    ## binary too, must not import the engine's CLI to read it).
  UnprivilegedCompileTimeoutSec* = 3600

proc compileFactArgs*(m: DeployManifest): seq[string] =
  ## The ``compile-profile`` options that make an agent's compile use the
  ## facts the producer compiled for. Empty when the manifest pins no
  ## compile: such a manifest's source profile is refused anyway, and the
  ## compile then runs with the host's own facts only to say why.
  ## With a signed system selection the compile is asked for exactly it.
  if m.compiledProfile.digest.len == 0: return
  result = @["--host", m.compiledProfile.host, "--platform",
    m.compiledProfile.platform, "--arch", m.compiledProfile.arch]
  when not agentMutated("compile-pin-drops-selection"):
    if m.compiledProfile.hasSystemSelection:
      result.add(["--system-mode", m.compiledProfile.systemMode,
        "--system-activities", m.compiledProfile.systemActivities.join(",")])
      # An agent compiles on the host it applies to: an add-on selection
      # is realised for this host's base (``add-on-arch`` on Arch), as
      # ``repro infra`` realises it there (spec §8.1).
      if m.compiledProfile.systemMode == "addOn":
        result.add(["--system-base", "this-host"])

const
  CompileProfileUsageExit* = 2
    ## ``compile-profile``'s exit code for a command line it refuses: here,
    ## ``--system-base`` given to a compiler older than the option. The one
    ## exit an agent retries without the option.
  CompileProfileTargetExit* = 3
    ## Mirrors ``repro_cli_support/deploy_agent.CompileProfileTargetExit``:
    ## the compiler understood its command line but cannot compile for the
    ## target (an unsupported base, an unreadable ``os-release``). Never
    ## retried. A profile the realisation refuses exits 1, never retried
    ## either.

type
  CompileAttempt* = object
    ## What ``runCompileForAnyRevision`` ran: the last result, and whether
    ## it is the retry without ``--system-base``.
    result*: HostToolResult
    retriedWithoutBase*: bool

proc withoutSystemBase*(argv: openArray[string]): seq[string] =
  ## ``argv`` without its ``--system-base <value>`` pair.
  var i = 0
  while i < argv.len:
    if argv[i] == "--system-base" and i + 1 < argv.len:
      i += 2
      continue
    result.add(argv[i])
    inc i

proc runCompileForAnyRevision*(argv: seq[string];
    run: proc(argv: seq[string]): HostToolResult): CompileAttempt =
  ## Run an agent's ``compile-profile`` (``run``), and when the compiler
  ## rejected ``--system-base`` as an unknown option -- the usage exit
  ## (``CompileProfileUsageExit``) and nothing else -- run it again without
  ## it (spec §13 decision 134, amended at AR1 review round 2). The retry
  ## exists only so that the compiler's own revision reaches the agent,
  ## which then refuses it as a revision mismatch instead of failing on a
  ## usage error; ``retriedCompileRefusal`` decides what a retried compile
  ## may be used for. A target the compiler cannot compile for exits
  ## ``CompileProfileTargetExit`` and is not retried.
  ##
  ## The retry is decided by the exit code, because the unprivileged
  ## compile does not capture stderr: the agent's own command line is
  ## well-formed for every compiler revision except in that one option.
  result.result = run(argv)
  if result.result.exitCode == CompileProfileUsageExit and
      "--system-base" in argv:
    result.result = run(withoutSystemBase(argv))
    result.retriedWithoutBase = true

type
  HostBaseObservation* = proc(): HostBase
    ## How an agent observes the base of the host it compiles on:
    ## ``observeHostBase`` (the running machine's ``os-release``) in
    ## production. A parameter, so the refusal can be driven for each base
    ## without touching the build host's own ``/etc/os-release``.

proc agentHostIsDebianFamily*(observe: HostBaseObservation = observeHostBase):
    bool =
  ## The host's ``os-release`` names the Debian family. False on any other
  ## base, when it cannot be read, and when the observation itself fails
  ## (raises): the one base a compile made without ``--system-base`` (the
  ## ``add-on-debian`` realisation) can be right for, so anything short of
  ## a Debian-family observation fails closed. ``observeHostBase`` reports
  ## an unreadable file as an unclassified base rather than raising; the
  ## ``except`` is for an observation that does raise.
  try:
    observe().isDebianFamily
  except CatchableError:
    false

proc retriedCompileRefusal*(retriedWithoutBase: bool;
    compilerRevision, pinnedRevision: string; hostIsDebianFamily: bool): string =
  ## Why a compile retried without ``--system-base`` must not be used, or
  ## "" when the pin check that follows may decide (spec §13 decision 134,
  ## as amended at AR1 review round 2):
  ##
  ## * a compiler that reports the PINNED revision knows the option, so its
  ##   usage exit was not the old-compiler case, and its compile is refused;
  ## * on a host that is not Debian-family (Arch, Omarchy, or an unreadable
  ##   ``os-release``) a compile made without ``--system-base`` realised the
  ##   Debian projection, which is wrong for the host: it is refused as the
  ##   revision mismatch it is, naming both revisions;
  ## * on a Debian-family host the compile is the right realisation, and
  ##   ``compiledProfileRefusal`` reports the revision mismatch itself.
  if not retriedWithoutBase: return ""
  let reported = if compilerRevision.len > 0: compilerRevision
                 else: "of an unknown revision"
  if compilerRevision.len > 0 and compilerRevision == pinnedRevision:
    return "the compiler reports the pinned revision " & pinnedRevision &
      " but refused --system-base, which that revision accepts; its " &
      "compile without the option is refused"
  if not hostIsDebianFamily:
    return CompilerRevisionMismatch & ": the producer compiled with " &
      "reprobuild " & pinnedRevision & ", this host's compiler is " &
      reported & ", which predates --system-base and so cannot compile " &
      "for this host's base; a compile without it is accepted only on a " &
      "Debian-family host"
  ""

proc launcherOf*(exe: string): string =
  ## The program to exec to run ``exe`` in a FRESH environment. A transient
  ## unit inherits nothing from this process, so an image a launcher script
  ## execs with its environment set up (Nix's ``wrapProgram``:
  ## ``bin/.reprobuild-wrapped`` behind ``bin/reprobuild``, which exports the
  ## runtime library path and the compiler's source paths) must be run
  ## through that launcher; otherwise ``exe`` itself.
  ## https://nixos.org/manual/nixpkgs/stable/#fun-wrapProgram
  let (dir, name, ext) = splitFile(exe)
  let base = name & ext
  if base.startsWith(".") and base.endsWith("-wrapped"):
    let launcher = dir / base[1 ..< base.len - "-wrapped".len]
    if fileExists(launcher): return launcher
  exe

const
  UnprivilegedCompileMemoryMax* = AgentCompileMemoryMax
  UnprivilegedCompileNice* = AgentCompileNice
  UnprivilegedCompileWeight* = AgentCompileWeight
    ## The fetch unit's bounds (``generation0.agentCompileBounds``): one
    ## compile, one budget, whichever unit runs it.

proc unprivilegedCompileLimits*(): seq[string] =
  ## The compile unit's resource properties (``systemd-run --property``).
  @["--property=MemoryMax=" & UnprivilegedCompileMemoryMax,
    "--property=MemorySwapMax=0",
    "--property=Nice=" & $UnprivilegedCompileNice,
    "--property=CPUWeight=" & $UnprivilegedCompileWeight,
    "--property=IOWeight=" & $UnprivilegedCompileWeight,
    "--property=OOMScoreAdjust=" & $AgentCompileOomScoreAdjust]

proc unprivilegedCompileArgv*(engineExe: string; m: DeployManifest;
                              timeoutSec = UnprivilegedCompileTimeoutSec):
    seq[string] =
  ## The ``systemd-run`` command line of ``unprivilegedCompile``: a
  ## transient service under a dynamic user, with no capabilities, no
  ## network, a private /tmp, the file system read-only and every home
  ## hidden. The same confinement as the add-on agent's fetch unit, minus
  ## the network it needs for fetching (spec §9.1).
  let systemdRun = resolveHostTool(SystemdRunCandidates)
  if systemdRun.len == 0:
    raise newException(HostToolMissing, "systemd-run not found at " &
      SystemdRunCandidates.join(" or ") & "; the profile cannot be " &
      "compiled unprivileged")
  result = @[systemdRun, "--quiet", "--wait", "--pipe", "--collect",
    "--service-type=exec",
    "--property=DynamicUser=yes",
    "--property=PrivateTmp=yes",
    "--property=ProtectSystem=strict",
    "--property=ProtectHome=yes",
    "--property=NoNewPrivileges=yes",
    "--property=CapabilityBoundingSet=",
    "--property=AmbientCapabilities=",
    "--property=PrivateNetwork=yes",
    "--property=IPAddressDeny=any",
    "--property=RestrictAddressFamilies=AF_UNIX",
    "--property=PrivateDevices=yes",
    "--property=ProtectKernelTunables=yes",
    "--property=ProtectKernelModules=yes",
    "--property=ProtectControlGroups=yes",
    "--property=InaccessiblePaths=-/run/systemd/resolve -/run/dbus " &
      "-/var/run/dbus -/run/nscd -/var/run/nscd -/var/lib/repro " &
      "-/etc/repro/anchors",
    "--property=RuntimeMaxSec=" & $timeoutSec,
    # The PATH bootstrap's preflight probed (§13 decision 31), named rather
    # than inherited from the manager, whose block an operator can change.
    "--setenv=PATH=" & ProfileCompilePath] & unprivilegedCompileLimits() &
    @["--", engineExe, "deploy-agent", "compile-profile", "--stdio"]
  for a in compileFactArgs(m): result.add(a)

proc compileInput*(m: DeployManifest): string =
  ## The ``compile-profile --stdio`` input for ``m``'s profile.
  var files = newJArray()
  for f in m.profileFiles:
    files.add(%*{"path": f.path, "content": base64.encode(f.content)})
  $(%*{"profileText": base64.encode(m.profileText), "profileFiles": files})

proc parseCompileOutput*(output: string):
    tuple[ok: bool; canonical, actionsJson, revision, error: string] =
  ## Find the result line in what ``compile-profile --stdio`` printed.
  for line in output.splitLines():
    if line.startsWith(CompiledProfileStdioMarker):
      try:
        let j = parseJson(base64.decode(
          line[CompiledProfileStdioMarker.len .. ^1].strip()))
        return (true, base64.decode(j["canonical"].getStr()),
                base64.decode(j["actions"].getStr()),
                j{"revision"}.getStr(), "")
      except CatchableError as e:
        return (false, "", "", "", "the compiler's result line is " &
          "malformed: " & e.msg)
  (false, "", "", "", "the compiler printed no result")

proc verifiedCompileWith*(argv: seq[string]; m: DeployManifest;
    run: proc(argv: seq[string]): HostToolResult;
    observe: HostBaseObservation):
    tuple[ok: bool; canonical, actionsJson, revision, error: string] =
  ## The agent's ``compile-profile --stdio`` run (``argv``, through ``run``)
  ## with the decision of spec §13 decision 134 applied: the retry without
  ## ``--system-base`` on the usage exit only, and the refusal of a
  ## retried compile (``retriedCompileRefusal``) for the base ``observe``
  ## reports. ``unprivilegedCompile`` is this with the confined
  ## ``systemd-run`` command line and the running host's base; the
  ## parameters are what a test drives it through.
  let attempt = runCompileForAnyRevision(argv, run)
  let r = attempt.result
  if r.exitCode != 0:
    return (false, "", "", "", "the unprivileged profile compile failed " &
      "(exit " & $r.exitCode & ")")
  result = parseCompileOutput(r.output)
  if result.ok:
    let why = retriedCompileRefusal(attempt.retriedWithoutBase,
      result.revision, m.compiledProfile.compilerRevision,
      agentHostIsDebianFamily(observe))
    if why.len > 0:
      # Nothing of the refused compile is handed back.
      return (false, "", "", "", why)

proc unprivilegedCompileVia*(argv: seq[string]; m: DeployManifest;
    run: proc(argv: seq[string]; input: string): HostToolResult):
    tuple[ok: bool; canonical, actionsJson, revision, error: string] =
  ## ``unprivilegedCompile`` with the command line and the process runner
  ## open and the RUNNING host's base (``observeHostBase``) fixed here: a
  ## test that drives this with a stand-in runner checks the observation
  ## production uses. ``m``'s request is the runner's input.
  let input = compileInput(m)
  verifiedCompileWith(argv, m,
    proc(a: seq[string]): HostToolResult = run(a, input), observeHostBase)

proc unprivilegedCompile*(engineExe: string; m: DeployManifest):
    tuple[ok: bool; canonical, actionsJson, revision, error: string] =
  ## Compile ``m``'s source profile with ``engineExe`` as a dynamic user
  ## (``unprivilegedCompileArgv``) and return what it emitted. The result is
  ## untrusted: the caller compares it with the signed pin
  ## (``compiledProfileRefusal``) before using it.
  unprivilegedCompileVia(unprivilegedCompileArgv(engineExe, m), m,
    proc(a: seq[string]; input: string): HostToolResult =
      runHostTool(a, mergeStderr = false, input = input))
