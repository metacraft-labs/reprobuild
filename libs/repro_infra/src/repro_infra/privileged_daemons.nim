## Grants a privileged daemon makes to a service's account: polkit rules
## and D-Bus system bus policy (ReproOS Add-On Mode spec §13 decision 58,
## decided 2026-11-07 by the owner).
##
## A service whose account, or any of its groups, is named by a host
## polkit rule (``.rules`` or ``.pkla``, and polkit's administrator
## identities) or a D-Bus system policy can ask a root daemon to act for
## it, outside its own sandbox; it reaches everything. Uncertainty counts
## as naming: a file that cannot be read, a JavaScript rule this module
## cannot judge, or an include it does not follow.
##
## A polkit JavaScript rule (polkit(8), "AUTHORIZATION RULES") is judged
## not to name the account only when every result it can return is shown
## either not to grant anything or not to match the account:
##
## - ``polkit.Result.NO``/``NOT_HANDLED``/``AUTH_ADMIN``/``AUTH_ADMIN_KEEP``,
##   or their string values, and a bare ``return``, grant nothing;
## - ``polkit.Result.YES``/``AUTH_SELF``/``AUTH_SELF_KEEP`` (or ``"yes"``,
##   ``"auth_self"``, ``"auth_self_keep"``) grant, and are judged by the
##   ``if`` conditions they sit under: a top-level ``&&`` term
##   ``subject.user == "<name>"`` or ``subject.isInGroup("<name>")`` naming
##   another account excludes this one; one naming this account names it;
## - an ``addAdminRule`` result, an array of ``"unix-user:<n>"`` and
##   ``"unix-group:<n>"`` identities, names an account it lists;
## - any other result expression, a ``polkit.Result`` used any other way,
##   a template string, and anything this reader cannot parse, names it.
##
## Any string literal in a rules file equal to the account's name, one of
## its groups' names, or ``unix-user:``/``unix-group:`` of them, names it.
##
## Sources: polkit(8) (https://www.freedesktop.org/software/polkit/docs/latest/polkit.8.html);
## pklocalauthority(8) for ``.pkla`` and ``localauthority.conf.d``
## (``Identity=``, ``AdminIdentities=``); dbus-daemon(1), "CONFIGURATION
## FILE" (``<policy user= group=>``, ``<allow user= group=>``, ``<include>``,
## ``<includedir>``).

import std/[os, strutils, sets]

import ./service_account

const DaemonMutation {.strdefine: "reproAddonMutation".} = ""
  ## ``privileged-daemons-unread`` (falsifying build): no policy is read.

const
  PolkitRuleDirs* = ["/etc/polkit-1/rules.d", "/run/polkit-1/rules.d",
    "/usr/local/share/polkit-1/rules.d", "/usr/share/polkit-1/rules.d"]
  PolkitPklaRoots* = ["/etc/polkit-1/localauthority",
    "/var/lib/polkit-1/localauthority"]
  PolkitAuthorityConfDirs* = ["/etc/polkit-1/localauthority.conf.d"]
  DbusSystemFiles* = ["/usr/share/dbus-1/system.conf",
    "/etc/dbus-1/system.conf", "/etc/dbus-1/system-local.conf"]
  DbusSystemDirs* = ["/usr/share/dbus-1/system.d", "/etc/dbus-1/system.d"]

type
  AccountNames* = object
    ## What names the account: its user (name and uid) and its gids.
    user*: string
    uid*: int
    gids*: seq[int]
    lookup*: AccountLookup

proc rootedPath(root, path: string): string =
  if root.len == 0 or root == "/": path else: root & path

proc namesUser(a: AccountNames; n: string): bool =
  if n.len == 0: return false
  if n == a.user: return true
  if n.allCharsInSet(Digits):
    try: return parseInt(n) == a.uid
    except ValueError: return true
  let u = a.lookup.uidOf(n)
  u >= 0 and u == a.uid

