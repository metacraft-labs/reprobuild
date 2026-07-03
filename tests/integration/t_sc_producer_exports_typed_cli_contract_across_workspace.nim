## Cross-Repo-Source-Consumption SC-8 — a workspace producer's declared
## ``executable … cli:`` / ``library`` schema is a CONSUMABLE TYPED CONTRACT
## keyed by the workspace project name (export-by-default; no new DSL keyword).
##
## Spec: ``Cross-Repo-Source-Consumption.md`` §9.1 (producer export contract) +
## §1.3 (the two-layer split — the compile-time schema this milestone pins down
## sits BELOW the SC-9 ``usesImportCode`` import). Milestone:
## ``Cross-Repo-Source-Consumption.milestones.org`` §SC-8.
##
## This test drives the SC-8 entry point ``resolveProducerTypedContract``
## (defined in ``repro_cli_support``) directly, hermetically, against real
## sibling producer ``repro.nim`` fixtures in a tempdir — nothing touches
## $HOME, no network / git is required. It proves:
##
##   1. **export-by-default typed contract.** A sibling producer declaring
##      ``executable foo: cli:`` (with a named ``bar`` command carrying typed
##      params) is discoverable BY THE WORKSPACE PROJECT NAME and its exported
##      schema is exactly what ``toolActionWrapperCode`` consumes: the command
##      names, params, and ``providerEntrypointId`` projected off the shipped
##      ``ProjectInterface.publicExecutables``. Discovered via BOTH arms —
##      a develop override AND an on-disk workspace sibling.
##   2. **a producer with no executable/library exposes NO contract.** A
##      sibling that declares neither an ``executable`` nor a ``library``
##      resolves to ``ptckNoContract`` (discovered, but nothing to export) —
##      so SC-9 can fail a typed bind loudly instead of silently no-op'ing.
##   3. **a selector naming no workspace producer exposes none.** An unknown
##      selector resolves to ``ptckNoProducer`` — the caller keeps its existing
##      resolution branch (byte-identical for every non-producer selector).
##   4. **library export-by-default.** A sibling declaring only a ``library``
##      block exposes the library as its typed contract (``ptckContract``).
##
## Falsifiability (reproduced by the implementation agent): a producer whose
## ``cli:`` command is RENAMED shifts the exported schema — the OLD command name
## disappears from ``typedContractCommands`` and the NEW one appears. The test
## asserts the exact command-name set both before and after the rename against a
## second producer fixture with the verb renamed, so a consumer (SC-9) binding
## the old name would find no command. Reverting the SC-8 projection to drop the
## per-command schema collapses assertion (1)'s command list to empty.

import std/[os, unittest]

import repro_cli_support

# ---------------------------------------------------------------------------
# Producer fixtures. Each is a real ``repro.nim`` extracted through the shipped
# ``extractInterfaceFromModule`` — the SAME extractor the SC-2/SC-3 splice
# pre-pass uses — so the exported schema is the genuine
# ``ProjectInterface.publicExecutables`` / ``.publicLibraries``, not a fabricated
# one.
# ---------------------------------------------------------------------------

# (1) An executable-exporting producer with a ``cli:`` command ``serve`` that
#     carries a typed flag param. ``serve`` is the verb a typed consumer would
#     bind as ``prodexe.<exportName>.serve(...)`` (SC-9/SC-10).
const producerExeRepro = """
import repro_project_dsl
import repro_dsl_stdlib/packages/sh

package prodexe:
  defaultToolProvisioning "path"

  uses:
    "sh"

  executable prodexe:
    name: "prodexe"
    cli:
      subcmd "serve":
        flag socket is string
      subcmd "status":
        flag verbose is string
"""

# The falsifiability twin: the SAME producer with the ``serve`` verb RENAMED to
# ``listen``. The exported schema MUST shift — ``serve`` gone, ``listen``
# present — so a consumer binding ``serve`` would find no command.
const producerExeRenamedRepro = """
import repro_project_dsl
import repro_dsl_stdlib/packages/sh

package prodexe:
  defaultToolProvisioning "path"

  uses:
    "sh"

  executable prodexe:
    name: "prodexe"
    cli:
      subcmd "listen":
        flag socket is string
      subcmd "status":
        flag verbose is string
"""

# (2) A producer that declares NEITHER an executable NOR a library — only a
#     build edge. It is discoverable, but exports no typed contract.
const producerNoContractRepro = """
import repro_project_dsl
import repro_dsl_stdlib/packages/sh

package prodplain:
  defaultToolProvisioning "path"

  uses:
    "sh"

  build:
    discard shell(
      command = "mkdir -p build && echo plain > build/out.txt",
      actionId = "prodplain.build.out",
      extraOutputs = @["build/out.txt"])
"""

# (4) A producer that declares only a ``library`` block — export-by-default via
#     the library channel.
const producerLibRepro = """
import repro_project_dsl

package prodlib:
  library prodlib:
    kind: shared
"""

proc writeProducer(root, source: string) =
  createDir(root)
  writeFile(root / "repro.nim", source)

