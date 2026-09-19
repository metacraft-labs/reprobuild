## Where a released secret lands, and the rule that it never lands
## anywhere else.
##
## ## The one property this module exists for
##
## A secret released to an attested machine is released to *that boot*.
## It is bound to evidence about a running configuration, and the whole
## protocol says so: a rebooted machine is a re-measured machine and must
## re-attest to be re-provisioned. If the secret survives the reboot on a
## disk, none of that is true — the binding becomes a formality and the
## machine's storage becomes the real credential.
##
## So this module writes to a **volatile filesystem or to nothing**. The
## check is a ``statfs`` against the filesystem's own magic number, it
## runs at start-up *and* again immediately before every write, and a
## directory that fails it produces a refusal rather than a file. Two
## checks rather than one because they answer different questions: the
## start-up check stops a daemon coming up misconfigured, and the
## per-write check stops a directory that *was* a tmpfs from becoming
## something else while the daemon runs. Mounting over a path is not an
## exotic attack; it is one command.
##
## ## Why a magic number and not a mount table
##
## ``/proc/self/mountinfo`` describes mounts, and the path a file is
## written through does not have to correspond to the entry a reader
## would pick out of it — bind mounts, mount namespaces and a mount that
## lands between the read and the write all break the correspondence.
## ``statfs`` answers the question about *this path, now*, which is the
## question. The two magic numbers accepted are ``tmpfs`` and ``ramfs``:
## both hold their contents in the page cache and neither has a backing
## store. Everything else, including every filesystem this build has
## never heard of, is refused — a new filesystem is not assumed volatile
## because nobody here has met it.
##
## ``tmpfs`` can be swapped. A deployment that swaps is a deployment that
## writes memory to a disk, and this module cannot see that; it is stated
## in the operator documentation and is the reason attested images
## encrypt swap.
##
## ## The other two rules
##
## ``O_NOFOLLOW`` on the final component. The name comes off the wire and
## the directory is writable by the daemon, so without it a symbolic link
## planted in the runtime directory would turn a tmpfs write into a write
## wherever the link points — which is precisely the property above,
## defeated through the one path the check does not cover.
##
## ``0600``, and a directory that is not group- or world-writable. A
## secret readable by another local account is a secret released to
## another local account.
##
## ## Mocking
##
## None. The filesystem is the filesystem: the gates point this at a real
## tmpfs and at a real disk-backed directory and read what happens.

import std/[os, posix, strutils]

import repro_attest

const
  TmpfsMagic* = 0x01021994'i64
    ## ``TMPFS_MAGIC`` from the kernel's ``include/uapi/linux/magic.h``.

  RamfsMagic* = 0x858458F6'i64
    ## ``RAMFS_MAGIC``. Distinct filesystem, same property: no backing
    ## store.

  VolatileFilesystemMagics*: array[2, int64] = [TmpfsMagic, RamfsMagic]
    ## The whole accept list, indexed by ``isVolatileFilesystem`` below
    ## rather than restated there. A magic that is not in this array is
    ## refused, so extending the list is a visible edit in one place.

  SecretFileMode* = 0o600
  DirectoryForbiddenMode* = 0o022
    ## Group-write and other-write. A runtime directory carrying either
    ## is refused.

# `O_NOFOLLOW` is the flag that stops the whole volatile-filesystem
# argument being defeated through a symbolic link, and `std/posix` does
# not expose it. It is taken from the header rather than written as a
# number, because the value differs between architectures.
when defined(linux):
  var O_NOFOLLOW_C {.importc: "O_NOFOLLOW", header: "<fcntl.h>".}: cint
else:
  var O_NOFOLLOW_C: cint = 0

type
  SecretStoreError* = object of CatchableError
    ## Every refusal here. Each message has exactly one producing site.

  ProvisionedSecretStore* = ref object
    ## A directory on a volatile filesystem, plus the rules for writing
    ## into it.
    dir: string

# ---------------------------------------------------------------------
# The filesystem question
# ---------------------------------------------------------------------

when defined(linux):
  type
    StatfsBuf {.importc: "struct statfs", header: "<sys/vfs.h>".} = object
      f_type {.importc: "f_type".}: clong

  proc c_statfs(path: cstring; buf: var StatfsBuf): cint
    {.importc: "statfs", header: "<sys/vfs.h>".}

proc filesystemMagic*(path: string): int64 =
  ## The magic number of the filesystem ``path`` is on.
  ##
  ## Separate from the decision below so the syscall and the policy can
  ## be read, and falsified, apart.
  when defined(linux):
    var buf: StatfsBuf
    if c_statfs(path.cstring, buf) != 0:
      raiseOSError(osLastError(),
        "statfs(" & path & ") — this build has to know which filesystem " &
        "a released secret would land on before it writes one")
    int64(buf.f_type)
  else:
    raise newException(SecretStoreError,
      "this build cannot establish which filesystem " & path.escape() &
      " is on, and it will not write a released secret to storage it " &
      "cannot classify")

