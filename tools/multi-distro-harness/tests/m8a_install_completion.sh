#!/bin/sh
# e2e_cs_m8a_install_script_sets_up_completion: the installer leaves Bash, Zsh
# and Fish completing `repro`, registered exactly once.
#
#   REPRO_M8A_ARCHIVE=/path/reprobuild-<version>-linux-<arch>.tar.gz \
#     sh tools/multi-distro-harness/tests/m8a_install_completion.sh
#
# Run it as root on a DISPOSABLE Debian/Ubuntu or Fedora container or VM, never
# on a workstation: it installs packages, creates and deletes a user, and
# writes system completion directories. For example, with incus:
#
#   incus launch images:debian/bookworm m8a
#   incus exec m8a -- apt-get install -y curl gnupg dpkg-dev apt-utils \
#       python3 sudo bash-completion zsh fish
#   (Fedora: dnf install -y curl gnupg2 python3 sudo bash-completion zsh fish
#       createrepo_c rpm-sign rpm-build)
#   push this checkout's scripts/, tools/multi-distro-harness/ and
#   tests/fixtures/release-completions/, and the archive, into the container;
#   run this script there with REPRO_M8A_ARCHIVE set.
#
# REPRO_M8A_ARCHIVE is a REAL release archive: the shape release.yml builds
# (bin/, lib/, share/repro/completions/), relocated so it runs off the machine
# that built it. A stand-in shell script will not do here, because completing
# `repro wor` means running the installed `repro __complete`, and registering
# completion means running the installed `repro hooks ensure`. The native
# package is built from that same archive by scripts/release/repro-build-packages.sh
# and served, with the archive, from a local HTTP server that stands in for
# the release host (REPRO_BASE_URL), signed with a throwaway key, as in the
# m3_install_* arms.
#
# Legs:
#   1  Native (apt here on Debian, dnf on Fedora), installed as root: the
#      package's system completion files exist, nothing is written under the
#      user's home or /root, the three shells complete `repro wor<Tab>` to
#      `workspace` for an unprivileged user, and Bash has one registration.
#   2  Tarball, `sudo sh repro-install.sh --method tarball` from the user's
#      session: the installed tree is root's and writable by no one else;
#      the user's files and rc blocks exist, owned by the user;
#      nothing goes to the system directories or /root; the three shells
#      complete; a re-run leaves one block per rc file; --uninstall removes
#      them.
#   3  Tarball as root with no SUDO_USER: the files go to /usr/local/share
#      (Fish's to /etc/fish/completions) and nothing to /root; the shells
#      complete for the user; --uninstall removes them.
#   4  --no-completion (and REPRO_NO_COMPLETION=1): no completion file
#      anywhere, and the shells do NOT complete. This is also the control
#      that shows the completion probe is not vacuous. A SUDO_USER that
#      names no usable account (`#0`) registers nothing either.
#
# How completion is observed: each shell is started interactively on a
# pseudo-terminal, as the unprivileged user, from an empty directory, and is
# typed `repro wor` and a Tab. Completion has worked when the terminal then
# shows the rest of the word (`kspace`), which the typed text does not
# contain. The probe kills only the shell it started.

set -eu

REPO_ROOT="${REPRO_REPO_ROOT:-$(CDPATH='' cd -- "$(dirname -- "$0")/../../.." && pwd)}"
SIGN_DIR="$REPO_ROOT/scripts/release-signing"
INSTALL_SH="$REPO_ROOT/scripts/install/repro-install.sh"
BUILD_PKGS="$REPO_ROOT/scripts/release/repro-build-packages.sh"
PUBLISH="$REPO_ROOT/scripts/release/repro-publish-repos.sh"

ARCHIVE="${REPRO_M8A_ARCHIVE:?set REPRO_M8A_ARCHIVE to a real release archive (reprobuild-<version>-linux-<arch>.tar.gz)}"
WORK="${REPRO_M8A_WORK:-/var/tmp/m8a-install-completion}"
WWW="$WORK/www"
PORT="${REPRO_M8A_PORT:-8741}"
BASE="http://127.0.0.1:$PORT"
TUSER="${REPRO_M8A_USER:-m8auser}"
THOME="/home/$TUSER"

