## Nimble-Package-Catalog § 10, "Offline verification": `repro nimble verify`
## re-hashes the store entries a lock names and compares them with the lock,
## with the network disabled. Threat model G10.
##
## A lock of two packages is fetched into a store from a mirror. The verb is
## then run, through its own entry point (`runNimbleVerifyCommand`), in a
## child process in a fresh network namespace (`unshare -rn`), where the
## loopback interface is down: the child first shows it cannot connect to the
## fixture's listener (positive control for "no network"), then verifies. It
## exits 0; after one byte of one stored file is changed it exits 1 and names
## the package; the store entry's receipt still names the locked digest, so a
## verifier that trusted the receipt would pass.
##
## No mock: a real fetch over the shared HTTPS fixture, a real lock written
## by the lock writer, a real network namespace.

import std/[net, os, osproc, streams, strutils, tempfiles, unittest]

import repro_lock
import repro_cli_support/nimble_verify

import ./fetch_fixtures

proc childMain() =
  ## `--verify-child <lock> <store> <port>`: prove the network is down, then
  ## run the verb and exit with its code.
  let port = parseInt(paramStr(4))
  var reached = true
  try:
    let s = newSocket()
    s.connect("127.0.0.1", Port(port), 2000)
    s.close()
  except CatchableError:
    reached = false
  if reached:
    echo "network: up"
    quit(97)
  echo "network: down"
  quit(runNimbleVerifyCommand(paramStr(2), paramStr(3)))

if paramCount() >= 1 and paramStr(1) == "--verify-child":
  childMain()

proc verifyOffline(lock, store: string; port: int): tuple[code: int;
                                                          output: string] =
  let unshare = findExe("unshare")
  doAssert unshare.len > 0, "unshare(1) is needed to disable the network"
  let p = startProcess(unshare, args = ["-rn", getAppFilename(),
    "--verify-child", lock, store, $port],
    options = {poStdErrToStdOut})
  let output = p.outputStream.readAll()
  let code = p.waitForExit()
  p.close()
  (code, output)

suite "NPC-M5: repro nimble verify is offline and re-hashes":
  test "passes, and fails after one byte changes, with the network disabled":
    let mirrorDir = createTempDir("npc-m5-verify-mirror-", "")
    let f = newFixture("verify-offline",
      @[Route(prefix: "/mirror/", serveDir: mirrorDir)])
    let work = createTempDir("npc-m5-verify-", "")
    let a = f.package("owner/alpha.git", @[nimbleFile("alpha"),
      file("src/alpha.nim", "proc a*(): int = 1\n")])
    let b = f.package("owner/beta.git", @[nimbleFile("beta"),
      file("src/beta.nim", "proc b*(): int = 2\n")])
    let m = parseMirror(mirrorDir)
    m.putSource(a)
    m.putSource(b)
    let rows = @[f.rowOf("alpha", a), f.rowOf("beta", b)]
    let store = work / "store"
    let r = fetchLocked(rows, f.fetchConfig(work, @[f.httpsMirror("/mirror/")],
      store = store))
    check r.ok
    var ld = LockedDependencies(schema: SolvedGraphLockSchemaV3)
    for row in rows: ld.deps.add lockedDepOf(row)
    let lock = work / "repro.lock"
    writeFile(lock, serializeLockedDependencies(ld))
    check nimbleRowsOf(parseLockedDependencies(readFile(lock))).len == 2

    let pass = verifyOffline(lock, store, f.port)
    checkpoint pass.output
    check "network: down" in pass.output
    check pass.code == 0
    check "verified: 2 package(s)" in pass.output

    # One byte of one stored file changes; the receipt does not.
    let victim = store / b.tree / "src" / "beta.nim"
    var bytes = readFile(victim)
    bytes[0] = chr(ord(bytes[0]) xor 0x01)
    writeFile(victim, bytes)
    check b.tree in readFile(receiptPath(store, b.tree))
    let fail = verifyOffline(lock, store, f.port)
    checkpoint fail.output
    check "network: down" in fail.output
    check fail.code == 1
    check "mismatch nimble:beta" in fail.output
    check "ok nimble:alpha" in fail.output

    # A missing entry is named too.
    removeDir(store / a.tree)
    let gone = verifyOffline(lock, store, f.port)
    check gone.code == 1
    check "missing nimble:alpha" in gone.output
