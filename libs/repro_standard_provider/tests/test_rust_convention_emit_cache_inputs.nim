## Rust convention: the ``cargo metadata`` emit cache misses whenever a
## file ``cargo metadata`` reads changes, wherever the file lies and
## however it is reached.
##
## The convention runs ``cargo metadata --format-version=1 --no-deps
## --offline`` at emit time and reuses its output while the output's
## emit-cache key is unchanged (Rust.md §"The ``cargo metadata`` emit
## cache"). Cargo reads more than the regular files below the project
## root: a workspace may list a member outside its root, a member
## directory or a manifest may be a symbolic link, and a glob in
## ``members`` makes a new directory a member (Cargo reference,
## "Workspaces", "The ``members`` and ``exclude`` fields":
## https://doc.rust-lang.org/cargo/reference/workspaces.html#the-members-and-exclude-fields).
## A key that misses such a change makes the convention emit from stale
## metadata: an old ``--edition``, a missing target, a missing member.
##
## Each case emits (which fills the cache), changes one thing, emits
## again, and requires that the second fragment holds the change AND
## equals, as a set of action ids with their argv, a cold emit made after
## deleting ``<root>/.repro/build/.emit-cache``. The cold emit is what the
## convention produces from fresh metadata, so the comparison holds the
## cached path to exactly that, not only to the one change the case names.
##
##   a. **A member outside the root** (``members = ["a", "../ext"]``,
##      ``workspace = "../ws"`` in its manifest) changes its ``edition``.
##   b. The same layout: the outside member gains a ``[[bin]]`` target.
##   c. **A member reached through a symbolic link to a directory**
##      (``root/b -> ../real-b``) changes its ``edition`` in the real
##      directory.
##   d. **A member whose ``Cargo.toml`` is a symbolic link** to a file
##      outside the root: the file it names changes its ``edition``.
##   e. **A glob member pattern outside the root**
##      (``members = ["a", "../ext/*"]``): a new crate directory is
##      created under ``../ext``.
##   f. **A symbolic link cycle** under the root (``root/loop -> root``)
##      neither hangs the emit nor breaks it, nor keeps the cache from
##      settling.
##   g. **Positive control: the cache is still used.** Once the state has
##      settled, an emit with nothing changed rewrites neither the cached
##      JSON nor its sidecar. For an outside member that takes two emits:
##      the set of files the key covers is read from the cached output, so
##      the first run, which has no cached output, cannot know it, and the
##      spec writes the key only when the run names the same set the key
##      was checked against. A workspace entirely under its root settles
##      after one emit.
##   h. **A second link to a directory the walk has already entered**: a
##      member's ``tests -> examples`` makes Cargo discover each example
##      as a test target too. The walk enters that directory once, so the
##      link must still change the key.
##   i. **The same under a glob pattern**: ``members = ["a", "crates/*"]``
##      with ``exclude = ["crates/b"]``; a link ``crates/c -> b`` makes
##      ``b`` a member through the spelling ``crates/c``.
##   j. **A path dependency outside the workspace** gains
##      ``workspace = "../ws"``: Cargo reads every path dependency's
##      manifest to decide whether it belongs to the workspace, and one
##      that names this workspace becomes a member (Cargo reference,
##      "Workspaces", "The ``members`` and ``exclude`` fields": "All path
##      dependencies residing in the workspace directory automatically
##      become members"; a path dependency elsewhere is one when its
##      ``package.workspace`` names the workspace).
##   k. **A link to a directory under the root is not followed**: a
##      project root holding ``.direnv/flake-inputs/x-source``, a link
##      into a tree outside it (nix-direnv leaves such links into the Nix
##      store), with manifests, sources and a link cycle of its own. No
##      input of the key lies in that tree, by the link's spelling or the
##      target's, and editing a source there does not re-run cargo. The
##      walk of the root does not follow links to directories (Rust.md
##      §"The ``cargo metadata`` emit cache"): following them made every
##      emit walk the linked trees, and the key grew by thousands of
##      entries.
##
## Cases c, d, f, h, i and k create symbolic links and are skipped on
## Windows, where creating one needs a privilege.
##
## No mocks: ``cargo metadata`` and the production emitter
## (``rustConvention().emitFragment``) run unmodified, and the cargo and
## rustc used are whichever are on ``PATH``. When either is missing the case
## is skipped with a reason, as the other Rust convention cases are. Every
## fixture change is first checked with a fresh ``cargo metadata`` run, so
## that a case fails on the convention and not on a fixture cargo would
## reject or read differently.
##
## Each case first clears what a developer shell may export for cargo (see
## ``isolateFromAmbientCargo``), the same isolation as
## ``test_rust_convention_build_script_members``.