# The fixture repositories are built by repro-publish-repos.sh, which names
# its keyring after reprobuild; the installer is pointed at that name, as in
# the m3 arms.
REPRO_KEYRING_FILE='reprobuild-archive-keyring.gpg'
REPRO_REPO_USERS_DIR='/var/lib/metacraft-labs/repository-users'
export REPRO_KEYRING_FILE REPRO_REPO_USERS_DIR

fails=0
checks=0
step() { printf '\n=== %s ===\n' "$*"; }
ok()   { checks=$((checks + 1)); printf 'PASS  %s\n' "$*"; }
bad()  { checks=$((checks + 1)); fails=$((fails + 1)); printf 'FAIL  %s\n' "$*"; }
assert_eq() { if [ "$1" = "$2" ]; then ok "$3 (= $1)"; else bad "$3: expected '$2', got '$1'"; fi; }
assert_file() { if [ -e "$1" ]; then ok "$2: $1"; else bad "$2 missing: $1"; fi; }
assert_absent() { if [ ! -e "$1" ]; then ok "$2 absent: $1"; else bad "$2 still present: $1"; fi; }

# ---------------------------------------------------------------------
step 'preconditions'
# ---------------------------------------------------------------------
[ "$(id -u)" -eq 0 ] || { echo 'must run as root' >&2; exit 1; }
[ -f "$ARCHIVE" ] || { echo "no archive at $ARCHIVE" >&2; exit 1; }
. /etc/os-release
case " ${ID:-} ${ID_LIKE:-} " in
  *' debian '*|*' ubuntu '*) FAMILY='apt' ;;
  *' fedora '*|*' rhel '*) FAMILY='dnf' ;;
  *) echo "m8a_install_completion: expected a Debian or Fedora family, got ID=${ID:-?}" >&2; exit 1 ;;
esac
for f in "$INSTALL_SH" "$BUILD_PKGS" "$PUBLISH" "$SIGN_DIR/make-test-key.sh" "$SIGN_DIR/repro-sign-release.sh"; do
  [ -f "$f" ] || { echo "missing required script: $f" >&2; exit 1; }
done
need='curl gpg python3 sudo runuser useradd find bash zsh fish'
if [ "$FAMILY" = 'apt' ]; then need="$need dpkg-deb dpkg-scanpackages apt-ftparchive"
else need="$need rpmbuild createrepo_c rpmsign"
fi
for t in $need; do
  command -v "$t" >/dev/null 2>&1 || { echo "missing required tool: $t" >&2; exit 1; }
done
# The distribution's bash-completion is what loads the system and per-user
# Bash files; without it the installer would (correctly) add a ~/.bashrc
# block instead, which is a different case from the one under test.
[ -f /usr/share/bash-completion/bash_completion ] \
  || { echo 'the distribution bash-completion package is not installed' >&2; exit 1; }

_base="$(basename "$ARCHIVE" .tar.gz)"
_rest="${_base#reprobuild-}"
MACHINE="${_rest##*-linux-}"
V="${_rest%-linux-*}"
[ -n "$V" ] && [ "$V" != "$_rest" ] || { echo "cannot read a version from $ARCHIVE" >&2; exit 1; }
[ "$MACHINE" = "$(uname -m)" ] || { echo "archive is for $MACHINE, this machine is $(uname -m)" >&2; exit 1; }

# What the shells here actually read, printed rather than assumed: the
# completion locations of the packages and of --system are only correct if
# these lists contain them.
echo "os=${PRETTY_NAME:-?} family=$FAMILY version=$V"
echo "bash: $(bash --version | head -n 1)"
echo "zsh:  $(zsh --version)   fish: $(fish --version)"
echo 'zsh default fpath:'; zsh -f -c 'print -rl -- $fpath' | sed 's/^/  /'
if [ "$FAMILY" = 'dnf' ]; then
  echo "rpm completion macros: $(rpm --eval '%{bash_completions_dir} %{zsh_completions_dir} %{fish_completions_dir}')"
