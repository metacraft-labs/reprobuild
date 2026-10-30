## Gate ``t_addon_secret_files_created_private_and_never_through_symlinks``
## (milestone A7; ReproOS Add-On Mode spec §10.3; threat model G18, G29,
## F3, T34).
##
## A secret file is created with its final mode at ``open(2)`` -- never
## written first and narrowed after -- and never written through a
## symbolic link.
##
## *The mode at creation*, under ``umask 022``: an inotify watcher thread
## (``IN_CREATE``, ``IN_ATTRIB``) on the service directory ``lstat``s every
## file the moment it is created and records its mode, and records every
## attribute change. Each secret is 4 MiB, so the write that follows the
## create takes long enough for the watcher to see the file while it is
## being written (a vacuity guard requires that it saw at least half of
## them). Green: every observed mode is ``0400`` and no secret file ever
## had an attribute change (a narrowing ``chmod`` is one).
##
## *Never through a link*: a symbolic link planted at a destination, at a
## secret's temporary name (``stagedSecretName``), or as the service
## directory is refused (``AddonSecretsFailed``), the link stays a link,
## and the file it points at is byte-identical afterwards.
##
## *Falsifying mutation*: ``-d:reproAddonMutation=secrets-write-then-narrow``
## writes the way the reused deploy agent wrote before it was fixed (a
## path-based write with the umask's mode, then a ``chmod``): the watcher
## sees ``0644`` files and attribute changes, and the link at the temporary
## name is followed. ``scripts/run_addon_unit_mutation.sh
## t_addon_secret_files_created_private_and_never_through_symlinks
## secrets-write-then-narrow`` runs it and expects red.
##
## *Mocking.* None: the production materialiser on real files; the
## required owner is the test's own uid and the tmpfs check is off (the
## scratch directory need not be a tmpfs; the VM gate checks that half).

import std/[os, posix, strutils, unittest]

import repro_infra/profile
import repro_deploy_agent/secrets

import repro_addon/addon_secrets

# --- inotify, straight from libc ---------------------------------------------

const
  InCreate = 0x00000100'u32
  InAttrib = 0x00000004'u32
  InOnlyDir = 0x01000000'u32

proc inotify_init1(flags: cint): cint {.importc, header: "<sys/inotify.h>".}
proc inotify_add_watch(fd: cint; path: cstring; mask: uint32): cint
  {.importc, header: "<sys/inotify.h>".}

type
  Observation = object
    name: string
    event: string        ## "create" or "attrib"
    mode: int            ## -1 when the file was already gone

  WatchArgs = object
    fd: cint
    dir: cstring

var observations: seq[Observation]
var obsLock: Pthread_mutex

proc watcher(a: WatchArgs) {.thread.} =
  ## Read inotify events until the sentinel file ``stop`` appears; for
  ## every created entry, ``lstat`` it at once and record its mode.
  var buf: array[65536, byte]
  let dir = $a.dir
  while true:
    let n = posix.read(a.fd, addr buf[0], buf.len)
    if n <= 0: break
    var off = 0
    var stop = false
    while off < n:
      let wd = cast[ptr int32](addr buf[off])[]
      discard wd
      let mask = cast[ptr uint32](addr buf[off + 4])[]
      let nameLen = int(cast[ptr uint32](addr buf[off + 12])[])
      var name = ""
      if nameLen > 0:
        name = $cast[cstring](addr buf[off + 16])
      off += 16 + nameLen
      if name == "stop":
        stop = true
        continue
      var o = Observation(name: name, mode: -1)
      if (mask and InCreate) != 0:
        o.event = "create"
        var st: Stat
        if lstat(cstring(dir & "/" & name), st) == 0:
          o.mode = int(st.st_mode) and 0o7777
      elif (mask and InAttrib) != 0:
        o.event = "attrib"
      else:
        continue
      discard pthread_mutex_lock(addr obsLock)
      {.cast(gcsafe).}:
        observations.add(o)
      discard pthread_mutex_unlock(addr obsLock)
    if stop: break

proc bigSecret(seed: int): seq[byte] =
  result = newSeq[byte](4 * 1024 * 1024)
  for i in 0 ..< result.len:
    result[i] = byte((i * 31 + seed * 7) and 0xff)

type Bed = object
  root: string
  layout: SecretsLayout
  outside: string

proc newBed(name: string): Bed =
  result.root = getTempDir() / ("repro-addon-secretfiles-" & name & "-" &
                                $getCurrentProcessId())
  removeDir(result.root)
  createDir(result.root)
  result.layout = SecretsLayout(agentDir: result.root / "agent",
    runDir: result.root / "run" / "secrets", owner: int(geteuid()),
    requireTmpfs: false)
  createDir(result.root / "run")
  result.outside = result.root / "outside"
  createDir(result.outside)

proc dirFor(b: Bed; svc: string): string = b.layout.runDir / svc