import std/[algorithm, json, os, osproc, sets, strtabs, strutils,
            tables, tempfiles, times, unittest]
import repro_test_support/reasoned_skip

import repro_core
import repro_core/process_streams
import repro_provider_runtime
import repro_project_dsl
import repro_standard_provider/convention
import repro_standard_provider/conventions/rust as rust_convention

proc isolateFromAmbientCargo(root: string) =
  ## Clear, for this whole process, every variable through which the
  ## caller's shell could steer cargo, and move ``CARGO_HOME`` to an empty
  ## directory under ``root``. Process-wide on purpose: this file is its own
  ## process.
  for name in ["CARGO_TARGET_DIR", "CARGO_BUILD_TARGET_DIR",
               "CARGO_BUILD_TARGET", "RUSTFLAGS", "CARGO_ENCODED_RUSTFLAGS",
               "CARGO_BUILD_RUSTFLAGS", "RUSTC", "CARGO_BUILD_RUSTC",
               "RUSTC_WRAPPER", "CARGO_BUILD_RUSTC_WRAPPER",
               "RUSTC_WORKSPACE_WRAPPER",
               "CARGO_BUILD_RUSTC_WORKSPACE_WRAPPER"]:
    delEnv(name)
  let cargoHome = root / "cargo-home"
  createDir(cargoHome)
  putEnv("CARGO_HOME", cargoHome)

proc dummyRequest(projectRoot: string): ProviderGraphRequest =
  ProviderGraphRequest(
    kind: prkGraphInvocation,
    providerArtifactId: "test-provider",
    entryPointId: "standardProvider.root",
    entryPointBodyHash: "test-body-hash",
    reason: girExplicitUserRequest,
    arguments: projectRoot,
    namespace: "project")

proc inlineArgvOf(action: BuildActionDef): seq[string] =
  for arg in action.call.arguments:
    if arg.name == "argv":
      if arg.encodedValue.len == 0:
        return @[]
      return arg.encodedValue.split("\x1f")
  @[]

proc rustToolchainAvailable(): bool =
  findExe("rustc").len > 0 and findExe("cargo").len > 0

proc flagValue(argv: openArray[string]; flag: string): string =
  for i, arg in argv:
    if arg == flag and i + 1 < argv.len:
      return argv[i + 1]
    if arg.startsWith(flag & "="):
      return arg[flag.len + 1 .. ^1]
  ""

proc runCapture(exe: string; args: openArray[string]; workingDir: string):
    tuple[output: string; exitCode: int] =
  ## Run ``exe`` with the ambient environment, stderr folded into stdout.
  var envTab = newStringTable(modeCaseSensitive)
  for k, v in envPairs():
    envTab[k] = v
  let p = startProcess(exe, workingDir = workingDir, args = args,
    env = envTab, options = {poStdErrToStdOut})
  # ``readAll`` stops at the first short read of the pipe; ``drainStream``
  # reads to end of file.
  let output = drainStream(p.outputStream)
  let code = p.waitForExit()
  p.close()
  (output, code)

proc freshCargoEditions(root: string): Table[string, string] =
  ## What a fresh ``cargo metadata`` run (no cache involved) reports:
  ## package name -> its edition, plus ``<package>/<target>`` -> the
  ## target's kinds for each of its targets. Fails the case when cargo
  ## rejects the fixture, so that the convention is never blamed for a
  ## fixture cargo would not load either.
  let (output, exitCode) = runCapture(findExe("cargo"),
    ["metadata", "--format-version=1", "--no-deps", "--offline",
     "--manifest-path", root / "Cargo.toml"], root)
  checkpoint "fresh cargo metadata exit " & $exitCode
  doAssert exitCode == 0, "cargo rejects the fixture:\n" & output
  let start = output.find('{')
  doAssert start >= 0, "cargo metadata printed no JSON:\n" & output
  let node = parseJson(output[start .. ^1])
  for pkg in node["packages"]:
    let name = pkg["name"].getStr()
    result[name] = pkg["edition"].getStr()
    for target in pkg["targets"]:
      var kinds: seq[string] = @[]
      for k in target["kind"]:
        kinds.add(k.getStr())
      result[name & "/" & target["name"].getStr()] = kinds.join(",")

