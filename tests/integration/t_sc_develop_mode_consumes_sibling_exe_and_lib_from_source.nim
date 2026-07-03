## Cross-Repo-Source-Consumption SC-5 — develop-mode from-source consumption
## end-to-end, BOTH channels in ONE consumer build.
##
## This is the combined capstone of SC-2 (executable channel) + SC-3 (library
## channel): a SINGLE consumer whose one build action needs a sibling PRODUCER
## project's declared ``executable`` (invoked by bare name, resolved via the
## PATH splice) AND a DIFFERENT sibling PRODUCER project's declared ``library``
## (linked + loaded via the aux channels), both built FROM SOURCE in place under
## develop mode — no ``direnv``, no ``cd ../sib && just build`` prebuild, nothing
## planted.
##
## Spec: ``Cross-Repo-Source-Consumption.md`` §5.1 (develop mode) + §7.1/§7.2.
## Milestone: ``Cross-Repo-Source-Consumption.milestones.org`` §SC-5.
##
## Fixture (built ``./build/bin/repro``, black-box; every path in a fresh
## tempdir so nothing touches $HOME):
##
##   <scratch>/
##     exeprod/                      sibling EXECUTABLE producer
##       repro.nim                   ``executable exeprod`` + build edge -> build/bin/exeprod
##     libprod/                      sibling LIBRARY producer
##       repro.nim                   ``library scprodlib: kind: shared`` + build edge
##       greeting.{h,c}              -> build/lib/libscprodlib.so + build/include/greeting.h
##     consumer/                     the CONSUMER project repo
##       repro.nim                   ``uses: "exeprod"`` + ``uses: "libprod"`` in ONE action
##       main.c                      #include <greeting.h>, calls scprodlib_greeting()
##       .repro/develop-overrides.toml   develop overrides: BOTH siblings
##
## The one consumer action:
##   1. runs the sibling EXECUTABLE by bare name (``exeprod``) -> build/exe.txt
##      (only resolves via the SC-2 PATH splice of ../exeprod/build/bin),
##   2. compiles + links + runs a C program against the sibling LIBRARY
##      (``cc main.c -lscprodlib`` then ``./build/consume``) -> build/consumed.txt
##      (only resolves via the SC-3 aux-channel splice of ../libprod's realized
##      library/include dirs onto CPATH/LIBRARY_PATH/LD_LIBRARY_PATH).
##
## Assertions:
##   1. ``repro build`` on the consumer exits 0.
##   2. BOTH sibling artifacts were materialized BY THIS RUN (absent before):
##      ../exeprod/build/bin/exeprod AND ../libprod/build/lib/libscprodlib.so.
##   3. The exe marker carries the executable producer's unique stamp AND the
##      lib marker carries the library producer's unique stamp — proving BOTH
##      channels resolved from source in the SAME build.
##   4. Source invalidation (develop): editing the LIBRARY producer's C source to
##      return a NEW stamp and rebuilding the consumer re-runs the consume step
##      and the lib marker carries the NEW stamp (the producer was rebuilt from
##      the edited source, §4.3).
##
## Falsifiability (per §SC-5): removing an override makes the sibling
## unresolvable in develop mode; dropping either splice fails the corresponding
## consume step (the exe bare name is not on PATH / the library header+symbol are
## not on the aux channels). Both are inherited from SC-2/SC-3's own falsifiable
## seams.
##
## Skip rule: ``cc``/``sh`` missing on PATH, or ``./build/bin/repro`` unbuilt, or
## a non-ELF host (the ``.so`` layout assumed here is Linux; kept Linux-only to
## stay hermetic, matching SC-3).

import std/[os, osproc, strutils, unittest]

const reproBinary = "./build/bin/repro"

# The executable producer's UNIQUE stamp — the built ``exeprod`` binary echoes
# exactly this. It cannot appear unless the sibling was built from source AND
# its binary ran (resolved via the SC-2 PATH splice).
const exeStamp = "SC5-EXEPRODUCER-STAMP-3c8b1f"

# The library producer's UNIQUE stamp — the library function returns exactly
# this. It cannot appear unless the sibling library was built from source AND
# its symbol was linked + loaded (via the SC-3 aux channels).
const libStamp = "SC5-LIBPRODUCER-STAMP-a17d92"
# The EDITED library stamp for the source-invalidation arm (assertion 4).
const libStampEdited = "SC5-LIBPRODUCER-STAMP-EDITED-b26e40"

# ---- The sibling EXECUTABLE producer repo (SC-2 shape). ----
const exeProducerRepro = """
import repro_project_dsl
import repro_dsl_stdlib/packages/sh

package exeprod:
  defaultToolProvisioning "path"

  uses:
    "sh"

  executable exeprod:
    name: "exeprod"

  build:
    discard shell(
      command = "mkdir -p build/bin && " &
        "printf '#!/bin/sh\necho """ & exeStamp & """\n' > build/bin/exeprod && " &
        "chmod +x build/bin/exeprod",
      actionId = "exeprod.build.exeprod",
      extraOutputs = @["build/bin/exeprod"])
"""

