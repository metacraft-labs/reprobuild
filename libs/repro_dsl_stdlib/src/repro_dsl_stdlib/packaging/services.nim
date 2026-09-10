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
## THE LAUNCHD RENDERER IS NOW HERE AND THE RC.D ONE IS STILL NOT, and
## the two answers have different reasons rather than one reason applied
## unevenly.
##
## M0 left both out with one sentence -- "adding them now would be
## writing M1's code without M1's verification" -- and that argument is
## still true of launchd: there is no Darwin host in this environment,
## so `launchdPlistText` below has NEVER BEEN LOADED BY LAUNCHD. What
## changed is what the alternative costs. M1 ships a package whose
## `Distribution` carries `services`, and on a Darwin target that list
## was silently rendered to nothing at all: not "unsupported", not a
## refusal -- a `.pkg` with a daemon in its data model and no daemon in
## its payload. A renderer whose TEXT is pinned by cases is strictly
## better than that, because the failure mode it leaves is "the plist
## may be wrong", which someone with a Mac can check in a minute,
## rather than "the service is absent", which looks like success.
##
## So: the plist grammar, the four mappings that are NOT one-to-one, and
## the one that is a genuine semantic inversion (see `Disabled` in
## `launchdPlistText`) are all unit-verified. Nothing here is
## host-verified, and the milestone says so in those words.
##
## rc.d is different, and the blocker is not the host. `TargetOs` has
## three values -- Linux, Darwin, Windows -- so there is no *BSD target
## to render an rc.d script FOR. Writing the renderer would mean adding
## a fourth target first, which pulls in a prefix layout
## (`/usr/local` rather than `/usr`), an ELF interpreter path, a
## never-vendor library set for a libc that is not glibc, and a
## dependency-floor computation that has no `libc6` to name -- a
## data-model change whose first consumer could not be run anywhere in
## this environment. That is a bigger claim than "no host", and it is
## the honest reason rc.d is absent.

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
# The rpm arm.
#
# Same systemd unit, different scriptlet vocabulary. Deliberately plain
# ``/bin/sh`` rather than the ``%systemd_post`` / ``%systemd_preun``
# macros: those come from the ``systemd-rpm-macros`` package, which a
# minimal image (and every non-systemd rpm distribution) need not carry,
# and a spec that used them would fail to BUILD on a host without them
# — turning a runtime concern into a build-time host assumption, which
# is the thing §6 rule 1 is about.
#
# The guard is the same one the deb scriptlets use, for the same
# reason: without ``/run/systemd/system`` there is no systemd running
# and ``systemctl`` would either fail or, worse, talk to the host's
# systemd from inside a container.
# ---------------------------------------------------------------------------

proc rpmPostText*(dist: Distribution): string =
  ## The ``%post`` scriptlet. rpm passes the number of packages of this
  ## name that will be installed once the transaction completes: 1 on a
  ## first install, 2 on an upgrade. Enabling on an upgrade would
  ## re-enable a unit the admin had deliberately disabled, so the
  ## enable arm is guarded on ``$1 = 1``.
  let system = systemServices(dist)
  if system.len == 0:
    return "/bin/true\n"
  result = "if [ -d /run/systemd/system ] && " &
    "command -v systemctl >/dev/null 2>&1; then\n"
  result.add("  systemctl daemon-reload >/dev/null 2>&1 || true\n")
  var anyBoot = false
  for svc in system:
    if svc.startAtBoot: anyBoot = true
  if anyBoot:
    result.add("  if [ \"$1\" = \"1\" ]; then\n")
    for svc in system:
      if svc.startAtBoot:
        let unit = systemdUnitFileName(svc)
        result.add("    systemctl enable " & unit &
          " >/dev/null 2>&1 || true\n")
        result.add("    systemctl start " & unit &
          " >/dev/null 2>&1 || true\n")
    result.add("  fi\n")
  result.add("fi\n")
  result.add("exit 0\n")