type
  EmittedFragment = object
    byId: Table[string, BuildActionDef]
    actionIds: seq[string]   ## every action id, in fragment order
    rustcIds: seq[string]
      ## the ids of the actions that run ``rustc`` on a crate, sorted
    signature: HashSet[string]
      ## every action as ``<id>\t<argv joined by US>``: what the
      ## comparison with a cold emit compares

proc emittedFragment(root: string): EmittedFragment =
  let conv = rust_convention.rustConvention()
  let request = dummyRequest(root)
  doAssert conv.recognize(root, request), "fixture not recognised"
  let fragment = conv.emitFragment(root, request)
  for node in fragment.nodes:
    if node.kind != gnkAction:
      continue
    let action = decodeBuildActionPayload(toBytes(node.payload))
    result.actionIds.add(action.id)
    result.byId[action.id] = action
    let argv = inlineArgvOf(action)
    result.signature.incl(action.id & "\t" & argv.join("\x1f"))
    if argv.len > 0 and argv[0].extractFilename.startsWith("rustc") and
        flagValue(argv, "--crate-name").len > 0:
      result.rustcIds.add(action.id)
  result.rustcIds.sort()

proc rustcActionsOf(emitted: EmittedFragment; crateName: string): seq[string] =
  for id in emitted.rustcIds:
    if flagValue(inlineArgvOf(emitted.byId[id]), "--crate-name") == crateName:
      result.add(id)

proc editionsOf(emitted: EmittedFragment; crateName: string): seq[string] =
  ## The ``--edition`` of every ``rustc`` action compiling ``crateName``,
  ## deduplicated and sorted.
  var seen: HashSet[string]
  for id in emitted.rustcActionsOf(crateName):
    seen.incl(flagValue(inlineArgvOf(emitted.byId[id]), "--edition"))
  for e in seen:
    result.add(e)
  result.sort()

proc emitCacheDir(root: string): string =
  root / ".repro" / "build" / ".emit-cache"

proc coldEmit(root: string): EmittedFragment =
  ## The emit the convention makes with no cache: what fresh metadata
  ## yields. Leaves the cache refilled, as any emit does.
  removeDir(emitCacheDir(root))
  require not dirExists(emitCacheDir(root))
  emittedFragment(root)

template requireMatchesColdEmit(root: string; warm: EmittedFragment) =
  ## The warm fragment is exactly the cold one, action for action.
  let cold = coldEmit(root)
  checkpoint "warm actions: " & $warm.actionIds
  checkpoint "cold actions: " & $cold.actionIds
  for entry in warm.signature - cold.signature:
    checkpoint "only in the warm emit: " & entry
  for entry in cold.signature - warm.signature:
    checkpoint "only in the cold emit: " & entry
  check warm.signature == cold.signature

proc writeRoot(root: string; members: openArray[string]) =
  ## A virtual workspace at ``root`` with ``members`` and a binary member
  ## ``a`` (no dependencies) under it.
  createDir(root / "a" / "src")
  writeFile(root / "reprobuild.nim",
    "import repro_project_dsl\n" &
    "package emitCacheInputs:\n" &
    "  uses:\n" &
    "    \"rust >=1.80\"\n")
  var quoted: seq[string] = @[]
  for m in members:
    quoted.add("\"" & m & "\"")
  writeFile(root / "Cargo.toml",
    "[workspace]\n" &
    "resolver = \"2\"\n" &
    "members = [" & quoted.join(", ") & "]\n")
  writeFile(root / "a" / "Cargo.toml",
    "[package]\n" &
    "name = \"a\"\n" &
    "version = \"0.1.0\"\n" &
    "edition = \"2021\"\n" &
    "publish = false\n")
  writeFile(root / "a" / "src" / "main.rs",
    "fn main() {\n" &
    "    println!(\"a\");\n" &
    "}\n")

