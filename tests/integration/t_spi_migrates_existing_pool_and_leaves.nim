## ``repro workspace shared-clones migrate`` brings a machine's existing pools
## and checkouts to the Shared-Clone-Pool-Integrity configuration in one pass.
##
## Spec: ``reprobuild-specs/spec/Shared-Clone-Pool-Integrity.md`` §5 (and the
## §3.1–§3.5 state it converges to); milestone SPI-4.
##
## Design. The built ``repro`` against real repositories: an upstream bare
## repository, two sibling workspaces (``ws`` and ``ws2``) made by
## ``repro workspace init`` that both borrow from ONE pool, and a second pool
## that nothing borrows from. Every pool and checkout is then put back into
## the configuration reprobuild wrote before this mechanism existed — no
## ``repro/`` directory in the pool, no retention hook, ``gc.pruneExpire=never``,
## no partial-clone keys, and no ``repro-pool`` remote or ``fetch.hideRefs`` in
## the checkouts — which is the state every user's cache is in today. Upstream
## also deletes and purges a branch the checkouts still track, and the pool is
## made to lose it (its packs rebuilt from ``rev-list --objects --all``), so
## both checkouts hold a dangling remote-tracking ref.
##
## One ``migrate`` run from ``ws`` must then:
##
##   - give the shared pool §3.1–§3.3: the hook, the partial-clone keys, and
##     ``gc.pruneExpire=2.weeks.ago`` — because its registry now holds BOTH
##     checkouts, including the one in the sibling workspace it was not run
##     from;
##   - leave the unborrowed pool at ``gc.pruneExpire=never``: a pool must not
##     expire objects on the strength of an empty registry;
##   - give both checkouts the ``repro-pool`` remote and ``fetch.hideRefs``,
##     and never ``extensions.partialClone`` (it makes a checkout unreadable
##     to Nix's libgit2; see t_spi_leaf_refetches_through_pool);
##   - remove both dangling refs, printing message A for each.
##
## No mocks. Hermetic: one ``createTempDir`` root, a private
## ``GIT_CONFIG_GLOBAL``, ``REPRO_WORKSPACE_CLONES`` in the temp root, and
## ``file://`` URLs. Skip rule: ``git`` missing on PATH; needs the built
## ``repro``.

import std/[os, osproc, strutils, tempfiles, unittest]
import repro_test_support/reasoned_skip

import repro_test_support
import shared_clones

proc q(value: string): string = quoteShell(value)

proc gitIn(cwd: string; args: varargs[string]): tuple[code: int;
                                                      output: string] =
  var cmd = "GIT_NO_LAZY_FETCH=1 git -C " & q(cwd)
  for a in args:
    cmd.add(" " & q(a))
  let res = execCmdEx(cmd)
  (code: res.exitCode, output: res.output.strip())

proc must(cwd: string; args: varargs[string]): string =
  let res = gitIn(cwd, args)
  if res.code != 0:
    checkpoint("git " & args.join(" ") & " in " & cwd & " failed: " &
      res.output)
  doAssert res.code == 0, "fixture git command failed: " & args.join(" ")
  res.output

proc commitFile(work, name, body: string) =
  writeFile(work / name, body)
  discard must(work, "add", name)
  discard must(work, "commit", "-q", "-m", name)

proc has(repo, id: string): bool =
  gitIn(repo, "cat-file", "-e", id).code == 0

proc cfg(repo, key: string): string =
  let res = gitIn(repo, "config", "--get-all", key)
  if res.code == 0: res.output else: ""

