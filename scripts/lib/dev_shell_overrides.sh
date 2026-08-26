# shellcheck shell=bash
#
# scripts/lib/dev_shell_overrides.sh — the two invariants that keep this
# repository's dev shell honest about what it is built from.
#
# Both exist because of the same failure shape: a mechanism that LOOKS
# authoritative while being ignored, so the shell a developer is standing in
# is built from something other than what the configuration says.
#
#   1. `.envrc` sets `NIX_FLAKE_OVERRIDE_*` knobs that only the flake-overrides
#      plugin can act on. If the plugin that actually gets loaded predates a
#      knob, that knob is inert: `flake_override_args_quoted` prints nothing,
#      `use flake` runs on the PINNED inputs, and nothing anywhere says so.
#      `dev_shell_guard_override_knobs` refuses to let that be silent. It does
#      not ask the plugin its version or look for an internal symbol — it makes
#      the plugin PERFORM each declared knob against a throwaway probe tree and
#      checks that the override came out. A plugin that renames its internals
#      still passes; a plugin that quietly drops a feature still fails.
#
#   2. An override resolved to a sibling working tree (`--override-input x
#      path:../x`) makes that tree a build input — but nothing in nix-direnv's
#      watch set mentions it. `use_flake` watches `flake.nix`, `flake.lock`,
#      `devshell.toml` and the direnvrc files, and invalidates the cached
#      profile only when one of those is newer than `.direnv/flake-profile-*.rc`.
#      A sibling can therefore advance by any number of commits without the
#      cache ever noticing: that is how `RUNQUOTA_SRC` came to name a store
#      path fifteen days and fifty-nine commits stale while direnv reported
#      "using cached dev shell". The fingerprint below closes that hole by
#      turning "what the overridden sources are at right now" into a FILE, so
#      direnv's existing staleness machinery can watch it like any other input.
#
# Sourced from three places, which is why it is a library and not inline in
# `.envrc`: `.envrc` itself (guard + fingerprint, at shell entry),
# `scripts/check_dev_shell_env.sh` (the `just lint` gate, offline), and
# `tests/integration/t_dev_shell_override_guards.nim` (the regression tests).

# ---------------------------------------------------------------------------
# Knob declaration
# ---------------------------------------------------------------------------

# Every `NIX_FLAKE_OVERRIDE_*` knob this repository knows how to verify.
# `check_dev_shell_env.sh` requires that every knob an `.envrc` sets appears
# here, so adding a knob without a probe fails lint rather than shipping a
# second inert setting.
DEV_SHELL_KNOWN_OVERRIDE_KNOBS=(
  NIX_FLAKE_OVERRIDE_INPUTS
  NIX_FLAKE_OVERRIDE_FLAKES
  NIX_FLAKE_OVERRIDE_SIBLINGS
  NIX_FLAKE_OVERRIDE_SIBLINGS_ROOT
  NIX_FLAKE_OVERRIDE_AUTO
  NIX_FLAKE_OVERRIDE_AUTO_STRIP_SUFFIXES
)

# Print the `NIX_FLAKE_OVERRIDE_*` knobs a given `.envrc` exports, one per
# line, in file order and without duplicates. Only `export NAME=` and plain
# `NAME=` at the start of a line count: a knob mentioned in a comment is not a
# knob that is set.
dev_shell_declared_override_knobs() {
  local envrc="$1"
  [[ -f "$envrc" ]] || return 0
  sed -n 's/^[[:space:]]*\(export[[:space:]][[:space:]]*\)\{0,1\}\(NIX_FLAKE_OVERRIDE_[A-Z_]*\)=.*/\2/p' \
    "$envrc" | awk '!seen[$0]++'
}

# ---------------------------------------------------------------------------
# Behavioural probes
# ---------------------------------------------------------------------------
#
# Each probe runs `flake_override_args_quoted` — the plugin's one public entry
# point — inside a subshell with a synthetic environment in which exactly one
# override MUST be produced, and reports whether it was. Positive by
# construction: a probe that matched nothing would be indistinguishable from a
# plugin that works, so every probe asserts the presence of a specific
# `--override-input` / `--override-flake` for a name that appears nowhere else.

