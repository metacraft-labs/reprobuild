# repro_cmake_trycompile

TryCompile direct-provider metadata schema (Tier 2a).

The CMake Reprobuild generator's TryCompile codepath emits a small binary
metadata file (`trycompile.rbsz`) describing the 1- or 2-edge graph the
test compile produces (a compile, and optionally a link). The engine
routes such projects to the pre-built `repro-cmake-trycompile-provider`
binary instead of compiling a per-project `reprobuild.nim` — the binary
parses this metadata, synthesises the same `BuildActionDef` shape the
DSL would produce, and emits the graph fragment.

The schema is the smallest superset of `ReprobuildAction` that the C++
generator currently writes inline into `reprobuild.nim`. It is not a
general project description; TryCompiles are stereotyped and that
limitation is the whole point of taking this fast path.
