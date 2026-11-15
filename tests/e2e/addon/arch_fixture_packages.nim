## Fixture pacman packages for the Arch add-on gates, built in the guest
## with ``makepkg`` (spec ReproOS-Add-On-Mode §4.3.1, §12.1): the Arch
## counterpart of the Debian gates' ``equivs`` fixtures
## (``addon_testbed.buildEquivsPackage``). A gate gets a package that owns
## the files it collides with -- backup files (``backup=``) and plain ones,
## a vendor unit -- in as many versions as it upgrades through.
##
## A package is described by ``ArchFixturePackage`` and rendered to a
## PKGBUILD (https://man.archlinux.org/man/PKGBUILD.5): ``arch=('any')``,
## no sources, ``options=('!strip' '!debug')`` so the build needs neither
## binutils nor debugedit, and a ``package()`` that writes each file from a
## base64 literal (so no content can end a here-document early). The build
## runs as ``nobody`` -- makepkg refuses to build as root -- in a directory
## under ``/tmp``, with ``fakeroot`` (installed from the guest's pinned
## archive by ``installMakepkgPrerequisites``) for the packaging step; the
## result is installed with ``pacman -U``, which takes an unsigned local
## file under Arch's default ``LocalFileSigLevel = Optional``.
##
## Everything here runs before a gate's baseline fingerprint, or is an
## explicit step of the gate (an upgrade, a removal): installing ``fakeroot``
## and the fixture packages changes ``pacman-local``, so the baseline must
## already include it.
##
## *Mocking.* None: real makepkg, real pacman, in the guest.

import std/[base64, os, strutils]

import ./addon_testbed

type
  ArchFixtureFile* = object
    path*: string        ## absolute, below ``/etc`` or ``/usr``
    content*: string
    mode*: string        ## octal, e.g. ``0644``
    backup*: bool        ## listed in ``backup=``: a pacman backup file

  ArchFixturePackage* = object
    name*: string
    pkgver*: string
    pkgrel*: string
    files*: seq[ArchFixtureFile]

const
  FixtureBuildRoot* = "/tmp/repro-fx-makepkg"
    ## Where packages are built and kept, in the guest (a tmpfs: never in a
    ## fingerprint).

proc fxFile*(path, content: string; backup = false; mode = "0644"):
    ArchFixtureFile =
  ArchFixtureFile(path: path, content: content, mode: mode, backup: backup)

proc version*(p: ArchFixturePackage): string = p.pkgver & "-" & p.pkgrel

proc rel(path: string): string =
  ## A PKGBUILD names files relative to the package root.
  doAssert path.len > 1 and path[0] == '/', "not an absolute path: " & path
  path[1 .. ^1]

proc pkgbuild*(p: ArchFixturePackage): string =
  ## The PKGBUILD for ``p``.
  var backups: seq[string]
  for f in p.files:
    if f.backup: backups.add("'" & rel(f.path) & "'")
  result = "pkgname=" & p.name & "\n" &
    "pkgver=" & p.pkgver & "\n" &
    "pkgrel=" & p.pkgrel & "\n" &
    "pkgdesc='Reprobuild add-on test fixture'\n" &
    "arch=('any')\n" &
    "license=('custom')\n" &
    "options=('!strip' '!debug' '!emptydirs')\n" &
    "backup=(" & backups.join(" ") & ")\n" &
    "package() {\n"
  for f in p.files:
    result.add("  install -d \"$pkgdir/" & rel(f.path.rsplit('/', 1)[0] & "/") &
               "\"\n")
    result.add("  printf '%s' '" & encode(f.content) & "' | base64 -d > " &
               "\"$pkgdir/" & rel(f.path) & "\"\n")
    result.add("  chmod " & f.mode & " \"$pkgdir/" & rel(f.path) & "\"\n")
  result.add("}\n")

proc installMakepkgPrerequisites*(g: Guest) =
  ## ``fakeroot`` from the guest's pinned archive (``pacman -S --needed``):
  ## the one package ``makepkg`` needs that the Arch guests do not carry.
  let r = g.exec("pacman -Sy --noconfirm --needed fakeroot 2>&1",
                 timeoutSec = 1800)
  if r.exitCode != 0:
    raise newException(TestBedError, "installing fakeroot from the pinned " &
      "archive failed: " & r.stdout & r.stderr)

