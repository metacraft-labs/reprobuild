import std/[os, strutils, tempfiles, unittest]

import repro_tool_profiles

suite "Nix propagated store path closure":
  test "recursively includes split-output dependencies once":
    let scratch = createTempDir("repro-nix-propagated-", "")
    defer: removeDir(scratch)

    let devOutput = scratch / "libbsd-dev"
    let runtimeOutput = scratch / "libbsd-runtime"
    let transitiveOutput = scratch / "libmd-runtime"
    createDir(devOutput / "nix-support")
    createDir(runtimeOutput / "nix-support")
    createDir(transitiveOutput)
    writeFile(devOutput / "nix-support" / "propagated-build-inputs",
      runtimeOutput & "\n")
    writeFile(runtimeOutput / "nix-support" /
      "propagated-native-build-inputs", transitiveOutput & "\n")

    var paths = @[devOutput]
    expandNixPropagatedStorePaths(paths)

    check paths == @[devOutput, runtimeOutput, transitiveOutput]

  test "adds propagated runtime directories to cached profile channels":
    let scratch = createTempDir("repro-nix-profile-propagated-", "")
    defer: removeDir(scratch)

    let devOutput = scratch / "fribidi-dev"
    let runtimeOutput = scratch / "fribidi-runtime"
    createDir(devOutput / "nix-support")
    createDir(devOutput / "lib" / "pkgconfig")
    createDir(runtimeOutput / "lib")
    writeFile(devOutput / "nix-support" / "propagated-build-inputs",
      runtimeOutput & "\n")

    var profile = PathOnlyToolProfile(
      installMethod: "nix",
      realizedStorePaths: @[devOutput])
    expandNixProfilePropagatedPaths(profile)

    check profile.realizedStorePaths == @[devOutput, runtimeOutput]
    check absolutePath(runtimeOutput / "lib") in profile.libraryPathList

  # A nixpkgs compiler wrapper records the libc it links against in
  # ``nix-support/orig-libc``; the wrapper passes it to its own compiler and
  # linker. It is not a propagated input, and following it as one put the libc
  # on LIBRARY_PATH, where a different compiler on the action's PATH (a host
  # gcc) linked against it and produced binaries the host libc cannot run.
  # Fake store directories stand in for the wrapper and the libc; the code
  # under test reads exactly these files, and nothing is mocked.
  test "a compiler wrapper's libc stays out of the realized paths":
    let scratch = createTempDir("repro-nix-wrapper-runtime-", "")
    defer: removeDir(scratch)

    let wrapper = scratch / "cc-wrapper"
    let runtime = scratch / "libc-runtime"
    let satellite = scratch / "libc-satellite"
    createDir(wrapper / "nix-support")
    createDir(runtime / "nix-support")
    createDir(runtime / "lib")
    createDir(satellite)
    writeFile(wrapper / "nix-support" / "orig-libc", runtime & "\n")
    writeFile(runtime / "nix-support" / "propagated-build-inputs",
      satellite & "\n" & wrapper & "\n")

    var paths = @[wrapper]
    expandNixPropagatedStorePaths(paths)
    check paths == @[wrapper]
    # The dedicated reader still finds it, for install normalization.
    check nixCompilerWrapperLibcs(paths) == @[runtime]
    check nixCompilerWrapperLibcDirs(paths) == @[runtime / "lib"]

  test "a compiler profile carries its libc only in the dedicated reader":
    let scratch = createTempDir("repro-nix-cached-wrapper-", "")
    defer: removeDir(scratch)

    let wrapper = scratch / "cc-wrapper"
    let runtime = scratch / "libc-runtime"
    createDir(wrapper / "nix-support")
    createDir(wrapper / "bin")
    createDir(wrapper / "lib")
    createDir(runtime / "lib")
    createDir(runtime / "include")
    createDir(runtime / "bin")
    # Content, not name, is what makes a directory a libc: the guard in the
    # engine refuses this one if it ever reaches LIBRARY_PATH.
    writeFile(runtime / "lib" / "libc.so.6", "synthetic libc")
    writeFile(wrapper / "nix-support" / "orig-libc", runtime & "\n")
    var profile = PathOnlyToolProfile(installMethod: "nix",
      realizedStorePaths: @[wrapper], pathSearchList: @[wrapper / "bin"])
    expandNixProfilePropagatedPaths(profile)
    check profile.realizedStorePaths == @[wrapper]
    check profile.libraryPathList == @[wrapper / "lib"]
    for list in [profile.libraryPathList, profile.cpathList,
                 profile.pkgConfigSearchList, profile.cmakePrefixList,
                 profile.pathSearchList]:
      for entry in list:
        check not entry.startsWith(runtime)
    check nixCompilerWrapperLibcDirs(profile.realizedStorePaths) ==
      @[runtime / "lib"]
    let fingerprint = profile.profileFingerprint
    expandNixProfilePropagatedPaths(profile)
    check profile.realizedStorePaths == @[wrapper]
    check profile.profileFingerprint == fingerprint

  test "a cached realization that followed the wrapper's libc is detected":
    # Builds that still followed ``orig-libc`` cached the libc among the
    # realized paths; their readers resolve such an entry afresh.
    let scratch = createTempDir("repro-nix-stale-wrapper-", "")
    defer: removeDir(scratch)

    let wrapper = scratch / "cc-wrapper"
    let runtime = scratch / "libc-runtime"
    let libcDev = scratch / "libc-dev"
    createDir(wrapper / "nix-support")
    createDir(runtime / "lib")
    createDir(libcDev / "nix-support")
    writeFile(wrapper / "nix-support" / "orig-libc", runtime & "\n")
    check nixStorePathsCarryWrapperLibc([wrapper, runtime], wrapper)
    # A fresh realization does not carry it.
    check not nixStorePathsCarryWrapperLibc([wrapper], wrapper)
    # The libc reached through a real propagated input is not stale.
    writeFile(libcDev / "nix-support" / "propagated-build-inputs",
      runtime & "\n")
    check not nixStorePathsCarryWrapperLibc([wrapper, libcDev, runtime],
      wrapper)
    # Nor is a libc that is the tool's own selected output.
    check not nixStorePathsCarryWrapperLibc([runtime, wrapper], runtime)
    # Nor anything without a wrapper.
    check not nixStorePathsCarryWrapperLibc([runtime], runtime)

  test "missing compiler runtime and non-runtime wrapper metadata stay out":
    let scratch = createTempDir("repro-nix-wrapper-metadata-", "")
    defer: removeDir(scratch)

    let wrapper = scratch / "cc-wrapper"
    let headers = scratch / "libc-dev"
    createDir(wrapper / "nix-support")
    createDir(headers / "include")
    writeFile(wrapper / "nix-support" / "orig-libc",
      scratch / "missing-libc" & "\n")
    writeFile(wrapper / "nix-support" / "orig-libc-dev", headers & "\n")
    var paths = @[wrapper]
    expandNixPropagatedStorePaths(paths)
    check paths == @[wrapper]
    check nixCompilerWrapperLibcs(paths).len == 0
    check nixCompilerWrapperLibcDirs(paths).len == 0