fi
if command -v pkg-config >/dev/null 2>&1; then
  echo "pkg-config bash-completion completionsdir: $(pkg-config --variable=completionsdir bash-completion 2>/dev/null || echo '?')"
  echo "pkg-config fish completionsdir: $(pkg-config --variable completionsdir fish 2>/dev/null || echo '?')"
fi

# Every place a `repro` completion script can be found, system-wide and for
# the user. A run is "registered once" for a shell when exactly one of these
# holds its script.
if [ "$FAMILY" = 'apt' ]; then ZSH_PKG_DIR='/usr/share/zsh/vendor-completions'
else ZSH_PKG_DIR='/usr/share/zsh/site-functions'
fi
PKG_BASH='/usr/share/bash-completion/completions/repro'
PKG_ZSH="$ZSH_PKG_DIR/_repro"
PKG_FISH='/usr/share/fish/vendor_completions.d/repro.fish'
SYS_BASH='/usr/local/share/bash-completion/completions/repro'
SYS_ZSH='/usr/local/share/zsh/site-functions/_repro'
# Fish's --system script goes in fish's configuration directory, which every
# fish searches; /usr/local/share/fish/vendor_completions.d is searched only
# when XDG_DATA_DIRS names /usr/local/share. The old place stays in the list
# of known locations so a script left there would be counted.
SYS_FISH='/etc/fish/completions/repro.fish'
OLD_SYS_FISH='/usr/local/share/fish/vendor_completions.d/repro.fish'
USR_BASH="$THOME/.local/share/bash-completion/completions/repro"
USR_ZSH="$THOME/.local/share/zsh/site-functions/_repro"
USR_FISH="$THOME/.config/fish/completions/repro.fish"
ALL_LOCATIONS="$PKG_BASH $PKG_ZSH $PKG_FISH $SYS_BASH $SYS_ZSH $SYS_FISH $OLD_SYS_FISH $USR_BASH $USR_ZSH $USR_FISH /root/.local/share/bash-completion/completions/repro /root/.local/share/zsh/site-functions/_repro /root/.config/fish/completions/repro.fish"

count_present() {
  _n=0
  for _p in "$@"; do [ -e "$_p" ] && _n=$((_n + 1)); done
  echo "$_n"
}

rm -rf "$WORK"
mkdir -p "$WORK" "$WWW"

# The pty probe. It starts ONE shell, as the test user, on a pseudo-terminal,
# answers the terminal queries a shell may wait on, types `repro wor` and a
# Tab, and reports whether the rest of the word appeared. For Bash it also
# reports how many `complete` registrations `repro` has. It kills only the
# process it started.
cat > "$WORK/pty_complete.py" <<'PY'
import os, pty, re, select, signal, sys, time

shell = sys.argv[1]
transcript_path = sys.argv[2]
argv = {"bash": ["bash", "-i"], "zsh": ["zsh", "-i"], "fish": ["fish", "-i"]}[shell]
pid, fd = pty.fork()
if pid == 0:
    os.execvp(argv[0], argv)

buf = bytearray()

def pump(seconds, until=None):
    end = time.time() + seconds
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.1)
        if r:
            try:
                data = os.read(fd, 65536)
            except OSError:
                return False
            if not data:
                return False
            buf.extend(data)
            # Primary device attributes and cursor-position queries: a shell
            # that asks and gets no answer may wait seconds for one.
            if b"\x1b[c" in data or b"\x1b[0c" in data:
                os.write(fd, b"\x1b[?62;22c")
            if b"\x1b[6n" in data:
                os.write(fd, b"\x1b[1;1R")
        if until is not None and until(bytes(buf)):
            return True
    return False

def plain(b):
    return re.sub(rb"\x1b\[[0-9;?]*[ -/]*[@-~]|\x1b[\]P][^\x07\x1b]*(\x07|\x1b\\)|\x1b[()][0-9A-Za-z]|\x1b[=>]|\r", b"", b)