proc namesGroup(a: AccountNames; n: string): bool =
  if n.len == 0: return false
  if n.allCharsInSet(Digits):
    try: return parseInt(n) in a.gids
    except ValueError: return true
  let g = a.lookup.gidOf(n)
  g != UnknownId and g in a.gids

proc globMatch(pat, s: string): bool =
  ## fnmatch(3) for ``*``, ``?`` and literal characters; a bracket
  ## expression matches anything (fails closed).
  if '[' in pat: return true
  var pi, si = 0
  var star = -1
  var mark = 0
  while si < s.len:
    if pi < pat.len and (pat[pi] == '?' or pat[pi] == s[si]):
      inc pi; inc si
    elif pi < pat.len and pat[pi] == '*':
      star = pi; mark = si; inc pi
    elif star >= 0:
      pi = star + 1; inc mark; si = mark
    else: return false
  while pi < pat.len and pat[pi] == '*': inc pi
  pi == pat.len

proc identityNames(a: AccountNames; id: string): bool =
  ## ``unix-user:<n>``, ``unix-group:<n>`` or ``unix-netgroup:<n>`` (a
  ## netgroup is not resolved: it names the account).
  let s = id.strip()
  if s.startsWith("unix-user:"):
    let n = s[10 .. ^1]
    if n.contains({'*', '?', '['}): return globMatch(n, a.user)
    return namesUser(a, n)
  if s.startsWith("unix-group:"):
    let n = s[11 .. ^1]
    if n.contains({'*', '?', '['}): return true
    return namesGroup(a, n)
  if s.startsWith("unix-netgroup:"): return true
  false

proc literalNames(a: AccountNames; lit: string): bool =
  namesUser(a, lit) or namesGroup(a, lit) or identityNames(a, lit)

# --- polkit JavaScript rules ------------------------------------------------

type
  TokKind = enum tkIdent, tkString, tkTemplate, tkNumber, tkPunct
  Tok = object
    kind: TokKind
    text: string

proc lexJs(src: string; ok: var bool): seq[Tok] =
  ok = true
  var i = 0
  while i < src.len:
    let c = src[i]
    if c in Whitespace: inc i; continue
    if c == '/' and i + 1 < src.len and src[i + 1] == '/':
      while i < src.len and src[i] != '\n': inc i
      continue
    if c == '/' and i + 1 < src.len and src[i + 1] == '*':
      let e = src.find("*/", i + 2)
      if e < 0: ok = false; return
      i = e + 2
      continue
    if c in {'"', '\''}:
      var s = ""
      inc i
      while i < src.len and src[i] != c:
        if src[i] == '\\':
          if i + 1 >= src.len: ok = false; return
          s.add(src[i + 1])     # an escape keeps the character it escapes
          i += 2
          continue
        if src[i] == '\n': ok = false; return
        s.add(src[i]); inc i
      if i >= src.len: ok = false; return
      inc i
      result.add(Tok(kind: tkString, text: s))
      continue
    if c == '`':
      result.add(Tok(kind: tkTemplate, text: ""))
      let e = src.find('`', i + 1)
      if e < 0: ok = false; return
      i = e + 1
      continue
    if c in IdentStartChars or c == '$':
      var s = ""
      while i < src.len and (src[i] in IdentChars or src[i] == '$'):
        s.add(src[i]); inc i
      result.add(Tok(kind: tkIdent, text: s))
      continue
    if c in Digits:
      var s = ""
      while i < src.len and src[i] in IdentChars + {'.'}:
        s.add(src[i]); inc i
      result.add(Tok(kind: tkNumber, text: s))
      continue
    # Multi-character operators this reader needs to tell apart.
    var op = $c
    for cand in ["===", "!==", "==", "!=", "&&", "||", "=>"]:
      if src.continuesWith(cand, i):
        op = cand
        break
    result.add(Tok(kind: tkPunct, text: op))
    i += op.len

type JsReader = object
  t: seq[Tok]
  i: int
  a: AccountNames
  why: string           ## set: the rules name the account (or uncertain)