proc libManifest(name, edition: string; workspace = ""; extra = ""): string =
  "[package]\n" &
    "name = \"" & name & "\"\n" &
    "version = \"0.1.0\"\n" &
    "edition = \"" & edition & "\"\n" &
    "publish = false\n" &
    (if workspace.len > 0: "workspace = \"" & workspace & "\"\n" else: "") &
    extra

proc writeLib(dir, name, edition: string; workspace = "") =
  ## A library package ``name`` in ``dir``; its manifest is
  ## ``libManifest``'s.
  createDir(dir / "src")
  writeFile(dir / "Cargo.toml", libManifest(name, edition, workspace))
  writeFile(dir / "src" / "lib.rs",
    "pub fn value() -> u32 {\n" &
    "    4217\n" &
    "}\n")

proc writeOutsideMemberFixture(parent: string): string =
  ## ``<parent>/ws`` (returned) lists ``a`` and ``../ext``; ``<parent>/ext``
  ## is library ``b`` naming ``../ws`` as its workspace.
  let root = parent / "ws"
  writeRoot(root, ["a", "../ext"])
  writeLib(parent / "ext", "b", "2021", workspace = "../ws")
  root

proc fileState(path: string): tuple[mtime: Time; content: string] =
  (getLastModificationTime(path), readFile(path))

