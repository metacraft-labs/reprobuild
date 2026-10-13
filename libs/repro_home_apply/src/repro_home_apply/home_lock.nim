## The home-profile lock (``home.lock`` beside ``home.nim``).
##
## GM4b, Provisioning-Contributions.md §"Profile Package References" → "The
## home-profile lock". It serialises what ``repro home apply`` SELECTED for
## each package reference — kind, contributor, version and realization lock
## identity — together with the selection policy that produced the
## selections, one record per target platform. "Curator snapshots may set
## defaults, but they must serialize the resulting selection into the lock"
## (§ Locks And Snapshots): ``adapterPreference:`` is that curator policy, so
## the lock records the policy and every selection made under it.
##
## Reading rules (``lockedPin``):
##
## * a recorded NON-ambient selection pins the next resolution of the same
##   package for the same target, provided the target's recorded policy still
##   equals the profile's current policy. The pin is the selection's kind,
##   contributor AND lock identity (``contributorLockIdentity`` form, the
##   identity ``uses:`` records): exactly the recorded realization is
##   eligible, so a realization added to the definition later is not
##   selected, and a withdrawn one fails asking for ``--relock`` instead of
##   being replaced silently;
## * an ambient selection (PATH, the host's Scoop inventory) is recorded but
##   never pinned — it is not reproducible by construction;
## * a target whose recorded policy differs from the current one is
##   re-derived: editing ``adapterPreference:`` is an explicit change of
##   selection basis. So is a record whose ``version`` differs from the
##   reference's exact version pin (``package(jdk, "21.0.5")`` edited to
##   another version);
## * a record with an empty ``lock_identity`` (a hand-written record, or one
##   from before identities were pinned) pins kind and contributor only; the
##   next apply re-records it with the identity it selected, so the lock
##   pins it from then on. ``--plan`` does not write that upgrade.
##
## On-disk format: the TOML subset of ``repro_lock/toml_subset`` (scalar keys
## and an array of inline tables per target), schema
## ``reprobuild.home-profile-lock.v1``:
##
## .. code-block:: toml
##   schema = "reprobuild.home-profile-lock.v1"
##
##   [target]
##   name = "aarch64-macos"
##   policy = "tarball,nix,scoop,path"
##   policy_source = "default"
##   packages = [{ name = "just", kind = "tarball", contributor = "", version = "1.51.0", lock_identity = "...", ambient = "false" }]
##
## A ``[target]`` header starts each record; the reader is strict about the
## schema and about a record missing its name or policy, and refuses an
## unknown realization kind rather than skipping it.

import std/[algorithm, options, os, strutils, tables]

from repro_core/paths import extendedPath
import repro_lock/toml_subset
import repro_tool_profiles/realization_selection

const
  HomeProfileLockSchemaV1* = "reprobuild.home-profile-lock.v1"
  HomeProfileLockFileName* = "home.lock"

type
  HomeLockSelection* = object
    package*: string
    kind*: RealizationKind
    contributor*: string
    version*: string
    lockIdentity*: string
    ambient*: bool

  HomeLockTarget* = object
    target*: string
      ## ``describeTarget`` spelling, e.g. ``aarch64-macos``.
    policy*: SelectionPolicy
    policySource*: string
      ## ``adapterPreference.<os>`` or ``default``.
    packages*: seq[HomeLockSelection]

  HomeProfileLock* = object
    schema*: string
    targets*: seq[HomeLockTarget]

  EHomeLockParse* = object of ValueError

  HomeLockPin* = object
    ## What a lock record imposes on the next resolution of its package.
    kind*: RealizationKind
    contributor*: string
    version*: string
      ## The recorded version, for diagnostics ("" when the realization
      ## names none).
    lockIdentity*: string
      ## The recorded lock identity; "" for a record that carries none, which
      ## then pins kind and contributor only.

proc homeProfileLockPath*(profileDir: string): string =
  profileDir / HomeProfileLockFileName

