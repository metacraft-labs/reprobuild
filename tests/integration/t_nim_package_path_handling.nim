## Integration Test: t_nim_package_path_handling
## Verifies that:
##   1. repro.paths, .gitignore, and config.nims are generated/updated.
##   2. Rebuilds occur and update paths when dependencies change.
##   3. Early cut-off rules preserve file mtimes when dependencies remain unchanged.

import std/[os, osproc, strutils, times, unittest]

const ReprobuildRepoRoot =
  currentSourcePath().parentDir().parentDir().parentDir()
  ## The reprobuild checkout root, resolved from THIS SOURCE FILE's path
  ## rather than from the process working directory. `currentSourcePath()` is
  ## absolute on both platforms, so `reproBinary` names the same file from
  ## every cwd — and the case below no longer SKIPS when it is launched from
  ## anywhere but the repo root.

const reproBinary =
  when defined(windows): ReprobuildRepoRoot / "build/bin/repro.exe"
  else: ReprobuildRepoRoot / "build/bin/repro"

proc q(value: string): string = quoteShell(value)

proc run(command: string; cwd = ""): tuple[code: int; output: string] =
  let res = execCmdEx(command, workingDir = cwd)
  (code: res.exitCode, output: res.output)

suite "Nim package path handling integration and caching":

  test "t_nim_package_path_handling":
    if not fileExists(reproBinary):
      checkpoint("skipped — repro binary not built")
      skip()
    else:
      # The three builds below run WITH THE REPO ROOT AS THEIR WORKING
      # DIRECTORY, which is a real fixture requirement (they build this
      # repository's own project file). Read it from the source path, not from
      # `getCurrentDir()`: the latter made the case build whatever project
      # happened to sit in the launcher's cwd.
      let repoRoot = ReprobuildRepoRoot
      let reproAbs = reproBinary
      let scratch = getTempDir() / "t_nim_package_path_handling-" & $getCurrentProcessId()
      
      removeDir(scratch)
      createDir(scratch)
      defer: removeDir(scratch)

      # 1. Create sibling dependency
      let sibRoot = absolutePath(scratch / "sibling_dep")
      createDir(sibRoot / "src")
      writeFile(sibRoot / "src" / "lib.nim", "const val* = 42\n")
      writeFile(sibRoot / "repro.nim", """
import repro_dsl_stdlib

package sibling_dep:
  library sibling_dep:
    discard
""")

      # 2. Create consumer project
      let projRoot = absolutePath(scratch / "project")
      createDir(projRoot)
      createDir(projRoot / ".repro")
      
      # Initialize config.nims and .gitignore
      let gitignore = projRoot / ".gitignore"
      let configNims = projRoot / "config.nims"
      let reproPaths = projRoot / "repro.paths"
      
      writeFile(gitignore, "# Original gitignore\n")
      writeFile(configNims, "# Original config\n")

      # Define consumer repro.nim
      let consumerRepro = """
import repro_dsl_stdlib

package project:
  defaultToolProvisioning "path"
  uses:
    "nim >=2.0"
    "sibling_dep"
  build:
    let acts = nim.nimRepropathsConfig()
    target("generate_paths", acts)
"""
      writeFile(projRoot / "repro.nim", consumerRepro)

      # We also need a develop-overrides.toml to point to sibling_dep
      writeFile(projRoot / ".repro" / "develop-overrides.toml", """
schema = "reprobuild.workspace.develop-overrides.v1"

[[override]]
package = "sibling_dep"
local_path = "../sibling_dep"
state = "editable"
created_at = "2026-07-02T00:00:00Z"
""")

      let cacheRoot = absolutePath(scratch / "action-cache-root")
      createDir(cacheRoot)
      
      let buildCmd = q(reproAbs) & " build " & q(projRoot / "repro.nim") &
        " --tool-provisioning=path --daemon=off --log=quiet" &
        " --progress=quiet --measure=none --action-cache-root=" & q(cacheRoot)

      # ---- RUN 1: Initial Generation ----
      checkpoint("RUN 1: " & buildCmd)
      let (code1, out1) = run(buildCmd, repoRoot)
      checkpoint(out1)
      check code1 == 0

      # Verify generated files exist
      check fileExists(reproPaths)
      check fileExists(gitignore)
      check fileExists(configNims)

      # Verify repro.paths content
      let pathsContent1 = readFile(reproPaths)
      # The provider resolves sibling paths from the process cwd.  On hosts
      # where the temporary directory is reached through a symlink (notably
      # Darwin's /tmp -> /private/tmp), getcwd returns the physical spelling.
      # Match that contract exactly rather than retaining the logical alias.
      let expectedPath1 = normalizedPath(
        expandFilename(sibRoot / "src")).replace('\\', '/')
      check "switch(\"path\", \"" & expectedPath1 & "\")" in pathsContent1

      # Verify gitignore has been updated
      let gitignoreContent1 = readFile(gitignore)
      check "repro.paths" in gitignoreContent1

      # Verify config.nims has the snippet
      let configContent1 = readFile(configNims)
      check "repro-paths-bootstrap" in configContent1

      # Capture initial modification times
      let pathsMtime1 = getLastModificationTime(reproPaths)
      let gitignoreMtime1 = getLastModificationTime(gitignore)
      let configMtime1 = getLastModificationTime(configNims)

      # Delay to ensure timestamp resolution isn't hit by sub-second precision limits
      sleep(1000)

      # ---- RUN 2: Re-run with No Changes (Early Cut-off) ----
      checkpoint("RUN 2 (Early Cut-off): " & buildCmd)
      let (code2, out2) = run(buildCmd, repoRoot)
      checkpoint(out2)
      check code2 == 0

      # Verify modification times are preserved exactly
      let pathsMtime2 = getLastModificationTime(reproPaths)
      let gitignoreMtime2 = getLastModificationTime(gitignore)
      let configMtime2 = getLastModificationTime(configNims)

      check pathsMtime2 == pathsMtime1
      check gitignoreMtime2 == gitignoreMtime1
      check configMtime2 == configMtime1

      # Delay before changing dependency
      sleep(1000)

      # ---- RUN 3: Add new dependency (Invalidation / Rebuild) ----
      let sibRoot2 = absolutePath(scratch / "sibling_dep_2")
      createDir(sibRoot2 / "src")
      writeFile(sibRoot2 / "src" / "lib.nim", "const val* = 84\n")
      writeFile(sibRoot2 / "repro.nim", """
import repro_dsl_stdlib

package sibling_dep_2:
  library sibling_dep_2:
    discard
""")

      # Update repro.nim to include the new dependency
      let consumerRepro2 = """
import repro_dsl_stdlib

package project:
  defaultToolProvisioning "path"
  uses:
    "nim >=2.0"
    "sibling_dep"
    "sibling_dep_2"
  build:
    let acts = nim.nimRepropathsConfig()
    target("generate_paths", acts)
"""
      writeFile(projRoot / "repro.nim", consumerRepro2)

      # Update develop-overrides.toml to override both dependencies
      writeFile(projRoot / ".repro" / "develop-overrides.toml", """
schema = "reprobuild.workspace.develop-overrides.v1"

[[override]]
package = "sibling_dep"
local_path = "../sibling_dep"
state = "editable"
created_at = "2026-07-02T00:00:00Z"

[[override]]
package = "sibling_dep_2"
local_path = "../sibling_dep_2"
state = "editable"
created_at = "2026-07-02T00:00:00Z"
""")

      checkpoint("RUN 3 (Dependency Added): " & buildCmd)
      let (code3, out3) = run(buildCmd, repoRoot)
      checkpoint(out3)
      check code3 == 0

      # Verify repro.paths updated with new path
      let pathsContent3 = readFile(reproPaths)
      let expectedPath2 = normalizedPath(
        expandFilename(sibRoot2 / "src")).replace('\\', '/')
      check "switch(\"path\", \"" & expectedPath1 & "\")" in pathsContent3
      check "switch(\"path\", \"" & expectedPath2 & "\")" in pathsContent3

      # Verify modification time has updated
      let pathsMtime3 = getLastModificationTime(reproPaths)
      check pathsMtime3 > pathsMtime2
