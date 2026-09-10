## ``patchelf`` — NixOS' ELF metadata editor.
##
## Distribution-And-Packaging.md §5 makes an ELF ``DT_RPATH`` pointing
## at the package's private libdir a HARD requirement of every non-Nix
## Linux package: the shipped ``repro`` binary ``dlopen``s zstd and
## clingo **by leaf name**, so unless the loader has a search path that
## reaches the vendored copies the binary does not run off-Nix. The
## flake gets this from ``postFixup``'s ``patchelf --set-rpath``; a
## ``.deb`` / ``.rpm`` / ``.tar.gz`` produced by the DSL packaging layer
## has to do the same thing to the staged copy.
##
## Packaging tools are reprobuild PACKAGES (Distribution-And-Packaging.md
## §6 rule 1) — the packaging layer must not shell out to an
## assumed-present host ``patchelf``. This module is that package
## definition, and ``packaging/runtime_contract.nim`` takes a real
## build-graph dependency on it, so a project that depends on a Linux
## producer transitively depends on patchelf.
##
## Windows / macOS carry no provisioning channel here on purpose. The
## §5 contract is satisfied by a different mechanism on each
## (``@loader_path`` via ``install_name_tool`` on Darwin, PATH-adjacent
## DLL placement on Windows), and an unavailable tool dependency is
## exactly how §6.1 says an unavailable capability should surface: as an
## ordinary unresolvable dependency, never as a format-aware switch in
## the engine.

import std/strutils
import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin
# DSL-port M9.R.2c — typed slot var for ``executable patchelfBin:``.
import repro_dsl_stdlib/types/executable

type
  PatchelfBinCall* = object
    ## The call record the ``implicitTargetName`` hook below receives.
    ##
    ## Hand-declared, and it must carry a same-named field for EVERY CLI
    ## parameter: the Named-Targets wrapper constructs it positionally
    ## by field name at each call site, so a missing field is a compile
    ## error at the call site rather than here. Same shape as the M1
    ## reference fixture ``libs/repro_build_engine/tests/m1_fixtures_hook.nim``.
    setRpath*: string
    forceRpath*: bool
    setInterpreter*: string
    shrinkRpath*: bool
    output*: string
    file*: string

package patchelf:
  provisioning:
    nixPackage "nixpkgs#patchelf", executablePath = "bin/patchelf",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash

  executable patchelfBin:
    cli:
      dependencyPolicy automaticMonitor

      call:
        # ``--set-rpath`` REPLACES the existing DT_RPATH/DT_RUNPATH.
        # The packaging layer always passes the full desired value
        # (``$ORIGIN``-relative), never an append, so the staged binary
        # is a pure function of the declared runtime closure.
        flag setRpath is string,
          alias = "--set-rpath",
          format = separate
        # nixpkgs' patchelf writes DT_RUNPATH by default; DT_RPATH is
        # what ``dlopen``-by-leaf-name from a *transitively* loaded
        # library honours, so the layer asks for the old tag
        # explicitly. Same reason flake.nix passes ``--force-rpath``.
        boolFlag forceRpath is bool, alias = "--force-rpath"
        flag setInterpreter is string,
          alias = "--set-interpreter",
          format = separate
        boolFlag shrinkRpath is bool, alias = "--shrink-rpath"
        # ``--output`` is what keeps the packaging layer free of any
        # in-place edge. patchelf's default is to rewrite its argument,
        # which would make one file the output of both the staging copy
        # and the patch — two edges declaring the same output, ordered
        # only by a dep chain. Writing to a distinct path instead means
        # every edge in the staging pipeline has an output nothing else
        # claims, so the whole install tree is a plain DAG of pure edges
        # and a rebuild is cache-hit-identical without relying on any
        # double-write exemption.
        flag output is string,
          alias = "--output",
          format = separate,
          role = output,
          required = true
        pos file is string,
          position = 0,
          role = input,
          required = true

        outputs output

    # Named-Targets: the implicit target name for an edge defaults to
    # its output's BASENAME with conventional extensions stripped, and
    # the DSL rejects two edges in one package that claim the same name.
    #
    # That default cannot work for a staging tool. Two producers over
    # one ``Distribution`` stage two trees whose files legitimately have
    # the SAME names — ``deb/usr/bin/hello.real`` and
    # ``tar/bin/hello.real`` are the same file staged twice — so the
    # basename rule makes an ordinary two-format build fail outright
    # with a duplicate-target error. The whole PATH is what identifies a
    # staged file, so that is what the name is derived from.
    implicitTargetName(call: PatchelfBinCall): string =
      call.output.replace("/", "-")
