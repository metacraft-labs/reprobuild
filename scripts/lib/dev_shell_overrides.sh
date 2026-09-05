# shellcheck shell=bash
#
# scripts/lib/dev_shell_overrides.sh — the invariants that keep this
# repository's dev shell honest.
#
# The first two are about what the shell is BUILT FROM, and both exist because
# of the same failure shape: a mechanism that LOOKS authoritative while being
# ignored, so the shell a developer is standing in is built from something
# other than what the configuration says. The third — at the bottom of this
# file, under "Loader injection" — is about what the shell DOES TO the
# processes started inside it, which is a different question with a different
# blast radius: it reaches binaries the shell neither built nor provides.
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
# Sourced from four places, which is why it is a library and not inline in
# `.envrc`: `.envrc` itself (guard + fingerprint, at shell entry),
# `scripts/check_dev_shell_env.sh` (the `just lint` gate, offline),
# `tests/integration/t_dev_shell_override_guards.nim` (the regression tests for
# the first two invariants) and
# `tests/integration/t_dev_shell_one_glibc_reaches_subprocesses.nim` (the third).

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
# Reachability of the auto-override arm
# ---------------------------------------------------------------------------
#
# The knob probes above answer "does the plugin ACT on the knobs .envrc sets".
# They cannot answer "does acting on them reach input X", and that gap is not
# hypothetical: it hid `stackable-hooks-src` for 30 commits.
#
# The auto arm strips a declared suffix off each flake input name and overrides
# the input when a sibling DIRECTORY OF THAT EXACT NAME exists. So an input
# whose upstream repository is `nim-stackable-hooks` but whose input name is
# `stackable-hooks-src` strips to `stackable-hooks`, matches no directory, and
# is silently left on its lock pin — while every other sibling-backed input in
# the same flake tracks the working tree. Nothing downstream could see it:
# `check_dev_shell_env.sh`'s fingerprint reconciles the inputs that WERE
# overridden, so an input missing from that set is missing from the check too.
# The blind spot had exactly the shape of the defect.
#
# What makes it detectable is that the flake states the upstream repository in
# the input's own `url`. Input name and repository name are two spellings of
# one thing, and when they disagree the auto arm cannot bridge them. This is a
# pure function of `flake.nix` plus the filesystem — offline, no nix
# evaluation, no plugin — which is what lets it run in `just lint`.