proc policyText(policy: SelectionPolicy): string =
  var parts: seq[string] = @[]
  for kind in policy:
    parts.add($kind)
  parts.join(",")

proc parsePolicyText(text: string): SelectionPolicy =
  for raw in text.split(','):
    let token = raw.strip()
    if token.len == 0:
      continue
    let parsed = parseRealizationKind(token)
    if not parsed.ok:
      raise newException(EHomeLockParse,
        "home-profile lock: unknown realization kind '" & token &
        "' in policy")
    result.add(parsed.kind)

proc serializeHomeProfileLock*(lock: HomeProfileLock): string =
  ## Canonical text: targets sorted by name, packages sorted by name, so two
  ## applies that select the same things write the same bytes.
  result = "schema = \"" & tomlEscape(HomeProfileLockSchemaV1) & "\"\n"
  var targets = lock.targets
  targets.sort(proc(a, b: HomeLockTarget): int = cmp(a.target, b.target))
  for t in targets:
    result.add("\n[target]\n")
    result.add("name = \"" & tomlEscape(t.target) & "\"\n")
    result.add("policy = \"" & tomlEscape(policyText(t.policy)) & "\"\n")
    result.add("policy_source = \"" & tomlEscape(t.policySource) & "\"\n")
    var packages = t.packages
    packages.sort(proc(a, b: HomeLockSelection): int = cmp(a.package, b.package))
    result.add("packages = [")
    for i, p in packages:
      if i > 0:
        result.add(",")
      result.add("\n  { name = \"" & tomlEscape(p.package) & "\"" &
        ", kind = \"" & $p.kind & "\"" &
        ", contributor = \"" & tomlEscape(p.contributor) & "\"" &
        ", version = \"" & tomlEscape(p.version) & "\"" &
        ", lock_identity = \"" & tomlEscape(p.lockIdentity) & "\"" &
        ", ambient = \"" & $p.ambient & "\" }")
    if packages.len > 0:
      result.add("\n")
    result.add("]\n")

proc parseHomeProfileLock*(content: string): HomeProfileLock =
  ## Inverse of ``serializeHomeProfileLock``. Raises ``EHomeLockParse`` on a
  ## missing or foreign schema, a record without a name or policy, or an
  ## unknown kind — a lock this reader cannot interpret is refused, never
  ## half-read.
  var sawSchema = false
  var current: HomeLockTarget
  var inTarget = false
  var sawPolicy = false
  proc finish(lock: var HomeProfileLock; t: HomeLockTarget; inTarget,
              sawPolicy: bool) =
    if not inTarget:
      return
    if t.target.len == 0:
      raise newException(EHomeLockParse,
        "home-profile lock: a [target] record has no name")
    if not sawPolicy:
      raise newException(EHomeLockParse,
        "home-profile lock: target '" & t.target & "' records no policy")
    lock.targets.add(t)
  # Logical lines: an inline-table array spans several physical lines, so a
  # ``packages = [`` line is joined with its continuation up to the ``]``.
  var lines: seq[string] = @[]
  var pending = ""
  for raw in content.splitLines():
    let line = raw.strip()
    if pending.len > 0:
      pending.add(" " & line)
      if line.endsWith("]"):
        lines.add(pending)
        pending = ""
      continue
    if line.startsWith("packages") and line.endsWith("[") :
      pending = line
      continue
    lines.add(line)
  if pending.len > 0:
    raise newException(EHomeLockParse,
      "home-profile lock: unterminated packages array")
  for line in lines:
    if line.len == 0 or line.startsWith("#"):
      continue
    if line == "[target]":
      finish(result, current, inTarget, sawPolicy)
      current = HomeLockTarget()
      inTarget = true
      sawPolicy = false
      continue
    if line.startsWith("["):
      raise newException(EHomeLockParse,
        "home-profile lock: unknown table " & line)
    let eq = line.find('=')
    if eq <= 0:
      raise newException(EHomeLockParse,
        "home-profile lock: unreadable line " & line.escape())
    let key = line[0 ..< eq].strip()
    let rhs = line[eq + 1 .. ^1].strip()
    if not inTarget:
      if key == "schema":
        result.schema = parseScalarString(rhs)
        sawSchema = true
      continue
    case key
    of "name": current.target = parseScalarString(rhs)
    of "policy":
      current.policy = parsePolicyText(parseScalarString(rhs))
      sawPolicy = true
    of "policy_source": current.policySource = parseScalarString(rhs)
    of "packages":
      for fields in inlineTables(rhs):
        let kind = parseRealizationKind(fields.getOrDefault("kind", ""))
        if not kind.ok:
          raise newException(EHomeLockParse,
            "home-profile lock: unknown realization kind '" &
            fields.getOrDefault("kind", "") & "' for package '" &
            fields.getOrDefault("name", "") & "'")
        current.packages.add(HomeLockSelection(
          package: fields.getOrDefault("name", ""),
          kind: kind.kind,
          contributor: fields.getOrDefault("contributor", ""),
          version: fields.getOrDefault("version", ""),
          lockIdentity: fields.getOrDefault("lock_identity", ""),
          ambient: fields.getOrDefault("ambient", "false") == "true"))
    else:
      discard  # forward-compatible within v1, as repro_lock's reader is
  finish(result, current, inTarget, sawPolicy)
  if not sawSchema or result.schema != HomeProfileLockSchemaV1:
    raise newException(EHomeLockParse,
      "home-profile lock: expected schema " & HomeProfileLockSchemaV1 &
      ", got '" & result.schema & "'")

