## The `attestation` activity: remote attestation of this machine's
## configuration, enabled the same way every other system-scope activity
## is.
##
## ## What an activity module is here, and what it is not
##
## A system-scope activity is a named bundle of contributions — packages
## to install, services to enable, groups to create — that a profile
## turns on as one decision. This module is the `attestation` bundle: the
## `attestation-agent` package and the `attestation-agent.service` unit,
## which together are the whole of what enabling attestation adds to a
## machine.
##
## What it is NOT is a declaration written in a configuration language of
## its own. The `activity` macro in `repro_profile` parses exactly seven
## body sections — `displayName`, `description`, `icon`,
## `systemPackages`, `systemServices`, `groups` and `homeContributions` —
## and every one of them takes a name or a list of names. In particular
## there is:
##
##   * no `config:` section, so an activity cannot declare typed,
##     defaulted settings of its own;
##   * no `@variant` annotation, so an activity cannot say that one of
##     those settings changes the package closure rather than only the
##     activation;
##   * no `validate:` section, so an activity cannot carry a rule
##     relating two of its settings, or relating a setting to the image
##     it will run inside;
##   * and `systemServices` is a list of unit names, so an activity
##     cannot say `enable: true` or `wantedBy:` per unit — what a unit
##     does when enabled comes from the unit file, which the agent
##     renders for itself (`repro_attest_agent/unit`).
##
## Those forms are worth having and are not here yet. Until they are, the
## parts of this activity that need them are ORDINARY NIM in this module:
## a typed `AttestationActivityConfig` with defaults, and
## `validateAttestationConfig`, a hand-written proc that raises
## `EConfigViolation`. That is the same escape hatch `reproos_desktop`
## takes for the same reason, and it is written down in both places
## rather than left for a reader to discover by finding that the
## declaration they copied out of a document does not compile.
##
## ## Where the rule bites
##
## A profile evaluates this module while `repro infra plan` is compiling
## it, long before anything is applied and long before anything boots. So
## a configuration this module refuses is a plan that does not exist,
## with the refusal naming both halves of the contradiction — rather than
## a machine that comes up running an agent that cannot produce evidence
## anybody would accept.
##
## ## The rule itself, and why a tier is not free to pick a layout
##
## An attestation tier names the root of trust that signs what the
## machine says about itself. Two of the three — `cvm` and `tpm` — sign a
## LAUNCH MEASUREMENT: a digest of the bytes the machine booted, taken by
## something below the operating system. A measurement is only worth
## quoting if those bytes are fixed and integrity-checked for the life of
## the boot; on a layout whose root filesystem is an ordinary writable
## volume, the thing measured at boot and the thing running an hour later
## are not the same thing, and the quote says nothing about the second.
##
## `mock` is the exception, and deliberately: it has no root of trust at
## all, produces evidence a production policy is required to refuse, and
## exists so that every layer above it can be developed and tested on a
## machine with no attestation hardware. Pinning it to an attestable
## layout would defeat the only purpose it has.
##
## Hence the rule: a tier that is not `mock` requires an image layout
## that can carry an integrity-checked, read-only root.
##
## ## What the rule does not check, stated plainly
##
## `imageLayout` is the name the image recipe was given. This module
## cannot observe the disk it will run on — at plan time there is no such
## disk, and at run time the agent is inside the image rather than above
## it. So the rule cross-checks TWO DECLARATIONS that would otherwise
## only meet at boot: the tier this profile enables, and the layout the
## image it is installed into was built for. A profile that names a
## layout its image was not built with is not caught here, and nothing at
## plan time could catch it.
##
## ## Mocking
##
## None. The validator is a pure function of the config, and the unit
## check below runs the real renderer the image build uses.

import std/strutils

import repro_attest/report
import repro_attest_agent/unit
import repro_profile

import ./config_violation

export config_violation

# The tier enum is re-exported whole — Nim cannot export an enum's
# fields one at a time — so a profile that writes `tier: atTpm` needs
# only this module. The vocabulary itself stays in `repro_attest`: the
# set of roots of trust is a property of the evidence model, not of the
# activity that switches one on.
export report.AttestationTier

# The agent's own defaults, re-exported so a profile that wants to name
# one writes the constant rather than a second copy of its value.
export unit.DefaultListen, unit.DefaultProvisionedSecretsDir, unit.UnitName

