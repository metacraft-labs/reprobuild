## M6 Phase-5 Gate: e2e_macos_phase5_launchd_user_agent
##
## Per the macOS Mac-host validation checklist in
## `metacraft/reprobuild-specs/Nix-Flake-Migration-Roadmap.md` ("Drivers
## with shipped macOS arms - never E2E-validated"), the
## `launchd.userAgent` driver (home-scope, in
## `libs/repro_home_resources/src/repro_home_resources/drivers/launchd_user.nim`)
## has shipped a `when defined(macosx)` arm that has never run on real
## Apple hardware. This gate is the M6 scaffolding; M10
## (`macOS Driver Validation - launchd Services`) populates the
## concrete apply/verify/destroy scenario.
##
## M6 deliverable: the non-destructive half asserts the pure plist
## generator (`buildLaunchAgentPlist`), the `agentPlistPath`
## derivation, the `escapeXml` helper, the resource-typed digest
## (`digestOfResource(rkLaunchdUserAgent)`), and the resource
## validation (`resourceValidationError`).
##
## ===========================================================================
## DESTRUCTIVE GATE - REQUIRES A macOS SANDBOX / VM. DO NOT RUN ON A
## REAL HOST.
## ===========================================================================
##
## The destructive half writes
## `~/Library/LaunchAgents/<label>.plist` + invokes
## `launchctl bootstrap gui/<uid> <plist>`. Even though this is
## home-scope and does not need root, the apply mutates the user's
## live LaunchAgents tree and registers a real launchd service —
## therefore it is guarded by BOTH `defined(macosx)` AND
## `REPRO_PHASE5_MACOS_LAUNCHD_VM=1` (shared with the system-daemon
## gate; M10 lands both at the same time). Until the env var is set,
## the destructive half emits a `[sandbox-gated]` notice.

import std/[os, strutils, unittest]

import repro_home_resources

# The real-mutation scenario is gated by BOTH the platform (macOS) and
# the explicit opt-in env var. The env var is left UNSET on every CI /
# dev host so the gate never writes a real `~/Library/LaunchAgents/`
# plist or invokes `launchctl bootstrap`.
let sandboxMode =
  defined(macosx) and
  getEnv("REPRO_PHASE5_MACOS_LAUNCHD_VM") == "1"

# ===========================================================================
# NON-DESTRUCTIVE: plist generator + path derivation + validation +
# digest assertion. Always runs.
# ===========================================================================

suite "launchd.userAgent: plist generator + path derivation":

  test "buildLaunchAgentPlist emits Label + ProgramArguments + RunAtLoad":
    let plist = buildLaunchAgentPlist("com.metacraft.repro.m6",
      @["/bin/sleep", "3600"], true, false)
    check plist.contains("<key>Label</key>")
    check plist.contains("com.metacraft.repro.m6")
    check plist.contains("<key>ProgramArguments</key>")
    check plist.contains("/bin/sleep")
    check plist.contains("3600")
    check plist.contains("<key>RunAtLoad</key>")
    check plist.contains("<true/>")
    check plist.contains("<key>KeepAlive</key>")

  test "buildLaunchAgentPlist KeepAlive flag flips":
    let off = buildLaunchAgentPlist("com.x", @["/bin/true"], true, false)
    let on  = buildLaunchAgentPlist("com.x", @["/bin/true"], true, true)
    check off != on

  test "agentPlistPath lands under ~/Library/LaunchAgents/":
    let p = agentPlistPath("/Users/zahary", "com.metacraft.repro.m6")
    check p.contains("/Library/LaunchAgents/")
    check p.contains("com.metacraft.repro.m6")

  test "escapeXml escapes the five predefined entities":
    check escapeXml("<a&b>") == "&lt;a&amp;b&gt;"
    check escapeXml("\"hi\"") == "&quot;hi&quot;"
    check escapeXml("'q'") == "&apos;q&apos;"

