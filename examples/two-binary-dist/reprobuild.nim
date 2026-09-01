## Two-binary distribution — the M0 packaging-layer sample.
##
## Demonstrates the CPack analog from
## ``reprobuild-specs/Distribution-And-Packaging.md`` §6: ONE build-graph
## definition (`distribution ...`) that produces a `.deb` AND a `.rpm`
## AND a `.tar.gz`, each installing both binaries to the declared prefix
## with the §5 runtime-wrapper / RPATH / env-default contract applied.
##
## Build everything:
##
##   $ repro build examples/two-binary-dist --tool-provisioning=path
##   $ ls examples/two-binary-dist/build/*.deb build/*.rpm build/*.tar.gz
##
## Or one format at a time via the named targets `deb` / `rpm` / `tarball`
## / `packages`.
##
## The two components are compiled from C (`src/greeter.c`,
## `src/farewell.c`) through the Layer-1 `c_executable` constructor, so
## they are real native binaries the §5 wrapper wraps. `greeter` reads the
## `TWO_BIN_DIST_GREETING` env var, whose default the generated wrapper
## seeds — running the installed `greeter` prints the packaged default,
## proving the env-default half of the contract end to end.

import repro_project_dsl
import repro_dsl_stdlib/constructors/c_executable
import repro_dsl_stdlib/packaging

package twoBinaryDist:
  defaultToolProvisioning "path"

  uses:
    "sh"
    "gcc"
    "tar"
    "dpkg-deb"
    "rpmbuild"

  build:
    # Two ordinary typed Executables — the packaging layer consumes any
    # `Executable` (from c_executable / nim_executable / a from-source
    # package slice), not a bespoke shape.
    let greeter = c_executable(
      into = "build/bin/greeter", sources = @["src/greeter.c"])
    let farewell = c_executable(
      into = "build/bin/farewell", sources = @["src/farewell.c"])

    # The ONE install-tree definition. Components + runtime contract +
    # (here empty) services + metadata. Every producer below translates
    # THIS; none of them re-derive it.
    let dist = distribution(
      name = "two-bin-dist",
      version = "1.0.0",
      components = @[greeter, farewell],
      metadata = packageMetadata(
        maintainer = "Reprobuild <dev@reprobuild.com>",
        description = "M0 sample: two trivial binaries packaged from one " &
          "build-graph definition.",
        license = "MIT",
        homepage = "https://reprobuild.com"),
      runtime = runtimeContract(
        # The env-default half of the §5 contract. (The vendored-library +
        # RPATH half is a structural no-op here — these trivial binaries
        # need no runtime closure — but the same `runtimeContract` field
        # carries reprobuild's blake3/xxHash/sqlite/openssl/zstd/clingo
        # closure when packaging reprobuild itself in M1.)
        envDefaults = @[
          ("TWO_BIN_DIST_GREETING", "hello from the installed package")]))

    # Format producers — one content-addressed build edge each.
    let debEdge = dist.deb(
      output = "build/two-bin-dist_1.0.0_" & debArch(dist.arch) & ".deb")
    let rpmEdge = dist.rpm(
      output = "build/two-bin-dist-1.0.0-1." & rpmArch(dist.arch) & ".rpm")
    let tgzEdge = dist.tarball(
      output = "build/two-bin-dist-1.0.0-" & dist.arch & ".tar.gz")

    discard target("deb", [debEdge])
    discard target("rpm", [rpmEdge])
    discard target("tarball", [tgzEdge])
    let all = target("packages", [debEdge, rpmEdge, tgzEdge])
    defaultTarget(all)