proc buildArchFixture*(g: Guest; p: ArchFixturePackage): string =
  ## Build ``p`` with makepkg in the guest and return the package file's
  ## guest path (``<name>-<version>-any.pkg.tar.zst``).
  let dir = FixtureBuildRoot & "/" & p.name & "-" & p.version
  let script = "set -e\n" &
    "rm -rf " & dir & "\nmkdir -p " & dir & "/out\n" &
    "cat > " & dir & "/PKGBUILD <<'REPRO_FIXTURE_EOF'\n" & pkgbuild(p) &
    "REPRO_FIXTURE_EOF\n" &
    "chown -R nobody: " & FixtureBuildRoot & "\n" &
    "cd " & dir & "\n" &
    "runuser -u nobody -- env HOME=" & dir & " PKGDEST=" & dir & "/out " &
    "SRCDEST=" & dir & " BUILDDIR=" & dir & "/build PKGEXT=.pkg.tar.zst " &
    "makepkg --nodeps --noconfirm --noprogressbar >" & dir & "/makepkg.log 2>&1 " &
    "|| { cat " & dir & "/makepkg.log; exit 1; }\n" &
    "ls " & dir & "/out/" & p.name & "-" & p.version & "-any.pkg.tar.zst\n"
  let r = g.exec(script, timeoutSec = 900)
  if r.exitCode != 0:
    raise newException(TestBedError, "makepkg of " & p.name & " " &
      p.version & " failed: " & r.stdout & r.stderr)
  r.stdout.strip().splitLines()[^1]

proc pacmanInstall*(g: Guest; pkgFile: string): ExecOut =
  ## ``pacman -U`` of a fixture package file (an install, an upgrade or a
  ## downgrade alike).
  g.exec("pacman -U --noconfirm " & pkgFile & " 2>&1", timeoutSec = 900)

proc pacmanRemove*(g: Guest; name: string): ExecOut =
  ## ``pacman -R`` of an installed package: a backup file whose bytes
  ## differ from the packaged version is kept as ``<path>.pacsave``.
  g.exec("pacman -R --noconfirm " & name & " 2>&1", timeoutSec = 900)

proc backupMd5InDb*(g: Guest; pkg, path: string): string =
  ## The MD5 the local database's ``%BACKUP%`` holds for ``path`` of the
  ## installed ``pkg`` (``pacman -Qii``'s source), or "" when none.
  g.run("f=$(ls -d /var/lib/pacman/local/" & pkg & "-*/files 2>/dev/null " &
    "| head -1); [ -n \"$f\" ] && awk -v p=" & quoteShell(rel(path)) &
    " 'BEGIN{FS=\"\\t\"} /^%BACKUP%$/{b=1;next} /^%/{b=0} " &
    "b && $1==p {print $2}' \"$f\" || true").strip()

proc md5InGuest*(g: Guest; path: string): string =
  ## ``md5sum`` of a guest file, or "absent".
  g.run("if [ -f " & path & " ] && [ ! -L " & path & " ]; then md5sum " &
    path & " | cut -d' ' -f1; else echo absent; fi").strip()

proc qkkProblems*(output: string): seq[string] =
  ## The lines of ``pacman -Qkk`` output that say a file of the package does
  ## not match what the database records. pacman reports a backup file whose
  ## content differs only as a ``backup file: <pkg>: <path> (SHA256 checksum
  ## mismatch)`` line (or MD5) and still counts "0 altered files", so the
  ## summary cannot be trusted; every ``mismatch`` line counts except
  ## ``Modification time mismatch``, which any restore causes (the file is
  ## rewritten) and which says nothing about its bytes. A ``missing`` or
  ## ``warning:`` line counts too.
  for raw in output.splitLines():
    let line = raw.strip()
    if line.len == 0: continue
    let low = line.toLowerAscii()
    if "mismatch" in low:
      if "(modification time mismatch)" in low: continue
      result.add(line)
    elif "missing" in low or low.startsWith("warning:") or low.startsWith("error:"):
      result.add(line)

block qkkProblemsSelfCheck:
  # Measured pacman 7.1 output (Arch guest, 2026-11-15): a restored file
  # whose bytes match carries only the modification-time line; one whose
  # bytes do not adds the checksum line under the same "0 altered files".
  doAssert qkkProblems("backup file: p: /etc/x (Modification time mismatch)\n" &
    "p: 3 total files, 0 altered files\n").len == 0
  doAssert qkkProblems("backup file: p: /etc/x (Modification time mismatch)\n" &
    "backup file: p: /etc/x (SHA256 checksum mismatch)\n" &
    "p: 3 total files, 0 altered files\n").len == 1
  doAssert qkkProblems("backup file: p: /etc/x (MD5 checksum mismatch)\n").len == 1
  doAssert qkkProblems("warning: p: /etc/y (No such file or directory)\n").len == 1
  doAssert qkkProblems("p: /etc/z (Size mismatch)\n").len == 1

proc pacmanQkkClean*(g: Guest; pkg: string): tuple[ok: bool; output: string] =
  ## ``pacman -Qkk <pkg>``: every file of the package, backup files
  ## included, matches what the database records -- exit 0 and no line
  ## ``qkkProblems`` counts.
  let r = g.exec("pacman -Qkk " & pkg & " 2>&1")
  let said = r.stdout & r.stderr
  (r.exitCode == 0 and qkkProblems(said).len == 0, said)