suite "SC-8: producer exports typed CLI contract across workspace":

  test "t_sc_producer_exports_typed_cli_contract_across_workspace":
    let scratch = getTempDir() / "sc8-" & $getCurrentProcessId()
    removeDir(scratch)
    createDir(scratch)
    defer: removeDir(scratch)

    # A consumer workspace root (absolute — required by the override resolver).
    # It carries the develop override + is the anchor whose PARENT holds the
    # on-disk sibling producers (``../<name>/repro.nim``).
    let workspace = absolutePath(scratch / "consumer")
    createDir(workspace)

    # The sibling producers live ONE LEVEL UP from the consumer so
    # ``findSiblingProjectFile`` (``../<name>``) discovers them.
    let exeRoot = absolutePath(scratch / "prodexe")
    let plainRoot = absolutePath(scratch / "prodplain")
    let libRoot = absolutePath(scratch / "prodlib")
    writeProducer(exeRoot, producerExeRepro)
    writeProducer(plainRoot, producerNoContractRepro)
    writeProducer(libRoot, producerLibRepro)

    # ---- (1a) discovery via an ON-DISK WORKSPACE SIBLING. ----
    # No develop override yet; ``prodexe`` is discovered as ``../prodexe``.
    let exeContract = resolveProducerTypedContract("prodexe", workspace)
    check exeContract.kind == ptckContract
    check exeContract.selector == "prodexe"
    check exeContract.projectName == "prodexe"
    check hasTypedContract(exeContract)
    # The exported schema carries the declared executable + its ``cli:``
    # command names (the payload ``toolActionWrapperCode`` turns into typed
    # wrappers). ``export-by-default``: no export keyword was written.
    check exeContract.publicExecutables.len == 1
    let exe = exeContract.publicExecutables[0]
    check exe.exportName == "prodexe"
    check exe.binaryName == "prodexe"
    # The per-command schema — command NAMES a consumer binds as typed calls.
    let cmds = typedContractCommands(exeContract, "prodexe")
    check "serve" in cmds
    check "status" in cmds
    check "listen" notin cmds
    # The typed params of ``serve`` are exported too (the wrapper formals).
    var serveParams: seq[string] = @[]
    for cmd in exe.commands:
      if cmd.name == "serve":
        for p in cmd.params:
          serveParams.add(p.name)
    check "socket" in serveParams

    # ---- (1b) discovery via a DEVELOP OVERRIDE (the other arm). ----
    # Register a develop override mapping ``prodexe`` -> the same checkout via a
    # DIFFERENT-looking path (``../prodexe`` relative to the workspace) so the
    # override arm is exercised, not only the sibling arm. The resolved schema
    # is identical — discovery arm does not change the exported contract.
    createDir(workspace / ".repro")
    writeFile(workspace / ".repro" / "develop-overrides.toml", """
schema = "reprobuild.workspace.develop-overrides.v1"

[[override]]
package = "prodexe"
local_path = "../prodexe"
state = "editable"
created_at = "2026-07-02T00:00:00Z"
""")
    let exeViaOverride = resolveProducerTypedContract("prodexe", workspace)
    check exeViaOverride.kind == ptckContract
    check exeViaOverride.projectName == "prodexe"
    let cmdsViaOverride = typedContractCommands(exeViaOverride, "prodexe")
    check "serve" in cmdsViaOverride
    check "status" in cmdsViaOverride
    removeFile(workspace / ".repro" / "develop-overrides.toml")

    # ---- (2) a producer with NO executable/library exposes NO contract. ----
    let plainContract = resolveProducerTypedContract("prodplain", workspace)
    check plainContract.kind == ptckNoContract
    check plainContract.projectName == "prodplain"  # discovered, but empty
    check not hasTypedContract(plainContract)
    check plainContract.publicExecutables.len == 0
    check plainContract.publicLibraries.len == 0

    # ---- (3) a selector naming no workspace producer exposes none. ----
    let unknown = resolveProducerTypedContract("nosuchproducer", workspace)
    check unknown.kind == ptckNoProducer
    check not hasTypedContract(unknown)

    # ---- (4) library export-by-default. ----
    let libContract = resolveProducerTypedContract("prodlib", workspace)
    check libContract.kind == ptckContract
    check hasTypedContract(libContract)
    check libContract.publicLibraries.len == 1
    check libContract.publicLibraries[0].name == "prodlib"

    # ---- FALSIFIABILITY: a renamed ``cli:`` command shifts the schema. ----
    # Rewrite the SAME sibling producer with ``serve`` -> ``listen`` and
    # re-resolve. The exported command set MUST shift; a consumer binding the
    # old ``serve`` (SC-9) would then find no command.
    writeFile(exeRoot / "repro.nim", producerExeRenamedRepro)
    let renamed = resolveProducerTypedContract("prodexe", workspace)
    check renamed.kind == ptckContract
    let renamedCmds = typedContractCommands(renamed, "prodexe")
    check "listen" in renamedCmds        # the NEW verb appears
    check "serve" notin renamedCmds      # the OLD verb is gone
    check "status" in renamedCmds        # the untouched verb stays
