## The service unit, rendered by the daemon that the unit starts.
##
## ## Why the binary emits its own unit
##
## The unit and the daemon have to agree about the executable's path, the
## flags it takes, the user it runs as and the directories it needs. When
## the unit is a heredoc in an image-build script and the flags are a
## parser in the daemon, those are two answers to one question, and they
## drift the first time a flag is renamed — silently, because a unit with
## a stale flag fails at boot on a machine nobody is watching.
##
## So the daemon renders it, and the image build asks the daemon. There
## is one place a flag is spelled, and a build that stages a binary
## automatically stages the unit that matches it.
##
## ## What the unit does, and why
##
## The hardening is not decoration. The agent is reachable before
## anything has authenticated, so the interesting question is what an
## attacker who takes the process gets. The answer should be: a process
## that can read one device node, write one tmpfs directory, and touch
## nothing else on a read-only root.
##
## ``ProtectSystem=strict`` and ``ProtectHome=yes`` leave the filesystem
## read-only apart from the one runtime directory — which is why
## ``RuntimeDirectory`` is *derived* from the secrets directory the
## daemon is told to use rather than written beside it. Two spellings of
## one path is the drift this file exists to avoid, and here it has
## teeth: a secrets directory anywhere else is a daemon that starts and
## then cannot write where it was told to, so it is refused at render
## time. ``PrivateTmp``,
## ``NoNewPrivileges``, ``RestrictSUIDSGID`` and a ``SystemCallFilter``
## limited to the system-service set close the usual escalation routes.
## ``MemoryDenyWriteExecute`` is safe here because nothing in the closure
## generates code at run time. ``RestrictAddressFamilies`` is limited to
## the two families a loopback HTTP listener needs, so a compromised
## agent cannot open a netlink or packet socket.
##
## ``Restart=on-failure`` rather than ``Restart=always``: an agent that
## exits cleanly has been told to, and a supervisor that restarts it
## anyway makes shutting the surface down impossible.
##
## ## Mocking
##
## None. The renderer is pure text and the tests read what it renders.

import std/strutils

const
  UnitName* = "attestation-agent.service"

  UnitInstallDir* = "usr/lib/systemd/system"
    ## Relative to the image root. It is ``usr/lib`` and not ``lib``:
    ## current systemd no longer carries the legacy path in its default
    ## unit search, so a unit installed there is a unit that is never
    ## found.

  UnitWantedBy* = "multi-user.target"

  DefaultListen* = "127.0.0.1:7331"
    ## Loopback by default. A deployment that wants the API reachable
    ## fronts it with its own authenticated channel and opens the port
    ## deliberately; nothing here opens it by accident.

  DefaultProvisionedSecretsDir* = "/run/attested-secrets"

  DefaultInstalledBinary* = "/usr/bin/attestation-agent"

type
  UnitOptions* = object
    binaryPath*: string
    listen*: string
    tier*: string
    measurementManifest*: string
    provisionedSecretsDir*: string

proc defaultUnitOptions*(): UnitOptions =
  UnitOptions(
    binaryPath: DefaultInstalledBinary,
    listen: DefaultListen,
    tier: "mock",
    measurementManifest: "",
    provisionedSecretsDir: DefaultProvisionedSecretsDir)

proc renderServiceUnit*(o: UnitOptions): string =
  ## The unit file, exactly as it is installed.
  if o.binaryPath.len == 0 or not o.binaryPath.startsWith("/"):
    raise newException(ValueError,
      "the service unit needs an absolute path to the agent binary, got " &
      o.binaryPath.escape())
  if o.listen.len == 0:
    raise newException(ValueError,
      "the service unit needs a listen address")
  if o.tier.len == 0:
    raise newException(ValueError,
      "the service unit needs a tier; a daemon that picked one for itself " &
      "could pick the one with no root of trust")

  # ``RuntimeDirectory`` is DERIVED from the flag rather than written
  # beside it. ``ProtectSystem=strict`` leaves the whole filesystem
  # read-only except the runtime directory systemd creates, so the
  # directory the daemon is told to write and the directory the unit
  # creates are one path — and a unit that spelled them separately would
  # be the second copy this file exists to avoid. A path anywhere else is
  # refused here, because the alternative is a daemon that starts and
  # then cannot write where it was told to.
  if not o.provisionedSecretsDir.startsWith("/run/") or
     o.provisionedSecretsDir.len <= "/run/".len or
     '/' in o.provisionedSecretsDir["/run/".len .. ^1]:
    raise newException(ValueError,
      "the provisioned-secrets directory must be a single name directly " &
      "under /run, got " & o.provisionedSecretsDir.escape() &
      "; ProtectSystem=strict leaves everything except this unit's " &
      "RuntimeDirectory read-only, and RuntimeDirectory is relative to /run")
  let runtimeDirectory = o.provisionedSecretsDir["/run/".len .. ^1]

  var exec = o.binaryPath & " serve" &
    " --listen=" & o.listen &
    " --tier=" & o.tier &
    " --provisioned-secrets-dir=" & o.provisionedSecretsDir
  if o.measurementManifest.len > 0:
    exec.add " --measurement-manifest=" & o.measurementManifest

  result = """[Unit]
Description=ReproOS attestation agent
Documentation=man:attestation-agent(8)
After=network.target
Wants=network.target

[Service]
Type=simple
ExecStart=$1
Restart=on-failure
RestartSec=2

# The agent holds no long-term keys and needs no persistent state. Its
# trustworthiness comes from being part of the measured image, so what a
# caller who takes the process gains is what matters, and the answer is
# meant to be almost nothing.
DynamicUser=yes
RuntimeDirectory=$3
RuntimeDirectoryMode=0700
NoNewPrivileges=yes
PrivateTmp=yes
PrivateDevices=no
ProtectSystem=strict
ProtectHome=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectKernelLogs=yes
ProtectControlGroups=yes
ProtectClock=yes
ProtectHostname=yes
ProtectProc=invisible
RestrictNamespaces=yes
RestrictRealtime=yes
RestrictSUIDSGID=yes
RestrictAddressFamilies=AF_INET AF_INET6
LockPersonality=yes
MemoryDenyWriteExecute=yes
SystemCallArchitectures=native
SystemCallFilter=@system-service
SystemCallErrorNumber=EPERM
CapabilityBoundingSet=
AmbientCapabilities=

[Install]
WantedBy=$2
""" % [exec, UnitWantedBy, runtimeDirectory]
