## The add-on's command line, described once in the clispec ``cli:`` language.
##
## Two programs read it:
##
## * the statically linked add-on ``repro`` (``apps/repro-addon``), whose
##   whole command line is ``addonProgramDescription`` (``repro system
##   addon …``, ``repro system state …`` (the ``state`` verbs, which its
##   own first-boot restore unit runs), ``repro system adopt|rollback``,
##   ``repro infra plan|apply``,
##   ``repro store gc|recover|roots|list``), and which, invoked as
##   ``repro-addon-fingerprint``, is the fingerprint tool
##   (``fingerprintToolDescription``);
## * the full engine, whose description (``repro_cli_support/cli_description``)
##   splices the same bodies under ``repro system addon``, ``repro system
##   state``, ``repro system secret`` and ``repro system adopt``.
##
## Both parse the words through the parser generated from these
## declarations (``repro_addon/cli``), so ``--help``, completion and the
## usage errors of the add-on's verbs are clispec's in either program.
##
## It lives in ``repro_infra``, not beside the add-on's code in
## ``repro_addon`` (which is Linux-only), because the full engine's
## description holds it on every platform: a host that is not Linux parses
## the add-on's command lines too, and its handlers refuse the platform.
##
## Each proc returns a ``cli:`` body built with ``quote do:``; the program
## that splices it runs ``repro_core/cli_ast.unbound`` over its whole
## description. A body is spliced once per command that holds it: call the
## proc again for a second splice. The procs import only ``std/macros`` and
## run at compile time only, so a program that merely reads a description
## (the thin client) links nothing for them. Only literals appear in values
## and defaults: a description is evaluated in the scope of the program that
## holds it, which does not see this module's constants (a verb whose
## default is one of them, such as ``agent-tick --allowed-signers``, applies
## it in its handler).

import std/macros

proc addonTrustFlags(): NimNode {.compileTime.} =
  ## Whom a host trusts: the deploy signers and the binary-cache publishers.
  quote do:
    flag deploySigners is string,
      help = "The deploy signers' allowed-signers file"
    flag cachePublishers is string,
      help = "The binary-cache publishers' keys file"
    flag cacheUrl is string,
      help = "The binary cache (with --cache-publishers)"

proc addonAgentFlags(): NimNode {.compileTime.} =
  ## The deploy agent a bootstrap installs.
  quote do:
    flag target is string, help = "The deploy agent's target"
    flag manifest is seq[string],
      help = "A manifest the deploy agent polls; repeat it for several"
    flag profileCompiler is string,
      help = "The profile compiler the deploy agent's fetch unit runs"
    flag pollInterval is Option[int],
      help = "The deploy agent's poll interval, in seconds"

proc addonEvidenceSinkFlags(): NimNode {.compileTime.} =
  ## The Evidence sink a host ships its evidence records to.
  quote do:
    flag evidenceSink is string,
      help = "The Evidence sink, as ADDR:PORT"
    flag evidenceSinkCa is string,
      help = "The certificate authority the Evidence sink's certificate " &
        "chains to"
    flag heartbeatInterval is Option[int],
      help = "The evidence heartbeat interval, in seconds"

proc addonPreflightFlags(): NimNode {.compileTime.} =
  ## The inputs of the preflight plan, which a bootstrap must be given
  ## exactly again (its digest is the plan's).
  let trust = addonTrustFlags()
  let agent = addonAgentFlags()
  let sink = addonEvidenceSinkFlags()
  quote do:
    `trust`
    `agent`
    `sink`
    boolFlag deferRecipientKey is bool,
      help = "Create no recipient key: the host's next boot creates its own"

proc addonRetentionFlags(): NimNode {.compileTime.} =
  ## How many generations' store roots an apply or `retention` keeps.
  quote do:
    flag keepGenerations is Option[int],
      help = "Keep the store roots of this many generations (default 5)"
    flag keepDays is Option[int],
      help = "Keep the store roots of generations this many days old " &
        "(default 30)"

proc addonGenerationFlags*(): NimNode {.compileTime.} =
  ## The command line of an add-on generation: `repro infra plan|apply` and
  ## `repro system adopt` on an add-on host.
  let retention = addonRetentionFlags()
  quote do:
    flag profile is string, help = "The system profile (required)"
    boolFlag reconcileDrift is bool, alias = "--accept-drift",
      help = "Replace drifted objects instead of refusing"
    `retention`
    flag plan is string,
      help = "The add-on plan-id `repro infra plan` printed; apply only " &
        "that plan"
    boolFlag noPreview is bool,
      help = "Accepted for the full engine's sake; an add-on apply always " &
        "converges without a preview"

