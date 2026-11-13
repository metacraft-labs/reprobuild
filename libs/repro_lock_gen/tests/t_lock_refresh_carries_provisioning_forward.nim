## A lock refresh never silently drops a locked provisioning realization.
##
## ReproOS-Campaign-Completion M7 deliverable 2 added a ``provisioning``
## array to the committed ``repro.lock`` (``repro_lock/provisioning``). The
## two doors that write the committed lock -- ``repro lock refresh`` and
## ``repro lock solve --write`` -- rebuild the document from the SOLVE, and
## the solve knows nothing about provisioning. Before this test they
## therefore wrote a document without the array, and a pinned contributor
## silently became "no lock, choose again".
##
## The decision (verification of M7 D2): a refresh re-solves the package
## graph and carries every locked provisioning realization forward
## UNCHANGED. Carrying a record forward is safe because a record is only
## ever handed back against the CURRENT interface and contribution
## fingerprints (``lockedRealizationFor``), so a record the refresh made
## stale refuses on read rather than being used. Re-selecting a contributor
## is deliverables 3 and 5, not a side effect of re-solving versions. An
## incumbent whose ``provisioning`` array cannot be read is NOT replaced:
## the refresh refuses and leaves the committed lock byte-identical.
##
## Each assertion pairs with a control, because "the bytes survived" is also
## what a refresh that did nothing would produce:
##   * the solved graph DOES move (``highest`` -> ``lowest``), so the file
##     really was rewritten;
##   * a lock with no ``provisioning`` array is rewritten exactly as before.
##
## ## Test-double policy: NO mocks, doubles, or fakes
##
## See ``nlf_m6_fixture``'s header. The provisioning record is sealed by the
## real ``sealLockedRealization`` and written by the real lock writer.

import std/[os, strutils, tables, unittest]

import repro_lock
import repro_lock_gen
import repro_solver

import ./nlf_m6_fixture

const
  App = "app"
  LibFoo = "libfoo"
  Published = ["1.2.0", "1.4.0", "1.9.0"]
  Host = "amd64-linux"

proc workspace(): seq[PackageDecl] =
  @[
    newPackage(App, @["1.0.0"], @[newDependency(LibFoo, ">=1.2 <2.0")]),
    newPackage(LibFoo, @["1.2.0"])]

proc lockedRecord(): LockedRealization =
  let contribution = repeat('c', 64)
  sealLockedRealization(LockedRealization(
    packageName: LibFoo,
    interfaceFingerprint: repeat('a', 64),
    contributor: "github:example/libfoo-packages",
    contributionFingerprint: contribution,
    catalogWorkspace: "github:example/workspace",
    catalogRemote: "github:example/libfoo-packages",
    catalogRevision: repeat('b', 40),
    catalogInterfaceArtifact: repeat('d', 64),
    realizationKind: lrkTarball,
    realizationLockIdentity: "sha256:" & repeat('e', 64),
    realizationIntegrity: repeat('e', 64),
    hostPlatform: Host,
    targetPlatform: Host,
    capabilities: @[],
    selectedBy: lsrUniqueEligible),
    ContributionEvidence(fingerprintHex: contribution))

proc provisioningLine(document: string): string =
  for line in document.splitLines():
    if line.startsWith(ProvisioningLockKey & " = "):
      return line
  ""

proc pinProvisioning(committed: string) =
  ## Add one locked realization to the committed lock, through the writer.
  writeFile(committed, serializeLockedDependencies(
    parseLockedDependencies(readFile(committed)).withProvisioningRealizations(
      @[lockedRecord()])))

