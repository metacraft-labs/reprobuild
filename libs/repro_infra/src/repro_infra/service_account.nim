## The account a systemd service will run as, resolved the way systemd
## resolves it -- one resolver for every check that judges a unit's
## account (the add-on's floor, the carried-state reach analysis).
##
## What systemd does, and so what this module models
## (systemd.exec(5) ``User=``, ``Group=``, ``SupplementaryGroups=``,
## ``DynamicUser=``; systemd.unit(5) "Specifiers"):
##
## - ``User=`` empty: the system manager runs the service as ``root``.
##   ``Group=`` empty: the user's primary group.
## - Specifiers are expanded first. For the system manager ``%U`` and ``%G``
##   are ``0``, ``%u`` and ``%g`` are ``root``; ``%i``/``%I`` are the
##   instance name, ``%n``/``%N``/``%p``/``%P``/``%j``/``%J`` parts of the
##   unit name, ``%%`` a ``%``. A template's own file (``foo@.service``)
##   names no instance: any instance can be started (``[Install]
##   DefaultInstance=`` only picks the one enabled), so an instance
##   specifier there does not resolve. Any other specifier, and any ``$``,
##   does not resolve.
## - ``DynamicUser=yes``: "If a statically allocated user or group of the
##   configured name already exists, it is used and no dynamic user/group
##   is allocated." That holds for ``Group=`` as well as ``User=``; with
##   ``User=`` empty the name is the unit's own (without its suffix), and
##   with ``Group=`` empty the group is named like the user. ``root``
##   always exists, so ``DynamicUser=yes`` with ``User=root`` runs as uid 0.
## - A name resolves through the account databases: another name with uid
##   0 (``toor``) is root; a user's ``/etc/group`` memberships are groups it
##   holds whatever ``SupplementaryGroups=`` says.
##
## Nothing here guesses. A name, id or group the lookup cannot resolve is
## reported in ``unknown``; a caller must treat a non-empty ``unknown`` as
## a refusal, never as "not root". Ids an account will get at creation from
## the system range (``useradd -r``, ``systemd-sysusers`` without a pinned
## id) are ``AllocatedId``, and a dynamic user's or group's id is
## ``DynamicId`` (61184-65519): neither is ever 0.

import std/[os, sets, strutils, tables]

import ./profile

const AccountMutation {.strdefine: "reproAddonMutation".} = ""
  ## ``account-as-written`` (falsifying build, ``repro_addon/mutations``):
  ## the account taken as written -- no specifiers, no static account under
  ## ``DynamicUser=yes``, no uid alias, no group memberships.

const
  UnknownId* = -1    ## not resolvable: a refusal for the caller
  AllocatedId* = -2  ## allocated at creation from the system range, never 0
  DynamicId* = -3    ## a dynamic user's or group's id, never 0

type
  AccountLookup* = object
    ## The account databases a resolution reads. Every proc returns
    ## ``UnknownId`` (or an empty result) for what it does not know.
    uidOf*: proc (name: string): int {.closure.}
      ## A user's uid by name.
    primaryGidOf*: proc (name: string): int {.closure.}
      ## A user's primary gid by name.
    gidOf*: proc (name: string): int {.closure.}
      ## A group's gid by name.
    groupsOf*: proc (name: string): seq[int] {.closure.}
      ## The gids of the groups that list the user as a member
      ## (``/etc/group``'s fourth field).
    userOfUid*: proc (uid: int): string {.closure.}
      ## A user's name by uid ("" when there is none).

  ResolvedAccount* = object
    ## The account a service runs as.
    user*: string             ## the user's name, or its uid as text
    uid*: int                 ## its uid (``AllocatedId``, ``DynamicId``, ``UnknownId``)
    dynamicUser*: bool        ## a dynamic user is allocated
    group*: string            ## the primary group's name, or its gid as text
    primaryGid*: int
    dynamicGroup*: bool       ## a dynamic group is allocated
    supplementaryGids*: seq[int]  ## from ``SupplementaryGroups=``
    memberGids*: seq[int]     ## the user's ``/etc/group`` memberships
    unknown*: seq[string]     ## what did not resolve (a refusal)

proc known*(a: ResolvedAccount): bool = a.unknown.len == 0
  ## Whether every part of the account resolved.

