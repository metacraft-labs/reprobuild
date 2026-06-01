## Tier-2 reprobuild-specific argv-tracing shim inventory for the
## macOS Phase-5 driver-validation gates (M7-M11).
##
## This module knows WHICH macOS binaries the Phase-5 drivers shell
## out to. The actual shim INSTALLATION primitive lives in the
## standalone vm-harness Nim library (`metacraft-labs/vm-harness`,
## per the M0 milestone in
## `reprobuild-specs/Multi-OS-VM-Automation-Campaign.milestones.org`)
## as a generic argv-tracer that can wrap any named binary. This
## file is the *binary list* the gates pass to that Tier-1
## primitive.
##
## See `README.md` in this directory for the full per-binary and
## per-gate mapping, including the env-var naming convention the
## sandbox-gated destructive halves consult.

import std/[strutils, tables]

type
  Phase5ShimSpec* = object
    ## A single argv-tracing shim specification. `binary` is the
    ## simple basename the driver shells out to (`dscl`, `launchctl`,
    ## `defaults`, `systemsetup`, `scutil`, `brew`). `description`
    ## is the human-readable purpose used in trace logs.
    ## `consumingGates` lists the M6 gate file basenames that
    ## reference traces for this binary (so a grep from the gate
    ## back to this inventory and from this inventory forward to
    ## the M7-M11 work stays trivial).
    binary*: string
    description*: string
    consumingGates*: seq[string]
    consumingMilestones*: seq[string]

const Phase5Shims*: seq[Phase5ShimSpec] = @[
  Phase5ShimSpec(
    binary: "defaults",
    description: "`defaults read|write|delete` against " &
                 "/Library/Preferences/*.plist for the macos." &
                 "systemDefault driver",
    consumingGates: @["t_e2e_macos_phase5_macos_system_default.nim"],
    consumingMilestones: @["M9"]),
  Phase5ShimSpec(
    binary: "launchctl",
    description: "`launchctl bootstrap|bootout|print` for the " &
                 "launchd.systemDaemon + launchd.userAgent drivers",
    consumingGates: @["t_e2e_macos_phase5_launchd_system_daemon.nim",
                      "t_e2e_macos_phase5_launchd_user_agent.nim"],
    consumingMilestones: @["M10"]),
  Phase5ShimSpec(
    binary: "systemsetup",
    description: "`systemsetup -settimezone|-gettimezone` for the " &
                 "osTimezone POSIX (macOS) arm",
    consumingGates: @["t_e2e_macos_phase5_os_timezone.nim"],
    consumingMilestones: @["M9"]),
  Phase5ShimSpec(
    binary: "scutil",
    description: "`scutil --set ComputerName/HostName/LocalHostName " &
                 "+ scutil --get` for the osHostname POSIX (macOS) arm",
    consumingGates: @["t_e2e_macos_phase5_os_hostname.nim"],
    consumingMilestones: @["M9"]),
  Phase5ShimSpec(
    binary: "dscl",
    description: "`dscl . -create|-read|-delete /Users/<name>` AND " &
                 "/Groups/<name>` for the passwd.user (macOS arm " &
                 "already shipped, reused via REPRO_M69_PASSWD_VM) " &
                 "+ passwd.group (M11 adds the macOS dscl arm)",
    consumingGates: @[
      "t_e2e_macos_phase5_passwd_group.nim",
      # M69 gate reused for the macOS passwd.user arm.
      "../m69/t_e2e_repro_infra_passwd_user_safe_destroy.nim"],
    consumingMilestones: @["M11"]),
  Phase5ShimSpec(
    binary: "brew",
    description: "`brew install [--cask] <name>`, `brew list " &
                 "--formula|--cask --versions <name>`, `brew " &
                 "uninstall [--cask] <name>` for the homebrew " &
                 "formula + cask drivers (M13, separate from " &
                 "M7-M11 Phase-5 gates)",
    consumingGates: @[],     # M13 ships its own gates
    consumingMilestones: @["M13"]),
]

proc phase5ShimBinaries*(): seq[string] =
  ## The flat list of macOS-specific binary basenames the M7-M11
  ## destructive-half blocks pass to the vm-harness Tier-1
  ## argv-tracing-shim-installer primitive at the start of a
  ## sandbox-gated run.
  result = @[]
  for spec in Phase5Shims:
    result.add(spec.binary)

proc phase5ShimsForGate*(gateBasename: string): seq[Phase5ShimSpec] =
  ## Return only the shims a specific gate consumes. Lets the
  ## destructive-half block install JUST the shims it needs (rather
  ## than the full set every time), which keeps trace output focused
  ## on the gate's surface.
  result = @[]
  for spec in Phase5Shims:
    if gateBasename in spec.consumingGates:
      result.add(spec)

proc phase5ShimsByMilestone*(): Table[string, seq[string]] =
  ## A milestone -> shim-binary-list view useful when authoring the
  ## M7 / M8 / M9 / M10 / M11 destructive halves: a single lookup
  ## answers "which argv-tracing shims do I need to install for
  ## THIS milestone's gates?".
  result = initTable[string, seq[string]]()
  for spec in Phase5Shims:
    for milestone in spec.consumingMilestones:
      if milestone notin result:
        result[milestone] = @[]
      result[milestone].add(spec.binary)

when isMainModule:
  ## Pretty-print the inventory. Useful when bumping the list or
  ## auditing which gates trace which binaries.
  echo "macOS Phase-5 argv-tracing shim inventory:"
  for spec in Phase5Shims:
    echo "  ", spec.binary, " - ", spec.description
    if spec.consumingGates.len > 0:
      echo "    consuming gates: ", spec.consumingGates.join(", ")
    if spec.consumingMilestones.len > 0:
      echo "    consuming milestones: ",
        spec.consumingMilestones.join(", ")
  echo ""
  echo "Flat binary list: ", phase5ShimBinaries().join(", ")
  echo ""
  echo "By milestone:"
  for milestone, binaries in phase5ShimsByMilestone():
    echo "  ", milestone, ": ", binaries.join(", ")
