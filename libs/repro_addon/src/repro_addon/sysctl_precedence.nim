## Which sysctl fragment wins at boot (ReproOS Add-On Mode §4.3, §7.2
## step 6).
##
## The add-on applies a ``linux.sysctl`` resource by running the host's
## ``systemd-sysctl`` on its own fragment, ``/etc/sysctl.d/90-repro-*.conf``.
## That sets the key now. At boot, though, ``systemd-sysctl.service``
## applies every fragment in one pass, ordered by file name across the
## sysctl.d directories, and a later assignment of the same key wins
## (https://www.freedesktop.org/software/systemd/man/latest/sysctl.d.html,
## "Configuration Directories and Precedence"). A base fragment that sorts
## after the add-on's -- ``99-sysctl.conf``, which Debian and Ubuntu link
## to ``/etc/sysctl.conf``, or any ``9x-`` file a package ships -- would
## silently put its own value back at every boot, so the host's value
## would follow the base, not the ledger. procps' ``sysctl --system``
## reads ``/etc/sysctl.conf`` last of all, so that file counts as later
## too.
##
## This module finds those later assignments so the plan can refuse the
## resource instead (§4.3: a collision is refused with the observation
## that justifies it). Pure over a root directory, so the unit tests run
## it on a fixture tree.

import std/[algorithm, os, posix, sets, strutils]

const
  SysctlDirs* = ["/etc/sysctl.d", "/run/sysctl.d", "/usr/local/lib/sysctl.d",
                 "/usr/lib/sysctl.d", "/lib/sysctl.d"]
    ## In systemd's precedence order: a file name in an earlier directory
    ## hides the same name in a later one.
  SysctlConf* = "/etc/sysctl.conf"

type
  LaterAssignment* = object
    file*: string      ## the fragment as found, with `` -> <target>``
                       ## when it is a link
    pattern*: string   ## the key or glob as written
    value*: string     ## the value it assigns, whitespace-normalised

proc normaliseKey*(key: string): string =
  ## sysctl.d accepts ``/`` as well as ``.`` as the separator.
  key.strip().replace('/', '.')

proc normaliseValue*(value: string): string =
  value.splitWhitespace().join(" ")

proc keyMatches(pattern, key: string): bool =
  ## A plain key, or a glob (systemd 249+: ``net.ipv4.conf.*.rp_filter``).
  if pattern == key: return true
  if pattern.contains({'*', '?', '['}):
    return fnmatch(pattern.cstring, key.cstring, 0) == 0
  false

proc assignmentsIn*(text: string): seq[tuple[pattern, value: string]] =
  ## ``key = value`` lines (comments ``#`` / ``;``, a leading ``-`` that
  ## only silences errors).
  for raw in text.splitLines():
    var line = raw.strip()
    if line.len == 0 or line[0] in {'#', ';'}: continue
    if line[0] == '-': line = line[1 .. ^1].strip()
    let eq = line.find('=')
    if eq <= 0: continue
    result.add((normaliseKey(line[0 ..< eq]), normaliseValue(line[eq + 1 .. ^1])))

proc laterAssignments*(key, ownFragment: string; root = "/"):
    seq[LaterAssignment] =
  ## Every assignment of ``key`` that systemd (or procps) applies AFTER
  ## ``ownFragment`` (a path in ``/etc/sysctl.d``): fragments whose name
  ## sorts after it, and ``/etc/sysctl.conf``. The add-on's own fragments
  ## (``90-repro-*``) are not the base's and are skipped. ``root``
  ## relocates the directories for tests.
  let wanted = normaliseKey(key)
  let own = extractFilename(ownFragment)
  var seen = initHashSet[string]()
  var files: seq[tuple[name, path: string]]
  for d in SysctlDirs:
    let dir = if root == "/": d else: root / d
    if not dirExists(dir): continue
    for kind, path in walkDir(dir):
      let name = extractFilename(path)
      if not name.endsWith(".conf") or name in seen: continue
      if kind notin {pcFile, pcLinkToFile}: continue
      seen.incl(name)
      files.add((name, path))
  files.sort(proc(a, b: tuple[name, path: string]): int = cmp(a.name, b.name))
  var later: seq[string]
  for f in files:
    if f.name > own and not f.name.startsWith("90-repro-"):
      later.add(f.path)
  let conf = if root == "/": SysctlConf else: root / SysctlConf
  if fileExists(conf): later.add(conf)
  var read = initHashSet[string]()
  for path in later:
    # Debian and Ubuntu link /etc/sysctl.d/99-sysctl.conf to
    # /etc/sysctl.conf: one file, reported once.
    let real = try: expandFilename(path) except OSError: path
    if real in read: continue
    read.incl(real)
    var text: string
    try:
      text = readFile(path)
    except IOError, OSError:
      continue
    for (pattern, value) in assignmentsIn(text):
      if keyMatches(pattern, wanted):
        result.add(LaterAssignment(
          file: (if real != path: path & " -> " & real else: path),
          pattern: pattern, value: value))

proc sysctlPrecedenceRefusal*(key, value, ownFragment: string;
                              root = "/"): string =
  ## "" unless a base fragment applied after the add-on's assigns ``key``
  ## a different value: then why the resource is refused. The same value
  ## is no collision -- the boot-time value is the ledger's either way.
  let want = normaliseValue(value)
  var clashes: seq[string]
  for a in laterAssignments(key, ownFragment, root):
    if a.value != want:
      clashes.add(a.file & " sets " & a.pattern & " = " & a.value)
  if clashes.len == 0: return ""
  "the base assigns " & key & " after the add-on's fragment " & ownFragment &
    " (" & clashes.join("; ") & "), so every boot would put that value " &
    "back over the ledger's " & want & "; remove or change the base's " &
    "assignment, or leave the key to the base"
