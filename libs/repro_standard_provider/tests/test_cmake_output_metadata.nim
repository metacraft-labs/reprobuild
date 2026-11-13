## File-API protocol fixtures exercise Windows-only metadata shapes on every
## host. These are parser inputs, not a mocked compiler: real CMake execution
## is covered by test_c_cpp_cmake_convention. The Windows artifact shape comes
## from CMake's Target::DumpArtifacts (cmFileAPICodemodel.cxx): it lists import
## libraries and PDBs even when the linker may not create them.
import std/[json, os, osproc, strutils, unittest]
import repro_standard_provider/conventions/output_discovery

suite "CMake file-API required artifacts and optional byproducts":
  test "main library is obligatory while import library and PDB are optional":
    let root = getTempDir() / "repro-cmake-optional-metadata"
    if dirExists(root): removeDir(root)
    let reply = root / ".cmake/api/v1/reply"
    createDir(reply)
    defer: removeDir(root)
    writeFile(reply / "index-1.json", $(%* {"reply": {"codemodel-v2": {"jsonFile": "model.json"}}}))
    writeFile(reply / "model.json", $(%* {"configurations": [
      {"name": "Release", "targets": [{"name": "hello", "jsonFile": "target.json"}]},
      {"name": "Debug", "targets": [{"name": "hello", "jsonFile": "debug.json"}]}]}))
    writeFile(reply / "debug.json", $(%* {"type": "SHARED_LIBRARY", "nameOnDisk": "hello-debug.dll",
      "artifacts": [{"path": "debug/hello-debug.dll"}]}))
    # Deliberately reorder artifacts: identification uses nameOnDisk, not order
    # or the .lib suffix (which is the mandatory output of a static library).
    writeFile(reply / "target.json", $(%* {"type": "SHARED_LIBRARY", "nameOnDisk": "hello.dll",
      "artifacts": [{"path": "custom/hello.lib"}, {"path": "custom/hello.dll"}, {"path": "custom/hello.pdb"}]}))
    check cmakeTargetOutputs(root, "hello") == @[root / "custom/hello.dll"]
    let fragment = root / "outputs.dyndep"
    require runOutputDiscoveryCommand(@["--convention-outputs", "cmake", root,
      "build-hello", "hello", fragment])
    let contents = readFile(fragment)
    check "output\tbuild-hello\t" & (root / "custom/hello.dll").replace('\\', '/') & "\n" in contents
    check "optional-output\tbuild-hello\t" & (root / "custom/hello.lib").replace('\\', '/') & "\n" in contents
    check "optional-output\tbuild-hello\t" & (root / "custom/hello.pdb").replace('\\', '/') & "\n" in contents
    # The selected Release configuration is not whichever JSON array entry
    # happens to come first.
    writeFile(reply / "model.json", $(%* {"configurations": [
      {"name": "Debug", "targets": [{"name": "hello", "jsonFile": "debug.json"}]},
      {"name": "Release", "targets": [{"name": "hello", "jsonFile": "target.json"}]}]}))
    check cmakeTargetOutputs(root, "hello") == @[root / "custom/hello.dll"]
    # A static .lib is the actual library, so its absence still fails a build.
    writeFile(reply / "target.json", $(%* {"type": "STATIC_LIBRARY", "nameOnDisk": "hello.lib",
      "artifacts": [{"path": "custom/hello.lib"}]}))
    check cmakeTargetOutputs(root, "hello") == @[root / "custom/hello.lib"]

  test "missing primary artifact is malformed metadata rather than optional":
    let root = getTempDir() / "repro-cmake-missing-primary-metadata"
    if dirExists(root): removeDir(root)
    let reply = root / ".cmake/api/v1/reply"
    createDir(reply)
    defer: removeDir(root)
    writeFile(reply / "index-1.json", $(%* {"reply": {"codemodel-v2": {"jsonFile": "model.json"}}}))
    writeFile(reply / "model.json", $(%* {"configurations": [
      {"name": "Release", "targets": [{"name": "hello", "jsonFile": "target.json"}]}]}))
    writeFile(reply / "target.json", $(%* {"type": "EXECUTABLE", "nameOnDisk": "hello.exe",
      "artifacts": [{"path": "hello.pdb"}]}))
    expect ValueError:
      discard cmakeTargetOutputs(root, "hello")

  test "object-library metadata keeps every object obligatory":
    let root = getTempDir() / "repro-cmake-object-metadata"
    if dirExists(root): removeDir(root)
    let reply = root / ".cmake/api/v1/reply"
    createDir(reply)
    defer: removeDir(root)
    writeFile(reply / "index-1.json", $(%* {"reply": {"codemodel-v2": {"jsonFile": "model.json"}}}))
    writeFile(reply / "model.json", $(%* {"configurations": [
      {"name": "Release", "targets": [{"name": "objects", "jsonFile": "target.json"}]}]}))
    writeFile(reply / "target.json", $(%* {"type": "OBJECT_LIBRARY",
      "artifacts": [{"path": "a.obj"}, {"path": "b.obj"}]}))
    check cmakeTargetOutputs(root, "objects") == @[root / "a.obj", root / "b.obj"]

  test "real versioned library identifies an existing primary output":
    let root = getTempDir() / "repro-cmake-versioned-metadata"
    if dirExists(root): removeDir(root)
    let build = root / "build"
    createDir(build / ".cmake/api/v1/query")
    defer: removeDir(root)
    writeFile(build / ".cmake/api/v1/query/codemodel-v2", "")
    writeFile(root / "lib.c", "int answer(void) { return 42; }\n")
    writeFile(root / "CMakeLists.txt", "cmake_minimum_required(VERSION 3.20)\nproject(metadata C)\nadd_library(hello SHARED lib.c)\nset_target_properties(hello PROPERTIES VERSION 1.2 SOVERSION 1 OUTPUT_NAME actual)\n")
    let configure = execCmdEx(@["cmake", "-S", root, "-B", build, "-DCMAKE_BUILD_TYPE=Release"].quoteShellCommand())
    checkpoint configure.output
    require configure.exitCode == 0
    let outputs = cmakeTargetOutputs(build, "hello")
    require outputs.len == 1
    let compile = execCmdEx(@["cmake", "--build", build, "--parallel", "2"].quoteShellCommand())
    checkpoint compile.output
    require compile.exitCode == 0
    check fileExists(outputs[0])
    # Resolve the declared primary path; a symlink to the versioned payload
    # is valid, and must not be confused with a conditionally emitted PDB.
    check "actual" in extractFilename(outputs[0])