proc addonAdoptParams*(): NimNode {.compileTime.} =
  ## `repro system adopt <address> --profile <file>`.
  let generation = addonGenerationFlags()
  quote do:
    `generation`
    pos address is string,
      help = "The resource whose object is claimed as it is"

proc addonStateCommands*(): NimNode {.compileTime.} =
  ## The body of `repro system addon state` (and `repro system state`): the
  ## profile's declared state set (stateDirectories).
  quote do:
    subcmd "backup", help = "Hold every unit of the profile's state set, " &
        "archive each carried directory and write the manifest":
      flag profile is string, required = true, help = "The system profile"
      flag outDir is string, required = true, perSource = [cli = "out"],
        help = "The directory the manifest and archives are written to"
      flag root is string,
        help = "The root of the system to back up (default /)"
    subcmd "release", help = "Lift the hold of a backup (an abandoned " &
        "conversion)":
      flag profile is string, required = true, help = "The system profile"
    subcmd "verify", help = "Recompute every directory's digest against " &
        "the manifest; exit 1 on a difference":
      flag fromDir is string, required = true, perSource = [cli = "from"],
        help = "The directory holding the manifest"
      flag root is string,
        help = "The root of the system to verify (default /)"
      flag only is string, values = ["keep", "carry"],
        help = "Verify only the directories kept or only those carried"
      boolFlag source is bool,
        help = "On the source host: also exit 1 when a unit of the set " &
          "is no longer held"
    subcmd "restore", help = "Restore the carried directories":
      flag fromDir is string, perSource = [cli = "from"],
        help = "The carried directory (default: " &
          "/var/lib/repro/system/carried under --root)"
      flag root is string,
        help = "The root of the system to restore (default /)"
      boolFlag boot is bool,
        help = "The first-boot unit: nothing to do when no carried state " &
          "was installed"
    subcmd "digest", help = "Print a directory's state digest":
      pos path is string, help = "The directory"
    subcmd "unit":
      help "Print the first-boot restore unit for this binary"
    subcmd "install-unit", help = "Install and enable the first-boot " &
        "restore unit, and make every carried unit require it":
      flag fromDir is string, perSource = [cli = "from"],
        help = "Only /var/lib/repro/system/carried is accepted"
      flag root is string,
        help = "The root of the system to install it into (default /)"
    subcmd "help", visibility = hidden:
      pos topic is seq[string], required = false

proc addonSecretCommands*(): NimNode {.compileTime.} =
  ## The body of `repro system addon secret`.
  quote do:
    subcmd "put", help = "Seal the secret read from stdin as the entry " &
        "SERVICE/NAME and materialise the current generation's secrets":
      flag service is string, required = true, help = "The service"
      flag name is string, required = true, help = "The secret's name"
      flag target is string, help = "The deploy target (default: this host)"

