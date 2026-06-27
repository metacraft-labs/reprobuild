## Workspace-Manifest-Optional MO-11 — non-VCS coordinates + integrity are
## PRODUCED from real solved-graph state, and the gate verifies them.
##
## A solved graph that contains BOTH a repro-store-realized artifact
## (``source: store``) AND a package-registry dependency
## (``source: registry <name>``) must produce, in the committed lock:
##
##   * a ``ckStore`` dependency carrying a ``store_hash`` coordinate AND a
##     self-describing ``blake3:<hex>`` integrity. For a content-addressed
##     store the address IS the content hash, so the ``store_hash`` coordinate
##     and the integrity digest are the SAME value — both are a genuine BLAKE3
##     recompute over the package's solved identity (name + version + platform),
##     not a fabricated constant.
##   * a ``ckRegistry`` dependency carrying ``reg_name`` / ``reg_version``
##     coordinates AND a self-describing ``blake3:<hex>`` integrity (the package
##     checksum recomputed over the registry coordinate).
##
## Then ``verifyLockedIntegrityAtCoordinates`` PASSES on the honest lock and
## FAILS (``locked-integrity-mismatch``-equivalent) when the store/registry
## integrity (or the store coordinate) is tampered — the same gate path the VCS
## case uses.
##
## Falsifiability: if non-VCS coordinate production were absent, the lock would
## carry no ``coord_kind = "store"`` / ``coord_kind = "registry"`` dep and the
## coordinate/integrity asserts FAIL; if the integrity were a constant
## unrelated to the package, the recompute-on-verify would NOT change under a
## tamper and the tamper asserts FAIL.
##
## Hermetic: a fresh git repo in a tempdir. Skip rule: ``git`` missing or repro
## unbuilt.

import std/[os, osproc, strutils, unittest]

import repro_cli_support
import repro_lock

const reproBinary = "./build/bin/repro"

# Two packages with DECLARED source provenance: ``app`` realizes into the repro
# store; ``leftpad`` is fetched from a package registry.
const solverInputs = """
package app
versions: 0.1.0
source: store

package leftpad
versions: 1.2.0
source: registry npmjs
"""

proc q(value: string): string = quoteShell(value)

proc run(command: string): tuple[code: int; output: string] =
  let res = execCmdEx(command)
  (code: res.exitCode, output: res.output)

proc git(gitBin, repo, rest: string): tuple[code: int; output: string] =
  run(q(gitBin) & " -C " & q(repo) & " " & rest)

proc flipOneHex(s: string): string =
  ## Flip the last hex digit of a multihash digest so the value stays
  ## well-formed but no longer matches the content.
  result = s
  let last = result[^1]
  result[^1] = (if last == '0': '1' else: '0')

