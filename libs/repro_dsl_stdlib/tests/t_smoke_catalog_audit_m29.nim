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

# The pin values come from the module the catalog itself imports. This test
# used to carry its own copy of both strings — a third copy alongside the 274
# in the entries — which could go stale against the catalog and still report
# green. There is now exactly one declaration, and this suite checks the
# entries against it rather than against a duplicate of it.
import repro_dsl_stdlib/nixpkgs_pin

const
  PackagesRel = "libs" / "repro_dsl_stdlib" / "src" / "repro_dsl_stdlib" /
    "packages"

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
  # D2 / NDE0-A: more foreign-distro library code that lives alongside
  # the catalog but carries no per-package provisioning shape — the
  # ``dnf`` / ``pacman`` repo-index parsers (counterparts of the
  # already-exempt ``apt_index``) and the ``apt-jammy`` native adapter.
  # Their realize metadata comes from the C2 harvester's per-package
  # JSON, not from these .nim helpers, exactly like the entries above.
  "dnf_index",
  "pacman_index",
  "apt_jammy",
  # Bootstrap-And-Self-Build B4: ``python_unittest_runner`` is a
  # TestRunner-adapter wrapper; its provisioning is inherited from
  # ``python3.nim`` (the engine resolves the runner's execution path
  # via the python3 profile). The M29 audit predates B4 and was not
  # updated when the adapter landed without its own provisioning
  # shape. Exempt it here rather than retroactively contort the
  # adapter to declare a fake one.
  "python_unittest_runner",
  # M9.R.10a: stdlib aggregator modules. They re-export concrete package
  # stubs that carry provisioning, but do not represent standalone packages.
  "system_tools",
  "kf6_qt6_modules",
]

const CanonicalPinExemptions = [
  # M9.R.16.1/16.2: ``accountsservice`` is deliberately pinned to
  # nixpkgs release-24.11 tip (``5ab036a8...``) instead of the canonical
  # rolling rev (``addf7cf...``). The rolling rev ships accountsservice
  # built against glib 2.84+, which exports ``g_variant_builder_init_static``;
  # the ``glib2Source`` from-source recipe is pinned at 2.82.5 and does NOT
  # provide that symbol, so linking ``daemon/gdm-session-worker`` against the
  # rolling-rev accountsservice fails with ``undefined reference to
  # 'g_variant_builder_init_static'``. This is the "graduate to per-package
  # pins by carving an exception in this gate" path the suite header
  # anticipates: a single coherent snapshot for the rest of the catalog,
  # with this one ABI-driven divergence documented + exempted explicitly.
  "accountsservice",
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

  test "every nixpkgs# entry references the canonical pin, not a copy of it":
    # Catalog hygiene: every entry that uses the ``nixpkgs#`` selector form
    # resolves against the same nixpkgs snapshot, so the Nix CI gate can probe
    # the whole catalog against a single flake input. Entries pinned to a local
    # expression (``expressionFile = ...``) are exempt — they're self-contained.
    #
    # This check used to compare 274 pasted copies of two strings against the
    # expected literals, because the DSL could not accept a `const` in a
    # provisioning setter. It can now, and the entries reference
    # `CanonicalNixpkgsRev` / `CanonicalNixpkgsNarHash` from
    # ``repro_dsl_stdlib/nixpkgs_pin``.
    #
    # So the question this test asks has changed, and got smaller. It is no
    # longer "are these 274 strings still equal to each other" — that is now
    # unrepresentable, which is the whole point. It is "does every entry go
    # through the shared const", i.e. has someone re-introduced a literal.
    # A pasted literal is the regression; catching it early is what keeps the
    # guarantee structural rather than conventional.
    for entry in catalogFiles():
      let body = readCatalog(entry.path)
      if "\"nixpkgs#" notin body:
        # Local expression (stylus-style) — skip the rev pin check.
        continue
      if entry.name in CanonicalPinExemptions:
        # Graduated per-package pin (see CanonicalPinExemptions) — a
        # documented, ABI-driven divergence from the coherent snapshot. These
        # write their own literals on purpose, so they are exempt from the
        # must-reference-the-const rule too.
        continue
      checkpoint "entry: " & entry.name & " (" & entry.path & ")"
      check "nixpkgsRev = CanonicalNixpkgsRev" in body
      check "nixpkgsNarHash = CanonicalNixpkgsNarHash" in body
      # The literal must be GONE, not merely accompanied by the const. A file
      # carrying both would drift silently the next time the pin is bumped —
      # exactly the failure this suite exists to prevent.
      check "nixpkgsRev = \"" & CanonicalNixpkgsRev & "\"" notin body
      check "nixpkgsNarHash = \"" & CanonicalNixpkgsNarHash & "\"" notin body

  test "the shared pin module holds well-formed values":
    # Cheap shape check on the single declaration everything now depends on.
    # A truncated rev or a narHash missing its algorithm prefix would fail at
    # realization with a hash error, far from the edit that caused it.
    check CanonicalNixpkgsRev.len == 40
    check CanonicalNixpkgsRev.allCharsInSet(HexDigits)
    check CanonicalNixpkgsNarHash.startsWith("sha256-")

  test "no duplicate catalog entries (case-folded basename)":
    var seen: seq[string] = @[]
    for entry in catalogFiles():
      let key = entry.name.toLowerAscii
      checkpoint "entry: " & entry.name
      check key notin seen
      seen.add(key)