proc erasePoolUnreachable(pool: string) =
  let objects = must(pool, "rev-list", "--objects", "--all")
  var ids = ""
  for line in objects.splitLines():
    let id = line.split(' ')[0].strip()
    if id.len > 0: ids.add(id & "\n")
  let packDir = pool / "objects" / "pack"
  let packed = execCmdEx("GIT_NO_LAZY_FETCH=1 git -C " & q(pool) &
    " pack-objects -q " & q(packDir / "fresh"), input = ids)
  doAssert packed.exitCode == 0, packed.output
  let keep = "fresh-" & packed.output.strip()
  for kind, f in walkDir(packDir):
    if not f.lastPathPart.startsWith(keep):
      removeFile(f)
  for kind, d in walkDir(pool / "objects"):
    if kind == pcDir and d.lastPathPart.len == 2:
      removeDir(d)

proc unsetAll(repo: string; keys: openArray[string]) =
  for key in keys:
    discard gitIn(repo, "config", "--unset-all", key)

proc revertPool(pool: string) =
  ## The pool as reprobuild left it before Shared-Clone-Pool-Integrity.
  removeDir(pool / "repro")
  unsetAll(pool, ["gc.recentObjectsHook", "extensions.partialClone",
    "remote.origin.promisor"])
  discard must(pool, "config", "core.repositoryFormatVersion", "0")
  discard must(pool, "config", "gc.pruneExpire", "never")

proc revertLeaf(leaf: string) =
  discard gitIn(leaf, "remote", "remove", "repro-pool")
  unsetAll(leaf, ["fetch.hideRefs"])

proc repoRoot(): string =
  currentSourcePath().parentDir.parentDir.parentDir

proc projectToml(name, libUrl: string): string =
  "schema = \"reprobuild.workspace.project.v1\"\n\n" &
  "[project]\n" &
  "name = \"" & name & "\"\n" &
  "default_revision = \"main\"\n" &
  "trunk = \"main\"\n\n" &
  "[[remote]]\nname = \"lib-origin\"\nfetch = \"" & libUrl & "\"\n\n" &
  "includes = [\n  \"repos/lib.toml\",\n]\n"

const libFragmentToml = """
schema = "reprobuild.workspace.repo.v1"

[repo]
name = "lib"
path = "lib"
remote = "lib-origin"
revision = "main"
"""

const GlobalConfig = """
[user]
  name = SPI Tester
  email = tester@example.invalid
[init]
  defaultBranch = main
"""

proc seedOrigin(root, name: string; branches: openArray[string]): string =
  result = root / (name & ".git")
  let work = root / ("seed-" & name)
  discard must(root, "init", "-q", "--bare", result)
  createDir(work)
  discard must(work, "init", "-q")
  commitFile(work, "a", name & "\n")
  discard must(work, "remote", "add", "origin", result)
  discard must(work, "push", "-q", "origin", "main")
  for br in branches:
    discard must(work, "checkout", "-q", "-b", br, "main")
    commitFile(work, br, br & "\n")
    discard must(work, "push", "-q", "origin", br)

