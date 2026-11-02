## The paths a ``linux.tmpfilesRule`` fragment acts on, and the scope every
## add-on apply holds them to (spec §4.1, the ``tmpfiles`` class; §4.4).
##
## A tmpfiles.d(5) line is ``Type Path Mode User Group Age Argument``.
## ``systemd-tmpfiles --create`` runs it as root, at once on apply and at
## every boot, so the line -- not the fragment's file name -- decides what
## is written: ``f+ /etc/nologin``, ``L+ /etc/ssh/sshd_config.d/x - - - -
## /var/lib/x`` or ``w /etc/pam.d/sshd - - - - ...`` write the management
## path through a fragment whose name is in scope
## (https://www.freedesktop.org/software/systemd/man/latest/tmpfiles.d.html).
##
## The class's roots are explicit (spec §4.1): ``/var/lib``, ``/var/cache``,
## ``/var/log`` and ``/run``, minus the directories other owners hold there
## (systemd's runtime unit, credential and class directories, the add-on's
## own state, logind's per-user runtime directories). A line is parsed, not
## guessed at: a type outside tmpfiles.d(5), a quoted or escaped field, a
## specifier (``%h``), a glob, a path that is not canonical, or a missing
## path is refused, and so is a device node (``c``, ``b``).

import std/strutils

import repro_elevation/posix_system_parse

import ./mutations

const
  TmpfilesClassRoots* = ["/var/lib/", "/var/cache/", "/var/log/", "/run/"]
    ## Spec §4.1: the tmpfiles class's "state, runtime and log
    ## directories". A rule's path is strictly below one of them.
  TmpfilesForeignRoots* = [
    # systemd's own runtime trees: units, drop-ins and generators under
    # /run/systemd/system, transient units, credentials, networkd's and
    # resolved's state; and the runtime class directories (a fragment
    # there is a class the add-on reaches through its own kind, never
    # through tmpfiles).
    "/run/systemd/", "/run/udev/", "/run/tmpfiles.d/", "/run/sysctl.d/",
    "/run/sysusers.d/", "/run/modprobe.d/", "/run/modules-load.d/",
    "/run/binfmt.d/", "/run/environment.d/", "/run/credentials/",
    # logind's per-user runtime directories (user-runtime-dir@.service).
    "/run/user/",
    # The add-on's own state and secrets, and systemd's persistent state
    # (dynamic users' StateDirectory, timers, linger).
    "/run/repro/", "/var/lib/repro/", "/var/lib/private/", "/var/lib/systemd/"]
    ## Directories below the class roots that belong to another owner: a
    ## rule may not act on them, in any apply.
  TmpfilesTypes = ["f", "w", "d", "D", "e", "v", "q", "Q", "p", "L", "C",
                   "x", "X", "r", "R", "z", "Z", "t", "T", "h", "H", "a",
                   "A"]
    ## tmpfiles.d(5)'s line types (each may carry ``+``), less the device
    ## nodes ``c`` and ``b``, which no state, runtime or log directory
    ## needs.
  TmpfilesModifiers = {'!', '-', '=', '~', '^'}
  TmpfilesSourceTypes = ["L", "C"]
    ## Types whose argument is a path the rule makes the target refer to
    ## or copies from: a symlink's target, a copy's source.

type
  TmpfilesRule* = object
    ## One parsed line: its type (letter and ``+``, modifiers dropped), its
    ## path, and for ``L``/``C`` the argument path ("" when ``-``/absent:
    ## systemd's default under /usr/share/factory).
    line*: string
    kind*: string
    path*: string
    source*: string

proc underRoot(path, root: string): bool =
  ## ``path`` is ``root`` without its slash, or below it.
  path & "/" == root or path.startsWith(root)

