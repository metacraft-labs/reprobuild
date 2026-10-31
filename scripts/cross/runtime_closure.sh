#!/usr/bin/env bash
# runtime_closure.sh -- a cross-built prefix carries its own runtime libraries.
#
# Sourced by build_linux_cross.sh. An installed prefix must not depend on
# libraries the target's distribution happens to have installed: an add-on
# host promises no dependency on the base's libraries (ReproOS add-on
# mode), and a missing one surfaces only on the target, as `could not load:
# libclingo.so` (measured 2026-10-31 on an Ubuntu 24.04 armhf guest; rpi2's
# engine ran only because its base had a libclingo installed). So:
#
#   build_target_clingo <cc> <cxx> <sysroot> <out-lib-dir> <work-dir>
#       cross-builds clingo -- the version the native build links, from this
#       flake's nixpkgs -- against the sysroot, as a shared library whose
#       RUNPATH is its own directory, and installs it as `libclingo.so` (the
#       leaf name the engine dlopens, as the native release's
#       `relocate_release_posix.sh` installs it) plus its versioned soname.
#
#   bundle_runtime_closure <stage> <sysroot> <triple>
#       copies every library an image in <stage> needs (DT_NEEDED,
#       transitively, and the engine's dlopen leaf names) from the sysroot
#       into <stage>/lib, except the C library itself, and sets every image's
#       RUNPATH to <stage>/lib relative to its own directory ($ORIGIN).
#
#   check_prefix_closure <stage>
#       refuses (non-zero, naming each) any DT_NEEDED or dlopen name that
#       does not resolve inside <stage>/lib or to the C library.
#
# The C library (glibc: libc, libm, libdl, libpthread, librt, libutil, the
# loader) stays the target's: it is the ABI the sysroot was taken for, and a
# private copy of it would not match the target's kernel interface or its
# loader.
#
# Tools: `readelf` and `patchelf`, resolved by the caller (READELF,
# PATCHELF), and `cmake` (CMAKE) for clingo.
# https://man7.org/linux/man-pages/man8/ld.so.8.html (DT_RUNPATH, $ORIGIN)

# The C library's sonames: never bundled, always the target's.
cross_glibc_sonames=(libc.so.6 libm.so.6 libdl.so.2 libpthread.so.0 librt.so.1
  libutil.so.1 libresolv.so.2 ld-linux-armhf.so.3 ld-linux-aarch64.so.1
  ld-linux-x86-64.so.2)
# What the engine dlopens by leaf name (repro_dsl_stdlib/packaging/
# runtime_contract.reprobuildDlopenLeafNames, Linux).
cross_dlopen_leaf_names=(libzstd.so.1 libclingo.so)

cross_is_glibc() {
  local n="$1" g
  for g in "${cross_glibc_sonames[@]}"; do [ "$n" = "$g" ] && return 0; done
  return 1
}

cross_elfs() {
  # Every ELF regular file under $1.
  find "$1" -type f -print0 | while IFS= read -r -d '' f; do
    if [ "$(head -c4 "$f" 2>/dev/null | od -An -tx1 | tr -d ' \n')" = 7f454c46 ]; then
      printf '%s\n' "$f"
    fi
  done
}

cross_needed() {
  "${READELF:?}" -d "$1" 2>/dev/null |
    sed -n 's/.*(NEEDED).*\[\(.*\)\].*/\1/p'
}