suite "t_addon_secret_files_created_private_and_never_through_symlinks":
  test "under umask 022 every secret file is 0400 at IN_CREATE and never narrowed":
    discard umask(Mode(0o022))
    let b = newBed("mode")
    defer: removeDir(b.root)
    # The directories exist first so the watcher can be on them before the
    # first file appears (the materialiser accepts our own 0700 directory).
    doAssert posix.mkdir(b.layout.runDir.cstring, Mode(0o700)) == 0
    doAssert posix.mkdir(b.dirFor("svc").cstring, Mode(0o700)) == 0
    let fd = inotify_init1(0)
    doAssert fd >= 0
    doAssert inotify_add_watch(fd, b.dirFor("svc").cstring,
                               InCreate or InAttrib or InOnlyDir) >= 0
    discard pthread_mutex_init(addr obsLock, nil)
    var th: Thread[WatchArgs]
    let dirC = b.dirFor("svc")
    createThread(th, watcher, WatchArgs(fd: fd, dir: dirC.cstring))
    const N = 12
    var decls: seq[SecretFileDecl]
    var files: seq[SecretFile]
    for i in 0 ..< N:
      decls.add(SecretFileDecl(service: "svc", name: "s" & $i))
      files.add(SecretFile(path: "svc/s" & $i, mode: 0o400,
                           content: bigSecret(i)))
    discard materialise(b.layout, decls, files)
    # A second materialisation with new contents rewrites every file.
    for i in 0 ..< N: files[i].content = bigSecret(i + 100)
    discard materialise(b.layout, decls, files)
    # Our own sentinel ends the watcher (it is not a secret).
    writeFile(b.dirFor("svc") / "stop", "")
    joinThread(th)
    discard posix.close(fd)
    var created, seen, wrong, attribs: seq[string]
    for o in observations:
      if o.name == "stop": continue
      if o.event == "create":
        created.add(o.name)
        if o.mode >= 0:
          seen.add(o.name)
          if o.mode != 0o400: wrong.add(o.name & "=" & toOct(o.mode, 4))
      elif o.event == "attrib":
        attribs.add(o.name)
    echo("  watcher: created " & $created.len & ", observed " & $seen.len &
      ", wrong " & $wrong & ", attribute changes " & $attribs)
    check created.len >= 2 * N        # every file, twice
    check seen.len * 2 >= created.len # vacuity guard: the watcher kept up
    check wrong.len == 0
    check attribs.len == 0
    for i in 0 ..< N:
      let p = b.dirFor("svc") / ("s" & $i)
      check (getFilePermissions(p) == {fpUserRead})
      var st: Stat
      doAssert lstat(p.cstring, st) == 0
      check (int(st.st_mode) and 0o7777) == 0o400

  test "a link at a destination is refused and its target is unchanged":
    let b = newBed("dest")
    defer: removeDir(b.root)
    writeFile(b.outside / "victim", "victim-bytes\n")
    doAssert posix.mkdir(b.layout.runDir.cstring, Mode(0o700)) == 0
    doAssert posix.mkdir(b.dirFor("svc").cstring, Mode(0o700)) == 0
    createSymlink(b.outside / "victim", b.dirFor("svc") / "token")
    expect AddonSecretsFailed:
      discard materialise(b.layout, [SecretFileDecl(service: "svc",
        name: "token")], [SecretFile(path: "svc/token", mode: 0o400,
        content: @[byte('x')])])
    check symlinkExists(b.dirFor("svc") / "token")
    check readFile(b.outside / "victim") == "victim-bytes\n"

  test "a link at a temporary name is refused and its target is unchanged":
    let b = newBed("staged")
    defer: removeDir(b.root)
    writeFile(b.outside / "victim", "victim-bytes\n")
    doAssert posix.mkdir(b.layout.runDir.cstring, Mode(0o700)) == 0
    doAssert posix.mkdir(b.dirFor("svc").cstring, Mode(0o700)) == 0
    let staged = b.dirFor("svc") / stagedSecretName("token")
    createSymlink(b.outside / "victim", staged)
    var refused = false
    try:
      discard materialise(b.layout, [SecretFileDecl(service: "svc",
        name: "token")], [SecretFile(path: "svc/token", mode: 0o400,
        content: @[byte('x')])])
    except AddonSecretsFailed:
      refused = true
    check refused
    check readFile(b.outside / "victim") == "victim-bytes\n"
    check getFilePermissions(b.outside / "victim") != {fpUserRead}

  test "a service directory that is a link is refused; nothing lands outside":
    let b = newBed("svcdir")
    defer: removeDir(b.root)
    doAssert posix.mkdir(b.layout.runDir.cstring, Mode(0o700)) == 0
    createSymlink(b.outside, b.dirFor("svc"))
    expect AddonSecretsFailed:
      discard materialise(b.layout, [SecretFileDecl(service: "svc",
        name: "token")], [SecretFile(path: "svc/token", mode: 0o400,
        content: @[byte('x')])])
    var inside: seq[string]
    for _, p in walkDir(b.outside): inside.add(p)
    check inside.len == 0

  test "positive control: secrets land 0400 in 0700 directories; undeclared ones go":
    discard umask(Mode(0o022))
    let b = newBed("ok")
    defer: removeDir(b.root)
    let changed = materialise(b.layout,
      [SecretFileDecl(service: "a", name: "k"),
       SecretFileDecl(service: "b", name: "k")],
      [SecretFile(path: "a/k", mode: 0o400, content: @[byte('1')]),
       SecretFile(path: "b/k", mode: 0o400, content: @[byte('2')]),
       SecretFile(path: "c/k", mode: 0o400, content: @[byte('3')])])
    check changed == @["a", "b"]
    check readFile(b.dirFor("a") / "k") == "1"
    check not dirExists(b.dirFor("c"))      # sealed, but not declared
    var st: Stat
    doAssert stat(b.layout.runDir.cstring, st) == 0
    check (int(st.st_mode) and 0o7777) == 0o700
    doAssert stat(b.dirFor("a").cstring, st) == 0
    check (int(st.st_mode) and 0o7777) == 0o700
    # A later generation that drops b: its directory goes.
    check materialise(b.layout, [SecretFileDecl(service: "a", name: "k")],
      [SecretFile(path: "a/k", mode: 0o400, content: @[byte('1')])]) == @["b"]
    check not dirExists(b.dirFor("b"))