proc readHomeProfileLock*(path: string): Option[HomeProfileLock] =
  ## ``none`` when no lock exists; raises on a lock that exists and does not
  ## parse (a broken lock is not the same as no lock).
  if not fileExists(extendedPath(path)):
    return none(HomeProfileLock)
  some(parseHomeProfileLock(readFile(extendedPath(path))))

proc writeHomeProfileLock*(path: string; lock: HomeProfileLock) =
  ## Write-then-rename so a crash never leaves a truncated lock.
  let tmp = path & ".tmp"
  writeFile(extendedPath(tmp), serializeHomeProfileLock(lock))
  moveFile(extendedPath(tmp), extendedPath(path))

proc lockedTarget*(lock: HomeProfileLock; target: string):
    Option[HomeLockTarget] =
  for t in lock.targets:
    if t.target == target:
      return some(t)
  none(HomeLockTarget)

proc lockedPin*(lockTarget: Option[HomeLockTarget]; packageId: string;
                policy: SelectionPolicy; requestedVersion = ""):
    Option[HomeLockPin] =
  ## The pin a lock record imposes on ``packageId``: its kind, contributor
  ## and lock identity, when the record exists, is not ambient, was made
  ## under ``policy``, and — when the reference pins an exact
  ## ``requestedVersion`` — recorded that version.
  if lockTarget.isNone or lockTarget.get.policy != policy:
    return none(HomeLockPin)
  for p in lockTarget.get.packages:
    if p.package == packageId and not p.ambient:
      if requestedVersion.len > 0 and p.version != requestedVersion:
        return none(HomeLockPin)
      return some(HomeLockPin(kind: p.kind, contributor: p.contributor,
        version: p.version, lockIdentity: p.lockIdentity))
  none(HomeLockPin)

proc withTarget*(lock: HomeProfileLock; record: HomeLockTarget):
    HomeProfileLock =
  ## ``lock`` with ``record`` replacing the record of the same target; the
  ## records of other targets are carried forward unchanged.
  result.schema = HomeProfileLockSchemaV1
  for t in lock.targets:
    if t.target != record.target:
      result.targets.add(t)
  result.targets.add(record)
