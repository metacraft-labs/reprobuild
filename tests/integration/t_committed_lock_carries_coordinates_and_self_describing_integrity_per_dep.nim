## Workspace-Manifest-Optional MO-8 — the committed lock is SELF-DESCRIBING:
## ``repro lock refresh`` writes a ``reprobuild.solved-graph-lock.v2`` lock in
## which every locked dependency carries checkout COORDINATES (url / ref /
## revision) AND a self-describing INTEGRITY multihash (``<alg>:<digest>``).
##
## Drives a built ``./build/bin/repro`` against a single git workspace repo
## (origin + clone, one published commit) carrying a ``repro.solver`` sidecar.
## Asserts:
##
##   1. ``repro lock refresh`` writes ``repro.lock`` with schema v2.
##   2. The lock carries a ``deps = [...]`` array; the workspace repo's dep
##      (path ".") carries coordinates: ``url = ...`` (origin), ``ref = ...``
##      (branch), ``revision = <40-hex git sha>``.
##   3. That dep carries an ``integrity = "<alg>:<digest>"`` whose ``<alg>`` is
##      a registered code (here ``git-sha1`` — the VCS-native object id) and
##      whose ``<digest>`` is non-empty lowercase hex. The recorded revision
##      and the git-sha1 integrity digest are the same commit id (the commit
##      is BOTH the coordinate and the integrity for a content-addressed VCS).
##   4. The lock round-trips: ``repro lock validate`` (which re-reads, re-
##      serializes, and recomputes the integrity) reports OK on the freshly
##      written lock — proving the model is internally consistent and
##      byte-stable (write -> read -> write same model).
##
## Falsifiability: if ``refresh`` recorded no coordinates / no integrity per
## dep, (2) and (3) FAIL (the ``deps`` array / ``integrity`` key is absent);
## if the integrity were a fake constant unrelated to the commit, (3)'s
## "revision == git-sha1 digest" equality FAILS.
##
## Hermetic: the git repo lives in a fresh tempdir. Skip rule: ``git`` missing
## or repro unbuilt.

import std/[os, osproc, strutils, unittest]

const reproBinary = "./build/bin/repro"

const solverInputs = """
package app
versions: 0.1.0
depends: nim >=2.2.0 <3.0.0

package nim
versions: 2.2.0
"""

proc q(value: string): string = quoteShell(value)

proc run(command: string): tuple[code: int; output: string] =
  let res = execCmdEx(command)
  (code: res.exitCode, output: res.output)

proc git(gitBin, repo, rest: string): tuple[code: int; output: string] =
  run(q(gitBin) & " -C " & q(repo) & " " & rest)

proc isLowerHex(s: string): bool =
  if s.len == 0: return false
  for c in s:
    if c notin {'0'..'9', 'a'..'f'}: return false
  true

suite "MO-8: committed lock carries coordinates + self-describing integrity":

  test "t_committed_lock_carries_coordinates_and_self_describing_integrity_per_dep":
    let gitBin = findExe("git")
    if gitBin.len == 0 or not fileExists(reproBinary):
      skip()
    else:
      let scratch = getTempDir() / "mo8-coords-" & $getCurrentProcessId()
      removeDir(scratch)
      createDir(scratch)
      defer: removeDir(scratch)

      # ---- A bare origin + a clone seeded with one published commit. ----
      let origin = scratch / "origin.git"
      let repo = scratch / "work"
      check git(gitBin, "", "init --bare -b main " & q(origin)).code == 0
      check run(q(gitBin) & " clone " & q(origin) & " " & q(repo)).code == 0
      check git(gitBin, repo, "config user.email t@example.invalid").code == 0
      check git(gitBin, repo, "config user.name Tester").code == 0
      writeFile(repo / "README.md", "mo8 fixture\n")
      writeFile(repo / "repro.solver", solverInputs)
      check git(gitBin, repo, "add README.md repro.solver").code == 0
      check git(gitBin, repo, "commit -m seed").code == 0
      check git(gitBin, repo, "push origin main").code == 0

      let headSha = git(gitBin, repo, "rev-parse HEAD").output.strip()
      check headSha.len == 40
      let originUrl = git(gitBin, repo, "remote get-url origin").output.strip()

      # ---- (1) refresh writes a v2 lock. ----
      let refresh = run(reproBinary & " lock refresh " & q(repo))
      check refresh.code == 0
      let lockBody = readFile(repo / "repro.lock")
      check "reprobuild.solved-graph-lock.v2" in lockBody

      # ---- (2) the dep carries coordinates. ----
      check "deps = [" in lockBody
      check ("revision = \"" & headSha & "\"") in lockBody
      check ("url = \"" & originUrl & "\"") in lockBody
      check "ref = \"main\"" in lockBody
      check "path = \".\"" in lockBody

      # ---- (3) the dep carries a well-formed self-describing integrity, and
      # for this content-addressed VCS it is the commit object id (git-sha1).
      check ("integrity = \"git-sha1:" & headSha & "\"") in lockBody
      # Parse out the integrity value generically and assert <alg>:<hex>.
      let intgMarker = "integrity = \""
      let ii = lockBody.find(intgMarker)
      check ii >= 0
      let afterIntg = lockBody[ii + intgMarker.len .. ^1]
      let intgVal = afterIntg[0 ..< afterIntg.find('"')]
      let colon = intgVal.find(':')
      check colon > 0
      check intgVal[0 ..< colon] in ["git-sha1", "git-sha256", "blake3"]
      check isLowerHex(intgVal[colon + 1 .. ^1])
      # The git-sha1 integrity digest IS the recorded revision (coordinate ==
      # integrity for a content-addressed VCS) — not a fake constant.
      check intgVal == "git-sha1:" & headSha

      # ---- (4) the lock round-trips + the model is internally consistent. ----
      let validate = run(reproBinary & " lock validate " & q(repo))
      check validate.code == 0
      check "OK" in validate.output
