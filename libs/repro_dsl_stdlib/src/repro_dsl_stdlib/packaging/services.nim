## Service wiring, authored once, translated per format.
##
## §6: "Post-install service hooks (deb ``postinst`` / rpm ``%post`` /
## Arch ``.INSTALL`` / MSI custom actions / macOS scripts / rc.d) are
## generated from the abstract ``services`` list, so the
## systemd/launchd/etc. wiring is authored once."
##
## ## Why this module is small and M1 is where the work is
##
## M0's obligation about services is a *data-model* obligation, not a
## feature: M1's summary is what bakes "the three daemon roles' service
## units (systemd/launchd/Windows service/rc.d)" into every package, and
## the risk M0 has to retire is that ``ServiceDef`` turns out to be the
## wrong shape when M1 tries to use it. Two renderers over structurally
## opposite mechanisms is the cheapest way to find that out:
##
## * **systemd** reads a unit FILE that the package ships in its
##   payload, and the package enables it from a maintainer script that
##   runs after unpacking.
## * **The Windows SCM** has no file. The installer WRITES to the
##   service database, through rows in the MSI's ``ServiceInstall`` and
##   ``ServiceControl`` tables, at install time.
##
## Anything ``ServiceDef`` carries that only one of those can consume is
## a modelling error, and writing both is what surfaces it. Two of them
## showed up and are recorded below: ``ssUser`` has no SCM analogue at
## all, and systemd's ``After=`` is a unit-ordering graph while the
## SCM's is a load-order group — related ideas, not the same one.
##
## launchd and rc.d renderers are deliberately NOT here. They would be
## two more instances of a pattern this module has already demonstrated
## twice, and M0's gate does not exercise them; adding them now would be
## writing M1's code without M1's verification.

import std/[strutils]

import ./types
import ./runtime_contract

proc systemdUnitFileName*(svc: ServiceDef): string =
  svc.name & ".service"

proc systemdUnitPath*(dist: Distribution; svc: ServiceDef): string =
  ## Root-relative path of the unit inside a deb/rpm payload.
  ##
  ## ``lib/systemd/{system,user}`` and not ``etc/systemd/…``: ``/etc``
  ## is the administrator's, and a unit a package ships there cannot be
  ## masked or overridden by the admin without editing the package's own
  ## file. ``/lib`` (merged-usr distributions symlink it to
  ## ``/usr/lib``) is the vendor location, which is what a package's
  ## unit is. Note this is ROOT-relative, not prefix-relative: systemd
  ## looks in fixed absolute locations, so a package installed under
  ## ``/opt`` still ships its unit here.
  discard dist
  case svc.scope
  of ssSystem: "lib/systemd/system/" & systemdUnitFileName(svc)
  of ssUser: "lib/systemd/user/" & systemdUnitFileName(svc)

proc installedExecPath*(dist: Distribution; svc: ServiceDef): string =
  ## Absolute path the service's executable will have once installed.
  ##
  ## The PUBLIC name, i.e. the §5 wrapper when there is one — a service
  ## that ran the unwrapped binary would start without the environment
  ## defaults the package exists to supply, which is the exact failure
  ## §5 is written to prevent and the one that would be hardest to
  ## diagnose from a unit that otherwise looks correct.
  var prefix = dist.prefix
  if prefix.len == 0 or not prefix.startsWith("/"):
    prefix = "/" & prefix.strip(chars = {'/'})
  let binDirRel = roleDefaultSubdir(dist, crExecutable)
  prefix.strip(leading = false, trailing = true, chars = {'/'}) & "/" &
    binDirRel & "/" & svc.execComponent

