## ``repro version`` is a verb, not only the ``--version`` / ``-V`` flag.
##
## The command must answer from anywhere -- no project, no workspace, no
## running daemon -- and print exactly the line ``repro --version`` prints.
## ``repro version --json`` prints one JSON object naming the client version
## and the wire-protocol versions this image speaks, so a debugging session or
## a tool can tell which daemon and store-daemon protocols a client expects
## without starting either of them.
##
## No mocks: every case runs the graph-built ``repro`` binary from an empty
## temporary directory with the daemon turned off.

import std/[json, os, strutils, tempfiles, unittest]

import repro_core
import repro_test_support
import repro_daemon_core/protocol as userDaemonProtocol
import repro_store_daemon/protocol as storeDaemonProtocol
import repro_provider_runtime/types as providerTypes

proc runReproIn(dir: string; args: openArray[string]): CmdResult =
  ## Run the built CLI in ``dir`` with no daemon. stderr is merged into the
  ## captured output, so a stray warning makes the exact-text and JSON
  ## assertions below fail rather than slip past them.
  runShell(shellCommand(@[reproBinaryPath()] & @args,
    env = [("REPRO_DAEMON", "off")]), dir)

suite "repro version":
  setup:
    let emptyDir = createTempDir("repro-version-verb", "")
  teardown:
    removeDir(emptyDir)

  test "the verb prints the same line as --version, outside any project":
    check fileExists(reproBinaryPath())
    let flag = runReproIn(emptyDir, ["--version"])
    let verb = runReproIn(emptyDir, ["version"])
    checkpoint("--version: " & flag.output)
    checkpoint("version: " & verb.output)
    check flag.code == 0
    check verb.code == 0
    check verb.output == flag.output
    check verb.output.strip() == "repro " & versionString()

  test "--json prints one object with the client and protocol versions":
    let res = runReproIn(emptyDir, ["version", "--json"])
    checkpoint(res.output)
    check res.code == 0
    let doc = parseJson(res.output)
    check doc.kind == JObject
    check doc["schemaId"].getStr() == "reprobuild.version.v1"
    check doc["program"].getStr() == "repro"
    check doc["version"].getStr() == versionString()
    let protocols = doc["protocols"]
    check protocols["userDaemon"]["major"].getInt() ==
      int(userDaemonProtocol.UserDaemonProtocolMajor)
    check protocols["userDaemon"]["minor"].getInt() ==
      int(userDaemonProtocol.UserDaemonProtocolMinor)
    check protocols["storeDaemon"].getInt() ==
      int(storeDaemonProtocol.StoreDaemonProtocolVersion)
    check protocols["provider"].getInt() ==
      int(providerTypes.ProviderProtocolVersion)

  test "an unknown argument is a usage error":
    let res = runReproIn(emptyDir, ["version", "--no-such-flag"])
    checkpoint(res.output)
    check res.code == 2
    check res.output.contains("--no-such-flag")
