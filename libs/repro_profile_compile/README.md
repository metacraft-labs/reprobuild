# repro_profile_compile

Reprobuild profile-compile build-graph edge (M83 Phase C).

Profile compilation is a normal build-graph edge: one monitored
`BuildAction` of kind `bakProcess`, submitted to `runBuild`, covering both
the `nim c` of the profile and the run of the binary that prints its
intent. Whether it re-runs is decided by the engine's action cache from
what io-mon observed it read — there is no source scan, digest or
structural fast path in front of it. The CLI exposes NO user-facing
`repro profile build` command; apply (Phase D) calls
`compileProfileToRbpi` automatically when it needs a fresh
`ProfileIntent`.

Submodules:

- `repro_profile_compile/sources` — repo-root / Nim-path discovery,
  profile-root resolution, cache-layout helpers.
- `repro_profile_compile/compile` — direct `nim c` invocation and the
  JSON→RBPI bridge. Used by the internal helper subcommand and by tests.
- `repro_profile_compile/edge` — `BuildAction` construction +
  `compileProfileToRbpi` public entry point.
- `repro_profile_compile/helper` — body of the
  `__repro-compile-profile` internal helper subcommand.

See `reprobuild-specs/Profile-Compile-As-A-Build-Edge.md` and the
M83 Phase C entries in `Reprobuild-Development.milestones.org` for the
broader design context.