proc allGids*(a: ResolvedAccount): seq[int] =
  ## Every gid the service's processes hold: the primary group, the
  ## supplementary groups and the user's memberships.
  result.add(a.primaryGid)
  for g in a.supplementaryGids: result.add(g)
  for g in a.memberGids: result.add(g)

proc userIsRoot*(a: ResolvedAccount): bool = a.uid == 0
  ## The service runs as uid 0. Meaningful only when ``known``.

proc groupIsRoot*(a: ResolvedAccount): bool = 0 in a.allGids
  ## The service holds gid 0. Meaningful only when ``known``.

proc unitParts(unit: string): tuple[prefix, instance, suffix: string;
                                     isTemplate: bool] =
  ## ``foo@bar.service`` -> ("foo", "bar", "service", false);
  ## ``foo@.service`` -> ("foo", "", "service", true).
  let dot = unit.rfind('.')
  let stem = if dot > 0: unit[0 ..< dot] else: unit
  result.suffix = if dot > 0: unit[dot + 1 .. ^1] else: ""
  let at = stem.find('@')
  if at < 0:
    result.prefix = stem
  else:
    result.prefix = stem[0 ..< at]
    result.instance = stem[at + 1 .. ^1]
    result.isTemplate = result.instance.len == 0

proc expandSpecifiers*(value, unit: string; ok: var bool): string =
  ## ``value`` with the specifiers systemd expands in an account setting
  ## of ``unit``, for the system manager. ``ok`` is false when one does not
  ## resolve (see the module header).
  ok = true
  when AccountMutation == "account-as-written":
    return value
  if '$' in value:
    ok = false
    return value
  let u = unitParts(unit)
  let stem = if u.instance.len > 0: u.prefix & "@" & u.instance else: u.prefix
  var i = 0
  while i < value.len:
    let c = value[i]
    if c != '%':
      result.add(c)
      inc i
      continue
    if i + 1 >= value.len:
      ok = false
      return
    let s = value[i + 1]
    i += 2
    case s
    of '%': result.add('%')
    of 'U', 'G': result.add("0")
    of 'u', 'g': result.add("root")
    of 'n': result.add(unit)
    of 'N': result.add(stem)
    of 'p', 'P': result.add(u.prefix)
    of 'j', 'J':
      let d = u.prefix.rfind('-')
      result.add(if d >= 0: u.prefix[d + 1 .. ^1] else: u.prefix)
    of 'i', 'I':
      if u.instance.len == 0:
        ok = false
        return
      result.add(u.instance)
    else:
      ok = false
      return
  # An unescaped specifier (%I, %P, %J) differs from the escaped one only
  # where the name holds a "\x.." escape; such a name is not resolved.
  if '\\' in result: ok = false

proc isNumericId(v: string): bool =
  v.len > 0 and v.allCharsInSet(Digits)

