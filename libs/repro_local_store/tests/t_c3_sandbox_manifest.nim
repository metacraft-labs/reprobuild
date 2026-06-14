## C3 P2 unit test: sandbox manifest module
##
## Covers:
##
##   * ``walkCatalogGraph`` against a stub catalog tree (closes C2
##     risk #4 by exercising the recursive walk, not just one root's
##     dep_closure).
##   * ``composeSandboxManifest`` deterministic ordering (sort by
##     target then source then flags).
##   * ``serializeManifest`` round-trips the expected canonical
##     bytes.
##   * ``generateLauncherShim`` emits the expected `exec` line.
##   * ``walkCatalogGraph`` raises ``CatalogResolveError`` on a
##     missing dep.

import std/[json, os, sets, strutils, tables, tempfiles, unittest]

import repro_local_store
import repro_dsl_stdlib/packages/foreign_common

# ---------------------------------------------------------------------------
# Fixture helpers
# ---------------------------------------------------------------------------

const TestSnapshot = "debian/bookworm/20260601T000000Z"

proc writeCatalog(dir, name: string; deps: openArray[string]) =
  ## Hand-craft a minimal apt-shape catalog under ``dir/apt/<name>.json``.
  ## We avoid using ``writeForeignCatalog`` so the test's fixture stays
  ## independent of the writer's JSON details.
  let aptDir = dir / "apt"
  createDir(aptDir)
  var pkg = newJObject()
  pkg["distro"] = %"apt"
  pkg["name"] = %name
  pkg["snapshot"] = %TestSnapshot
  pkg["tier"] = %"foreign-bundle"
  pkg["version"] = %"1.0.0"

  var prov = newJArray()
  var p1 = newJObject()
  p1["kind"] = %"direct-snapshot-url"
  p1["url"] = %("https://example.invalid/" & name & ".deb")
  p1["sha256"] = %(repeat('0', 64))
  p1["size_bytes"] = %0
  prov.add(p1)

  var closure = newJArray()
  for d in deps:
    var node = newJObject()
    node["distro"] = %"apt"
    node["name"] = %d
    node["snapshot"] = %TestSnapshot
    node["tier"] = %"foreign-bundle"
    closure.add(node)

  var root = newJObject()
  root["format_version"] = %1
  root["package"] = pkg
  root["provisioning_methods"] = prov
  root["dependency_closure"] = closure
  root["signed_envelope"] = newJNull()

  writeFile(aptDir / (name & ".json"), pretty(root))

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