proc systemdUnitText*(dist: Distribution; svc: ServiceDef): string =
  ## Render one systemd unit from the abstract definition.
  var execLine = installedExecPath(dist, svc)
  for arg in svc.execArgs:
    # systemd's own splitting rules apply to ExecStart; quoting an
    # argument that contains whitespace is the documented way to keep
    # it one argument.
    if arg.contains(' ') or arg.contains('\t'):
      execLine.add(" \"" & arg.replace("\"", "\\\"") & "\"")
    else:
      execLine.add(" " & arg)
  result = "[Unit]\n"
  let desc =
    if svc.description.len > 0: svc.description
    elif svc.displayName.len > 0: svc.displayName
    else: svc.name
  result.add("Description=" & desc.splitLines()[0] & "\n")
  for dep in svc.after:
    result.add("After=" & dep & "\n")
  result.add("\n[Service]\n")
  result.add("Type=simple\n")
  result.add("ExecStart=" & execLine & "\n")
  for (name, value) in svc.environment:
    result.add("Environment=" & name & "=" & value & "\n")
  if svc.restartOnFailure:
    result.add("Restart=on-failure\n")
  result.add("\n[Install]\n")
  result.add(
    case svc.scope
    of ssSystem: "WantedBy=multi-user.target\n"
    of ssUser: "WantedBy=default.target\n")

proc systemServices*(dist: Distribution): seq[ServiceDef] =
  for svc in dist.services:
    if svc.scope == ssSystem: result.add(svc)

proc userServices*(dist: Distribution): seq[ServiceDef] =
  for svc in dist.services:
    if svc.scope == ssUser: result.add(svc)

proc debPostInstText*(dist: Distribution): string =
  ## The ``postinst`` that enables and starts what the package shipped.
  ##
  ## ``deb-systemd-invoke`` / ``deb-systemd-helper`` are the Debian
  ## policy-blessed wrappers and are guarded rather than assumed:
  ## a container image routinely has no running systemd, and a
  ## maintainer script that fails there fails the whole ``dpkg -i`` —
  ## which is exactly the environment the M0 gate installs the package
  ## in. Guarding is not a workaround for the test; Debian policy
  ## requires a maintainer script to succeed on a system where the init
  ## system is not systemd.
  let system = systemServices(dist)
  result = "#!/bin/sh\n"
  result.add("# Generated by the reprobuild DSL packaging layer.\n")
  result.add("set -e\n")
  result.add("\n")
  result.add("if [ \"$1\" != \"configure\" ]; then\n")
  result.add("  exit 0\n")
  result.add("fi\n")
  if system.len == 0:
    result.add("exit 0\n")
    return
  result.add("\n")
  result.add("if [ -d /run/systemd/system ] && " &
    "command -v systemctl >/dev/null 2>&1; then\n")
  result.add("  systemctl daemon-reload >/dev/null 2>&1 || true\n")
  for svc in system:
    let unit = systemdUnitFileName(svc)
    if svc.startAtBoot:
      result.add("  systemctl enable " & unit & " >/dev/null 2>&1 || true\n")
      result.add("  systemctl start " & unit & " >/dev/null 2>&1 || true\n")
  result.add("fi\n")
  result.add("exit 0\n")

proc debPreRmText*(dist: Distribution): string =
  ## Stop the services before the files they run go away.
  let system = systemServices(dist)
  result = "#!/bin/sh\n"
  result.add("# Generated by the reprobuild DSL packaging layer.\n")
  result.add("set -e\n")
  if system.len == 0:
    result.add("exit 0\n")
    return
  result.add("\n")
  result.add("if [ -d /run/systemd/system ] && " &
    "command -v systemctl >/dev/null 2>&1; then\n")
  for svc in system:
    let unit = systemdUnitFileName(svc)
    result.add("  systemctl stop " & unit & " >/dev/null 2>&1 || true\n")
    result.add("  systemctl disable " & unit & " >/dev/null 2>&1 || true\n")
  result.add("fi\n")
  result.add("exit 0\n")

# ---------------------------------------------------------------------------
# The Windows arm.
# ---------------------------------------------------------------------------