proc resolveServiceAccount*(user, group, supplementaryGroups: string;
                            dynamicUser: bool; unitName: string;
                            lookup: AccountLookup): ResolvedAccount =
  ## The account ``unitName`` runs as with these settings (their values
  ## after systemd's last-assignment-wins, unexpanded). See the module
  ## header for the rules.
  var ok: bool
  var u = expandSpecifiers(user.strip(), unitName, ok)
  if not ok:
    result.unknown.add("User=" & user & " (a specifier that does not resolve)")
  var g = expandSpecifiers(group.strip(), unitName, ok)
  if not ok:
    result.unknown.add("Group=" & group & " (a specifier that does not resolve)")
  let parts = unitParts(unitName)
  let unitStem = if parts.instance.len > 0: parts.prefix & "@" & parts.instance
                 else: parts.prefix

  # --- The user.
  proc staticUid(name: string): int =
    if isNumericId(name): return parseInt(name)
    if name == "root": return 0
    when AccountMutation == "account-as-written":
      return UnknownId
    lookup.uidOf(name)
  when AccountMutation == "account-as-written":
    let dynamicUserNow = dynamicUser
  else:
    let dynamicUserNow = dynamicUser and
      staticUid(if u.len > 0: u else: unitStem) == UnknownId
  if dynamicUserNow:
    result.dynamicUser = true
    result.user = if u.len > 0: u else: unitStem
    result.uid = DynamicId
  else:
    let name = if u.len > 0: u elif dynamicUser: unitStem else: "root"
    result.user = name
    result.uid = staticUid(name)
    when AccountMutation == "account-as-written":
      # Round 3's reading: only "", "root" and "0" are root; any other
      # name is someone else, resolved or not.
      if result.uid == UnknownId: result.uid = AllocatedId
    if result.uid == UnknownId:
      result.unknown.add("User=" & name & " (no such account here or in " &
        "the profile)")

  # --- The primary group.
  proc staticGid(name: string): int =
    if isNumericId(name): return parseInt(name)
    if name == "root": return 0
    when AccountMutation == "account-as-written":
      return UnknownId
    lookup.gidOf(name)
  if g.len > 0:
    let gid = staticGid(g)
    result.group = g
    if gid == UnknownId and dynamicUser:
      # A group of that name does not exist: a dynamic one is allocated.
      result.dynamicGroup = true
      result.primaryGid = DynamicId
    else:
      result.primaryGid = gid
      when AccountMutation == "account-as-written":
        if result.primaryGid == UnknownId: result.primaryGid = AllocatedId
      if result.primaryGid == UnknownId:
        result.unknown.add("Group=" & g & " (no such group here or in the " &
          "profile)")
  elif result.dynamicUser:
    # The group is named like the user; a static one of that name is used.
    result.group = result.user
    let gid = staticGid(result.user)
    if gid == UnknownId:
      result.dynamicGroup = true
      result.primaryGid = DynamicId
    else:
      result.primaryGid = gid
  else:
    # The user's primary group.
    if result.uid == 0 and (result.user == "root" or result.user == "0"):
      result.group = "root"
      result.primaryGid = 0
    else:
      var name = result.user
      if isNumericId(name):
        name = if result.uid >= 0: lookup.userOfUid(result.uid) else: ""
      when AccountMutation == "account-as-written":
        result.primaryGid = AllocatedId
      else:
        result.primaryGid =
          if name.len > 0: lookup.primaryGidOf(name) else: UnknownId
      result.group = $result.primaryGid
      if result.primaryGid == UnknownId and result.uid != UnknownId:
        result.unknown.add("the primary group of " & result.user &
          " (not known here or in the profile)")

  # --- Supplementary groups and memberships.
  for w in supplementaryGroups.splitWhitespace():
    var okW: bool
    let name = expandSpecifiers(w, unitName, okW)
    if not okW:
      result.unknown.add("SupplementaryGroups=" & w & " (a specifier that " &
        "does not resolve)")
      continue
    let gid = staticGid(name)
    if gid == UnknownId:
      result.unknown.add("SupplementaryGroups=" & name & " (no such group " &
        "here or in the profile)")
    result.supplementaryGids.add(gid)
  when AccountMutation != "account-as-written":
    if not result.dynamicUser and result.uid != UnknownId:
      var name = result.user
      if isNumericId(name):
        name = if result.uid >= 0: lookup.userOfUid(result.uid) else: ""
      if name.len > 0:
        for gid in lookup.groupsOf(name): result.memberGids.add(gid)

# ---------------------------------------------------------------------------
# The lookup of a host, and of the accounts a profile creates on it.
# ---------------------------------------------------------------------------

proc parseId(v: string): int =
  if isNumericId(v): parseInt(v) else: UnknownId

proc readAccountFile(root, file: string): seq[seq[string]] =
  ## The colon-separated records of ``<root>/etc/<file>``; none when the
  ## file is missing.
  let f = (if root == "/" or root.len == 0: "" else: root.strip(
    leading = false, chars = {'/'})) & "/etc/" & file
  if not fileExists(f): return
  for line in readFile(f).splitLines():
    if line.len == 0 or line[0] == '#': continue
    result.add(line.split(':'))

