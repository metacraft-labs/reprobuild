## HL-11 shared helpers for the cases about a repo that carries BOTH locks: a
## committed `repro.lock` beside the NF-2 fixture's `flake.nix` / `flake.lock`.
##
## Deliberately not a `t_*.nim` file, for the reason
## `nf2_flake_lock_fixture.nim` states: `scripts/generate_test_edges.nim` only
## discovers `t_*` / `test_*` stems, so this helper is never compiled as a test
## of its own.
##
## Test-double policy: NO mocks, doubles or fakes. Every helper below writes a
## real file in its real on-disk shape (a `repro.lock` in the shipped
## `reprobuild.solved-graph-lock.v2` schema) or drives real git. See
## `nf2_flake_lock_fixture.nim` for the inventory of the fixture they extend.

import std/[os, strutils]

import nf3_override_state_fixture
export nf3_override_state_fixture

proc lineNumberOf*(text, needle: string): int =
  ## The 1-based line of the first line of ``text`` containing ``needle``, or
  ## 0.
  var n = 0
  for line in text.splitLines():
    inc n
    if needle in line: return n
  0

proc commitWithoutHook*(fx: Nf2Fixture; message: string) =
  ## Commit whatever the working tree holds WITHOUT the pre-commit hook, and
  ## publish it: the bypassed commit path the push gate exists to catch.
  removePreCommitDispatch(fx)
  discard gitIn(fx, fx.app, "add -A")
  discard gitIn(fx, fx.app, "commit -q -m " & q(message))
  publishRepo(fx, fx.app)
  installPreCommitDispatch(fx)

proc stagedText*(fx: Nf2Fixture; rel: string): string =
  ## ``rel`` as the index holds it: what a refused commit left staged.
  run(q(fx.gitBin) & " -C " & q(fx.app) & " show " & q(":" & rel)).output

proc committedText*(fx: Nf2Fixture; rel: string; rev = "HEAD"): string =
  ## ``rel`` as the commit ``rev`` carries it.
  run(q(fx.gitBin) & " -C " & q(fx.app) & " show " & q(rev & ":" & rel)).output

proc lockDepEntry*(fx: Nf2Fixture; name, path, origin, rev: string): string =
  ## One `deps` entry of a committed `repro.lock`, fetching ``origin``.
  "{ name = \"" & name & "\", path = \"" & path &
  "\", coord_kind = \"vcs\", url = \"" & originUrl(fx, origin) &
  "\", ref = \"main\", revision = \"" & rev &
  "\", integrity = \"git-sha1:" & rev &
  "\", version = \"\", visibility = \"public\", participation = \"\"" &
  ", depends = \"\", groups = \"\" }"

proc reproLockText*(fx: Nf2Fixture; owner, ownerRev: string;
    deps: openArray[string]; packages = ""): string =
  ## A committed `repro.lock` in the shipped `reprobuild.solved-graph-lock.v2`
  ## shape: the owner's root entry plus ``deps``.
  var all = @[lockDepEntry(fx, owner, ".", owner, ownerRev)]
  for d in deps: all.add(d)
  "schema = \"reprobuild.solved-graph-lock.v2\"\n\n[lock]\n" &
  "platform = \"x86_64-linux\"\noptimal = true\n" &
  "inputs_digest = \"h1-h2-fixture\"\nvariants = []\n" &
  "packages = [" & packages & "]\n" &
  "deps = [" & all.join(", ") & "]\n"

proc packageEntry*(name, version: string): string =
  ## One selected `packages` entry of a committed `repro.lock`.
  "{ name = \"" & name & "\", version = \"" & version & "\", source = \"" &
    name & "\", selection = \"selected\" }"

proc lockedRevOfNode*(lockText, node: string): string =
  ## ``locked.rev`` of one node of a `flake.lock`, read from its raw text.
  let n = nodeText(lockText, node)
  let lockedAt = n.find("\"locked\"")
  if lockedAt < 0: return ""
  let revAt = n.find("\"rev\": \"", lockedAt)
  if revAt < 0: return ""
  let start = revAt + "\"rev\": \"".len
  let stop = n.find('"', start)
  if stop < 0: "" else: n[start ..< stop]

proc reproLockRevisionOf*(lockText, name: string): string =
  ## The `revision` of the `repro.lock` entry ``name``, or "".
  let key = "{ name = \"" & name & "\", "
  let at = lockText.find(key)
  if at < 0: return ""
  let revAt = lockText.find("revision = \"", at)
  if revAt < 0: return ""
  let start = revAt + "revision = \"".len
  let stop = lockText.find('"', start)
  if stop < 0: "" else: lockText[start ..< stop]

proc indexTree*(fx: Nf2Fixture): string =
  ## The tree the index would record (`git write-tree`): the index, byte for
  ## byte, as one object id.
  gitIn(fx, fx.app, "write-tree").strip()

proc tryCommitKeepingIndex*(fx: Nf2Fixture; message: string):
    tuple[code: int; output: string; head: string; treeBefore: string;
          treeAfter: string] =
  ## ``tryCommitInApp``, plus the index tree just before `git commit` runs the
  ## hook and just after it returns: a refused commit must leave the index
  ## exactly as it found it.
  let stamp = message.replace(" ", "-")
  writeFile(fx.app / (stamp & ".txt"), message & "\n")
  discard gitIn(fx, fx.app, "add -A")
  result.treeBefore = indexTree(fx)
  let res = run(q(fx.gitBin) & " -C " & q(fx.app) & " commit -q -m " &
    q(message))
  result.code = res.code
  result.output = res.output
  result.head = headOf(fx, fx.app)
  result.treeAfter = indexTree(fx)
