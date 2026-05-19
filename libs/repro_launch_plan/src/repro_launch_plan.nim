## `repro_launch_plan` — typed Launch Plans and per-platform launcher
## machinery (M57, see specs/Launch-Plans-And-Platform-Launchers.md).
##
## Public surface:
##
##   * `LaunchPlan`, `EnvBinding`, `ExecutableBinding`, `SupportProfile`,
##     `LaunchPlanProvenance`, `LaunchPlanBindingKind` — the typed
##     domain record.
##   * `encodeLaunchPlan` / `decodeLaunchPlan` — the binary RBLP envelope
##     with trailing BLAKE3 checksum.
##   * `launchPlanIdBytes` / `launchPlanIdHex` — content-addressed key.
##   * `decideBinding` — pure binding-decision algorithm per platform.
##   * `generatePosixLauncherScript` — deterministic strategy-3 script
##     bytes used by Linux and macOS.
##   * `parseElf` / `rewriteRunpathInPlace` — minimal ELF64 RUNPATH
##     rewriter used by strategy 1 on Linux.
##   * `parseMacho` / `rewriteFirstRpath` — minimal Mach-O LC_RPATH
##     rewriter used by strategy 1 on macOS.
##   * `LaunchSidecar`, `encodeLaunchSidecar`, `decodeLaunchSidecar`,
##     `readSidecarFile`, `writeSidecarFile` — the RBLS sidecar shape
##     used by the Windows launcher binary.
##   * `storeLaunchPlan` / `loadLaunchPlan` — M56 CAS facade.

import ./repro_launch_plan/types
import ./repro_launch_plan/codec
import ./repro_launch_plan/binding
import ./repro_launch_plan/elf
import ./repro_launch_plan/macho
import ./repro_launch_plan/json_view
import ./repro_launch_plan/store_io
import ./repro_launch_plan/slim_cas
import ./repro_launch_plan/synthetic

export types
export codec
export binding
export elf
export macho
export json_view
export store_io
export slim_cas
export synthetic
