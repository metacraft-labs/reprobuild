## Read-only access to pacman's local package database on an Arch-family
## base (Arch Linux, Omarchy): what the collision observer, the preflight,
## the base identity and the fingerprint read on Arch where they read dpkg's
## records on Debian (spec ReproOS-Add-On-Mode §4.3.1, §6.1, §12.2).
##
## The database is ``/var/lib/pacman/local``: an ``ALPM_DB_VERSION`` file and
## one directory per installed package, ``<name>-<version>``, holding a
## ``desc`` entry (``%NAME%``, ``%VERSION%``, ``%ARCH%``, ...) and a
## ``files`` entry (``%FILES%``, the paths the package installed, relative
## to pacman's root, directories with a trailing ``/``; ``%BACKUP%``, its
## backup files with their packaged MD5s). Each entry is a sequence of
## ``%SECTION%`` blocks, one value per line, ended by a blank line.
## https://man.archlinux.org/man/alpm-db.7
##
## Everything here only reads files: nothing runs ``pacman`` (which would
## take its database lock), so the readers are safe in the zero-write
## preflight. ``root`` relocates the database for the unit tests' fixture
## trees.

import std/[algorithm, os, strutils, tables]

import repro_infra/host_base

const
  PacmanLocalDir* = "/var/lib/pacman/local"
    ## The local database directory.
  PacmanDbVersionFile* = "ALPM_DB_VERSION"
    ## Written by pacman into ``PacmanLocalDir``; its absence means the
    ## directory is not (or not yet) a pacman database.

type
  PacmanPackage* = object
    ## One installed package as its ``desc`` entry states it.
    name*: string
    version*: string        ## ``%VERSION%``: ``[epoch:]pkgver-pkgrel``
    architecture*: string   ## ``%ARCH%``
    dir*: string            ## its database directory (absolute)

proc pacmanSections*(text: string): Table[string, seq[string]] =
  ## The ``%SECTION%`` blocks of a ``desc`` or ``files`` entry. Lines are
  ## kept as written; a section with no value lines maps to ``@[]``.
  var cur = ""
  for line in text.splitLines():
    if line.len > 2 and line[0] == '%' and line[^1] == '%':
      cur = line[1 ..< line.len - 1]
      discard result.hasKeyOrPut(cur, @[])
    elif line.len == 0:
      cur = ""
    elif cur.len > 0:
      result[cur].add(line)

proc firstValue(s: Table[string, seq[string]]; key: string): string =
  let v = s.getOrDefault(key)
  if v.len > 0: v[0].strip() else: ""

proc pacmanFilesPaths*(filesEntry: string): seq[string] =
  ## The paths of a ``files`` entry's ``%FILES%`` section (the
  ## ``pacman -Qo`` semantics), as ``/``-rooted paths without a directory's
  ## trailing ``/``, so they compare with a target path's text. Lines that
  ## are already absolute are not pacman's and are skipped.
  for p in pacmanSections(filesEntry).getOrDefault("FILES"):
    var q = p
    while q.len > 1 and q[^1] == '/': q.setLen(q.len - 1)
    if q.len > 0 and q[0] != '/': result.add("/" & q)

type
  PacmanBackupFile* = object
    ## One line of a ``files`` entry's ``%BACKUP%`` section: a backup file
    ## (pacman's counterpart of a dpkg conffile) and the MD5 the local
    ## database holds for it, which is the packaged version's: libalpm
    ## records the new package's hash whether it extracted the file or kept
    ## a locally changed one (and wrote ``<path>.pacnew``). Spec
    ## ReproOS-Add-On-Mode §4.3.1; https://man.archlinux.org/man/alpm-db.7
    ## and https://wiki.archlinux.org/title/Pacman/Pacnew_and_Pacsave.
    path*: string   ## ``/``-rooted, as ``pacmanFilesPaths`` gives it
    md5*: string    ## lower-case hex, 32 digits; "" when pacman recorded
                    ## no digest (``PacmanNoDigest``)

const PacmanNoDigest* = "(null)"
  ## What libalpm writes as a ``%BACKUP%`` digest it does not have (its
  ## ``%s`` of a NULL hash): a file the package lists as backup but whose
  ## packaged MD5 pacman never computed -- measured on Omarchy 4.5.0-3,
  ## ``bash-completion`` 2.18.0-1's
  ## ``etc/bash_completion.d/000_bash_completion_compat.bash``. Read as a
  ## backup file with no packaged digest, never as a damaged entry.

proc isMd5Hex(s: string): bool =
  s.len == 32 and s.allCharsInSet({'0'..'9', 'a'..'f'})

proc pacmanBackupFiles*(filesEntry: string): seq[PacmanBackupFile] =
  ## The ``%BACKUP%`` section of a ``files`` entry: ``<path><TAB><md5>``
  ## per line, the path relative to pacman's root. ``PacmanNoDigest`` is
  ## read as a backup file with no packaged digest (``md5`` ""). A line
  ## without a tab, a path that is already absolute, or any other digest
  ## that is not 32 lower-case hex digits is not pacman's and raises
  ## ``ValueError``: a reader that decides whether a file may be taken over
  ## must not read a damaged entry as "not a backup file".
  for raw in pacmanSections(filesEntry).getOrDefault("BACKUP"):
    let tab = raw.rfind('\t')
    if tab <= 0:
      raise newException(ValueError, "a %BACKUP% line without a digest: " &
        raw)
    let path = raw[0 ..< tab]
    var md5 = raw[tab + 1 .. ^1].strip()
    if md5 == PacmanNoDigest: md5 = ""
    if path[0] == '/' or (md5.len > 0 and not isMd5Hex(md5)):
      raise newException(ValueError, "a %BACKUP% line pacman did not " &
        "write: " & raw)
    result.add(PacmanBackupFile(path: "/" & path, md5: md5))