try:
    pump(3)
    os.write(fd, b"echo M8A''READY\r")
    ready = pump(20, lambda b: b"M8AREADY" in plain(b).replace(b"M8A''READY", b""))
    mark = len(buf)
    os.write(fd, b"repro wor\t")
    completed = pump(15, lambda b: b"kspace" in plain(b[mark:]))
    registrations = "-"
    if shell == "bash":
        os.write(fd, b"\x15echo M8ACOUNT=$(complete -p repro 2>/dev/null | wc -l)\r")
        pump(10, lambda b: re.search(rb"M8ACOUNT=\d", plain(b[mark:])) is not None)
        m = re.search(rb"M8ACOUNT=(\d+)", plain(bytes(buf[mark:])))
        registrations = m.group(1).decode() if m else "?"
    print(f"ready={'yes' if ready else 'no'} completed={'yes' if completed else 'no'} registrations={registrations}")
finally:
    try:
        os.write(fd, b"\x15exit\r")
        pump(2)
    except OSError:
        pass
    try:
        os.kill(pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    try:
        os.waitpid(pid, 0)
    except ChildProcessError:
        pass
    with open(transcript_path, "wb") as f:
        f.write(plain(bytes(buf)))
PY

# probe <shell> <tag>: run the pty probe as the test user, with a clean
# environment, from an empty directory; print its one-line result.
probe() {
  _d="$(runuser -u "$TUSER" -- mktemp -d)"
  ( cd "$_d" && runuser -u "$TUSER" -- env -i HOME="$THOME" USER="$TUSER" LOGNAME="$TUSER" \
      SHELL="/bin/$1" TERM=xterm LANG=C.UTF-8 \
      PATH=/usr/local/bin:/usr/bin:/bin \
      python3 "$WORK/pty_complete.py" "$1" "$_d/.transcript" ) 2>&1 | tail -n 1
  cp "$_d/.transcript" "$WORK/transcript-$(printf %s "$2" | tr ' ' -)-$1.txt" 2>/dev/null || true
  rm -rf "$_d"
}

# assert_completes <tag> yes|no
assert_completes() {
  _tag="$1"; _want="$2"
  for _sh in bash zsh fish; do
    _r="$(probe "$_sh" "$_tag")"
    case "$_r" in *'ready=yes'*) ;; *) bad "$_tag: the $_sh probe never got a prompt ($_r; transcript $WORK/transcript-$(printf %s "$_tag" | tr " " -)-$_sh.txt)"; continue ;; esac
    case "$_r" in
      *"completed=$_want"*) ok "$_tag: $_sh completes 'repro wor<Tab>' -> workspace: $_want ($_r)" ;;
      *) bad "$_tag: $_sh: expected completed=$_want, got: $_r (transcript $WORK/transcript-$(printf %s "$_tag" | tr " " -)-$_sh.txt)"
         sed -n '1,30p' "$WORK/transcript-$(printf %s "$_tag" | tr " " -)-$_sh.txt" ;;
    esac
    if [ "$_sh" = bash ] && [ "$_want" = yes ]; then
      case "$_r" in
        *'registrations=1'*) ok "$_tag: bash has exactly one 'complete' registration for repro" ;;
        *) bad "$_tag: bash registrations for repro: $_r" ;;
      esac
    fi
  done
}

# assert_registered_once <tag> <bash-path> <zsh-path> <fish-path>: each shell's
# script is at the expected place and at no other known place.
assert_registered_once() {
  _tag="$1"; shift
  for _p in "$@"; do assert_file "$_p" "$_tag: completion script"; done
  assert_eq "$(count_present $ALL_LOCATIONS)" "$#" "$_tag: completion scripts present across every known location"
}

# A listing of a directory tree, for "nothing was written here".
snapshot() { find "$1" -xdev \( -type f -o -type d -o -type l \) -printf '%P %y %s %m %U\n' 2>/dev/null | LC_ALL=C sort; }

