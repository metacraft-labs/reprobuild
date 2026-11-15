# shellcheck shell=bash
#
# scripts/lib/package_build_openssl.sh — package-build detection and the
# OpenSSL link-search selection for --define:ssl entrypoints. Sourced by
# scripts/build_apps.sh; tests/integration/t_package_build_openssl_selection.nim
# runs this real file under `env -i`. Defines `package_build`,
# `require_package_prefix` and `openssl_passl`; exits 2 on a refusal.

# A package build (`nix build`) must resolve every library from its own
# closure. Darwin builds are not sandboxed, so an ambient Homebrew prefix or
# a `/nix/store/*` glob match is visible to them and silently becomes a
# link-time rpath, which makes the output depend on the builder. In that mode
# the host fallbacks below are refused: a missing prefix variable fails the
# build instead. A dev shell sets IN_NIX_SHELL (and also NIX_BUILD_TOP), so it
# keeps the fallbacks.
package_build=0
if [ -n "${NIX_BUILD_TOP:-}" ] && [ -z "${IN_NIX_SHELL:-}" ]; then
  package_build=1
fi
require_package_prefix() {
  local name="$1"
  if [ "${package_build}" = 1 ] && [ -z "${!name:-}" ]; then
    echo "error: ${name} is unset in a Nix package build." >&2
    echo "       Falling back to a host library (Homebrew, or the first matching" >&2
    echo "       /nix/store path) would bake a path outside the package's closure" >&2
    echo "       into its LC_RPATH / DT_RPATH. Set ${name} in the derivation's env." >&2
    exit 2
  fi
}

openssl_passl=()
for tok in ${NIX_LDFLAGS:-}; do
  case "$tok" in
    -L*openssl*)
      openssl_passl=("--passL:${tok}" "--passL:-lssl" "--passL:-lcrypto")
      break
      ;;
  esac
done
if [ ${#openssl_passl[@]} -eq 0 ] && [ "${package_build}" = 1 ] &&
    [ -n "${OPENSSL_LIBDIR:-}" ] && [ -d "${OPENSSL_LIBDIR}" ]; then
  # The derivation names its OpenSSL explicitly; that is as much a closure
  # path as NIX_LDFLAGS' -L, and does not depend on how a platform's
  # cc-wrapper spells it.
  openssl_passl=("--passL:-L${OPENSSL_LIBDIR}" "--passL:-lssl" "--passL:-lcrypto")
fi
if [ ${#openssl_passl[@]} -eq 0 ] && [ "${package_build}" = 1 ]; then
  echo "error: no OpenSSL -L in NIX_LDFLAGS or OPENSSL_LIBDIR in a Nix package build; refusing the" >&2
  echo "       Homebrew fallback (it would plant a host rpath in the package)." >&2
  exit 2
fi
if [ ${#openssl_passl[@]} -eq 0 ]; then
  for candidate_dir in "/opt/homebrew/opt/openssl/lib" "/opt/homebrew/opt/openssl@3/lib" "/usr/local/opt/openssl/lib"; do
    if [ -d "$candidate_dir" ]; then
      openssl_passl=("--passL:-L${candidate_dir}" "--passL:-lssl" "--passL:-lcrypto")
      break
    fi
  done
fi
