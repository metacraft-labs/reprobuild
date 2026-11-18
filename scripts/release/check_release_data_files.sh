#!/usr/bin/env bash
# check_release_data_files.sh <package-dir>
#
# Prove a staged or unpacked release tree carries every data file its own
# recipes name for the installed engine to read at RUN time.
#
# WHAT IS CHECKED. A recipe's provisioning arm can name a file beside it:
#
#   tarball ..., closureManifest = "closures/<name>.manifest"
#   nixPackage ..., expressionFile = "nix/<name>/default.nix"
#
# Both resolve against the directory of the module that declares them, which
# for an installed reprobuild is a module under share/repro, and both are
# opened only when that arm is realized. A tree missing one compiles, starts
# and passes every other check here, then fails in a consumer's first
# provisioning on that platform. v0.2.26's Windows archive was that case:
#
#   tool-resolution failed: closure manifest not found:
#   ...\share\repro\source\libs\repro_dsl_stdlib\src\repro_dsl_stdlib\
#   packages\closures\playwright-core-1.56.1-windows.manifest
#
# The expected list is DERIVED from the tree's own recipes, never written
# down here: every `closureManifest =` / `expressionFile =` argument in a
# `.nim` file under share/repro (reprobuild's libs, the source-only inputs and
# the reprobuild-packages catalog). A value is a string literal or the name of
# a string constant declared in the same module; any other form fails the
# check rather than going unchecked, so a recipe written in a new form extends
# this script instead of slipping past it. A Nix expression is followed
# through the relative paths it imports (`import ../nixpkgs.nix`), each of
# which must exist too.
#
# What it cannot see: a file an expression reads without importing it (the
# stylus expression's `src = ./.` takes its whole directory, package.json and
# package-lock.json with it). The stager ships every file of the source root
# for that reason (stage_release_sources.sh); this check proves the files the
# recipes name, which is what a consumer's error names.
#
# Uses bash builtins plus grep, sed, tr and awk, spawned per matching line or
# per referenced file, never per file of the tree: it runs in Git for
# Windows' bash on the Windows release leg, where a process costs tens of
# milliseconds.
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <package-dir>" >&2
  exit 64
fi
me=check_release_data_files