# Recreate the test user with the distribution's default home (its skeleton
# .bashrc is what loads bash-completion on Debian) and a .zshrc that holds
# only compinit, as the plan states.
new_user() {
  userdel -r "$TUSER" >/dev/null 2>&1 || true
  useradd -m -s /bin/bash "$TUSER"
  printf 'autoload -U compinit; compinit\n' > "$THOME/.zshrc"
  chown "$TUSER:" "$THOME/.zshrc"
  printf '%s ALL=(ALL) NOPASSWD: ALL\n' "$TUSER" > /etc/sudoers.d/m8a-user
  chmod 0440 /etc/sudoers.d/m8a-user
}

cleanup() {
  set +e
  [ -z "${HTTP_PID:-}" ] || kill "$HTTP_PID" 2>/dev/null
  rm -f /etc/sudoers.d/m8a-user
  userdel -r "$TUSER" >/dev/null 2>&1
}
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------
step 'reset: no reprobuild, no repro completion anywhere'
# ---------------------------------------------------------------------
if [ "$FAMILY" = 'apt' ]; then apt-get remove -y --purge reprobuild >/dev/null 2>&1 || true
else dnf -y remove reprobuild >/dev/null 2>&1 || true
fi
rm -rf /var/lib/reprobuild /usr/local/lib/reprobuild /usr/local/bin/repro
for _p in $ALL_LOCATIONS; do rm -f "$_p"; done
new_user
assert_eq "$(count_present $ALL_LOCATIONS)" '0' 'reset: no repro completion script anywhere'

# ---------------------------------------------------------------------
step 'throwaway signing key; native package and signed tarball from the archive'
# ---------------------------------------------------------------------
GOOD_HOME="$WORK/gnupg-good"
GOOD_FPR="$(sh "$SIGN_DIR/make-test-key.sh" --home "$GOOD_HOME")"
[ -n "$GOOD_FPR" ] || { echo 'no signing key' >&2; exit 1; }
mkdir -p "$WORK/pkgs"
if ! sh "$BUILD_PKGS" --version "$V" --tarball "$ARCHIVE" --out "$WORK/pkgs" \
     --ecosystem "$( [ "$FAMILY" = apt ] && echo deb || echo rpm )" \
     --platform linux --asset-arch "$MACHINE" > "$WORK/build-pkgs.log" 2>&1; then
  cat "$WORK/build-pkgs.log"; echo 'repro-build-packages.sh failed' >&2; exit 1
fi
if [ "$FAMILY" = 'apt' ]; then
  _pubargs="--ecosystem deb --deb-arch $(dpkg --print-architecture)"
else
  _pubargs='--ecosystem rpm'
fi
# shellcheck disable=SC2086
if ! env GNUPGHOME="$GOOD_HOME" REPRO_SIGNING_ALLOW_TEST_KEY=1 \
     sh "$PUBLISH" --version "$V" --packages "$WORK/pkgs" --key "$GOOD_FPR" \
     $_pubargs --repo-root "$WORK/repo" --target "local:$WWW" \
     --export-keyring "$WORK/keyring.gpg" > "$WORK/publish.log" 2>&1; then
  cat "$WORK/publish.log"; echo 'repro-publish-repos.sh failed' >&2; exit 1
fi
ANCHOR_SHA="$(cat "$WWW/keys/$REPRO_KEYRING_FILE.sha256")"
DL="$WWW/downloads/v$V"
mkdir -p "$DL"
cp "$ARCHIVE" "$DL/"
( cd "$DL" && sha256sum "$(basename "$ARCHIVE")" > SHA256SUMS )
if ! env GNUPGHOME="$GOOD_HOME" REPRO_SIGNING_ALLOW_TEST_KEY=1 \
     sh "$SIGN_DIR/repro-sign-release.sh" --dir "$DL" --key "$GOOD_FPR" > "$WORK/sign.log" 2>&1; then
  cat "$WORK/sign.log"; echo 'repro-sign-release.sh failed' >&2; exit 1
fi
ok "native package and signed tarball for $V published under $WWW"

# ---------------------------------------------------------------------
step 'serve the release host over local HTTP'
# ---------------------------------------------------------------------
# A port already bound is refused, never adopted: a server left over from a
# previous run would serve this run's files and hide its own failure.
if curl -fsS -o /dev/null "$BASE/" 2>/dev/null; then
  echo "FATAL: $BASE answers before this run started its server" >&2; exit 1
