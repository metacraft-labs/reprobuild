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

proc pacmanDbPresent*(root = "/"): bool =
  ## ``root`` carries a pacman local database (its version file exists).
  fileExists(root / PacmanLocalDir / PacmanDbVersionFile)

proc pacmanPackageDirs*(root = "/"): seq[string] =
  ## Every package directory of the local database, sorted. A directory
  ## without a ``desc`` entry is not a package (pacman writes it first).
  let dir = root / PacmanLocalDir
  if not dirExists(dir): return
  for kind, p in walkDir(dir):
    if kind == pcDir and fileExists(p / "desc"): result.add(p)
  result.sort(system.cmp)

proc parsePacmanDesc*(descEntry: string; dir = ""): PacmanPackage =
  ## The package a ``desc`` entry describes. The name is read from
  ## ``%NAME%``, never split off the directory name: a name may hold ``-``.
  let s = pacmanSections(descEntry)
  PacmanPackage(name: firstValue(s, "NAME"), version: firstValue(s, "VERSION"),
                architecture: firstValue(s, "ARCH"), dir: dir)

proc pacmanInstalledPackages*(root = "/"): seq[PacmanPackage] =
  ## Every installed package, sorted by name; empty without a database.
  ## An entry with no ``%NAME%`` is returned with an empty name, so a caller
  ## that must fail closed on a damaged database can see it.
  for d in pacmanPackageDirs(root):
    result.add(parsePacmanDesc(readFile(d / "desc"), d))
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
