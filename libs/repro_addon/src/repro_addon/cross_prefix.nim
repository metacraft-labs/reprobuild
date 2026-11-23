## A cross-built reprobuild prefix and the host's glibc.
##
## ReproOS add-on mode §7.9 (the glibc exception). The add-on's own artefact
## is static and links nothing from the base, but an engine prefix that
## ``scripts/cross/build_linux_cross.sh`` cross-builds for a small board
## (rpi2's armhf engine, the add-on agent's profile compiler there) is
## dynamically linked against the glibc of the sysroot it was built with.
## glibc is backward compatible only: a binary runs on a glibc of at least
## the version it was linked against, and on an older one the loader refuses
## it with "version `GLIBC_2.xx' not found" (glibc's symbol versioning,
## https://sourceware.org/glibc/wiki/Development_Todo/Versioning). So such a
## prefix may be installed only where the base's glibc is at least the
## sysroot's, and it is checked before it is used, by name, rather than left
## to fail at the first compile with a loader message.
##
## The prefix records its sysroot's glibc in ``share/repro/cross-build-info``
## (copied from the sysroot's ``.sysroot-info`` by the build):
## ``sysroot_glibc_version=2.41`` from current builds, and on older ones only
## ``sysroot_glibc=ldd (Debian GLIBC 2.41-12) 2.41``, whose last word is the
## version. A prefix without the file is not a cross prefix (the Nix
## closure's engine carries its own glibc) and is not judged.

import std/[os, strutils]

import ./host_exec
import ./mutations

const CrossBuildInfoRel* = "share" / "repro" / "cross-build-info"
  ## Where a cross prefix records how it was built, relative to its root.

proc isGlibcVersion(s: string): bool =
  ## "2.41", "2.39": dot-separated decimal fields, at least two.
  let parts = s.split('.')
  if parts.len < 2: return false
  for p in parts:
    if p.len == 0 or not p.allCharsInSet(Digits): return false
  true

proc sysrootGlibcVersion*(crossBuildInfo: string): string =
  ## The sysroot glibc version a ``cross-build-info`` text records, or ""
  ## when it records none. ``sysroot_glibc_version=`` wins; otherwise the
  ## last word of ``sysroot_glibc=`` (``ldd --version``'s first line) when
  ## it is a version.
  var fromLdd = ""
  for raw in crossBuildInfo.splitLines():
    let line = raw.strip()
    if line.startsWith("sysroot_glibc_version="):
      let v = line["sysroot_glibc_version=".len .. ^1].strip()
      if isGlibcVersion(v): return v
    elif line.startsWith("sysroot_glibc="):
      let words = line["sysroot_glibc=".len .. ^1].splitWhitespace()
      if words.len > 0 and isGlibcVersion(words[^1]):
        fromLdd = words[^1]
  fromLdd

proc glibcVersionCmp*(a, b: string): int =
  ## Compare two glibc versions field by field, numerically: "2.9" < "2.10".
  let x = a.split('.')
  let y = b.split('.')
  for i in 0 ..< max(x.len, y.len):
    let p = if i < x.len: parseInt(x[i]) else: 0
    let q = if i < y.len: parseInt(y[i]) else: 0
    if p != q: return cmp(p, q)
  0

proc crossPrefixRoot*(binary: string): string =
  ## The prefix a binary is installed in (``<prefix>/bin/<name>``), through
  ## any symlinks (``/usr/local/bin/reprobuild -> /usr/local/repro/bin/...``),
  ## or "" when ``binary`` does not exist.
  if not fileExists(binary): return ""
  var p = binary
  try:
    p = expandFilename(binary)
  except OSError:
    return ""
  p.parentDir.parentDir

proc crossPrefixGlibcProblem*(binary, hostGlibc: string): string =
  ## Why ``binary``'s cross prefix cannot run on a host whose glibc is
  ## ``hostGlibc`` (``getconf GNU_LIBC_VERSION``'s version), or "" when it
  ## can, when ``binary`` is not in a cross prefix, or when the prefix
  ## records no sysroot glibc. An unknown host glibc (""), with a prefix
  ## that needs one, is a problem: a base without glibc cannot run it.
  when mutated("cross-prefix-glibc-unchecked"):
    return ""
  let root = crossPrefixRoot(binary)
  if root.len == 0: return ""
  let info = root / CrossBuildInfoRel
  if not fileExists(info): return ""
  let needed = sysrootGlibcVersion(readFile(info))
  if needed.len == 0: return ""
  if hostGlibc.len == 0 or not isGlibcVersion(hostGlibc):
    return "the cross-built prefix " & root & " needs glibc " & needed &
      " or newer (its sysroot's), and this host's glibc version could not " &
      "be read"
  if glibcVersionCmp(hostGlibc, needed) < 0:
    return "the cross-built prefix " & root & " was linked against glibc " &
      needed & " (its sysroot's) and this host has glibc " & hostGlibc &
      ": rebuild it against a sysroot taken from this host " &
      "(scripts/cross/fetch_target_sysroot.sh)"
  ""

proc hostGlibcVersion*(): string =
  ## This host's glibc version (``getconf GNU_LIBC_VERSION`` prints
  ## "glibc 2.41"), or "" when there is no ``getconf`` or it is not glibc.
  ## ``getconf`` is used rather than ``gnu_get_libc_version`` because the
  ## add-on binary is static and links no glibc to ask.
  let getconf = resolveHostTool(["/usr/bin/getconf", "/bin/getconf"])
  if getconf.len == 0: return ""
  try:
    let r = runHostTool([getconf, "GNU_LIBC_VERSION"], timeoutSec = 30)
    if r.exitCode != 0: return ""
    let words = r.output.splitWhitespace()
    if words.len == 2 and words[0] == "glibc" and isGlibcVersion(words[1]):
      return words[1]
  except CatchableError:
    discard
  ""