fi
( cd "$WWW" && exec python3 -m http.server "$PORT" --bind 127.0.0.1 ) > "$WORK/http.log" 2>&1 &
HTTP_PID=$!
_i=0
until curl -fsS -o /dev/null "$BASE/downloads/v$V/SHA256SUMS" 2>/dev/null; do
  _i=$((_i + 1))
  [ "$_i" -lt 50 ] && kill -0 "$HTTP_PID" 2>/dev/null || { cat "$WORK/http.log"; echo 'the HTTP server did not come up' >&2; exit 1; }
  sleep 0.2
done
ok "HTTP server pid $HTTP_PID serves $BASE"

# The installer's environment for this run's release host and trust anchor
# (no value contains a space), passed explicitly because sudo resets the
# environment.
INSTALL_ENV="REPRO_BASE_URL=$BASE REPRO_KEYRING_SHA256=$ANCHOR_SHA REPRO_ALLOW_TEST_KEY=1 REPRO_VERIFY_SCRIPT=$SIGN_DIR/repro-verify-release.sh REPRO_KEYRING_FILE=$REPRO_KEYRING_FILE REPRO_REPO_USERS_DIR=$REPRO_REPO_USERS_DIR"
# As root, with no invoking user (incus exec and a root login set none).
# shellcheck disable=SC2086
as_root() { env -u SUDO_USER -u SUDO_UID -u SUDO_GID -u SUDO_COMMAND $INSTALL_ENV "$@"; }
# From the test user's session, through sudo, so the installer sees SUDO_USER.
# shellcheck disable=SC2086
as_user_sudo() { runuser -u "$TUSER" -- sudo -n env $INSTALL_ENV "$@"; }

# =====================================================================
step "leg 1: native ($FAMILY), as root"
# =====================================================================
snapshot "$THOME" > "$WORK/home-before.txt"
snapshot /root > "$WORK/root-before.txt"
set +e
as_root sh "$INSTALL_SH" --method "$FAMILY" > "$WORK/leg1.log" 2>&1
_rc=$?
set -e
sed -n '1,60p' "$WORK/leg1.log"
assert_eq "$_rc" '0' 'leg 1: the native install exited 0'
snapshot "$THOME" > "$WORK/home-after.txt"
snapshot /root > "$WORK/root-after.txt"
if cmp -s "$WORK/home-before.txt" "$WORK/home-after.txt"; then ok "leg 1: nothing written under $THOME"
else bad "leg 1: the native install wrote under $THOME"; diff "$WORK/home-before.txt" "$WORK/home-after.txt" || true
fi
if cmp -s "$WORK/root-before.txt" "$WORK/root-after.txt"; then ok 'leg 1: nothing written under /root'
else bad 'leg 1: the native install wrote under /root'; diff "$WORK/root-before.txt" "$WORK/root-after.txt" || true
fi
assert_registered_once 'leg 1' "$PKG_BASH" "$PKG_ZSH" "$PKG_FISH"
assert_absent /var/lib/reprobuild/completion 'leg 1: a tarball completion record'
assert_completes 'leg 1' yes
set +e
as_root sh "$INSTALL_SH" --method "$FAMILY" --uninstall > "$WORK/leg1-uninstall.log" 2>&1
_rc=$?
set -e
assert_eq "$_rc" '0' 'leg 1: the native uninstall exited 0'
assert_eq "$(count_present $ALL_LOCATIONS)" '0' 'leg 1: the uninstalled package left no completion script'

