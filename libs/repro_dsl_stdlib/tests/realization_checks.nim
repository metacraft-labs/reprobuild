## Shared checks for the stdlib's archive realizations (GM4b).
##
## The bulk-harvest tests (M67, M68, M8) used to validate ``<tool>Catalog``
## ``VersionedProvisioning`` literals. Those records are now ``tarball``
## realizations of the packages' canonical definitions, so the same
## properties are asserted on what a recipe and a home profile actually
## select from: the records ``profileToolUse(name)`` projects — the
## interface-extraction projection over the definitions the engine links.
##
## ``realizationProblems`` returns one line per defect; an empty result is a
## well-formed set of realizations. No mocks: real definitions, real
## projection, the real selection and the real realizer-routing predicate.

import std/[options, strutils]

import repro_interface_artifacts
import repro_dsl_stdlib/packages_schema
import repro_home_apply/package_catalog

export repro_interface_artifacts, package_catalog

proc tarballRecordsOf*(name: string): seq[InterfaceTarballProvisioning] =
  profileToolUse(name).useDef.tarballProvisioning

proc isHexOfLen(s: string; n: int): bool =
  if s.len != n: return false
  for ch in s:
    if ch notin {'0'..'9', 'a'..'f', 'A'..'F'}:
      return false
  true

proc recordProblems*(name: string; r: InterfaceTarballProvisioning):
    seq[string] =
  ## Everything a realizer needs from one record, checked as the realizers
  ## read it.
  let at = name & " " & r.url & ": "
  if r.url.len == 0: result.add(at & "empty url")
  var digests = 0
  if r.sha256.len > 0:
    inc digests
    if not isHexOfLen(r.sha256, 64): result.add(at & "malformed sha256")
  if r.detail.sha512.len > 0:
    inc digests
    if not isHexOfLen(r.detail.sha512, 128): result.add(at & "malformed sha512")
  if r.detail.sha1.len > 0:
    inc digests
    if not isHexOfLen(r.detail.sha1, 40): result.add(at & "malformed sha1")
  if digests != 1:
    result.add(at & "expected exactly one digest, found " & $digests)
  if r.executablePath.len == 0: result.add(at & "no executablePath")
  if r.detail.version.len == 0: result.add(at & "no version")
  let arm = tarballArm(r)
  if not arm.ok: result.add(at & "unreadable coordinate: " & arm.problem)
  if not parseInstallMethodToken(r.detail.installMethod).ok:
    result.add(at & "unknown installMethod " & r.detail.installMethod)
  for env in r.detail.env:
    if env.find('=') <= 0: result.add(at & "env not NAME=value: " & env)
  for encoded in r.detail.preInstall:
    try: discard decodePreInstallAction(encoded)
    except ValueError as e: result.add(at & "preInstall: " & e.msg)
  for encoded in r.detail.launcherEmit:
    try: discard decodeLauncherEmitSpec(encoded)
    except ValueError as e: result.add(at & "launcherEmit: " & e.msg)
  # Some realizer performs everything the record asks for; an installer-
  # route record must also project into the home archive realizer's input.
  try:
    if archiveRouteFor(name, r) == arInstaller:
      discard archiveRealizationOf(name, r)
  except ValueError as e:
    result.add(at & "no realizer: " & e.msg)

proc realizationProblems*(name: string): seq[string] =
  let records = tarballRecordsOf(name)
  if records.len == 0:
    return @[name & ": no tarball realization"]
  for r in records:
    result.add(recordProblems(name, r))

proc unpinnedSelection*(name: string; cpu: PlatformCpu; os: PlatformOs):
    Option[InterfaceTarballProvisioning] =
  ## What an unpinned reference selects among ``name``'s archives for the
  ## target — the "default version" of the retired catalog.
  let records = tarballRecordsOf(name)
  let choice = selectTarballRecord(records,
    realizationTargetFor(cpu, os, baselineMicroarchLevel(cpu)))
  if choice.status == kcSelected:
    some(records[choice.index])
  else:
    none(InterfaceTarballProvisioning)