_dev_shell_probe_root() {
  local tmp
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/repro-fo-probe.XXXXXX")" || return 1
  mkdir -p "$tmp/probe-sibling"
  # `_nfo_emit_sibling` refuses a sibling with no `flake.nix`, so the probe
  # tree has to look like a flake for the probe to mean anything.
  printf '{ outputs = _: { }; }\n' >"$tmp/probe-sibling/flake.nix"
  printf '%s' "$tmp"
}

# Run `flake_override_args_quoted` with the plugin's env fully reset except
# for the assignments passed as `NAME=VALUE` arguments. Prints its output.
_dev_shell_run_override_args() {
  (
    unset NIX_FLAKE_OVERRIDE_INPUTS NIX_FLAKE_OVERRIDE_FLAKES \
      NIX_FLAKE_OVERRIDE_SIBLINGS NIX_FLAKE_OVERRIDE_SIBLINGS_ROOT \
      NIX_FLAKE_OVERRIDE_AUTO NIX_FLAKE_OVERRIDE_AUTO_STRIP_SUFFIXES
    local assignment
    for assignment in "$@"; do
      export "${assignment?}"
    done
    # The auto arm asks nix for the flake's input names. Answering it here
    # keeps the probe offline, instantaneous, and independent of whether this
    # repository's flake happens to declare an input with a sibling.
    # shellcheck disable=SC2329  # called by the plugin's auto arm, not here
    _nfo_flake_input_names() { printf 'probe-sibling-src\n'; }
    flake_override_args_quoted 2>/dev/null
  )
}

_dev_shell_probe_inputs() {
  local out
  out="$(_dev_shell_run_override_args \
    "NIX_FLAKE_OVERRIDE_INPUTS=probe-explicit=github:probe/probe")"
  [[ "$out" == *"--override-input"* && "$out" == *"probe-explicit"* ]]
}

_dev_shell_probe_flakes() {
  local out
  out="$(_dev_shell_run_override_args \
    "NIX_FLAKE_OVERRIDE_FLAKES=probe-flake=github:probe/probe")"
  [[ "$out" == *"--override-flake"* && "$out" == *"probe-flake"* ]]
}

_dev_shell_probe_siblings() {
  local root out
  root="$(_dev_shell_probe_root)" || return 2
  out="$(_dev_shell_run_override_args \
    "NIX_FLAKE_OVERRIDE_SIBLINGS=probe-sibling" \
    "NIX_FLAKE_OVERRIDE_SIBLINGS_ROOT=$root")"
  rm -rf "$root"
  [[ "$out" == *"--override-input"* && "$out" == *"probe-sibling"* ]]
}

# `NIX_FLAKE_OVERRIDE_SIBLINGS_ROOT` only means anything through one of the
# sibling arms, so it is probed through the auto arm below; on its own it is
# satisfied by the same evidence.
_dev_shell_probe_siblings_root() { _dev_shell_probe_auto; }

_dev_shell_probe_auto() {
  local root out
  root="$(_dev_shell_probe_root)" || return 2
  # The stubbed input name is `probe-sibling-src` and the sibling on disk is
  # `probe-sibling`, so this single probe covers the auto arm AND the `-src`
  # suffix stripping that every one of this repository's inputs depends on.
  out="$(_dev_shell_run_override_args \
    "NIX_FLAKE_OVERRIDE_AUTO=1" \
    "NIX_FLAKE_OVERRIDE_AUTO_STRIP_SUFFIXES=-src" \
    "NIX_FLAKE_OVERRIDE_SIBLINGS_ROOT=$root")"
  rm -rf "$root"
  [[ "$out" == *"--override-input"* && "$out" == *"probe-sibling-src"* ]]
}

_dev_shell_probe_auto_strip_suffixes() { _dev_shell_probe_auto; }

