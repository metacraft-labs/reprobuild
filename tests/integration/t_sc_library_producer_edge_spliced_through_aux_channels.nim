## Cross-Repo-Source-Consumption SC-3 — producer graph load + splice
## (LIBRARY channel). A consumer whose build action LINKS + LOADS a sibling
## PRODUCER project's declared ``library`` builds that sibling's shared library
## FROM SOURCE first and links/loads it through the EXISTING aux channels
## (``CPATH`` / ``LIBRARY_PATH`` / ``LD_LIBRARY_PATH``) — no prebuilt ``.so``
## planted, no ``cd ../sib && cargo build``, no hand-copied artifact, no
## ``patchelf``, and NO ``LD_LIBRARY_PATH`` set by the test.
##
## Spec: ``Cross-Repo-Source-Consumption.md`` §4.2 point 4 (library channel) +
## §7.2 (the codetracer-native-backend library example) + §1.2 / §2 (the aux
## channels REUSED, not rebuilt). Milestone:
## ``Cross-Repo-Source-Consumption.milestones.org`` §SC-3.
##
## Fixture (built ``./build/bin/repro``, black-box; every path in a fresh
## tempdir so nothing touches $HOME):
##
##   <scratch>/
##     libprod/                      the sibling PRODUCER project repo
##       repro.nim                   declares ``library scprodlib`` (shared) +
##                                   a build edge that compiles the sibling's
##                                   own C source into build/lib/libscprodlib.so
##                                   and installs its header to build/include
##       greeting.c / greeting.h     the sibling's library source
##     consumer/                     the CONSUMER project repo
##       repro.nim                   ``uses: "libprod"`` + a build action that
##                                   compiles a C program #include-ing the
##                                   sibling's header and linking -lscprodlib,
##                                   then RUNS it, capturing its output
##       main.c                      the consuming program (#include <greeting.h>)
##       .repro/develop-overrides.toml   develop override: libprod -> ../libprod
##
## The develop override maps the consumer's ``uses: "libprod"`` selector to the
## sibling checkout (§5.1). ``repro build`` on the consumer must, via the SC-3
## pre-pass: load ``../libprod/repro.nim``, build its declared ``library``'s
## producing edge from source (recursively, in-process), realize
## ``../libprod/build/lib/libscprodlib.so`` + ``../libprod/build/include/greeting.h``,
## and project the realized library dir onto ``LIBRARY_PATH`` + ``LD_LIBRARY_PATH``
## and the include dir onto ``CPATH`` for the consuming action — so
## ``cc main.c -lscprodlib`` compiles (header found via CPATH, symbol found via
## LIBRARY_PATH) and the produced program runs (library found via
## LD_LIBRARY_PATH). No aux env var is set by this test.
##
## Assertions:
##   1. ``repro build`` on the consumer exits 0.
##   2. The producer library ``../libprod/build/lib/libscprodlib.so`` was
##      materialized BY THIS RUN (it was removed before the build; nothing
##      planted it).
##   3. The consumer's action linked + loaded the freshly-built producer
##      library: the marker file ``consumer/build/consumed.txt`` carries the
##      producer library's unique stamp, RETURNED by the library function the
##      consuming C program called (proving the header was found via CPATH, the
##      symbol was linked via LIBRARY_PATH, and the ``.so`` loaded at run time
##      via LD_LIBRARY_PATH — all fed from the SC-3 aux-channel splice, not from
##      any env the test set).
##
## Falsifiability (reproduced by the implementation agent): editing the SC-3
## pre-pass so it does NOT record ``producerMaterializedAuxPaths`` (leaving the
## realized library dirs off the aux channels) makes the consumer's
## ``cc main.c -lscprodlib`` action fail — the header/symbol/loader are not on
## CPATH/LIBRARY_PATH/LD_LIBRARY_PATH, so the build exits non-zero (assertion 1
## trips) and the marker file is never written (assertion 3 trips). Reverting
## the edit restores green.
##
## Skip rule: ``cc`` or ``sh`` missing on PATH, or ``./build/bin/repro`` unbuilt,
## or a non-ELF host (the ``.so`` layout assumed here is Linux; on macOS the
## same channels carry ``.dylib`` but the test's hard-coded ``.so`` basename
## would need the platform ext — kept Linux-only to stay hermetic).

import std/[os, osproc, strutils, unittest]

const reproBinary = "./build/bin/repro"

# The producer library's UNIQUE stamp — the library function returns exactly
# this string. It cannot appear in the consumer's marker unless the sibling
# library was built from source AND its symbol was linked + loaded.
const producerStamp = "SC3-LIBPRODUCER-STAMP-7b4e0d"

# The sibling library's C header. Declares the one exported function.
const producerHeader = """
#ifndef SCPRODLIB_GREETING_H
#define SCPRODLIB_GREETING_H
const char *scprodlib_greeting(void);
#endif
"""

# The sibling library's C source. Returns the unique stamp.
const producerSource = "#include \"greeting.h\"\n" &
  "const char *scprodlib_greeting(void) { return \"" & producerStamp & "\"; }\n"