# The Darwin SDK cases below reproduce the layout measured on an
# aarch64-darwin host at the stdlib's canonical nixpkgs pin (``addf7cf5``).
# ``nixpkgs#clang`` is ``clang-wrapper-21.1.2``, whose
# ``nix-support/darwin-sdk-setup.bash`` falls back to ``apple-sdk-14.4``.
# That SDK carries no ``libiconv``. Its ``nix-support/propagated-build-inputs``
# lists ``libiconv-109.100.2-dev`` (and libresolv, libsbuf, libutil), and its
# ``propagated-native-build-inputs`` lists xcbuild's ``xcrun``. The ``-dev``
# output propagates the output whose ``lib/`` holds ``libiconv.dylib``, which
# also has a ``bin/iconv``. Fake store directories stand in for the store
# paths so the cases run on every host. Nothing is mocked: the code under test
# reads exactly these files.

proc writeDarwinSdkSetup(wrapper, sdk: string) =
  ## The wrapper script's shape, copied from the measured wrapper. The
  ## ``DEVELOPER_DIR_<suffix>`` reference is the caller's override, and the
  ## default after ``:-`` is the SDK the compiler uses without one.
  writeFile(wrapper / "nix-support" / "darwin-sdk-setup.bash",
    "accumulateRoles\n\n" &
    "if [[ \"14.0\" ]]; then\n" &
    "    mangleVarSingle DEVELOPER_DIR ${role_suffixes[@]+\"${role_suffixes[@]}\"}\n" &
    "    export DEVELOPER_DIR=${DEVELOPER_DIR_arm64_apple_darwin:-" & sdk & "}\n" &
    "    export SDKROOT=\"$DEVELOPER_DIR/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk\"\n" &
    "fi\n")

type DarwinSdkFixture = object
  wrapper, sdk, iconvDev, iconv, xcrun: string

proc darwinSdkFixture(scratch: string): DarwinSdkFixture =
  result = DarwinSdkFixture(
    wrapper: scratch / "clang-wrapper",
    sdk: scratch / "apple-sdk",
    iconvDev: scratch / "libiconv-dev",
    iconv: scratch / "libiconv",
    xcrun: scratch / "xcbuild-xcrun")
  for dir in [result.wrapper / "nix-support", result.wrapper / "bin",
              result.sdk / "nix-support",
              result.iconvDev / "nix-support", result.iconvDev / "include",
              result.iconv / "lib", result.iconv / "bin",
              result.xcrun / "bin"]:
    createDir(dir)
  writeDarwinSdkSetup(result.wrapper, result.sdk)
  writeFile(result.sdk / "nix-support" / "propagated-build-inputs",
    result.iconvDev & " \n")
  writeFile(result.sdk / "nix-support" / "propagated-native-build-inputs",
    result.xcrun & "\n")
  writeFile(result.iconvDev / "nix-support" / "propagated-build-inputs",
    " " & result.iconv)

