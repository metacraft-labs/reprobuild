## `repro daemon status` must print a field that DISCRIMINATES builds, next to
## the one that looks like it does and does not.
##
## reprobuild-pm issue 2026-10-13 ("`repro daemon status` reports
## `binary-version` as the daemon's identity, but two daemons differing by a
## required feature report the same string"). On one host, minutes apart and
## separated only by a `repro daemon restart`, the status report read
##
##   binary-version: 0.2.5
##   features: ...,substitute-routing,lease-registry
##   source-image-path: /nix/store/0a8j...-reprobuild-0.2.5/bin/...-wrapped
##
## and then
##
##   binary-version: 0.2.5
##   features: ...,substitute-routing,lease-registry,service-instance-registry
##   source-image-path: <a local checkout's build output>/reprobuild
##
## A shared-dev-services lane compared the CLI's `repro 0.2.5` against the
## daemon's `binary-version`, found them equal, concluded the daemon was
## current, and lost its diagnosis time to a refused attach that surfaced
## somewhere else entirely. The version string is stamped from the package
## version, so every build between two version bumps shares it; it is not a
## build identity and never was. The report already carried a real one --
## `running-hash:`, the blake3 digest of the running image -- twelve lines
## further down, where a reader looking at `binary-version` has no reason
## to go.
##
## THE FIX keeps `binary-version:` byte-for-byte (other tools read the report
## with a `field: value` parser, and the value is still the right answer to
## "which release line is this?"), and immediately after it prints
##
##   binary-identity: <running-hash, or path:<image> when no digest exists>
##   binary-version-note: the version string does not identify the build ...
##
## WITHOUT THE FIX the four cases that look up `binary-identity` or
## `binary-version-note` fail on that lookup: `renderUserDaemonStatus`
## printed neither line, so `fieldValue` answers its "<absent>" sentinel.
## The other two -- every pre-existing line still printed in order, and the
## not-running report unchanged -- pass either way; they guard against the
## fix dropping or reordering what was already there. The first case is
## the issue's own observation rebuilt from two status values -- same
## version, different image digest, different feature set -- and asserts
## the report now tells them apart on the line beside the version.
##
## No mocks: these are the real `UserDaemonStatus` values the daemon fills
## in and the real renderer `repro daemon status` echoes. Nothing about the
## rendering depends on a live daemon, so none is started.

import std/[strutils, unittest]

import repro_daemon_core/protocol
import repro_daemon_core/runtime

const Absent = "<absent>"

proc fieldValue(report, field: string): string =
  ## The same `field: value` reading the other consumers of this report do
  ## (the m10 control-plane suite's helper has this shape). Returns the
  ## `Absent` sentinel rather than "" so an empty value and a missing line
  ## can never be confused by an assertion.
  let prefix = field & ": "
  for line in report.splitLines():
    if line.startsWith(prefix):
      return line[prefix.len .. ^1]
  Absent

proc lineIndex(report, field: string): int =
  let prefix = field & ": "
  let lines = report.splitLines()
  for i, line in lines:
    if line.startsWith(prefix):
      return i
  -1

proc runningStatus(version, imagePath, runningHash,
                   featureFlags: string): UserDaemonStatus =
  ## A running daemon's status as `statusFor` assembles it: the handshake
  ## identity carries the version string, and the image path/digest pair is
  ## what `devRestartStateFor` records at daemon init.
  UserDaemonStatus(
    running: true,
    role: UserDaemonRole,
    endpoint: "/run/user/1000/repro-daemon-1000.sock",
    stateDir: "/home/u/.local/state/repro/daemon",
    logPath: "/home/u/.local/state/repro/daemon/logs/repro-daemon.log",
    pid: 4242,
    protocolMajor: UserDaemonProtocolMajor,
    protocolMinor: UserDaemonProtocolMinor,
    binary: BinaryIdentity(name: "repro", path: imagePath, version: version),
    featureFlags: featureFlags,
    generation: "g1",
    sourceImagePath: imagePath,
    runningImagePath: imagePath,
    sourceHash: runningHash,
    runningHash: runningHash)

const
  NixImage = "/nix/store/0a8j7cz0kccz6iplxrkz0vq250hbd8jk-reprobuild-0.2.5" &
    "/bin/.reprobuild-wrapped"
  LocalImage = "/home/u/reprobuild-sds/local-out/reprobuild"
  NixHash = "blake3-256:" & repeat("a1", 32)
  LocalHash = "blake3-256:" & repeat("b2", 32)

