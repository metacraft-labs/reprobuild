# W3 Windows catalog schema (PoC)

`ReproOS-Multi-OS-Catalog-PoC` milestone W3 extension of the C1 foreign
catalog shape (`recipes/catalog/foreign/SCHEMA.md`). The W3 catalog
files (`gh.json`, `just.json`, `ninja.json`) describe Windows software
that ReproOS executes via WINE.

Hand-pinned per the W3 milestone deliverable list; the post-PoC
`repro-harvest-winget` adapter will emit these files automatically.

## Relationship to C1's `recipes/catalog/foreign/<distro>/` shape

The W3 catalogs deliberately sit at `recipes/catalog/windows/` rather
than under `recipes/catalog/foreign/windows/` for two reasons:

1. `KnownForeignDistros = ["apt", "dnf", "pacman"]` (closed set in
   `libs/repro_system_apply/src/repro_system_apply/types.nim`). Adding
   `"windows"` to that set is a breaking change for B1's parser; W3 is
   PoC-scope and must not regress A+B+C+D+X1+X2+W1+W2.
2. The W3 build script (`build-windows-prefix.sh`) reads these files
   directly (Python JSON), bypassing C1's typed `readForeignCatalog`.
   The W3 schema is therefore additive without crossing a parser API
   boundary.

The base shape is byte-compatible with C1's format_version=1 layout so
a future production catalog tier can lift these files into the typed
parser with a single `windows`-distro enum addition.

## Fields (additive over C1)

| Field | Type | Purpose |
|-------|------|---------|
| `runtime` | string | Always `"wine"` for W3 PoC tools. Selects the W2 launcher's WINE runtime path. |
| `wine_prefix_id` | string | Subtree selector inside the shared WINEPREFIX. Always `"shared"` for the PoC; reserved for future per-package prefix isolation. |
| `exec_path` | string | WINEPREFIX-relative POSIX path the launcher passes to `wine_exec=`. Always rooted at `drive_c/repro-store/<name>/bin/<name>.exe`. |
| `payload_files` | array | Per-file extraction map. Each entry: `archive_relpath` (path inside the .zip), `install_relpath` (path inside the per-package prefix), `kind` (`"exe"` / `"dll"`), `sha256` (pinned content hash). The W3 build script verifies each file's sha256 after extraction. |
| `dependency_dll_closure` | array | Explicit DLL deps. PER W2 review's risk #3: **no system DLL fallback**. The 3 PoC tools all import only WINE-provided system DLLs (kernel32 / advapi32 / bcrypt / dbghelp / ntdll / ole32 / shell32), so this list is empty for all three. Non-empty entries trigger additional payload extraction at build time. |
| `wine_version_banner` | string | Expected prefix of the `--version` stdout for the W3 verification gate. The W3 build script's smoke test asserts `<binary>.exe --version` starts with this string. |

The C1 base fields (`package`, `provisioning_methods`, `format_version`,
`dependency_closure`, `signed_envelope`) carry their existing
semantics. `dependency_closure` stays empty for the PoC tools (all are
self-contained binaries; transitive deps would be other catalog
entries, none of which apply for gh / just / ninja).

## Pinning policy

`provisioning_methods[0]` is the upstream GitHub release URL. The W3
PoC pins versions chosen for WINE 6.0.3 (Ubuntu 22.04 / Debian
bookworm — matches the W1 ISO build host):

* **gh 2.40.0** — gh imports only `kernel32.dll`; verified to run
  cleanly on WINE 6.0.3.
* **just 1.24.0** — pinned older than upstream's latest because
  just 1.36.0 imports `bcryptprimitives.dll` (added to WINE in 7.x),
  which WINE 6.0.3 lacks. 1.24.0 imports only stock WINE DLLs.
* **ninja 1.12.1** — ninja imports only `KERNEL32` + `dbghelp`;
  verified to run cleanly on WINE 6.0.3.

## Verification (W3 P3 gate)

`recipes/reproos-mvp-config/build-windows-prefix.sh` reads each
catalog, fetches the pinned .zip, verifies the archive sha256, extracts
into `<store>/prefixes-win/<name>/`, plants the result into
`$WINEPREFIX/drive_c/repro-store/<name>/`, emits a W2 launcher
manifest, and runs `wine-<name> --version` to assert the banner
matches. PASS iff all three tools' banners match.

## Limitations (PoC scope)

* No transitive dep walker; `dependency_dll_closure` is hand-curated.
  A future `repro-harvest-winget` adapter would discover deps via
  PE-import inspection (`dumpbin /imports` or a Python pefile parser).
* No signed envelope. The catalog ships unsigned; C2's
  signed-envelope path is a post-PoC follow-up here.
* No multi-architecture support. All three .exes are x86_64 PE
  (matches gh's `_windows_amd64.zip`, just's `x86_64-pc-windows-msvc`
  triple, ninja's `ninja-win.zip` x86_64 binary).
