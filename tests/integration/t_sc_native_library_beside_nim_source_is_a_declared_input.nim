## Cross-Repo-Source-Consumption §4.2c — a producer that is a Nim source
## library AND declares a native ``library`` (``kind: shared``) beside its
## source root.
##
## The reported gap (reprobuild-pm issue
## 2026-11-12-a-consumer-cannot-declare-a-sibling-repos-non-library-build-output):
## isonim-render-serve's tests load ``libgpui_nim_shim`` / ``libfreya_nim_shim``,
## built by a ``cargo.build`` edge of the sibling that exports a Nim ``src/``.
## Because ``src/`` exists, the producer was treated as source-only and its
## sub-build was skipped, so the shim was never a declared input of the
## consumer's action and a changed shim did not invalidate its cached result.
##
## Fixture (black-box, the built ``./build/bin/repro``; a fresh tempdir):
##
##   hybridprod/   ``library hybridsrc`` (Nim source root ``src/``) +
##                 ``library hybridshim: kind: shared`` whose edge writes
##                 ``build/lib/libhybridshim.so``
##   consumer/     ``uses: "hybridprod"``; target ``consume`` names the
##                 producer in its tool-identity refs and loads the shim,
##                 target ``base`` does not name it
##
## Cases:
##   1. ``consume`` builds the shim from source and the consumer loads it
##      (the marker carries the shim's stamp) with no LD_LIBRARY_PATH set.
##   2. An edited shim source is rebuilt and the consumer observes the new
##      stamp on its next run.
##   3. ``base``, which does not name the producer, does not build the shim
##      (SC-2/SC-3 scoping is unchanged).
##
## Falsifiability: reverting the §4.2c decision in
## ``repro_cli_support.nim`` (``producerHasNativeLibraryBesideSource``) makes
## case 1 fail — ``src/`` exists, so the sub-build is skipped and the marker is
## never written.
##
## Skip rule: ``cc`` or ``sh`` missing, ``repro`` unbuilt, or a non-Linux host
## (the ``.so`` basename is hard-coded).

import std/[os, osproc, strutils, unittest]
import repro_test_support/reasoned_skip

const ReprobuildRepoRoot = currentSourcePath().parentDir().parentDir().parentDir()
const reproBinary = ReprobuildRepoRoot / "build/bin/repro".addFileExt(ExeExt)

const stampOne = "HYBRID-SHIM-STAMP-ONE-31c9"
const stampTwo = "HYBRID-SHIM-STAMP-TWO-8a52"

proc shimSource(stamp: string): string =
  "const char *hybridshim_stamp(void) { return \"" & stamp & "\"; }\n"

const shimHeader = """
#ifndef HYBRIDSHIM_H
#define HYBRIDSHIM_H
const char *hybridshim_stamp(void);
#endif
"""

const producerRepro = """
import repro_project_dsl
import repro_dsl_stdlib/packages/sh

package hybridprod:
  defaultToolProvisioning "path"

  uses:
    "sh"
    "mkdir"
    "cc"
    "cp"

  library hybridsrc:
    discard

  library hybridshim:
    kind: shared

  build:
    let buildLib = shell(
      command = "mkdir -p build/lib build/include && " &
        "cc -shared -fPIC -o build/lib/libhybridshim.so shim.c && " &
        "cp shim.h build/include/shim.h",
      actionId = "hybridprod.build.hybridshim",
      extraInputs = @["shim.c", "shim.h"],
      extraOutputs = @["build/lib/libhybridshim.so", "build/include/shim.h"],
      cacheable = false)
    appendRegisteredActionToolIdentityRefs(buildLib.id, ["mkdir", "cc", "cp"])
"""

const consumerSource = """
#include <stdio.h>
#include <shim.h>
int main(void) {
  FILE *f = fopen("build/consumed.txt", "w");
  if (!f) return 2;
  fputs(hybridshim_stamp(), f);
  fclose(f);
  return 0;
}
"""

