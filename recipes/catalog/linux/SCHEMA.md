# DE0-G Linux catalog schema (PoC)

`ReproOS-Wayland-DEs-PoC` milestone DE0-G extension of the C1 foreign
catalog shape (`recipes/catalog/foreign/SCHEMA.md`). The DE0-G catalog
files describe the Wayland-prerequisite **Linux** libraries that
compositors (Hyprland in DE-H1, GNOME in DE-G1) need at runtime:

- Mesa (`libgbm1`, `libegl-mesa0`, `libglapi-mesa`)
- libdrm (`libdrm2`, `libdrm-common`)
- Wayland IPC (`libwayland-client0`, `libwayland-server0`, `libwayland-egl1`)
- Keyboard handling (`libxkbcommon0`)
- Fontconfig (`fontconfig`, `libfontconfig1`)
- Default font (`fonts-dejavu-core`)

Hand-pinned per the DE0-G deliverable list; a future
`repro-harvest-apt` adapter will emit these files automatically from
the Ubuntu jammy archive (parallel to `repro-harvest-winget` for W3
and a future `repro-harvest-darling` for D3).

## Relationship to C1's `recipes/catalog/foreign/<distro>/` shape

The DE0-G catalogs deliberately sit at `recipes/catalog/linux/` rather
than under `recipes/catalog/foreign/apt/` for two reasons:

1. `KnownForeignDistros = ["apt", "dnf", "pacman"]` (closed set in
   `libs/repro_system_apply/src/repro_system_apply/types.nim`). Adding
   `"linux-graphics"` to that set is a breaking change for B1's parser;
   DE0-G is PoC-scope and must not regress A+B+C+D+X1+X2+W1+W2+W3+D1+D3.
2. The DE0-G build script (`build-linux-graphics-stack.sh`) reads these
   files directly (Python JSON), bypassing C1's typed
   `readForeignCatalog`. The DE0-G schema is therefore additive without
   crossing a parser API boundary.

The base shape stays byte-compatible with C1's `format_version=1`
layout so a future production catalog tier can lift these files into
the typed parser with a single `linux-graphics`-distro enum addition.

## Provisioning source decision

DE0-G's spec (`reprobuild-specs/ReproOS-Wayland-DEs-PoC.milestones.org`
section DE0-G) allows two provisioning sources:

1. **nixpkgs binary cache** — pin `nixpkgs/<revision>/<attr>`, record
   the NAR archive URL on `https://cache.nixos.org/`.
2. **Distro-harvested `.deb`s** — pin a snapshot URL on
   `http://archive.ubuntu.com/ubuntu/`.

The PoC picks **distro-harvested .debs from Ubuntu jammy 22.04** for
three reasons:

1. **ABI consistency** with DE0-D (which copies host-installed dbus
   binaries from the jammy build host). Mixing nixpkgs-cached mesa
   with jammy-host libsystemd would risk silent ABI breakage that
   nothing in the gate catches until vm-harness boot.
2. **No new fetcher needed.** The build script reuses
   `curl + sha256sum + dpkg-deb -x`, the same toolchain DE0-D's
   `plant_pkg` helper uses transitively. Teaching the builder how to
   pull NAR archives is a follow-up (DE-X tier; the spec explicitly
   tags this as a future milestone).
3. **Snapshot stability.** The `pool/main/m/mesa/libgbm1_...deb` URL
   on archive.ubuntu.com is stable for the lifetime of a jammy
   security pocket (years). nixpkgs cache URLs rotate with each
   channel bump.

Future graphics tiers (DE-H2 Hyprland, DE-G1 GNOME) may add the nixpkgs
fetcher; the schema below leaves room for it via the
`provisioning_methods` array (one entry today, can grow).

## Schema (format_version 1)

Each `recipes/catalog/linux/<name>.json` is a single JSON object with
**sorted keys at every level**. The serializer enforces this so two
identical catalogs re-serialize byte-identically — the same idempotency
property the C1 harvester relies on.

