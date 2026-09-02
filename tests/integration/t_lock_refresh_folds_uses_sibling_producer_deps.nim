## FUP-M — ``repro lock refresh`` folds a recipe's declared ``uses:`` SIBLING
## PRODUCER edges into the committed lock's ``deps``.
##
## Regression for the bug FUP-J discovered: refresh built ``deps`` purely from
## develop-mode DISCOVERY (nested ``deps/…`` + ``.repro/develop-overrides.toml``)
## and IGNORED the recipe's ``uses:`` producer selectors. A consumer whose only
## cross-repo edge is a ``uses: "<sibling>"`` (no override entry, no nested
## checkout) therefore refreshed to a SELF-ONLY lock — the solver resolved the
## sibling into ``packages`` but the unified ``deps`` set dropped it, so a
## lock-only build could not resolve the producer graph.
##
## Fixture (built ``./build/bin/repro``, black-box):
##
##   <scratch>/
##     producer/                  a SIBLING producer — its own git repo
##       repro.nim                declares ``library producer`` (a uses: target)
##     consumer/                  the workspace repo (its own git repo)
##       repro.nim                ``uses: "nim >=2.0"`` + ``uses: "producer"``
##       repro.lock               written by ``repro lock refresh``
##   (NO ``.repro/develop-overrides.toml`` — the ONLY edge to the sibling is the
##    recipe's ``uses: "producer"`` declaration, so this exercises the uses:
##    producer fold specifically, NOT the develop-override discovery path.)
##
## Asserts:
##   1. After ``repro lock refresh``, the committed lock carries the sibling
##      producer as a first-class ``deps`` entry: ``path = "../producer"`` with
##      VCS coordinates (``coord_kind = "vcs"`` + the sibling's HEAD ``revision``)
##      AND a self-describing ``integrity`` multihash.
##   2. The root consumer dep gains a ``depends`` edge onto ``producer``.
##   3. A toolchain ``uses:`` that names NO on-disk sibling (``nim``) is NOT
##      locked as a dep — only genuine cross-repo source siblings become deps.
##   4. No ``.repro/develop-overrides.toml`` is present, proving (1) came from
##      the ``uses:`` fold and not the override discovery path.
##
## Falsifiability: on the pre-fix code (``lockedDepsForWorkspace`` ignoring the
## recipe's ``uses:`` selectors) the lock is self-only — ``path = "../producer"``
## is absent and the root ``depends`` edge is empty, so (1) and (2) FAIL.
##
## Hermetic: every git repo lives in a fresh tempdir; nothing touches $HOME.
## Skip rule: ``git`` missing on PATH, or repro unbuilt.

import std/[os, osproc, strutils, unittest]

const ReprobuildRepoRoot = currentSourcePath().parentDir().parentDir().parentDir()
  ## The reprobuild checkout root, resolved from THIS SOURCE FILE's path
  ## rather than from the process working directory.
  ##
  ## The previous spelling (``"./build/bin/" & addFileExt("repro", ExeExt)``)
  ## made the working directory an unstated fixture input: from the repo root
  ## the case ran, from any other directory ``fileExists`` was false and it
  ## SKIPPED, and from a scratch directory that happened to carry a staged
  ## ``build/bin/repro`` it ran against THAT binary and reported failures that
  ## read as product refusals. ``currentSourcePath()`` is absolute on both
  ## platforms, so this constant is the same from every cwd.
const reproBinary = ReprobuildRepoRoot / "build/bin/repro".addFileExt(ExeExt)

const producerRecipe = """
import repro_project_dsl

package producer:
  library producer
  build:
    discard aggregate("producer-aggregate", actions = @[])
"""

const consumerRecipe = """
import repro_project_dsl

package consumer:
  defaultToolProvisioning "path"
  uses:
    "nim >=2.0"
    "producer"
  build:
    discard aggregate("consumer-aggregate", actions = @[])
"""

proc q(value: string): string = quoteShell(value)

proc run(command: string; cwd = ""): tuple[code: int; output: string] =
  let res = execCmdEx(command, workingDir = cwd)
  (code: res.exitCode, output: res.output)

proc git(gitBin, repo, rest: string): tuple[code: int; output: string] =
  run(q(gitBin) & " -C " & q(repo) & " " & rest)

proc initRepo(gitBin, dir: string) =
  check git(gitBin, "", "init -q -b main " & q(dir)).code == 0
  check git(gitBin, dir, "config user.email t@example.invalid").code == 0
  check git(gitBin, dir, "config user.name Tester").code == 0

suite "FUP-M: lock refresh folds uses: sibling producer deps":

  test "t_lock_refresh_folds_uses_sibling_producer_deps":
    let gitBin = findExe("git")
    if gitBin.len == 0 or not fileExists(reproBinary):
      skip()
    else:
      let scratch = getTempDir() / "fupm-uses-sibling-" & $getCurrentProcessId()
      removeDir(scratch)
      createDir(scratch)
      defer: removeDir(scratch)

      # ---- The SIBLING producer, one level up: its own git repo carrying a
      # reprobuild project that declares a ``library`` (a uses: target).
      let producer = scratch / "producer"
      createDir(producer)
      initRepo(gitBin, producer)
      writeFile(producer / "repro.nim", producerRecipe)
      check git(gitBin, producer, "add repro.nim").code == 0
      check git(gitBin, producer, "commit -q -m producer").code == 0

      # ---- The consumer workspace repo. Its ONLY edge to the sibling is the
      # recipe's ``uses: "producer"`` — there is NO develop-override file.
      # The checkout basename intentionally differs from its origin repository
      # name. A committed lock must remain stable when the same repository is
      # cloned into another directory.
      let consumer = scratch / "consumer-checkout"
      createDir(consumer)
      initRepo(gitBin, consumer)
      check git(gitBin, consumer,
        "remote add origin https://example.invalid/acme/consumer.git").code == 0
      writeFile(consumer / "repro.nim", consumerRecipe)
      check git(gitBin, consumer, "add repro.nim").code == 0
      check git(gitBin, consumer, "commit -q -m consumer").code == 0

      # Precondition (4): no override file — the uses: edge is the only path.
      check not fileExists(consumer / ".repro" / "develop-overrides.toml")

      # ---- refresh the lock: it must fold the uses: sibling into `deps`. ----
      let refresh = run(reproBinary & " lock refresh " & q(consumer))
      checkpoint("refresh exit=" & $refresh.code)
      checkpoint(refresh.output)
      check refresh.code == 0
      check fileExists(consumer / "repro.lock")
      let lockBody = readFile(consumer / "repro.lock")

      check "name = \"consumer\", path = \".\"" in lockBody
      check "name = \"consumer-checkout\", path = \".\"" notin lockBody

      # (1) The sibling producer is a first-class locked dep: workspace-relative
      # path, VCS coordinates (kind + revision) + a self-describing integrity.
      check "path = \"../producer\"" in lockBody
      check "coord_kind = \"vcs\"" in lockBody
      let producerSha = git(gitBin, producer, "rev-parse HEAD").output.strip()
      check producerSha in lockBody              # the sibling revision is pinned
      check "integrity = \"git-" in lockBody     # self-describing VCS integrity

      # (2) The root consumer repo depends on the producer.
      check "depends = \"producer\"" in lockBody or
            "depends = \"producer," in lockBody or
            ",producer\"" in lockBody or ",producer," in lockBody

      # (3) The toolchain ``uses: "nim"`` is NOT folded as a dep — no ``nim``
      # sibling exists, so only genuine cross-repo source siblings are locked.
      check "path = \"../nim\"" notin lockBody
      check "name = \"nim\", path" notin lockBody