proc at(r: JsReader; s: string): bool =
  r.i < r.t.len and r.t[r.i].kind in {tkPunct, tkIdent} and r.t[r.i].text == s

proc fail(r: var JsReader; why: string) =
  if r.why.len == 0: r.why = why

proc skipBalanced(r: var JsReader; open, close: string): seq[Tok] =
  ## The tokens between ``open`` (at ``r.i``) and its ``close``.
  var depth = 0
  while r.i < r.t.len:
    let k = r.t[r.i]
    if k.kind == tkPunct and k.text == open:
      inc depth
      if depth == 1: inc r.i; continue
    elif k.kind == tkPunct and k.text == close:
      dec depth
      if depth == 0:
        inc r.i
        return
    result.add(k)
    inc r.i
  r.fail("unbalanced " & open & close)

const
  NonGrantResults = ["NO", "NOT_HANDLED", "AUTH_ADMIN", "AUTH_ADMIN_KEEP"]
  GrantResults = ["YES", "AUTH_SELF", "AUTH_SELF_KEEP"]

proc splitTop(ts: seq[Tok]; sep: string): seq[seq[Tok]] =
  var depth = 0
  var cur: seq[Tok]
  for k in ts:
    if k.kind == tkPunct and k.text in ["(", "[", "{"]: inc depth
    elif k.kind == tkPunct and k.text in [")", "]", "}"]: dec depth
    if depth == 0 and k.kind == tkPunct and k.text == sep:
      result.add(cur)
      cur = @[]
    else:
      cur.add(k)
  result.add(cur)

proc stripParens(ts: seq[Tok]): seq[Tok] =
  result = ts
  while result.len >= 2 and result[0].text == "(" and result[^1].text == ")":
    # Only when the outer pair encloses everything.
    var depth = 0
    var whole = true
    for j, k in result:
      if k.kind == tkPunct and k.text == "(": inc depth
      elif k.kind == tkPunct and k.text == ")":
        dec depth
        if depth == 0 and j < result.len - 1: whole = false
    if not whole: break
    result = result[1 .. ^2]

proc subjectTerm(ts: seq[Tok]; name: var string): bool =
  ## ``subject.user ==|=== "<n>"`` (either side) or
  ## ``subject.isInGroup("<n>")``.
  let t = stripParens(ts)
  if t.len == 5 and t[0].text == "subject" and t[1].text == "." and
      t[2].text == "user" and t[3].text in ["==", "==="] and t[4].kind == tkString:
    name = "unix-user:" & t[4].text
    return true
  if t.len == 5 and t[4].text == "user" and t[3].text == "." and
      t[2].text == "subject" and t[1].text in ["==", "==="] and t[0].kind == tkString:
    name = "unix-user:" & t[0].text
    return true
  if t.len == 6 and t[0].text == "subject" and t[1].text == "." and
      t[2].text == "isInGroup" and t[3].text == "(" and t[4].kind == tkString and
      t[5].text == ")":
    name = "unix-group:" & t[4].text
    return true
  false

proc judgeReturn(r: var JsReader; expr: seq[Tok]; guards: seq[seq[Tok]]) =
  let e = stripParens(expr)
  if e.len == 0: return
  if e.len == 1 and e[0].kind == tkString:
    let v = e[0].text
    if v in ["no", "not_handled", "auth_admin", "auth_admin_keep"]: return
    if v notin ["yes", "auth_self", "auth_self_keep"]:
      r.fail("a rule returns " & v)
      return
  elif e.len == 5 and e[0].text == "polkit" and e[1].text == "." and
      e[2].text == "Result" and e[3].text == ".":
    if e[4].text in NonGrantResults: return
    if e[4].text notin GrantResults:
      r.fail("a rule returns polkit.Result." & e[4].text)
      return
  elif e.len >= 2 and e[0].text == "[" and e[^1].text == "]":
    # addAdminRule: a list of identities.
    for part in splitTop(e[1 .. ^2], ","):
      if part.len != 1 or part[0].kind != tkString:
        r.fail("an administrator rule returns a computed identity")
        return
      if identityNames(r.a, part[0].text):
        r.fail("an administrator rule names " & part[0].text)
        return
    return
  else:
    r.fail("a rule returns a value this check does not judge")
    return
  # A grant: excluded only by a guard term naming another account.
  for g in guards:
    for term in splitTop(stripParens(g), "&&"):
      var n: string
      if subjectTerm(term, n):
        if identityNames(r.a, n):
          r.fail("a rule grants " & n)
          return
        return                     # this grant is another account's
  r.fail("a rule grants a result its conditions do not keep from this account")

