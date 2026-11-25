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

# Root input names, including pure follows and non-repository URLs. Unlike
# dev_shell_flake_declares_input (the sibling-exception check), provenance
# filtering must retain every declared input, not just repository inputs.
# Callers only infer absence after the independent URL count validates the
# structural parse; an unrecognized flake shape must not erase provenance.
dev_shell_flake_input_names() {
  local flake="$1"
  awk '
    /^  inputs = \{/ { inputs = 1; next }
    inputs && /^  \};/ { inputs = 0 }
    !inputs { next }
    {
      line = $0; sub(/^[[:space:]]+/, "", line)
      if (line ~ /^[A-Za-z0-9_-]+([.]|[[:space:]]*=)/) {
        name = line; sub(/[.[:space:]=].*$/, "", name); print name
      } else if (line ~ /^"[^"]+"([.]|[[:space:]]*=)/) {
        name = line; sub(/^"/, "", name); sub(/".*$/, "", name); print name
      } else if (line !~ /^#/ && line ~ /=/) {
        # An unsupported declaration is not proof that its input is absent.
        print "# incomplete input-name parse"
      }
    }
  ' "$flake" | sort -u
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
# would copy change. A sibling override copies the working tree, not just the
# commit, so the commit alone is not enough — an uncommitted edit is just as
# much a different input.
#
# `HEAD` plus a digest of `git status --porcelain` is exactly the right measure
# for a sibling taken as a git tree, because that is the same set of files nix
# enumerates: tracked content, at its working-tree bytes.
#
# This used to carry a known limit — files excluded by `.gitignore` were copied
# by a `path:` override but do not appear in `git status`, so an edit confined
# to one of those went undetected. That residue is gone rather than merely
# tolerated: a git tree does not copy ignored files at all, so not watching
# them is now precisely correct instead of a gap. `git status --porcelain` does
# list untracked files, which a git tree does NOT copy — so the fingerprint can
# now move when the built input did not. That direction is the safe one: it
# rebuilds a shell that was already correct, where the old residue served a
# stale one.
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
# `input<TAB>dir` lines for the LOCAL-DIRECTORY overrides — the only ones whose
# source is a working tree this machine can change behind the cache's back.
#
# Two spellings name a local directory, and BOTH must be recognised:
#
#   path:/abs/dir                     a plain directory copy
#   git+file:///abs/dir[?query]       the same directory taken as a git tree
#
# Matching only `path:` was safe while that was the only spelling emitted. It
# stopped being safe the moment `repro flake override-args` began naming git
# checkouts as git trees: this function would have matched nothing, the
# fingerprint would have been EMPTY, and an empty fingerprint does not fail —
# it reports "no overrides configured" and never invalidates again. That is the
# fifteen-day-stale RUNQUOTA_SRC failure this whole file exists to prevent,
# reintroduced by the fix for a different one.
dev_shell_override_path_pairs_from_args() {
  local args
  args="$(cat)"
  local words=()
  eval "words=( $args )"
  local i=0
  # Both `--override-input` and `--override-flake` are exactly three words,
  # so a stride of three lands on every flag and never mid-triple.
  while (( i + 2 < ${#words[@]} )); do
    if [[ "${words[i]:-}" == "--override-input" ]]; then
      local ref="${words[i + 2]:-}" dir=""
      case "$ref" in
        path:*)
          dir="${ref#path:}"
          ;;
        git+file://*)
          dir="${ref#git+file://}"
          # Drop any `?submodules=1` — the fingerprint is about the working
          # tree at that path, not about how nix was asked to read it.
          dir="${dir%%\?*}"
          ;;
      esac
      if [[ -n "$dir" ]]; then
        printf '%s\t%s\n' "${words[i + 1]}" "$dir"
      fi
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
  [[ -r "$path" ]] || return 0
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
# The OTHER side of the comparison: what flake.lock pins
# ---------------------------------------------------------------------------
#
# Everything above compares the cached shell against THE OVERRIDE SOURCES — the
# sibling working trees. Both sides of that comparison are the same local
# checkout, which is why it is structurally unable to answer the one question
# that keeps costing whole days: is the checkout the shell is built from BEHIND
# the revision `flake.lock` pins for that input? A sibling that is behind its
# pin compiles against sources that lack the symbols its consumers were written
# for, and the resulting error names neither the sibling nor the pin — it names
# whatever module the compiler happened to reach first, including modules of
# the standard library.
#
# So this section supplies the second, INDEPENDENT side: the committed lock.
#
# WHY A PARSER HERE AND NOT `repro flake override-status`. That verb computes
# the same relation and computes it well, and `.envrc` already calls it at
# shell entry (see `dev_shell_report_override_drift`). It is the wrong tool for
# a LINT GATE for three reasons, each of which has a scar behind it:
#
#   * it needs `repro`, and this gate is run by the pre-commit hook on a PATH
#     built in `flake.nix` that deliberately carries no compiled artifact of
#     this repository — the gate's own tool contract (check 0) is coreutils,
#     awk, sed and git;
#   * it needs the APPLIED override vector, which exists only inside an
#     activated dev shell. `just lint` is routinely run from a git hook, where
#     there is no plugin and no vector;
#   * it reports, and is required never to be fatal. A warning is what this
#     already was. The warning was printed, in a shell-entry banner alongside
#     others, and the stale sibling still reached a compiler five times.
#
# The lock is a committed text file and the question is two `git rev-list`
# calls, so the gate asks it itself and FAILS on the answer.

# Print `input<TAB>rev` for every input of the lock's ROOT node, where `rev` is
# the revision that input's node is locked to, `follows` when the root entry
# is a `follows` path (an array, not a node name), or `-` when it names a node
# with no `locked.rev` at all (a `path:`/`file:` input).
#
# `follows` and `-` rows are emitted rather than dropped for the same reason
# `dev_shell_flake_input_repos` emits them: "this input carries no pin" and
# "this input is not in the file" are different answers and the caller treats
# them differently. Dropping the first would turn it into the second. The two
# no-pin answers are kept apart because only the first is a positive reading
# of the lock: a `follows` is recognised by its shape, while `-` is also what
# a node whose `locked` block stopped parsing would produce.
#
# nix writes `flake.lock` as deterministically indented JSON — two spaces per
# level, one key per line — so the nesting depth of a line identifies what it
# is. The parser keys on that, and the caller is required to refuse an empty
# result rather than read it as "no pins to disagree with".
dev_shell_flake_lock_pins() {
  local lock="$1"
  [[ -f "$lock" ]] || return 0
  awk '
    # A top-level node header: `    "<key>": {`
    /^    "[^"]+": \{$/ {
      node = $0; sub(/^    "/, "", node); sub(/": \{$/, "", node)
      innode = 1; inlocked = 0; inrootinputs = 0; infollows = 0
      inroot = (node == "root") ? 1 : 0
      next
    }
    /^    \},?$/ {
      innode = 0; inroot = 0; inlocked = 0; inrootinputs = 0; infollows = 0
      next
    }

    # The root node`s input map: `<input name>` -> `<node key>`.
    inroot && /^      "inputs": \{$/ { inrootinputs = 1; next }
    inrootinputs && /^      \},?$/ { inrootinputs = 0; next }
    infollows && /^        \],?$/ { infollows = 0; next }
    infollows { next }
    inrootinputs && /^        "[^"]+": "[^"]+",?$/ {
      n = $0; sub(/^        "/, "", n); sub(/": ".*/, "", n)
      v = $0; sub(/^        "[^"]*": "/, "", v); sub(/",?$/, "", v)
      rootnode[n] = v; order[++cnt] = n; next
    }
    # An array value is a `follows` path, which routes to another input and
    # carries no revision of its own.
    inrootinputs && /^        "[^"]+": \[$/ {
      n = $0; sub(/^        "/, "", n); sub(/": \[$/, "", n)
      isfollows[n] = 1; order[++cnt] = n; infollows = 1; next
    }

    # Every other node`s `locked.rev`. `original.rev` is deliberately NOT read:
    # it is what was ASKED for, and the question here is what was resolved.
    innode && !inroot && /^      "locked": \{$/ { inlocked = 1; next }
    inlocked && /^      \},?$/ { inlocked = 0; next }
    inlocked && /^        "rev": "[0-9a-fA-F]+",?$/ {
      r = $0; sub(/^        "rev": "/, "", r); sub(/",?$/, "", r)
      noderev[node] = r; next
    }

    END {
      for (i = 1; i <= cnt; i++) {
        n = order[i]; k = rootnode[n]
        if (n in isfollows) printf "%s\tfollows\n", n
        else if (!(k in noderev)) printf "%s\t-\n", n
        else printf "%s\t%s\n", n, noderev[k]
      }
    }
  ' "$lock"
}