suite "daemon status names a build identity beside the version string":

  test "two builds sharing a version string are told apart beside it":
    # THE ISSUE'S OBSERVATION. Same `binary-version`, different image
    # digest, and the local build advertises one feature more.
    let nixReport = renderUserDaemonStatus(runningStatus("0.2.5", NixImage,
      NixHash, UserDaemonFeatureFlags))
    let localReport = renderUserDaemonStatus(runningStatus("0.2.5",
      LocalImage, LocalHash, UserDaemonFeatureFlags & ",extra-feature"))

    # The version line is unchanged and still identical -- which is
    # exactly the trap, and why it must stay parseable as it was.
    check fieldValue(nixReport, "binary-version") == "0.2.5"
    check fieldValue(nixReport, "binary-version") ==
      fieldValue(localReport, "binary-version")

    # The identity line is the running image's digest, verbatim -- the
    # same value `running-hash:` prints, algorithm prefix included -- and
    # it differs between the two builds.
    check fieldValue(nixReport, "binary-identity") == NixHash
    check fieldValue(localReport, "binary-identity") == LocalHash
    check fieldValue(nixReport, "binary-identity") !=
      fieldValue(localReport, "binary-identity")
    check fieldValue(nixReport, "binary-identity") ==
      fieldValue(nixReport, "running-hash")

  test "the identity and the warning sit immediately after the version":
    # Placement is the point: the reader who stops at `binary-version`
    # must not have to scroll to find out it does not discriminate.
    let report = renderUserDaemonStatus(runningStatus("0.2.5", NixImage,
      NixHash, UserDaemonFeatureFlags))
    let versionAt = lineIndex(report, "binary-version")
    check versionAt >= 0
    check lineIndex(report, "binary-identity") == versionAt + 1
    check lineIndex(report, "binary-version-note") == versionAt + 2
    let note = fieldValue(report, "binary-version-note")
    check note != Absent
    check note.contains("does not identify the build")
    check note.contains("binary-identity")
    check note.contains("features")
    # One line: a multi-line note would break every `field: value` reader.
    check not note.contains('\n')

  test "every pre-existing line is still printed, in order":
    # Additive only. The m1 / m10 control-plane suites and any external
    # reader key on these names, so dropping or reordering one is a
    # regression even if the new lines are right.
    let report = renderUserDaemonStatus(runningStatus("0.2.5", NixImage,
      NixHash, UserDaemonFeatureFlags))
    var previous = -1
    for field in ["role", "endpoint", "state-dir", "log", "protocol",
                  "binary-name", "binary-path", "binary-version", "features",
                  "generation", "pid", "uptime-seconds", "active-sessions",
                  "dev-mode", "source-image-path", "running-image-path",
                  "source-hash", "running-hash", "protocol-generation",
                  "restart-run-id", "staged-generation-dir",
                  "previous-staged-generation-dir",
                  "reconnect-limitations"]:
      let at = lineIndex(report, field)
      check at > previous
      previous = at
    check report.splitLines()[0] == "repro daemon: running"

  test "with no digest the identity falls back to the running image path":
    # `imageDigestHex` answers "" when the image cannot be read (deleted or
    # replaced under a running daemon). A path is a weaker identity than a
    # digest, but it is still the field that discriminated the issue's two
    # builds; labelling it `path:` keeps a reader from comparing it to a
    # digest as if they were the same kind of value.
    var status = runningStatus("0.2.5", LocalImage, "", UserDaemonFeatureFlags)
    check fieldValue(renderUserDaemonStatus(status), "binary-identity") ==
      "path:" & LocalImage
    # The source image stands in when the running image was not recorded.
    status.runningImagePath = ""
    status.sourceImagePath = NixImage
    check fieldValue(renderUserDaemonStatus(status), "binary-identity") ==
      "path:" & NixImage

  test "with neither digest nor path the identity says unknown":
    # Never an empty value: an empty `binary-identity:` compared against
    # another empty one would read as "same build".
    var status = runningStatus("0.2.5", "", "", UserDaemonFeatureFlags)
    status.sourceImagePath = ""
    status.runningImagePath = ""
    let report = renderUserDaemonStatus(status)
    check fieldValue(report, "binary-identity") == "unknown"
    check fieldValue(report, "binary-version-note") != Absent

  test "a stopped daemon's report is unchanged":
    # There is no running image to identify; the two-line not-running
    # report is parsed by `start` / `status` callers and stays as it was.
    let report = renderUserDaemonStatus(UserDaemonStatus(running: false,
      endpoint: "/run/user/1000/repro-daemon-1000.sock"))
    check report == "repro daemon: not-running\n" &
      "endpoint: /run/user/1000/repro-daemon-1000.sock"