proc parseTmpfilesLine*(line: string; rule: var TmpfilesRule): string =
  ## Parse one non-blank, non-comment line into ``rule``; "" or why it is
  ## refused as unparseable.
  if '"' in line or '\'' in line or '\\' in line:
    return "it quotes or escapes a field, which the add-on does not parse"
  let f = line.splitWhitespace()
  if f.len < 2:
    return "it names no path"
  var t = f[0]
  while t.len > 1 and t[^1] in TmpfilesModifiers: t.setLen(t.len - 1)
  let base = if t.endsWith("+"): t[0 ..< ^1] else: t
  if base notin TmpfilesTypes:
    return "type '" & f[0] & "' is not a tmpfiles.d(5) type the add-on " &
      "applies (device nodes c and b are not)"
  rule = TmpfilesRule(line: line, kind: t, path: f[1])
  if base in TmpfilesSourceTypes and f.len >= 7:
    let arg = f[6 .. ^1].join(" ")
    if arg != "-": rule.source = arg
  for p in [rule.path, rule.source]:
    if p.len == 0: continue
    if '%' in p:
      return "path " & p & " uses a specifier, which the add-on does not resolve"
    if p.contains({'*', '?', '['}):
      return "path " & p & " is a glob, which could match outside the class"
    let canon = nonCanonicalPathError("path", p)
    if canon.len > 0:
      return canon
  ""

proc tmpfilesRules*(content: string; rules: var seq[TmpfilesRule]): string =
  ## Every rule of ``content``; "" or the first line's refusal.
  for raw in content.splitLines():
    let line = raw.strip()
    if line.len == 0 or line[0] == '#': continue
    var r: TmpfilesRule
    let why = parseTmpfilesLine(line, r)
    if why.len > 0:
      return "line `" & line & "`: " & why
    rules.add(r)
  ""

proc tmpfilesClassRefusal*(path: string): string =
  ## Why ``path`` is outside the tmpfiles class (spec §4.1), or "".
  var inClass = false
  for root in TmpfilesClassRoots:
    if path.startsWith(root): inClass = true
  if not inClass:
    return path & " is outside the tmpfiles class's directories (" &
      TmpfilesClassRoots.join(", ") & "; spec §4.1)"
  for root in TmpfilesForeignRoots:
    if underRoot(path, root):
      return path & " is under " & root & ", which another owner holds " &
        "(spec §4.1)"
  ""

proc tmpfilesScopeRefusal*(content: string): string =
  ## Why a tmpfiles fragment is out of scope for any add-on apply (spec
  ## §4.1, §4.4), or "": every line parses, and every path it acts on --
  ## and a symlink's target or a copy's source -- is in the class. The
  ## class lies outside ``/etc``, so no rule reaches a managed ``/etc``
  ## prefix, a class directory or a unit.
  when mutated("tmpfiles-scope-unchecked"):
    return ""
  var rules: seq[TmpfilesRule]
  let bad = tmpfilesRules(content, rules)
  if bad.len > 0:
    return bad
  for r in rules:
    for p in [r.path, r.source]:
      if p.len == 0: continue
      let why = tmpfilesClassRefusal(p)
      if why.len > 0:
        return "line `" & r.line & "`: " & why
  ""

const TmpfilesManagementPaths* = [
  # pam_nologin reads /run/nologin as well as /etc/nologin: its presence
  # refuses every non-root login.
  "/run/nologin", "/var/run/nologin",
  # sshd's privilege-separation directory and pid file.
  "/run/sshd", "/run/sshd.pid",
  # The firewall and network classes' runtime and persistent state.
  "/run/NetworkManager/", "/run/netplan/", "/run/network/",
  "/run/firewalld/", "/var/lib/NetworkManager/", "/var/lib/firewalld/",
  "/var/lib/iptables/", "/var/lib/nftables/"]
  ## Paths under the tmpfiles class that are part of the management path
  ## (spec §9.1): an agent apply's rule may not act on them.

proc tmpfilesManagementRefusal*(content: string): string =
  ## Why a deploy-agent apply may not carry this tmpfiles fragment (spec
  ## §9.1), or "": a rule acts on a management path. The scope check
  ## refuses an unparseable fragment first; one that does not parse here
  ## is refused too.
  when mutated("agent-management-path-ignores-tmpfiles"):
    return ""
  var rules: seq[TmpfilesRule]
  let bad = tmpfilesRules(content, rules)
  if bad.len > 0:
    return bad
  for r in rules:
    for p in [r.path, r.source]:
      if p.len == 0: continue
      for m in TmpfilesManagementPaths:
        if (if m.endsWith("/"): underRoot(p, m) else: p == m or p.startsWith(m & "/")):
          return "line `" & r.line & "` acts on " & p & " (the management " &
            "path: what can lock sshd's or the console's users out)"
  ""
