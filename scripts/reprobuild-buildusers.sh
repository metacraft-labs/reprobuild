#!/usr/bin/env bash
# reprobuild-buildusers — provision the optional system build-user pool.
#
# M6 PLATFORM-EXPANSION, clause 2. This is the OFF-BY-DEFAULT half of the
# system/shared-store mode for hardened multi-user hosts. Nothing in a
# default reprobuild install runs this script; a default install stays
# per-user and never creates a system account. It has to be invoked
# deliberately, as root, by an administrator who wants the hardened mode.
#
# What it provisions
# ------------------
#   * one system GROUP (default: reprobuild) that owns the shared store,
#   * N system ACCOUNTS (default: reprobuildbld01..reprobuildbld04) whose
#     only purpose is to be the uid a build executes as.
#
# The accounts are deliberately inert: --system (so they land in the
# system uid range and never show up in a login picker), no home
# directory, and a nologin shell. They exist to be a uid, not a user.
#
# Why a pool rather than one account
# ----------------------------------
# Concurrent builds must not be able to see or signal each other. Two
# builds sharing a uid can ptrace and kill each other and can write each
# other's temp files, so the pool size is the concurrency ceiling for
# mutually-untrusting builds. This mirrors the nixbld model.
#
# Usage
#   reprobuild-buildusers.sh provision [options]
#   reprobuild-buildusers.sh status    [options]
#   reprobuild-buildusers.sh destroy   [options]
#
# Options
#   --group NAME    build group name      (default: reprobuild)
#   --prefix NAME   account name prefix   (default: reprobuildbld)
#   --count N       number of accounts    (default: 4)
#   --dry-run       print what would run; change nothing
#
# `provision` is idempotent: re-running it converges rather than failing,
# and it reports what it actually observed afterwards via getent(1) --
# never merely what it asked for.
#
# Exit codes
#   0  success
#   1  usage / argument error
#   2  needs root and is not root
#   3  a required system tool is missing
#   4  provisioning ran but the post-condition read back from the system
#      did not match what was requested (this is the "we asked, the
#      system did not comply" case and must never be silent)

set -euo pipefail

GROUP_NAME="reprobuild"
USER_PREFIX="reprobuildbld"
USER_COUNT=4
DRY_RUN=0
COMMAND=""

die() { printf 'reprobuild-buildusers: %s\n' "$1" >&2; exit "${2:-1}"; }
note() { printf 'reprobuild-buildusers: %s\n' "$1" >&2; }

usage() {
  sed -n '2,48p' "$0" | sed 's/^# \{0,1\}//'
}

# --- argument parsing -------------------------------------------------------

while [ $# -gt 0 ]; do
  case "$1" in
    provision|status|destroy)
      [ -z "$COMMAND" ] || die "more than one command given: $COMMAND and $1"
      COMMAND="$1"; shift ;;
    --group)  [ $# -ge 2 ] || die "--group needs a value";  GROUP_NAME="$2"; shift 2 ;;
    --prefix) [ $# -ge 2 ] || die "--prefix needs a value"; USER_PREFIX="$2"; shift 2 ;;
    --count)  [ $# -ge 2 ] || die "--count needs a value";  USER_COUNT="$2";  shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[ -n "$COMMAND" ] || { usage >&2; die "no command given (provision|status|destroy)"; }

case "$USER_COUNT" in
  ''|*[!0-9]*) die "--count must be a non-negative integer, got '$USER_COUNT'" ;;
esac
[ "$USER_COUNT" -ge 1 ] || die "--count must be at least 1"
[ "$USER_COUNT" -le 64 ] || die "--count above 64 is almost certainly a typo"

# Conservative useradd(8)/groupadd(8) name charset. A name that needs
# quoting is a name that will eventually be interpolated somewhere it
# should not be.
for name in "$GROUP_NAME" "$USER_PREFIX"; do
  # Reject on the complement: any character outside the allowed set
  # anywhere in the string. A `[a-z0-9_-]*` glob would NOT do this --
  # `*` matches anything, so such a pattern silently accepts
  # `bad name!` and defers the rejection to groupadd(8).
  case "$name" in
    '') die "empty name" ;;
    *[!a-z0-9_-]*) die "invalid name '$name': only [a-z0-9_-] are allowed" ;;
  esac
  case "$name" in
    [a-z_]*) ;;
    *) die "invalid name '$name': must start with a lowercase letter or '_'" ;;
  esac
done

account_name() { printf '%s%02d' "$USER_PREFIX" "$1"; }

# --- system observation helpers --------------------------------------------
#
# Every one of these reads the SYSTEM's answer (getent) rather than
# echoing back the value we asked for. A provisioning script that
# verified its own inputs would pass on a host where nothing happened.

# NOTE on the trailing `|| true` in each reader: getent(1) exits 2 when
# the name is simply not present. That is a normal answer here, not a
# failure, but with `set -e` and `set -o pipefail` it would otherwise
# abort the script mid-report. The VALUE these return is still the
# system's answer -- empty means absent -- which is what every caller
# branches on.
group_gid() {
  # Echoes the gid, or nothing at all if the group does not exist.
  getent group "$1" 2>/dev/null | awk -F: 'NF>=3 {print $3}' || true
}

user_uid() {
  getent passwd "$1" 2>/dev/null | awk -F: 'NF>=3 {print $3}' || true
}