proc statement(r: var JsReader; guards: seq[seq[Tok]])

proc block0(r: var JsReader; guards: seq[seq[Tok]]) =
  ## ``{`` statements ``}``.
  inc r.i
  while r.i < r.t.len and not r.at("}") and r.why.len == 0:
    r.statement(guards)
  if r.i >= r.t.len:
    r.fail("unbalanced {}")
    return
  inc r.i

proc functionBody(r: var JsReader) =
  ## After ``function [name] (params)`` or ``(params) =>``: a body that may
  ## run under no condition of the code around it.
  if r.at("{"): r.block0(@[])
  else:
    var expr: seq[Tok]
    var depth = 0
    while r.i < r.t.len:
      let k = r.t[r.i]
      if depth == 0 and k.kind == tkPunct and k.text in [",", ")", ";", "}"]: break
      if k.kind == tkPunct and k.text in ["(", "[", "{"]: inc depth
      if k.kind == tkPunct and k.text in [")", "]", "}"]: dec depth
      expr.add(k)
      inc r.i
    r.judgeReturn(expr, @[])

proc expression(r: var JsReader; stops: openArray[string]) =
  ## Skip an expression up to a stop token at depth 0, reading every
  ## function literal inside it.
  var depth = 0
  while r.i < r.t.len and r.why.len == 0:
    let k = r.t[r.i]
    if depth == 0 and k.kind == tkPunct and k.text in stops: return
    if k.kind == tkTemplate:
      r.fail("a template string")
      return
    if k.kind == tkIdent and k.text == "function":
      inc r.i
      if r.i < r.t.len and r.t[r.i].kind == tkIdent: inc r.i
      if not r.at("("):
        r.fail("a function without parameters")
        return
      discard r.skipBalanced("(", ")")
      if not r.at("{"):
        r.fail("a function without a body")
        return
      r.functionBody()
      continue
    if k.kind == tkPunct and k.text == "=>":
      inc r.i
      r.functionBody()
      continue
    if k.kind == tkIdent and k.text == "polkit" and r.i + 2 < r.t.len and
        r.t[r.i + 2].text == "Result":
      # polkit.Result outside a return: aliased or computed.
      r.fail("polkit.Result used outside a return")
      return
    if k.kind == tkPunct and k.text in ["(", "[", "{"]: inc depth
    if k.kind == tkPunct and k.text in [")", "]", "}"]:
      if depth == 0: return
      dec depth
    inc r.i

