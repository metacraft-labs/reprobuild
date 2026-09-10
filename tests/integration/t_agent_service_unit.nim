## The service unit and the daemon it starts agree about the daemon.
##
## ## What this gate is for
##
## A unit file and an argument parser are two spellings of the same
## contract, kept in different files, edited by different changes. When
## they drift the machine still builds, still installs and still boots —
## and the agent fails at start-up on a host nobody is watching, which is
## the worst place to discover a renamed flag.
##
## So the unit is not compared against an expected string. It is
## *rendered*, its ``ExecStart`` is taken apart, and the result is fed
## through the parser the daemon actually uses. The gate asserts that the
## options which come out are the options the unit was rendered from.
## Renaming a flag on either side breaks it; renaming it on both sides,
## consistently, does not — which is correct, because that is not a
## defect.
##
## The hardening directives are checked as *bindings* (``Key=Value``
## after comments are stripped), not as names appearing somewhere in the
## file. A directive is either set to what it must be or it is not there,
## and a check that only looked for the name would pass on a unit that
## mentioned it in a comment and on one that set it to the opposite.
##
## ## What this gate does not prove
##
## It does not boot anything. That the unit *starts* the agent on a real
## ReproOS image is the image build's to show, and no image build was
## run here. What is established here is that the file the image
## installs describes this binary, and that its sandboxing directives say
## what they are meant to say.
##
## ## Mocking
##
## None.

import std/[strutils, unittest]

import repro_attest_agent
import repro_attest_agent/cli

proc execStartOf(unitText: string): string =
  ## The ``ExecStart=`` value from the ``[Service]`` section, and only
  ## from there. Scoped to the section rather than scanned for from the
  ## top of the file: a forward scan that runs past the section under
  ## test finds whatever the next one happens to contain.
  var inService = false
  for raw in unitText.splitLines:
    let line = raw.strip()
    if line.startsWith("["):
      inService = line == "[Service]"
      continue
    if not inService: continue
    if line.startsWith("ExecStart="):
      return line["ExecStart=".len .. ^1]
  ""

proc directivesOf(unitText, section: string): seq[(string, string)] =
  ## Every ``Key=Value`` binding in one section, with comment and blank
  ## lines dropped. Bindings, not names.
  var inSection = false
  for raw in unitText.splitLines:
    let line = raw.strip()
    if line.len == 0 or line.startsWith("#") or line.startsWith(";"):
      continue
    if line.startsWith("["):
      inSection = line == section
      continue
    if not inSection: continue
    let eq = line.find('=')
    if eq <= 0: continue
    result.add (line[0 ..< eq], line[eq + 1 .. ^1])

proc valueOf(bindings: seq[(string, string)]; key: string): string =
  ## The LAST binding of a key, because that is the one systemd uses for
  ## a non-list directive. Reading the first would be defeated by a decoy
  ## below it saying the opposite.
  result = "<absent>"
  for (k, v) in bindings:
    if k == key: result = v

