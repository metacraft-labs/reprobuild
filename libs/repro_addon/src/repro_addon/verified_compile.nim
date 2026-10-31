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

import ./host_exec

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
  if m.compiledProfile.digest.len == 0: return
  @["--host", m.compiledProfile.host, "--platform", m.compiledProfile.platform,
    "--arch", m.compiledProfile.arch]

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
    "--", engineExe, "deploy-agent", "compile-profile", "--stdio"]
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

proc unprivilegedCompile*(engineExe: string; m: DeployManifest):
    tuple[ok: bool; canonical, actionsJson, revision, error: string] =
  ## Compile ``m``'s source profile with ``engineExe`` as a dynamic user
  ## (``unprivilegedCompileArgv``) and return what it emitted. The result is
  ## untrusted: the caller compares it with the signed pin
  ## (``compiledProfileRefusal``) before using it.
  let argv = unprivilegedCompileArgv(engineExe, m)
  let r = runHostTool(argv, mergeStderr = false, input = compileInput(m))
  if r.exitCode != 0:
    return (false, "", "", "", "the unprivileged profile compile failed " &
      "(exit " & $r.exitCode & ")")
  parseCompileOutput(r.output)
