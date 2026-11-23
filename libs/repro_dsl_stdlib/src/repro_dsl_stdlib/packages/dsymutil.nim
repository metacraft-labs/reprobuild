## ``dsymutil`` — the Mach-O debug-info linker, declared as a selector of its
## own so an edge that compiles with debug info on macOS can NAME it.
##
## WHY THIS IS A SEPARATE PACKAGE AND NOT PART OF ``clang``.
##
## On macOS, debug information is not written into the executable. The linker
## leaves DWARF in the object files and records only a debug map; ``dsymutil``
## is the separate pass that follows the link, reads that map and produces the
## ``.dSYM`` bundle. Anything that compiles with ``-g`` on darwin therefore
## runs TWO tools, and the second one is invoked by BARE NAME.
##
## ``nim c`` with ``debugInfo = true`` is exactly this shape. It emits C,
## shells out to ``clang`` to compile and link (which ``packages/nim.nim``
## already declares as a sub-tool ref), and then shells out AGAIN to a bare
## ``dsymutil``. The second call is easy to miss because it happens AFTER a
## working binary has already been written — the action dies with a non-zero
## status having produced a correct executable and an empty ``.dSYM``.
##
## The obvious-looking fix — "let the ``clang`` package expose its toolchain's
## binary directory" — DOES NOT WORK, and this is a measurement rather than a
## preference. ``uses: "clang"`` under nix provisioning realizes
## ``nixpkgs#clang``, a clang-WRAPPER derivation; measured 2026-10-16 on
## aarch64-darwin against reprobuild ``2391fa8cb9``, the realized
## ``clang-wrapper-21.1.8/bin`` holds ``addr2line ar as c++ c++filt cc clang
## clang++ cpp gprof ld nm objcopy objdump ranlib size strings strip`` and NO
## ``dsymutil``. The wrapper's directory genuinely lacks the binary, so there
## is nothing to widen or alias — the tool has to come from a different
## derivation, which is what a selector of its own is for.
##
## WHY ``nixpkgs#llvm`` AND NOT ``darwin.cctools``.
##
## Both carry a working ``dsymutil``. ``nixpkgs#llvm`` is already a selector
## this catalog uses (``packages/llvm_objdump.nim``, ``packages/llvm_config.nim``),
## so it reuses the pinned ``CanonicalNixpkgsRev`` and adds no new upstream
## surface; ``darwin.cctools`` would be a first reference to the ``darwin.*``
## attribute set. Measured 2026-10-16 against ``CanonicalNixpkgsRev``
## (``addf7cf5…``): the realization is
## ``/nix/store/3q0facdwp42jawa24zd01kp9wf49g7xd-llvm-21.1.2`` and
## ``bin/dsymutil`` is present.
##
## That directory is also SAFE to put on an edge's hermetic ``PATH`` beside the
## compiler's. ``toolPathPrefix`` (``repro_cli_support.nim:2340``) adds
## ``parentDir(resolvedExecutablePath)`` per ref in DECLARATION ORDER, so a
## recipe naming ``clang`` before ``dsymutil`` gets the clang-wrapper directory
## first; and measured on the realization above, the 91 binaries in
## ``llvm-21.1.2/bin`` include none of ``clang clang++ cc c++ ld as ar ranlib
## strip nm``, so there is no name for it to shadow even if the order were
## reversed.
##
## DO NOT "FIX" THIS BY LETTING THE EDGE REACH ``/usr/bin/dsymutil``.
##
## ``/usr/bin/dsymutil`` is a SIP platform binary — measured 2026-10-16,
## ``codesign -dv`` reports ``Platform identifier=26`` for it and reports NO
## platform identifier for the nix one. The macOS interpose monitor cannot
## inject into a platform binary, so an edge that resolves there is classified
## an unknown-scope loss and its cache publish is skipped. Letting the edge
## inherit the ambient ``PATH`` again has the same effect by a longer route,
## and additionally re-opens the unkeyed input channel that declaring tool refs
## exists to close.
##
## macOS only, deliberately. ``dsymutil`` splits debug info out of Mach-O
## images; ELF and PE builds keep theirs in the object/image and never invoke
## it. A recipe should gate its ``uses:`` entry with ``when defined(macosx)``.

import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

package dsymutil:
  provisioning:
    nixPackage "nixpkgs#llvm", executablePath = "bin/dsymutil",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash
