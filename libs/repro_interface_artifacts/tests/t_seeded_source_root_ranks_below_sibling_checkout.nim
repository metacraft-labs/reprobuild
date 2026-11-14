## A source root the CLI seeded from its own build must not shadow a sibling
## checkout (issue 2026-11-14-repro-0-2-18-on-the-workspace-path-cannot-compile-
## reprobuild-agents-libs-repro-runquota).
##
## The packaged ``repro`` wrapper exports ``RUNQUOTA_SRC`` (and the other source
## roots) pointing at the library snapshot it was built with, and records that
## in ``REPRO_BOOTSTRAP_SOURCE_ENV``. A workspace whose pinned ``repro`` lags
## the tree it compiles then compiled that tree against the engine's older
## runquota (``undeclared routine: withWidthRange``) because the seeded
## environment variable outranked the workspace's own ``runquota/`` checkout.
## An explicit caller value must still win.
##
## No mocks: real directories with the marker files the resolvers probe, and
## the real seeding procedure. The process environment is mutated, so this
## binary runs on its own.

import std/[os, tempfiles, unittest]

import repro_interface_artifacts

proc touch(path: string) =
  createDir(path.parentDir)
  writeFile(path, "")

proc makeRunquota(root: string) =
  touch(root / "libs" / "runquota_core" / "src" / "runquota_core.nim")
  touch(root / "libs" / "runquota_client" / "src" / "runquota_client.nim")

proc runquotaFlags(flags: seq[string]; root: string): bool =
  ("--path:" & root / "libs" / "runquota_client" / "src") in flags

suite "seeded source roots rank below sibling checkouts":
  var workspace, engineSnapshot: string

  setup:
    workspace = createTempDir("repro-seeded-ws-", "")
    engineSnapshot = createTempDir("repro-seeded-engine-", "")
    createDir(workspace / "reprobuild")
    createDir(workspace / "consumer")
    makeRunquota(workspace / "runquota")
    makeRunquota(engineSnapshot)
    delEnv("RUNQUOTA_SRC")
    delEnv(SeededSourceEnvironmentVar)

  teardown:
    delEnv("RUNQUOTA_SRC")
    delEnv(SeededSourceEnvironmentVar)
    removeDir(workspace)
    removeDir(engineSnapshot)

  test "the sibling runquota beats the seeded engine snapshot":
    seedSourcePackageEnvironment([("RUNQUOTA_SRC", engineSnapshot)])
    check getEnv("RUNQUOTA_SRC") == engineSnapshot
    let flags = bootstrapSiblingPackagePathFlags(
      workspace / "reprobuild", workspace)
    check runquotaFlags(flags, workspace / "runquota")
    check not runquotaFlags(flags, engineSnapshot)

  test "the seeded snapshot is still used when no sibling exists":
    removeDir(workspace / "runquota")
    seedSourcePackageEnvironment([("RUNQUOTA_SRC", engineSnapshot)])
    let flags = bootstrapSiblingPackagePathFlags(
      workspace / "reprobuild", workspace)
    check runquotaFlags(flags, engineSnapshot)

  test "an explicit RUNQUOTA_SRC still beats the sibling":
    putEnv("RUNQUOTA_SRC", engineSnapshot)
    let flags = bootstrapSiblingPackagePathFlags(
      workspace / "reprobuild", workspace)
    check runquotaFlags(flags, engineSnapshot)
    check not runquotaFlags(flags, workspace / "runquota")