```jsonc
{
  "dependency_closure": [
    {"distro": "linux-graphics", "name": "libdrm", "snapshot": "ubuntu/jammy/20220422T000000Z"}
  ],
  "format_version": 1,
  "linux_version_banner": "libdrm.so.2",
  "package": {
    "distro": "linux-graphics",
    "name": "mesa",
    "snapshot": "ubuntu/jammy/20240130T000000Z",
    "version": "23.2.1-1ubuntu3.1~22.04.3"
  },
  "package_source": "ubuntu-jammy",
  "payload_files": [
    {
      "deb_url": "http://archive.ubuntu.com/ubuntu/pool/main/m/mesa/libgbm1_23.2.1-1ubuntu3.1~22.04.3_amd64.deb",
      "deb_sha256": "ac2ccbd5cb1cb1630da8281e8b5af280b14ecd31a0b06f1e591864704565cc3e",
      "deb_size_bytes": 33526,
      "deb_pkg": "libgbm1",
      "expected_files": [
        {
          "kind": "shared_library",
          "path": "usr/lib/x86_64-linux-gnu/libgbm.so.1.0.0",
          "soname_link": "usr/lib/x86_64-linux-gnu/libgbm.so.1"
        }
      ]
    }
  ],
  "provisioning_methods": [
    {
      "kind": "ubuntu-jammy-archive",
      "pocket": "main"
    }
  ],
  "runtime": "linux",
  "signed_envelope": null
}
```

### Required fields

- `format_version` (integer) — schema version. Start at 1.
- `runtime` (string) — Always `"linux"` for DE0-G entries. Selects the
  launcher's Linux runtime path (already supported per spec).
- `package_source` (string) — Traceability marker; the PoC uses
  `"ubuntu-jammy"`. A future nixpkgs-fetched entry would use
  `"nixpkgs-<channel>"`.
- `package.distro` (string) — Always `"linux-graphics"` for DE0-G.
  Disambiguates from C1's `apt`/`dnf`/`pacman` foreign-package catalog
  shapes.
- `package.name` (string) — Logical catalog entry name. DE0-G ships
  six entries: `mesa`, `libdrm`, `libwayland`, `libxkbcommon`,
  `fontconfig`, `dejavu-fonts`. Each maps to one or more Ubuntu
  .deb packages via `payload_files[]`.
- `package.snapshot` (string) — `ubuntu/jammy/<rfc3339-compact>` shape
  matching the C1 three-segment invariant. The middle segment is
  jammy's codename (analogous to bookworm in apt examples).
- `package.version` (string) — Upstream version of the *primary* .deb
  in `payload_files[0]`. The build script's smoke probe uses this for
  the boot-banner regex.
- `payload_files` (array, ordered by .deb name) — Each entry describes
  one Ubuntu `.deb` archive:
  - `deb_pkg` (string) — Ubuntu binary-package name (matches
    `apt-cache show`).
  - `deb_url` (string) — Full `http://archive.ubuntu.com/ubuntu/<Filename>`
    URL. Pinned to a specific pool path.
  - `deb_sha256` (string) — 64-char hex digest of the .deb contents
    (matches `apt-cache show`'s SHA256: line; verified by
    `sha256sum` post-fetch).
  - `deb_size_bytes` (integer) — Archive size; cross-verifies the
    sha256.
  - `expected_files` (array) — The files the build script asserts are
    present after `dpkg-deb -x` extraction. Each entry:
    - `kind` (string) — One of `shared_library`, `binary`, `config`,
      `font`, `data`. Drives downstream behaviour (e.g.
      `shared_library` triggers SONAME-link creation; `binary` gets
      executable bit; `config` is left as-is).
    - `path` (string) — POSIX relative path under the dpkg extraction
      root (matches `dpkg-deb -c` output minus the leading `./`).
    - `soname_link` (string, optional) — For `kind=shared_library` only:
      the SONAME-link path to create alongside `path` so `ld.so` finds
      it via the standard `libfoo.so.N` lookup. dpkg post-install
      normally creates these via `ldconfig`; we hand-pin them to
      keep the build deterministic and CI-friendly (no `ldconfig`
      dep on the build host).
- `dependency_closure` (array of `PackageRef`) — Shallow dep list.
  Per the campaign spec, closure resolution is out of scope for the
  PoC; entries here are advisory and used by the build script to
  emit a `Wants:` line in the install manifest. Each entry uses the
  same `(distro, name, snapshot)` shape as the C1 dep records.
- `linux_version_banner` (string) — Regex-or-literal the integration
  test matches against `ldconfig -p` output (or equivalent file-presence
  probe) to assert the entry's libs are visible at runtime. For the
  PoC this is a literal SONAME like `libdrm.so.2` that grep matches
  exactly.
- `provisioning_methods` (array) — Per C1, at least one entry. DE0-G
  uses `kind = "ubuntu-jammy-archive"` with a `pocket` selector
  (`main` or `universe`). The actual per-.deb URL lives on
  `payload_files[].deb_url` so the build script doesn't need to
  reconstruct paths from the package name.

### Optional fields