type
  MsiServiceRow* = object
    ## A ``ServiceDef`` projected onto what WiX v3's ``ServiceInstall``
    ## element actually accepts.
    ##
    ## A named projection type, rather than the MSI producer reading
    ## ``ServiceDef`` fields inline, so the two places the model does NOT
    ## survive the crossing are recorded in the type system instead of
    ## in a comment somebody will delete:
    ##
    ## * ``ssUser`` services do not appear here at all. The Windows SCM
    ##   has no per-user services; the nearest equivalents (a Run-key
    ##   entry, a Task Scheduler task) are different mechanisms with
    ##   different lifetimes, and silently substituting one would ship a
    ##   package that installs something other than what the recipe
    ##   asked for. ``msiServiceRows`` drops them and the MSI producer
    ##   says so.
    ## * ``after`` is dropped. systemd's ``After=`` orders units in a
    ##   dependency graph; the SCM's nearest concept is
    ##   ``LoadOrderGroup`` plus ``ServiceDependency``, which orders
    ##   *drivers and services by name at boot*. They are related ideas,
    ##   not the same one, and mapping ``network.target`` onto either
    ##   would be an invention.
    id*: string
    name*: string
    displayName*: string
    description*: string
    exeRelPath*: string
      ## Prefix-relative path of the executable the SCM will run.
      ##
      ## The REAL binary, not the §5 wrapper — the one place the two
      ## service mechanisms need opposite answers. systemd's
      ## ``ExecStart`` can and should be the wrapper, because a shell
      ## script is a perfectly good thing for systemd to fork. The SCM
      ## cannot: a Windows service must be an executable image that
      ## talks the service-control protocol back to the SCM, and a
      ## ``.cmd`` file cannot, so pointing ``ServiceInstall`` at the
      ## wrapper produces a service that fails to start with error
      ## 193. That is why the environment defaults the wrapper would
      ## have supplied are carried separately, as the SCM's own
      ## ``Environment`` registry value (see ``environment`` below).
    args*: seq[string]
    startAtBoot*: bool
    restartOnFailure*: bool
    environment*: seq[(string, string)]

proc msiIdentifier*(value: string): string =
  ## MSI identifiers are ``[A-Za-z_][A-Za-z0-9_.]*`` and at most 72
  ## characters. A name that violates that makes ``light`` fail with a
  ## message about the Identifier column rather than about the recipe,
  ## so the mapping happens here, once.
  var ident = ""
  for ch in value:
    if ch.isAlphaNumeric or ch == '_' or ch == '.': ident.add(ch)
    else: ident.add('_')
  if ident.len == 0: ident = "Id"
  if not (ident[0].isAlphaAscii or ident[0] == '_'):
    ident = "_" & ident
  if ident.len > 72: ident = ident[0 ..< 72]
  ident

proc msiServiceRows*(dist: Distribution): seq[MsiServiceRow] =
  ## Project the abstract services onto the SCM's model, dropping what
  ## does not cross. See ``MsiServiceRow``.
  for svc in dist.services:
    if svc.scope != ssSystem:
      continue
    # Resolve to the file the SCM can actually start. When the §5
    # contract wraps the executables the public name belongs to a
    # ``.cmd``, which is not a service image.
    let target =
      if dist.runtime.wrapExecutables:
        realFileName(dist, svc.execComponent)
      else:
        svc.execComponent
    result.add(MsiServiceRow(
      id: msiIdentifier("Svc_" & svc.name),
      name: svc.name,
      displayName:
        if svc.displayName.len > 0: svc.displayName else: svc.name,
      description: svc.description.splitLines()[0],
      exeRelPath: roleDefaultSubdir(dist, crExecutable) & "/" & target,
      args: svc.execArgs,
      startAtBoot: svc.startAtBoot,
      restartOnFailure: svc.restartOnFailure,
      environment: svc.environment))

proc droppedUserServices*(dist: Distribution): seq[string] =
  ## Names of services an MSI cannot express. The producer surfaces
  ## these rather than dropping them silently.
  for svc in dist.services:
    if svc.scope == ssUser: result.add(svc.name)
