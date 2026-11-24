## `repro_cargo_fetch` -- registry crates fetched into the store root.
##
## Every crates.io crate a `Cargo.lock` pins is fetched by its own
## `cargo.fetch` edge (`netFetch`), verified against the lock's SHA-256
## before anything parses it, and published as a read-only prefix of the
## local content-addressed store, shared by every checkout and project of
## the user. The edges that later compile the sources read store paths only
## and declare no network. See `fetch.nim`.
##
## A fetched crate's library is compiled by its own rustc edge, from its
## store prefix, with the prefix remapped out of the outputs. See
## `crate_compile.nim`.

import ./repro_cargo_fetch/crate_rows
import ./repro_cargo_fetch/crate_store
import ./repro_cargo_fetch/fetch
import ./repro_cargo_fetch/crate_compile

export crate_rows, crate_store, fetch, crate_compile