# Print `input<TAB>repo` for every input in a flake.nix that has a `url`, where
# `repo` is the repository basename the url points at — or `-` when the url
# names no repository (`path:` / `file:`), which has no sibling to be out of
# step with. Inputs with no `url` at all (pure `follows`) do not appear.
#
# The `-` rows exist so the row count is exactly the url count, which is what
# `dev_shell_flake_input_url_count` below is compared against.
dev_shell_flake_input_repos() {
  local flake="$1"
  [[ -f "$flake" ]] || return 0
  awk '
    /^  inputs = \{/ { inputs = 1; next }
    inputs && /^  \};/ { inputs = 0 }
    !inputs { next }
    # Single-line form: `name.url = "…";`
    match($0, /^    [A-Za-z0-9_.-]+\.url = "[^"]+";/) {
      name = $0; sub(/^    /, "", name); sub(/\.url.*/, "", name)
      url = $0; sub(/^[^"]*"/, "", url); sub(/".*$/, "", url)
      print name "\t" url; next
    }
    # Attribute-set form: `name = {` … `url = "…";` … `};`
    match($0, /^    [A-Za-z0-9_.-]+ = \{/) {
      cur = $0; sub(/^    /, "", cur); sub(/ = \{.*/, "", cur); next
    }
    cur != "" && match($0, /^      url = "[^"]+";/) {
      url = $0; sub(/^[^"]*"/, "", url); sub(/".*$/, "", url)
      print cur "\t" url; cur = ""; next
    }
    cur != "" && /^    \};/ { cur = "" }
  ' "$flake" | while IFS=$'\t' read -r name url; do
    local repo
    repo="$(_dev_shell_repo_from_url "$url")"
    printf '%s\t%s\n' "$name" "${repo:--}"
  done
}

# How many `url = "…"` assignments the flake's `inputs` block contains,
# counted WITHOUT the structural parse above. The two numbers must agree, and
# the caller fails when they do not.
#
# A silent UNDER-parse is the dangerous failure here, not a crash: the parser
# keys on this flake's exact indentation, so a reformat, a nested attribute
# set, or a new input shape makes it match fewer inputs — and every input it
# stopped matching is an input this check silently stops examining, which reads
# exactly like "no problems found". `scripts/reprobuild_suite_inventory.py`
# records the same lesson from a field-list change that emptied a checked-in
# baseline from 1357 rows to 18. An independent count is the cheapest thing
# that can notice.
dev_shell_flake_input_url_count() {
  local flake="$1"
  [[ -f "$flake" ]] || { printf '0'; return 0; }
  awk '
    /^  inputs = \{/ { inputs = 1; next }
    inputs && /^  \};/ { inputs = 0 }
    !inputs { next }
    # Both spellings an input can carry a url in: the nested `url = "…";` of an
    # attribute set, and the flattened `name.url = "…";`.
    /(^|[[:space:]]|\.)url = "/ { n++ }
    END { printf "%d", n + 0 }
  ' "$flake"
}

# The repository basename a flake input url points at, or nothing when the url
# does not name one.
_dev_shell_repo_from_url() {
  local url="$1" rest
  case "$url" in
    path:* | file:* | "") return 0 ;;
    github:* | gitlab:* | sourcehut:*)
      # `<type>:<owner>/<repo>[/<ref-or-rev>][?query]`
      rest="${url#*:}"
      rest="${rest#*/}"
      rest="${rest%%\?*}"
      rest="${rest%%/*}"
      ;;
    *)
      # `git+https://host/owner/repo[.git][?query]`, and anything else with a
      # path. Drop the query first: `?ref=…` can otherwise contain slashes.
      rest="${url%%\?*}"
      rest="${rest%/}"
      rest="${rest##*/}"
      rest="${rest%.git}"
      ;;
  esac
  [[ "$rest" == *:* ]] && return 0
  printf '%s' "$rest"
}

# The suffixes the auto arm is configured to strip, one per line, read from an
# `.envrc`. Prints nothing when the auto arm is not enabled there, which is the
# signal that this whole check does not apply.
dev_shell_auto_strip_suffixes() {
  local envrc="$1"
  [[ -f "$envrc" ]] || return 0
  grep -Eq '^[[:space:]]*(export[[:space:]]+)?NIX_FLAKE_OVERRIDE_AUTO=' "$envrc" ||
    return 0
  local raw
  raw="$(sed -n 's/^[[:space:]]*\(export[[:space:]][[:space:]]*\)\{0,1\}NIX_FLAKE_OVERRIDE_AUTO_STRIP_SUFFIXES=[",'"'"']*\([^",'"'"']*\).*/\2/p' \
    "$envrc" | head -n 1)"
  # The plugin splits on commas and always considers the empty suffix (an input
  # named exactly like its sibling), so mirror both.
  printf '%s\n' "" ${raw:+$(printf '%s\n' "$raw" | tr ',' '\n')}
}

# The directory the auto arm looks for siblings in.
dev_shell_siblings_root() {
  local repo_root="$1"
  if [[ -n "${NIX_FLAKE_OVERRIDE_SIBLINGS_ROOT:-}" ]]; then
    printf '%s' "$NIX_FLAKE_OVERRIDE_SIBLINGS_ROOT"
  else
    printf '%s' "$(dirname "$repo_root")"
  fi
}

