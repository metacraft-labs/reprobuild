## A declared package must provide the command name it is declared under.
##
## A realized prefix reaches PATH as a DIRECTORY, so the name a consumer can
## invoke is a file's own name. When those two disagree the package still
## resolves, still realizes, still reports success — and the command a
## recipe actually runs comes from the HOST.
##
## ``python3`` is the case that showed it. The DSL package is named
## ``python3``, every recipe declares ``python3``, and the Linux and macOS
## entries ship ``python/bin/python3`` so the name is right there. The
## Windows entry is python.org's *embeddable* distribution, which ships
## ``python.exe`` and nothing else — so the prefix contributed
## ``python.exe`` and ``python3`` fell through to whatever the machine had.
## Measured against a clean store: the package realized correctly and
## ``command -v python3`` answered out of the user's Scoop shims.
##
## That failure is invisible in practice, which is why it needs a test
## rather than a comment: the host's python usually works, so nothing
## breaks until the two pythons differ in a version or a module.

import std/[sequtils, strutils, unittest]

import repro_project_dsl

import repro_dsl_stdlib/packages/python3

proc slices(name: string): seq[TarballProvisioningDef] =
  let hits = registeredPackages().filterIt(it.packageName == name)
  doAssert hits.len == 1, "expected one package named " & name
  hits[0].tarballProvisioning

suite "python3 answers to the name it is declared under":

  test "every platform slice provides a `python3` command":
    # Either the declared executable IS `python3`, or an alias supplies
    # that name beside it, or -- POSIX only -- the declared file is the
    # versioned interpreter `python3.<minor>` of a python-build-standalone
    # archive, which ships `python3` as a symlink beside it in the same
    # `bin/`. A slice offering none of these realizes a prefix whose
    # declared command nobody invokes.
    #
    # The third arm exists because f7b524b6b had to declare the regular
    # file: realization refuses a declared executable reached through a
    # symlink, and in those archives `python/bin/python3` IS the symlink.
    # The name consumers invoke is still in the directory PATH gets, but
    # that is a fact about the archive's bytes, which this text-level test
    # cannot see. `t_stdlib_python_tarball_arms_realize` extracts the
    # host's arm and asserts `python3` is present there; this arm of the
    # rule is only as good as that test. The arm is deliberately narrow --
    # `python3.<digits>` in a `bin/` directory, never on Windows -- so a
    # slice declaring some other name still fails here.
    for slice in slices("python3"):
      checkpoint(slice.os & "/" & slice.cpu & " -> " &
        slice.executablePath & " alias=" & slice.executableAlias)
      let parts = slice.executablePath.rsplit('/', 2)
      let declared = parts[^1]
      let versionedBeside =
        slice.os != "windows" and parts.len >= 2 and parts[^2] == "bin" and
        declared.startsWith("python3.") and declared.len > "python3.".len and
        declared["python3.".len .. ^1].allCharsInSet({'0'..'9'})
      let provides =
        declared == "python3" or declared == "python3.exe" or
        slice.executableAlias == "python3" or
        slice.executableAlias == "python3.exe" or
        versionedBeside
      check provides

  test "the Windows slice carries the alias specifically":
    # Pinned on its own because this is the slice that regressed, and a
    # loop that passes for the wrong reason would hide it: the POSIX
    # entries satisfy the rule above through `executablePath` alone.
    let windows = slices("python3").filterIt(it.os == "windows")
    check windows.len == 1
    check windows[0].executablePath == "python.exe"
    check windows[0].executableAlias == "python3.exe"
