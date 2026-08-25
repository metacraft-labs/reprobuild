## DS-7 (CLI/develop.md §"Membership axis", stage 1) — **the dependency-edge
## selection modes, over a lock set that actually HAS dependency edges**.
##
##   > 1. **mode** — `--all` (default) | `--direct` | `--indirect` |
##   >    `--transitive-of=<pkg>`
##
## Why this is not cosmetic. `t_develop_selectors_compose_in_fixed_order`
## exercises `--direct` / `--indirect` only against a fixture whose repos
## declare no `depends` at all, where the root repo has no edges — so `--direct`
## selects nothing, `--indirect` selects the whole closure, and the two modes
## are indistinguishable from "empty" and "everything". That fixture can tell
## you the flags PARSE; it cannot tell you they SELECT anything, and
## `--indirect` (specified in the V1 proposal from the beginning, implemented
## for the first time in this change) was never exercised against a single real
## edge.
##
## The edges are constructible and always were: `repos/<repo>.toml` carries a
## documented `depends` array (Workspace-Manifests.md §"`repos/<repo>.toml`"),
## the resolver copies it into `ResolvedRepo.depends`, and
## `lockedDepFromStoreRepo` copies THAT into `LockedDep.depends` — which is the
## field `dasmDirect`, `dasmIndirect` and `dasmTransitiveOf` read. A
## manifest-backed lock set therefore carries dependency edges whenever the
## fragments declare them.
##
## Fixture (built ``./build/bin/repro``, black-box, fully offline):
##
##   <scratch>/
##     origin-lib-{a,b,c,d}.git   — four seeded repos
##     ws/                        — the workspace ROOT repo, at manifest path
##                                  "." (only a repo at "." can HAVE direct
##                                  edges: `isRootLockedDep` is what
##                                  `--direct` reads them from)
##       .repro/manifests/        — the TEAM backend (a git checkout)
##         repos/ws-root.toml     — depends = ["lib-a", "lib-b"]
##         repos/lib-a.toml       — depends = ["lib-c"]
##         repos/lib-{b,c,d}.toml — no depends
##         locks/mix/ws-root/<sha>.toml — pins all five
##       .git/repro/config.toml   — layer 5: team -> git-checkout
##
##   graph:  ws-root -> {lib-a, lib-b};  lib-a -> lib-c;  lib-d unreferenced
##
## Asserts:
##   1. `--direct`   selects exactly the root's edges: lib-a, lib-b;
##   2. `--indirect` selects exactly the complement: lib-c, lib-d — the first
##      time this flag has been shown to select ANYTHING;
##   3. `--transitive-of=lib-a` follows the edge to lib-c and includes the
##      named root itself; `--transitive-of=lib-b` and `=lib-d` are singletons;
##   4. `--direct` and `--indirect` PARTITION `--all`: disjoint, and their
##      union is the whole closure. That is the property that makes them a
##      pair rather than two independent filters;
##   5. the root repo itself is in NO mode's selection — it is the consumer.
##
## Falsifiability / pre-fix failure: against ``391a892a`` this test fails at
## (2), where `--indirect` is rejected outright:
##
##   repro develop: error: unsupported `repro develop --all` argument: --indirect
##
## Mutation check: implementing `--indirect` as "the closure minus the root"
## (forgetting to subtract the direct edges) fails (2) and (4); implementing
## `--direct` as "everything the lock names" fails (1) and (4);
## making `--transitive-of` exclude the named root fails (3).
##
## Mocks: NONE. Real git repositories on the real filesystem, a real manifest
## checkout, a real layer-5 config inside a real ``.git``, the real ``repro``
## binary, the real git-checkout lock backend.
##
## Hermetic: fresh tempdir; layers 2 and 3 are silenced via the
## ``REPROBUILD_*_CONFIG`` overrides. Skip: ``git`` missing or ``repro``
## unbuilt.

import std/[algorithm, os, osproc, strutils, tempfiles, unittest]

const reproBinary = "./build/bin/" & addFileExt("repro", ExeExt)

proc q(value: string): string = quoteShell(value)

proc run(command: string; cwd = ""): tuple[code: int; output: string] =
  let res = execCmdEx(command, workingDir = cwd)
  (code: res.exitCode, output: res.output)

proc requireGit(command: string; cwd = ""): string =
  let res = run(command, cwd)
  if res.code != 0:
    checkpoint("command failed: " & command & "\nexit=" & $res.code &
      "\n" & res.output)
    quit 1
  res.output

proc initGitRepo(gitBin, path: string) =
  createDir(path)
  discard requireGit(q(gitBin) & " init -b main " & q(path))
  discard requireGit(q(gitBin) & " -C " & q(path) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(path) &
    " config user.name \"DS7 Graph Tester\"")

proc seedGitOrigin(gitBin, originPath, workPath: string): string =
  discard requireGit(q(gitBin) & " init --bare -b main " & q(originPath))
  initGitRepo(gitBin, workPath)
  writeFile(workPath / "seed.txt", extractFilename(workPath) & "\n")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " add -A")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " commit -m seed")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " remote add origin " & q(originPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " push origin main")
  requireGit(q(gitBin) & " -C " & q(workPath) & " rev-parse HEAD").strip()

