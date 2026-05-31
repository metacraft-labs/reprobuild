## M3 (Realize-Closure-And-Catalog-Expansion spec) — nested-7z
## recursive flatten realize hook. Covers gcc's M71-deferred shape:
## ``components-*.7z`` whose payload is itself a sequence of inner .7z
## archives (``binutils-*.7z`` + ``mingw-w64+gcc.7z``).
##
## Hermetic: every fixture is materialized on disk. Requires a host
## ``7z.exe`` to build the synthetic nested archive — skipped cleanly
## when absent.

import std/[os, osproc, strutils, tables, unittest]
from repro_core/paths import extendedPath

import repro_local_store
import repro_dsl_stdlib/packages_schema

import repro_home_apply/package_catalog
import repro_home_apply/builtin_adapter

const FixtureRoot = "build/test-tmp/t-builtin-adapter-7z-nested"

proc resetDir(path: string) =
  if dirExists(extendedPath(path)):
    removeDir(extendedPath(path))
  createDir(extendedPath(path))

proc fileToUrl(absPath: string): string =
  let normalized = absPath.replace('\\', '/')
  when defined(windows):
    if normalized.len >= 2 and normalized[1] == ':':
      "file:///" & normalized
    else:
      "file://" & normalized
  else:
    "file://" & normalized

proc resolveRealSevenZip(hostExe: string): string =
  let shimSidecar = changeFileExt(hostExe, "shim")
  if not fileExists(extendedPath(shimSidecar)):
    return hostExe
  for line in lines(extendedPath(shimSidecar)):
    let s = line.strip()
    if s.startsWith("path"):
      let eq = s.find('=')
      if eq > 0:
        var value = s[eq + 1 .. ^1].strip()
        if value.startsWith("\"") and value.endsWith("\""):
          value = value[1 ..< value.len - 1]
        if fileExists(extendedPath(value)):
          return value
  hostExe

proc seedSevenZipPrefix(store: var Store; hostSevenZ: string): string =
  let prefixId = computeRealizationHash("7zip", "test-seed",
    "builtin", "sha256:seed", "bin/7z.exe", "file:///seed",
    "seed", @["fixture"])
  let hint = StoreReceiptHint(
    adapter: "builtin", packageName: "7zip", version: "test-seed",
    declaredExecutablePath: "bin/7z.exe",
    exportedExecutables: @["bin/7z.exe"],
    lockIdentity: "sha256:seed", provenanceUrl: "file:///seed",
    provenanceChecksum: "sha256:seed",
    materializationMechanism: "raw+extract")
  let realExe = resolveRealSevenZip(hostSevenZ)
  let outcome = realizePrefix(store, prefixId, hint,
    proc (stagingDir: string; mechanism: var string) =
      createDir(extendedPath(stagingDir / "bin"))
      copyFile(extendedPath(realExe),
        extendedPath(stagingDir / "bin" / "7z.exe"))
      let codecsDll = parentDir(realExe) / "7z.dll"
      if fileExists(extendedPath(codecsDll)):
        copyFile(extendedPath(codecsDll),
          extendedPath(stagingDir / "bin" / "7z.dll"))
      mechanism = "copy")
  outcome.absolutePath