proc addonCommands*(withTestSleep = false): NimNode {.compileTime.} =
  ## The body of `repro system addon`. ``withTestSleep`` adds the hidden
  ## `test-sleep <seconds>` a crash-consistency gate runs, which only the
  ## static binary declares (and only its seam build runs).
  let preflightInputs = addonPreflightFlags()
  let bootstrapInputs = addonPreflightFlags()
  let enrolSink = addonEvidenceSinkFlags()
  let retention = addonRetentionFlags()
  let state = addonStateCommands()
  let secret = addonSecretCommands()
  let seamCommands = if withTestSleep:
      quote do:
        subcmd "test-sleep", visibility = hidden:
          pos seconds is int
    else:
      newStmtList()
  quote do:
    subcmd "preflight", help = "Inventory the host read-only and print the " &
        "plan and its digest":
      `preflightInputs`
      boolFlag json is bool, help = "Print the plan as JSON"
    subcmd "bootstrap", help = "Install the add-on on a host whose " &
        "preflight plan has the digest given":
      flag plan is string, help = "The preflight plan's digest (required)"
      `bootstrapInputs`
    subcmd "evidence-ship", help = "Append every queued evidence record to " &
        "the Evidence sink, then a heartbeat (the shipping unit)":
      boolFlag heartbeat is bool, help = "Send a heartbeat now"
      boolFlag noBackoff is bool, visibility = internal,
        help = "Return without the shipping unit's wait"
    subcmd "evidence-enrol", help = "Give a host the attestation key and " &
        "the sink write credential, or replace them (--rekey)":
      `enrolSink`
      boolFlag rekey is bool,
        help = "Replace an enrolled host's attestation key and sink " &
          "credential"
      boolFlag noHandover is bool,
        help = "With --rekey: no hand-over signed by the old key"
    subcmd "store-verify", help = "Hash every store path the current " &
        "generation uses; quarantine an altered one":
      boolFlag background is bool,
        help = "The background unit: always exit 0"
      boolFlag adoptUnverified is bool,
        help = "Record the current digest of paths realised before " &
          "receipts carried one"
    subcmd "egress-check":
      help "Record every destination the deploy " &
          "agent's fetch unit was refused, and heartbeat"
    subcmd "evidence-harvest":
      help "Turn the apt hook wrapper's events " &
          "into evidence records (the shipping unit's first step)"
    subcmd "evidence-credential-check":
      help "Test this host's sink " &
          "write credential: only an append may succeed"
    subcmd "uninstall", help = "Reverse everything the ownership ledger " &
        "records":
      boolFlag keepStore is bool, help = "Keep the store and its objects"
      boolFlag discardStoreEvidence is bool,
        help = "Discard the store's evidence"
      boolFlag discardUnacknowledgedStoreEvidence is bool,
        help = "Discard store evidence the Evidence sink has not " &
          "acknowledged (writes a signed intent record first)"
    subcmd "verify-discard-record", help = "Check a signed discard record " &
        "(an uninstall's intent record, or its completion)":
      flag key is string,
        help = "The host's enrolled attestation key, as hex (required)"
      pos record is string, help = "The record"
    subcmd "verify", help = "Compare every ledger object with the host " &
        "(report only)":
      boolFlag boot is bool, help = "The boot unit: always exit 0"
      boolFlag afterDpkg is bool,
        help = "The apt hook: also report packages that now own ledger " &
          "paths; always exit 0"
    subcmd "boot-confirm":
      help "Replay a pending switch the " &
          "re-assertion left to the boot-confirm unit; always exit 0"
    subcmd "reassert", help = "Finish or revert an interrupted switch and " &
        "check the current generation":
      boolFlag boot is bool, help = "The re-assert unit: always exit 0"
    subcmd "recover":
      help "The same, for an operator: exit 1 unless the " &
          "host ends ok or drift"
    subcmd "secrets", help = "Re-materialise the current generation's " &
        "secrets from the retained envelope":
      boolFlag boot is bool, help = "The boot secrets unit: always exit 0"
    subcmd "probe", help = "Run one tcp: or http:// health check here":
      pos healthCheck is string, help = "The health check"
    subcmd "secret", help = "Seal a secret to this host":
      `secret`
    subcmd "rotate-recipient-key":
      help "Generate the next recipient key " &
          "and print its public half"
    subcmd "image-assemble", help = "The assembly boot of `repro infra " &
        "image` (its one-shot unit, never an operator)":
      flag payload is string, required = true,
        help = "The assembly payload directory"
    subcmd "agent-repin", help = "Resolve the deploy agent's origins again " &
        "and print the re-pin plan, or apply it":
      flag apply is string, help = "Apply the plan with this digest"
    subcmd "agent-tick", help = "One deploy-agent tick in one process":
      flag source is seq[string],
        help = "A manifest source; repeat it for several (at least one)"
      flag target is string, help = "The deploy target (default: this host)"
      flag allowedSigners is string,
        help = "The deploy signers' allowed-signers file (default: the " &
          "add-on's)"
    subcmd "agent-fetch":
      help "The fetch unit: select, compile, " &
          "substitute and download into its staging area"
    subcmd "agent-apply":
      help "The apply unit: copy the staging area, " &
          "verify everything again, apply"
    subcmd "migration-plan", help = "Plan, writing nothing, the migration " &
        "of an agent that applied outside the switch":
      flag stateDir is string,
        help = "The add-on state directory (default: the host's)"
      flag agentState is string,
        help = "The agent's state directory (default: the host's)"
      flag target is string, help = "The deploy target (default: this host)"
      flag legacySecretsDir is string,
        help = "The agent's secrets directory"
    subcmd "resume":
      help "Let the deploy agent converge again after a " &
          "local rollback paused it"
    subcmd "migrate":
      help "Re-render generation 0's objects this build " &
          "renders differently, by one switch"
    subcmd "contain", help = "Contain the host: ship a signed record and " &
        "stop the deploy agent's units":
      flag operator is string, required = true, help = "Who contains it"
      flag reason is string, required = true, help = "Why"
    subcmd "release", help = "Release a contained host":
      flag operator is string, required = true, help = "Who releases it"
      flag reason is string, required = true, help = "Why"
    subcmd "fingerprint", help = "Record the base fingerprint, or compare " &
        "two":
      call:
        flag root is string, default = "/",
          help = "The root to fingerprint"
        boolFlag noLive is bool, help = "Skip the live (running) state"
        flag outPath is string, perSource = [cli = "out"],
          help = "Write it here instead of stdout"
      subcmd "diff", help = "Compare two fingerprints; exit 1 on a " &
          "difference":
        flag exceptRule is seq[string], perSource = [cli = "except"],
          help = "Ignore a difference, as COMPONENT:KEY-GLOB; repeat it " &
            "for several"
        flag expect is string,
          help = "Compare the diff with this expectation file instead"
        pos before is string, help = "The earlier fingerprint"
        pos after is string, help = "The later fingerprint"
    subcmd "expected-delta", help = "The fingerprint diff an apply between " &
        "two ledgers may cause":
      pos before is string, help = "The earlier ledger, or - for none"
      pos after is string, help = "The later ledger"
    subcmd "ledger":
      help "Print the current ownership ledger"
    subcmd "import", help = "Print a profile skeleton that reproduces a " &
        "hand-configured unit; writes nothing":
      flag unit is string, required = true, help = "The unit"
    subcmd "state", help = "Back up and restore the profile's declared " &
        "state set":
      `state`
    subcmd "status":
      help "The current generation, the store roots, the " &
          "static tree and any pending switch"
    subcmd "retention", help = "Release the store roots of generations " &
        "outside the retention policy now":
      `retention`
    subcmd "selfcheck-btrfs", help = "Create and delete a btrfs subvolume " &
        "the way the store root is created (a test)":
      pos mountPoint is string, help = "A btrfs mount point"
    subcmd "selfcheck-write", help = "Write a managed file through the " &
        "system-file driver as the switch does (a test)":
      pos path is string, help = "The path"
    subcmd "help", visibility = hidden:
      pos topic is seq[string], required = false
    `seamCommands`

