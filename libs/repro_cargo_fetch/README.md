# repro_cargo_fetch

Registry crates in the store root. Every crates.io crate a `Cargo.lock` pins
is fetched by its own build-graph edge, verified against the lock's SHA-256
checksum before anything parses it, and published as a read-only prefix of
the local content-addressed store, shared by every checkout and project of
the user.

| Module | What it does |
| --- | --- |
| `crate_rows` | the crates.io rows of a `Cargo.lock` (via `repro_core/cargo_lock`), each checked for a name, version and checksum that cannot change a path or URL; `git+` and other-registry packages are reported, not fetched |
| `crate_store` | the crate's prefix, `<store root>/prefixes/<name>/<version>-<realization hash>/`, published by the store's own write protocol; the realization hash covers the registry identity, `cargo:<name>`, the version, the checksum and the extractor's layout, and nothing host- or project-specific; the verified `.crate` is kept as a `cas/` blob |
| `crate_compile` | the rustc edge of one fetched library crate (`cargo.rustc/<name>@<version>-<hash>`): cargo's invocation for a dependency unit plus `--remap-path-prefix=<prefix>=<name>-<version>`, so the rlib and rmeta do not name the store; outputs the rlib and rmeta (the dep-info file is not an output), checked by content and gathered by the monitor; dependencies through `--extern` on their `.rmeta`; a crate with a build script, a proc-macro or `links` is refused before any action exists |
| `fetch` | the `cargo.fetch/<name>@<version>` edges (`bakSourceFetch`, `netFetch`, every mirror and the origin URL as tracked destinations): the store, then each configured mirror (`cargo/crates/<c0c1>/<cksum>.crate`), then the origin (`https://static.crates.io/crates/<name>/<version>/download`) under the origin egress policy |

Bytes whose SHA-256 is not the lock's checksum are discarded unparsed, the
mirror that served them is tried last for the rest of the wave, and the next
location is tried; there is no unverified fallback. Verified bytes are
gunzipped and extracted in process by the Nimble fetch's confined extractor
(`repro_nimble_fetch/archive_extract`), which refuses absolute and `..`
names, members outside `<name>-<version>/`, links that leave the tree, hard
links and special files, and accepts the GNU long-name records cargo writes
for long paths.

Nothing reads or writes cargo's own state (`$CARGO_HOME`, `~/.cargo`). The
edges that compile the sources are ordinary compile edges: they declare no
network and receive store paths only.

The compile edge takes each unit's features, profile flags and dependencies
from its caller, as cargo would plan them; deriving those units from a
cargo build of the lock is not part of this library.

The per-crate edges of one wave run one after another: the engine runs an
executor-backed built-in edge inline.