const consumerRepro = """
import repro_project_dsl
import repro_dsl_stdlib/packages/sh

package consumer:
  defaultToolProvisioning "path"

  uses:
    "sh"
    "mkdir"
    "cc"
    "hybridprod"

  build:
    let base = shell(
      command = "mkdir -p build && printf 'base\n' > build/base.txt",
      actionId = "consumer.build.base",
      extraOutputs = @["build/base.txt"])
    appendRegisteredActionToolIdentityRefs(base.id, ["mkdir"])
    let consume = shell(
      command = "mkdir -p build && " &
        "cc -o build/consume main.c -lhybridshim && " &
        "./build/consume",
      actionId = "consumer.build.consume",
      deps = @[base.id],
      extraInputs = @["main.c"],
      extraOutputs = @["build/consume", "build/consumed.txt"])
    appendRegisteredActionToolIdentityRefs(consume.id,
      ["hybridprod", "mkdir", "cc"])
    discard target("base", [base])
    discard target("consume", [base, consume])
"""

proc q(value: string): string = quoteShell(value)

proc run(command: string; cwd = ""): tuple[code: int; output: string] =
  let res = execCmdEx(command, workingDir = cwd)
  (code: res.exitCode, output: res.output)

suite "§4.2c: a native library declared beside a Nim source root":

  test "t_sc_native_library_beside_nim_source_is_a_declared_input":
    if not defined(linux):
      checkpoint("skipped — the fixture assumes the Linux .so layout")
      skip("non-Linux host: the .so basename is hard-coded")
    elif findExe("cc").len == 0 or findExe("sh").len == 0 or
        not fileExists(reproBinary):
      skip("cc/sh missing on PATH or ./build/bin/repro unbuilt")
    else:
      let reproAbs = absolutePath(reproBinary)
      let scratch = getTempDir() / "sc42c-" & $getCurrentProcessId()
      removeDir(scratch)
      createDir(scratch)
      defer: removeDir(scratch)

      let prodRoot = absolutePath(scratch / "hybridprod")
      createDir(prodRoot / "src")
      writeFile(prodRoot / "repro.nim", producerRepro)
      writeFile(prodRoot / "src" / "hybrid_mod.nim", "const hybridMod* = 1\n")
      writeFile(prodRoot / "shim.h", shimHeader)
      writeFile(prodRoot / "shim.c", "#include \"shim.h\"\n" & shimSource(stampOne))

      let consumerRoot = absolutePath(scratch / "consumer")
      createDir(consumerRoot / ".repro")
      writeFile(consumerRoot / "repro.nim", consumerRepro)
      writeFile(consumerRoot / "main.c", consumerSource)
      writeFile(consumerRoot / ".repro" / "develop-overrides.toml", """
schema = "reprobuild.workspace.develop-overrides.v1"

[[override]]
package = "hybridprod"
local_path = "../hybridprod"
state = "editable"
created_at = "2026-11-12T00:00:00Z"
""")

      let shim = prodRoot / "build" / "lib" / "libhybridshim.so"
      let marker = consumerRoot / "build" / "consumed.txt"
      let cacheRoot = absolutePath(scratch / "action-cache-root")
      createDir(cacheRoot)
      check getEnv("LD_LIBRARY_PATH").find("hybridprod") < 0

      proc build(target, report: string): tuple[code: int; output: string] =
        let cmd = q(reproAbs) & " build " & target &
          " --tool-provisioning=path --daemon=off --log=quiet" &
          " --progress=quiet --measure=all" &
          " --write-report=" & q(report) &
          " --action-cache-root=" & q(cacheRoot)
        checkpoint("running: " & cmd)
        result = run(cmd, consumerRoot)
        checkpoint(result.output)

      # (3) An unnamed producer's native library is not built.
      let baseReport = scratch / "base-report.json"
      let (baseCode, _) = build("base", baseReport)
      check baseCode == 0
      check not fileExists(shim)

      # (1) The naming consumer builds the shim and loads it.
      let r1 = scratch / "r1.json"
      let (code1, _) = build("consume", r1)
      check code1 == 0
      check fileExists(shim)
      check fileExists(marker) and readFile(marker).strip() == stampOne

      # (2) The shim is rebuilt from the producer's source on the next build,
      # so an edit to it reaches the consumer's next run. (How the realized
      # library's digest keys the consumer action is the pre-existing SC-2/SC-3
      # fold; this case covers what §4.2c adds, the producer sub-build.)
      writeFile(prodRoot / "shim.c", "#include \"shim.h\"\n" & shimSource(stampTwo))
      let r2 = scratch / "r2.json"
      let (code2, _) = build("consume", r2)
      check code2 == 0
      check fileExists(marker) and readFile(marker).strip() == stampTwo