# The name the auto arm would look for, given an input name and the configured
# suffixes: the longest declared suffix the name ends with is removed.
dev_shell_strip_input_suffix() {
  local name="$1"
  shift
  local best="" suffix
  for suffix in "$@"; do
    [[ -n "$suffix" ]] || continue
    [[ "$name" == *"$suffix" ]] || continue
    (( ${#suffix} > ${#best} )) && best="$suffix"
  done
  printf '%s' "${name%"$best"}"
}

# THE CHECK. Print one `kind<TAB>input<TAB>stripped<TAB>repo<TAB>sibling` line
# per input whose sibling checkout the auto arm does not reach, where `kind` is
#
#   unreachable — the sibling exists under the REPOSITORY's name, but the
#                 input name does not strip to it. The auto arm is looking for
#                 a directory that does not exist. Renaming the input fixes it,
#                 here, today: this is the `stackable-hooks-src` defect.
#   unflakeable — the names agree and the sibling exists, but it has no
#                 `flake.nix`, which the plugin requires before it will emit an
#                 `--override-input`. Not fixable in this repository; it has to
#                 be declared instead, so that a NEW one is not silent.
#
# Returns 1 when any line was printed.
dev_shell_unreached_siblings() {
  local flake="$1" envrc="$2" repo_root="$3"
  local suffixes=()
  mapfile -t suffixes < <(dev_shell_auto_strip_suffixes "$envrc")
  # Only the empty suffix came back ⇒ the auto arm is off in this `.envrc`.
  local configured=0 s
  for s in "${suffixes[@]}"; do [[ -n "$s" ]] && configured=1; done
  [[ "$configured" -eq 1 ]] || return 0

  local root
  root="$(dev_shell_siblings_root "$repo_root")"
  local found=0 input repo stripped
  while IFS=$'\t' read -r input repo; do
    [[ -n "$input" ]] || continue
    # `-` is a url that names no repository at all (`path:` / `file:`); it is
    # carried through the listing only to keep the row count honest.
    [[ "$repo" == "-" ]] && continue
    stripped="$(dev_shell_strip_input_suffix "$input" "${suffixes[@]}")"
    # The auto arm looks ONLY under the stripped input name. When a directory
    # is there, that is the sibling this input resolves to (whatever the
    # upstream repository happens to be called — `nim-results-src` legitimately
    # points at `metacraft-labs/nim-result`), and the only remaining question
    # is whether the plugin will accept it.
    if [[ -d "$root/$stripped" ]]; then
      if [[ ! -f "$root/$stripped/flake.nix" ]]; then
        printf 'unflakeable\t%s\t%s\t%s\t%s\n' \
          "$input" "$stripped" "$repo" "$root/$stripped"
        found=1
      fi
      continue
    fi
    # Nothing under the stripped name — but the repository this input names IS
    # checked out beside us under its own name. The auto arm cannot bridge the
    # two spellings, so the input stays on its lock pin while its sibling moves.
    if [[ "$stripped" != "$repo" && -d "$root/$repo" ]]; then
      printf 'unreachable\t%s\t%s\t%s\t%s\n' \
        "$input" "$stripped" "$repo" "$root/$repo"
      found=1
    fi
  done < <(dev_shell_flake_input_repos "$flake")
  return "$found"
}

# Whether `flake.nix` declares an input this check could ever report on: one
# that appears in `dev_shell_flake_input_repos` — the same listing
# `dev_shell_unreached_siblings` walks — WITH a repository url. A row naming
# anything else describes an input that was renamed away or deleted, one that
# carries no `url` at all (a pure `follows`), or one whose url names no
# repository (`path:` / `file:`, listed as `-`). Every finding begins by
# resolving the input to a sibling repository checkout, so an input in any of
# those states can never produce a finding in ANY workspace, and a row excusing
# it is decay wherever it is read.
#
# The `-` case is why this asks for a url rather than mere presence. A
# `path:`-url input is skipped by `dev_shell_unreached_siblings` outright, so
# without this it would fall through to the shape question below and be excused
# in any workspace that happens to have no directory of that name — a row that
# describes nothing anywhere, passed over as though it described somewhere
# else.
#
# Kept separate from the shape question below on purpose. "This input can never
# be reported on" is decay that is true everywhere and must fail everywhere;
# "this input's sibling is not checked out here" is a statement about one
# workspace. Folding the first into the second would have let a row survive a
# rename in every workspace that happens not to clone the sibling, which is a
# weakening, and the point of the shape fix is that it is not one.
dev_shell_flake_declares_input() {
  local flake="$1" input="$2" f_input f_repo
  while IFS=$'\t' read -r f_input f_repo; do
    [[ "$f_input" == "$input" ]] || continue
    # `-` is a url that names no repository at all, the same rows
    # `dev_shell_unreached_siblings` skips. Declared, but never reportable.
    [[ "$f_repo" == "-" || -z "$f_repo" ]] && return 1
    return 0
  done < <(dev_shell_flake_input_repos "$flake")
  return 1
}

# Whether a `scripts/dev-shell-pinned-siblings.tsv` row can describe anything
# in THIS workspace: is the sibling checkout it is about on disk at all?
#
# Exit 0 = the sibling is here, so the row is a claim about this tree and the
# caller may hold it to it. Exit 1 = it is not, so the row describes a
# workspace shape other than this one.
#
# THIS IS THE SHAPE-AWARENESS THE STALE-DECLARATION ARM WAS MISSING, and its
# absence made the gate unsatisfiable rather than merely wrong. Every finding
# `dev_shell_unreached_siblings` produces begins with "the sibling exists", so
# the finding set is a function of which repositories a given workspace happens
# to have checked out — while the stale arm demanded an EXACT match against a
# list committed once for every workspace. A row for a sibling CI does not
# clone fails in CI; delete it and the workspace that DOES clone that sibling
# fails instead, on an undeclared finding. Both are the same file, so no
# content satisfied both shapes: `nim-stew-src` / `nim-results-src` were
# removed on 2026-09-01 for the CI half and this workspace failed on the other
# half from that day, which — because the pre-commit hook runs `just lint` —
# meant this repository accepted no commit at all here.
#
# A row whose subject is absent is not evidence of decay; it is evidence of a
# different workspace. Only a row whose sibling IS here and no longer produces
# a finding has genuinely stopped describing something, and that row still
# fails. The caller reports the skipped rows by name rather than dropping them
# silently, so a list that has quietly become inapplicable in EVERY shape is
# still visible to a reader.
#
# "The sibling" is looked for under both spellings a row can be about, matching
# the two finding kinds: the name the auto arm strips the input to
# (`unflakeable`, and the directory the arm actually probes), and the
# repository the input's url names (`unreachable`, where the two spellings
# differ and the checkout is under the repository's). An input no longer in
# `flake.nix` at all has no url to consult, so only the stripped name applies —
# which is correct: that is the directory whose presence would have produced
# the finding the row claims to excuse. Callers ask
# `dev_shell_flake_declares_input` FIRST, so by the time this runs the input is
# known to be one a finding could name.
dev_shell_declared_row_is_applicable() {
  local flake="$1" envrc="$2" repo_root="$3" input="$4"
  local suffixes=()
  mapfile -t suffixes < <(dev_shell_auto_strip_suffixes "$envrc")

  local root
  root="$(dev_shell_siblings_root "$repo_root")"

  local stripped
  stripped="$(dev_shell_strip_input_suffix "$input" "${suffixes[@]}")"
  [[ -d "$root/$stripped" ]] && return 0

  local f_input f_repo
  while IFS=$'\t' read -r f_input f_repo; do
    [[ "$f_input" == "$input" ]] || continue
    [[ "$f_repo" == "-" || -z "$f_repo" ]] && continue
    [[ -d "$root/$f_repo" ]] && return 0
  done < <(dev_shell_flake_input_repos "$flake")

  return 1
}

# ---------------------------------------------------------------------------
# Override-source fingerprint
# ---------------------------------------------------------------------------

DEV_SHELL_FINGERPRINT_HEADER='# reprobuild dev-shell override-source fingerprint v1'

# Ask git about the directory NAMED, not about whatever repository the ambient
# environment points at.
#
# `git -C <dir>` only changes the working directory, and the working directory
# is the LAST thing git consults. `GIT_DIR` and its companions are read first
# and win outright, so under an environment that sets them `git -C ../sibling
# rev-parse HEAD` cheerfully answers with the other repository's commit. Git
# hooks are exactly such an environment — git exports `GIT_DIR` (and usually
# `GIT_INDEX_FILE`, `GIT_PREFIX`, sometimes `GIT_WORK_TREE`) to every hook it
# runs — so a `just lint` fired from `pre-commit` saw every sibling report the
# hooking repository's HEAD, the whole fingerprint mismatched at once, and the
# gate demanded a `direnv reload` that could not possibly help. A failure no
# edit can clear is worse than no gate at all: it teaches `--no-verify`, which
# turns off the gates that DO work.
#
# What is neutralised, and why each earns its place — measured, not copied out
# of the manual:
#
#   GIT_DIR                            replaces discovery outright: both the
#                                      commit and the dirty state become the
#                                      other repository's.
#   GIT_WORK_TREE                      commit stays right, `status` compares
#                                      the sibling's index against a foreign
#                                      tree — every file reads as deleted.
#   GIT_INDEX_FILE                     `status` dies on a foreign index; the
#                                      digest of the empty output is the
#                                      digest of "clean", so a genuinely
#                                      dirty source silently stops drifting.
#   GIT_COMMON_DIR                     refs and objects resolve elsewhere;
#                                      same silent false-clean.
#   GIT_OBJECT_DIRECTORY               same, via the object store.
#   GIT_ALTERNATE_OBJECT_DIRECTORIES   alone it only ADDS object sources and
#                                      changed no answer under test, but git
#                                      sets it together with
#                                      GIT_OBJECT_DIRECTORY (push quarantine);
#                                      honouring half of a paired redirection
#                                      is less defensible than honouring none.
#
# Deliberately left alone: `GIT_PREFIX` is informational — it tells a hook
# where the user was standing and steers no lookup (verified: no effect on
# either query). `GIT_NAMESPACE` namespaces refs for the pack protocol, not
# `rev-parse HEAD` or `status` (verified likewise). `GIT_CEILING_DIRECTORIES`
# bounds the upward walk, and this function only ever names a directory that
# holds its own `.git`, so discovery stops before a ceiling is consulted
# (verified with the ceiling set to the checkout itself).
#
# The unsets live in a subshell so nothing escapes into the caller. That
# matters: `.envrc` SOURCES this file into the developer's interactive shell,
# where stripping git variables would be a side effect on their session rather
# than a fix for ours.
dev_shell_git() {
  (
    unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR \
      GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES
    git "$@"
  )
}

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
    head="$(dev_shell_git -C "$dir" rev-parse HEAD 2>/dev/null)" || head=unborn
    status="$(dev_shell_git -C "$dir" status --porcelain 2>/dev/null |
      _dev_shell_digest)"
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

# ---------------------------------------------------------------------------
# Loader injection: one glibc per dev-shell subprocess
# ---------------------------------------------------------------------------
#
# The dev shell does not only hand its subprocesses a PATH. It hands them
# LOADER STATE, and loader state is process-global: it applies to every binary
# started from the shell, including binaries the shell did not build and does
# not own.
#
# There are two such channels in this repository and they are independent:
#
#   A. `LD_LIBRARY_PATH`, set in `flake.nix`'s devShell so that Nim's
#      `{.dynlib.}` bindings can `dlopen` clingo / zstd / OpenSSL / pcre by
#      bare soname (the `.rodata`-bake guard in `config.nims` deliberately
#      keeps those paths out of the binaries). It is consulted BEFORE any
#      DT_RUNPATH, so a shell library shadows the copy a foreign binary was
#      linked against.
#
#   B. `LD_PRELOAD` of `build/lib/librepro_monitor_shim.so`, which automatic
#      monitoring injects into every process a build action starts. The shim is
#      a DSO with its own DT_RUNPATH, so its `libm`/`librt`/`libdl`/`libpthread`
#      come from the shell's glibc regardless of what the program being
#      monitored links against.
#
# Both channels can put a SECOND glibc into a process whose `libc.so.6` is the
# first one, and glibc's satellite libraries carry symbol-version requirements
# that an older `libc.so.6` cannot satisfy. That is not a theory. On the host
# that motivated this check, `git` came from the developer's ambient
# `~/.nix-profile` (glibc-2.40-66) while the shell's libraries came from the
# flake's nixpkgs (glibc-2.42-61), and BOTH channels were fatal:
#
#   channel A:  git-remote-https: .../glibc-2.40-66/lib/libc.so.6: version
#               `GLIBC_ABI_DT_X86_64_PLT' not found (required by
#               .../glibc-2.42-61/lib/libdl.so.2)
#               fatal: remote helper 'https' aborted session
#
#   channel B:  git: .../glibc-2.40-66/lib/libc.so.6: version
#               `GLIBC_ABI_DT_X86_64_PLT' not found (required by
#               .../glibc-2.42-61/lib/libm.so.6)
#
# so no fetch, clone or push over https worked in the shell, and no git-using
# test could run under `repro build '.#test#<name>'` — the loop for iterating
# on one test at a time.
#
# WHY THIS IS A VERSION COMPARISON AND NOT A STORE-PATH COMPARISON. "Two
# different glibc store paths" is the wrong predicate: it is both too weak and
# too strong. Measured on the same host, the system's `ssh`, `perl` and `rsync`
# run on glibc-2.40-224 — a different store path, a different build, and
# perfectly fine under both channels, because that build DEFINES
# `GLIBC_ABI_DT_X86_64_PLT` even though its version number is older. The thing
# that actually decides the outcome is whether the host `libc.so.6` defines
# every symbol version the injected glibc's satellite libraries require, so
# that is what is compared. A check keyed on store paths would have shouted
# about three healthy tools and taught everyone to ignore it.
#
# SCOPE: the programs reprobuild itself spawns to reach a remote — `git` and
# the `git-remote-*` helpers it execs. `ssh` is deliberately NOT in the list:
# every remote this workspace declares is `https://`, git's ssh transport is
# not on reprobuild's path to them, and the system `ssh` measured here
# satisfies both channels anyway. If that ever changes the remedy is the same
# one this check prescribes for `git` — have the dev shell provide the tool
# instead of inheriting it — so add `ssh` here and `pkgs.openssh` to the
# devShell's `packages` together.

# The programs the dev shell must be able to hand its own loader state to.
DEV_SHELL_SUBPROCESS_TOOLS=(
  git
)

# glibc satellite libraries: the ones that are separate `.so` files carrying
# their own `libc.so.6` version requirements. These are what get dragged into a
# foreign process; `libc.so.6` itself is already loaded (it is the process's
# PT_INTERP) and is never re-resolved through either channel.
DEV_SHELL_GLIBC_SATELLITES=(
  libm.so.6
  librt.so.1
  libdl.so.2
  libpthread.so.0
  libanl.so.1
  libresolv.so.2
  libutil.so.1
  libnsl.so.1
  libcrypt.so.1
)

# The `/nix/store/<hash>-glibc-<version>` prefixes mentioned by a string.
_dev_shell_glibc_prefixes() {
  grep -oE '/nix/store/[a-z0-9]{32}-glibc-[0-9][^/[:space:]:]*' <<<"${1:-}" |
    sort -u
}

# The glibc an executable will actually run on: the store path of its
# PT_INTERP. Prints nothing when the file is not an ELF with a nix-store
# interpreter (a script, a static binary, a non-nix host).
dev_shell_elf_glibc() {
  local file="$1" interp
  [[ -f "$file" ]] || return 0
  interp="$(patchelf --print-interpreter "$file" 2>/dev/null)" || return 0
  _dev_shell_glibc_prefixes "$interp"
}

# The glibc(s) a library directory would drag in: the store paths its shared
# objects name in their own RPATH/RUNPATH.
dev_shell_libdir_glibc() {
  local dir="$1" file rpath
  [[ -d "$dir" ]] || return 0
  for file in "$dir"/*.so "$dir"/*.so.*; do
    [[ -f "$file" ]] || continue
    rpath="$(patchelf --print-rpath "$file" 2>/dev/null)" || continue
    _dev_shell_glibc_prefixes "$rpath"
  done | sort -u
}

# The symbol versions a glibc's `libc.so.6` DEFINES.
#
# Read out of `.gnu.version_d` only. `readelf -V` prints the version NEEDS
# section in the same output and with the same `Name:` key, and libc.so.6 has
# one (it needs `GLIBC_PRIVATE` from `ld-linux`), so an unrestricted grep would
# report a version as defined because something else requires it. The section
# heading is matched on its stem — binutils writes "Version definition section"
# and has written "Version definitions section"; a pattern that assumed either
# spelling parses to the EMPTY SET against the other, and an empty defined-set
# reads exactly like "this libc defines nothing", i.e. a conflict against every
# injected glibc. Hence also the non-zero return below: a caller must be able
# to tell "nothing defined" from "nothing parsed".
dev_shell_glibc_defined_versions() {
  local prefix="$1" libc="$1/lib/libc.so.6" out
  [[ -f "$libc" ]] || return 0
  out="$(readelf -V "$libc" 2>/dev/null |
    sed -n "/Version definition/,/^\$/p" |
    grep -oE 'Name: GLIBC_[A-Za-z0-9_.]+' |
    sed 's/^Name: //' | sort -u)"
  [[ -n "$out" ]] || return 2
  printf '%s\n' "$out"
}

# The symbol versions a glibc's satellite libraries REQUIRE FROM `libc.so.6`.
#
# `.gnu.version_r` groups its entries under a `File:` line, so the file each
# requirement is against has to be tracked while scanning; a flat grep would
# attribute a requirement on `ld-linux-x86-64.so.2` to `libc.so.6`.
dev_shell_glibc_required_versions() {
  local prefix="$1" soname file
  for soname in "${DEV_SHELL_GLIBC_SATELLITES[@]}"; do
    file="$prefix/lib/$soname"
    [[ -f "$file" ]] || continue
    readelf -V "$file" 2>/dev/null |
      sed -n "/Version need/,/^\$/p" |
      awk '
        /File: / {
          current = ""
          if (match($0, /File: [^ ]+/)) {
            current = substr($0, RSTART + 6, RLENGTH - 6)
          }
          next
        }
        current == "libc.so.6" && match($0, /Name: GLIBC_[A-Za-z0-9_.]+/) {
          print substr($0, RSTART + 6, RLENGTH - 6)
        }
      '
  done | sort -u
}

# Every glibc the dev shell can inject into a subprocess, one `channel<TAB>
# origin<TAB>glibc-prefix` row per finding.
#
# `origin` is the concrete thing that carries it — a directory off
# `LD_LIBRARY_PATH`, or the monitor shim — so a report can name what to change
# rather than only what is wrong.
dev_shell_injected_glibcs() {
  local repo_root="${1:-.}" dir glibc shim
  local -a dirs=()
  if [[ -n "${LD_LIBRARY_PATH:-}" ]]; then
    IFS=: read -r -a dirs <<<"$LD_LIBRARY_PATH"
  fi
  for dir in ${dirs[@]+"${dirs[@]}"}; do
    [[ -n "$dir" ]] || continue
    while read -r glibc; do
      [[ -n "$glibc" ]] || continue
      printf 'LD_LIBRARY_PATH\t%s\t%s\n' "$dir" "$glibc"
    done < <(dev_shell_libdir_glibc "$dir")
  done
  shim="$repo_root/build/lib/librepro_monitor_shim.so"
  if [[ -f "$shim" ]]; then
    while read -r glibc; do
      [[ -n "$glibc" ]] || continue
      printf 'LD_PRELOAD\t%s\t%s\n' "$shim" "$glibc"
    done < <(_dev_shell_glibc_prefixes \
      "$(patchelf --print-rpath "$shim" 2>/dev/null)")
  fi
}

# The programs in `DEV_SHELL_SUBPROCESS_TOOLS`, resolved on PATH, plus the
# helpers `git` execs for a remote — `git-remote-https` is the binary that
# actually died on this host, and it lives in `git --exec-path`, not on PATH.
dev_shell_subprocess_tool_binaries() {
  local tool path exec_path helper
  for tool in "${DEV_SHELL_SUBPROCESS_TOOLS[@]}"; do
    path="$(command -v "$tool" 2>/dev/null)" || continue
    [[ -n "$path" ]] || continue
    path="$(readlink -f "$path" 2>/dev/null || printf '%s' "$path")"
    printf '%s\t%s\n' "$tool" "$path"
    if [[ "$tool" == "git" ]]; then
      exec_path="$("$path" --exec-path 2>/dev/null)" || exec_path=""
      for helper in git-remote-https git-remote-http; do
        if [[ -n "$exec_path" && -f "$exec_path/$helper" ]]; then
          printf '%s\t%s\n' "$helper" "$exec_path/$helper"
        fi
      done
    fi
  done
}

# The check itself. Prints one row per finding, tab-separated, with the first
# field naming the KIND so the caller can report each with its own remedy:
#
#   conflict<TAB>tool<TAB>binary<TAB>host-glibc<TAB>channel<TAB>origin<TAB>injected-glibc<TAB>missing-versions
#   unreadable<TAB>glibc-prefix<TAB>which
#
# Returns 1 when there is at least one row of either kind. `unreadable` is a
# finding and not a silent skip on purpose: every comparison here is "the host
# libc does not define X", so a libc whose version table could not be read
# would otherwise present as a libc that defines NOTHING — a conflict against
# every injected glibc, with a missing-list naming every version there is. That
# is what a wrong `readelf` section heading produced while this was being
# written, and it is indistinguishable from a real finding to anyone reading
# the output.
dev_shell_loader_glibc_conflicts() {
  local repo_root="${1:-.}"
  local -a injected=()
  mapfile -t injected < <(dev_shell_injected_glibcs "$repo_root")
  [[ ${#injected[@]} -gt 0 ]] || return 0

  local tool binary host channel origin glibc missing row found=0 rc
  local -A defined_cache=() required_cache=() unreadable=()
  while IFS=$'\t' read -r tool binary; do
    [[ -n "$binary" ]] || continue
    host="$(dev_shell_elf_glibc "$binary")"
    # No nix-store interpreter: a script, a static binary, or a non-nix host.
    # Nothing here can say anything about it, and saying nothing is the
    # honest answer rather than a pass or a fail.
    [[ -n "$host" ]] || continue
    if [[ -z "${defined_cache[$host]+set}" ]]; then
      rc=0
      defined_cache["$host"]="$(dev_shell_glibc_defined_versions "$host")" ||
        rc=$?
      if [[ "$rc" -ne 0 ]]; then
        if [[ -z "${unreadable[$host]+set}" ]]; then
          unreadable["$host"]=1
          printf 'unreadable\t%s\t%s\n' "$host" \
            'defined versions of lib/libc.so.6'
          found=1
        fi
        continue
      fi
    elif [[ -n "${unreadable[$host]+set}" ]]; then
      continue
    fi
    for row in "${injected[@]}"; do
      IFS=$'\t' read -r channel origin glibc <<<"$row"
      [[ -n "$glibc" ]] || continue
      [[ "$glibc" != "$host" ]] || continue
      if [[ -z "${required_cache[$glibc]+set}" ]]; then
        required_cache["$glibc"]="$(dev_shell_glibc_required_versions "$glibc")"
      fi
      missing="$(comm -23 \
        <(printf '%s\n' "${required_cache[$glibc]}" | grep -v '^$' | sort -u) \
        <(printf '%s\n' "${defined_cache[$host]}" | grep -v '^$' | sort -u) |
        paste -sd, -)"
      [[ -n "$missing" ]] || continue
      printf 'conflict\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$tool" "$binary" "$host" "$channel" "$origin" "$glibc" "$missing"
      found=1
    done
  done < <(dev_shell_subprocess_tool_binaries)
  return $((found == 0 ? 0 : 1))
}
