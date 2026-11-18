## The one reading of a ``REPRO_VARIANTS`` value: ``name=value`` entries,
## comma separated, where a name assigned more than once takes its LAST
## assignment.
##
## ``repro build --variant targetTriple=A --target=B`` writes
## ``targetTriple=A,targetTriple=B`` (``--target`` is appended after every
## ``--variant``), and ``--release --debug`` writes ``buildType`` twice in
## command-line order. Every entry is a ``prSet`` contribution, and at equal
## priority a scalar's last write wins (Configurable-System.md §"Priorities
## And Contributions"; CLI/build.md §"Cross Targets: `--target`"). The solver
## is fed only the last contribution per name
## (``repro_dsl_stdlib/configurables/variants.addPendingCliOverride``), so
## every other reader -- the install mirror's target tag, the object check,
## the cache keys that fold the assignments in -- must reduce the same way or
## it describes a different build from the one that ran (reprobuild-pm issue
## ``2026-11-17-two-readers-of-repro-variants-disagree-on-a-repeated-target-triple``).

import std/[algorithm, strutils]

proc entryName(entry: string): string =
  ## The name of a stripped entry, or the whole entry when it has no ``=``
  ## (such an entry is kept as-is by the canonical form, keyed by itself).
  let eq = entry.find('=')
  if eq <= 0: entry else: entry[0 ..< eq].strip()

proc lastVariantAssignment*(raw, name: string): string =
  ## The value of the last ``name=`` entry in ``raw``, stripped, or "" when
  ## ``name`` is not assigned.
  result = ""
  for item in raw.split(','):
    let kv = item.split('=', 1)
    if kv.len == 2 and kv[0].strip() == name:
      result = kv[1].strip()

proc canonicalVariantAssignmentsOf*(raw: string): string =
  ## ``raw`` reduced to the assignments in force -- the last entry for each
  ## name -- then sorted and comma-joined. For a value that assigns no name
  ## twice this is the sorted, de-duplicated list of entries it always was,
  ## so existing cache keys do not move; for one that does, the key names the
  ## value the build used, and ``buildType=release,buildType=debug`` and
  ## ``buildType=debug,buildType=release`` no longer share a key.
  var parts: seq[string] = @[]
  for item in raw.split(','):
    let s = item.strip()
    if s.len == 0:
      continue
    let name = entryName(s)
    var i = 0
    while i < parts.len:
      if entryName(parts[i]) == name: parts.delete(i)
      else: inc i
    parts.add(s)
  parts.sort()
  parts.join(",")