suite "MO-11: store + registry deps carry coordinates + integrity":

  test "t_store_and_registry_deps_carry_coordinates_and_integrity":
    let gitBin = findExe("git")
    if gitBin.len == 0 or not fileExists(reproBinary):
      skip()
    else:
      let scratch = getTempDir() / "mo11-coords-" & $getCurrentProcessId()
      removeDir(scratch)
      createDir(scratch)
      defer: removeDir(scratch)

      let origin = scratch / "origin.git"
      let repo = scratch / "work"
      check git(gitBin, "", "init --bare -b main " & q(origin)).code == 0
      check run(q(gitBin) & " clone " & q(origin) & " " & q(repo)).code == 0
      check git(gitBin, repo, "config user.email t@example.invalid").code == 0
      check git(gitBin, repo, "config user.name Tester").code == 0
      writeFile(repo / "README.md", "mo11 fixture\n")
      writeFile(repo / "repro.solver", solverInputs)
      check git(gitBin, repo, "add README.md repro.solver").code == 0
      check git(gitBin, repo, "commit -m seed").code == 0
      check git(gitBin, repo, "push origin main").code == 0

      # ---- refresh produces the lock; assert store + registry coordinates ----
      let refresh = run(reproBinary & " lock refresh " & q(repo))
      check refresh.code == 0
      let lockBody = readFile(repo / "repro.lock")
      check "reprobuild.solved-graph-lock.v2" in lockBody

      # A ckStore dep for ``app`` with a store_hash coordinate + blake3 integrity.
      check "coord_kind = \"store\"" in lockBody
      check "store_hash = \"" in lockBody
      # A ckRegistry dep for ``leftpad`` with reg_name / reg_version coordinates.
      check "coord_kind = \"registry\"" in lockBody
      check "reg_name = \"npmjs\"" in lockBody
      check "reg_version = \"1.2.0\"" in lockBody

      # ---- load the lock through the unified populator + assert per-dep shape.
      let ld = populateLockedDeps(
        LockSource(kind: lskCommittedLock, workspaceRoot: repo))

      var storeIdx = -1
      var registryIdx = -1
      for i, d in ld.deps:
        if d.coordinates.kind == ckStore: storeIdx = i
        elif d.coordinates.kind == ckRegistry: registryIdx = i
      check storeIdx >= 0
      check registryIdx >= 0

      # Store dep: well-formed self-describing multihash; for a content-addressed
      # store the integrity digest IS the store_hash coordinate.
      let storeDep = ld.deps[storeIdx]
      check storeDep.name == "app"
      check storeDep.coordinates.storeHash.len > 0
      check isWellFormedMultihash(storeDep.integrity)
      check storeDep.integrity == "blake3:" & storeDep.coordinates.storeHash
      # Grounded: it equals a fresh recompute over the package's solved identity.
      check storeDep.coordinates.storeHash ==
        solvedPackageStoreHash("app", "0.1.0", ld.platform)

      # Registry dep: well-formed self-describing multihash = the package
      # checksum over the registry coordinate.
      let regDep = ld.deps[registryIdx]
      check regDep.name == "leftpad"
      check regDep.coordinates.registryName == "npmjs"
      check regDep.coordinates.registryVersion == "1.2.0"
      check isWellFormedMultihash(regDep.integrity)
      check regDep.integrity ==
        solvedPackageRegistryIntegrity("npmjs", "leftpad", "1.2.0")

      # ---- verify PASSES on the honest lock (store + registry recompute). ----
      check verifyLockedIntegrityAtCoordinates(repo, ld).len == 0

      # ---- verify FAILS when the STORE integrity is tampered. ----
      block storeIntegrityTamper:
        var bad = ld
        bad.deps[storeIdx].integrity = flipOneHex(bad.deps[storeIdx].integrity)
        check isWellFormedMultihash(bad.deps[storeIdx].integrity)  # still valid form
        let fails = verifyLockedIntegrityAtCoordinates(repo, bad)
        check fails.len == 1
        check fails[0].name == "app"
        check "store integrity" in fails[0].diagnostic

      # ---- verify FAILS when the STORE coordinate (store_hash) is tampered. ----
      block storeCoordTamper:
        var bad = ld
        bad.deps[storeIdx].coordinates.storeHash =
          flipOneHex(bad.deps[storeIdx].coordinates.storeHash)
        let fails = verifyLockedIntegrityAtCoordinates(repo, bad)
        check fails.len == 1
        check fails[0].name == "app"

      # ---- verify FAILS when the REGISTRY integrity is tampered. ----
      block registryIntegrityTamper:
        var bad = ld
        bad.deps[registryIdx].integrity =
          flipOneHex(bad.deps[registryIdx].integrity)
        check isWellFormedMultihash(bad.deps[registryIdx].integrity)
        let fails = verifyLockedIntegrityAtCoordinates(repo, bad)
        check fails.len == 1
        check fails[0].name == "leftpad"
        check "registry integrity" in fails[0].diagnostic

      # ---- the lock still validates (the packages sub-part round-trips). ----
      let validate = run(reproBinary & " lock validate " & q(repo))
      check validate.code == 0