proc pacmanFilesSection*(filesEntry: string): seq[string] =
  ## The ``%FILES%`` section's lines exactly as the entry holds them (the
  ## base identity digests them, spec §4.3.1).
  pacmanSections(filesEntry).getOrDefault("FILES")

proc pacmanDbPresent*(root = "/"): bool =
  ## ``root`` carries a pacman local database (its version file exists).
  fileExists(root / PacmanLocalDir / PacmanDbVersionFile)

proc pacmanPackageDirs*(root = "/"): seq[string] =
  ## Every directory of the local database, sorted -- one without a
  ## ``desc`` entry included: pacman writes a package's directory before its
  ## ``desc``, so such a directory is a package being installed or a damaged
  ## entry, and a reader that must fail closed has to see it
  ## (``pacmanInstalledPackages`` returns it with no name).
  let dir = root / PacmanLocalDir
  if not dirExists(dir): return
  for kind, p in walkDir(dir):
    if kind == pcDir: result.add(p)
  result.sort(system.cmp)

proc parsePacmanDesc*(descEntry: string; dir = ""): PacmanPackage =
  ## The package a ``desc`` entry describes. The name is read from
  ## ``%NAME%``, never split off the directory name: a name may hold ``-``.
  let s = pacmanSections(descEntry)
  PacmanPackage(name: firstValue(s, "NAME"), version: firstValue(s, "VERSION"),
                architecture: firstValue(s, "ARCH"), dir: dir)

proc pacmanInstalledPackages*(root = "/"): seq[PacmanPackage] =
  ## Every installed package, sorted by name; empty without a database.
  ## An entry with no ``desc`` or no ``%NAME%`` is returned with an empty
  ## name, so a caller that must fail closed on a damaged database (the
  ## collision driver, the fingerprint) can see it.
  for d in pacmanPackageDirs(root):
    if fileExists(d / "desc"):
      result.add(parsePacmanDesc(readFile(d / "desc"), d))
    else:
      result.add(PacmanPackage(dir: d))
  result.sort(proc(a, b: PacmanPackage): int = cmp(a.name, b.name))

proc pacmanInstalledVersion*(name: string; root = "/"): string =
  ## ``%VERSION%`` of the installed package ``name``, "" when it is not
  ## installed or there is no database.
  for p in pacmanInstalledPackages(root):
    if p.name == name: return p.version
  ""

proc pacmanMajor*(version: string): int =
  ## The major version of a pacman version string: ``7.0.0-3`` -> 7,
  ## ``1:7.1.0-1`` -> 7 (an epoch is not part of the version proper).
  ## 0 when unparsable.
  var v = version.strip()
  let colon = v.find(':')
  if colon >= 0: v = v[colon + 1 .. ^1]
  var digits = ""
  for c in v:
    if c in {'0'..'9'}: digits.add(c)
    else: break
  if digits.len == 0: return 0
  try: parseInt(digits) except ValueError: 0

proc isArchFamilyRoot*(root = "/"): bool =
  ## ``root``'s os-release(5) (``/etc/os-release``, else
  ## ``/usr/lib/os-release``) names the Arch family: ``ID=arch``, or ``arch``
  ## among the words of ``ID_LIKE`` (Omarchy). False when neither file is
  ## readable. Read by ``repro_infra/host_base``'s parser, the one every
  ## other reader of the base's family uses.
  observeHostBaseAt(root).isArchFamily()

proc pacmanOwnersOf*(paths: openArray[string]; root = "/"):
    Table[string, seq[string]] =
  ## For each of ``paths`` (``/``-rooted, no trailing ``/``), every installed
  ## package whose ``%FILES%`` lists it -- as a file or as a directory, which
  ## several packages may list -- sorted by name; a path no package lists has
  ## no key. Raises ``ValueError`` for a database entry with no name or no
  ## ``files`` list: a reader that reports who owns a path must not read a
  ## damaged entry as "nobody".
  var wanted = initTable[string, seq[string]]()
  for p in paths: wanted[p] = @[]
  for pkg in pacmanInstalledPackages(root):
    if pkg.name.len == 0 or not fileExists(pkg.dir / "files"):
      raise newException(ValueError, "the pacman database entry " & pkg.dir &
        " has no name or no files list")
    for p in pacmanFilesPaths(readFile(pkg.dir / "files")):
      if p in wanted and pkg.name notin wanted[p]:
        wanted[p].add(pkg.name)
  for p, owners in wanted:
    if owners.len > 0:
      result[p] = owners.sorted(system.cmp)

proc pacmanPackageFilesEntry*(name: string; root = "/"):
    tuple[found: bool; entry: string] =
  ## The ``files`` entry of the installed package ``name``; ``found`` false
  ## when it is not installed. Raises ``IOError`` when it is installed and
  ## the entry cannot be read.
  for pkg in pacmanInstalledPackages(root):
    if pkg.name == name:
      return (true, readFile(pkg.dir / "files"))
  (false, "")
