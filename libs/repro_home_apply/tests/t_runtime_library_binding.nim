## The launcher layer's half of the runtime-library binding.
##
## The join itself is covered exhaustively by
## `repro_project_dsl/tests/dsl_port/t_dsl_runtime_library_resolution`, which
## can vary the host because it takes the tokens as parameters. What is
## specific to this layer, and untested there, is the two conversions that feed
## it — and one of them is a real trap:
##
## `hostArch()` reports `arm64` for the machine the DSL's `cpu = "..."` fields
## call `aarch64`. Passing `hostArch()` straight into the matcher would make
## every `cpu = "aarch64"` declaration match no host, silently — a non-matching
## slice is indistinguishable from an absent one, so the symptom would be a
## missing directory with nothing pointing at the cause.

import std/[unittest, strutils]

import repro_project_dsl
import repro_home_apply/materialize_launchers

package rlbConsumer:
  runtimeDeps:
    "glib2 >=2.70"
    "polkit"
    "dbus >=1.14"

package rlbNoDeps:
  uses:
    "nim >=2.2 <3.0"

suite "host tokens speak the DSL's taxonomy":
  test "the cpu token is a value the DSL's cpu field accepts":
    # The whitelist `parsePackageDef` enforces on `cpu = "..."`. A token
    # outside it can never match a declaration, so this is the shape of the
    # arm64/aarch64 bug rather than a restatement of the implementation.
    check dslCpuToken() in ["x86_64", "aarch64", ""]

  test "the cpu token is never the hostArch spelling of arm":
    # `hostArch()` says `arm64`; the DSL says `aarch64`. If these are ever
    # conflated this test fails on ARM hosts, which is where it matters.
    check dslCpuToken() != "arm64"
    check dslCpuToken() != "arm32"

  test "the os token is a value the DSL's os field accepts":
    check dslOsToken() in ["windows", "linux", "macos", ""]

  test "the tokens agree with the compiling host":
    when defined(windows):
      check dslOsToken() == "windows"
    elif defined(macosx):
      check dslOsToken() == "macos"
    elif defined(linux):
      check dslOsToken() == "linux"
    when defined(amd64) or defined(x86_64):
      check dslCpuToken() == "x86_64"

suite "runtimeDeps constraint strings reduce to package selectors":
  test "the leading token is taken, version constraints dropped":
    let sels = runtimeDepSelectors("rlbConsumer")
    check sels == @["glib2", "polkit", "dbus"]

  test "declaration order is preserved":
    # The resulting search path is prepend-only and never wider than
    # runtimeLibraryDirs, so order is part of the contract.
    let sels = runtimeDepSelectors("rlbConsumer")
    check sels.len == 3
    check sels[0] == "glib2"
    check sels[2] == "dbus"

  test "a package with no runtimeDeps yields nothing":
    check runtimeDepSelectors("rlbNoDeps").len == 0

  test "an unregistered package yields nothing rather than raising":
    # Called for every launcher, including packages that never opted in.
    check runtimeDepSelectors("noSuchPackageEverDeclared").len == 0
