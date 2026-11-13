{.define: reproSourceRevalidationTest.}

## Real filesystem, Git repositories and in-process production dispatch; no
## mocks. Two consumers select different revisions of the same package name,
## proving cached-channel validation checks the source actually reused.
import std/[os, sets, strutils, tables, unittest]
import repro_core/ambient_execution
import repro_lock
import repro_cli_support
import source_producer_fixture

suite "source producer invocation scope":
  test "later builds in the same process revalidate producers":
    when defined(windows):
      skip()
    else:
      let binary = absolutePath("build/bin/repro")
      require fileExists(binary)
      let root = createSourceFixture()
      defer: removeDir(root)
      let originalDir = getCurrentDir()
      var saved: seq[tuple[key, value: string, present: bool]]
      for (key, value) in sourceFixtureEnv(root):
        saved.add((key, getEnv(key), existsEnv(key)))
        putEnv(key, value)
      setCurrentDir(root / "consumer")
      defer:
        setCurrentDir(originalDir)
        for item in saved:
          if item.present: putEnv(item.key, item.value)
          else: delEnv(item.key)
      let args = @["--daemon=off", "--tool-provisioning=from-source",
        "--progress=quiet", "--log=quiet"]
      require runSourceRevalidationBuildForTest(args, binary) == 0
      check readFile("build/result.txt") == "implementation-one\n"
      check fromSourceResolvedRecipes.len == 0
      writeFile(root / "catalog/probe/repro.nim",
        producerRecipe.replace("source = inputName", "source = \"two.txt\""))
      require runSourceRevalidationBuildForTest(args, binary) == 0
      check readFile("build/result.txt") == "implementation-two\n"
      check fromSourceResolvedRecipes.len == 0


  test "cached producer channels must agree with the next consumer pin":
    let git = uncontrolledFindExe("git")
    require git.len > 0
    let binary = absolutePath("build/bin/repro")
    require fileExists(binary)
    let root = absolutePath(getTempDir() / ("source-pin-reuse-" &
      $getCurrentProcessId()))
    removeDir(root)
    createDir(root)
    defer: removeDir(root)
    let originalDir = getCurrentDir()
    defer: setCurrentDir(originalDir)
    producerMaterializedAuxPaths.clear()
    producerMaterializedBinDirs.clear()
    defer:
      producerMaterializedAuxPaths.clear()
      producerMaterializedBinDirs.clear()
      producerSourceBindings.clear()

    proc gitRun(directory: string; args: openArray[string]): string =
      var command = quoteShell(git) & " -C " & quoteShell(directory)
      for arg in args: command.add(" " & quoteShell(arg))
      let execution = uncontrolledExecCmdEx(command)
      doAssert execution.exitCode == 0, execution.output
      execution.output.strip()

    proc projectSet(label: string): tuple[consumer, library, revision: string] =
      let library = root / label / "libprod"
      let consumer = root / label / "consumer"
      createDir(library / "src")
      createDir(consumer / "build")
      writeFile(library / "repro.nim", """
import repro_project_dsl
package libprod:
  defaultToolProvisioning "path"
  library libprod
""")
      writeFile(library / "src/libprod.nim", "const revision* = " & label.escape & "\n")
      discard gitRun(library, ["init", "--quiet"])
      discard gitRun(library, ["config", "user.name", "Source Pin Fixture"])
      discard gitRun(library, ["config", "user.email", "source-pin@example.invalid"])
      discard gitRun(library, ["add", "-A"])
      discard gitRun(library, ["commit", "--quiet", "-m", label])
      let revision = gitRun(library, ["rev-parse", "HEAD"])
      writeFile(consumer / "repro.nim", """
import repro_project_dsl
import repro_dsl_stdlib/fs as fs
package consumer:
  defaultToolProvisioning "path"
  uses:
    "libprod"
  build:
    let marker = fs.writeText(text = "built", output = "build/marker")
    discard collect("default", @[marker])
""")
      var lock = LockedDependencies(schema: "reprobuild.solved-graph-lock.v2",
        platform: currentPlatformId(), optimal: true,
        inputsDigest: inputsDigestOf("source-pin-reuse"))
      lock.deps.add(LockedDep(name: "libprod", path: "../libprod",
        coordinates: Coordinates(kind: ckVcs, url: library, revision: revision),
        integrity: gitObjectMultihash("sha1", revision)))
      writeFile(consumer / "repro.lock", serializeLockedDependencies(lock))
      (consumer, library, revision)

    let old = projectSet("old")
    let current = projectSet("current")
    require old.revision != current.revision
    proc hasProducerSource(expected: string): bool =
      let paths = producerMaterializedAuxPaths["libprod"].nimPathDirs
      # Darwin's temporary directory has /var and /private/var aliases.
      # Compare filesystem identity while still requiring exactly one root.
      paths.len == 1 and sameFile(paths[0], expected / "src")
    let args = @["--daemon=off", "--tool-provisioning=path",
      "--progress=quiet", "--log=quiet", "--action-cache-root=" & (root / "cache")]
    setCurrentDir(old.consumer)
    require runSourceRevalidationBuildForTest(args, binary) == 0
    require producerMaterializedAuxPaths.hasKey("libprod")
    check hasProducerSource(old.library)
    # The same pin can reuse its channels; only disagreement must refuse.
    require runSourceRevalidationBuildForTest(args, binary) == 0
    setCurrentDir(current.consumer)
    var refusal = ""
    try:
      discard runSourceRevalidationBuildForTest(args, binary)
    except OSError as error:
      # The in-process dispatcher propagates errors; the public CLI catches
      # them at its outer boundary and returns a failure status instead.
      refusal = error.msg
    check refusal.contains("source revision mismatch")
    check refusal.contains(old.library)
    check refusal.contains(current.consumer / "repro.lock")
    check refusal.contains(old.revision)
    check refusal.contains(current.revision)
    check not fileExists(current.consumer / "build/marker")
    check hasProducerSource(old.library)
    # B is independently valid: after dropping A's retained channels, the
    # identical second consumer succeeds and records B's actual source paths.
    producerMaterializedAuxPaths.clear()
    producerMaterializedBinDirs.clear()
    require runSourceRevalidationBuildForTest(args, binary) == 0
    check hasProducerSource(current.library)
    check readFile(current.consumer / "build/marker") == "built"
