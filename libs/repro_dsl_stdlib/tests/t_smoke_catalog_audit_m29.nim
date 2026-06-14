## M29 Part B verification: provisioning catalog audit.
##
## Walks ``libs/repro_dsl_stdlib/src/repro_dsl_stdlib/packages/*.nim`` and
## asserts:
##   1. Every M29-flagged "missing" entry now exists. This is the
##      provisioning-coverage gate — if a future cleanup accidentally
##      deletes one of these the harness fails before the runtime
##      ``ModuleNotFoundError`` / ``cargo: command not found`` surfaces
##      at a downstream M9 fixture.
##   2. Every catalog file mentions a ``nixPackage "nixpkgs#`` selector
##      AND a ``nixpkgsRev`` pin AND a ``nixpkgsNarHash`` pin (the
##      provisioning shape every existing entry already follows). This
##      keeps the Nix CI gate's parser (``scripts/verify-nix-catalog-attrs.sh``)
##      able to extract every entry's selector + rev tuple.
##   3. Every catalog file's nixpkgsRev + NarHash matches the canonical
##      pin used by the rest of the toolchain — so an entry isn't
##      pinned to a divergent revision by accident. (This is a design
##      decision: the catalog is treated as a single coherent snapshot;
##      future Ms can graduate to per-package pins by carving an
##      exception in this gate.)

import std/[os, strutils, unittest]

const
  PackagesRel = "libs" / "repro_dsl_stdlib" / "src" / "repro_dsl_stdlib" /
    "packages"
  CanonicalNixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8"
  CanonicalNixpkgsNarHash =
    "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="

  # M29 deliverable (per
  # Standard-Provider-Implementation.milestones.org §M29): catalog entries
  # promoted from "missing" to "present" in this milestone.
  M29NewEntries = [
    "autoconf",
    "automake",
    "bun",
    "maturin",
    "npm",
    "pnpm",
    "pyproject_hooks",
  ]

proc repoRoot(): string =
  ## Locate the reprobuild repo root by walking up from this test
  ## file's location until we hit the directory that contains both
  ## ``libs/`` and ``apps/``. The test file lives at
  ## ``libs/repro_dsl_stdlib/tests/`` so ``../../..`` is the answer on
  ## the canonical layout, but resolve dynamically to stay robust against
  ## relocations.
  result = currentSourcePath.parentDir
  for _ in 0 ..< 8:
    if dirExists(result / "libs") and dirExists(result / "apps"):
      return result
    result = result.parentDir
  raiseAssert("could not locate reprobuild repo root from " & currentSourcePath)

proc packagesDir(): string =
  repoRoot() / PackagesRel

const AuditExemptions = [
  # ReproOS-Generations-And-Foreign-Packages C1/C2: the Tier-3
  # foreign-distro adapter modules live alongside the Tier-1 / Tier-2
  # catalog files but do NOT declare a per-package provisioning shape:
  # they are library code (DSL constructors + shared codec + apt-index
  # parser). The realize pipeline consumes the per-package metadata
  # from ``recipes/catalog/foreign/<distro>/<package>.json`` files the
  # C2 harvester emits, not from these .nim helpers. Exempt them
  # explicitly so the M29 audit doesn't falsely flag them as missing
  # provisioning.
  "foreign_common",
  "foreign_apt",
  "foreign_dnf",
  "foreign_pacman",
  "apt_index",
  # Bootstrap-And-Self-Build B4: ``python_unittest_runner`` is a
  # TestRunner-adapter wrapper; its provisioning is inherited from
  # ``python3.nim`` (the engine resolves the runner's execution path
  # via the python3 profile). The M29 audit predates B4 and was not
  # updated when the adapter landed without its own provisioning
  # shape. Exempt it here rather than retroactively contort the
  # adapter to declare a fake one.
  "python_unittest_runner",
]

iterator catalogFiles(): tuple[name, path: string] =
  for kind, path in walkDir(packagesDir()):
    if kind == pcFile and path.endsWith(".nim"):
      let name = splitFile(path).name
      if name in AuditExemptions: continue
      yield (name: name, path: path)

proc readCatalog(path: string): string =
  readFile(path)

suite "M29 Part B — catalog audit":

  test "all M29-flagged missing entries now exist":
    let dir = packagesDir()
    check dirExists(dir)
    for entry in M29NewEntries:
      let path = dir / (entry & ".nim")
      checkpoint "entry: " & entry
      check fileExists(path)

  test "every catalog entry declares a provisioning shape":
    # Every entry must declare ONE of:
    #   * ``nixPackage`` (the M21/M29 nix-first shape — pinned to either
    #     a ``"nixpkgs#..."`` selector OR a local ``expressionFile``);
    #   * ``VersionedProvisioning`` (the M63/M67 catalog shape harvested
    #     from Scoop bucket manifests; the M64+ ``cakBuiltin`` adapter
    #     consumes it on Windows hosts).
    # Either shape is valid provisioning; the audit just requires
    # SOMETHING is there. (M67 introduced files like ``maven.nim`` /
    # ``gradle.nim`` / ``zig.nim`` that ship ONLY the M63 catalog
    # because Maven / Gradle / Zig have no existing Nix entry to
    # co-host. ``ruby.nim`` carries both — see the hand-merge note in
    # that file.)
    var seen = 0
    for entry in catalogFiles():
      let body = readCatalog(entry.path)
      checkpoint "entry: " & entry.name & " (" & entry.path & ")"
      let hasNixPackage = "nixPackage " in body
      let hasVersionedProvisioning = "VersionedProvisioning(" in body or
        "initVersionedProvisioning(" in body
      check hasNixPackage or hasVersionedProvisioning
      inc seen
    # Sanity: the catalog can't have shrunk to nothing.
    check seen >= 60

  test "every nixpkgs# entry uses the canonical nixpkgs pin":
    # Catalog hygiene: every entry that uses the ``nixpkgs#`` selector
    # form pins to the same nixpkgs rev + hash so the Nix CI gate can
    # probe them against a single flake input. A divergence usually
    # means a hand-edited file forgot to bump in lockstep with the rest
    # of the catalog. Entries pinned to a local expression
    # (``expressionFile = ...``) are exempt — they're self-contained.
    for entry in catalogFiles():
      let body = readCatalog(entry.path)
      if "\"nixpkgs#" notin body:
        # Local expression (stylus-style) — skip the rev pin check.
        continue
      checkpoint "entry: " & entry.name & " (" & entry.path & ")"
      check "nixpkgsRev = \"" & CanonicalNixpkgsRev & "\"" in body
      check "nixpkgsNarHash = \"" & CanonicalNixpkgsNarHash & "\"" in body

  test "no duplicate catalog entries (case-folded basename)":
    var seen: seq[string] = @[]
    for entry in catalogFiles():
      let key = entry.name.toLowerAscii
      checkpoint "entry: " & entry.name
      check key notin seen
      seen.add(key)