proc rpmPreUnText*(dist: Distribution): string =
  ## The ``%preun`` scriptlet. ``$1`` is the number of instances that
  ## will REMAIN: 0 on a real removal, 1 during an upgrade's removal of
  ## the old package. Stopping on an upgrade would take the service down
  ## and leave it down, so this fires only at ``$1 = 0`` — which is the
  ## one place rpm's scriptlet contract differs materially from deb's
  ## ``prerm`` and the reason these are two procs rather than one.
  let system = systemServices(dist)
  if system.len == 0:
    return "/bin/true\n"
  result = "if [ \"$1\" = \"0\" ]; then\n"
  result.add("  if [ -d /run/systemd/system ] && " &
    "command -v systemctl >/dev/null 2>&1; then\n")
  for svc in system:
    let unit = systemdUnitFileName(svc)
    result.add("    systemctl stop " & unit & " >/dev/null 2>&1 || true\n")
    result.add("    systemctl disable " & unit & " >/dev/null 2>&1 || true\n")
  result.add("  fi\n")
  result.add("fi\n")
  result.add("exit 0\n")

proc rpmPostUnText*(dist: Distribution): string =
  ## The ``%postun`` scriptlet: tell systemd the unit files are gone.
  ## Separate from ``%preun`` because at ``%preun`` time the files are
  ## still on disk, so a ``daemon-reload`` there would re-read the unit
  ## that is about to vanish.
  let system = systemServices(dist)
  if system.len == 0:
    return "/bin/true\n"
  result = "if [ -d /run/systemd/system ] && " &
    "command -v systemctl >/dev/null 2>&1; then\n"
  result.add("  systemctl daemon-reload >/dev/null 2>&1 || true\n")
  result.add("fi\n")
  result.add("exit 0\n")

# ---------------------------------------------------------------------------
# The Darwin arm.
#
# NOT HOST-VERIFIED. There is no macOS machine in this environment, so
# every claim below is about the TEXT this renders and none is about
# what launchd does with it.
# ---------------------------------------------------------------------------

proc launchdLabel*(dist: Distribution; svc: ServiceDef): string =
  ## The plist's ``Label``, which is launchd's primary key: two loaded
  ## jobs may not share one, and ``launchctl`` addresses a job by it.
  ##
  ## ``<package>.<service>``, and deliberately NOT a reverse-DNS string.
  ## Apple's convention is ``com.example.foo``, and a layer that wanted
  ## to follow it would have to invent an organisation's domain for
  ## every recipe that did not supply one -- a name that means something
  ## in the world, chosen by a build system. Reverse-DNS is a CONVENTION
  ## and uniqueness is the REQUIREMENT; the package name plus the
  ## service name is unique by the same argument that makes
  ## ``installRelPath`` unique, and ``validate`` already refuses two
  ## components that collide.
  if svc.name == dist.name: svc.name
  else: dist.name & "." & svc.name

proc launchdPlistFileName*(dist: Distribution; svc: ServiceDef): string =
  launchdLabel(dist, svc) & ".plist"

proc launchdPlistPath*(dist: Distribution; svc: ServiceDef): string =
  ## Root-relative path of the plist inside a ``.pkg`` payload.
  ##
  ## ROOT-relative rather than prefix-relative, exactly as
  ## ``systemdUnitPath`` is and for the same reason: launchd reads four
  ## fixed absolute directories and nothing else, so a package installed
  ## under ``/opt`` still puts its plist here.
  ##
  ## ``LaunchDaemons`` for system scope, ``LaunchAgents`` for user
  ## scope, both under ``/Library`` rather than ``/System/Library``
  ## (Apple's, SIP-protected) or ``~/Library`` (per-user, and a package
  ## installer has no user to write it for -- the same argument that
  ## keeps the systemd USER unit out of ``postinst``'s enable list).
  discard dist
  case svc.scope
  of ssSystem: "Library/LaunchDaemons/" & launchdPlistFileName(dist, svc)
  of ssUser: "Library/LaunchAgents/" & launchdPlistFileName(dist, svc)

proc plistEscape(value: string): string =
  for ch in value:
    case ch
    of '&': result.add("&amp;")
    of '<': result.add("&lt;")
    of '>': result.add("&gt;")
    else: result.add(ch)