# =====================================================================
step 'leg 2: tarball, through sudo from the user session'
# =====================================================================
new_user
snapshot /root > "$WORK/root-before.txt"
set +e
as_user_sudo sh "$INSTALL_SH" --method tarball --version "$V" > "$WORK/leg2.log" 2>&1
_rc=$?
set -e
sed -n '1,80p' "$WORK/leg2.log"
assert_eq "$_rc" '0' 'leg 2: the tarball install exited 0'
assert_file /usr/local/lib/reprobuild/share/repro/completions/_repro 'leg 2: the archive share/ was installed'
# The archive's owner is whoever built it; the installed tree, whose binary
# root runs, must be root's and writable by no one else.
assert_eq "$(find /usr/local/lib/reprobuild ! -uid 0 | wc -l)" '0' 'leg 2: every installed file is owned by root'
assert_eq "$(find /usr/local/lib/reprobuild -perm /022 ! -type l | wc -l)" '0' 'leg 2: no installed file is group- or world-writable'
assert_registered_once 'leg 2' "$USR_BASH" "$USR_ZSH" "$USR_FISH"
for _p in "$USR_BASH" "$USR_ZSH" "$USR_FISH" "$THOME/.zshrc"; do
  assert_eq "$(stat -c %U "$_p" 2>/dev/null || echo missing)" "$TUSER" "leg 2: $_p is owned by the user"
done
for _d in "$THOME/.local" "$THOME/.local/share" "$THOME/.config"; do
  assert_eq "$(stat -c %U "$_d" 2>/dev/null || echo missing)" "$TUSER" "leg 2: $_d is owned by the user"
done
assert_eq "$(grep -c '>>> repro:home:repro-completion-zsh >>>' "$THOME/.zshrc" || true)" '1' 'leg 2: one zsh block in .zshrc'
assert_eq "$(grep -c 'repro:home:repro-completion' "$THOME/.bashrc" || true)" '0' 'leg 2: no bash block (bash-completion loads the file)'
snapshot /root > "$WORK/root-after.txt"
if cmp -s "$WORK/root-before.txt" "$WORK/root-after.txt"; then ok 'leg 2: nothing written under /root'
else bad 'leg 2: the tarball install wrote under /root'; diff "$WORK/root-before.txt" "$WORK/root-after.txt" || true
fi
assert_completes 'leg 2' yes
set +e
as_user_sudo sh "$INSTALL_SH" --method tarball --version "$V" > "$WORK/leg2-rerun.log" 2>&1
_rc=$?
set -e
assert_eq "$_rc" '0' 'leg 2: a re-run exited 0'
assert_eq "$(grep -c '>>> repro:home:repro-completion-zsh >>>' "$THOME/.zshrc" || true)" '1' 'leg 2: still one zsh block after a re-run'
assert_eq "$(grep -c 'repro:home:repro-completion' "$THOME/.bashrc" || true)" '0' 'leg 2: still no bash block after a re-run'
assert_eq "$(count_present $ALL_LOCATIONS)" '3' 'leg 2: still one script per shell after a re-run'
set +e
as_user_sudo sh "$INSTALL_SH" --method tarball --uninstall > "$WORK/leg2-uninstall.log" 2>&1
_rc=$?
set -e
sed -n '1,30p' "$WORK/leg2-uninstall.log"
assert_eq "$_rc" '0' 'leg 2: --uninstall exited 0'
assert_eq "$(count_present $ALL_LOCATIONS)" '0' 'leg 2: --uninstall removed every completion script'
assert_eq "$(grep -c 'repro:home:repro-completion' "$THOME/.zshrc" || true)" '0' 'leg 2: --uninstall removed the zsh block'
assert_absent /var/lib/reprobuild/completion 'leg 2: the completion record'
assert_absent /usr/local/lib/reprobuild 'leg 2: the tarball tree'