- `signed_envelope` — `null` or an object carrying a BLAKE3 digest +
  ECDSA-P256 signature. Mirrors A2/A3. DE0-G leaves this null; a
  future `repro-harvest-apt` adapter would wire it.

### Realize-hash composition

The catalog file's `package` + sorted `dependency_closure` digest map
into an A3 `CacheEntryIdentity` exactly as C1 specifies. For DE0-G the
`selectedOptions` adds `package_source = "ubuntu-jammy"` so a future
nixpkgs-source variant gets a distinct identity even when the binary
contents collide.

## Pinning policy

DE0-G pins to **jammy 22.04 security-pocket** versions (the same pool
DE0-D plants its dbus binaries from). This guarantees the libdbus
shipped by DE0-D and the libdrm shipped by DE0-G share a libsystemd
ABI floor.

The six catalog entries map to these `.deb` pins:

| Catalog | Primary .deb | Version | Notes |
|---------|--------------|---------|-------|
| `mesa.json` | `libgbm1` + `libegl-mesa0` + `libglapi-mesa` | 23.2.1-1ubuntu3.1~22.04.3 | mesa 23.2 is the jammy security-pocket build; ships llvmpipe SW rasterizer + EGL + GLAPI. |
| `libdrm.json` | `libdrm2` + `libdrm-common` | 2.4.113-2~ubuntu0.22.04.1 | libdrm-common is `Architecture: all` (data only); libdrm2 is the .so. |
| `libwayland.json` | `libwayland-client0` + `libwayland-server0` + `libwayland-egl1` | 1.20.0-1ubuntu0.1 | All three .debs share a version; libwayland-egl1 is what Mesa's EGL backend links against. |
| `libxkbcommon.json` | `libxkbcommon0` | 1.4.0-1 | jammy ships 1.4.0; sufficient for Hyprland 0.50.0. |
| `fontconfig.json` | `fontconfig` + `libfontconfig1` | 2.13.1-4.2ubuntu5 | fontconfig is the CLI tools (fc-cache etc.); libfontconfig1 is the .so. |
| `dejavu-fonts.json` | `fonts-dejavu-core` | 2.37-2build1 | Architecture: all; ships TTF + fontconfig snippets. |

The transitional `fonts-dejavu` umbrella package (which pulls in
both -core and -extra) is intentionally skipped: -extra adds 11 MB
of bitmap variants that no Wayland compositor needs at boot. The
schema's `dependency_closure` field carries the advisory link for
future tooling.

`libgl1-mesa-glx` (the legacy GLX runtime) is intentionally NOT
included in `mesa.json`: Wayland compositors use EGL, not GLX. If a
later X11-fallback tier needs GLX, it adds a new catalog entry
`libgl1-mesa-glx.json` without touching the DE0-G six.

## Verification (DE0-G P3 gate)

`recipes/reproos-mvp-config/build-linux-graphics-stack.sh` reads each
catalog file, fetches each .deb to `vendored-archives/linux/`, verifies
the .deb sha256 + size, extracts via `dpkg-deb -x` under a temp
overlay root, copies the `expected_files[]` into
`$OVERLAY/opt/reproos-linux/store/<hash>/`, creates the SONAME links,
and appends to `/etc/ld.so.conf.d/00-reproos-linux.conf` so the
overlay's libs are discovered at runtime via standard `ld.so` lookup.

Per the spec the integration test asserts:

1. Each .deb's `expected_files[]` lands in the overlay.
2. `registry.json` lists all six catalog entries with their final
   store-hash dir.
3. A binary linked against `libdrm.so.2` resolves the dependency via
   the overlay's path (LD_LIBRARY_PATH or `/etc/ld.so.conf.d/`).
4. Re-applying the planter is a no-op (sentinel
   `/var/lib/reproos-de0-graphics-done`).

## Limitations (PoC scope)

- No transitive dep walker; `dependency_closure` is hand-curated.
  Mesa transitively pulls libelf, zlib, libdrm-amdgpu, libxcb-* etc;
  the PoC relies on the jammy host already shipping these (matches
  DE0-D's support-libs handling).
- No nixpkgs path. The schema reserves
  `provisioning_methods[].kind = "nixpkgs-narinfo"` for a follow-up
  milestone (DE-H tier).
- No multi-architecture support. All amd64; arm64 jammy debs would
  need parallel catalog entries with a `package.architecture` field
  (currently implicit via the `_amd64.deb` URL).
- No signed envelope; relies on `archive.ubuntu.com` over plain HTTP
  + sha256 pin. Future `repro-harvest-apt` would gate via Ubuntu's
  signed `Release` file the same way `repro-harvest-winget` plans to
  gate on Authenticode.
