## M69 — synthesize PATH + per-tool env var resources from realized
## package records.
##
## Step 5 of the M69 apply flow (per the spec): "bind PATH / env vars
## via the existing ``repro_home_resources`` machinery —
## ``executables:`` → ``env.userPath``, per-tool ``env:`` block →
## ``env.userVariable``". This module owns that synthesis: it takes the
## ``RealizedRecord`` sequence the M64/M65 dispatcher produced and
## returns one ``Resource`` per binding the apply pipeline must
## reconcile.
##
## Address conventions (stable across re-applies so the lifecycle
## planner's cache-hit detection works on the second apply):
##
##   * ``home.package.<id>.bin`` — the ``env.userPath`` resource
##     contributing the realized prefix's bin directories to the user
##     PATH.
##   * ``home.package.<id>.env.<VAR>`` — one ``env.userVariable``
##     resource per ``env:`` entry the catalog declared (with
##     ``${prefix}`` already substituted by the cakBuiltin realizer).
##
## The address namespace is reserved for M69 synthesis; profile-author-
## written addresses do NOT collide because every M69 address begins
## with ``home.package.``.

import std/[os, sets]

import repro_home_resources

import ./realize

type
  EnvBindingPlan* = object
    ## Bundle of synthesized resources + the per-package bin dir list.
    ## The pipeline injects ``resources`` into ``desiredResources`` and
    ## records ``binDirs`` for the manifest writer / launcher loop.
    resources*: seq[Resource]
    binDirs*: seq[string]
    envVariables*: seq[tuple[name, value: string]]

proc prefixBinDirs*(record: RealizedRecord): seq[string] =
  ## Walk the realized record's exported executables and return the
  ## ABSOLUTE bin directories (one entry per unique parent dir).
  ## Order: the catalog's declared ``bin_relpath`` order, deduplicated
  ## first-occurrence-wins.
  var seen: HashSet[string]
  if record.prefixAbsolutePath.len == 0:
    return
  # The realized record's `resolvedExecutablePath` is the first
  # bin_relpath joined with the prefix. We get every bin dir by
  # walking the prefix tree the realizer placed under
  # `prefixAbsolutePath` — but the cheap reliable signal is the
  # resolved executable + the M64 builtin adapter's bin_relpath
  # array which is NOT directly exposed on the record. Fall back to
  # treating the parent of `resolvedExecutablePath` as the canonical
  # bin dir; downstream code that wants every bin dir derives it
  # from the receipt (out of scope for M69).
  if record.resolvedExecutablePath.len > 0:
    let dir = record.resolvedExecutablePath.parentDir
    if dir.len > 0 and dir notin seen:
      seen.incl(dir)
      result.add(dir)

proc envUserPathResource*(packageId: string; binDirs: seq[string]):
    Resource =
  ## Build an ``env.userPath`` resource contributing ``binDirs`` to
  ## the user PATH. The address encodes the package id so a re-apply
  ## with the same package id cache-hits at the lifecycle planner.
  ##
  ## POSIX shell rc files carry MANY per-package PATH blocks side-by-
  ## side; each home-package owns its own sentinel-delimited slice.
  ## The block id is derived from the resource address (which is
  ## already unique per package — ``home.package.<id>.bin``) so the
  ## rc file ends up with one block per package, not one block
  ## shared across all of them.
  let address = "home.package." & packageId & ".bin"
  result = Resource(
    kind: rkEnvUserPath,
    address: address,
    lifecyclePolicy: lpDefault,
    pathEntries: binDirs,
    pathHostFilePath: defaultUserPathHostFile(),
    pathBlockId: "repro-home-userpath:" & address)

proc envUserVariableResource*(packageId, varName, value: string):
    Resource =
  ## Build an ``env.userVariable`` resource for one per-tool env entry
  ## (e.g. ``JAVA_HOME = <prefix>``). The address embeds the package
  ## id AND the env var name so two tools never collide on the same
  ## generic address (``home.package.jdk.env.JAVA_HOME`` is distinct
  ## from a hypothetical ``home.package.openjdk.env.JAVA_HOME``).
  ## ``${prefix}`` substitution happened in the M64 realizer; the
  ## value passed here is already concrete.
  var payload: RegistryValuePayload
  payload.kind = rvkString
  payload.bytes = encodeString(value)
  result = Resource(
    kind: rkEnvUserVariable,
    address: "home.package." & packageId & ".env." & varName,
    lifecyclePolicy: lpDefault,
    envVarName: varName,
    envVarPayload: payload)

proc planEnvBindings*(realized: seq[RealizedRecord]): EnvBindingPlan =
  ## Synthesize the M69 PATH + env var resources from a realized-
  ## package sequence. The returned ``resources`` list is in a stable
  ## order: per-package PATH resource first, then the per-package env
  ## vars sorted by name (matching the M64 builtin adapter's
  ## ``envBindings`` ordering which is already key-sorted).
  for r in realized:
    let binDirs = prefixBinDirs(r)
    if binDirs.len > 0:
      result.resources.add(envUserPathResource(r.packageId, binDirs))
      for d in binDirs:
        result.binDirs.add(d)
    for binding in r.envBindings:
      result.resources.add(envUserVariableResource(r.packageId,
        binding.name, binding.value))
      result.envVariables.add(binding)