template carriesForwardThrough(door: string) =
  ## One door that writes the committed lock; inlined into each test so a
  ## failed check fails THAT test.
  block:
    let reg = startRegistry("prov-carry-" &
      door.replace(" ", "").replace("-", ""))
    try:
      reg.server.publish(App, ["1.0.0"])
      reg.server.publish(LibFoo, Published)
      let committed = reg.scratch / "project" / "repro.lock"
      discard runLockSolve(reg.request(workspace(), lsHighest), committed)
      pinProvisioning(committed)
      let pinned = provisioningLine(readFile(committed))
      check pinned.len > 0

      let rewritten =
        if door == "refresh":
          runLockRefresh(reg.request(workspace(), lsLowest), committed)
        else:
          runLockSolve(reg.request(workspace(), lsLowest), committed)
      let after = readFile(committed)
      # The file WAS rewritten from a new solve ...
      check lockToSolution(parseSolvedGraphLock(after)).packages[LibFoo] ==
        "1.2.0"
      check rewritten.lockDocument == after
      # ... and the locked realization came through byte for byte.
      check provisioningLine(after) == pinned
      let parsed = parseLockedDependencies(after)
      check parsed.provisioningRealizationCount == 1
      check parsed.lockedRealizationFor(LibFoo, Host, Host,
        repeat('a', 64), repeat('c', 64)).contributor ==
        "github:example/libfoo-packages"
      # Carrying the record does not move the lock identity.
      check rewritten.lockIdentity == lockIdentityOf(parsed)
      check lockIdentityOf(parsed) == lockIdentityOf(
        parseLockedDependencies(after.replace(pinned & "\n", "")))
    finally:
      reg.shutdown()

suite "a lock refresh carries locked provisioning realizations forward":

  test "`repro lock refresh` keeps the provisioning array unchanged":
    carriesForwardThrough("refresh")

  test "`repro lock solve --write` keeps the provisioning array unchanged":
    carriesForwardThrough("solve --write")

  test "a refresh refuses, and does not overwrite, an unreadable provisioning array":
    let reg = startRegistry("prov-carry-refuse")
    try:
      reg.server.publish(App, ["1.0.0"])
      reg.server.publish(LibFoo, Published)
      let committed = reg.scratch / "project" / "repro.lock"
      discard runLockSolve(reg.request(workspace(), lsHighest), committed)
      pinProvisioning(committed)
      let pinned = provisioningLine(readFile(committed))
      # The last four (found by the M7 D5 verifier): records under a key
      # spelling the strict reader skips -- quoted, escaped, another letter
      # case -- used to be dropped by the rewrite without a word, and the
      # next build then ran unpinned.
      let records = pinned[pinned.find('=') + 1 .. ^1].strip()
      for damaged in [pinned[0 ..< pinned.len - 3], "provisioning",
                      pinned.replace("\"tarball\"", "\"docker\""),
                      "\"provisioning\" = " & records,
                      "\"\\u0070rovisioning\" = " & records,
                      "Provisioning = " & records,
                      "[PROVISIONING]"]:
        let incumbent = readFile(committed).replace(pinned, damaged)
        writeFile(committed, incumbent)
        var refusal = ""
        try:
          discard runLockRefresh(reg.request(workspace(), lsLowest), committed)
        except CatchableError as err:
          refusal = err.msg
        check "provisioning" in refusal
        check "refusing" in refusal
        check readFile(committed) == incumbent
        writeFile(committed, incumbent.replace(damaged, pinned))
    finally:
      reg.shutdown()

  test "a lock without a provisioning array is rewritten exactly as before":
    let reg = startRegistry("prov-carry-control")
    try:
      reg.server.publish(App, ["1.0.0"])
      reg.server.publish(LibFoo, Published)
      let committed = reg.scratch / "project" / "repro.lock"
      discard runLockSolve(reg.request(workspace(), lsHighest), committed)
      let rewritten = runLockRefresh(reg.request(workspace(), lsLowest),
        committed)
      let after = readFile(committed)
      check ProvisioningLockKey notin after
      check after == rewritten.lockDocument
      check lockToSolution(parseSolvedGraphLock(after)).packages[LibFoo] ==
        "1.2.0"
    finally:
      reg.shutdown()