# Classify one checkout against one pin. Prints
# `relation<TAB>ahead<TAB>behind<TAB>detail` on one line, where `relation` is
#
#   at         the revision the shell was built from IS the pinned one
#   ahead      the checkout contains the pin and more — ordinary development
#   behind     THE PIN CONTAINS COMMITS THE CHECKOUT DOES NOT
#   diverged   each contains commits the other does not; the behind half of
#              that is the same deficiency as `behind`
#   unfetched  one of the two revisions is not an object in this repository
#   unknown    both objects are there and `rev-list` still could not answer
#
# The names and the directions match `repro flake override-status`, which
# decides the same relation in Nim (`flakeClassifyPin`), so an operator who has
# seen one reading has seen the other. The two implementations are deliberately
# independent — this one must answer with nothing compiled — and where they are
# compared they must agree.
#
# `unknown` is kept apart from `unfetched` because it is the shape a CORRUPT
# object database presents: a commit that the commit-graph knows and the object
# store does not. `git log`, `git cat-file -e` and a history search all answer
# from the graph and report confidently; only a walk that must read the objects
# fails. A gate that folded that into "fine" would certify a repository that
# cannot be read.
dev_shell_pin_relation() {
  local dir="$1" pin="$2" head="$3"
  if [[ ! -d "$dir" ]]; then
    printf 'unknown\t0\t0\t%s\n' "$dir is not on disk"
    return 0
  fi
  if [[ "$pin" == "$head" ]]; then
    printf 'at\t0\t0\t\n'
    return 0
  fi
  local absent=()
  dev_shell_git -C "$dir" cat-file -e "$pin^{commit}" 2>/dev/null ||
    absent+=("the pinned revision $pin")
  dev_shell_git -C "$dir" cat-file -e "$head^{commit}" 2>/dev/null ||
    absent+=("the recorded revision $head")
  if [[ ${#absent[@]} -gt 0 ]]; then
    printf 'unfetched\t0\t0\t%s\n' \
      "$(printf '%s and ' "${absent[@]}" | sed 's/ and $//') is not an object in $dir"
    return 0
  fi
  local ahead behind err
  err=""
  ahead="$(dev_shell_git -C "$dir" rev-list --count "$pin..$head" 2>&1)" ||
    err="$ahead"
  if [[ -z "$err" ]]; then
    behind="$(dev_shell_git -C "$dir" rev-list --count "$head..$pin" 2>&1)" ||
      err="$behind"
  fi
  if [[ -n "$err" ]]; then
    printf 'unknown\t0\t0\t%s\n' \
      "git rev-list in $dir failed: $(printf '%s' "$err" | tr '\n' ' ')"
    return 0
  fi
  if [[ "$behind" -gt 0 && "$ahead" -gt 0 ]]; then
    printf 'diverged\t%s\t%s\t\n' "$ahead" "$behind"
  elif [[ "$behind" -gt 0 ]]; then
    printf 'behind\t0\t%s\t\n' "$behind"
  elif [[ "$ahead" -gt 0 ]]; then
    printf 'ahead\t%s\t0\t\n' "$ahead"
  else
    # Distinct revisions, neither reachable from the other and both counts
    # zero: `rev-list` cannot produce this, so reaching it means the two
    # queries did not describe the revisions asked about.
    printf 'unknown\t0\t0\t%s\n' \
      "$pin and $head differ but rev-list reports no distance in either direction"
  fi
}

# Succeed when revision `$2` of the repository at `$1` has a regular file
# named `flake.nix` at the root of its tree. The answer comes from the tree
# entry (`ls-tree` prints `<mode> <type> <oid><TAB><path>`), so it needs the
# commit and its root tree but not the blob, which a partial clone may lack
# (see dev_shell_unflakeable_pin_state).
dev_shell_tree_has_flake_nix() {
  local dir="$1" rev="$2" entry
  entry="$(dev_shell_git -C "$dir" ls-tree "$rev" -- flake.nix 2>/dev/null)" ||
    return 1
  [[ "$entry" == *" blob "*$'\t'"flake.nix" ]]
}

# Explain an `unflakeable` finding: the sibling directory has no `flake.nix`,
# but WHY? Two very different repositories present identically on disk:
#
#   * one that has no `flake.nix` at all — the plugin can never override it,
#     and the remedy is to add one or to declare the pin;
#   * one whose `flake.nix` exists at the revision `flake.lock` pins, while
#     the checkout simply predates the commit that added it. Adding a
#     `flake.nix` there would duplicate a file the repository already has, and
#     declaring the pin would excuse a stale checkout. The remedy is to bring
#     the checkout up to its pin.
#
# The second case used to be reported as the first: a `nim-shm-queue`
# checkout seven commits behind its pin `8dff4ad` failed the pre-commit
# `just lint` with "add a flake.nix to that repository", and neither remedy it
# named was right.
#
# Prints `state<TAB>pin<TAB>behind` on one line, where `state` is
#
#   no-pin       flake.lock gives no revision for the input (no lock, a
#                `follows`, a `path:` input, or the input is not in the lock),
#                so the pin cannot be consulted — report the finding as before
#   not-git      the sibling is not a git checkout whose HEAD can be read
#   unfetched    the pinned revision is not an object in the sibling, so
#                whether it has a `flake.nix` cannot be told offline
#   pin-unflaked the pinned revision has no `flake.nix` either: the repository
#                genuinely is not a flake at its pin
#   behind       the pin has a `flake.nix` and HEAD is an ancestor of the pin:
#                fast-forwarding to the pin is the whole remedy
#   diverged     the pin has a `flake.nix` and HEAD is NOT an ancestor of it:
#                the checkout carries its own commits and lacks the pin's
#   worktree-deleted  HEAD's own tree has a `flake.nix`; only the working tree
#                lacks it
#   removed-since-pin HEAD contains the pin, so a commit after the pin removed
#                the `flake.nix` the pin has
#
# `behind` carries the number of pin commits HEAD lacks (0 for other states).
#
# It reads the committed lock and the sibling's object database. Whether a
# revision has a `flake.nix` is answered from its TREE (`ls-tree`), never by
# reading the blob: workspace checkouts are partial clones (`blob:none`) of a
# promisor pool, so the pin's `flake.nix` blob is routinely absent locally.
# `cat-file -e <rev>:flake.nix` on such a checkout lazy-fetches the blob, and
# with the pool unreachable it fails — which would classify the pin as
# `pin-unflaked` and print "add a flake.nix", the very misreport this function
# exists to prevent. Commit presence is tested with `cat-file -e`, as in
# `dev_shell_pin_relation`; in a promisor checkout git may lazily fetch a
# missing commit to answer that, exactly as it does there.
dev_shell_unflakeable_pin_state() {
  local lock="$1" input="$2" sibling="$3"
  local pin="" l_input l_rev
  if [[ -f "$lock" ]]; then
    while IFS=$'\t' read -r l_input l_rev; do
      [[ "$l_input" == "$input" ]] || continue
      pin="$l_rev"
      break
    done < <(dev_shell_flake_lock_pins "$lock")
  fi
  if [[ -z "$pin" || "$pin" == "-" || "$pin" == "follows" ]]; then
    printf 'no-pin\t-\t0\n'
    return 0
  fi
  local head
  if [[ ! -e "$sibling/.git" ]] ||
    ! head="$(dev_shell_git -C "$sibling" rev-parse --verify -q 'HEAD^{commit}' 2>/dev/null)"; then
    printf 'not-git\t%s\t0\n' "$pin"
    return 0
  fi
  if ! dev_shell_git -C "$sibling" cat-file -e "$pin^{commit}" 2>/dev/null; then
    printf 'unfetched\t%s\t0\n' "$pin"
    return 0
  fi
  # Only the root of the tree counts: a flake.nix the repository keeps in a
  # subdirectory is not one the plugin would read either.
  if ! dev_shell_tree_has_flake_nix "$sibling" "$pin"; then
    printf 'pin-unflaked\t%s\t0\n' "$pin"
    return 0
  fi
  # The pin has one. Before blaming the checkout's distance from the pin, rule
  # out the two shapes where distance is not the cause: HEAD's own tree has a
  # flake.nix (so it was deleted in the working tree), or HEAD already contains
  # the pin (so the checkout's own commits removed it). "Fast-forward to the
  # pin" would be wrong for both.
  if dev_shell_tree_has_flake_nix "$sibling" "$head"; then
    printf 'worktree-deleted\t%s\t0\n' "$pin"
    return 0
  fi
  local behind
  behind="$(dev_shell_git -C "$sibling" rev-list --count "$head..$pin" 2>/dev/null)" ||
    behind=""
  if [[ "$behind" == "0" ]]; then
    printf 'removed-since-pin\t%s\t0\n' "$pin"
    return 0
  fi
  [[ -n "$behind" ]] || behind=0
  if dev_shell_git -C "$sibling" merge-base --is-ancestor "$head" "$pin" 2>/dev/null; then
    printf 'behind\t%s\t%s\n' "$pin" "$behind"
  else
    printf 'diverged\t%s\t%s\n' "$pin" "$behind"
  fi
}

# ---------------------------------------------------------------------------
# The §3.2 ambient drift report, at shell entry
# ---------------------------------------------------------------------------
#
# Nix-Flake-Coexistence.md §3.2 makes this a rule rather than a nicety:
#
#   > A behind-pin sibling is reported **ambiently, at shell entry**, naming
#   > the sibling, the distance, and the command that reconciles it. It is not
#   > an error: deliberately testing an older dependency is legitimate. It must
#   > not be silent: unknowingly testing one is how a green shell certifies
#   > nothing.
#
# The report itself has existed since NF-3 and is correct. What has been
# missing is a route to it that shell entry can afford: the only one was
# `repro flake override-args`, whose cost is dominated by
# `repro develop --list --all` at ~226 s on this workspace, and NF-3's LANDED
# notes record that cost as the blocker on migrating this repository's `.envrc`
# off the direnv plugin. So the warning the spec requires has never actually
# reached a developer here, and the four failures it would have named arrived
# instead as Nim compile errors about undeclared identifiers — `KillEvidence`,
# `EvidenceScope` — in repos that had nothing to do with the stale checkout.
#
# `--applied` closes that gap without re-opening the one NF-3 closed. It does
# not DERIVE the override set a second way (the derivation that disagreed with
# the exact answer in both directions, and made the pre-push gate fail open);
# it is handed the vector this shell is about to splice into `use flake` and
# reads the substitutions out of it. Whatever produced that vector — the plugin
# today, `repro flake override-args` after the migration — is the thing being
# reported on, so the report cannot describe a different shell than the one
# being entered.
#
# NEVER FATAL. The overrides are correct and the shell is usable whatever this
# says; a dev shell that refused to activate because `flake.lock` was
# unreadable would stop work over something the shell does not depend on.
# Absence of `repro` is likewise not an error: a fresh clone has no `repro`
# yet, and that is exactly when nothing has drifted either.
#
# WHEN IT RUNS is the other half, and it is already right for free. direnv
# re-evaluates `.envrc` when a watched file moves; `flake.lock` is watched (see
# `.envrc`), and so is the override fingerprint, which moves precisely when an
# overridden source does. Those are the only two ways this drift can arise, so
# the report fires on exactly the events that can create it and stays silent
# on every other directory entry.
#
# AND IT PROBES, for the same reason `dev_shell_guard_override_knobs` probes.
# `repro` on `PATH` at shell entry is whatever the machine happens to have —
# typically an installed build, not the one this checkout produces — and a copy
# predating `--applied` does not reject the flag. It routes every unrecognised
# word into `repro develop`'s selector composer, so the exact invocation below
# would make an old binary resolve the whole develop set (~226 s) on every
# directory entry and then report on a set nobody asked about. Refusing to ask
# a version question and MAKING THE BINARY PERFORM the behaviour instead is the
# same discipline the knob guard applies to the direnv plugin, and for the same
# reason: a binary that renames its internals still passes, and one that does
# not implement the flag still fails.
#
# The probe is the contradiction refusal, which only a binary that KNOWS
# `--applied` can produce: `--applied` together with a develop selector exits 2
# before git is resolved or any flake is read. `--flake` names a directory with
# no flake in it so that a binary WITHOUT the flag takes its
# "no flake.nix + flake.lock pair" early return and exits 0 in milliseconds,
# rather than resolving a develop set to answer a probe.
_dev_shell_applied_report_supported() {
  local probe out code
  probe="$(mktemp -d "${TMPDIR:-/tmp}/repro-applied-probe.XXXXXX")" || return 1
  out="$(repro flake override-status --applied --only=__probe__ \
    --flake="$probe" 2>&1)"
  code=$?
  rm -rf "$probe"
  [[ "$code" -eq 2 && "$out" == *"contradictory"* ]]
}

dev_shell_report_override_drift() {
  local args="$1"
  command -v repro >/dev/null 2>&1 || return 0
  if ! _dev_shell_applied_report_supported; then
    # LOUD, once, and not fatal. Silence here would be the inert knob exactly:
    # `.envrc` would say it reports drift while reporting none, which is the
    # shape of every failure this file exists to prevent.
    printf '%s\n' \
      "dev shell: the \`repro\` on PATH ($(command -v repro)) predates" \
      "  \`repro flake override-status --applied\`, so NO drift report can be" \
      "  produced for this shell. That is NOT the same answer as 'nothing has" \
      "  drifted': a sibling behind its flake.lock pin will be silent again," \
      "  and will next be visible as a compiler error naming a symbol." \
      "  Remedy: install a current repro (\`just build\` in this checkout puts" \
      "  one at ./build/bin/repro), or put that build earlier on PATH." >&2
    return 0
  fi
  local words=()
  eval "words=( ${args} )"
  # `${words[@]+…}` rather than a bare `"${words[@]}"`: an EMPTY array under
  # `set -u` is an unbound-variable error on bash before 4.4, and an empty
  # override vector is an ordinary state (a clone with no siblings beside it),
  # not a reason to break shell activation on an older bash.
  #
  # `|| true` deliberately, and belt-and-braces with the caller: this function
  # is sourced into `.envrc`, where direnv runs under `set -e`, and a report
  # that ended shell activation would be a far larger harm than the drift it
  # reports.
  repro flake override-status --applied -- ${words[@]+"${words[@]}"} || true
  return 0
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
# SCOPE: the programs reprobuild itself spawns — `git` and the `git-remote-*`
# helpers it execs to reach a remote, and `ssh-keygen`, which signs and
# verifies test certificates and mints the certificate signer's keys. A host
# `ssh-keygen` links `libcrypto.so.3`, which `LD_LIBRARY_PATH` resolves to the
# shell's OpenSSL: on an Ubuntu runner (glibc 2.35) `/usr/bin/ssh-keygen` died
# with "version `GLIBC_2.38' not found (required by .../libcrypto.so.3)" and
# no certificate could be signed. That scope is the rule's, not the reach of
# the injection: every other program started in the shell gets the same
# `LD_LIBRARY_PATH`, and "host programs the rule does not cover", at the end
# of this file, is the warning that names the ones it breaks.
#
# `ssh` is deliberately NOT in the list: every remote this workspace declares
# is `https://`, and git's ssh transport is not on reprobuild's path to them.
# The system `ssh` measured when this was written satisfied both channels, but
# that host was NixOS; on a distribution host whose glibc is older than the
# shell's, `ssh` links libcrypto, loads the shell's copy and dies — which the
# host-program warning reports, because reprobuild does not run it. If
# reprobuild ever does, the remedy is the same one this check prescribes for
# `git` — have the dev shell provide the tool instead of inheriting it — so add
# `ssh` here and `pkgs.openssh` to the devShell's `packages` together.
#
# Plus one program the shell names by VARIABLE rather than on PATH:
# `$REPRO_SYSTEMD_ANALYZE`, which `just lint`'s CONF-3/CONF-4 checks run with
# this shell's `LD_LIBRARY_PATH`. The host's systemd-analyze died exactly this
# way under it (reprobuild-pm issue
# 2026-10-22-lint-confinement-check-runs-the-hosts-systemd-analyze); the
# flake's must not, and this check is what says so if it ever does.

# The programs the dev shell must be able to hand its own loader state to.
DEV_SHELL_SUBPROCESS_TOOLS=(
  git
  ssh-keygen
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

# The glibc an executable will actually run on. For a nix-store PT_INTERP it is
# that glibc's store path. For a host interpreter (`/lib64/ld-linux-x86-64.so.2`
# on Debian, Ubuntu or Fedora) it is the `libc.so.6` installed beside the
# interpreter the link resolves to, which is where those distributions keep the
# pair. Prints nothing when the file is not a dynamic ELF, or when no libc sits
# beside its interpreter (NixOS's `/lib64` stub loader), because nothing can be
# said about it then.
#
# The host arm is not optional. A runner that is not NixOS runs its own
# `/usr/bin` programs on its own glibc, and those are the programs a dev shell
# leaves on PATH when it does not provide them. Without this arm the check said
# nothing about them, and an Ubuntu runner's `ssh-keygen` loaded this shell's
# OpenSSL and died while `just lint` reported one glibc.
dev_shell_elf_glibc() {
  local file="$1" interp resolved libc
  [[ -f "$file" ]] || return 0
  interp="$(patchelf --print-interpreter "$file" 2>/dev/null)" || return 0
  [[ -n "$interp" ]] || return 0
  if [[ "$interp" == /nix/store/* ]]; then
    _dev_shell_glibc_prefixes "$interp"
    return 0
  fi
  resolved="$(readlink -f "$interp" 2>/dev/null)" || return 0
  [[ -n "$resolved" ]] || return 0
  libc="$(dirname "$resolved")/libc.so.6"
  [[ -f "$libc" ]] || return 0
  printf '%s\n' "$libc"
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
#
# The argument is a glibc store prefix, or a host `libc.so.6` itself as
# `dev_shell_elf_glibc` reports one for a program outside the nix store.
dev_shell_glibc_defined_versions() {
  if [[ -f "$1" ]]; then
    dev_shell_libc_defined_versions "$1"
  else
    dev_shell_libc_defined_versions "$1/lib/libc.so.6"
  fi
}

# The same table, for a `libc.so.6` named by its FILE rather than by a glibc
# store prefix. A host program on a distribution host runs on
# `/lib/x86_64-linux-gnu/libc.so.6`, which has no `/nix/store/<hash>-glibc-…`
# prefix to name, and the host-program scan below has to read it all the same.
dev_shell_libc_defined_versions() {
  local libc="$1" out
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
    dev_shell_elf_libc_requirements "$file"
  done | sort -u
}

# The symbol versions one ELF object requires FROM `libc.so.6`, one per line.
# The `.gnu.version_r` scan above, for a single file of any kind.
dev_shell_elf_libc_requirements() {
  readelf -V "$1" 2>/dev/null |
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
      # `GIT_EXEC_PATH` is cleared for this one question, and only this one.
      # The question is "where does THE BINARY WE JUST RESOLVED keep its
      # helpers", and `git --exec-path` answers with the environment's value
      # when there is one. Git exports it to every hook it runs, so from a
      # commit hook this paired a `git` taken from the dev shell with
      # `git-remote-https` taken from the CONTRIBUTOR'S git — two different
      # installations — and then reported the mismatch between them as though
      # this shell had caused it. The remedy it printed (have the dev shell
      # provide the program) could not clear it, because the shell already
      # provided the git that was checked; the helper came from somewhere the
      # repository does not control.
      #
      # Nothing is lost by clearing it. The dev shell's own git is still
      # checked as `git` above, which is the subject this whole check is about.
      exec_path="$( (unset GIT_EXEC_PATH; "$path" --exec-path) 2>/dev/null)" ||
        exec_path=""
      for helper in git-remote-https git-remote-http; do
        if [[ -n "$exec_path" && -f "$exec_path/$helper" ]]; then
          printf '%s\t%s\n' "$helper" "$exec_path/$helper"
        fi
      done
    fi
  done
  if [[ -n "${REPRO_SYSTEMD_ANALYZE:-}" && -x "$REPRO_SYSTEMD_ANALYZE" ]]; then
    printf '%s\t%s\n' systemd-analyze \
      "$(readlink -f "$REPRO_SYSTEMD_ANALYZE" 2>/dev/null || printf '%s' "$REPRO_SYSTEMD_ANALYZE")"
  fi
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
    # No interpreter whose libc can be located: a script, a static binary,
    # or a loader with no `libc.so.6` beside it (NixOS's stub loader, a musl
    # host). Nothing here can say anything about it, and saying nothing is
    # the honest answer rather than a pass or a fail.
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

# ---------------------------------------------------------------------------
# Loader injection, continued: host programs the rule does not cover
# ---------------------------------------------------------------------------
#
# THE SCOPE OF THE RULE ABOVE IS "PROGRAMS REPROBUILD ITSELF RUNS", and this
# section exists because channel A reaches further than that. `LD_LIBRARY_PATH`
# applies to EVERY program started in the shell, so a host program that links
# one of the sonames the shell injects (`libssl.so.3`, `libcrypto.so.3`,
# `libzstd.so.1`, `libpcre.so.1`, …) gets the shell's copy instead of its own,
# and with it the shell's glibc. On a host whose `libc.so.6` is older, that
# program dies before `main`. Measured on an Ubuntu 22.04 runner (glibc 2.35)
# against the flake's openssl, built on glibc 2.42:
#
#   /usr/bin/ssh-keygen: version `GLIBC_2.38' not found (required by
#   .../openssl-3.6.1/lib/libcrypto.so.3)
#
# The programs that fail this way on such a host include `ssh`, `scp`,
# `openssl`, `zstd` and `systemctl` (the last through `libsystemd-shared`,
# which links libcrypto and libzstd). The shell cannot PROVIDE every program a
# contributor might start, so for programs reprobuild does not run the rule is
# a warning, not a refusal: `scripts/check_dev_shell_env.sh` names each program
# on PATH that this shell breaks, the injected library that breaks it, and the
# remedy. A program that reprobuild (or a recipe `just` runs) DOES start is a
# different matter and belongs in `DEV_SHELL_SUBPROCESS_TOOLS` together with a
# dev-shell-provided copy, where check 6 refuses instead of warning.
#
# HOW A PROGRAM IS JUDGED, and why each step is there:
#
#   1. Which libc it runs on: the `libc.so.6` beside its resolved PT_INTERP.
#      That covers both a nix-store loader and a distribution's
#      `/lib64/ld-linux-x86-64.so.2` (a symlink into `/lib/x86_64-linux-gnu`),
#      which is the case the defect was found on. It is the resolution
#      `dev_shell_elf_glibc` makes for check 6's programs, applied to all of
#      PATH.
#   2. Whether ANY injected glibc requires a symbol version that libc lacks.
#      If none does, the program is fine whatever it links, and the expensive
#      step is skipped. This is the same version comparison check 6 makes, for
#      the reason given there (a store-path comparison is wrong both ways).
#   3. What the injection adds to the process. The loader's mapping of the
#      program's dependencies is simulated twice — with this shell's
#      `LD_LIBRARY_PATH` and without it — breadth-first, each soname loaded
#      once, as ld.so does it (see `_dev_shell_simulate_load` for the search
#      order). Every object only the injected run maps, and that needs a
#      symbol version the program's libc lacks, is a reason the program dies.
#      That is the object the loader names ("required by <object>"), often not
#      the injected library itself: `curl` died on the shell glibc's
#      `libdl.so.2`, which the injected libcrypto pulled in. Transitive,
#      because `systemctl` reaches libcrypto only through `libsystemd-shared`.
#
# Static, not behavioural: nothing on PATH is executed, not even its loader in
# trace mode, because this scan reads every executable on PATH and a lint gate
# must not start arbitrary programs to find out whether they would start.

# The sonames this shell injects through `LD_LIBRARY_PATH`, one `soname<TAB>
# library-dir<TAB>glibc-prefix` row each, in the order the loader would find
# them: the first directory that holds a soname wins, as it does for ld.so. The
# glibc is read from the RPATH of that library file itself, not of its
# directory, so a directory mixing builds is attributed correctly. A soname
# whose library names no store glibc carries no glibc into a process, and is
# not reported.
dev_shell_injected_sonames() {
  local dir file soname glibc
  local -a dirs=()
  local -A seen=()
  if [[ -n "${LD_LIBRARY_PATH:-}" ]]; then
    IFS=: read -r -a dirs <<<"$LD_LIBRARY_PATH"
  fi
  for dir in ${dirs[@]+"${dirs[@]}"}; do
    [[ -n "$dir" && -d "$dir" ]] || continue
    for file in "$dir"/*.so "$dir"/*.so.*; do
      [[ -f "$file" ]] || continue
      soname="$(basename "$file")"
      [[ -z "${seen[$soname]+set}" ]] || continue
      seen["$soname"]=1
      while read -r glibc; do
        [[ -n "$glibc" ]] || continue
        printf '%s\t%s\t%s\n' "$soname" "$dir" "$glibc"
      done < <(_dev_shell_glibc_prefixes \
        "$(patchelf --print-rpath "$file" 2>/dev/null)")
    done
  done
}

# Every executable regular file on PATH, once per resolved file, as
# `name<TAB>resolved-path`. The first PATH entry that provides a name wins, as
# it does for a shell looking the name up; a later entry of the same name is
# never what a contributor starts, so it is not judged.
#
# Builtins for the per-file work and ONE `readlink -f` for the lot: a dev
# shell's PATH holds well over a thousand files, and a fork per file made this
# enumeration alone take 45 s.
dev_shell_path_executables() {
  local dir file name i
  local -a dirs=() picked_names=() picked_files=() resolved=()
  local -A names=() files=()
  IFS=: read -r -a dirs <<<"${PATH:-}"
  for dir in ${dirs[@]+"${dirs[@]}"}; do
    [[ -n "$dir" && -d "$dir" ]] || continue
    for file in "$dir"/*; do
      name="${file##*/}"
      [[ -z "${names[$name]+set}" ]] || continue
      [[ -f "$file" && -x "$file" ]] || continue
      names["$name"]=1
      picked_names+=("$name")
      picked_files+=("$file")
    done
  done
  [[ ${#picked_files[@]} -gt 0 ]] || return 0
  mapfile -t resolved < <(printf '%s\0' "${picked_files[@]}" |
    xargs -0 readlink -f -- 2>/dev/null)
  # `readlink -f` prints nothing for a name it cannot resolve, which would
  # shift every later pairing by one; refuse the pairing rather than misname.
  if [[ ${#resolved[@]} -ne ${#picked_files[@]} ]]; then
    resolved=("${picked_files[@]}")
  fi
  for i in "${!picked_files[@]}"; do
    file="${resolved[$i]}"
    [[ -z "${files[$file]+set}" ]] || continue
    files["$file"]=1
    printf '%s\t%s\n' "${picked_names[$i]}" "$file"
  done
}

# `file<TAB>PT_INTERP` for every dynamic ELF among the files named on stdin
# (one per line), read by `readelf` in batches rather than a process per file.
# `readelf` heads its output with `File: <name>` only when it is given more
# than one file, so each batch starts with `/dev/null`, which readelf rejects
# on stderr and which guarantees the header for the files after it.
dev_shell_elf_interpreters() {
  tr '\n' '\0' |
    xargs -0 -n 256 readelf -lW /dev/null 2>/dev/null |
    awk '
      /^File: / { file = substr($0, 7); next }
      /\[Requesting program interpreter: / {
        interp = $0
        sub(/.*\[Requesting program interpreter: /, "", interp)
        sub(/\]$/, "", interp)
        if (file != "") print file "\t" interp
      }
    '
}

# The dynamic section of one ELF object, memoised in the caller's
# `_dsh_needed` / `_dsh_rpath` / `_dsh_runpath` (keyed by path) from ONE
# `readelf -d`: NEEDED entries in order, DT_RPATH and DT_RUNPATH kept apart,
# because the loader treats them differently (below).
_dev_shell_read_dynamic() {
  local obj="$1" line needed="" rpath="" runpath="" value
  [[ -z "${_dsh_needed[$obj]+set}" ]] || return 0
  while IFS= read -r line; do
    [[ "$line" == *"["*"]"* ]] || continue
    value="${line#*[}"
    value="${value%]*}"
    case "$line" in
      *"(NEEDED)"*) needed+="$value " ;;
      *"(RPATH)"*) rpath="$value" ;;
      *"(RUNPATH)"*) runpath="$value" ;;
    esac
  done < <(readelf -dW "$obj" 2>/dev/null)
  _dsh_needed["$obj"]="$needed"
  _dsh_rpath["$obj"]="$rpath"
  _dsh_runpath["$obj"]="$runpath"
}

# Simulate the loader mapping a program's dependencies, leaving the objects
# it would load in the caller's `_dsh_loaded` (path -> the injected soname
# through which it was reached, or `-`).
#
# Why a simulation and not a closure. ld.so maps DT_NEEDED breadth-first and
# loads each soname ONCE: a later request for a name already in the process is
# satisfied by the copy already there, wherever the requester would have found
# its own. So a host program whose own dependencies load its own glibc's
# `libdl.so.2` before the injected libcrypto asks for one keeps its own, and
# starts. Measured: of 36 programs on glibc 2.40 that a closure-based version
# of this scan flagged in a glibc-2.42 shell, 10 (`nix`, `openssl`, `pw-cat`,
# …) started fine for exactly this reason, while `curl` really died on the
# 2.42 `libdl.so.2`. Charging an injected library with its whole closure is
# wrong; charging what the process would actually load is right.
#
# Search order for a name `N` requested by object `O` (ld.so(8)): if `O` has
# no DT_RUNPATH, `O`'s DT_RPATH and then the executable's DT_RPATH;
# `LD_LIBRARY_PATH` (only when `$3` is `inject`); `O`'s DT_RUNPATH; then the
# directory of the libc the program runs on (`$2`, which on a distribution is
# the multiarch directory `ld.so.cache` mostly points into) and the default
# directories. `$ORIGIN` expands to `O`'s directory. The interpreter and every
# name that resolves to nothing are skipped: the first is already mapped, and
# a missing library is a different failure from the one this is about.
_dev_shell_simulate_load() {
  local exe="$1" libc_dir="$2" mode="$3"
  local -a queue=("$exe") llp=() search=() part=()
  local -A by_name=()
  local obj origin needed dir found exe_rpath="" via from_llp
  _dsh_loaded=()
  [[ "$mode" != inject || -z "${LD_LIBRARY_PATH:-}" ]] ||
    IFS=: read -r -a llp <<<"$LD_LIBRARY_PATH"
  _dev_shell_read_dynamic "$exe"
  [[ -n "${_dsh_runpath[$exe]}" ]] || exe_rpath="${_dsh_rpath[$exe]}"
  _dsh_loaded["$exe"]=-
  while [[ ${#queue[@]} -gt 0 ]]; do
    obj="${queue[0]}"
    queue=("${queue[@]:1}")
    _dev_shell_read_dynamic "$obj"
    origin="${obj%/*}"
    for needed in ${_dsh_needed[$obj]}; do
      [[ -z "${by_name[$needed]+set}" ]] || continue
      [[ "$needed" != ld-linux* ]] || continue
      search=()
      if [[ -z "${_dsh_runpath[$obj]}" && -n "${_dsh_rpath[$obj]}" ]]; then
        IFS=: read -r -a part <<<"${_dsh_rpath[$obj]}"; search+=("${part[@]}")
      fi
      # The executable's DT_RPATH is inherited only by an object that has no
      # DT_RUNPATH of its own: ld.so ignores the whole RPATH chain for a
      # requester that carries a RUNPATH.
      if [[ -n "$exe_rpath" && -z "${_dsh_runpath[$obj]}" ]]; then
        IFS=: read -r -a part <<<"$exe_rpath"; search+=("${part[@]}")
      fi
      # Tagged entries: `L:` marks an LD_LIBRARY_PATH directory, so a hit
      # there can be told apart from the same directory named by an RPATH.
      for dir in ${llp[@]+"${llp[@]}"}; do search+=("L:$dir"); done
      part=()
      [[ -z "${_dsh_runpath[$obj]}" ]] ||
        IFS=: read -r -a part <<<"${_dsh_runpath[$obj]}"
      search+=(${part[@]+"${part[@]}"} "$libc_dir" /lib /usr/lib /lib64 /usr/lib64)
      found=""
      via="${_dsh_loaded[$obj]}"
      for dir in "${search[@]}"; do
        from_llp=no
        if [[ "$dir" == L:* ]]; then from_llp=yes; dir="${dir#L:}"; fi
        dir="${dir//\$\{ORIGIN\}/$origin}"
        dir="${dir//\$ORIGIN/$origin}"
        [[ -n "$dir" && -f "$dir/$needed" ]] || continue
        found="$dir/$needed"
        # Found through LD_LIBRARY_PATH: this is the injection itself.
        if [[ "$from_llp" == yes && -n "${_dsh_injected[$needed]+set}" ]]; then
          via="$needed"
        fi
        break
      done
      by_name["$needed"]=1
      [[ -n "$found" ]] || continue
      # Memoised in the caller's `_dsh_real`: a fork per resolved library
      # per program is what made this scan take minutes on a PATH where most
      # programs run on another libc.
      if [[ -z "${_dsh_real[$found]+set}" ]]; then
        _dsh_real["$found"]="$(readlink -f "$found" 2>/dev/null ||
          printf '%s' "$found")"
      fi
      found="${_dsh_real[$found]}"
      [[ -z "${_dsh_loaded[$found]+set}" ]] || continue
      _dsh_loaded["$found"]="$via"
      queue+=("$found")
    done
  done
}

# An UPPER BOUND on what an injected library can drag into a process: the
# symbol versions `libc.so.6` must define for the library and its whole
# dependency closure, resolved through `LD_LIBRARY_PATH` and then each
# object's RPATH/RUNPATH. Used only as the step-2 filter: a libc that defines
# all of these cannot be broken by this injection, whatever a program on it
# links. It is NOT the verdict for any one program — a program that already
# loads its own copy of one of those dependencies is never charged with it;
# see `_dev_shell_simulate_load`.
_dev_shell_injected_requirements() {
  local file="$1"
  local -a queue=("$file") search=() llp=()
  local -A visited=()
  local obj origin rpath needed dir found
  [[ -z "${LD_LIBRARY_PATH:-}" ]] || IFS=: read -r -a llp <<<"$LD_LIBRARY_PATH"
  while [[ ${#queue[@]} -gt 0 ]]; do
    obj="${queue[0]}"
    queue=("${queue[@]:1}")
    [[ -z "${visited[$obj]+set}" ]] || continue
    visited["$obj"]=1
    dev_shell_elf_libc_requirements "$obj"
    origin="${obj%/*}"
    rpath="$(patchelf --print-rpath "$obj" 2>/dev/null)" || rpath=""
    rpath="${rpath//\$\{ORIGIN\}/$origin}"
    rpath="${rpath//\$ORIGIN/$origin}"
    search=(${llp[@]+"${llp[@]}"})
    if [[ -n "$rpath" ]]; then
      local -a rp=()
      IFS=: read -r -a rp <<<"$rpath"
      search+=("${rp[@]}")
    fi
    while read -r needed; do
      [[ -n "$needed" && "$needed" != libc.so.6 && "$needed" != ld-linux* ]] ||
        continue
      found=""
      for dir in ${search[@]+"${search[@]}"}; do
        [[ -n "$dir" && -f "$dir/$needed" ]] || continue
        found="$(readlink -f "$dir/$needed" 2>/dev/null ||
          printf '%s' "$dir/$needed")"
        break
      done
      [[ -z "$found" ]] || queue+=("$found")
    done < <(patchelf --print-needed "$obj" 2>/dev/null)
  done | sort -u
}

# The scan. One row per finding, tab-separated, kind first:
#
#   broken<TAB>name<TAB>binary<TAB>libc-dir<TAB>object<TAB>injected-soname<TAB>library-dir<TAB>injected-glibc<TAB>missing-versions
#
# `object` is the library the loader would name ("required by <object>"):
# the injected library itself, or one it pulls in, such as the shell glibc's
# `libdl.so.2`. `injected-soname` is the LD_LIBRARY_PATH entry it came in
# through.
#   unreadable<TAB>libc.so.6-path
#
# plus a final `examined<TAB><count>` row, so a report can say how much it
# looked at. Always returns 0: these are warnings about programs reprobuild
# does not run, and the caller decides how loudly to report them.
dev_shell_host_programs_broken_by_injection() {
  local -A _dsh_injected=() _dsh_needed=() _dsh_rpath=() _dsh_runpath=()
  local -A _dsh_loaded=() own_requires=() soname_dir=() in_baseline=()
  local -A _dsh_real=() missing_of=()
  local -A soname_glibc=() soname_requires=() defined_cache=() unreadable=()
  local -A libc_risky=() interp_of=() libc_dir_of=() requires_of_file=()
  local soname dir glibc name binary libc_dir libc rc missing row
  local interp real file all_required obj via injected_row
  local -a executables=() injected_run=()
  local examined=0
  while IFS=$'\t' read -r soname dir glibc; do
    [[ -n "$glibc" ]] || continue
    _dsh_injected["$soname"]=1
    soname_dir["$soname"]="$dir"
    soname_glibc["$soname"]="$glibc"
    # Memoised by resolved file: `libzstd.so`, `libzstd.so.1` and
    # `libzstd.so.1.5.7` are one library.
    file="$(readlink -f "$dir/$soname" 2>/dev/null || printf '%s' "$dir/$soname")"
    if [[ -z "${requires_of_file[$file]+set}" ]]; then
      requires_of_file["$file"]="$(_dev_shell_injected_requirements "$file")"
    fi
    soname_requires["$soname"]="${requires_of_file[$file]}"
  done < <(dev_shell_injected_sonames)
  if [[ ${#_dsh_injected[@]} -eq 0 ]]; then
    printf 'examined\t0\n'
    return 0
  fi
  all_required="$(printf '%s\n' "${soname_requires[@]}" | grep -v '^$' | sort -u)"

  mapfile -t executables < <(dev_shell_path_executables)
  while IFS=$'\t' read -r binary interp; do
    interp_of["$binary"]="$interp"
  done < <(printf '%s\n' ${executables[@]+"${executables[@]}"} | cut -f2 |
    dev_shell_elf_interpreters)

  for row in ${executables[@]+"${executables[@]}"}; do
    IFS=$'\t' read -r name binary <<<"$row"
    interp="${interp_of[$binary]:-}"
    [[ -n "$interp" ]] || continue
    # Step 1, once per interpreter: the `libc.so.6` in the directory of the
    # resolved PT_INTERP. Cached per loader, so it costs one fork per distinct
    # loader rather than one per program.
    if [[ -z "${libc_dir_of[$interp]+set}" ]]; then
      libc_dir_of["$interp"]=""
      real="$(readlink -f "$interp" 2>/dev/null)" || real=""
      if [[ -n "$real" && -f "${real%/*}/libc.so.6" ]]; then
        libc_dir_of["$interp"]="${real%/*}"
      fi
    fi
    libc_dir="${libc_dir_of[$interp]}"
    [[ -n "$libc_dir" ]] || continue
    examined=$((examined + 1))
    libc="$libc_dir/libc.so.6"
    if [[ -z "${defined_cache[$libc]+set}" ]]; then
      rc=0
      defined_cache["$libc"]="$(dev_shell_libc_defined_versions "$libc")" ||
        rc=$?
      if [[ "$rc" -ne 0 ]]; then
        unreadable["$libc"]=1
        printf 'unreadable\t%s\n' "$libc"
      fi
    fi
    [[ -z "${unreadable[$libc]+set}" ]] || continue
    # Step 2, once per libc: can any injected library conflict with it at
    # all? If not, the program is fine whatever it links.
    if [[ -z "${libc_risky[$libc]+set}" ]]; then
      libc_risky["$libc"]=no
      if [[ -n "$(comm -23 <(printf '%s\n' "$all_required") \
        <(printf '%s\n' "${defined_cache[$libc]}" | grep -v '^$' | sort -u) |
        head -n 1)" ]]; then
        libc_risky["$libc"]=yes
      fi
    fi
    [[ "${libc_risky[$libc]}" == yes ]] || continue
    # Step 3: what would the process load with and without the injection?
    # The objects only the injected run maps are what LD_LIBRARY_PATH adds;
    # each of them that needs a version this libc lacks is a reason the
    # program dies, and is reported as the loader would report it ("required
    # by <object>").
    # The injected run first: a program that reaches no injected soname
    # (most of PATH) needs no baseline at all.
    _dev_shell_simulate_load "$binary" "$libc_dir" inject
    injected_run=()
    for obj in "${!_dsh_loaded[@]}"; do
      [[ "${_dsh_loaded[$obj]}" == - ]] ||
        injected_run+=("$obj"$'\t'"${_dsh_loaded[$obj]}")
    done
    [[ ${#injected_run[@]} -gt 0 ]] || continue
    _dev_shell_simulate_load "$binary" "$libc_dir" plain
    in_baseline=()
    for obj in "${!_dsh_loaded[@]}"; do in_baseline["$obj"]=1; done
    for injected_row in "${injected_run[@]}"; do
      IFS=$'\t' read -r obj via <<<"$injected_row"
      [[ -z "${in_baseline[$obj]+set}" ]] || continue
      if [[ -z "${own_requires[$obj]+set}" ]]; then
        own_requires["$obj"]="$(dev_shell_elf_libc_requirements "$obj" | sort -u)"
      fi
      if [[ -z "${missing_of[$libc|$obj]+set}" ]]; then
        missing_of["$libc|$obj"]="$(comm -23 \
          <(printf '%s\n' "${own_requires[$obj]}" | grep -v '^$' | sort -u) \
          <(printf '%s\n' "${defined_cache[$libc]}" | grep -v '^$' | sort -u) |
          paste -sd, -)"
      fi
      missing="${missing_of[$libc|$obj]}"
      [[ -n "$missing" ]] || continue
      printf 'broken\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "$binary" \
        "$libc_dir" "$obj" "$via" "${soname_dir[$via]}" \
        "${soname_glibc[$via]}" "$missing"
    done
  done
  printf 'examined\t%s\n' "$examined"
  return 0
}