suite "C3 sandbox_manifest":
  test "walkCatalogGraph: minimal three-package transitive set":
    let workdir = createTempDir("c3wk_", "")
    defer: removeDir(workdir)

    # git -> libc6 -> libgcc-s1
    # libcurl -> libc6, libnghttp2
    # libnghttp2 -> libc6
    writeCatalog(workdir, "git", ["libc6", "libcurl3-gnutls"])
    writeCatalog(workdir, "libc6", ["libgcc-s1"])
    writeCatalog(workdir, "libgcc-s1", [])
    writeCatalog(workdir, "libcurl3-gnutls", ["libc6", "libnghttp2-14"])
    writeCatalog(workdir, "libnghttp2-14", ["libc6"])

    let rootPath = workdir / "apt" / "git.json"
    let closure = walkCatalogGraph(rootPath, workdir, includeRoot = true)

    var names: HashSet[string]
    for p in closure: names.incl(p.name)
    check "git" in names
    check "libc6" in names
    check "libgcc-s1" in names
    check "libcurl3-gnutls" in names
    check "libnghttp2-14" in names
    check closure.len == 5

    # Sorted by (distro, name, snapshot): git, libc6, libcurl3-gnutls,
    # libgcc-s1, libnghttp2-14
    let expected = @["git", "libc6", "libcurl3-gnutls",
                     "libgcc-s1", "libnghttp2-14"]
    var got: seq[string]
    for p in closure: got.add(p.name)
    check got == expected

  test "walkCatalogGraph: missing dep raises CatalogResolveError":
    let workdir = createTempDir("c3miss_", "")
    defer: removeDir(workdir)
    writeCatalog(workdir, "rootpkg", ["nonexistent-dep"])
    let rootPath = workdir / "apt" / "rootpkg.json"
    expect CatalogResolveError:
      discard walkCatalogGraph(rootPath, workdir)

  test "walkCatalogGraph: tolerates the C2-fixture full-transitive shape":
    # Real C2 fixture: every catalog's dep_closure already lists the
    # full per-record transitive set. The walker must produce the same
    # union regardless of whether deps list "immediate only" or
    # "transitive".
    let workdir = createTempDir("c3c2_", "")
    defer: removeDir(workdir)

    writeCatalog(workdir, "git",
      ["libc6", "libcurl3-gnutls", "libgcc-s1", "libnghttp2-14"])
    writeCatalog(workdir, "libc6", ["libgcc-s1"])
    writeCatalog(workdir, "libcurl3-gnutls",
      ["libc6", "libgcc-s1", "libnghttp2-14"])
    writeCatalog(workdir, "libgcc-s1", [])
    writeCatalog(workdir, "libnghttp2-14", ["libc6", "libgcc-s1"])

    let closure = walkCatalogGraph(workdir / "apt" / "git.json", workdir)
    var names: HashSet[string]
    for p in closure: names.incl(p.name)
    check names.len == 5
    check "git" in names
    check "libc6" in names

  test "composeSandboxManifest: deterministic sort + raises on missing prefix":
    var prefixes: PrefixesMap
    prefixes["apt/libc6"] = "/store/prefixes/libc6/aaa"
    # NOTE: missing "apt/git" -> should raise

    let p = PackageRef(tier: ptForeignBundle, name: "git",
      distro: "apt", snapshot: TestSnapshot)
    expect KeyError:
      discard composeSandboxManifest(@[p], prefixes,
        execPath = "/store/prefixes/git/bbb/usr/bin/git",
        existsCheck = proc(s: string): bool = true)

  test "composeSandboxManifest: emits bind set in sorted order":
    var prefixes: PrefixesMap
    prefixes["apt/libc6"] = "/store/prefixes/libc6/aaa"
    prefixes["apt/zlib1g"] = "/store/prefixes/zlib1g/bbb"

    let pkgs = @[
      PackageRef(tier: ptForeignBundle, name: "libc6", distro: "apt",
                 snapshot: TestSnapshot),
      PackageRef(tier: ptForeignBundle, name: "zlib1g", distro: "apt",
                 snapshot: TestSnapshot),
    ]
    # Make every probed path "exist" so the bind candidates fire.
    let m = composeSandboxManifest(pkgs, prefixes,
      execPath = "/store/prefixes/libc6/aaa/usr/bin/dummy",
      existsCheck = proc(s: string): bool = true)
    check m.binds.len > 0
    # Sort invariant: targets non-decreasing
    for i in 1 ..< m.binds.len:
      check m.binds[i-1].target <= m.binds[i].target

  test "serializeManifest: canonical bytes":
    let m = SandboxManifest(
      binds: @[
        BindMount(source: "/a", target: "/lib", flags: "rbind,ro"),
        BindMount(source: "/b", target: "/usr/lib", flags: "rbind,ro"),
      ],
      execPath: "/store/x/bin/tool",
      cwd: "",
      extraDirectives: @["proc"],
    )
    let text = serializeManifest(m)
    check "exec=/store/x/bin/tool\n" in text
    check "/a:/lib:rbind,ro\n" in text
    check "/b:/usr/lib:rbind,ro\n" in text
    check "\nproc\n" in text

  test "generateLauncherShim: shape":
    let s = generateLauncherShim("git",
      actualPath = "/store/prefixes/git/abc/usr/bin/git",
      manifestPath = "/store/prefixes/git/abc/launcher.manifest",
      launcherBinPath = "/usr/local/bin/reprobuild-sandbox-launcher")
    check s.startsWith("#!/bin/sh\n")
    check "exec /usr/local/bin/reprobuild-sandbox-launcher" in s
    check "--manifest=/store/prefixes/git/abc/launcher.manifest" in s
    check "--exec=/store/prefixes/git/abc/usr/bin/git" in s
    check "-- \"$@\"\n" in s

  test "materializeSandboxManifest: end-to-end":
    let workdir = createTempDir("c3mat_", "")
    defer: removeDir(workdir)

    writeCatalog(workdir, "tool", ["dep1"])
    writeCatalog(workdir, "dep1", [])

    var prefixes: PrefixesMap
    prefixes["apt/tool"] = workdir / "prefixes" / "tool"
    prefixes["apt/dep1"] = workdir / "prefixes" / "dep1"
    # Create plausible bin/lib in each prefix.
    for key in ["tool", "dep1"]:
      createDir(workdir / "prefixes" / key / "usr/bin")
      createDir(workdir / "prefixes" / key / "usr/lib")

    let manifestPath = workdir / "out.manifest"
    let closure = materializeSandboxManifest(
      rootCatalogPath = workdir / "apt" / "tool.json",
      catalogRoot = workdir,
      prefixes = prefixes,
      execPath = workdir / "prefixes" / "tool" / "usr/bin/tool",
      outPath = manifestPath)
    check closure.len == 2
    check fileExists(manifestPath)
    let body = readFile(manifestPath)
    check "exec=" in body
    check ":/usr/bin:rbind,ro" in body
    check ":/usr/lib:rbind,ro" in body