# The producer sibling repo. ``library scprodlib`` (shared) is the declared
# consumable library. The build edge is a real ``shell(...)`` action that
# compiles the sibling's own C source into the canonical build/lib output
# layout (libscprodlib.so) and installs the header to build/include — exactly
# the realized-library layout SC-3 discovers and projects onto the aux channels.
const producerRepro = """
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

# The consuming program. #include-s the sibling header (found only via CPATH)
# and calls the library function (linked only via LIBRARY_PATH -lscprodlib,
# loaded only via LD_LIBRARY_PATH). It writes the returned stamp to a marker.
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

# The consumer repo. ``uses: "libprod"`` names the sibling producer; the
# develop override maps it to ../libprod. The build action compiles + links +
# runs a C program against the sibling library WITHOUT any -I/-L path and
# WITHOUT any LD_LIBRARY_PATH — it only works if the SC-3 splice put the
# sibling's realized library + header dirs on CPATH/LIBRARY_PATH/LD_LIBRARY_PATH.
const consumerRepro = """
import repro_project_dsl
import repro_dsl_stdlib/packages/sh

package consumer:
  defaultToolProvisioning "path"

  uses:
    "sh"
    "libprod"

  build:
    discard shell(
      command = "mkdir -p build && " &
        "cc -o build/consume main.c -lscprodlib && " &
        "./build/consume",
      actionId = "consumer.build.consume",
      extraInputs = @["main.c"],
      extraOutputs = @["build/consume", "build/consumed.txt"],
      cacheable = false)
"""

proc q(value: string): string = quoteShell(value)

proc run(command: string; cwd = ""): tuple[code: int; output: string] =
  let res = execCmdEx(command, workingDir = cwd)
  (code: res.exitCode, output: res.output)

suite "SC-3: library producer edge spliced through aux channels":

  test "t_sc_library_producer_edge_spliced_through_aux_channels":
    let ccBin = findExe("cc")
    let shBin = findExe("sh")
    let onLinux = defined(linux)
    if not onLinux:
      checkpoint("skipped — SC-3 test fixture assumes the Linux .so layout")
      skip()
    elif ccBin.len == 0 or shBin.len == 0 or not fileExists(reproBinary):
      checkpoint("skipped — cc/sh missing on PATH or repro unbuilt")
      skip()
    else:
      let repoRoot = getCurrentDir()
      let reproAbs = absolutePath(reproBinary)
      let scratch = getTempDir() / "sc3-" & $getCurrentProcessId()
      removeDir(scratch)
      createDir(scratch)
      defer: removeDir(scratch)

      # ---- The sibling PRODUCER library project. ----
      let prodRoot = absolutePath(scratch / "libprod")
      createDir(prodRoot)
      writeFile(prodRoot / "repro.nim", producerRepro)
      writeFile(prodRoot / "greeting.h", producerHeader)
      writeFile(prodRoot / "greeting.c", producerSource)

      # ---- The CONSUMER project + its develop override for the producer. ----
      let consumerRoot = absolutePath(scratch / "consumer")
      createDir(consumerRoot)
      writeFile(consumerRoot / "repro.nim", consumerRepro)
      writeFile(consumerRoot / "main.c", consumerSource)
      createDir(consumerRoot / ".repro")
      writeFile(consumerRoot / ".repro" / "develop-overrides.toml", """
schema = "reprobuild.workspace.develop-overrides.v1"

[[override]]
package = "libprod"
local_path = "../libprod"
state = "editable"
created_at = "2026-07-02T00:00:00Z"
""")

      # Nothing prebuilt: the producer library must NOT exist before the build,
      # so assertion (2) measures whether THIS run produced it.
      let producerLibrary = prodRoot / "build" / "lib" / "libscprodlib.so"
      check not fileExists(producerLibrary)
      let consumedMarker = consumerRoot / "build" / "consumed.txt"
      if fileExists(consumedMarker):
        removeFile(consumedMarker)

      # Guard: the test itself sets NO aux env var. The only way the consuming
      # ``cc main.c -lscprodlib`` action can find the header, link the symbol,
      # and load the .so is via the SC-3 splice of the sibling's freshly-built
      # library dirs onto CPATH/LIBRARY_PATH/LD_LIBRARY_PATH.
      check getEnv("SCPRODLIB_STAGED").len == 0

      # ---- Build the consumer. The SC-3 pre-pass must build ../libprod first
      # and splice its realized library + header dirs onto the aux channels so
      # the consumer's cc action links + loads the freshly-built library. ----
      let cmd = q(reproAbs) & " build " & q(consumerRoot / "repro.nim") &
        " --tool-provisioning=path --daemon=off --log=quiet" &
        " --progress=quiet --report=none"
      checkpoint("running: " & cmd)
      let (code, output) = run(cmd, repoRoot)
      checkpoint("exit=" & $code)
      checkpoint(output)

      # (1) The consumer build succeeds.
      check code == 0

      # (2) The producer library was materialized from source BY THIS RUN.
      check fileExists(producerLibrary)

      # (3) The consumer action linked + loaded the freshly-built producer
      # library: the marker file carries the library's unique stamp, returned
      # by the library function the consuming program called. This is only
      # possible if the SC-3 splice put the sibling's realized library dir on
      # LIBRARY_PATH + LD_LIBRARY_PATH and its include dir on CPATH.
      check fileExists(consumedMarker)
      if fileExists(consumedMarker):
        let consumed = readFile(consumedMarker).strip()
        checkpoint("consumed.txt=" & consumed)
        check consumed == producerStamp
