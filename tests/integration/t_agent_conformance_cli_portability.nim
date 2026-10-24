## The real enrolled conformance command: usage is 2 everywhere; an
## unavailable Unix transport refuses before provider launch, never PASS.
## On POSIX the SAME production command still executes the full original
## fixture-provider scenario and rejects an idle provider. No mocks: provider
## roles re-execute this test binary, and a real marker proves launch/no launch.
## The graph supplies build/bin/repro-agent-conformance; no runtime compiler.

import std/[os, strutils, tempfiles, unittest]
import repro_test_support
when defined(posix):
  import repro_agent_protocol/fixture_provider

let roleArgs = commandLineParams()
if roleArgs.len == 2 and roleArgs[0] in ["--cli-provider", "--cli-idle"]:
  writeFile(roleArgs[1], "provider started\n")
  when defined(posix):
    if roleArgs[0] == "--cli-provider":
      quit(runFixtureProvider())
  quit(0)

const RepoRoot = currentSourcePath().parentDir.parentDir.parentDir

proc cli(): string =
  requireBinary(RepoRoot / "build" / "bin" /
    addFileExt("repro-agent-conformance", ExeExt),
    "reprobuild.apps.repro-agent-conformance")

suite "agent conformance production CLI portability":
  test "usage errors remain exit 2 without starting a provider":
    for args in [newSeq[string](), @["--"]]:
      let r = runShellSplit(shellCommand(@[cli()] & args),
        cwd = RepoRoot, timeoutMs = 150_000)
      checkpoint r.stdout & r.stderr
      check r.code == 2
      check "usage: repro-agent-conformance" in r.stdout
      check "PASS agent-v1" notin r.stdout & r.stderr

  test "valid invocation runs the full scenario or refuses before launch":
    let scratch = createTempDir("rac-cli-positive-", "")
    defer: removeDir(scratch)
    let marker = scratch / "provider started.txt"
    let r = runShellSplit(shellCommand([cli(), "--", getAppFilename(),
      "--cli-provider", marker]), cwd = RepoRoot, timeoutMs = 150_000)
    checkpoint r.stdout & r.stderr
    when defined(posix):
      check r.code == 0
      check fileExists(marker)
      check "PASS agent-v1" in r.stdout
      check "provider exit: 0" in r.stdout
    else:
      check r.code == 1
      check "Unix peer-credential transport is not implemented" in r.stderr
      check "PASS agent-v1" notin r.stdout & r.stderr
      check not fileExists(marker)

  test "an idle provider never earns a passing CLI verdict":
    let scratch = createTempDir("rac-cli-idle-", "")
    defer: removeDir(scratch)
    let marker = scratch / "idle started.txt"
    let r = runShellSplit(shellCommand([cli(), "--", getAppFilename(),
      "--cli-idle", marker]), cwd = RepoRoot, timeoutMs = 150_000)
    checkpoint r.stdout & r.stderr
    check r.code == 1
    check "PASS agent-v1" notin r.stdout & r.stderr
    when defined(posix):
      check fileExists(marker)
      check "FAIL agent-v1" in r.stdout
      check "never attached" in r.stdout
    else:
      check "Unix peer-credential transport is not implemented" in r.stderr
      check not fileExists(marker)