proc isVolatileFilesystem*(magic: int64): bool =
  ## Whether a filesystem with this magic number keeps its contents in
  ## memory and has no backing store.
  ##
  ## Pure, and exported, so the accept list can be gated by value on
  ## both sides — the two magics that pass and a neighbour of each that
  ## does not — without needing a machine that has those filesystems
  ## mounted.
  for m in VolatileFilesystemMagics:
    if m == magic: return true
  false

proc magicHex(magic: int64): string =
  "0x" & toHex(magic, 8).toLowerAscii

proc requireVolatileDirectory(dir: string; whenDescription: string) =
  ## The check, phrased so the message says *when* it ran. A start-up
  ## refusal and a write-time refusal are different operational
  ## situations and an operator reading one line has to be able to tell
  ## which happened.
  if not dirExists(dir):
    raise newException(SecretStoreError,
      "the provisioned-secrets directory " & dir.escape() &
      " does not exist (" & whenDescription & ")")
  let magic = filesystemMagic(dir)
  if not isVolatileFilesystem(magic):
    raise newException(SecretStoreError,
      "the provisioned-secrets directory " & dir.escape() &
      " is on a filesystem with magic " & magicHex(magic) &
      ", which is not one that keeps its contents in memory (" &
      whenDescription & "); a secret released to one boot must not " &
      "survive it, so this build writes no secret rather than writing " &
      "one to storage")

proc requireTightPermissions(dir: string) =
  var st: Stat
  if stat(dir.cstring, st) != 0:
    raiseOSError(osLastError(),
      "stat(" & dir & ") — the provisioned-secrets directory's mode " &
      "decides who else on this machine holds the secret")
  let mode = int(st.st_mode) and 0o777
  if (mode and DirectoryForbiddenMode) != 0:
    raise newException(SecretStoreError,
      "the provisioned-secrets directory " & dir.escape() & " is mode 0" &
      toOct(mode, 3) & "; a secret another local account can write beside " &
      "or read out of is a secret released to that account")

# ---------------------------------------------------------------------
# The store
# ---------------------------------------------------------------------

proc newProvisionedSecretStore*(dir: string): ProvisionedSecretStore =
  ## Everything that can be wrong with the directory is wrong here,
  ## before the daemon binds a socket — the same discipline the agent's
  ## own constructor follows.
  if dir.len == 0:
    raise newException(SecretStoreError,
      "a provisioned-secrets directory was not configured; this build " &
      "will not choose a default, because the default would be wrong on " &
      "exactly the deployments that matter")
  if not dir.isAbsolute:
    raise newException(SecretStoreError,
      "the provisioned-secrets directory " & dir.escape() &
      " is relative; a daemon's working directory is not a place to put " &
      "a secret")
  requireVolatileDirectory(dir, "checked when the agent started")
  requireTightPermissions(dir)
  ProvisionedSecretStore(dir: dir)

proc directory*(s: ProvisionedSecretStore): string = s.dir

proc secretPath*(s: ProvisionedSecretStore; name: string): string =
  ## Where a secret of this name would be written. Validates the name,
  ## so there is no spelling of this call that produces a path outside
  ## the directory.
  validateSecretName(name)
  s.dir / name

proc storeSecret*(s: ProvisionedSecretStore; name, secret: string): string =
  ## Write a released secret and return the path it landed at.
  ##
  ## Re-checks the filesystem first. See the module header: the
  ## start-up check and this one answer different questions.
  let path = s.secretPath(name)
  requireVolatileDirectory(s.dir, "re-checked before writing a secret")

  let fd = posix.open(path.cstring,
    O_WRONLY or O_CREAT or O_TRUNC or O_NOFOLLOW_C or O_CLOEXEC,
    Mode(SecretFileMode))
  if fd < 0:
    let err = osLastError()
    if int(err) == int(ELOOP):
      raise newException(SecretStoreError,
        "the provisioned-secrets path " & path.escape() &
        " is a symbolic link; a released secret is written to the " &
        "directory this build checked, never through a link out of it")
    raiseOSError(err, "opening " & path & " for a released secret")
  try:
    # `chmod` after the fact, because the process umask subtracts from
    # the mode `open` was given and a umask is not this module's to
    # assume. The file is created before it is written, so there is no
    # window in which it holds the secret under a looser mode.
    #
    # Through the DESCRIPTOR, not the path. `O_NOFOLLOW` above establishes
    # that what was opened is not a link; a second lookup by name would
    # throw that away and re-open the question, because `chmod(2)`
    # follows links and the name could have become one in between. The
    # threat model that makes `O_NOFOLLOW` necessary — something plants a
    # link in the directory this daemon writes to — is the same one that
    # makes a path-based `chmod` a hole, so both answers come from the
    # one descriptor.
    when defined(posix):
      if fchmod(fd, Mode(SecretFileMode)) != 0:
        raiseOSError(osLastError(), "fchmod " & path)
    var written = 0
    while written < secret.len:
      let n = posix.write(fd, addr secret[written], secret.len - written)
      if n <= 0:
        raiseOSError(osLastError(), "writing " & path)
      written += n
  finally:
    discard posix.close(fd)
  path