# Verify that the flake-overrides plugin loaded in THIS shell actually acts on
# the knobs it is asked about. Prints a diagnostic naming each inert knob and
# returns 1.
#
# With no arguments it probes every knob that is currently SET — a knob nobody
# uses is not worth refusing a shell over. With explicit knob names it probes
# all of them whether they are set or not: that is the form `.envrc` uses, and
# it is the difference between finding a stale plugin pin the moment it goes
# stale and finding it the day somebody first tries to use the feature.
#
# Returns 2 — a different failure, deliberately — when there is no plugin at
# all, because "the plugin never loaded" and "the plugin is too old" want
# different remedies.
dev_shell_guard_override_knobs() {
  local knobs=("$@")
  local probe_unset=1
  if [[ ${#knobs[@]} -eq 0 ]]; then
    probe_unset=0
    local knob
    for knob in "${DEV_SHELL_KNOWN_OVERRIDE_KNOBS[@]}"; do
      [[ -n "${!knob:-}" ]] && knobs+=("$knob")
    done
  fi
  [[ ${#knobs[@]} -eq 0 ]] && return 0

  if ! declare -F flake_override_args_quoted >/dev/null 2>&1; then
    _dev_shell_say \
      "the flake-overrides plugin did not load, but ${knobs[*]} is set." \
      "Nothing would translate it into --override-input, so the shell would" \
      "be built from the pinned inputs while the configuration says" \
      "otherwise. Refusing to continue."
    return 2
  fi

  local inert=()
  local knob probe
  for knob in "${knobs[@]}"; do
    if [[ "$probe_unset" -eq 0 && -z "${!knob:-}" ]]; then
      continue
    fi
    probe="_dev_shell_probe_$(printf '%s' "${knob#NIX_FLAKE_OVERRIDE_}" |
      tr '[:upper:]' '[:lower:]')"
    if ! declare -F "$probe" >/dev/null 2>&1; then
      printf 'dev-shell: %s is set but this repository has no probe for it;\n' \
        "$knob" >&2
      printf 'dev-shell: add one to scripts/lib/dev_shell_overrides.sh.\n' >&2
      inert+=("$knob")
      continue
    fi
    "$probe" || inert+=("$knob")
  done

  [[ ${#inert[@]} -eq 0 ]] && return 0

  _dev_shell_say \
    "the loaded flake-overrides plugin ignores ${inert[*]}." \
    "The plugin loads, emits no --override-input for those knobs, and" \
    "'use flake' then builds the shell from the PINNED inputs while .envrc" \
    "says it builds from the workspace siblings. Refusing to continue rather" \
    "than proceeding under a configuration this repository does not have." \
    "" \
    "Remedy: bump the pinned plugin revision in .envrc to a build that" \
    "implements the knob — the published plugin at" \
    "https://direnv-flake-overrides.blocksense.network/plugin does — or check" \
    "out ../direnv-nix-flake-overrides, which .envrc prefers when present."
  return 1
}

# Emit a `dev-shell:`-prefixed diagnostic, one argument per line.
_dev_shell_say() {
  local line
  for line in "$@"; do
    if [[ -z "$line" ]]; then
      printf 'dev-shell:\n' >&2
    else
      printf 'dev-shell: %s\n' "$line" >&2
    fi
  done
}

# ---------------------------------------------------------------------------
# Override-source fingerprint
# ---------------------------------------------------------------------------

DEV_SHELL_FINGERPRINT_HEADER='# reprobuild dev-shell override-source fingerprint v1'

# Describe one overridden source in a way that changes whenever the bytes nix
# would copy change. `path:` inputs copy the working tree, so the commit alone
# is not enough — an uncommitted edit is just as much a different input.
#
# Known limit, stated rather than papered over: files excluded by `.gitignore`
# are copied by `path:` but do not appear in `git status`, so an edit confined
# to one of those is not detected. That is the residue; the reported failure —
# a sibling that advanced by commits — is covered exactly.
dev_shell_source_state() {
  local dir="$1"
  if [[ ! -d "$dir" ]]; then
    printf 'absent'
    return 0
  fi
  if [[ -e "$dir/.git" ]] && command -v git >/dev/null 2>&1; then
    local head status
    head="$(git -C "$dir" rev-parse HEAD 2>/dev/null)" || head=unborn
    status="$(git -C "$dir" status --porcelain 2>/dev/null | _dev_shell_digest)"
    printf 'git:%s+%s' "$head" "$status"
    return 0
  fi
  # No git: fall back to the newest mtime in the tree. Coarse, but it is only
  # reached for vendored sources that are not checkouts at all. `stat -c` is
  # GNU and `stat -f` is BSD; trying both keeps macOS from silently landing on
  # the "no evidence" branch, which would never drift and never say why.
  local newest
  newest="$(find "$dir" -type f -exec stat -c %Y {} + 2>/dev/null |
    sort -rn | head -n 1)"
  if [[ -z "$newest" ]]; then
    newest="$(find "$dir" -type f -exec stat -f %m {} + 2>/dev/null |
      sort -rn | head -n 1)"
  fi
  printf 'mtime:%s' "${newest:-none}"
}

_dev_shell_digest() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | cut -c1-16
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | cut -c1-16
  else
    cksum | tr -d ' '
  fi
}

# Turn `flake_override_args_quoted` output (read from stdin) into
# `input<TAB>dir` lines for the `path:` overrides — the only ones whose source
# is a working tree this machine can change behind the cache's back.
dev_shell_override_path_pairs_from_args() {
  local args
  args="$(cat)"
  local words=()
  eval "words=( $args )"
  local i=0
  # Both `--override-input` and `--override-flake` are exactly three words,
  # so a stride of three lands on every flag and never mid-triple.
  while (( i + 2 < ${#words[@]} )); do
    if [[ "${words[i]:-}" == "--override-input" && "${words[i + 2]:-}" == path:* ]]; then
      printf '%s\t%s\n' "${words[i + 1]}" "${words[i + 2]#path:}"
    fi
    i=$((i + 3))
  done
}

# The same thing, asking the loaded plugin for the arguments. Requires the
# plugin; prints nothing without it.
dev_shell_override_path_pairs() {
  declare -F flake_override_args_quoted >/dev/null 2>&1 || return 0
  flake_override_args_quoted 2>/dev/null |
    dev_shell_override_path_pairs_from_args
}

# Render the fingerprint for a set of `input<TAB>dir` pairs read on stdin.
dev_shell_render_fingerprint() {
  printf '%s\n' "$DEV_SHELL_FINGERPRINT_HEADER"
  local input dir
  while IFS=$'\t' read -r input dir; do
    [[ -n "$input" ]] || continue
    printf '%s\t%s\t%s\n' "$input" "$dir" "$(dev_shell_source_state "$dir")"
  done | LC_ALL=C sort
}

# Write the fingerprint only when it differs, so the file's mtime moves when —
# and only when — an overridden source moved. That is the whole trick: direnv
# invalidates on mtime, so a file that churns on every load would rebuild the
# shell constantly, and a file that never moves would never invalidate at all.
dev_shell_write_fingerprint() {
  local path="$1" body="$2"
  if [[ -f "$path" ]] && [[ "$(cat "$path")" == "$body" ]]; then
    return 0
  fi
  mkdir -p "$(dirname "$path")"
  printf '%s\n' "$body" >"$path"
}

# Compare a recorded fingerprint against the sources as they are NOW. Prints
# one line per drifted input and returns 1 if any drifted.
dev_shell_fingerprint_drift() {
  local path="$1"
  [[ -f "$path" ]] || return 0
  local drifted=0 input dir recorded current
  while IFS=$'\t' read -r input dir recorded; do
    [[ -n "$input" ]] || continue
    [[ "$input" == \#* ]] && continue
    current="$(dev_shell_source_state "$dir")"
    if [[ "$current" != "$recorded" ]]; then
      printf '%s\t%s\t%s\t%s\n' "$input" "$dir" "$recorded" "$current"
      drifted=1
    fi
  done <"$path"
  return "$drifted"
}