# normalize <path>: drop `./` and fold `<dir>/../` segments, so a file reached
# by two routes is checked and reported once, under one name.
normalize() {
  local lead="" part out=() IFS=/
  [[ "$1" == /* ]] && lead=/
  # Split on `/` (IFS) with globbing off, so a component is never a pattern.
  set -f
  # shellcheck disable=SC2086 # the split is the point
  set -- $1
  set +f
  for part in "$@"; do
    case "$part" in
      ''|.) ;;
      ..)
        if (( ${#out[@]} > 0 )) && [[ "${out[${#out[@]}-1]}" != .. ]]; then
          unset "out[${#out[@]}-1]"
        else
          out+=(..)
        fi ;;
      *) out+=("$part") ;;
    esac
  done
  printf '%s%s' "$lead" "${out[*]-}"
}

pkg=$1
# Normalized like every path reported below, so each one is shown relative to
# it however the package directory was spelled (`pkg/`, `./pkg`).
share=$(normalize "$pkg/share/repro")
[[ -d "$share" ]] || { echo "$me: ERROR: $pkg has no share/repro" >&2; exit 1; }

# Relative to $share, so a grep hit's `<file>:<line>:` prefix holds no drive
# colon however the package directory was spelled.
roots=()
for r in source src reprobuild-packages; do
  [[ -d "$share/$r" ]] && roots+=("$r")
done

checked=0
problems=()
seen=$'\n'

# check_file <path> <why>: record whether a referenced file is present; for a
# Nix expression, follow the relative paths it imports.

check_file() {
  local path why=$2
  path=$(normalize "$1")
  case "$seen" in *$'\n'"$path"$'\n'*) return 0 ;; esac
  seen+="$path"$'\n'
  checked=$((checked + 1))
  if [[ ! -f "$path" ]]; then
    echo "  MISSING ${path#"$share"/}  ($why)"
    problems+=("${path#"$share"/} ($why)")
    return 0
  fi
  echo "  ok      ${path#"$share"/}  ($why)"
  [[ "$path" == *.nix ]] || return 0
  local dir=${path%/*} rel
  # Comments dropped; `import <relative path>` is the form the stdlib's
  # expressions use to reach a shared one (nixpkgs.nix, rust-release.nix).
  while IFS= read -r rel; do
    [[ -n "$rel" ]] || continue
    check_file "$dir/$rel" "imported by ${path#"$share"/}"
  done < <(sed -e 's/#.*//' "$path" | tr -d '\r' |
             grep -oE 'import[[:space:]]+\.\.?/[A-Za-z0-9._/+-]+' |
             sed -E 's/^import[[:space:]]+//' || true)
}

# The string a constant `<name>` is declared with in <file>: `Name* = "v"` on
# one line, or `Name* =` with the literal on the next non-blank line.
const_value() {
  # awk, not a sed script with labels: BSD sed (macOS) and GNU sed disagree
  # on those, and the release verification runs under both.
  tr -d '\r' < "$1" | awk -v name="$2" '
    function literal(s) {
      if (match(s, /^[[:space:]]*"[^"]*"/)) {
        s = substr(s, RSTART, RLENGTH); sub(/^[[:space:]]*"/, "", s)
        sub(/"$/, "", s); print s; return 1
      }
      return 0
    }
    pending {
      if ($0 ~ /^[[:space:]]*$/) next
      literal($0); exit
    }
    {
      line = $0
      if (!sub("^[[:space:]]*" name "[*]?[[:space:]]*(:[^=]*)?=", "", line)) next
      if (line ~ /^[[:space:]]*$/) { pending = 1; next }
      literal(line); exit
    }'
}

echo "=== Checking the run-time data files the recipes in $share name ==="
refs=0
if (( ${#roots[@]} > 0 )); then
  # One grep over the whole tree; only the few matching lines are processed.
  # The pattern is a keyword argument at the start of a line or after `(` /
  # `,`: implementation code (`result.closureManifest = ...`, `let
  # expressionFile = ...`) and prose (`# ``closureManifest = ...``) do not
  # match it.
  while IFS= read -r hit; do
    hit=${hit%$'\r'}
    file=$share/${hit%%:*}; rest=${hit#*:}
    line=${rest%%:*}; text=${rest#*:}
    key=$(printf '%s' "$text" |
          sed -E 's/.*(closureManifest|expressionFile)[[:space:]]*=.*/\1/')
    value=$(printf '%s' "$text" |
            sed -E 's/.*(closureManifest|expressionFile)[[:space:]]*=[[:space:]]*//; s/[[:space:]]*[,)].*$//; s/[[:space:]]*$//')
    where="$key of ${file#"$share"/}:$line"
    refs=$((refs + 1))
    case "$value" in
      \"*\")
        rel=${value#\"}; rel=${rel%\"} ;;
      *)
        if [[ "$value" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
          rel=$(const_value "$file" "$value")
          if [[ -z "$rel" ]]; then
            problems+=("$where: $value is not a string constant declared in that module; extend $me to resolve it")
            echo "  UNRESOLVED $where = $value"
            continue
          fi
        else
          problems+=("$where: '$value' is not a string literal or a constant name; extend $me to resolve it")
          echo "  UNRESOLVED $where = $value"
          continue
        fi ;;
    esac
    case "$rel" in
      /*|[A-Za-z]:*)
        problems+=("$where: '$rel' is absolute, so it names a file of the machine the recipe was written on")
        echo "  ABSOLUTE $where = $rel"
        continue ;;
    esac
    check_file "${file%/*}/$rel" "$where"
  done < <(cd "$share" && grep -rnE --include='*.nim' \
             '(^|[(,])[[:space:]]*(closureManifest|expressionFile)[[:space:]]*=' \
             "${roots[@]}" || true)
fi

# Positive control. reprobuild's stdlib declares these (playwright's Windows
# closure, the Nix expressions of go, rustc and others), so a scan that finds
# none is a scan that did not run -- a moved tree or a grep that read nothing
# -- not a tree with nothing to check.
if (( refs == 0 )); then
  echo "$me: ERROR: no closureManifest/expressionFile reference found under $share;" >&2
  echo "  the scan read nothing (is share/repro/source/libs staged?)" >&2
  exit 1
fi
if (( ${#problems[@]} > 0 )); then
  echo "$me: ERROR: the recipes in $pkg name data files the tree does not carry:" >&2
  printf '  %s\n' "${problems[@]}" >&2
  echo "  An installed reprobuild opens these when it realizes the arm that names" >&2
  echo "  them. Staged by scripts/release/stage_release_sources.sh." >&2
  exit 1
fi
echo "=== data files OK: $checked file(s) named by $refs reference(s), all present ==="