proc repoFragment(name, path, remote: string; depends: seq[string]): string =
  result = "schema = \"reprobuild.workspace.repo.v1\"\n\n" &
    "[repo]\n" &
    "name = \"" & name & "\"\n" &
    "path = \"" & path & "\"\n" &
    "remote = \"" & remote & "\"\n" &
    "revision = \"main\"\n"
  if depends.len > 0:
    result.add("depends = [\"" & depends.join("\", \"") & "\"]\n")

suite "DS-7: the dependency-edge modes over a real `depends` graph":

  test "t_develop_dependency_modes_walk_a_real_depends_graph":
    let gitBin = findExe("git")
    if gitBin.len == 0 or not fileExists(reproBinary):
      skip()
    else:
      let repro = absolutePath(reproBinary)
      let scratch = createTempDir("ds7-graph-", "")
      defer: removeDir(scratch)

      let libs = ["lib-a", "lib-b", "lib-c", "lib-d"]
      var shas: seq[string]
      for name in libs:
        shas.add(seedGitOrigin(gitBin, scratch / ("origin-" & name & ".git"),
          scratch / ("seed-" & name)))
      for s in shas: check s.len == 40

      let ws = scratch / "workspace"
      initGitRepo(gitBin, ws)
      let manifestsRoot = ws / ".repro" / "manifests"
      createDir(manifestsRoot / "projects")
      createDir(manifestsRoot / "repos")

      var remoteBlock = "[[remote]]\nname = \"root-origin\"\n" &
        "fetch = \"file://" & scratch / "origin-lib-a.git" & "\"\n\n"
      for name in libs:
        remoteBlock.add("[[remote]]\nname = \"" & name & "-origin\"\n" &
          "fetch = \"file://" & scratch / ("origin-" & name & ".git") &
          "\"\n\n")

      writeFile(manifestsRoot / "projects" / "mix.toml",
        "schema = \"reprobuild.workspace.project.v1\"\n\n" &
        "[project]\n" &
        "name = \"mix\"\n" &
        "default_revision = \"main\"\n" &
        "trunk = \"main\"\n\n" &
        remoteBlock &
        "includes = [\n  \"repos/ws-root.toml\",\n" &
        "  \"repos/lib-a.toml\",\n  \"repos/lib-b.toml\",\n" &
        "  \"repos/lib-c.toml\",\n  \"repos/lib-d.toml\",\n]\n")

      # THE GRAPH. Only a repo at path "." can carry the root's direct edges.
      writeFile(manifestsRoot / "repos" / "ws-root.toml",
        repoFragment("ws-root", ".", "root-origin", @["lib-a", "lib-b"]))
      writeFile(manifestsRoot / "repos" / "lib-a.toml",
        repoFragment("lib-a", "lib-a", "lib-a-origin", @["lib-c"]))
      for name in ["lib-b", "lib-c", "lib-d"]:
        writeFile(manifestsRoot / "repos" / (name & ".toml"),
          repoFragment(name, name, name & "-origin", @[]))

      initGitRepo(gitBin, manifestsRoot)
      discard requireGit(q(gitBin) & " -C " & q(manifestsRoot) & " add -A")
      discard requireGit(q(gitBin) & " -C " & q(manifestsRoot) &
        " commit -m manifests")

      for name in libs:
        discard requireGit(q(gitBin) & " clone " &
          q("file://" & scratch / ("origin-" & name & ".git")) & " " &
          q(ws / name))

      createDir(ws / ".repro")
      writeFile(ws / ".repro" / "workspace.toml",
        "schema = \"reprobuild.workspace.local.v1\"\n\n" &
        "[workspace]\n" &
        "project = \"mix\"\n" &
        "branch = \"main\"\n")
      writeFile(ws / ".repro-workspace.toml",
        "schema = \"reprobuild.workspace.bootstrap.v1\"\n\n" &
        "[manifest]\n" &
        "url = \"https://example.invalid/manifests.git\"\n")

      let layer5Dir = ws / ".git" / "repro"
      createDir(layer5Dir)
      writeFile(layer5Dir / "config.toml",
        "schema = \"reprobuild.config.v1\"\n\n" &
        "[locking]\n" &
        "route = [{ visibility = \"team\", backend = \"git-checkout\", " &
        "path = \".repro/manifests\", repos = [\"ws-root\", \"lib-a\", " &
        "\"lib-b\", \"lib-c\", \"lib-d\"] }]\n")

      writeFile(ws / ".gitignore",
        ".repro/\nlib-a/\nlib-b/\nlib-c/\nlib-d/\n")
      discard requireGit(q(gitBin) & " -C " & q(ws) & " add -A")
      discard requireGit(q(gitBin) & " -C " & q(ws) & " commit -m c1")
      let rootSha = requireGit(q(gitBin) & " -C " & q(ws) &
        " rev-parse HEAD").strip()
      check rootSha.len == 40

      # The commit-keyed record, pinning every repo in the graph.
      var record = "schema = \"reprobuild.workspace.lock.v1\"\n\n" &
        "[lock]\n" &
        "project = \"mix\"\n" &
        "created_at = \"2026-01-01T00:00:00Z\"\n" &
        "created_by = \"ds7 graph fixture\"\n\n" &
        "[[repo]]\nname = \"ws-root\"\npath = \".\"\n" &
        "remote = \"root-origin\"\nrevision = \"" & rootSha & "\"\n" &
        "branch = \"main\"\n"
      for i, name in libs:
        record.add("\n[[repo]]\nname = \"" & name & "\"\npath = \"" & name &
          "\"\nremote = \"" & name & "-origin\"\nrevision = \"" & shas[i] &
          "\"\nbranch = \"main\"\n")
      createDir(manifestsRoot / "locks" / "mix" / "ws-root")
      writeFile(manifestsRoot / "locks" / "mix" / "ws-root" /
        (rootSha & ".toml"), record)
      discard requireGit(q(gitBin) & " -C " & q(manifestsRoot) & " add -A")
      discard requireGit(q(gitBin) & " -C " & q(manifestsRoot) &
        " commit -m lock")

      putEnv("REPROBUILD_SYSTEM_CONFIG", scratch / "no-system.toml")
      putEnv("REPROBUILD_USER_CONFIG", scratch / "no-user.toml")
      defer:
        delEnv("REPROBUILD_SYSTEM_CONFIG")
        delEnv("REPROBUILD_USER_CONFIG")

      proc selected(flags: string): seq[string] =
        ## The repo names of a ``--list`` table. STDOUT only, so the notices
        ## the DS-5 test owns cannot interleave into the parse. A non-zero
        ## exit leaves the name list empty, so every assertion below fails
        ## with the command's own output on the checkpoint trail.
        let res = run(repro & " develop --list --tool-provisioning=path " &
          flags & " 2>/dev/null", cwd = ws)
        if res.code != 0:
          checkpoint("develop --list " & flags & " exited " & $res.code &
            ": " & res.output)
          return
        var inTable = false
        for line in res.output.splitLines():
          if line.startsWith("REPO "):
            inTable = true
            continue
          if not inTable: continue
          if line.startsWith("repro develop"): continue
          let name = line.split(' ')[0].strip()
          if name.len > 0: result.add(name)
        result.sort()

      let all = selected("--all")
      check all == @["lib-a", "lib-b", "lib-c", "lib-d"]

      # ---- (1) --direct: exactly the root repo's declared edges. ----------
      let direct = selected("--direct")
      check direct == @["lib-a", "lib-b"]

      # ---- (2) --indirect: exactly the complement. ------------------------
      # `lib-c` is reached only THROUGH lib-a; `lib-d` is reached by nothing.
      # Both are indirect; neither is a direct edge of the root.
      let indirect = selected("--indirect")
      check indirect == @["lib-c", "lib-d"]

      # ---- (3) --transitive-of follows the edges. -------------------------
      check selected("--transitive-of=lib-a") == @["lib-a", "lib-c"]
      check selected("--transitive-of=lib-b") == @["lib-b"]
      check selected("--transitive-of=lib-d") == @["lib-d"]

      # ---- (4) --direct and --indirect PARTITION --all. -------------------
      for n in direct: check n notin indirect
      var union = direct & indirect
      union.sort()
      check union == all

      # ---- (5) the root repo is in NO mode's selection. -------------------
      # It is the consumer the develop set is assembled FOR.
      for mode in ["--all", "--direct", "--indirect"]:
        check "ws-root" notin selected(mode)

      # ---- (6) …and NAMING it is a LOUD error, not a silent empty run. ----
      #
      # "``--only`` and ``--except`` name repos EXACTLY; a name matching
      # nothing is a loud error, never a silent no-op." The root repo IS in the
      # lock set, so the exact-name check against the lock set passes it — and
      # then the membership axis drops it, because the develop-manageable set
      # is the union "**minus** the workspace root repo itself … and **minus**
      # evidence-only repos" (CLI/develop.md §"Composing the lock set"). Both
      # exclusions must be equally loud; only the evidence-only one was.
      # Before the fix `--only=ws-root` exited 0 with "no dependency nodes
      # selected", which is indistinguishable from a workspace whose lock set
      # manages nothing.
      let namedRoot = run(repro &
        " develop --all --only=ws-root --tool-provisioning=path", cwd = ws)
      if namedRoot.code != 2:
        checkpoint("develop --only=ws-root output: " & namedRoot.output)
      check namedRoot.code == 2
      check "THIS WORKSPACE'S ROOT REPO" in namedRoot.output
      check "you are already standing in it" in namedRoot.output
      # The refusal mutated nothing.
      check not fileExists(ws / ".repro" / "develop-overrides.toml")

      # …and `--transitive-of` on the root is the same refusal, because it
      # names a repo exactly too.
      let transRoot = run(repro &
        " develop --transitive-of=ws-root --tool-provisioning=path", cwd = ws)
      check transRoot.code == 2
      check "THIS WORKSPACE'S ROOT REPO" in transRoot.output
