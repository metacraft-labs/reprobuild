# Foreign-package catalog schema (C1)

Each foreign-distro package the operator references via the
`aptPackage()` / `dnfPackage()` / `pacmanPackage()` DSL produces a
catalog entry under
`recipes/catalog/foreign/<distro>/<package>.json`. The file shape is the
authoritative input the realize pipeline consumes once C2 (the
harvester) populates the dep closure.

This document defines the on-disk schema. C2 fills the dep closure
+ vendor key bundle; D1 wires it into the apply pipeline.

## Status — campaign milestone C1 (2026-06-15)

C1 ships:

- the DSL surface (`aptPackage(...)` / `dnfPackage(...)` /
  `pacmanPackage(...)`),
- this schema document,
- the JSON codec (write + read + round-trip + byte-identical
  reserialization),
- the realize-hash composer that mixes (distro, name, snapshot, dep
  closure) into an A3-shaped `CacheEntryIdentity`,
- three placeholder catalog files (`apt/git.json`, `dnf/htop.json`,
  `pacman/neovim.json`) authored by hand to exercise the schema. C2
  replaces the placeholder dep closures with real harvested ones.

C1 does NOT ship: the harvester (C2), the bind-mount sandbox launcher
(C3), the dep-closure resolution algorithm.

## Schema (format_version 1)

The on-disk shape is a single JSON object with **sorted keys at every
level**. The serializer enforces this so two identical catalogs
re-serialize byte-identically — the C2 harvester's idempotency
requirement.

```jsonc
{
  "dependency_closure": [
    {
      "distro": "apt",
      "name": "libc6",
      "snapshot": "debian/bookworm/20260601T000000Z",
      "tier": "foreign-bundle"
    }
  ],
  "format_version": 1,
  "package": {
    "distro": "apt",
    "name": "git",
    "snapshot": "debian/bookworm/20260601T000000Z",
    "version": "1:2.39.5-0+deb12u2"
  },
  "provisioning_methods": [
    {
      "kind": "direct-snapshot-url",
      "sha256": "...",
      "size_bytes": 0,
      "url": "https://snapshot.debian.org/.../git_2.39.5-0+deb12u2_amd64.deb"
    }
  ],
  "signed_envelope": null
}
```

### Required fields

- `format_version` (integer) — schema version. Start at 1. Bumped on
  breaking schema changes; unchanged across additive changes.
- `package.distro` (string) — one of `apt` / `dnf` / `pacman`.
- `package.name` (string) — the foreign package name.
- `package.snapshot` (string) — the pinned snapshot specifier matching
  the `<distro>/<release>/<rfc3339-compact>` shape the B1 parser
  validates: a non-empty, slash-separated string with at least three
  non-empty segments. Examples:
  - apt: `debian/bookworm/20260601T000000Z`
  - dnf: `fedora/39/20260601`
  - pacman: `archlinux/rolling/20260601` (Arch is a rolling release,
    so the middle segment is the literal token `rolling` — this keeps
    the three-segment invariant B1's parser enforces while staying
    faithful to Arch's flat archive layout. The campaign spec's C1
    example `archlinux/20260601` is rejected at parse time; use the
    three-segment form.)
- `package.version` (string) — package version inferred from the
  snapshot's `Packages` index. C1 ships placeholder strings; C2 fills
  the real version.
- `provisioning_methods` (array, sorted by `kind`) — at least one entry.
  The only `kind` C1 defines is `"direct-snapshot-url"`; future tiers
  may add e.g. `"mirror-url"`.
- `dependency_closure` (array) — transitive deps as `PackageRef` records
  (same shape as the inner `package` field). May be empty for the
  current C1 placeholders; C2 populates it. Sorted by
  `(distro, name, snapshot)` for byte stability.

### Optional fields

- `signed_envelope` — `null` or an object carrying the BLAKE3 digest of
  the rest of the file + an ECDSA-P256 signature. Mirrors the A2 / A3
  envelope shape used by the binary-cache manifest path. C1 leaves this
  `null`; the harvester (C2) wires it in once the key-bundle policy
  lands.

### Provisioning method shape (`kind = "direct-snapshot-url"`)

```jsonc
{
  "kind": "direct-snapshot-url",
  "sha256": "<64-char hex digest of the .deb / .rpm / .pkg.tar.zst>",
  "size_bytes": <integer; archive size in bytes>,
  "url": "<full snapshot.debian.org / kojipkgs / archive.archlinux.org URL>"
}
```

The realize pipeline downloads `url`, verifies the SHA-256, then hands
the archive to the per-distro extractor (C2's domain). The size is
recorded for substituter throughput accounting (matches the A2 manifest
shape).

### Realize-hash composition

The catalog file's `package` + sorted `dependency_closure` digest map
into an A3 `CacheEntryIdentity`:

- `packageName` = `package.name`
- `packageVersion` = `package.version`
- `selectedOptions` = `{ "distro": package.distro, "snapshot": package.snapshot }`
- `platform` = the host platform (foreign packages are host-specific;
  the realize pipeline supplies the host's triple)
- `toolchain` = a `ToolchainIdentity` whose `name = "<distro>-harvester"`
  and `version = "<harvester-revision>"` (placeholder until C2)
- `depClosure` = sorted hex of each transitive dep's
  `CacheEntryIdentity` digest
- `providerRevision` = SHA-256 of the canonical catalog-file bytes
  (computed BEFORE the `signed_envelope` field is added — the envelope
  is a wrapper, not part of the identity)

The hash differentiates four axes by construction:

1. Same package, different snapshot → different `selectedOptions` →
   different key.
2. Same package, different distro → different `selectedOptions` AND
   different `packageName` namespace by convention → different key.
3. Same name, different distro → different `selectedOptions["distro"]`
   → different key.
4. Adding / removing a dep → different `depClosure` → different key.

## Versioning rule

- **Additive changes** (new optional fields, new
  `provisioning_methods` kinds, new fields on existing kinds):
  `format_version` stays at the current value. Existing readers tolerate
  the new fields (the JSON decoder ignores unknown keys).
- **Breaking changes** (renaming a required field, changing a field's
  shape, removing a kind): bump `format_version`. The reader rejects
  any file whose version it doesn't recognize and the operator must
  re-harvest with the matching C2 release.

## Robustness against B2's manifest churn (Phase B risk #8)

B2 currently ships a plain-text `manifest.txt`; the campaign spec calls
out that the harvester (C2) will eventually emit snapshot-pinned manifest
fragments the B2 pipeline consumes. C1's catalog files are isolated from
that churn:

- The catalog is the input to the realize pipeline; the manifest is its
  output. They live on different sides of the pipeline boundary.
- The JSON envelope is versioned (`format_version`); the realize-hash
  composer keys off the canonical bytes BEFORE any wrapper.
- The deterministic sorted-key encoding means any future schema
  evolution can be detected by a one-byte diff against the previous
  version's canonical bytes (no whitespace / key-ordering noise).