proc accountLookupOf(passwd, group: seq[seq[string]];
                     p: SystemProfile): AccountLookup =
  ## The lookup over ``passwd`` and ``group`` records (a host's, or none)
  ## and the accounts ``p`` creates; see ``hostAccountLookup``.
  var uids = initTable[string, int]()
  var pgids = initTable[string, int]()
  var gids = initTable[string, int]()
  var members = initTable[string, seq[int]]()
  var names = initTable[int, string]()
  for f in passwd:
    if f.len < 4: continue
    let uid = parseId(f[2])
    if f[0] notin uids: uids[f[0]] = uid
    if f[0] notin pgids: pgids[f[0]] = parseId(f[3])
    if uid >= 0 and uid notin names: names[uid] = f[0]
  for f in group:
    if f.len < 3: continue
    let gid = parseId(f[2])
    if f[0] notin gids: gids[f[0]] = gid
    if f.len >= 4:
      for m in f[3].split(','):
        if m.len > 0: members.mgetOrPut(m, @[]).add(gid)
  # The profile's accounts, after the host's (which win).
  var hostUsers = initHashSet[string]()
  for k in uids.keys: hostUsers.incl(k)
  var hostGroups = initHashSet[string]()
  for k in gids.keys: hostGroups.incl(k)
  for r in p.resources:
    case r.kind
    of srkLinuxSysusersEntry:
      let id = r.seId.strip()
      if r.seKind == "group":
        if r.seName notin hostGroups:
          gids[r.seName] = if id.len == 0 or id == "-": AllocatedId
                           else: parseId(id)
      elif r.seName notin hostUsers:
        # sysusers.d(5): "-", a uid, "uid:gid" or "uid:group", or a path.
        if id.len == 0 or id == "-":
          uids[r.seName] = AllocatedId
          pgids[r.seName] = AllocatedId
        elif ':' in id:
          let s = id.split(':', maxsplit = 1)
          uids[r.seName] = parseId(s[0])
          pgids[r.seName] = if isNumericId(s[1]): parseInt(s[1])
                            elif s[1] == "root": 0
                            else: gids.getOrDefault(s[1], UnknownId)
        else:
          uids[r.seName] = parseId(id)
          pgids[r.seName] = parseId(id)
        if r.seName notin hostGroups and r.seName notin gids:
          gids[r.seName] = pgids[r.seName]
        if uids[r.seName] >= 0: names[uids[r.seName]] = r.seName
    of srkPasswdGroup:
      if r.pgName notin hostGroups:
        gids[r.pgName] = if r.pgGid.len == 0: AllocatedId else: parseId(r.pgGid)
      for m in r.pgMembers:
        members.mgetOrPut(m, @[]).add(gids.getOrDefault(r.pgName, UnknownId))
    of srkPasswdUser:
      if r.puName notin hostUsers:
        uids[r.puName] = AllocatedId
        pgids[r.puName] = AllocatedId
        if r.puName notin gids: gids[r.puName] = AllocatedId
      for gname in r.puGroups:
        let gid = if gname == "root": 0
                  elif isNumericId(gname): parseInt(gname)
                  else: gids.getOrDefault(gname, UnknownId)
        members.mgetOrPut(r.puName, @[]).add(gid)
    else: discard
  result.uidOf = proc (name: string): int = uids.getOrDefault(name, UnknownId)
  result.primaryGidOf = proc (name: string): int =
    pgids.getOrDefault(name, UnknownId)
  result.gidOf = proc (name: string): int = gids.getOrDefault(name, UnknownId)
  result.groupsOf = proc (name: string): seq[int] =
    members.getOrDefault(name, @[])
  result.userOfUid = proc (uid: int): string = names.getOrDefault(uid, "")

proc hostAccountLookup*(root = "/"; p: SystemProfile = SystemProfile()): AccountLookup =
  ## The accounts of ``<root>/etc/passwd`` and ``<root>/etc/group``, and
  ## those the profile ``p`` creates (``passwd.user``, ``passwd.group``,
  ## ``linux.sysusersEntry``): an account already on the host keeps its ids
  ## (neither ``useradd`` nor ``systemd-sysusers`` changes one), a new one
  ## gets its pinned id or ``AllocatedId``. Memberships a profile adds
  ## (``passwd.user`` ``groups``, ``passwd.group`` ``members``) are added to
  ## the host's.
  accountLookupOf(readAccountFile(root, "passwd"),
                  readAccountFile(root, "group"), p)

proc profileAccountLookup*(p: SystemProfile): AccountLookup =
  ## Only the accounts the profile ``p`` creates, with the ids and
  ## memberships ``hostAccountLookup`` would give them on a host that has
  ## none of its own: no host database is read, so a check made at parse
  ## time with it decides the same on every host. ``root`` still resolves
  ## (``resolveServiceAccount`` knows it by name), and any other account
  ## the profile does not create is ``UnknownId``.
  accountLookupOf(@[], @[], p)
