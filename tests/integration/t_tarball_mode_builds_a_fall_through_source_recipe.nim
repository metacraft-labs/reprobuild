## `repro build --tool-provisioning=tarball` builds the from-source recipe of
## a package that has no tarball for the host, then uses it.
##
## reprobuild-specs Dependency-Provisioning-In-Build-Graph.md 4.3: an unbuilt
## fall-through recipe "is built by `repro build` before the consuming graph
## is resolved, by the same recursive sub-build from-source mode uses", in the
## invocation's mode. Before that rule a tarball-mode build stopped at tool
## resolution with "no tarball provisioning entry ... matches host".
##
## Black-box: this checkout's real `repro` binary builds the consumer of
## `source_producer_fixture` (the fixture `t_source_producer_revalidation`
## uses in from-source mode). Its `probe` package is a stub with no
## realization at all, so tarball mode has no tarball for any host and must
## fall through to the catalog's `probe` recipe, which `REPRO_FROM_SOURCE_ROOT`
## selects. Both recipes use only builtin actions, so the run needs no host
## tool. Nothing is mocked.

import std/[os, osproc, strtabs, strutils, unittest]
import source_producer_fixture

const reproBinary = "build" / "bin" / addFileExt("repro", ExeExt)

suite "tarball mode builds a fall-through source recipe":
  test "an unbuilt recipe is built in tarball mode, then the consumer runs":
    let binary = absolutePath(reproBinary)
    require fileExists(binary)
    let root = createSourceFixture()
    defer: removeDir(root)
    # `usesImportPath "stubs"` splices `import stubs/probe` into the
    # consumer's module, which Nim resolves against the consumer's own
    # directory; the fixture's root `config.nims` path switch is not read by
    # the extractor's compile on Windows, so the stub also sits beside it.
    copyDir(root / "stubs", root / "consumer" / "stubs")
    let artifact = root / "catalog/probe/.repro/output/install/usr/lib/libprobe.so"
    let output = root / "consumer/build/result.txt"
    check not fileExists(artifact)

    var env = newStringTable(modeCaseSensitive)
    for key, value in envPairs(): env[key] = value
    for (key, value) in sourceFixtureEnv(root): env[key] = value
    env["REPROBUILD_NO_RUNQUOTA"] = "1"
    let res = execCmdEx(quoteShellCommand([binary, "build", "--daemon=off",
      "--tool-provisioning=tarball", "--progress=quiet", "--log=actions"]),
      env = env, workingDir = root / "consumer")
    checkpoint(res.output)
    check res.exitCode == 0
    check "\"probe\" has no tarball realization for this host" in res.output
    check fileExists(artifact)
    check fileExists(output)
    if fileExists(output):
      check readFile(output) == "implementation-one\n"