proc statement(r: var JsReader; guards: seq[seq[Tok]]) =
  if r.i >= r.t.len: return
  let k = r.t[r.i]
  if k.kind == tkPunct and k.text == "{":
    r.block0(guards)
  elif k.kind == tkPunct and k.text == ";":
    inc r.i
  elif k.kind == tkIdent and k.text == "if":
    inc r.i
    if not r.at("("):
      r.fail("if without a condition")
      return
    let start = r.i
    let cond = r.skipBalanced("(", ")")
    # The condition itself may hold function literals.
    let after = r.i
    r.i = start + 1
    r.expression([")"])
    r.i = after
    r.statement(guards & @[cond])
    if r.at("else"):
      inc r.i
      r.statement(guards)
  elif k.kind == tkIdent and k.text == "return":
    inc r.i
    var expr: seq[Tok]
    var depth = 0
    while r.i < r.t.len:
      let x = r.t[r.i]
      if depth == 0 and x.kind == tkPunct and x.text in [";", "}"]: break
      if x.kind == tkPunct and x.text in ["(", "[", "{"]: inc depth
      if x.kind == tkPunct and x.text in [")", "]", "}"]: dec depth
      if x.kind == tkIdent and x.text in ["function"] or
          (x.kind == tkPunct and x.text == "=>"):
        r.fail("a rule returns a function")
        return
      expr.add(x)
      inc r.i
    if r.at(";"): inc r.i
    r.judgeReturn(expr, guards)
  elif k.kind == tkIdent and k.text in ["for", "while", "switch", "with"]:
    inc r.i
    if r.at("("):
      let start = r.i
      discard r.skipBalanced("(", ")")
      let after = r.i
      r.i = start + 1
      r.expression([")"])
      r.i = after
    r.statement(guards)
  elif k.kind == tkIdent and k.text in ["do", "try", "finally", "else"]:
    inc r.i
    r.statement(guards)
  elif k.kind == tkIdent and k.text == "catch":
    inc r.i
    if r.at("("): discard r.skipBalanced("(", ")")
    r.statement(guards)
  elif k.kind == tkIdent and k.text in ["case", "default"]:
    r.expression([":"])
    if r.at(":"): inc r.i
  elif k.kind == tkIdent and k.text == "function":
    r.expression([";", "}"])
    if r.at(";"): inc r.i
  else:
    r.expression([";", "}"])
    if r.at(";"): inc r.i

proc polkitRulesNames*(src: string; a: AccountNames): string =
  ## Why a polkit ``.rules`` file names the account, or "".
  var ok: bool
  let toks = lexJs(src, ok)
  if not ok: return "a rules file this check cannot read"
  for k in toks:
    if k.kind == tkString and literalNames(a, k.text):
      return "names \"" & k.text & "\""
  var r = JsReader(t: toks, a: a)
  while r.i < r.t.len and r.why.len == 0:
    let before = r.i
    r.statement(@[])
    if r.i == before:
      inc r.i                       # a stray closing token
      r.fail("a rules file this check cannot parse")
  r.why

# --- .pkla, localauthority.conf.d, D-Bus ------------------------------------

proc iniIdentitiesName(src: string; keys: openArray[string]; a: AccountNames): string =
  for raw in src.splitLines():
    let l = raw.strip()
    if l.len == 0 or l[0] in {'#', ';', '['}: continue
    let eq = l.find('=')
    if eq <= 0: continue
    let k = l[0 ..< eq].strip()
    if k notin keys: continue
    for id in l[eq + 1 .. ^1].split(';'):
      if id.strip().len > 0 and identityNames(a, id):
        return k & "=" & id.strip()
  ""

proc xmlAttr(tag, name: string; vals: var seq[string]) =
  var i = 0
  while true:
    let j = tag.find(name, i)
    if j < 0: return
    i = j + name.len
    if j > 0 and tag[j - 1] notin Whitespace: continue
    var k = i
    while k < tag.len and tag[k] in Whitespace: inc k
    if k >= tag.len or tag[k] != '=': continue
    inc k
    while k < tag.len and tag[k] in Whitespace: inc k
    if k >= tag.len or tag[k] notin {'"', '\''}: continue
    let q = tag[k]
    let e = tag.find(q, k + 1)
    if e < 0: return
    vals.add(tag[k + 1 ..< e])
    i = e + 1

