## The fixture package of
## `tests/integration/test_cs_m14_package_build_generates_completion_files.nim`.
##
## Three executables with a `cli:` section, each compiled with `nim.c` from a
## program in `src/` that imports this file (so it compiles in the DSL's thin
## mode) and instantiates its description:
##
## * `csm14-describe` with nim-entrypoints' `cliProgramWithEntryPoint` and
##   `describeProgram`, so it registers the `complete` and `completion`
##   entries;
## * `csm14-entries` with clispec's `cliProgram` and nim-entrypoints'
##   `main:`, so its compile writes an entry list without `complete`;
## * `csm14-plain` with clispec's `cliProgram` alone, so its compile writes
##   no entry list.
##
## The last two print their own completion script for
## `--printCompletion=<shell>`, which the test compares the generated files
## with.
##
## The test copies this package to a scratch directory and fills in:
##
## * `__CLISPEC_SRC__`, `__ENTRYPOINTS_SRC__`: nim-cli-spec's and
##   nim-entrypoints' `src/` directories;
## * `__REPRO_DSL_SRC__`: this repository's `libs/repro_project_dsl/src`,
##   which the programs' thin import of this file needs;
## * `__NATIVE_BACKEND__`: the C compiler Nim calls (`gcc`, or `clang` on
##   macOS);
## * `__DESCRIBE_LINKER__`: empty, or `tools/link-text.sh` (absolute) to make
##   `csm14-describe`'s link write a text file instead of a program.

import repro_project_dsl

when reproDslMode != rdmThin:
  # Imported under another name, so `nim` below is the tool, not the module.
  import reprobuild/dsl/packages/nim as nimTool

const
  ClispecSrc = "__CLISPEC_SRC__"
  EntrypointsSrc = "__ENTRYPOINTS_SRC__"
  ReproDslSrc = "__REPRO_DSL_SRC__"
  DescribeLinker = "__DESCRIBE_LINKER__"

package cs_m14_completion_files:
  defaultToolProvisioning "path"

  uses:
    "nim"
    "__NATIVE_BACKEND__"

  executable csm14Describe:
    name: "csm14-describe"
    cli:
      help "The fixture's program that describes itself"
      flag jobs is int, default = 2, help = "How many jobs to run"
      subcmd "greet", help = "Print a greeting":
        pos who is string, help = "Whom to greet"

  executable csm14Entries:
    name: "csm14-entries"
    cli:
      help "The fixture's program with entries but no self-description"
      flag printCompletion is string, default = "",
        help = "Print this shell's completion script"

  executable csm14Plain:
    name: "csm14-plain"
    cli:
      help "The fixture's program without nim-entrypoints"
      flag printCompletion is string, default = "",
        help = "Print this shell's completion script"

  build:
    for (program, source) in [("csm14-describe", "csm14_describe"),
                              ("csm14-entries", "csm14_entries"),
                              ("csm14-plain", "csm14_plain")]:
      discard nim.c(
        source = "src/" & source & ".nim",
        binary = "build/bin/" & program,
        paths = @[ClispecSrc, EntrypointsSrc, ReproDslSrc],
        nimcache = "build/nimcache/" & program,
        skipUserCfg = true,
        gccLinkerExe = (if program == "csm14-describe": DescribeLinker
                        else: ""),
        actionId = "csm14.compile." & program)