suite "Darwin compiler wrapper SDK":
  test "a Darwin compiler profile links against its SDK's propagated libiconv":
    # The defect as a consumer saw it: the clang profile's library path held
    # only the wrapper's libc, so `-liconv` from Rust's default link line
    # resolved nowhere.
    let scratch = createTempDir("repro-nix-darwin-sdk-profile-", "")
    defer: removeDir(scratch)
    let f = darwinSdkFixture(scratch)

    check nixDarwinWrapperDefaultSdk(f.wrapper) == f.sdk
    check nixDarwinWrapperSdkLibraries([f.wrapper]) == @[f.iconvDev, f.iconv]

    var profile = PathOnlyToolProfile(installMethod: "nix",
      realizedStorePaths: @[f.wrapper], pathSearchList: @[f.wrapper / "bin"])
    expandNixProfilePropagatedPaths(profile)
    check profile.libraryPathList == @[absolutePath(f.iconv / "lib")]
    check profile.cpathList == @[absolutePath(f.iconvDev / "include")]
    let fingerprint = profile.profileFingerprint
    # Idempotent, like every other channel.
    expandNixProfilePropagatedPaths(profile)
    check profile.libraryPathList == @[absolutePath(f.iconv / "lib")]
    check profile.profileFingerprint == fingerprint

  test "the SDK's libraries reach no channel that puts a bin directory on PATH":
    # Realized store paths feed CMAKE_PREFIX_PATH, and the engine puts each
    # prefix's `bin/` on the action's PATH. The SDK, its libraries (libiconv
    # has `bin/iconv`) and its build-machine tools (`xcrun`) must stay out of
    # that, or an undeclared tool reaches the action.
    let scratch = createTempDir("repro-nix-darwin-sdk-path-", "")
    defer: removeDir(scratch)
    let f = darwinSdkFixture(scratch)

    var profile = PathOnlyToolProfile(installMethod: "nix",
      realizedStorePaths: @[f.wrapper], pathSearchList: @[f.wrapper / "bin"])
    expandNixProfilePropagatedPaths(profile)
    check profile.realizedStorePaths == @[f.wrapper]
    check profile.cmakePrefixList == @[f.wrapper]
    check profile.pathSearchList == @[f.wrapper / "bin"]
    check f.xcrun notin nixDarwinWrapperSdkLibraries([f.wrapper])
    for list in [profile.libraryPathList, profile.cpathList,
                 profile.pkgConfigSearchList, profile.cmakePrefixList]:
      for entry in list:
        check not entry.startsWith(f.sdk)
        check not entry.startsWith(f.xcrun)

  test "no SDK is followed without a usable default":
    let scratch = createTempDir("repro-nix-darwin-sdk-absent-", "")
    defer: removeDir(scratch)

    # A Linux wrapper: no setup script at all.
    let linuxWrapper = scratch / "gcc-wrapper"
    createDir(linuxWrapper / "nix-support")
    createDir(linuxWrapper / "lib")
    check nixDarwinWrapperDefaultSdk(linuxWrapper) == ""

    # A default naming a store path that is not there.
    let missing = scratch / "missing-wrapper"
    createDir(missing / "nix-support")
    writeDarwinSdkSetup(missing, scratch / "collected-apple-sdk")
    check nixDarwinWrapperDefaultSdk(missing) == ""

    # Only the caller's override, with no default: nothing to follow.
    let overrideOnly = scratch / "override-only-wrapper"
    createDir(overrideOnly / "nix-support")
    writeFile(overrideOnly / "nix-support" / "darwin-sdk-setup.bash",
      "export DEVELOPER_DIR=${DEVELOPER_DIR_arm64_apple_darwin}\n")
    check nixDarwinWrapperDefaultSdk(overrideOnly) == ""

    # A relative default is not a store path.
    let relative = scratch / "relative-wrapper"
    createDir(relative / "nix-support")
    createDir(scratch / "apple-sdk")
    writeFile(relative / "nix-support" / "darwin-sdk-setup.bash",
      "export DEVELOPER_DIR=${DEVELOPER_DIR_arm64_apple_darwin:-apple-sdk}\n")
    check nixDarwinWrapperDefaultSdk(relative) == ""

    let wrappers = @[linuxWrapper, missing, overrideOnly, relative]
    check nixDarwinWrapperSdkLibraries(wrappers).len == 0
    # A Linux compiler profile is exactly what it was before.
    var profile = PathOnlyToolProfile(installMethod: "nix",
      realizedStorePaths: @[linuxWrapper])
    expandNixProfilePropagatedPaths(profile)
    check profile.realizedStorePaths == @[linuxWrapper]
    check profile.libraryPathList == @[absolutePath(linuxWrapper / "lib")]
    check profile.cpathList.len == 0