# ---- The sibling LIBRARY producer repo (SC-3 shape). ----
const libProducerHeader = """
#ifndef SCPRODLIB_GREETING_H
#define SCPRODLIB_GREETING_H
const char *scprodlib_greeting(void);
#endif
"""

proc libProducerSource(stamp: string): string =
  "#include \"greeting.h\"\n" &
  "const char *scprodlib_greeting(void) { return \"" & stamp & "\"; }\n"

const libProducerRepro = """
import repro_project_dsl
import repro_dsl_stdlib/packages/sh

package libprod:
  defaultToolProvisioning "path"

  uses:
    "sh"

  library scprodlib:
    kind: shared

  build:
    discard shell(
      command = "mkdir -p build/lib build/include && " &
        "cc -shared -fPIC -o build/lib/libscprodlib.so greeting.c && " &
        "cp greeting.h build/include/greeting.h",
      actionId = "libprod.build.scprodlib",
      extraInputs = @["greeting.c", "greeting.h"],
      extraOutputs = @["build/lib/libscprodlib.so", "build/include/greeting.h"],
      cacheable = false)
"""

# ---- The consuming C program (SC-3 shape): #include <greeting.h> (via CPATH),
# calls the library function (linked via -lscprodlib on LIBRARY_PATH, loaded via
# LD_LIBRARY_PATH). It writes the returned stamp to build/consumed.txt. ----
const consumerSource = """
#include <stdio.h>
#include <greeting.h>
int main(void) {
  FILE *f = fopen("build/consumed.txt", "w");
  if (!f) return 2;
  fputs(scprodlib_greeting(), f);
  fclose(f);
  return 0;
}
"""

# ---- The consumer repo. ONE action consumes BOTH producers: it invokes the
# sibling EXECUTABLE by bare name (SC-2) AND compiles/links/runs against the
# sibling LIBRARY (SC-3), WITHOUT any -I/-L path and WITHOUT any LD_LIBRARY_PATH
# — it only works if BOTH the SC-2 PATH splice and the SC-3 aux-channel splice
# fire in the SAME build. ----
const consumerRepro = """
import repro_project_dsl
import repro_dsl_stdlib/packages/sh

package consumer:
  defaultToolProvisioning "path"

  uses:
    "sh"
    "exeprod"
    "libprod"

  build:
    discard shell(
      command = "mkdir -p build && " &
        "exeprod > build/exe.txt && " &
        "cc -o build/consume main.c -lscprodlib && " &
        "./build/consume",
      actionId = "consumer.build.consume",
      extraInputs = @["main.c"],
      extraOutputs = @["build/exe.txt", "build/consume", "build/consumed.txt"],
      cacheable = false)
"""

proc q(value: string): string = quoteShell(value)

proc run(command: string; cwd = ""): tuple[code: int; output: string] =
  let res = execCmdEx(command, workingDir = cwd)
  (code: res.exitCode, output: res.output)

