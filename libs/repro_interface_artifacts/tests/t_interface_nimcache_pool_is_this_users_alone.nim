## The interface extraction's shared nimcache pool holds code this user
## compiles and runs -- the generated extraction runner, its search-path
## script, and the objects linked into it -- so it is a backing store under
## reprobuild-pm `spec/Tool-Owned-Caches.md` §"Trust Boundary": it lives in
## this user's private state, a store found owned by another user or writable
## by group or others is refused (naming its path, owner and mode) and left as
## it is, and a file found under a runner's content-digest name is used only
## when it holds that content.
##
## reprobuild-pm issue 2026-11-18-interface-extraction-nimcache-pool-lives-in-
## the-shared-temporary-directory. The pool was first
## `getTempDir() / "repro-nimcache-interface"` -- `/tmp` on Linux -- and
## later moved to the user cache directory, but at no point was the owner or
## mode of any level checked, and a runner already present under its
## predictable name was compiled unread. Each case below is an attack another
## local user could mount on a pool, or on a directory above one, that they
## can write; before the fix each succeeded.
##
## The ancestor-configuration attack (a `config.nims` above the pool that the
## runner's compile would evaluate) needs a real extraction compile, and is in
## `tests/integration/t_compiler_scratch_isolation.nim`.
##
## MOCK POLICY - none. Real directories, real modes, real file locks and the
## production `acquireInterfaceNimcacheSlot` / `publishContentNamedFile`. The
## "another owner" case chowns a pool root when it runs as root; otherwise it
## offers the store check `/`, which is already another account's. A link
## owned by another account can only be made as root, so that case runs only
## there. The other mode and symlink cases need no privilege.

import std/[os, strutils, tempfiles, unittest]

import repro_interface_artifacts

when defined(posix):
  import std/posix

  proc modeOf(path: string): int =
    var st: Stat
    doAssert lstat(path.cstring, st) == 0, path
    int(st.st_mode) and 0o777

  proc setMode(path: string; mode: int) =
    doAssert chmod(path.cstring, Mode(mode)) == 0, path

  proc refusal(configDir: string): string =
    ## The message `acquireInterfaceNimcacheSlot` refuses with, or "" when it
    ## admitted the store (the slot is released again at once).
    try:
      var slot = acquireInterfaceNimcacheSlot(configDir, slotCount = 1)
      releaseInterfaceNimcacheSlot(slot)
      ""
    except OwnedDirectoryError as err:
      err.msg

