## The gate must write the lock record it is about to demand.
##
## The incident
## ------------
## Two sibling repos of one project, with identical manifest fragments,
## identical branches, identical committed `repro.lock` presence and identical
## clean/published git state, disagreed about whether they could be pushed:
##
##   $ repro check --mode=pre-push --current-repo=…/codetracer-evm-recorder
##   repro check: OK
##
##   $ repro check --mode=pre-push --current-repo=…/codetracer-fuel-recorder
##   repro check: lock publication failed: expected lock record is not
##     reachable at ba9bbc58…: locks/codetracer/codetracer-fuel-recorder/
##     ed7739e2….toml
##   repro check: lock-publish-failure — run 'repro push' …
##
## An earlier investigation could not isolate the discriminator. It is not a
## property of either repo. It is this:
##
##   * the gate APPENDS an expected lock record — keyed
##     ``locks/<project>/<pushed repo>/<its HEAD>.toml`` — whenever
##     ``--current-repo`` resolves to a declared repo with an observable HEAD,
##     and the publisher then proves that record is reachable from the store's
##     HEAD; but
##   * the gate only CREATED that record when the push was additionally
##     accepted as ``outgoing-current``: a single fast-forward HEAD update to
##     the manifest-agreed remote, which needs a ``--pushed-refs`` stream and
##     is declined for a same-oid update, a force update, or no stream at all.
##
## Outside that narrow shape the gate reported "lock already current", wrote
## nothing, and then refused the push for the absence of the very record it had
## declined to write. The writer creates no commit, and then the verifier looks
## for one.
##
## Which repo that kills is therefore pure history: a repo that has ever been
## an explicit trigger at its CURRENT head already has the record, so the
## missing write goes unnoticed; its otherwise identical sibling that has not
## is refused, and stays refused, because nothing on the refused path ever
## writes the record. In the field one sibling had been pushed once after a
## store cleanup and the other had not — that, and nothing about the repos,
## was the whole difference.
##
## What is asserted
## ----------------
## The fixture reproduces both sides in ONE workspace so the discriminator is
## demonstrated rather than asserted:
##
##   * ``anchored`` has been an explicit lock trigger at its current HEAD, so
##     its record exists — the passing sibling;
##   * ``unanchored`` never has — the failing sibling. Both are declared the
##     same way, both are clean, both are published, and the newest lock record
##     in the store already pins BOTH at exactly their current HEADs, so the
##     gate's staleness comparison finds nothing to do for either.
##
## The absence of ``unanchored``'s record is established by a positive find
## over the same enumeration that finds ``anchored``'s, so it cannot be read
## off an empty scan. After the gate runs it is required to be present, in the
## store's HEAD tree, and pushed to the store's upstream — a record that exists
## only in the working tree would satisfy a ``fileExists`` check and still fail
## the publisher.
##
## Hermetic: fresh tempdir, local ``git init``/``--bare`` only, no network.
## Black-box: the real ``./build/bin/repro`` through ``check --mode=pre-push``.
## No mocks — real git, real lock store, real gate.
## Skip: ``git`` missing or ``./build/bin/repro`` absent.

import std/[algorithm, os, osproc, strutils, tempfiles, unittest]

const reproBinary = "./build/bin/repro"

proc q(value: string): string = quoteShell(value)

proc run(command: string; cwd = ""): tuple[code: int; output: string] =
  let res = execCmdEx(command, workingDir = cwd)
  (code: res.exitCode, output: res.output)

proc requireRun(command: string; cwd = ""): string =
  let res = run(command, cwd)
  if res.code != 0:
    checkpoint("command failed: " & command & "\nexit=" & $res.code &
      "\n" & res.output)
    quit 1
  res.output

proc silenceLayers(scratch: string) =
  putEnv("REPROBUILD_SYSTEM_CONFIG", scratch / "no-system.toml")
  putEnv("REPROBUILD_USER_CONFIG", scratch / "no-user.toml")
  putEnv("REPROBUILD_VCS_PRIVATE_CONFIG", scratch / "no-vcs.toml")