suite "launchd.userAgent: typed-resource wiring + digest + validation":

  test "a launchd.userAgent Resource accepts the canonical fields":
    let r = Resource(kind: rkLaunchdUserAgent,
      address: "agent:com.metacraft.repro.m6",
      lifecyclePolicy: lpDefault,
      launchdLabel: "com.metacraft.repro.m6",
      launchdProgramArgs: @["/bin/sleep", "3600"],
      launchdRunAtLoad: true,
      launchdKeepAlive: false)
    check resourceValidationError(r) == ""
    check realWorldIdentity(r) == "launchd:user:com.metacraft.repro.m6"

  test "resourceValidationError rejects an injected launchd label":
    let bad = Resource(kind: rkLaunchdUserAgent,
      address: "agent:evil",
      lifecyclePolicy: lpDefault,
      launchdLabel: "com.x;touch /tmp/pwn",   # not in launchd charset
      launchdPlistContent: "<plist/>")
    check resourceValidationError(bad).len > 0
    # An empty label is also rejected.
    let empty = Resource(kind: rkLaunchdUserAgent,
      address: "agent:empty",
      lifecyclePolicy: lpDefault,
      launchdLabel: "",
      launchdPlistContent: "<plist/>")
    check resourceValidationError(empty).len > 0

  test "digestOfResource changes when ProgramArguments change":
    var r = Resource(kind: rkLaunchdUserAgent,
      address: "agent:digest",
      lifecyclePolicy: lpDefault,
      launchdLabel: "com.metacraft.repro.m6",
      launchdProgramArgs: @["/bin/true"],
      launchdRunAtLoad: true,
      launchdKeepAlive: false)
    let d0 = digestOfResource(r)
    r.launchdProgramArgs = @["/bin/true", "--new-flag"]
    let d1 = digestOfResource(r)
    check d0 != d1

  test "digestOfResource changes when keepAlive flips":
    var r = Resource(kind: rkLaunchdUserAgent,
      address: "agent:keep",
      lifecyclePolicy: lpDefault,
      launchdLabel: "com.metacraft.repro.m6",
      launchdProgramArgs: @["/bin/true"],
      launchdRunAtLoad: true,
      launchdKeepAlive: false)
    let d0 = digestOfResource(r)
    r.launchdKeepAlive = true
    let d1 = digestOfResource(r)
    check d0 != d1

  test "resourceKindFromString recognizes launchd.userAgent":
    check resourceKindFromString("launchd.userAgent") == rkLaunchdUserAgent

# ===========================================================================
# DESTRUCTIVE: real `~/Library/LaunchAgents/<label>.plist` write +
# `launchctl bootstrap gui/<uid>`. SANDBOX/VM-ONLY - guarded by BOTH
# the macOS platform AND `REPRO_PHASE5_MACOS_LAUNCHD_VM=1`. M10
# lands the concrete scenario; M6 only scaffolds.
# ===========================================================================

suite "launchd.userAgent: REAL bootstrap / verify / destroy (sandbox-only)":

  test "real launchd.userAgent lifecycle (only under macOS + env var)":
    if not sandboxMode:
      echo "  [sandbox-gated] REPRO_PHASE5_MACOS_LAUNCHD_VM not set " &
        "(or not on macOS) - the real `~/Library/LaunchAgents/...` " &
        "plist write + `launchctl bootstrap gui/<uid>` scenario is " &
        "NOT EXERCISED on this host. Run this gate inside a " &
        "disposable macOS VM with REPRO_PHASE5_MACOS_LAUNCHD_VM=1 " &
        "to exercise the real `launchctl` mutation. The pure-logic " &
        "suites above already proved the plist generator + typed-" &
        "field digest + validation without mutating any host."
    else:
      echo "  [sandbox-scaffold] REPRO_PHASE5_MACOS_LAUNCHD_VM set; " &
        "M6 scaffold present, M10 will populate the concrete " &
        "bootstrap/verify/destroy steps."