proc dbusFileNames(src, path: string; a: AccountNames; scanned: HashSet[string];
                   root: string): string =
  ## Why a D-Bus configuration file names the account, or "".
  var i = 0
  while true:
    let lt = src.find('<', i)
    if lt < 0: return ""
    if src.continuesWith("<!--", lt):
      let e = src.find("-->", lt)
      if e < 0: return "an unterminated comment in " & path
      i = e + 3
      continue
    let gt = src.find('>', lt)
    if gt < 0: return "an unterminated element in " & path
    let tag = src[lt + 1 ..< gt]
    i = gt + 1
    let name = tag.strip().split({' ', '\t', '\n', '/'})[0]
    if name in ["include", "includedir"]:
      let ce = src.find("</" & name, gt)
      if ce < 0: return "an unterminated " & name & " in " & path
      if "if_selinux_enabled" in tag:
        # SELinux's own context associations (dbus-daemon(1), "include"):
        # read only when SELinux is enabled, and they name no account.
        i = ce
        continue
      var target = src[gt + 1 ..< ce].strip()
      if not target.startsWith("/"): target = parentDir(path) / target
      target = normalizedPath(target)
      if target notin scanned:
        return "an " & name & " of " & target & " this check does not read"
      i = ce
      continue
    if name notin ["policy", "allow", "deny"]: continue
    var users, groups: seq[string]
    xmlAttr(tag, "user", users)
    xmlAttr(tag, "group", groups)
    for u in users:
      # ``<allow user="*"/>`` lets anyone connect, which is the bus's
      # default; a ``<policy user="*">`` grants to everyone.
      if u == "*" and name != "policy": continue
      if u == "*" or namesUser(a, u):
        return "<" & name & " user=\"" & u & "\"> in " & path
    for g in groups:
      if g == "*" and name != "policy": continue
      if g == "*" or namesGroup(a, g):
        return "<" & name & " group=\"" & g & "\"> in " & path

proc privilegedDaemonGrant*(a: AccountNames; root = "/"): string =
  ## Why a host polkit rule or D-Bus system policy names the account (or
  ## cannot be shown not to), or "" (spec §13 decision 58).
  when DaemonMutation == "privileged-daemons-unread":
    return ""
  for d in PolkitRuleDirs:
    let full = rootedPath(root, d)
    if not dirExists(full): continue
    for kind, f in walkDir(full):
      if not f.endsWith(".rules"): continue
      var src = ""
      try: src = readFile(f)
      except IOError, OSError: return "the polkit rule " & f & " cannot be read"
      let why = polkitRulesNames(src, a)
      if why.len > 0: return "the polkit rule " & d / f.extractFilename & ": " & why
  for d in PolkitPklaRoots:
    let full = rootedPath(root, d)
    if not dirExists(full): continue
    for f in walkDirRec(full):
      if not f.endsWith(".pkla"): continue
      var src = ""
      try: src = readFile(f)
      except IOError, OSError: return "the polkit authority " & f & " cannot be read"
      let why = iniIdentitiesName(src, ["Identity"], a)
      if why.len > 0: return "the polkit authority " & f & ": " & why
  for d in PolkitAuthorityConfDirs:
    let full = rootedPath(root, d)
    if not dirExists(full): continue
    for kind, f in walkDir(full):
      if not f.endsWith(".conf"): continue
      var src = ""
      try: src = readFile(f)
      except IOError, OSError: return "the polkit configuration " & f & " cannot be read"
      let why = iniIdentitiesName(src, ["AdminIdentities"], a)
      if why.len > 0: return "the polkit configuration " & f & ": " & why
  var files: seq[string]
  var scanned = initHashSet[string]()
  for f in DbusSystemFiles:
    scanned.incl(f)
    if fileExists(rootedPath(root, f)): files.add(f)
  for d in DbusSystemDirs:
    scanned.incl(d)
    let full = rootedPath(root, d)
    if not dirExists(full): continue
    for kind, f in walkDir(full, relative = true):
      if f.endsWith(".conf"):
        files.add(d / f)
        scanned.incl(d / f)
  for f in files:
    var src = ""
    try: src = readFile(rootedPath(root, f))
    except IOError, OSError: return "the D-Bus policy " & f & " cannot be read"
    let why = dbusFileNames(src, f, a, scanned, root)
    if why.len > 0: return "the D-Bus system policy: " & why
  ""