proc launchdPlistText*(dist: Distribution; svc: ServiceDef): string =
  ## Render one launchd job from the abstract definition.
  ##
  ## FOUR MAPPINGS ARE NOT ONE-TO-ONE, and each is a place where copying
  ## the systemd renderer's shape would have produced a plausible file
  ## that behaves differently:
  ##
  ## 1. ``startAtBoot = false`` INVERTS. A systemd unit that a package
  ##    ships and does not ``enable`` simply does not run. launchd has
  ##    no enable step: it loads every plist in ``/Library/LaunchDaemons``
  ##    at boot, so shipping the file IS enabling it. The analogue of
  ##    "installed but not enabled" is therefore an explicit
  ##    ``Disabled`` key, and omitting it would make the Darwin package
  ##    start a service on install that every other format's package
  ##    does not -- which for ``repro-binary-cache`` means opening
  ##    ``0.0.0.0:7878`` on a machine whose administrator has not chosen
  ##    a root, a key or a network boundary.
  ## 2. ``RunAtLoad`` is a SECOND, different switch: it decides whether
  ##    a LOADED job starts immediately rather than on demand. Both are
  ##    written, because writing only one leaves the other at a default
  ##    that differs between macOS releases.
  ## 3. ``restartOnFailure`` becomes ``KeepAlive`` with
  ##    ``SuccessfulExit = false``, which is "restart unless it exited
  ##    zero". A bare ``KeepAlive = true`` is the nearest-looking value
  ##    and is wrong: it restarts a job that exited SUCCESSFULLY, which
  ##    turns a one-shot into a spin.
  ## 4. ``after`` is DROPPED, as it is for the MSI and for the same
  ##    class of reason: launchd has no ordering graph. It has
  ##    ``KeepAlive``-with-conditions and ``launchd``-managed sockets,
  ##    which express "start when this is available" rather than "start
  ##    after this unit", and mapping ``network.target`` onto either
  ##    would be an invention.
  ##
  ## The executable is the PUBLIC name -- the §5 wrapper when there is
  ## one -- matching systemd and NOT matching the MSI. launchd forks an
  ## ordinary process and a shell script is a perfectly good thing to
  ## fork; the Windows SCM's requirement for a service image is what
  ## makes that arm the exception.
  result = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
  result.add("<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" " &
    "\"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n")
  result.add("<plist version=\"1.0\">\n")
  result.add("<dict>\n")
  result.add("  <key>Label</key>\n  <string>" &
    plistEscape(launchdLabel(dist, svc)) & "</string>\n")
  result.add("  <key>ProgramArguments</key>\n  <array>\n")
  result.add("    <string>" &
    plistEscape(installedExecPath(dist, svc)) & "</string>\n")
  for arg in svc.execArgs:
    result.add("    <string>" & plistEscape(arg) & "</string>\n")
  result.add("  </array>\n")
  if svc.environment.len > 0:
    result.add("  <key>EnvironmentVariables</key>\n  <dict>\n")
    for pair in svc.environment:
      result.add("    <key>" & plistEscape(pair[0]) & "</key>\n")
      result.add("    <string>" & plistEscape(pair[1]) & "</string>\n")
    result.add("  </dict>\n")
  result.add("  <key>RunAtLoad</key>\n  <" &
    (if svc.startAtBoot: "true" else: "false") & "/>\n")
  # See (1): the inversion. A plist that omits this starts at boot.
  result.add("  <key>Disabled</key>\n  <" &
    (if svc.startAtBoot: "false" else: "true") & "/>\n")
  if svc.restartOnFailure:
    result.add("  <key>KeepAlive</key>\n  <dict>\n")
    result.add("    <key>SuccessfulExit</key>\n    <false/>\n")
    result.add("  </dict>\n")
  result.add("</dict>\n")
  result.add("</plist>\n")

proc darwinUnsupportedServices*(dist: Distribution): seq[string] =
  ## Names of services a launchd package cannot express.
  ##
  ## EMPTY, today, and that is the finding rather than an omission:
  ## launchd is the one of the three mechanisms that has BOTH scopes
  ## (``LaunchDaemons`` and ``LaunchAgents``), so unlike the MSI it drops
  ## nothing. The proc exists anyway, with the same name-shape as
  ## ``droppedUserServices``, so a producer asks the same question of
  ## every target instead of knowing which targets have an answer.
  discard dist

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