suite "M3 — cakBuiltin nested 7z":

  test "test_m3_nested_7z_flatten_synthetic_gcc_winlibs_shape":
    ## Builds a synthetic outer .7z whose payload is itself a sequence
    ## of inner .7z archives (binutils + mingw-w64+gcc, mirroring the
    ## winlibs ``components-*.7z`` shape). Drives realize with
    ## ``nested_7z = true`` and asserts:
    ##   * outer 7z is extracted into the prefix;
    ##   * the inner ``binutils-stub.7z`` + ``mingw-w64+gcc-stub.7z``
    ##     are recursively extracted in place;
    ##   * the inner archives are removed (the realized prefix carries
    ##     only the final flattened tree);
    ##   * bin/gcc.exe + bin/g++.exe + bin/gfortran.exe are all present.
    let fixtureDir = FixtureRoot / "gcc-nested"
    let storeDir = fixtureDir / "store"
    let stagingDir = fixtureDir / "staging"
    resetDir(fixtureDir); resetDir(storeDir); resetDir(stagingDir)

    let hostSeven = findExe("7z")
    if hostSeven.len == 0:
      echo "  [skip] no host 7z on PATH"
      skip()
    else:
      # Build inner archive #1: a binutils-style payload. We pack from
      # WITHIN ``binutils-stub-src/`` so the archive entries are
      # bare ``bin/as.exe``, ``bin/ld.exe`` (no parent dir wrapper).
      let binutilsDir = stagingDir / "binutils-stub-src"
      createDir(extendedPath(binutilsDir / "bin"))
      writeFile(extendedPath(binutilsDir / "bin" / "as.exe"),
        "stub-as-bytes\n")
      writeFile(extendedPath(binutilsDir / "bin" / "ld.exe"),
        "stub-ld-bytes\n")
      let binutils7z = stagingDir / "binutils-stub.7z"
      discard execCmdEx(
        quoteShell(hostSeven) & " a -t7z " &
        quoteShell(absolutePath(binutils7z)) &
        " bin -y -bsp0 -bso0",
        workingDir = binutilsDir)
      check fileExists(extendedPath(binutils7z))

      # Build inner archive #2: mingw-w64+gcc payload (same shape —
      # archive contains bare ``bin/<exe>`` entries).
      let gccDir = stagingDir / "gcc-stub-src"
      createDir(extendedPath(gccDir / "bin"))
      writeFile(extendedPath(gccDir / "bin" / "gcc.exe"),
        "stub-gcc-bytes\n")
      writeFile(extendedPath(gccDir / "bin" / "g++.exe"),
        "stub-gxx-bytes\n")
      writeFile(extendedPath(gccDir / "bin" / "gfortran.exe"),
        "stub-gfortran-bytes\n")
      let gcc7z = stagingDir / "mingw-w64+gcc-stub.7z"
      discard execCmdEx(
        quoteShell(hostSeven) & " a -t7z " &
        quoteShell(absolutePath(gcc7z)) &
        " bin -y -bsp0 -bso0",
        workingDir = gccDir)
      check fileExists(extendedPath(gcc7z))

      # Now build the OUTER archive carrying both inner .7z files
      # inside a ``components-stub-20.0/`` subdir (mirrors the winlibs
      # extract_dir shape).
      let outerInnerName = "components-stub-20.0"
      let outerInnerDir = stagingDir / outerInnerName
      createDir(extendedPath(outerInnerDir))
      copyFile(extendedPath(binutils7z),
        extendedPath(outerInnerDir / "binutils-stub.7z"))
      copyFile(extendedPath(gcc7z),
        extendedPath(outerInnerDir / "mingw-w64+gcc-stub.7z"))
      let outerArchive = fixtureDir / "components-stub.7z"
      let outerRes = execCmdEx(
        quoteShell(hostSeven) & " a -t7z " &
        quoteShell(absolutePath(outerArchive)) &
        " " & quoteShell(outerInnerName) & " -y -bsp0 -bso0",
        workingDir = stagingDir)
      check outerRes.exitCode == 0
      let sha = fileShaHex(outerArchive, "sha256")

      var store = openStore(storeDir)
      defer: store.close()
      discard seedSevenZipPrefix(store, hostSeven)

      let vp = initVersionedProvisioning(
        version = "stub-15.2.0",
        archive_format = afSevenZip,
        install_method = imExtract,
        bin_relpath = @["bin/gcc.exe", "bin/g++.exe", "bin/gfortran.exe"],
        platforms = @[
          initPlatformBinary(
            cpu = detectHostCpu(), os = detectHostOs(),
            url = fileToUrl(absolutePath(outerArchive)),
            sha256 = sha,
            extract_path = outerInnerName,
            nested_7z = true)
        ])
      let res = resolveBuiltinPackage("gcc-nested", @[vp])
      check res.found
      check res.resolution.nested7z

      let outR = realizeBuiltinPackage(store, res.resolution)
      check (not outR.cacheHit)

      # The realized prefix carries all three binaries — both inner
      # archives were recursively extracted in place. The bin/ dir is
      # the merged contents (binutils + gcc stubs both flatten to
      # bin/).
      check fileExists(extendedPath(outR.prefixAbsolutePath / "bin" / "gcc.exe"))
      check fileExists(extendedPath(outR.prefixAbsolutePath / "bin" / "g++.exe"))
      check fileExists(extendedPath(outR.prefixAbsolutePath / "bin" / "gfortran.exe"))
      check fileExists(extendedPath(outR.prefixAbsolutePath / "bin" / "as.exe"))
      check fileExists(extendedPath(outR.prefixAbsolutePath / "bin" / "ld.exe"))
      # The inner .7z files were removed after extraction (no longer
      # surface inside the realized prefix).
      check (not fileExists(extendedPath(outR.prefixAbsolutePath / "binutils-stub.7z")))
      check (not fileExists(extendedPath(outR.prefixAbsolutePath / "mingw-w64+gcc-stub.7z")))

  test "test_m3_nested_7z_disabled_keeps_inner_archives":
    ## Sanity: when ``nested_7z = false`` (the default), inner .7z
    ## files inside the extracted tree are LEFT IN PLACE — the recursive
    ## extract is an opt-in feature, not an always-on side effect. This
    ## protects catalog entries that happen to ship .7z files as data
    ## (e.g. a documentation tarball containing example archives).
    let fixtureDir = FixtureRoot / "no-nested"
    let storeDir = fixtureDir / "store"
    let stagingDir = fixtureDir / "staging"
    resetDir(fixtureDir); resetDir(storeDir); resetDir(stagingDir)
    let hostSeven = findExe("7z")
    if hostSeven.len == 0:
      echo "  [skip] no host 7z on PATH"
      skip()
    else:
      let payloadDir = stagingDir / "payload-stub"
      createDir(extendedPath(payloadDir))
      writeFile(extendedPath(payloadDir / "binutils-data.7z"),
        "this is a stub data file, not a real 7z archive\n")
      writeFile(extendedPath(payloadDir / "marker.txt"),
        "marker contents\n")
      let outerArchive = fixtureDir / "outer.7z"
      discard execCmdEx(
        quoteShell(hostSeven) & " a -t7z " &
        quoteShell(absolutePath(outerArchive)) &
        " payload-stub -y -bsp0 -bso0",
        workingDir = stagingDir)
      let sha = fileShaHex(outerArchive, "sha256")
      var store = openStore(storeDir)
      defer: store.close()
      discard seedSevenZipPrefix(store, hostSeven)
      let vp = initVersionedProvisioning(
        version = "stub-1.0.0",
        archive_format = afSevenZip,
        install_method = imExtract,
        bin_relpath = @["marker.txt"],
        platforms = @[
          initPlatformBinary(
            cpu = detectHostCpu(), os = detectHostOs(),
            url = fileToUrl(absolutePath(outerArchive)),
            sha256 = sha,
            extract_path = "payload-stub",
            nested_7z = false)
        ])
      let res = resolveBuiltinPackage("no-nested", @[vp])
      check res.found
      check (not res.resolution.nested7z)
      let outR = realizeBuiltinPackage(store, res.resolution)
      check (not outR.cacheHit)
      # The .7z file is still in the prefix because nested extract is off.
      check fileExists(extendedPath(outR.prefixAbsolutePath / "binutils-data.7z"))
      check fileExists(extendedPath(outR.prefixAbsolutePath / "marker.txt"))
