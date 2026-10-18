## Test-only subsystem control for platforms without a complete tree-lifetime
## guard. Validate the real capture's fail-closed verdict and exactly one
## platform marker before removing that marker from a separate in-memory view.
## Every other record, including any other loss, survives. Callers must keep
## using the original capture for product verdicts and raw evidence comparisons.
##
## The limitation itself is normative, not a defect to wait out: io-mon's
## `docs/usage.md` ("macOS and Windows limitation (normative)", introduced by
## io-mon 57ce305) requires every finished macOS and Windows capture to carry
## the marker below, to grade `mcIncomplete`, and offers no override. The
## engine therefore never publishes a monitored edge's record on those hosts
## and re-runs it on every build. Suites whose assertions depend on
## publication or reuse branch on `NoTreeLifetimeGuard` instead of each
## spelling its own `when defined(...)`, so the platform set lives here once,
## next to the marker it is derived from.
import std/strutils
import io_mon

const NoTreeLifetimeGuard* = defined(macosx) or defined(windows)
  ## True where io-mon cannot prove detached-descendant quiescence, so every
  ## monitored capture fails closed and no monitored edge is ever published.
  ## A plain `bool` constant rather than a `when` symbol, so a caller can
  ## branch with an ordinary `if` and BOTH arms still compile (and are
  ## `nim check`ed) on every host.

# The exact detail io-mon writes for the platform limitation, up to the
# `run=<id>` suffix. Empty where the limitation does not apply, which
# `isTreeLifetimeLimitation` turns into "never matches".
const TreeLifetimeLimitationPrefix* =
  when defined(macosx) or defined(windows):
    "detached-descendant quiescence cannot be established: " &
      (when defined(macosx): "macos" else: "windows") &
      " backend has no complete tree-lifetime guard run="
  else:
    ""

proc isTreeLifetimeLimitation*(detail: string): bool =
  ## Is `detail` exactly this platform's tree-lifetime marker: the prefix, a
  ## non-empty run id, and nothing after it? Anything looser would let an
  ## unrelated loss that merely mentions the phrase pass as the expected one.
  if TreeLifetimeLimitationPrefix.len == 0 or
      not detail.startsWith(TreeLifetimeLimitationPrefix):
    return false
  let runId = detail[TreeLifetimeLimitationPrefix.len .. ^1]
  runId.len > 0 and runId.find({' ', '\t', '\r', '\n'}) < 0

proc descendantSubsystemEvidence*(dep: MonitorDepFile): MonitorDepFile =
  when NoTreeLifetimeGuard:
    doAssert dep.completeness == mcIncomplete,
      "real capture must fail closed without a complete tree-lifetime guard"
    var records: seq[MonitorRecord]
    var limitations = 0
    for record in dep.records:
      if record.kind == mrEventLoss and record.observationKind == moEventLoss and
          record.detail.isTreeLifetimeLimitation:
        inc limitations
        continue
      records.add record
    doAssert limitations == 1,
      "capture must carry exactly one explicit platform tree-lifetime limitation"
    result = depFileFromRecords(records)
  else:
    result = dep
