## Shared runtime closure normalization for typed and custom install mirrors.
## Kept below the DSL umbrella so custom provider synthesis and the stdlib use
## the same implementation without a project-DSL/stdlib import cycle.

import std/[os, strutils]
import ./install_mirror_resolver

const m9r30PropagatedManifestName* = ".m9r30_propagated_libdirs.txt"

proc m9r14fStripDepConstraint*(value: string): string =
  for i, ch in value:
    if ch in {' ', '>', '<', '=', '~', '^'}:
      return value[0 ..< i]
  value

proc installMirrorDepLibDirs*(projectRoot: string;
                             dependencies: openArray[string]): seq[string] =
  let recipesRoot = parentDir(projectRoot)
  if recipesRoot.len == 0:
    return
  for raw in dependencies:
    let dep = m9r14fStripDepConstraint(raw)
    if dep.len == 0:
      continue
    for path in packageInstallMirrorLibDirs(recipesRoot, dep):
      if path notin result:
        result.add(path)

proc installMirrorDepManifestPaths*(projectRoot: string;
                                   dependencies: openArray[string]): seq[string] =
  let recipesRoot = parentDir(projectRoot)
  if recipesRoot.len == 0:
    return
  for raw in dependencies:
    let dep = m9r14fStripDepConstraint(raw)
    if dep.len == 0:
      continue
    let path = packageInstallMirrorPropagatedManifestPath(
      recipesRoot, dep, m9r30PropagatedManifestName)
    if path.len > 0 and path notin result:
      result.add(path)

proc installMirrorToolIdentityRefs*(packageName: string;
                                   dependencies: openArray[string]): seq[string] =
  result = typedInstallMirrorShellTools(packageName)
  result.add(InstallMirrorPublishToolName)
  for raw in dependencies:
    let dep = m9r14fStripDepConstraint(raw)
    if dep.len > 0 and dep notin result:
      result.add(dep)