proc unsilenceLayers() =
  delEnv("REPROBUILD_SYSTEM_CONFIG")
  delEnv("REPROBUILD_USER_CONFIG")
  delEnv("REPROBUILD_VCS_PRIVATE_CONFIG")

suite "the pre-push gate writes the lock record it demands":

  test "t_pre_push_writes_the_lock_record_it_demands":
    let gitBin = findExe("git")
    if gitBin.len == 0 or not fileExists(reproBinary):
      skip()
    else:
      let reproAbs = absolutePath(reproBinary)
      let scratch = createTempDir("gate-writes-record-", "")
      defer: removeDir(scratch)
      silenceLayers(scratch)
      defer: unsilenceLayers()

      let git = q(gitBin)
      proc gitCfg(repo: string) =
        discard requireRun(git & " -C " & q(repo) &
          " config user.email tester@example.invalid")
        discard requireRun(git & " -C " & q(repo) &
          " config user.name \"Record Tester\"")

      let ws = scratch / "workspace"
      createDir(ws / "projects")
      createDir(ws / "repos")

      # Distinct seed content so the two repos' HEAD SHAs differ: a record path
      # is keyed by (repo, sha), and identical SHAs would make "the record for
      # THIS repo" indistinguishable from "the record for the other one".
      proc declareRepo(name, seed: string) =
        let origin = scratch / ("origin-" & name & ".git")
        discard requireRun(git & " init -q --bare -b main " & q(origin))
        discard requireRun(git & " clone -q " & q("file://" & origin) & " " &
          q(ws / name))
        gitCfg(ws / name)
        writeFile(ws / name / "seed.txt", seed)
        discard requireRun(git & " -C " & q(ws / name) & " add -A")
        discard requireRun(git & " -C " & q(ws / name) &
          " commit -qm " & q("seed " & name))
        discard requireRun(git & " -C " & q(ws / name) & " push -q origin main")
        writeFile(ws / "repos" / (name & ".toml"),
          "schema = \"reprobuild.workspace.repo.v1\"\n\n" &
          "[repo]\nname = \"" & name & "\"\npath = \"" & name & "\"\n" &
          "remote = \"" & name & "-origin\"\nrevision = \"main\"\n")

      writeFile(ws / "projects" / "mix.toml",
        "schema = \"reprobuild.workspace.project.v1\"\n\n" &
        "[project]\nname = \"mix\"\ndefault_revision = \"main\"\n" &
        "trunk = \"main\"\n\n" &
        "[[remote]]\nname = \"anchored-origin\"\nfetch = \"file://" &
          scratch / "origin-anchored.git" & "\"\n\n" &
        "[[remote]]\nname = \"unanchored-origin\"\nfetch = \"file://" &
          scratch / "origin-unanchored.git" & "\"\n\n" &
        "includes = [\n  \"repos/anchored.toml\",\n" &
        "  \"repos/unanchored.toml\",\n]\n")
      declareRepo("anchored", "anchored seed\n")
      declareRepo("unanchored", "unanchored seed\n")

      let store = ws / ".repro" / "manifests"
      createDir(parentDir(store))
      let storeOrigin = scratch / "origin-manifests.git"
      discard requireRun(git & " init -q --bare -b main " & q(storeOrigin))
      discard requireRun(git & " clone -q " & q("file://" & storeOrigin) &
        " " & q(store))
      gitCfg(store)
      writeFile(store / "README.md", "lock store\n")
      discard requireRun(git & " -C " & q(store) & " add -A")
      discard requireRun(git & " -C " & q(store) & " commit -qm seed")
      discard requireRun(git & " -C " & q(store) & " push -q origin main")

      writeFile(ws / ".repro" / "workspace.toml",
        "schema = \"reprobuild.workspace.local.v1\"\n\n" &
        "[workspace]\nproject = \"mix\"\nbranch = \"main\"\n")

      discard requireRun(git & " init -q -b main " & q(ws))
      gitCfg(ws)
      writeFile(ws / ".gitignore", "/.repro/\n/anchored/\n/unanchored/\n")
      discard requireRun(git & " -C " & q(ws) & " add -A")
      discard requireRun(git & " -C " & q(ws) & " commit -qm \"seed manifests\"")

      proc headOf(repo: string): string =
        requireRun(git & " -C " & q(repo) & " rev-parse HEAD").strip()

      let anchoredSha = headOf(ws / "anchored")
      let unanchoredSha = headOf(ws / "unanchored")
      check anchoredSha != unanchoredSha

      # ---- the ONLY asymmetry the fixture introduces ----------------------
      # One explicit lock anchored at ``anchored``. Its document pins BOTH
      # repos at exactly their current HEADs, so from here the gate's staleness
      # comparison is satisfied for both and neither is "stale".
      let seedLock = run(reproAbs & " workspace lock --workspace-root=" &
        q(ws) & " --trigger-repo=anchored")
      checkpoint("seed lock: exit " & $seedLock.code & "\n" & seedLock.output)
      check seedLock.code == 0

      proc storeRecords(): seq[string] =
        let root = store / "locks"
        if not dirExists(root): return @[]
        for path in walkDirRec(root):
          if path.endsWith(".toml"):
            result.add(path[store.len + 1 .. ^1].replace(DirSep, '/'))
        result.sort()

      let anchoredRecord = "locks/mix/anchored/" & anchoredSha & ".toml"
      let unanchoredRecord = "locks/mix/unanchored/" & unanchoredSha & ".toml"
      let before = storeRecords()
      checkpoint("records before: " & before.join(" "))
      # Positive find and paired absence over the SAME enumeration: the scan
      # provably works, so the absence below is a fact about the store rather
      # than about the scan.
      check anchoredRecord in before
      check unanchoredRecord notin before
      # ...and the seeded document really does pin the unanchored repo at its
      # current HEAD, which is what makes the gate call the lock "current" and
      # skip the write. Without this the test would be reproducing a plain
      # stale-lock refresh instead of the defect.
      check readFile(store / anchoredRecord.replace('/', DirSep))
        .contains(unanchoredSha)

      proc gate(repo: string): tuple[code: int; output: string] =
        # No ``--pushed-refs``: this is the diagnostic form of the very gate
        # git's hook runs, and the form the incident was reproduced with. The
        # record obligation must not depend on which of the two forms is used.
        run(reproAbs & " check --mode=pre-push --write-report" &
          " --workspace-root=" & q(ws) &
          " --current-repo=" & q(ws / repo), cwd = ws / repo)

      # ---- the passing sibling -------------------------------------------
      let anchoredGate = gate("anchored")
      checkpoint("gate(anchored): exit " & $anchoredGate.code & "\n" &
        anchoredGate.output)
      check anchoredGate.code == 0

      # ---- the failing sibling, which differs in nothing else -------------
      let unanchoredGate = gate("unanchored")
      checkpoint("gate(unanchored): exit " & $unanchoredGate.code & "\n" &
        unanchoredGate.output)
      check not unanchoredGate.output.contains(
        "expected lock record is not reachable")
      check unanchoredGate.code == 0

      # The record the gate demanded is the record the gate wrote — present on
      # disk, in the store's HEAD tree, and pushed to the store's upstream. A
      # working-tree-only file would pass a `fileExists` check and still leave
      # the publisher refusing.
      let after = storeRecords()
      checkpoint("records after: " & after.join(" "))
      check unanchoredRecord in after
      check anchoredRecord in after
      check requireRun(git & " -C " & q(store) & " ls-tree HEAD -- " &
        q(unanchoredRecord)).strip().len > 0
      check requireRun(git & " -C " & q(store) &
        " ls-tree origin/main -- " & q(unanchoredRecord)).strip().len > 0

      # ---- and it is idempotent -------------------------------------------
      # Re-running the gate must not try to re-publish, re-write, or trip the
      # immutability refusal on the record it just created.
      let again = gate("unanchored")
      checkpoint("gate(unanchored) again: exit " & $again.code & "\n" &
        again.output)
      check again.code == 0
      check storeRecords() == after