suite "the interface nimcache pool is this user's alone":

  test "the pool is in the per-user cache directory, not the temporary one":
    let tmp = createTempDir("repro-ifpool-tmp-", "")
    let cache = createTempDir("repro-ifpool-cache-", "")
    defer:
      removeDir(tmp)
      removeDir(cache)
    let savedTmp = getEnv("TMPDIR")
    let savedCache = getEnv("XDG_CACHE_HOME")
    defer:
      if savedTmp.len > 0: putEnv("TMPDIR", savedTmp) else: delEnv("TMPDIR")
      if savedCache.len > 0: putEnv("XDG_CACHE_HOME", savedCache)
      else: delEnv("XDG_CACHE_HOME")
    putEnv("TMPDIR", tmp)
    putEnv("XDG_CACHE_HOME", cache)
    let root = interfaceExtractionNimcacheRoot()
    when defined(posix):
      check root == cache / "repro-nimcache-interface"
    check not root.startsWith(tmp)
    # Beside the provider's, as its doc comment says.
    check root.parentDir == providerCompileNimcacheRoot().parentDir
    check interfaceExtractionIgnoredInputPrefixes() == @[absolutePath(root)]

  when defined(posix):
    test "a store it creates is mode 0700 at every level":
      let base = createTempDir("repro-ifpool-", "")
      defer: removeDir(base)
      let root = base / "repro-nimcache-interface"
      let config = root / "config"
      check refusal(config) == ""
      check modeOf(root) == 0o700
      check modeOf(config) == 0o700
      check modeOf(config / "slot-0") == 0o700

    test "a pool root created under a permissive umask is still admitted":
      # The engine creates the pool root before the extraction's cache lookup
      # (`repro_cli_support`), then the extraction admits it. Created with a
      # umask-following `createDir`, a umask of 002 made it 0775 and every
      # extraction refused the root the engine had just made. The creator is
      # `ensureInterfaceNimcacheStoreDir`, which sets the mode exactly.
      let base = createTempDir("repro-ifpool-", "")
      defer: removeDir(base)
      let root = base / "repro-nimcache-interface"
      let previous = umask(Mode(0o002))
      try:
        ensureInterfaceNimcacheStoreDir(root)
        check modeOf(root) == 0o700
        check refusal(root / "config") == ""
        check modeOf(root / "config") == 0o700
      finally:
        discard umask(previous)

    test "a pool root another account can write is refused and left alone":
      let base = createTempDir("repro-ifpool-", "")
      defer: removeDir(base)
      let root = base / "repro-nimcache-interface"
      createDir(root)
      setMode(root, 0o777)
      let msg = refusal(root / "config")
      checkpoint(msg)
      check root in msg
      check "0777" in msg
      # Not repaired, and nothing created inside it.
      check modeOf(root) == 0o777
      check not dirExists(root / "config")

    test "a configuration directory or a slot another account can write is refused":
      let base = createTempDir("repro-ifpool-", "")
      defer: removeDir(base)
      let root = base / "repro-nimcache-interface"
      let config = root / "config"
      check refusal(config) == ""
      setMode(config, 0o775)
      let configMsg = refusal(config)
      checkpoint(configMsg)
      check config in configMsg and "0775" in configMsg
      setMode(config, 0o700)
      let slot = config / "slot-0"
      setMode(slot, 0o777)
      let slotMsg = refusal(config)
      checkpoint(slotMsg)
      check slot in slotMsg and "0777" in slotMsg
      check modeOf(slot) == 0o777
      # The refused slot's lock was released: once the slot is fixed, the
      # next extraction takes slot 0 at once (`slotCount = 1` would otherwise
      # wait forever).
      setMode(slot, 0o700)
      check refusal(config) == ""

    test "a slot replaced by a symbolic link is refused":
      let base = createTempDir("repro-ifpool-", "")
      defer: removeDir(base)
      let config = base / "repro-nimcache-interface" / "config"
      check refusal(config) == ""
      let elsewhere = base / "attacker-owned"
      createDir(elsewhere)
      removeDir(config / "slot-0")
      createSymlink(elsewhere, config / "slot-0")
      let msg = refusal(config)
      checkpoint(msg)
      check (config / "slot-0") in msg and "not a directory" in msg

    test "a pool root owned by another account is refused":
      if geteuid() != 0:
        # Without the privilege to chown, use a directory that already
        # belongs to another account: `/` is root's.
        var msg = ""
        try:
          ensureInterfaceNimcacheStoreDir("/")
        except OwnedDirectoryError as err:
          msg = err.msg
        checkpoint(msg)
        # The owner `/` shows depends on the user namespace (root, or the
        # overflow uid in a sandbox); what matters is that it is not this
        # user.
        check "/" in msg and "not by this user" in msg
      else:
        let base = createTempDir("repro-ifpool-", "")
        defer: removeDir(base)
        let root = base / "repro-nimcache-interface"
        createDir(root)
        setMode(root, 0o755)
        const Nobody = 65534
        doAssert chown(root.cstring, Uid(Nobody), Gid(Nobody)) == 0
        let msg = refusal(root / "config")
        checkpoint(msg)
        check root in msg and ("uid " & $Nobody) in msg
        check not dirExists(root / "config")

  when defined(posix):
    test "a pool whose parent another account can write is refused":
      # The root itself passes its own check; the parent would let another
      # account rename it aside and substitute its own.
      let base = createTempDir("repro-ifpool-", "")
      defer: removeDir(base)
      let parent = base / "cache-home"
      createDir(parent)
      setMode(parent, 0o777)
      let msg = refusal(parent / "repro-nimcache-interface" / "config")
      checkpoint(msg)
      check parent in msg and "0777" in msg
      check not dirExists(parent / "repro-nimcache-interface" / "config")
      # Sticky, as `/tmp` is: only an entry's owner can rename it.
      setMode(parent, 0o1777)
      check refusal(parent / "repro-nimcache-interface" / "config") == ""

    test "a writable directory further up, reached through a link, is refused":
      # Not only the immediate parent: whoever can write ANY directory on the
      # way to the pool can rename the path aside below it. And a symbolic
      # link is followed to where it leads, which is walked the same way.
      let base = createTempDir("repro-ifpool-", "")
      defer: removeDir(base)
      let shared = base / "shared"
      let parent = shared / "private" / "cache-home"
      createDir(parent)
      setMode(shared / "private", 0o700)
      setMode(parent, 0o700)
      setMode(shared, 0o777)
      let msg = refusal(parent / "repro-nimcache-interface" / "config")
      checkpoint(msg)
      check shared in msg and "0777" in msg
      check not dirExists(parent / "repro-nimcache-interface")
      # The same tree reached through a link this user owns, in a directory
      # only this user can write: the walk follows it into `shared`.
      createSymlink(parent, base / "link")
      let viaLink = refusal(base / "link" / "repro-nimcache-interface" /
        "config")
      checkpoint(viaLink)
      check shared in viaLink and "0777" in viaLink
      # Sticky, as `/tmp` is: admitted, through the link too.
      setMode(shared, 0o1777)
      check refusal(base / "link" / "repro-nimcache-interface" /
        "config") == ""

    if geteuid() == 0:
      test "a symbolic link another account owns on the way is refused":
        # An `XDG_CACHE_HOME=/tmp/<name>` that another user created first,
        # as a link to a directory of this user's: every directory passes,
        # and they could repoint the link once the pool was admitted.
        let base = createTempDir("repro-ifpool-", "")
        defer: removeDir(base)
        setMode(base, 0o1777)
        let target = base / "mine"
        createDir(target)
        setMode(target, 0o700)
        let link = base / "theirs"
        createSymlink(target, link)
        const Nobody = 65534
        doAssert lchown(link.cstring, Uid(Nobody), Gid(Nobody)) == 0
        let msg = refusal(link / "cache" / "repro-nimcache-interface" /
          "config")
        checkpoint(msg)
        check link in msg and "symbolic link" in msg
        check not dirExists(target / "cache" / "repro-nimcache-interface")

    test "a missing parent is created private whatever the umask":
      # Under the 002 umask of a per-user-group distribution, a umask-
      # following `createDir` made a fresh `~/.cache` 0775.
      let base = createTempDir("repro-ifpool-", "")
      defer: removeDir(base)
      let parent = base / "fresh" / "cache-home"
      let previous = umask(Mode(0o002))
      try:
        check refusal(parent / "repro-nimcache-interface" / "config") == ""
      finally:
        discard umask(previous)
      check modeOf(base / "fresh") == 0o700
      check modeOf(parent) == 0o700

    test "a parent writable by this user's own private group is admitted":
      # A `~/.cache` made 0775 under a per-user-group umask is writable by
      # this user alone when its group is the user's private group
      # (login.defs(5) USERGROUPS_ENAB). A shared group is another matter.
      let base = createTempDir("repro-ifpool-", "")
      defer: removeDir(base)
      let parent = base / "cache-home"
      createDir(parent)
      let pw = getpwuid(geteuid())
      doAssert pw != nil
      doAssert chown(parent.cstring, Uid(geteuid()), pw.pw_gid) == 0
      setMode(parent, 0o775)
      let gr = getgrgid(pw.pw_gid)
      let privateGroup = gr != nil and $gr.gr_name == $pw.pw_name
      let msg = refusal(parent / "repro-nimcache-interface" / "config")
      checkpoint(msg)
      if privateGroup:
        check msg == ""
      else:
        check parent in msg and "0775" in msg

    test "a relative XDG_CACHE_HOME is ignored":
      let saved = getEnv("XDG_CACHE_HOME")
      defer:
        if saved.len > 0: putEnv("XDG_CACHE_HOME", saved)
        else: delEnv("XDG_CACHE_HOME")
      putEnv("XDG_CACHE_HOME", "relative-cache")
      when defined(macosx):
        check interfaceExtractionNimcacheRoot() ==
          absolutePath(getHomeDir() / "Library" / "Caches") /
          "repro-nimcache-interface"
      else:
        check interfaceExtractionNimcacheRoot() ==
          absolutePath(getHomeDir() / ".cache") / "repro-nimcache-interface"

  test "a planted file under a runner's digest name is refused, not run":
    let dir = createTempDir("repro-ifpool-publish-", "")
    defer: removeDir(dir)
    let runner = dir / "extract_runner_0123456789abcdef.nim"
    const Honest = "echo \"the runner this extraction generated\"\n"
    # Absent: published.
    publishContentNamedFile(runner, Honest)
    check readFile(runner) == Honest
    # Present with the same bytes: used as is.
    publishContentNamedFile(runner, Honest)
    check readFile(runner) == Honest
    # Present with other bytes under the same name: refused and left alone.
    const Planted = "static: discard staticExec(\"touch /tmp/pwned\")\n"
    writeFile(runner, Planted)
    var refused = ""
    try:
      publishContentNamedFile(runner, Honest)
    except IOError as err:
      refused = err.msg
    checkpoint(refused)
    check runner in refused
    check readFile(runner) == Planted