const
  ActivityName* = "attestation"

  AgentPackage* = "attestation-agent"
    ## The Tier-1 package the activity installs. One name, matching the
    ## binary the service unit's `ExecStart` names.

  AttestableImageLayouts* = ["uefi-attested"]
    ## The image layouts on which a launch measurement means anything:
    ## the root filesystem is integrity-checked and read-only for the
    ## whole life of the boot, and everything writable is off the
    ## measured surface.
    ##
    ## A LIST rather than a single constant because this is a property of
    ## a layout, not a name: a second attestable layout would be added
    ## here and the rule below would not change. It is not a list of
    ## "layouts that exist" — an unknown name is refused by the image
    ## recipe's own registry, which is where the set of legal names
    ## lives.

type
  AttestationActivityConfig* = object
    ## What enabling the activity can be told. The fields a `config:`
    ## section would declare if an activity body had one.
    tier*: AttestationTier
      ## Root-of-trust tier. CLOSURE-AFFECTING: the guest drivers and
      ## vendor libraries the agent needs differ per tier, so this is
      ## the field a `@variant` annotation would mark. Nothing in the
      ## current build varies its closure on it — the mock backend is
      ## the only one compiled in — so the annotation would today be a
      ## promise about a future closure rather than a description of
      ## this one.
    listen*: string
      ## Listen address for the agent API. Loopback by default;
      ## deployments front it with their own authenticated channel.
    exposeRemotely*: bool
      ## Whether the API is meant to be reachable from outside the
      ## machine. It does NOT open anything by itself: see
      ## `validateAttestationConfig` for what it is checked against, and
      ## the note below for what it does not yet do.
    provisionedSecretsDir*: string
      ## Where secrets provisioned to this instance are delivered. A
      ## tmpfs the unit creates; never persisted.
    imageLayout*: string
      ## The name of the disk layout the image this profile configures
      ## was built for — the value the image recipe was given, carried
      ## here so the rule below can be decided at plan time.
      ##
      ## It is a field on the activity rather than something read out of
      ## the machine because at plan time there is no machine: the image
      ## does not exist yet, and the profile is being evaluated on
      ## whatever host happens to be running the planner. See the
      ## module header for what that means the rule can and cannot
      ## catch.

proc attestationConfig*(imageLayout: string;
                        tier = atMock;
                        listen = DefaultListen;
                        exposeRemotely = false;
                        provisionedSecretsDir = DefaultProvisionedSecretsDir):
    AttestationActivityConfig =
  ## Build a configuration, taking the defaults for anything not named.
  ##
  ## This proc is what a `config:` section would be if an activity body
  ## had one: every setting has a default, and a profile writes only the
  ## ones it disagrees with. It is the *supported* way to construct the
  ## config — the object type is exported too, but constructing it
  ## directly means Nim's own zero values for the fields left out, and
  ## an empty listen address is not the shipped default, it is nothing.
  ##
  ## `imageLayout` has no default and is positional, deliberately: it is
  ## the field the rule below turns on, and a default for it would be
  ## this module quietly deciding what image the operator is building.
  ##
  ## `mock` IS the default tier, because it is the tier that runs
  ## anywhere. A deployment that has a root of trust says so, and saying
  ## so is exactly what brings the layout rule into force.
  AttestationActivityConfig(
    tier: tier,
    listen: listen,
    exposeRemotely: exposeRemotely,
    provisionedSecretsDir: provisionedSecretsDir,
    imageLayout: imageLayout)

proc unitOptionsFor*(cfg: AttestationActivityConfig): UnitOptions =
  ## The service-unit options this configuration implies.
  ##
  ## Derived rather than written out a second time: the listen address
  ## the daemon is told to bind and the directory it is told to write are
  ## the same two values in both places, and a unit that spelled them
  ## separately is the drift `repro_attest_agent/unit` exists to prevent.
  UnitOptions(
    binaryPath: DefaultInstalledBinary,
    listen: cfg.listen,
    tier: $cfg.tier,
    measurementManifest: "",
    provisionedSecretsDir: cfg.provisionedSecretsDir)

proc isLoopbackListen(listen: string): bool =
  ## Whether the address binds only to this machine's loopback
  ## interface. Host part only — the port is irrelevant to reachability
  ## from another machine.
  let hostPart =
    if listen.startsWith("["):
      # A bracketed IPv6 literal: `[::1]:7331`.
      let close = listen.find(']')
      if close < 0: listen else: listen[1 ..< close]
    else:
      let colon = listen.rfind(':')
      if colon < 0: listen else: listen[0 ..< colon]
  hostPart == "localhost" or hostPart == "::1" or
    hostPart.startsWith("127.")