proc m9r14fEmitRpathPatchScript*(escapedDstUsr: string;
                                 depMirrorLibDirs: seq[string];
                                 depManifestPaths: seq[string] = @[];
                                 ownManifestPath: string = "";
                                 packageName: string = "";
                                 recipesRoot: string = ""): string =
  ## DSL-port M9.R.14f.2 — emit a POSIX shell snippet that walks every
  ## ELF under ``<mirror>/lib`` + ``<mirror>/lib64`` + ``<mirror>/bin`` +
  ## ``<mirror>/sbin`` + ``<mirror>/libexec``
  ## and runs ``patchelf --set-rpath`` on each. RPATH layout:
  ## ``$ORIGIN:$ORIGIN/../lib:$ORIGIN/../lib64:<dep1>:<dep2>:...``.
  ##
  ## DSL-port M9.R.30.2 — when ``depManifestPaths`` is non-empty, the
  ## script reads each dep's ``.m9r30_propagated_libdirs.txt`` manifest
  ## file (if it exists on disk) and appends every line to the RPATH.
  ## Standard install-mirror paths from a moved producer checkout are remapped
  ## under ``recipesRoot`` when the equivalent active mirror exists. This keeps
  ## restored package outputs from retaining historical checkout locations while
  ## leaving genuine external/federated dependency paths intact.
  ## When ``ownManifestPath`` is non-empty, the script ALSO writes the
  ## consumer's final RPATH lines to that path so downstream consumers
  ## (recipes that buildDep this one) can read the closure transitively.
  ##
  ## DSL-port M9.R.30.3 — when ``ownManifestPath`` is non-empty (i.e.
  ## the standard install-mirror call path) and REPRO_M9R30_NEEDED_CHECK=1,
  ## after patching every ELF
  ## the script runs ``patchelf --print-needed`` and verifies that
  ## every NEEDED line resolves to an actual file under one of the
  ## RPATH dirs. An unresolved NEEDED FAILS THE BUILD (exit 75) with
  ## a structured error naming the package + binary + missing SONAME.
  ## This forces recipe authors to declare the missing transitive dep
  ## explicitly instead of silently shipping broken binaries to the
  ## ISO stage.
  ##
  ## The ``$ORIGIN`` family covers same-directory + sibling-directory
  ## SONAME chains (``libwayland-server.so`` next to
  ## ``libwayland-client.so``; ``wayland-scanner`` in ``bin/`` reaching
  ## ``../lib/libwayland-client.so``). Absolute dep paths cover
  ## transitive runtime deps (libexpat for wayland-scanner; libffi for
  ## libwayland-server; etc.).
  ##
  ## Idempotent: ``patchelf`` overwrites the existing RPATH every time,
  ## so re-running the install-mirror produces the same final RPATH.
  ##
  ## Graceful skip: non-Linux hosts can construct the same action graph
  ## without providing ``patchelf``. Linux install-mirror actions declare
  ## the typed ``patchelf`` tool explicitly below, so executed ELF
  ## normalization never depends on the caller's ambient PATH.
  var script = ""
  script.add("if command -v patchelf >/dev/null 2>&1; then ")
  # A completed source tool can come from the mirror being normalized.
  # Patch a separate inode, then rename beside the resolved target so running
  # executables (including patchelf itself) and loader symlinks remain valid.
  script.add("m9r14f_patch_elf() ( ")
  script.add("m9r14f_target=$(readlink -f -- \"$1\") || exit; shift; ")
  script.add("m9r14f_temp=$(mktemp \"$m9r14f_target.repro-patch.XXXXXX\") || exit; ")
  script.add("trap 'rm -f -- \"$m9r14f_temp\"' 0; ")
  script.add("trap 'exit 129' HUP; trap 'exit 130' INT; trap 'exit 143' TERM; ")
  script.add("cp -p -- \"$m9r14f_target\" \"$m9r14f_temp\" && ")
  script.add("chmod u+w -- \"$m9r14f_temp\" && ")
  script.add("patchelf \"$@\" \"$m9r14f_temp\" && ")
  script.add("chmod --reference=\"$m9r14f_target\" -- \"$m9r14f_temp\" && ")
  script.add("mv -f -- \"$m9r14f_temp\" \"$m9r14f_target\"; ")
  script.add("); ")
  # Build the RPATH string. Single-quote ``$ORIGIN`` so the shell does
  # not expand it — ``$ORIGIN`` must reach patchelf verbatim so the
  # dynamic linker interprets it at load time. Use a here-doc-free
  # construction so the snippet stays compatible with /bin/sh.
  #
  # M9.R.15q.5.1 — existence-check each dep mirror lib dir before
  # appending it to RPATH. Recipes routinely declare nix-stub deps
  # (libltdl, hwdata, libxdmcp, ...) whose ``<recipeRoot>/<depName>/
  # .repro/output/install/usr/lib`` path NEVER exists on disk — those
  # are resolved via ``/nix/store/...`` at engine fork time. Without
  # the existence-check, every such dep contributed a dangling RPATH
  # entry; ``patchelf`` happily bakes it into the ELF and the dynamic
  # loader silently skips it at run time, masking the resolution gap
  # until something later trips a missing-SONAME error.
  #
  # In ADDITION to the existence-check, inspect directories present
  # in ``$LD_LIBRARY_PATH`` for unresolved DT_NEEDED SONAMEs. The engine's
  # ``applyResolvedAuxPaths`` populates ``LD_LIBRARY_PATH`` from each
  # tool-identity-ref's ``libraryPathList`` (nix-store lib dirs for
  # nix-stub deps; sibling install-mirror lib dirs for from-source
  # deps). This is the load-bearing channel that carries the nix-store
  # paths the install-mirror script has no other way to discover. Build-only
  # directories are excluded from the installed RPATH.
  script.add("rpath=$(printf '%s' '$ORIGIN'")
  script.add("; printf ':%s' '$ORIGIN/../lib'")
  script.add("; printf ':%s' '$ORIGIN/../lib64'")
  script.add("); ")
  # Append every existing sibling-recipe install-mirror lib dir. The
  # ``[ -d ... ]`` guard skips nix-stub deps whose mirror path doesn't
  # exist (M9.R.15q.5.1).
  for libDir in depMirrorLibDirs:
    let escapedLibDir = libDir.replace("\"", "\\\"")
    script.add("if [ -d \"" & escapedLibDir & "\" ]; then ")
    script.add("rpath=\"$rpath:" & escapedLibDir & "\"; ")
    script.add("fi; ")
  # DSL-port M9.R.30.2 — read each direct dep's propagated-libdirs
  # manifest (if it exists) and append every line to rpath. Each
  # recipe's install-mirror writes its own manifest at
  # ``<recipeRoot>/.repro/output/install/.m9r30_propagated_libdirs.txt``
  # with the full set of lib dirs that contributed to ITS rpath. So a
  # consumer transitively inherits its dep's dep's dep's lib dirs
  # without having to walk the recipe graph at Nim time. Lines are
  # absolute POSIX paths; existence-check via ``[ -d ... ]`` so stale
  # entries don't pollute the embedded RPATH.
  #
  # The dedup is by simple substring scan against the current rpath
  # — ``case ":$rpath:" in *":$line:"*) ;; *) rpath="$rpath:$line";;
  # esac`` — so a dep already on rpath from the direct-walk doesn't
  # duplicate. This keeps the final RPATH bounded by the total number
  # of distinct lib dirs in the build closure.
  for manifestPath in depManifestPaths:
    let escapedManifest = manifestPath.replace("\"", "\\\"")
    script.add("if [ -f \"" & escapedManifest & "\" ]; then ")
    script.add("while IFS= read -r line || [ -n \"$line\" ]; do ")
    script.add("if [ -z \"$line\" ]; then continue; fi; ")
    if recipesRoot.len > 0:
      let escapedRecipesRoot = recipesRoot.replace("\"", "\\\"")
      script.add("case \"$line\" in */.repro/output/install/*) ")
      script.add("m9r14f_old_recipe=${line%%/.repro/output/install/*}; ")
      script.add("m9r14f_dep=${m9r14f_old_recipe##*/}; ")
      script.add("m9r14f_rel=${line#*/.repro/output/install/}; ")
      script.add("m9r14f_active=\"" & escapedRecipesRoot &
        "/$m9r14f_dep/.repro/output/install/$m9r14f_rel\"; ")
      script.add("if [ -d \"$m9r14f_active\" ]; then line=$m9r14f_active; fi;; ")
      script.add("esac; ")
    script.add("if ! [ -d \"$line\" ]; then continue; fi; ")
    # A dependency's Nix runtime dirs belong on that dependency's ELFs, not
    # on every downstream consumer. The stage closure walks every ELF, so
    # propagating these paths only multiplies unrelated store outputs.
    script.add("case \"$line\" in /nix/store/*|/repro/store/*) continue;; esac; ")
    script.add("case \":$rpath:\" in *\":$line:\"*) ;; ")
    script.add("*) rpath=\"$rpath:$line\";; esac; ")
    script.add("done < \"" & escapedManifest & "\"; ")
    script.add("fi; ")
  # Collect the SONAMEs actually needed by this package's output. Tool
  # provisioning can put hundreds of build-only directories on
  # LD_LIBRARY_PATH; only a directory that resolves an otherwise missing
  # DT_NEEDED entry belongs in the installed RPATH.
  script.add("needed_sonames=$(for d in \"" & escapedDstUsr &
    "/lib\" \"" & escapedDstUsr & "/lib64\" \"" & escapedDstUsr &
    "/bin\" \"" & escapedDstUsr & "/sbin\" \"" & escapedDstUsr & "/libexec\"; do ")
  script.add("if [ -d \"$d\" ]; then ")
  script.add("find \"$d\" -type f \\( -name '*.so' -o -name '*.so.*' -o -perm -u+x \\) 2>/dev/null | ")
  script.add("while IFS= read -r f; do ")
  script.add("magic=$(head -c 4 \"$f\" 2>/dev/null | od -An -c | head -1 | tr -d ' '); ")
  script.add("case \"$magic\" in 177ELF*) patchelf --print-needed \"$f\" 2>/dev/null || true;; esac; ")
  script.add("done; fi; done | sort -u); ")

  # Return success when a SONAME already exists in the package itself or in
  # the RPATH assembled from source dependency mirrors.
  script.add("m9r14f_soname_resolved() { m9r14f_so=$1; ")
  script.add("for own in \"" & escapedDstUsr & "/lib/$m9r14f_so\" \"")
  script.add(escapedDstUsr & "/lib64/$m9r14f_so\" \"")
  script.add(escapedDstUsr & "/lib\"/*/\"$m9r14f_so\" \"")
  script.add(escapedDstUsr & "/lib64\"/*/\"$m9r14f_so\"; do ")
  script.add("if [ -e \"$own\" ]; then return 0; fi; done; ")
  script.add("m9r14f_old_ifs=$IFS; IFS=':'; ")
  script.add("for rp in $rpath; do case \"$rp\" in '$ORIGIN'*) continue;; esac; ")
  script.add("if [ -e \"$rp/$m9r14f_so\" ]; then IFS=$m9r14f_old_ifs; return 0; fi; ")
  script.add("done; IFS=$m9r14f_old_ifs; return 1; }; ")

  # Append only LD_LIBRARY_PATH entries that satisfy an unresolved SONAME.
  # Parse the colon-separated list without changing IFS around the SONAME
  # loop and without clobbering the action's positional parameters.
  script.add("if [ -n \"$LD_LIBRARY_PATH\" ]; then ")
  script.add("m9r14f_ldpaths=$LD_LIBRARY_PATH; ")
  script.add("while [ -n \"$m9r14f_ldpaths\" ]; do ")
  script.add("ldp=${m9r14f_ldpaths%%:*}; ")
  script.add("if [ \"$m9r14f_ldpaths\" = \"$ldp\" ]; then m9r14f_ldpaths=; ")
  script.add("else m9r14f_ldpaths=${m9r14f_ldpaths#*:}; fi; ")
  script.add("if [ -z \"$ldp\" ] || ! [ -d \"$ldp\" ]; then continue; fi; ")
  script.add("case \":$rpath:\" in *\":$ldp:\"*) continue;; esac; ")
  script.add("m9r14f_use_ldp=0; for so in $needed_sonames; do ")
  script.add("if ! m9r14f_soname_resolved \"$so\" && [ -e \"$ldp/$so\" ]; then ")
  script.add("m9r14f_use_ldp=1; break; fi; done; ")
  script.add("if [ \"$m9r14f_use_ldp\" = 1 ]; then rpath=\"$rpath:$ldp\"; fi; ")
  script.add("done; ")
  script.add("fi; ")
  # DSL-port M9.R.15h.14.4 — preserve the toolchain libstdc++ / libgcc_s
  # path. Without a from-source gcc recipe, the C++ compiler is the
  # nix-shell-provisioned gcc-wrapper which links against libstdc++.so.6
  # at e.g. ``/nix/store/<gcc-lib>-gcc-N.M.0-lib/lib/libstdc++.so.6``.
  # The plain $ORIGIN + dep-mirror rpath chain doesn't reach this path,
  # so executables that need C++ runtime (qtpaths, lupdate, lrelease,
  # KF6 binaries) hit ``error while loading shared libraries:
  # libstdc++.so.6: cannot open shared object file`` at run time even
  # when launched from inside the originating nix-shell.
  #
  # Append the gcc-wrapper's resolved libstdc++ dirname to the rpath
  # so the dynamic loader finds it without LD_LIBRARY_PATH. We resolve
  # the path at install-mirror time via ``gcc -print-file-name=...``,
  # which echoes the absolute path of the named library file even when
  # the compiler isn't on PATH. The directory of that path is what we
  # want on rpath.
  script.add("if printf '%s\\n' \"$needed_sonames\" | grep -qx 'libstdc++.so.6' && ")
  script.add("! m9r14f_soname_resolved 'libstdc++.so.6'; then ")
  script.add("stdcxx_file=$(gcc -print-file-name=libstdc++.so.6 2>/dev/null); ")
  script.add("if [ -n \"$stdcxx_file\" ] && [ \"$stdcxx_file\" != \"libstdc++.so.6\" ]; then ")
  script.add("stdcxx_dir=$(dirname \"$stdcxx_file\"); ")
  script.add("case \":$rpath:\" in *\":$stdcxx_dir:\"*) ;; *) rpath=\"$rpath:$stdcxx_dir\";; esac; ")
  script.add("fi; fi; ")
  # DSL-port M9.R.26.5 — discover the recipe's OWN internal versioned
  # subdirs under lib/ + lib64/ (e.g. mutter-15/, qt6/plugins/, etc.)
  # and append each as an absolute path to the rpath. Without this,
  # files under lib64/mutter-15/*.so are patched with a base rpath
  # whose $ORIGIN/.. resolves to lib64/ (good) but whose $ORIGIN/../..
  # is the usr/ root, and the cross-subdir SONAME chain (libmutter-cogl
  # in mutter-15/ linking against libmutter-mtk in the same subdir,
  # plus libmutter-15.so in lib64/ linking against everything in
  # mutter-15/) breaks because the parent lib's $ORIGIN doesn't reach
  # the versioned subdir.
  #
  # Solution: enumerate every versioned subdir at install-mirror time
  # and add it to the per-recipe rpath. The enumeration is dynamic
  # (POSIX glob) so any recipe that ships internal-implementation .so
  # files in lib64/<pkg-version>/ subdirs gets the right rpath without
  # having to hand-thread per-recipe overrides.
  for libDirName in ["lib", "lib64"]:
    let libDirAbs = escapedDstUsr & "/" & libDirName
    script.add("if [ -d \"" & libDirAbs & "\" ]; then ")
    script.add("for subd in \"" & libDirAbs & "\"/*/; do ")
    script.add("if [ -d \"$subd\" ]; then ")
    # Only include the subdir if it contains .so* files (skip pkg-config /
    # cmake / locale / static-only subdirs).
    script.add("if find \"$subd\" -maxdepth 1 -name '*.so*' -print -quit 2>/dev/null | grep -q .; then ")
    # Strip trailing slash for a clean rpath entry.
    script.add("rpath=\"$rpath:${subd%/}\"; ")
    script.add("fi; ")
    script.add("fi; ")
    script.add("done; ")
    script.add("fi; ")
  # A Nix-provisioned compiler gives executables a Nix dynamic interpreter.
  # When the package explicitly depends on a source-built libc, the RPATH
  # assembled above can then select that libc under the old interpreter. That
  # loader/libc combination is unsupported and, among other things, crashes as
  # soon as the io-monitor shim is preloaded. Select the first declared runtime
  # loader in RPATH order and move executable ELFs to it together with the
  # libraries that RPATH already selected. Shared libraries have no interpreter
  # and are left alone by the print-interpreter guard below.
  script.add("m9r14f_runtime_loader=; OLD_IFS=$IFS; IFS=':'; ")
  script.add("for rp in $rpath; do ")
  script.add("case \"$rp\" in '$ORIGIN'*) continue;; esac; ")
  script.add("for candidate in \"$rp\"/ld-linux-*.so.* \"$rp\"/ld-musl-*.so.*; do ")
  script.add("if [ -f \"$candidate\" ]; then m9r14f_runtime_loader=$candidate; break 2; fi; ")
  script.add("done; done; IFS=$OLD_IFS; ")
  # LIBRARY_PATH carries declared link inputs, including libc directories that
  # the engine intentionally excludes from LD_LIBRARY_PATH. If no declared
  # mirror supplied a loader, retain only the runtime already selected by the
  # linker. Matching PT_INTERP avoids importing unrelated compiler runtimes.
  script.add("if [ -z \"$m9r14f_runtime_loader\" ] && [ -n \"${LIBRARY_PATH:-}\" ]; then ")
  script.add("m9r14f_linked_loaders=$(for d in \"" & escapedDstUsr &
    "/lib\" \"" & escapedDstUsr & "/lib64\" \"" & escapedDstUsr &
    "/bin\" \"" & escapedDstUsr & "/sbin\" \"" & escapedDstUsr & "/libexec\"; do ")
  script.add("if [ -d \"$d\" ]; then ")
  script.add("find \"$d\" -type f \\( -name '*.so' -o -name '*.so.*' -o -perm -u+x \\) 2>/dev/null | ")
  script.add("while IFS= read -r f; do ")
  script.add("m9r14f_interp=$(patchelf --print-interpreter \"$f\" 2>/dev/null || true); ")
  script.add("case \"$m9r14f_interp\" in /*) ")
  script.add("readlink -f \"$m9r14f_interp\" 2>/dev/null || true;; esac; ")
  script.add("done; fi; done | sort -u); ")
  script.add("m9r14f_linkdirs=${LIBRARY_PATH}; m9r14f_linked_libdir=; ")
  script.add("while [ -n \"$m9r14f_linkdirs\" ]; do ")
  script.add("ldp=${m9r14f_linkdirs%%:*}; ")
  script.add("if [ \"$m9r14f_linkdirs\" = \"$ldp\" ]; then m9r14f_linkdirs=; ")
  script.add("else m9r14f_linkdirs=${m9r14f_linkdirs#*:}; fi; ")
  script.add("case \"$ldp\" in /*) ;; *) continue;; esac; ")
  script.add("if ! [ -d \"$ldp\" ]; then continue; fi; ")
  script.add("for candidate in \"$ldp\"/ld-linux-*.so.* \"$ldp\"/ld-musl-*.so.*; do ")
  script.add("if ! [ -f \"$candidate\" ]; then continue; fi; ")
  script.add("m9r14f_linked_loader=$(readlink -f \"$candidate\" 2>/dev/null) || continue; ")
  script.add("if ! printf '%s\\n' \"$m9r14f_linked_loaders\" | ")
  script.add("grep -Fxq -- \"$m9r14f_linked_loader\"; then continue; fi; ")
  script.add("if [ \"$m9r14f_linked_loaders\" != \"$m9r14f_linked_loader\" ]; then ")
  script.add("printf '%s\\n' 'install-mirror: conflicting linked runtime loaders' >&2; exit 75; fi; ")
  script.add("case \"${candidate##*/}\" in ld-linux-*) ")
  script.add("for so in libc.so.6 libm.so.6; do ")
  script.add("if [ \"$so\" = libm.so.6 ] && ! printf '%s\\n' \"$needed_sonames\" | ")
  script.add("grep -Fxq -- \"$so\"; then continue; fi; ")
  script.add("if ! [ -f \"$ldp/$so\" ]; then ")
  script.add("printf '%s\\n' \"install-mirror: linked runtime $ldp is missing $so\" >&2; exit 75; ")
  script.add("fi; done;; esac; ")
  script.add("m9r14f_runtime_loader=$m9r14f_linked_loader; ")
  script.add("if [ -z \"$m9r14f_linked_libdir\" ]; then m9r14f_linked_libdir=$ldp; fi; ")
  script.add("done; done; ")
  # Keep this libc ahead of any partial runtime directory lacking a loader.
  script.add("if [ -n \"$m9r14f_linked_libdir\" ]; then ")
  script.add("rpath=\"$m9r14f_linked_libdir:$rpath\"; fi; fi; ")
  # DSL-port M9.R.30.2 — write the consumer's own propagated-libdirs
  # manifest BEFORE walking the ELFs so a parallel build pass that
  # races against this consumer's downstream recipe can read the
  # manifest as soon as the rpath is computed. Lines are absolute,
  # one per line, in the order they appear in $rpath. We split rpath
  # on ``:`` and filter out the ``$ORIGIN`` family (those are
  # binary-relative and meaningless to a downstream consumer); only
  # the ABSOLUTE paths land in the manifest.
  if ownManifestPath.len > 0:
    let escapedManifest = ownManifestPath.replace("\"", "\\\"")
    script.add("mkdir -p \"$(dirname \"" & escapedManifest & "\")\"; ")
    # ``: > file`` truncates atomically; the subsequent appends are
    # individual ``printf`` calls each appending one line. Using
    # printf rather than ``echo`` so a future rpath entry that starts
    # with ``-`` doesn't get interpreted as a flag.
    script.add(": > \"" & escapedManifest & "\"; ")
    script.add("OLD_IFS=$IFS; IFS=':'; ")
    script.add("for rp in $rpath; do ")
    # Skip ``$ORIGIN`` family — binary-relative tokens have no meaning
    # to a downstream consumer's ELF (its $ORIGIN is different).
    script.add("case \"$rp\" in '$ORIGIN'*) continue;; esac; ")
    # Skip empty / non-absolute entries.
    script.add("if [ -z \"$rp\" ]; then continue; fi; ")
    script.add("case \"$rp\" in /*) ;; *) continue;; esac; ")
    script.add("printf '%s\\n' \"$rp\" >> \"" & escapedManifest & "\"; ")
    script.add("done; IFS=$OLD_IFS; ")
  # Nix compiler wrappers may inject a self-RPATH into runtime loaders while
  # linking them. glibc rejects DT_RUNPATH on ld.so at startup, so normalize
  # glibc and musl loader names before the general ELF patch pass below.
  script.add("for loader in \"" & escapedDstUsr & "/lib\"/ld-*.so* \"")
  script.add(escapedDstUsr & "/lib64\"/ld-*.so*; do ")
  script.add("if [ -f \"$loader\" ]; then ")
  script.add("m9r14f_patch_elf \"$loader\" --remove-rpath; ")
  script.add("fi; done; ")
  # Walk lib/ + lib64/ for .so* files (the SONAME-versioned chain).
  # Walk bin/ + sbin/ + libexec/ for executables.
  script.add("for d in \"" & escapedDstUsr & "/lib\" \"" & escapedDstUsr &
    "/lib64\" \"" & escapedDstUsr & "/bin\" \"" & escapedDstUsr & "/sbin\" \"" & escapedDstUsr & "/libexec\"; do ")
  script.add("if [ -d \"$d\" ]; then ")
  script.add("find \"$d\" -type f \\( ")
  script.add("-name '*.so' -o -name '*.so.*' -o -perm -u+x ")
  script.add("\\) 2>/dev/null | while IFS= read -r f; do ")
  # Runtime loaders reject a DT_RUNPATH on their own ELF. This covers glibc
  # (ld-linux-*.so.*, ld-2.*.so) and musl (ld-musl-*.so.*) conventions.
  script.add("case \"$(basename \"$f\")\" in ld-*.so*) continue;; esac; ")
  # Skip non-ELF executables before patching. Errors on actual ELFs must fail
  # the action rather than publishing a partially normalized runtime closure.
  script.add("magic=$(head -c 4 \"$f\" 2>/dev/null | od -An -c | head -1 | tr -d ' '); ")
  script.add("case \"$magic\" in 177ELF*) ")
  script.add("m9r14f_old_interpreter=; ")
  script.add("if [ -n \"$m9r14f_runtime_loader\" ]; then ")
  script.add("m9r14f_old_interpreter=$(patchelf --print-interpreter \"$f\" 2>/dev/null || true); ")
  script.add("fi; ")
  script.add("if [ -n \"$m9r14f_old_interpreter\" ]; then ")
  script.add("m9r14f_patch_elf \"$f\" --set-interpreter \"$m9r14f_runtime_loader\" --set-rpath \"$rpath\"; ")
  script.add("else m9r14f_patch_elf \"$f\" --set-rpath \"$rpath\"; fi; ")
  script.add(";; esac; ")
  script.add("done; ")
  script.add("fi; done; ")
  # DSL-port M9.R.30.3 — NEEDED safety net. After patching every ELF,
  # re-walk lib/ + lib64/ + bin/ + sbin/ + libexec/ and run ``patchelf --print-needed``
  # on each ELF. For every NEEDED SONAME, verify the file is found
  # under one of the RPATH dirs (split $rpath on ``:`` and probe
  # ``$dir/$soname``). If any NEEDED is unresolved, FAIL the build
  # (exit 75 — "M9.R.30 unresolved transitive NEEDED").
  #
  # The check is gated on the M9.R.30 env var ``REPRO_M9R30_NEEDED_CHECK``
  # so partial-graph dev builds (a single recipe rebuilt in isolation
  # while a downstream dep is in flight) can opt out. The reproos-iso
  # build sets the env var to ``1`` so the ISO-staging path always
  # enforces. The default is OFF so single-recipe unit-test fixtures
  # don't accidentally fail.
  #
  # ``$ORIGIN``-relative entries in rpath are expanded by substituting
  # the directory of the ELF being checked (``dirname "$f"``); this
  # matches the dynamic-linker semantics exactly.
  #
  # The ``while read`` body runs in a SUBSHELL (find | while pipe), so
  # we count failures via a marker FILE next to the manifest; the
  # parent shell then checks the file's line count + exits non-zero
  # if any unresolved NEEDED landed.
  if ownManifestPath.len > 0:
    let escapedPackage = packageName.replace("\"", "\\\"")
    let escapedManifest = ownManifestPath.replace("\"", "\\\"")
    script.add("if [ \"${REPRO_M9R30_NEEDED_CHECK:-0}\" = \"1\" ]; then ")
    script.add("m9r30_unresolved_log=\"" & escapedManifest & ".m9r30_unresolved\"; ")
    script.add(": > \"$m9r30_unresolved_log\"; ")
    script.add("for d in \"" & escapedDstUsr & "/lib\" \"" & escapedDstUsr &
      "/lib64\" \"" & escapedDstUsr & "/bin\" \"" & escapedDstUsr & "/sbin\" \"" & escapedDstUsr & "/libexec\"; do ")
    script.add("if [ -d \"$d\" ]; then ")
    script.add("find \"$d\" -type f \\( ")
    script.add("-name '*.so' -o -name '*.so.*' -o -perm -u+x ")
    script.add("\\) 2>/dev/null | while IFS= read -r f; do ")
    script.add("magic=$(head -c 4 \"$f\" 2>/dev/null | od -An -c | head -1 | tr -d ' '); ")
    script.add("case \"$magic\" in 177ELF*) ")
    script.add("origin_dir=$(dirname \"$f\"); ")
    script.add("for so in $(patchelf --print-needed \"$f\" 2>/dev/null); do ")
    script.add("found=0; ")
    script.add("OLD_IFS=$IFS; IFS=':'; ")
    script.add("for rp in $rpath; do ")
    script.add("expanded=$(printf '%s' \"$rp\" | sed \"s|\\$ORIGIN|$origin_dir|g\"); ")
    script.add("if [ -f \"$expanded/$so\" ]; then ")
    script.add("found=1; break; ")
    script.add("fi; ")
    script.add("done; IFS=$OLD_IFS; ")
    # Also accept resolution via standard system dirs the live ISO
    # always has (the dynamic loader's default search list).  Without
    # this fallback every ELF would fail on ``libc.so.6`` /
    # ``ld-linux-*.so`` etc. since those come from the nix-stub /
    # base-rootfs path, not from a from-source dep mirror.
    script.add("if [ \"$found\" = \"0\" ]; then ")
    script.add("for sysd in /lib /lib64 /usr/lib /usr/lib64 /lib/x86_64-linux-gnu /usr/lib/x86_64-linux-gnu; do ")
    script.add("if [ -f \"$sysd/$so\" ]; then found=1; break; fi; ")
    script.add("done; fi; ")
    script.add("if [ \"$found\" = \"0\" ]; then ")
    script.add("printf '[m9r30] UNRESOLVED NEEDED: pkg=%s bin=%s soname=%s\\n' " &
      "\"" & escapedPackage & "\" \"$f\" \"$so\" >&2; ")
    script.add("printf '%s\\t%s\\n' \"$f\" \"$so\" >> \"$m9r30_unresolved_log\"; ")
    script.add("fi; ")
    script.add("done; ")
    script.add(";; esac; ")
    script.add("done; ")
    script.add("fi; done; ")
    # Parent-shell tally: any non-empty unresolved log = fail.
    script.add("if [ -s \"$m9r30_unresolved_log\" ]; then ")
    script.add("printf '[m9r30] FAILED: pkg=%s has %d unresolved NEEDED " &
      "entries (see %s)\\n' \"" & escapedPackage &
      "\" \"$(wc -l < \"$m9r30_unresolved_log\")\" \"$m9r30_unresolved_log\" >&2; ")
    script.add("exit 75; ")
    script.add("fi; ")
    script.add("fi; ")
  script.add("fi; ")
  script