suite "SC-5: develop-mode consumes sibling exe AND lib from source":

  test "t_sc_develop_mode_consumes_sibling_exe_and_lib_from_source":
    let ccBin = findExe("cc")
    let shBin = findExe("sh")
    let onLinux = defined(linux)
    if not onLinux:
      checkpoint("skipped — SC-5 test fixture assumes the Linux .so layout")
      skip()
    elif ccBin.len == 0 or shBin.len == 0 or not fileExists(reproBinary):
      checkpoint("skipped — cc/sh missing on PATH or repro unbuilt")
      skip()
    else:
      let repoRoot = getCurrentDir()
      let reproAbs = absolutePath(reproBinary)
      let scratch = getTempDir() / "sc5-" & $getCurrentProcessId()
      removeDir(scratch)
      createDir(scratch)
      defer: removeDir(scratch)

      # ---- The sibling EXECUTABLE producer. ----
      let exeProdRoot = absolutePath(scratch / "exeprod")
      createDir(exeProdRoot)
      writeFile(exeProdRoot / "repro.nim", exeProducerRepro)

      # ---- The sibling LIBRARY producer. ----
      let libProdRoot = absolutePath(scratch / "libprod")
      createDir(libProdRoot)
      writeFile(libProdRoot / "repro.nim", libProducerRepro)
      writeFile(libProdRoot / "greeting.h", libProducerHeader)
      writeFile(libProdRoot / "greeting.c", libProducerSource(libStamp))

      # ---- The CONSUMER project + its develop overrides for BOTH siblings. ----
      let consumerRoot = absolutePath(scratch / "consumer")
      createDir(consumerRoot)
      writeFile(consumerRoot / "repro.nim", consumerRepro)
      writeFile(consumerRoot / "main.c", consumerSource)
      createDir(consumerRoot / ".repro")
      writeFile(consumerRoot / ".repro" / "develop-overrides.toml", """
schema = "reprobuild.workspace.develop-overrides.v1"

[[override]]
package = "exeprod"
local_path = "../exeprod"
state = "editable"
created_at = "2026-07-02T00:00:00Z"

[[override]]
package = "libprod"
local_path = "../libprod"
state = "editable"
created_at = "2026-07-02T00:00:00Z"
""")

      # Nothing prebuilt: BOTH sibling artifacts must NOT exist before the build,
      # so assertion (2) measures whether THIS run produced them.
      let exeProducerBinary = exeProdRoot / "build" / "bin" /
        addFileExt("exeprod", ExeExt)
      let libProducerLibrary = libProdRoot / "build" / "lib" / "libscprodlib.so"
      check not fileExists(exeProducerBinary)
      check not fileExists(libProducerLibrary)

      let exeMarker = consumerRoot / "build" / "exe.txt"
      let libMarker = consumerRoot / "build" / "consumed.txt"
      for m in [exeMarker, libMarker]:
        if fileExists(m):
          removeFile(m)

      # Guard: there is NO host ``exeprod`` that could satisfy the bare name by
      # accident, and the test sets NO aux env var — the ONLY way both consume
      # steps resolve is via the SC-2 + SC-3 splices of the freshly-built
      # sibling dirs.
      check findExe("exeprod").len == 0

      # Hermetic action-cache root: this heavy test drives ``repro build``, which
      # otherwise shares the developer's ``~/.cache/repro/action-cache``. A
      # co-tenant-bloated shared cache (multi-GB) makes the build wedge on a
      # full-file scan. Point each ``repro build`` at a fresh empty cache under
      # this test's scratch (highest-precedence ``--action-cache-root`` flag,
      # ``repro_cli_support.nim:377``) so the test is immune to that bloat and
      # does not pollute the shared cache. This is test hygiene only; it does not
      # change production cache behavior.
      let cacheRoot = absolutePath(scratch / "action-cache-root")
      createDir(cacheRoot)
      let buildCmd = q(reproAbs) & " build " & q(consumerRoot / "repro.nim") &
        " --tool-provisioning=path --daemon=off --log=quiet" &
        " --progress=quiet --report=none" &
        " --action-cache-root=" & q(cacheRoot)

      # ---- Build the consumer. The SC-2/SC-3 pre-pass must build BOTH siblings
      # from source first and splice the exe bin dir onto PATH and the lib dirs
      # onto the aux channels so the single consumer action consumes both. ----
      checkpoint("running (1): " & buildCmd)
      let (code, output) = run(buildCmd, repoRoot)
      checkpoint("exit=" & $code)
      checkpoint(output)

      # (1) The consumer build succeeds.
      check code == 0

      # (2) BOTH sibling artifacts were materialized from source BY THIS RUN.
      check fileExists(exeProducerBinary)
      check fileExists(libProducerLibrary)

      # (3) The consumer action consumed BOTH from source: the exe marker carries
      # the executable producer's stamp (SC-2 PATH splice) and the lib marker
      # carries the library producer's stamp (SC-3 aux-channel splice).
      check fileExists(exeMarker)
      check fileExists(libMarker)
      if fileExists(exeMarker):
        let exeConsumed = readFile(exeMarker).strip()
        checkpoint("exe.txt=" & exeConsumed)
        check exeConsumed == exeStamp
      if fileExists(libMarker):
        let libConsumed = readFile(libMarker).strip()
        checkpoint("consumed.txt=" & libConsumed)
        check libConsumed == libStamp

      # (4) Source invalidation (develop, §4.3): edit the LIBRARY producer's C
      # source to return a NEW stamp; rebuilding the consumer must rebuild the
      # producer from the edited source and re-run the consume step so the lib
      # marker carries the NEW stamp. (The library edge is ``cacheable = false``,
      # so the consume step re-runs; the point proven here is that develop-mode
      # picks up the EDITED sibling source, not a stale prebuilt artifact.)
      writeFile(libProdRoot / "greeting.c", libProducerSource(libStampEdited))
      if fileExists(libMarker):
        removeFile(libMarker)
      checkpoint("running (2, after producer source edit): " & buildCmd)
      let (code2, output2) = run(buildCmd, repoRoot)
      checkpoint("exit2=" & $code2)
      checkpoint(output2)
      check code2 == 0
      check fileExists(libMarker)
      if fileExists(libMarker):
        let libConsumed2 = readFile(libMarker).strip()
        checkpoint("consumed.txt(after edit)=" & libConsumed2)
        check libConsumed2 == libStampEdited