proc validateAttestationConfig*(cfg: AttestationActivityConfig) =
  ## The `validate:` rules this activity would carry if an activity body
  ## could carry them. Raises `EConfigViolation`.
  ##
  ## Three rules, in the order a reader meets the fields:
  ##
  ## 1. The configuration must be one the shipped service unit can be
  ##    rendered from. This is delegated to the renderer rather than
  ##    restated, so there is exactly one place that decides what a legal
  ##    listen address and a legal secrets directory are.
  ## 2. `exposeRemotely` and `listen` must agree. A profile that declares
  ##    the API reachable from outside while binding loopback has said
  ##    two contradictory things, and the contradiction is silent at run
  ##    time: the agent starts, answers locally, and every remote caller
  ##    sees a refused connection.
  ## 3. A tier that is not `mock` requires an attestable image layout.

  # 1. Renderability, decided by the renderer.
  try:
    discard renderServiceUnit(unitOptionsFor(cfg))
  except ValueError as err:
    raise newException(EConfigViolation,
      "the attestation activity was given a configuration the agent's " &
      "service unit cannot be rendered from: " & err.msg)

  # 2. The two halves of "reachable from outside".
  if cfg.exposeRemotely and isLoopbackListen(cfg.listen):
    raise newException(EConfigViolation,
      "the attestation activity is configured to expose the agent API " &
      "remotely, but its listen address " & cfg.listen.escape() &
      " binds loopback only, so nothing outside this machine can reach " &
      "it. Either bind an address reachable from the network, or leave " &
      "exposeRemotely off and front the loopback listener with an " &
      "authenticated channel of your own.")

  # 3. The tier and the image layout.
  if cfg.tier != atMock and cfg.imageLayout notin AttestableImageLayouts:
    raise newException(EConfigViolation,
      "the attestation activity is enabled at tier " & $cfg.tier &
      ", which answers a challenge with a launch measurement signed by a " &
      "root of trust, but the image layout is " &
      cfg.imageLayout.escape() & ", whose root filesystem is writable " &
      "for the life of the boot — so what was measured at boot and what " &
      "is running afterwards need not be the same bytes, and no verifier " &
      "can conclude anything from the quote. Build the image on " &
      AttestableImageLayouts.join(" or ") & ", or set the tier to " &
      $atMock & ", which has no root of trust and whose evidence a " &
      "production policy is required to refuse.")

# ---------------------------------------------------------------------------
# The activity itself.
# ---------------------------------------------------------------------------
#
# The list sections below are written as STRING LITERALS and not as the
# constants that hold the same values, and that is forced rather than
# chosen. `systemPackages:` and `systemServices:` are harvested by the
# `activity` macro's `collectStrLitList`, which accepts a string literal
# OR an identifier — and takes an identifier's *own name*. So
# `systemPackages: [AgentPackage]` does not install the
# `attestation-agent` package; it installs a package called
# "AgentPackage", silently, with no error at any stage.
#
# A literal therefore has to appear here, which is the second spelling of
# a name that already has one — exactly the drift
# `repro_attest_agent/unit` was written to prevent, since the unit name
# also appears in the unit the daemon renders for itself. The `static`
# block below is what stops the two from parting: it is evaluated at
# compile time, so a rename on either side is a build failure rather than
# a machine that enables a unit nobody installed.

static:
  doAssert AgentPackage == "attestation-agent",
    "the package name written into the activity body below no longer " &
    "matches AgentPackage"
  doAssert UnitName == "attestation-agent.service",
    "the unit name written into the activity body below no longer " &
    "matches the unit name the agent renders for itself"
  doAssert ActivityName == "attestation",
    "the activity name written into the activity body below no longer " &
    "matches ActivityName"

proc attestationActivity*(cfg: AttestationActivityConfig):
    SystemActivitySpec =
  ## The activity, validated. The only way to obtain the spec is through
  ## the validator, so a profile cannot enable a configuration the rules
  ## above refuse — there is no unchecked constructor beside this one.
  validateAttestationConfig(cfg)
  buildActivitySpec("attestation"):
    displayName: "Remote attestation"
    description: "Remote attestation of this machine's configuration."
    systemPackages: ["attestation-agent"]
    systemServices: ["attestation-agent.service"]
