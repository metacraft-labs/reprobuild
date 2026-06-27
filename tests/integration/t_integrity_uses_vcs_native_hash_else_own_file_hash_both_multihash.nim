## Workspace-Manifest-Optional MO-8 — the locked integrity is the VCS-native
## content hash where one exists, else Reprobuild's OWN deterministic
## NAR-style file hash. Both are self-describing multihashes (``<alg>:<hex>``).
##
## Drives a built ``./build/bin/repro``:
##
##   A. A GIT workspace dep -> ``repro lock refresh`` records integrity tagged
##      ``git-sha1`` (or ``git-sha256``): the VCS-native object id.
##   B. A NON-content-addressed source (a plain directory with NO ``.git``) ->
##      refresh records integrity tagged ``blake3``: Reprobuild's OWN NAR-style
##      hash over the checked-out files. Changing a file's CONTENT changes the
##      integrity — proving it genuinely hashes the contents, not a constant.
##
## Both integrity values are asserted to be well-formed self-describing
## multihashes (a registered ``<alg>`` + non-empty lowercase-hex digest).
##
## Falsifiability: a fake/constant integrity that did not hash file content
## would leave B's integrity UNCHANGED after the edit, failing the
## "integrity changed" assertion; a non-multihash value fails the
## ``<alg>:<hex>`` shape assertions.
##
## Hermetic: fresh tempdirs. Skip rule: ``git`` missing or repro unbuilt.

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

proc firstIntegrity(lockBody: string): string =
  ## Extract the first ``integrity = "<value>"`` value from a lock body.
  const marker = "integrity = \""
  let i = lockBody.find(marker)
  if i < 0: return ""
  let rest = lockBody[i + marker.len .. ^1]
  rest[0 ..< rest.find('"')]

proc assertWellFormedMultihash(value: string) =
  let colon = value.find(':')
  check colon > 0
  check value[0 ..< colon] in ["git-sha1", "git-sha256", "blake3", "fnv1a64"]
  check isLowerHex(value[colon + 1 .. ^1])

suite "MO-8: integrity is VCS-native hash else own-file-hash, both multihash":

  test "t_integrity_uses_vcs_native_hash_else_own_file_hash_both_multihash":
    let gitBin = findExe("git")
    if gitBin.len == 0 or not fileExists(reproBinary):
      skip()
    else:
      let scratch = getTempDir() / "mo8-integrity-" & $getCurrentProcessId()
      removeDir(scratch)
      createDir(scratch)
      defer: removeDir(scratch)

      # ===== A. GIT dep -> VCS-native integrity (git-sha1). =====
      let gitWs = scratch / "gitws"
      createDir(gitWs)
      check git(gitBin, "", "init -b main " & q(gitWs)).code == 0
      check git(gitBin, gitWs, "config user.email t@example.invalid").code == 0
      check git(gitBin, gitWs, "config user.name Tester").code == 0
      writeFile(gitWs / "repro.solver", solverInputs)
      check git(gitBin, gitWs, "add repro.solver").code == 0
      check git(gitBin, gitWs, "commit -m seed").code == 0
      let headSha = git(gitBin, gitWs, "rev-parse HEAD").output.strip()
      check run(reproBinary & " lock refresh " & q(gitWs)).code == 0

      let gitIntegrity = firstIntegrity(readFile(gitWs / "repro.lock"))
      assertWellFormedMultihash(gitIntegrity)
      # The VCS-native content hash is the commit object id.
      check gitIntegrity == "git-sha1:" & headSha
      check gitIntegrity.startsWith("git-sha1:")

      # ===== B. Non-content-addressed source -> own-file-hash (blake3). =====
      let plainWs = scratch / "plainws"   # NO .git anywhere.
      createDir(plainWs)
      writeFile(plainWs / "repro.solver", solverInputs)
      writeFile(plainWs / "payload.txt", "original content\n")
      check not dirExists(plainWs / ".git")
      check run(reproBinary & " lock refresh " & q(plainWs)).code == 0

      let blakeIntegrity1 = firstIntegrity(readFile(plainWs / "repro.lock"))
      assertWellFormedMultihash(blakeIntegrity1)
      check blakeIntegrity1.startsWith("blake3:")

      # Changing a file's CONTENT changes the own-file-hash integrity.
      writeFile(plainWs / "payload.txt", "DIFFERENT content now\n")
      check run(reproBinary & " lock refresh " & q(plainWs)).code == 0
      let blakeIntegrity2 = firstIntegrity(readFile(plainWs / "repro.lock"))
      assertWellFormedMultihash(blakeIntegrity2)
      check blakeIntegrity2.startsWith("blake3:")
      check blakeIntegrity2 != blakeIntegrity1   # genuinely hashes content

      # Re-refreshing WITHOUT changing files is stable (the lock file itself is
      # excluded from the own-file-hash, so it is not self-referential).
      check run(reproBinary & " lock refresh " & q(plainWs)).code == 0
      check firstIntegrity(readFile(plainWs / "repro.lock")) == blakeIntegrity2
