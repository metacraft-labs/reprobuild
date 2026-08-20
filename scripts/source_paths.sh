#!/usr/bin/env bash

resolve_repo_source_path() {
  local env_name="$1"
  local marker="$2"
  local sibling="$3"
  local value="${!env_name:-}"

  if [ -n "${value}" ] && [ -f "${value}/${marker}" ]; then
    printf '%s\n' "${value}"
    return 0
  fi
  if [ -n "${sibling}" ] && [ -f "${sibling}/${marker}" ]; then
    printf '%s\n' "${sibling}"
    return 0
  fi
  if command -v nix >/dev/null 2>&1 && [ -f flake.nix ]; then
    local system candidate
    system="$(nix eval --raw --impure --expr 'builtins.currentSystem' 2>/dev/null || true)"
    if [ -n "${system}" ]; then
      candidate="$(
        nix eval --raw ".#devShells.${system}.default.${env_name}" \
          2>/dev/null || true
      )"
      if [ -n "${candidate}" ] && [ -f "${candidate}/${marker}" ]; then
        printf '%s\n' "${candidate}"
        return 0
      fi
    fi
  fi

  return 1
}

resolve_shm_queue_src() {
  if resolve_repo_source_path "SHM_QUEUE_SRC" "shm_queue.nim" "../nim-shm-queue/src"; then
    return 0
  fi
  echo "missing nim-shm-queue source; set SHM_QUEUE_SRC or provide ../nim-shm-queue/src" >&2
  return 2
}

# The marker for nim-bearssl is the module the build actually needs, not the
# package's root file.
#
# `bearssl.nim` sits at the root of EVERY revision of the package, including
# ones predating the `bearssl/abi/` module tree that `repro_deploy_agent`
# imports. A probe testing only for the root file therefore accepts a checkout
# that cannot satisfy the import, and the build dies several layers later on
# `cannot open file: bearssl/abi/consttypes` — a message naming the module
# rather than the wrong checkout that lacks it. Probing for the module itself
# makes the check reject exactly what the compiler would reject.
bearssl_layout_marker="bearssl/abi/consttypes.nim"

resolve_bearssl_src() {
  # An explicitly supplied BEARSSL_SRC that does not carry the module tree is
  # an ERROR, not a reason to go looking elsewhere. Quietly substituting a
  # different checkout for the one the caller named is how the wrong bearssl
  # came to be used in the first place, and it would hide a stale pin in
  # whatever set the variable.
  if [ -n "${BEARSSL_SRC:-}" ] && [ ! -f "${BEARSSL_SRC}/${bearssl_layout_marker}" ]; then
    echo "BEARSSL_SRC=${BEARSSL_SRC} has no ${bearssl_layout_marker};" >&2
    echo "  that checkout predates the bearssl/abi/ module tree reprobuild needs." >&2
    echo "  Unset BEARSSL_SRC to use the dev shell's pinned nim-bearssl, or point" >&2
    echo "  it at a checkout carrying that file." >&2
    return 2
  fi
  # `libs/` first, then the env value / sibling / dev-shell chain. The dev
  # shell's value comes from the flake's pinned input, so it is authoritative —
  # unlike a scan of /nix/store, which returns whichever nim-bearssl some other
  # derivation happens to have left behind.
  if [ -f "libs/nim-bearssl/${bearssl_layout_marker}" ]; then
    printf '%s\n' "libs/nim-bearssl"
    return 0
  fi
  if resolve_repo_source_path "BEARSSL_SRC" "${bearssl_layout_marker}" "../nim-bearssl"; then
    return 0
  fi
  echo "missing nim-bearssl source carrying ${bearssl_layout_marker}." >&2
  echo "  Build inside the dev shell (nix develop, or scripts/dev-shell.sh), which" >&2
  echo "  exports BEARSSL_SRC from the flake's pinned input; or set BEARSSL_SRC to a" >&2
  echo "  checkout of it; or place one at ../nim-bearssl." >&2
  return 2
}