user_primary_gid() {
  getent passwd "$1" 2>/dev/null | awk -F: 'NF>=4 {print $4}' || true
}

user_shell() {
  getent passwd "$1" 2>/dev/null | awk -F: 'NF>=7 {print $7}' || true
}

nologin_path() {
  for candidate in /usr/sbin/nologin /sbin/nologin /usr/bin/false /bin/false; do
    [ -x "$candidate" ] && { printf '%s' "$candidate"; return 0; }
  done
  printf '/bin/false'
}

run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    printf 'would run:'; printf ' %q' "$@"; printf '\n'
    return 0
  fi
  "$@"
}

require_root() {
  [ "$(id -u)" -eq 0 ] || die "must run as root to change system accounts" 2
}

require_tools() {
  local missing=""
  for t in getent awk "$@"; do
    command -v "$t" >/dev/null 2>&1 || missing="$missing $t"
  done
  [ -z "$missing" ] || die "missing required tool(s):$missing" 3
}

# --- commands ---------------------------------------------------------------

cmd_status() {
  require_tools
  local gid rc=0
  gid="$(group_gid "$GROUP_NAME")"
  if [ -n "$gid" ]; then
    printf 'group %s gid=%s\n' "$GROUP_NAME" "$gid"
  else
    printf 'group %s ABSENT\n' "$GROUP_NAME"; rc=1
  fi
  local i name uid
  i=1
  while [ "$i" -le "$USER_COUNT" ]; do
    name="$(account_name "$i")"
    uid="$(user_uid "$name")"
    if [ -n "$uid" ]; then
      printf 'user %s uid=%s gid=%s shell=%s\n' \
        "$name" "$uid" "$(user_primary_gid "$name")" "$(user_shell "$name")"
    else
      printf 'user %s ABSENT\n' "$name"; rc=1
    fi
    i=$((i + 1))
  done
  return "$rc"
}

cmd_provision() {
  require_root
  require_tools groupadd useradd
  local shell_path
  shell_path="$(nologin_path)"

  if [ -z "$(group_gid "$GROUP_NAME")" ]; then
    note "creating group $GROUP_NAME"
    run groupadd --system "$GROUP_NAME"
  else
    note "group $GROUP_NAME already present; leaving it alone"
  fi

  local i name
  i=1
  while [ "$i" -le "$USER_COUNT" ]; do
    name="$(account_name "$i")"
    if [ -z "$(user_uid "$name")" ]; then
      note "creating account $name"
      # --system            : system uid range, no login clutter
      # --gid <group>       : primary group is the build group
      # --no-create-home    : a build user owns no home; the build gets a
      #                       scratch dir handed to it instead
      # --shell <nologin>   : the account is a uid, not a way in
      run useradd --system \
                  --gid "$GROUP_NAME" \
                  --no-create-home \
                  --home-dir /var/empty \
                  --shell "$shell_path" \
                  --comment "reprobuild build user" \
                  "$name"
    else
      note "account $name already present; leaving it alone"
    fi
    i=$((i + 1))
  done

  [ "$DRY_RUN" -eq 1 ] && { note "dry run: no verification possible"; return 0; }

  # ---- post-condition: read the system back, do not trust our own asks ----
  local gid
  gid="$(group_gid "$GROUP_NAME")"
  [ -n "$gid" ] || die "group $GROUP_NAME still absent after groupadd" 4

  i=1
  while [ "$i" -le "$USER_COUNT" ]; do
    name="$(account_name "$i")"
    local uid pgid
    uid="$(user_uid "$name")"
    pgid="$(user_primary_gid "$name")"
    [ -n "$uid" ] || die "account $name still absent after useradd" 4
    [ "$uid" -ne 0 ] || die "account $name resolved to uid 0; refusing" 4
    [ "$pgid" = "$gid" ] || \
      die "account $name primary gid $pgid != build group gid $gid" 4
    i=$((i + 1))
  done

  note "provisioned group $GROUP_NAME (gid=$gid) and $USER_COUNT account(s)"
  cmd_status
}

cmd_destroy() {
  require_root
  require_tools groupdel userdel
  local i name
  i=1
  while [ "$i" -le "$USER_COUNT" ]; do
    name="$(account_name "$i")"
    if [ -n "$(user_uid "$name")" ]; then
      note "removing account $name"
      run userdel "$name" || note "userdel $name failed; continuing"
    fi
    i=$((i + 1))
  done
  if [ -n "$(group_gid "$GROUP_NAME")" ]; then
    note "removing group $GROUP_NAME"
    run groupdel "$GROUP_NAME" || note "groupdel $GROUP_NAME failed; continuing"
  fi

  [ "$DRY_RUN" -eq 1 ] && return 0

  # Post-condition, again read back from the system.
  [ -z "$(group_gid "$GROUP_NAME")" ] || die "group $GROUP_NAME survived groupdel" 4
  i=1
  while [ "$i" -le "$USER_COUNT" ]; do
    name="$(account_name "$i")"
    [ -z "$(user_uid "$name")" ] || die "account $name survived userdel" 4
    i=$((i + 1))
  done
  note "removed group $GROUP_NAME and $USER_COUNT account(s)"
}

case "$COMMAND" in
  provision) cmd_provision ;;
  status)    cmd_status ;;
  destroy)   cmd_destroy ;;
  *)         die "unhandled command '$COMMAND'" ;;
esac
