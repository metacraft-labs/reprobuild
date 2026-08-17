## Named-Runnable-Edges N1 verification — `repro run --choose` (and
## `repro tasks`) lists BOTH a declared dev-env task AND a named run-edge,
## each labelled by source (`[task]` / `[run-edge]`), in a deterministic
## order.
##
## Spec cite: Named-Runnable-Edges.md §3.1 / §5; the N1 milestone
## Verification `t_e2e_repro_run_lists_tasks_and_edges`.
##
## The fixture declares a `devEnv:` block with a `task "greet"` and a
## `run "app-run", build = "build-app"` run-target. Both `repro run
## --choose` and `repro tasks` must show the task under `[task]` and the
## run-edge under `[run-edge]` — proving the listing merges the two
## resolution sources rather than the old task-only view.

import std/[os, strutils, tempfiles, unittest]

import repro_test_support

proc reproBinary(repoRoot: string): string =
  requireBinary(repoRoot / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

proc writeExecutable(path, content: string) =
  createDir(path.splitPath.head)
  writeFile(path, content)
  setFilePermissions(path, {fpUserRead, fpUserWrite, fpUserExec,
    fpGroupRead, fpGroupExec, fpOthersRead, fpOthersExec})

proc writeTool(binDir: string) =
  writeExecutable(binDir / "n1-tool",
    "#!/bin/sh\n" &
    "set -eu\n" &
    "if [ \"${1:-}\" = \"--version\" ]; then echo 'n1-tool 1.0.0'; exit 0; fi\n" &
    "input= output=\n" &
    "while [ \"$#\" -gt 0 ]; do\n" &
    "  case \"$1\" in\n" &
    "    --input) input=$2; shift 2 ;;\n" &
    "    --output) output=$2; shift 2 ;;\n" &
    "    *) echo \"unknown arg $1\" >&2; exit 64 ;;\n" &
    "  esac\n" &
    "done\n" &
    "mkdir -p \"$(dirname \"$output\")\"\n" &
    "cp \"$input\" \"$output\"\n")

proc writeProject(path: string) =
  ## A dev-env task ``greet`` and a named run-edge ``app-run`` coexist.
  let projectRoot = path.splitPath.head
  createDir(projectRoot / "reprobuild" / "packages")
  writeFile(projectRoot / "reprobuild" / "packages" / "n1_tool.nim",
    "import repro_project_dsl\n\n" &
    "defineCliInterface n1Tool, \"n1-tool\":\n" &
    "  call:\n" &
    "    flag input is string, alias = \"--input\", role = input, required = true\n" &
    "    flag output is string, alias = \"--output\", role = output, required = true\n" &
    "    outputs output\n")
  writeFile(path,
    "import repro_project_dsl\n" &
    "import repro_resources\n\n" &
    "package n1ListPkg:\n" &
    "  usesImportPath \"reprobuild/packages\"\n" &
    "  uses:\n" &
    "    \"n1-tool >=1.0 <2.0\"\n\n" &
    "  devEnv:\n" &
    "    task \"greet\", command = \"echo hi\", description = \"say hi\"\n\n" &
    "  build:\n" &
    "    n1Tool(actionId = \"build-app\",\n" &
    "      input = \"src/main.txt\",\n" &
    "      output = \"build/app\")\n" &
    "    run(\"app-run\", build = \"build-app\")\n")

proc runRepro(reproBin, pathValue: string; cwd: string;
              subArgs: openArray[string]): string =
  var args = @[reproBin]
  for a in subArgs:
    args.add(a)
  let entries = @[
    ("PATH", pathValue),
    ("REPRO_TOOL_PROVISIONING", "path")
  ]
  requireSuccess(shellCommand(args, entries), cwd)

suite "t_e2e_repro_run_lists_tasks_and_edges":

  test "t_e2e_repro_run_lists_tasks_and_edges":
    let repoRoot = getCurrentDir()
    let tempRoot = createTempDir("repro-n1-list", "")
    defer: removeDir(tempRoot)

    let reproBin = reproBinary(repoRoot)
    let binDir = tempRoot / "bin"
    writeTool(binDir)
    let pathValue = binDir & $PathSep & getEnv("PATH")

    let projectRoot = tempRoot / "project"
    createDir(projectRoot / "src")
    writeFile(projectRoot / "src" / "main.txt", "main v1\n")
    writeProject(projectRoot / "reprobuild.nim")

    # `repro run --choose` lists both the dev-env task and the run-edge,
    # each labelled by source.
    let chooseOut = runRepro(reproBin, pathValue, projectRoot,
      ["run", "--choose"])
    check chooseOut.contains("[task]")
    check chooseOut.contains("greet")
    check chooseOut.contains("[run-edge]")
    check chooseOut.contains("app-run")

    # `repro tasks` shows the same merged, source-labelled listing.
    let tasksOut = runRepro(reproBin, pathValue, projectRoot, ["tasks"])
    check tasksOut.contains("[task]")
    check tasksOut.contains("greet")
    check tasksOut.contains("[run-edge]")
    check tasksOut.contains("app-run")

    # The documented from-source spelling must be accepted by dev-env
    # introspection, and listing the run edge must not resolve the missing
    # build-only n1-tool from PATH.
    let sourceModeOut = requireSuccess(shellCommand(
      @[reproBin, "tasks"], @[
        ("PATH", getEnv("PATH")),
        ("REPRO_TOOL_PROVISIONING", "from-source"),
      ]), projectRoot)
    check sourceModeOut.contains("[task]")
    check sourceModeOut.contains("greet")
    check sourceModeOut.contains("[run-edge]")
    check sourceModeOut.contains("app-run")