# =====================================================================
step 'leg 3: tarball as root with no SUDO_USER'
# =====================================================================
new_user
snapshot "$THOME" > "$WORK/home-before.txt"
snapshot /root > "$WORK/root-before.txt"
set +e
as_root sh "$INSTALL_SH" --method tarball --version "$V" > "$WORK/leg3.log" 2>&1
_rc=$?
set -e
sed -n '1,80p' "$WORK/leg3.log"
assert_eq "$_rc" '0' 'leg 3: the tarball install exited 0'
assert_registered_once 'leg 3' "$SYS_BASH" "$SYS_ZSH" "$SYS_FISH"
snapshot "$THOME" > "$WORK/home-after.txt"
snapshot /root > "$WORK/root-after.txt"
if cmp -s "$WORK/root-before.txt" "$WORK/root-after.txt"; then ok 'leg 3: nothing written under /root'
else bad 'leg 3: the install wrote under /root'; diff "$WORK/root-before.txt" "$WORK/root-after.txt" || true
fi
if cmp -s "$WORK/home-before.txt" "$WORK/home-after.txt"; then ok "leg 3: nothing written under $THOME"
else bad "leg 3: the install wrote under $THOME"; diff "$WORK/home-before.txt" "$WORK/home-after.txt" || true
fi
assert_completes 'leg 3' yes
set +e
as_root sh "$INSTALL_SH" --method tarball --uninstall > "$WORK/leg3-uninstall.log" 2>&1
_rc=$?
set -e
assert_eq "$_rc" '0' 'leg 3: --uninstall exited 0'
assert_eq "$(count_present $ALL_LOCATIONS)" '0' 'leg 3: --uninstall removed the system completion scripts'

# =====================================================================
step 'leg 4: --no-completion and REPRO_NO_COMPLETION=1'
# =====================================================================
new_user
set +e
as_user_sudo sh "$INSTALL_SH" --method tarball --version "$V" --no-completion > "$WORK/leg4.log" 2>&1
_rc=$?
set -e
sed -n '1,40p' "$WORK/leg4.log"
assert_eq "$_rc" '0' 'leg 4: the --no-completion install exited 0'
assert_file /usr/local/bin/repro 'leg 4: repro is installed'
assert_eq "$(count_present $ALL_LOCATIONS)" '0' 'leg 4: --no-completion wrote no completion script'
assert_eq "$(grep -c 'repro:home:repro-completion' "$THOME/.zshrc" || true)" '0' 'leg 4: --no-completion wrote no zsh block'
assert_absent /var/lib/reprobuild/completion 'leg 4: a completion record'
# The control for the probe itself: with repro installed and no completion
# registered, no shell may complete `repro wor`.
assert_completes 'leg 4' no
set +e
as_root env REPRO_NO_COMPLETION=1 sh "$INSTALL_SH" --method tarball --version "$V" > "$WORK/leg4b.log" 2>&1
_rc=$?
set -e
assert_eq "$_rc" '0' 'leg 4: the REPRO_NO_COMPLETION=1 root install exited 0'
assert_eq "$(count_present $ALL_LOCATIONS)" '0' 'leg 4: REPRO_NO_COMPLETION=1 wrote no completion script'
# A SUDO_USER that names no usable account ('#0' is uid 0 to `sudo -u`) is
# refused: nothing is registered, for that "user" or system-wide.
snapshot /root > "$WORK/root-before.txt"
set +e
as_root env SUDO_USER='#0' sh "$INSTALL_SH" --method tarball --version "$V" > "$WORK/leg4c.log" 2>&1
_rc=$?
set -e
assert_eq "$_rc" '0' "leg 4: the install with SUDO_USER='#0' exited 0"
assert_eq "$(count_present $ALL_LOCATIONS)" '0' "leg 4: SUDO_USER='#0' wrote no completion script"
assert_absent /var/lib/reprobuild/completion "leg 4: SUDO_USER='#0' left no completion record"
snapshot /root > "$WORK/root-after.txt"
if cmp -s "$WORK/root-before.txt" "$WORK/root-after.txt"; then ok "leg 4: SUDO_USER='#0' wrote nothing under /root"
else bad "leg 4: SUDO_USER='#0' wrote under /root"; diff "$WORK/root-before.txt" "$WORK/root-after.txt" || true
fi
set +e
as_root sh "$INSTALL_SH" --method tarball --uninstall > "$WORK/leg4-uninstall.log" 2>&1
set -e

# ---------------------------------------------------------------------
step 'summary'
# ---------------------------------------------------------------------
printf 'm8a_install_completion (%s): %d checks, %d failure(s)\n' "$FAMILY" "$checks" "$fails"
[ "$fails" -eq 0 ] || exit 1
exit 0
