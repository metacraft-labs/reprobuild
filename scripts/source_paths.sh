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