suite "attestation agent — the service unit describes this daemon":

  test "the unit's ExecStart parses as this binary's own command line":
    # Values chosen to differ from every default, so a renderer that
    # ignored its options and printed the defaults would fail here rather
    # than pass by coincidence.
    var opts: Options
    opts.sub = scServe
    opts.binaryPath = "/opt/reproos/bin/attestation-agent"
    opts.listen = "127.0.0.1:7777"
    opts.tier = "mock"
    opts.manifestPath = "/etc/reproos/reproos.attested-image.json"
    opts.provisionedSecretsDir = "/run/secrets-under-test"

    let unitText = renderServiceUnit(unitOptionsFor(opts))
    let exec = execStartOf(unitText)
    check exec.len > 0
    let words = exec.splitWhitespace()
    check words[0] == opts.binaryPath

    # The flags the unit writes, read by the parser that will read them
    # at boot. A flag renamed on one side only stops parsing here.
    let reparsed = parseArgs(words[1 .. ^1])
    check reparsed.sub == scServe
    check reparsed.listen == opts.listen
    check reparsed.tier == opts.tier
    check reparsed.manifestPath == opts.manifestPath
    check reparsed.provisionedSecretsDir == opts.provisionedSecretsDir

  test "a unit rendered without a manifest still parses, and omits the flag":
    var opts: Options
    opts.sub = scServe
    opts.binaryPath = "/usr/bin/attestation-agent"
    opts.listen = DefaultListen
    opts.tier = "mock"
    opts.provisionedSecretsDir = DefaultProvisionedSecretsDir

    let exec = execStartOf(renderServiceUnit(unitOptionsFor(opts)))
    check "--measurement-manifest" notin exec
    let reparsed = parseArgs(exec.splitWhitespace()[1 .. ^1])
    check reparsed.manifestPath.len == 0
    check reparsed.listen == DefaultListen

  test "an unparseable ExecStart would be caught, so the check above can fail":
    # The cross-check is only worth something if the parser refuses a
    # flag the unit might grow. Shown here directly rather than assumed.
    expect ValueError:
      discard parseArgs(@["serve", "--listen-address=127.0.0.1:1"])
    expect ValueError:
      discard parseArgs(@["not-a-subcommand"])

  test "the sandboxing directives are set, as bindings and not as names":
    let unitText = renderServiceUnit(defaultUnitOptions())
    let service = directivesOf(unitText, "[Service]")

    for (key, want) in {
        "Type": "simple",
        "Restart": "on-failure",
        "DynamicUser": "yes",
        "NoNewPrivileges": "yes",
        "PrivateTmp": "yes",
        "ProtectSystem": "strict",
        "ProtectHome": "yes",
        "ProtectKernelModules": "yes",
        "ProtectControlGroups": "yes",
        "RestrictSUIDSGID": "yes",
        "RestrictNamespaces": "yes",
        "LockPersonality": "yes",
        "MemoryDenyWriteExecute": "yes",
        "SystemCallArchitectures": "native",
        "SystemCallFilter": "@system-service",
        "RestrictAddressFamilies": "AF_INET AF_INET6",
        "CapabilityBoundingSet": "",
        "AmbientCapabilities": ""}:
      check service.valueOf(key) == want

    # `Restart=always` would make the surface impossible to shut down, so
    # the value matters and not merely the key's presence.
    check service.valueOf("Restart") != "always"

    # The literal, not `UnitWantedBy`. Comparing the rendered unit
    # against the constant that rendered it passes however that constant
    # is spelled — including as a target the machine never reaches — so
    # the check would be a tautology rather than a claim about when the
    # agent starts.
    let install = directivesOf(unitText, "[Install]")
    check install.valueOf("WantedBy") == "multi-user.target"
    check UnitWantedBy == "multi-user.target"

  test "the install path is the one current systemd actually searches":
    # `lib/systemd/system` was dropped from the default unit search, so a
    # unit installed there is a unit that is never found. Pinned as a
    # value because the failure it prevents is silent.
    check UnitInstallDir == "usr/lib/systemd/system"
    check not UnitInstallDir.startsWith("lib/")
    check UnitName == "attestation-agent.service"
    check UnitName.endsWith(".service")

  test "the renderer refuses a unit that could not start anything":
    var broken = defaultUnitOptions()
    broken.binaryPath = "attestation-agent"      # not absolute
    expect ValueError: discard renderServiceUnit(broken)

    broken = defaultUnitOptions()
    broken.listen = ""
    expect ValueError: discard renderServiceUnit(broken)

    broken = defaultUnitOptions()
    broken.tier = ""
    expect ValueError: discard renderServiceUnit(broken)

    # The positive polarity: the defaults render.
    check renderServiceUnit(defaultUnitOptions()).len > 0

  test "the runtime directory is the directory the daemon is told to write":
    # The one place this unit could still keep two spellings of one fact:
    # `ProtectSystem=strict` makes everything read-only except the
    # `RuntimeDirectory` systemd creates, so a `--provisioned-secrets-dir`
    # naming anywhere else is a daemon that starts and then cannot write.
    # Checked as an agreement between the two, not as two literals.
    var opts = defaultUnitOptions()
    opts.provisionedSecretsDir = "/run/secrets-under-test"
    let unitText = renderServiceUnit(opts)
    let runtimeDir = directivesOf(unitText, "[Service]").valueOf(
      "RuntimeDirectory")
    check runtimeDir == "secrets-under-test"
    check "--provisioned-secrets-dir=/run/" & runtimeDir in
      execStartOf(unitText)

    # And the defaults agree with each other for the same reason.
    let shipped = renderServiceUnit(defaultUnitOptions())
    check "--provisioned-secrets-dir=/run/" &
      directivesOf(shipped, "[Service]").valueOf("RuntimeDirectory") in
      execStartOf(shipped)

    # A directory systemd would not create is refused at render time
    # rather than at boot on a machine nobody is watching.
    for elsewhere in ["/var/lib/attested-secrets", "/run", "/tmp/x",
                      "/run/nested/dir"]:
      var broken = defaultUnitOptions()
      broken.provisionedSecretsDir = elsewhere
      expect ValueError: discard renderServiceUnit(broken)

  test "the default listen address is loopback":
    # The API is a pre-authentication surface. A default that bound every
    # interface would put it on the network of every machine that enabled
    # the unit without anyone deciding to.
    check DefaultListen.startsWith("127.0.0.1:")
    check "0.0.0.0" notin renderServiceUnit(defaultUnitOptions())
