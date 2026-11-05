## Test-only view of a capture for suites that grade one subsystem. It used to
## remove exactly one diagnostic, the platform-wide "macos backend has no
## complete tree-lifetime guard" limitation, so that subsystem suites could
## grade what they test on a platform where every capture carried it.
##
## No platform carries that limitation any more. Linux proves detached-
## descendant quiescence with its subreaper, Windows with its Job Object guard
## (reprobuild-pm spec/io-mon-Windows-Tree-Lifetime-Guard.md), and macOS, from
## io-mon 3d47bb1 (G42) on, with its kernel census and tree ledger (io-mon
## `docs/usage.md`, "The macOS tree-lifetime guard (normative)"). A healthy
## macOS capture is now complete and its edge is published, as on Linux, and a
## capture whose descendant does survive the root is still a loss. This module
## therefore removes NOTHING on any platform: a suite that grades through it
## asserts the real completeness. The retired marker is deliberately not
## recognised, so one that ever reappeared would fail the suites that expect a
## healthy fixture instead of being filtered out.
##
## `NoTreeLifetimeGuard` stays as the single switch the suites branch on, so a
## future platform without a guard is added here once.
import io_mon

const NoTreeLifetimeGuard* = false
  ## True where io-mon cannot prove detached-descendant quiescence, so every
  ## monitored capture fails closed and no monitored edge is ever published.
  ## No platform is in that set (see above). A plain `bool` constant rather
  ## than a `when` symbol, so a caller can branch with an ordinary `if` and
  ## BOTH arms still compile (and are `nim check`ed) on every host.

const TreeLifetimeLimitationPrefix* = ""
  ## The detail io-mon wrote for the platform limitation. Empty: no platform
  ## writes it, and `isTreeLifetimeLimitation` turns empty into "never
  ## matches".

proc isTreeLifetimeLimitation*(detail: string): bool =
  ## Never true: no platform carries the limitation (see the module header).
  ## A detail that merely mentions the phrase is an ordinary loss.
  TreeLifetimeLimitationPrefix.len > 0 and false

proc descendantSubsystemEvidence*(dep: MonitorDepFile): MonitorDepFile =
  ## The capture itself, unchanged on every platform.
  dep