suite "SPI-4: migration of existing pools and leaves":

  test "migrate_converges_pools_and_leaves_and_repairs_dangling_refs":
    if findExe("git").len == 0:
      skip("needs git on PATH")
    else:
      let reproBin = requireBinary(repoRoot() / "build" / "bin" /
        addFileExt("repro", ExeExt), "reprobuild.apps.repro")
      let root = createTempDir("repro-spi4-", "")
      defer:
        delEnv("GIT_CONFIG_GLOBAL")
        delEnv("GIT_CONFIG_NOSYSTEM")
        removeDir(root)
      writeFile(root / "gitconfig", GlobalConfig)
      putEnv("GIT_CONFIG_GLOBAL", root / "gitconfig")
      putEnv("GIT_CONFIG_NOSYSTEM", "1")
      let gitBin = findExe("git")
      let cache = root / "cache"
      let env = @[("REPRO_WORKSPACE_CLONES", cache)]
      let origin = seedOrigin(root, "lib", ["f1"])
      # Two sibling workspaces borrowing from one pool.
      var leaves: seq[string]
      for wsName in ["ws", "ws2"]:
        let ws = root / wsName
        createDir(ws / "projects")
        createDir(ws / "repos")
        writeFile(ws / "projects" / "spiproj.toml",
          projectToml("spiproj", fileUrl(origin)))
        writeFile(ws / "repos" / "lib.toml", libFragmentToml)
        let init = runShell(shellCommand(@[reproBin, "workspace", "init",
          "spiproj", "--workspace-root=" & ws], env))
        checkpoint(wsName & " init: " & init.output)
        check init.code == 0
        leaves.add(ws / "lib")
      let pool = sharedBarePath(cache, fileUrl(origin))
      check dirExists(pool / "objects")
      # A second pool that nothing borrows from.
      let lonelyOrigin = seedOrigin(root, "lonely", [])
      let lonely = refreshSharedBare(gitBin, cache, fileUrl(lonelyOrigin))
      check lonely.ok

      # Today's configuration, everywhere.
      revertPool(pool)
      revertPool(lonely.sharedBarePath)
      for leaf in leaves:
        revertLeaf(leaf)
        doAssert gitIn(leaf, "rev-parse", "-q", "--verify",
          "refs/remotes/origin/f1").code == 0
      # Upstream deletes and purges f1; the pool loses it.
      let f1 = must(leaves[0], "rev-parse", "refs/remotes/origin/f1")
      discard must(origin, "update-ref", "-d", "refs/heads/f1")
      discard must(origin, "reflog", "expire", "--expire=now", "--all")
      discard must(origin, "gc", "-q", "--prune=now")
      discard must(pool, "update-ref", "-d", "refs/heads/f1")
      erasePoolUnreachable(pool)
      doAssert not has(leaves[0], f1)

      let migrated = runShell(shellCommand(@[reproBin, "workspace",
        "shared-clones", "migrate", "spiproj", "--workspace-root=" & root / "ws"],
        env))
      checkpoint("migrate: " & migrated.output)
      check migrated.code == 0

      # The shared pool: §3.1–§3.3, and the expiry window, because both
      # leaves are now registered.
      check fileExists(retentionHookPath(pool))
      check cfg(pool, "gc.recentObjectsHook") == retentionHookConfigValue(pool)
      check cfg(pool, "extensions.partialClone") == "origin"
      check cfg(pool, "remote.origin.promisor") == "true"
      check cfg(pool, "core.repositoryFormatVersion") == "1"
      check cfg(pool, "remote.origin.fetch") == SharedBareFetchRefspec
      for (key, value) in SharedBareSafetyConfig:
        check cfg(pool, key) == value
      check cfg(pool, "gc.pruneExpire") == PoolPruneExpire
      let registered = readBorrowers(pool)
      check registered.len == 2
      for leaf in leaves:
        check leaf in registered
      check ("pool " & pool & " gc.pruneExpire=2.weeks.ago borrowers=2") in
        migrated.output
      # The unborrowed pool: hook in place, but never expires.
      check fileExists(retentionHookPath(lonely.sharedBarePath))
      check cfg(lonely.sharedBarePath, "gc.pruneExpire") == PoolNeverExpire
      # Both leaves: §3.4 (less the format extension) and §3.5, and repaired.
      for leaf in leaves:
        check cfg(leaf, "remote.repro-pool.url") == poolFileUrl(pool)
        check cfg(leaf, "remote.repro-pool.promisor") == "true"
        check cfg(leaf, "remote.repro-pool.uploadpack") == LeafPoolUploadPack
        check cfg(leaf, "fetch.hideRefs") == LeafHiddenFetchRefs
        check cfg(leaf, "extensions.partialClone") == ""
        check gitIn(leaf, "rev-parse", "-q", "--verify",
          "refs/remotes/origin/f1").code != 0
        check ("repro: " & leaf & ": removed refs/remotes/origin/f1 (" &
          f1[0 ..< 7] & ")") in migrated.output
        check fileExists(leaf / ".git" / "repro" / "dropped-refs.log")