cross_find_in_sysroot() {
  # The file a soname resolves to in the sysroot's library directories.
  local sysroot="$1" triple="$2" name="$3" d
  for d in "usr/lib/${triple}" "lib/${triple}" usr/lib lib "usr/lib/gcc/${triple}"/*; do
    if [ -e "${sysroot}/${d}/${name}" ]; then
      printf '%s\n' "${sysroot}/${d}/${name}"
      return 0
    fi
  done
  return 1
}

build_target_clingo() {
  local cc="$1" cxx="$2" sysroot="$3" libdir="$4" work="$5" src soname
  src="$(nix build --no-link --print-out-paths --inputs-from "${repo_root:?}" nixpkgs#clingo.src)" ||
    return 1
  rm -rf "${work}"
  mkdir -p "${work}"
  cp -r "${src}" "${work}/src"
  chmod -R u+w "${work}/src"
  "${CMAKE:?}" -S "${work}/src" -B "${work}/build" \
    -DCMAKE_SYSTEM_NAME=Linux -DCMAKE_SYSROOT="${sysroot}" \
    -DCMAKE_C_COMPILER="${cc}" -DCMAKE_CXX_COMPILER="${cxx}" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_SHARED_LINKER_FLAGS='-Wl,-rpath,$ORIGIN' \
    -DCLINGO_BUILD_APPS=OFF -DCLINGO_BUILD_EXAMPLES=OFF -DCLINGO_BUILD_TESTS=OFF \
    -DCLINGO_BUILD_WITH_PYTHON=OFF -DCLINGO_BUILD_WITH_LUA=OFF \
    -DCLINGO_BUILD_SHARED=ON -DCLINGO_BUILD_STATIC=OFF \
    -DCLINGO_MANAGE_RPATH=OFF >"${work}/configure.log" 2>&1 || {
      tail -n 30 "${work}/configure.log" >&2; return 1; }
  "${CMAKE}" --build "${work}/build" --target libclingo \
    -j "${NIX_BUILD_CORES:-$(nproc)}" >"${work}/build.log" 2>&1 || {
      tail -n 30 "${work}/build.log" >&2; return 1; }
  local built
  built="$(find "${work}/build" -name 'libclingo.so.*' -type f | head -n1)"
  [ -n "${built}" ] || { echo "runtime_closure: no libclingo.so.* was built" >&2; return 1; }
  soname="$("${READELF:?}" -d "${built}" | sed -n 's/.*(SONAME).*\[\(.*\)\].*/\1/p')"
  mkdir -p "${libdir}"
  cp "${built}" "${libdir}/${soname:-$(basename "${built}")}"
  # The leaf name the engine dlopens, a copy as the native release ships it.
  cp "${built}" "${libdir}/libclingo.so"
}

bundle_runtime_closure() {
  local stage="$1" sysroot="$2" triple="$3" changed=1 f n src rel up
  mkdir -p "${stage}/lib"
  # The dlopen names first (zstd from the sysroot; clingo is already built).
  for n in "${cross_dlopen_leaf_names[@]}"; do
    [ -e "${stage}/lib/${n}" ] && continue
    src="$(cross_find_in_sysroot "${sysroot}" "${triple}" "${n}")" || continue
    cp -L "${src}" "${stage}/lib/${n}"
  done
  # DT_NEEDED, transitively, until nothing new is copied.
  while [ "${changed}" = 1 ]; do
    changed=0
    while IFS= read -r f; do
      while IFS= read -r n; do
        [ -n "${n}" ] || continue
        cross_is_glibc "${n}" && continue
        [ -e "${stage}/lib/${n}" ] && continue
        if src="$(cross_find_in_sysroot "${sysroot}" "${triple}" "${n}")"; then
          cp -L "${src}" "${stage}/lib/${n}"
          chmod u+w "${stage}/lib/${n}"
          changed=1
        fi
      done < <(cross_needed "${f}")
    done < <(cross_elfs "${stage}")
  done
  # Every image finds them through its own RUNPATH.
  while IFS= read -r f; do
    rel="$(dirname "${f#"${stage}"/}")"
    if [ "${rel}" = lib ]; then
      "${PATCHELF:?}" --set-rpath '$ORIGIN' "${f}"
      continue
    fi
    up=""
    IFS=/ read -r -a parts <<< "${rel}"
    for _ in "${parts[@]}"; do up="../${up}"; done
    "${PATCHELF}" --set-rpath "\$ORIGIN/${up}lib" "${f}"
  done < <(cross_elfs "${stage}")
}

check_prefix_closure() {
  local stage="$1" f n bad=()
  while IFS= read -r f; do
    while IFS= read -r n; do
      [ -n "${n}" ] || continue
      cross_is_glibc "${n}" && continue
      [ -e "${stage}/lib/${n}" ] || bad+=("${f#"${stage}"/} needs ${n}")
    done < <(cross_needed "${f}")
  done < <(cross_elfs "${stage}")
  for n in "${cross_dlopen_leaf_names[@]}"; do
    [ -e "${stage}/lib/${n}" ] || bad+=("the engine dlopens ${n}")
  done
  if [ "${#bad[@]}" -gt 0 ]; then
    echo "runtime_closure: not inside the prefix (and not the C library):" >&2
    printf '  %s\n' "${bad[@]}" >&2
    return 1
  fi
}