proc fingerprintToolDescription*(): NimNode {.compileTime.} =
  ## The whole command line of `repro-addon-fingerprint`, the name under
  ## which the static add-on binary is the base fingerprint tool: the body
  ## of `repro system addon fingerprint`, as a program of its own.
  quote do:
    help "Record a host's base fingerprint, or compare two"
    convention cli = kebabCase
    call:
      flag root is string, default = "/",
        help = "The root to fingerprint"
      boolFlag noLive is bool, help = "Skip the live (running) state"
      flag outPath is string, perSource = [cli = "out"],
          help = "Write it here instead of stdout"
    subcmd "diff", help = "Compare two fingerprints; exit 1 on a " &
        "difference":
      flag exceptRule is seq[string], perSource = [cli = "except"],
        help = "Ignore a difference, as COMPONENT:KEY-GLOB; repeat it for " &
          "several"
      flag expect is string,
        help = "Compare the diff with this expectation file instead"
      pos before is string, help = "The earlier fingerprint"
      pos after is string, help = "The later fingerprint"

proc addonProgramDescription*(): NimNode {.compileTime.} =
  ## The whole command line of the static add-on `repro`.
  let addon = addonCommands(withTestSleep = true)
  let state = addonStateCommands()
  let adopt = addonAdoptParams()
  let plan = addonGenerationFlags()
  let apply = addonGenerationFlags()
  quote do:
    help "The add-on host's repro: the add-on verbs and the system-scope " &
      "apply path they run on"
    convention cli = kebabCase
    call:
      boolFlag version is bool, help = "Print the version and exit"
    subcmd "system", help = "The add-on and its generations":
      subcmd "addon", help = "Manage an add-on host":
        `addon`
      # The first-boot restore unit `state unit` and `state install-unit`
      # write runs `<this binary> system state restore --boot`, as the full
      # engine's does, so this binary answers `system state` too.
      subcmd "state", help = "Save and restore the declared state set":
        `state`
      subcmd "adopt", help = "Claim the object a declared resource targets " &
          "as it is, writing nothing to it":
        `adopt`
      subcmd "rollback", help = "Re-apply a retained generation through the " &
          "switch (default: the previous one)":
        boolFlag reconcileDrift is bool,
          help = "Replace drifted objects instead of refusing"
        pos generation is string, required = false,
          help = "The generation to roll back to"
    subcmd "infra", help = "Plan and apply an add-on generation":
      subcmd "plan", help = "The ledger diff, collision report and service " &
          "transitions of applying a profile; writes nothing":
        `plan`
      subcmd "apply", help = "Apply an add-on generation through the switch":
        `apply`
    subcmd "store", help = "The system-scope store":
      subcmd "gc", help = "Collect store prefixes no root holds":
        flag graceSeconds is Option[int],
          help = "Keep prefixes younger than this many seconds"
      subcmd "recover":
        help "Sweep the staging area and reconcile every " &
            "prefix with the index"
      subcmd "roots":
        help "List the store roots"
      subcmd "list":
        help "List the store prefixes"
    subcmd "version":
      help "Print the version"
