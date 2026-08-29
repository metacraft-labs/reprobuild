#!/usr/bin/env bash
#
# Make a packaged reprobuild release tree run OFF nix.
#
# The `.#release` build produces binaries linked by the nix toolchain: their
# ELF PT_INTERP is a `/nix/store/...-glibc/.../ld-linux-*.so` and their
# DT_RPATH / dlopen resolution points at `/nix/store` lib dirs. Packaging then
# raw-copies them (release.yml `cp -a build/bin/* build/lib/*`), so the tarball
# only runs where `/nix/store` exists. `scripts/verify_release.sh`'s multi-distro
# docker sweep catches this: `exec /reprobuild/bin/repro: no such file or
# directory` on ubuntu:24.04 is a missing ELF interpreter.
#
# This step rewrites the extracted `pkg/` tree to be self-contained:
#
#   Linux  — bundle the FULL runtime closure (incl. the nix glibc + its loader,
#            libssl/libcrypto, libblake3/libxxhash/libsqlite3, libgcc_s/libstdc++,
#            and the bare-dlopen'd libclingo/libzstd) into `lib/`, set every ELF's
#            rpath to `$ORIGIN/../lib`, and replace each `bin/<app>` with a tiny
#            wrapper that execs the BUNDLED loader with `--library-path lib`. The
#            bundled loader+libc are a matched pair, so the result is independent
#            of the target distro's glibc (passes debian:11 .. ubuntu:24.04).
#            A wrapper is used rather than `patchelf --set-interpreter` because a
#            tarball can be unpacked anywhere and PT_INTERP cannot be relative to
#            the binary ($ORIGIN is not honoured for the interpreter).
#
#   Darwin — bundle the otool(1) dylib closure into `lib/`, rewrite install names
#            / add LC_RPATH to `@loader_path/../lib` (via fixup_macho_runtime.sh),
#            and ad-hoc re-sign (every install_name_tool edit invalidates the
#            signature and macOS refuses to exec a Mach-O with a stale one).
#
# Idempotent-ish and loud: it fails hard rather than shipping a half-relocated
# tree, because a broken relocation becomes a 404-at-runtime for every consumer.
set -euo pipefail

pkg_dir="${1:?usage: relocate_release_posix.sh <pkg_dir>}"
bindir="${pkg_dir}/bin"
libdir="${pkg_dir}/lib"
mkdir -p "${libdir}"

os="$(uname -s)"

is_elf() { LC_ALL=C dd if="$1" bs=4 count=1 2>/dev/null | LC_ALL=C grep -q $'\x7fELF'; }

case "${os}" in
  Linux*)
    command -v patchelf >/dev/null 2>&1 || { echo "relocate: patchelf not on PATH" >&2; exit 1; }

    # ---- 0. Locate the bare-dlopen'd libs (libclingo, libzstd) --------------
    # ldd does NOT list them (they are dlopen'd at runtime, not DT_NEEDED), so
    # gather candidate source dirs from the build-env prefixes AND from the
    # binary's CURRENT rpath (build_apps.sh baked the nix clingo/zstd dirs there
    # before we overwrite it below).
    declare -a src_dirs=()
    [ -n "${CLINGO_PREFIX:-}" ] && src_dirs+=("${CLINGO_PREFIX}/lib" "${CLINGO_PREFIX}")
    [ -n "${ZSTD_PREFIX:-}" ] && src_dirs+=("${ZSTD_PREFIX}/lib" "${ZSTD_PREFIX}")
    if [ -x "${bindir}/repro" ]; then
      while IFS= read -r d; do
        [ -n "${d}" ] && src_dirs+=("${d}")
      done < <(patchelf --print-rpath "${bindir}/repro" 2>/dev/null | tr ':' '\n')
    fi

    copy_named_lib() {
      # copy_named_lib <soname-glob> — copy first match found under src_dirs
      local glob="$1" d hit
      for d in "${src_dirs[@]:-}"; do
        [ -d "${d}" ] || continue
        hit="$(find "${d}" -maxdepth 2 -name "${glob}" -type f 2>/dev/null | head -n1 || true)"
        if [ -n "${hit}" ]; then
          cp -Lf "${hit}" "${libdir}/$(basename "${hit}")"
          return 0
        fi
      done
      return 1
    }
    copy_named_lib 'libclingo.so*' || echo "relocate: WARNING libclingo not found in src_dirs" >&2
    copy_named_lib 'libzstd.so*'   || echo "relocate: WARNING libzstd not found in src_dirs" >&2

    # ---- 1. Transitive ldd closure of every ELF in bin/ + lib/ --------------
    resolve_deps() {
      # print absolute paths of shared objects ldd resolves for <elf>
      ldd "$1" 2>/dev/null | sed -nE 's#.* => (/[^ ]+) \(0x[0-9a-f]+\)$#\1#p'
      # the loader line has no "=>" — capture it too
      ldd "$1" 2>/dev/null | sed -nE 's#^[[:space:]]*(/[^ ]*ld-linux[^ ]*) \(0x[0-9a-f]+\)$#\1#p'
    }
    changed=1
    while [ "${changed}" = 1 ]; do
      changed=0
      while IFS= read -r -d '' elf; do
        is_elf "${elf}" || continue
        while IFS= read -r dep; do
          [ -n "${dep}" ] || continue
          [ -e "${dep}" ] || continue
          base="$(basename "${dep}")"
          case "${base}" in linux-vdso*|'') continue ;; esac
          if [ ! -e "${libdir}/${base}" ]; then
            cp -Lf "${dep}" "${libdir}/${base}"
            changed=1
          fi
        done < <(resolve_deps "${elf}")
      done < <(find "${bindir}" "${libdir}" -type f -print0)
    done

    # ---- 2. The loader ------------------------------------------------------
    loader="$(patchelf --print-interpreter "${bindir}/repro")"
    loadername="$(basename "${loader}")"
    [ -e "${libdir}/${loadername}" ] || cp -Lf "${loader}" "${libdir}/${loadername}"
    chmod u+w "${libdir}/${loadername}" 2>/dev/null || true

    # ---- 3. rpath every bundled lib to its own dir --------------------------
    while IFS= read -r -d '' so; do
      is_elf "${so}" || continue
      chmod u+w "${so}" 2>/dev/null || true
      patchelf --set-rpath '$ORIGIN' "${so}" 2>/dev/null || true
    done < <(find "${libdir}" -type f -print0)

    # ---- 4. Wrap every bin so it execs the bundled loader relocatably -------
    while IFS= read -r -d '' app; do
      is_elf "${app}" || continue
      base="$(basename "${app}")"
      case "${base}" in .*.real) continue ;; esac
      chmod u+w "${app}" 2>/dev/null || true
      patchelf --set-rpath '$ORIGIN/../lib' "${app}" 2>/dev/null || true
      mv "${app}" "${bindir}/.${base}.real"
      cat > "${app}" <<EOS