suite "rust convention: the cargo metadata emit cache sees every input":
  test "a: an edition change in a member outside the root":
    if not rustToolchainAvailable():
      skip("rustc or cargo not on PATH")
    else:
      let parent = createTempDir("test_rust_emit_cache_outside_edition_", "")
      defer:
        removeDir(parent)
      isolateFromAmbientCargo(parent)
      let root = writeOutsideMemberFixture(parent)
      require freshCargoEditions(root)["b"] == "2021"
      let before = emittedFragment(root)
      require before.editionsOf("b") == @["2021"]

      writeFile(parent / "ext" / "Cargo.toml",
        libManifest("b", "2018", workspace = "../ws"))
      require freshCargoEditions(root)["b"] == "2018"
      let after = emittedFragment(root)
      check after.editionsOf("b") == @["2018"]
      requireMatchesColdEmit(root, after)

  test "b: a [[bin]] target added to a member outside the root":
    if not rustToolchainAvailable():
      skip("rustc or cargo not on PATH")
    else:
      let parent = createTempDir("test_rust_emit_cache_outside_bin_", "")
      defer:
        removeDir(parent)
      isolateFromAmbientCargo(parent)
      let root = writeOutsideMemberFixture(parent)
      let before = emittedFragment(root)
      require before.rustcActionsOf("extra").len == 0

      writeFile(parent / "ext" / "src" / "extra.rs",
        "fn main() {\n" &
        "    println!(\"{}\", b::value());\n" &
        "}\n")
      writeFile(parent / "ext" / "Cargo.toml",
        libManifest("b", "2021", workspace = "../ws",
          extra = "\n[[bin]]\nname = \"extra\"\npath = \"src/extra.rs\"\n"))
      require freshCargoEditions(root).getOrDefault("b/extra") == "bin"
      let after = emittedFragment(root)
      check after.rustcActionsOf("extra").len > 0
      requireMatchesColdEmit(root, after)

  test "c: an edition change in a member reached through a linked directory":
    if not rustToolchainAvailable():
      skip("rustc or cargo not on PATH")
    elif defined(windows):
      skip("creating a symbolic link needs a privilege on Windows")
    else:
      let parent = createTempDir("test_rust_emit_cache_linked_dir_", "")
      defer:
        removeDir(parent)
      isolateFromAmbientCargo(parent)
      let root = parent / "ws"
      writeRoot(root, ["a", "b"])
      writeLib(parent / "real-b", "b", "2021")
      createSymlink("../real-b", root / "b")
      require freshCargoEditions(root)["b"] == "2021"
      let before = emittedFragment(root)
      require before.editionsOf("b") == @["2021"]

      writeFile(parent / "real-b" / "Cargo.toml", libManifest("b", "2018"))
      require freshCargoEditions(root)["b"] == "2018"
      let after = emittedFragment(root)
      check after.editionsOf("b") == @["2018"]
      requireMatchesColdEmit(root, after)

  test "d: an edition change in a linked Cargo.toml's target":
    if not rustToolchainAvailable():
      skip("rustc or cargo not on PATH")
    elif defined(windows):
      skip("creating a symbolic link needs a privilege on Windows")
    else:
      let parent = createTempDir("test_rust_emit_cache_linked_manifest_", "")
      defer:
        removeDir(parent)
      isolateFromAmbientCargo(parent)
      let root = parent / "ws"
      writeRoot(root, ["a", "b"])
      writeLib(root / "b", "b", "2021")
      createDir(parent / "manifests")
      moveFile(root / "b" / "Cargo.toml", parent / "manifests" / "b.toml")
      createSymlink(parent / "manifests" / "b.toml", root / "b" / "Cargo.toml")
      require freshCargoEditions(root)["b"] == "2021"
      let before = emittedFragment(root)
      require before.editionsOf("b") == @["2021"]

      writeFile(parent / "manifests" / "b.toml", libManifest("b", "2018"))
      require freshCargoEditions(root)["b"] == "2018"
      let after = emittedFragment(root)
      check after.editionsOf("b") == @["2018"]
      requireMatchesColdEmit(root, after)

  test "e: a crate directory added under a glob member pattern outside the root":
    if not rustToolchainAvailable():
      skip("rustc or cargo not on PATH")
    else:
      let parent = createTempDir("test_rust_emit_cache_outside_glob_", "")
      defer:
        removeDir(parent)
      isolateFromAmbientCargo(parent)
      let root = parent / "ws"
      writeRoot(root, ["a", "../ext/*"])
      writeLib(parent / "ext" / "c1", "c1", "2021", workspace = "../../ws")
      require "c1" in freshCargoEditions(root)
      let before = emittedFragment(root)
      require before.rustcActionsOf("c1").len > 0
      require before.rustcActionsOf("c2").len == 0

      writeLib(parent / "ext" / "c2", "c2", "2021", workspace = "../../ws")
      require "c2" in freshCargoEditions(root)
      let after = emittedFragment(root)
      check after.rustcActionsOf("c2").len > 0
      requireMatchesColdEmit(root, after)

  test "f: a symbolic link cycle under the root":
    if not rustToolchainAvailable():
      skip("rustc or cargo not on PATH")
    elif defined(windows):
      skip("creating a symbolic link needs a privilege on Windows")
    else:
      let parent = createTempDir("test_rust_emit_cache_link_cycle_", "")
      defer:
        removeDir(parent)
      isolateFromAmbientCargo(parent)
      let root = parent / "ws"
      writeRoot(root, ["a", "b"])
      writeLib(root / "b", "b", "2021")
      # ``loop`` names the root itself, and ``b/up`` the member's parent:
      # a walk that follows links without remembering where it has been
      # never ends.
      createSymlink(root, root / "loop")
      createSymlink("..", root / "b" / "up")
      require freshCargoEditions(root)["b"] == "2021"
      let first = emittedFragment(root)
      check first.editionsOf("b") == @["2021"]
      writeFile(root / "b" / "Cargo.toml", libManifest("b", "2018"))
      require freshCargoEditions(root)["b"] == "2018"
      let after = emittedFragment(root)
      check after.editionsOf("b") == @["2018"]
      requireMatchesColdEmit(root, after)
      # The links do not keep the cache from settling. Neither walk
      # enters them: the walk of the root follows no link to a directory,
      # and the walk of member ``b`` reads only its target directories.
      # One emit after the change writes the key at the latest, and the
      # next one reuses it.
      let cache = emitCacheDir(root)
      discard emittedFragment(root)
      require fileExists(cache / "cargo-metadata.repro-emit-fingerprint")
      let jsonBefore = fileState(cache / "cargo-metadata.cached.json")
      let sidecarBefore =
        fileState(cache / "cargo-metadata.repro-emit-fingerprint")
      sleep(1100)
      discard emittedFragment(root)
      check fileState(cache / "cargo-metadata.cached.json") == jsonBefore
      check fileState(cache / "cargo-metadata.repro-emit-fingerprint") ==
        sidecarBefore

  test "g: an emit with nothing changed reuses the cached metadata":
    if not rustToolchainAvailable():
      skip("rustc or cargo not on PATH")
    else:
      let parent = createTempDir("test_rust_emit_cache_still_used_", "")
      defer:
        removeDir(parent)
      isolateFromAmbientCargo(parent)
      let jsonName = "cargo-metadata.cached.json"
      let sidecarName = "cargo-metadata.repro-emit-fingerprint"

      # A workspace entirely under its root: the first emit already
      # writes the key, and the second reuses it.
      let inRoot = parent / "in-root"
      writeRoot(inRoot, ["a", "b"])
      writeLib(inRoot / "b", "b", "2021")
      let firstInRoot = emittedFragment(inRoot)
      let cacheInRoot = emitCacheDir(inRoot)
      require fileExists(cacheInRoot / jsonName)
      check fileExists(cacheInRoot / sidecarName)
      if fileExists(cacheInRoot / sidecarName):
        let jsonBefore = fileState(cacheInRoot / jsonName)
        let sidecarBefore = fileState(cacheInRoot / sidecarName)
        # Coarse file systems keep whole-second times: wait past one so a
        # rewrite cannot keep the old time.
        sleep(1100)
        let second = emittedFragment(inRoot)
        check fileState(cacheInRoot / jsonName) == jsonBefore
        check fileState(cacheInRoot / sidecarName) == sidecarBefore
        check second.signature == firstInRoot.signature

      # A member outside the root: the first emit has no cached output to
      # read the set of package files from, so it writes no key; the
      # second does; the third reuses it.
      let root = writeOutsideMemberFixture(parent / "outside")
      let cache = emitCacheDir(root)
      discard emittedFragment(root)
      require fileExists(cache / jsonName)
      check not fileExists(cache / sidecarName)
      let second = emittedFragment(root)
      require fileExists(cache / jsonName)
      require fileExists(cache / sidecarName)
      let jsonBefore = fileState(cache / jsonName)
      let sidecarBefore = fileState(cache / sidecarName)
      sleep(1100)
      let third = emittedFragment(root)
      check fileState(cache / jsonName) == jsonBefore
      check fileState(cache / sidecarName) == sidecarBefore
      check third.signature == second.signature
      requireMatchesColdEmit(root, third)

  test "h: a second link to a directory the walk has already entered":
    if not rustToolchainAvailable():
      skip("rustc or cargo not on PATH")
    elif defined(windows):
      skip("creating a symbolic link needs a privilege on Windows")
    else:
      let parent = createTempDir("test_rust_emit_cache_dir_alias_", "")
      defer:
        removeDir(parent)
      isolateFromAmbientCargo(parent)
      let root = parent / "ws"
      writeRoot(root, ["a", "b"])
      writeLib(root / "b", "b", "2021")
      createDir(root / "b" / "examples")
      writeFile(root / "b" / "examples" / "probe.rs",
        "fn main() {\n" &
        "    println!(\"{}\", b::value());\n" &
        "}\n")
      require freshCargoEditions(root).getOrDefault("b/probe") == "example"
      let before = emittedFragment(root)
      # The walk of ``b``'s target directories now reaches ``examples``
      # through two spellings and enters it once: whichever spelling it
      # meets second must still change the key.
      createSymlink("examples", root / "b" / "tests")
      let (output, exitCode) = runCapture(findExe("cargo"),
        ["metadata", "--format-version=1", "--no-deps", "--offline",
         "--manifest-path", root / "Cargo.toml"], root)
      require exitCode == 0
      # ``freshCargoEditions`` keys targets by name, and the example and
      # the test are both ``probe``: count the test target directly.
      var testTargets = 0
      for pkg in parseJson(output[output.find('{') .. ^1])["packages"]:
        for target in pkg["targets"]:
          if target["name"].getStr() == "probe" and
              target["kind"][0].getStr() == "test":
            inc testTargets
      require testTargets == 1
      require "rustc-test-compile-b.test.probe" notin before.byId
      let after = emittedFragment(root)
      check "rustc-test-compile-b.test.probe" in after.byId
      requireMatchesColdEmit(root, after)

  test "i: a link under a glob pattern names an excluded directory":
    if not rustToolchainAvailable():
      skip("rustc or cargo not on PATH")
    elif defined(windows):
      skip("creating a symbolic link needs a privilege on Windows")
    else:
      let parent = createTempDir("test_rust_emit_cache_glob_alias_", "")
      defer:
        removeDir(parent)
      isolateFromAmbientCargo(parent)
      let root = parent / "ws"
      writeRoot(root, ["a", "crates/*"])
      writeFile(root / "Cargo.toml",
        readFile(root / "Cargo.toml") & "exclude = [\"crates/b\"]\n")
      writeLib(root / "crates" / "b", "b", "2021", workspace = "../..")
      require "b" notin freshCargoEditions(root)
      let before = emittedFragment(root)
      require before.rustcActionsOf("b").len == 0

      createSymlink("b", root / "crates" / "c")
      require "b" in freshCargoEditions(root)
      let after = emittedFragment(root)
      check after.rustcActionsOf("b").len > 0
      requireMatchesColdEmit(root, after)

  test "j: a path dependency outside the workspace joins it":
    if not rustToolchainAvailable():
      skip("rustc or cargo not on PATH")
    else:
      let parent = createTempDir("test_rust_emit_cache_path_dep_joins_", "")
      defer:
        removeDir(parent)
      isolateFromAmbientCargo(parent)
      let root = parent / "ws"
      writeRoot(root, ["a"])
      writeFile(root / "a" / "Cargo.toml",
        readFile(root / "a" / "Cargo.toml") &
          "\n[dependencies]\nd = { path = \"../../d\" }\n")
      writeLib(parent / "d", "d", "2021")
      require "d" notin freshCargoEditions(root)
      let before = emittedFragment(root)
      require before.editionsOf("d").len == 0

      writeFile(parent / "d" / "Cargo.toml",
        libManifest("d", "2018", workspace = "../ws"))
      require freshCargoEditions(root).getOrDefault("d") == "2018"
      let after = emittedFragment(root)
      check after.editionsOf("d") == @["2018"]
      requireMatchesColdEmit(root, after)

  test "k: a link to a directory under the root is not followed":
    if not rustToolchainAvailable():
      skip("rustc or cargo not on PATH")
    elif defined(windows):
      skip("creating a symbolic link needs a privilege on Windows")
    else:
      let parent = createTempDir("test_rust_emit_cache_unfollowed_link_", "")
      defer:
        removeDir(parent)
      isolateFromAmbientCargo(parent)
      let root = parent / "ws"
      writeRoot(root, ["a"])
      # What nix-direnv leaves in a project: a link into a large tree
      # (the Nix store) that holds manifests and sources of its own. The
      # tree here is a crate outside the root, and it holds a link cycle
      # (``src/up -> ..``), so a walk that entered it would also have to
      # stop.
      let target = parent / "store" / "x-source"
      writeLib(target, "x", "2021")
      createSymlink("..", target / "src" / "up")
      createDir(root / ".direnv" / "flake-inputs")
      let link = root / ".direnv" / "flake-inputs" / "x-source"
      createSymlink(target, link)
      require "x" notin freshCargoEditions(root)
      let first = emittedFragment(root)
      let cache = emitCacheDir(root)
      let jsonPath = cache / "cargo-metadata.cached.json"
      let sidecarPath = cache / "cargo-metadata.repro-emit-fingerprint"
      require fileExists(jsonPath)
      # The workspace lies under its root, so the first emit writes the
      # key (case g).
      require fileExists(sidecarPath)

      # The sidecar is the key's text, one input per line: no input may
      # lie in the linked tree, by either spelling.
      let targetSpellings = [target, expandSymlink(link),
                             parent / "store", root / ".direnv"]
      for line in readFile(sidecarPath).splitLines:
        for spelling in targetSpellings:
          if spelling in line:
            checkpoint "key input in the linked tree: " & line
          check spelling notin line

      # A change in the linked tree is not a change cargo sees, so it
      # must not re-run cargo.
      let jsonBefore = fileState(jsonPath)
      let sidecarBefore = fileState(sidecarPath)
      sleep(1100)
      writeFile(target / "src" / "lib.rs",
        "pub fn value() -> u32 {\n" &
        "    4218\n" &
        "}\n")
      writeFile(target / "src" / "extra.rs", "pub fn extra() {}\n")
      let second = emittedFragment(root)
      check fileState(jsonPath) == jsonBefore
      check fileState(sidecarPath) == sidecarBefore
      check second.signature == first.signature
      requireMatchesColdEmit(root, second)