#!/bin/sh
# reprobuild portable launcher: run the real binary through the bundled glibc
# loader so it does not depend on the host's /nix/store or system glibc.
here=\$(CDPATH= cd -- "\$(dirname -- "\$0")" && pwd)
exec "\${here}/../lib/${loadername}" --library-path "\${here}/../lib" "\${here}/.${base}.real" "\$@"
EOS
      chmod +x "${app}"
    done < <(find "${bindir}" -type f -print0)

    echo "relocate(linux): bundled $(find "${libdir}" -type f | wc -l | tr -d ' ') libs; wrapped $(find "${bindir}" -name '.*.real' | wc -l | tr -d ' ') bins."
    ;;

  Darwin*)
    # ---- 1. Bundle the otool dylib closure into lib/ ------------------------
    # Walk each Mach-O in bin/ + lib/, copy every /nix/store (or other absolute,
    # non-system) dylib dependency into lib/, iterating to a fixpoint.
    is_macho() { file -b "$1" 2>/dev/null | grep -q 'Mach-O'; }
    dylib_deps() {
      otool -L "$1" 2>/dev/null | tail -n +2 | awk '{print $1}' \
        | grep -E '^/' | grep -vE '^/usr/lib/|^/System/'
    }
    changed=1
    while [ "${changed}" = 1 ]; do
      changed=0
      while IFS= read -r -d '' img; do
        is_macho "${img}" || continue
        while IFS= read -r dep; do
          [ -n "${dep}" ] || continue
          [ -e "${dep}" ] || continue
          base="$(basename "${dep}")"
          case "${base}" in @*) continue ;; esac
          if [ ! -e "${libdir}/${base}" ]; then
            cp -Lf "${dep}" "${libdir}/${base}"
            chmod u+w "${libdir}/${base}" 2>/dev/null || true
            changed=1
          fi
        done < <(dylib_deps "${img}")
      done < <(find "${bindir}" "${libdir}" -type f -print0)
    done

    # bare-dlopen'd libs (libclingo/libzstd) — otool won't list them
    for pfx in "${CLINGO_PREFIX:-}" "${ZSTD_PREFIX:-}"; do
      [ -n "${pfx}" ] || continue
      while IFS= read -r hit; do
        [ -n "${hit}" ] || continue
        base="$(basename "${hit}")"
        [ -e "${libdir}/${base}" ] || { cp -Lf "${hit}" "${libdir}/${base}"; chmod u+w "${libdir}/${base}" 2>/dev/null || true; }
      done < <(find "${pfx}" -maxdepth 2 \( -name 'libclingo*.dylib' -o -name 'libzstd*.dylib' \) -type f 2>/dev/null)
    done

    # ---- 2. Rewrite install names / rpath to @loader_path/../lib -----------
    # fixup_macho_runtime.sh adds LC_RPATH entries and sets -id on libraries,
    # per-arch for universal images. Point every image at the bundled lib dir.
    script_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
    bash "${script_dir}/fixup_macho_runtime.sh" "${pkg_dir}" "@loader_path/../lib" "@executable_path/../lib"

    # Also rewrite each absolute dependency reference to @rpath/<base> so the
    # LC_RPATH above resolves it from the bundle rather than /nix/store.
    while IFS= read -r -d '' img; do
      is_macho "${img}" || continue
      chmod u+w "${img}" 2>/dev/null || true
      while IFS= read -r dep; do
        [ -n "${dep}" ] || continue
        case "${dep}" in /usr/lib/*|/System/*|@*) continue ;; esac
        install_name_tool -change "${dep}" "@rpath/$(basename "${dep}")" "${img}" 2>/dev/null || true
      done < <(dylib_deps "${img}")
    done < <(find "${bindir}" "${libdir}" -type f -print0)

    # ---- 3. Ad-hoc re-sign (install_name_tool invalidated signatures) ------
    while IFS= read -r -d '' img; do
      is_macho "${img}" || continue
      codesign --remove-signature "${img}" 2>/dev/null || true
      codesign -f -s - "${img}" 2>/dev/null || codesign -f -s - --preserve-metadata=entitlements "${img}" 2>/dev/null || true
    done < <(find "${bindir}" "${libdir}" -type f -print0)

    echo "relocate(darwin): bundled $(find "${libdir}" -type f | wc -l | tr -d ' ') dylibs; re-signed bin/ + lib/."
    ;;

  *)
    echo "relocate: unsupported OS ${os}" >&2
    exit 1
    ;;
esac
