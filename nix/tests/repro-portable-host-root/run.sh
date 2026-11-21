#!/usr/bin/env bash
# Builds a host-shaped root with NO /nix -- merged /usr (`/bin -> usr/bin`),
# busybox for the base tools, a static git, empty /opt /srv /mnt /media, the way
# a Debian runner image looks -- and runs probe.sh in it under bubblewrap, twice:
#
#   positive  `repro` on PATH is the portable bundle under test;
#   negative  `repro` on PATH launches the SAME extracted closure the way the
#             stock bundle did: from the extraction directory, through the
#             stock nix-user-chroot and its fixed directory allowlist.
#
# Then it binds a host /nix into the same root (a /nix/store with a marker and
# a `nix` on PATH, as after a job installs Nix) and runs probe-nix-host.sh
# twice more:
#
#   nix-host-positive  `repro` is the bundle under test, which must refuse;
#   nix-host-negative  `repro` is the same bundle with its Nix-host guard
#                      removed -- byte for byte the bundle before the guard --
#                      which starts and hides the host's Nix.
#
# Each positive run must PASS every property and each negative run must FAIL
# every one; a control that passes anything is not a control.
#
# Inputs (environment): BUNDLE, OLD_NUC, REPRO_PROGRAM, BUSYBOX, GIT_BIN,
# PROBE, PROBE_NIX_HOST, HEADER_BEFORE_GUARD, NIX_HOST_GUARD, BWRAP, WORK.
set -euo pipefail

: "${BUNDLE:?}" "${OLD_NUC:?}" "${REPRO_PROGRAM:?}" "${BUSYBOX:?}"
: "${GIT_BIN:?}" "${PROBE:?}" "${PROBE_NIX_HOST:?}" "${HEADER_BEFORE_GUARD:?}"
: "${NIX_HOST_GUARD?}" "${BWRAP:?}" "${WORK:?}"

properties=(
  repro-spawns-bin-sh
  repro-cwd-is-caller-cwd
  hooks-ensure-installs-post-checkout
  git-checkout-dispatches-post-checkout
)
nix_host_properties=(
  refuses-on-a-nix-host
  refusal-names-what-to-install
  host-nix-never-hidden
  refuses-before-extracting
)

root="$WORK/root"
mkdir -p "$root"/{usr/bin,usr/sbin,usr/lib,usr/lib64,usr/local/bin,etc}
mkdir -p "$root"/{home/runner,root,tmp,var/tmp,run,dev,proc,sys}
mkdir -p "$root"/{opt/old-allowlist/bin,srv,mnt,media}
ln -s usr/bin "$root/bin"
ln -s usr/sbin "$root/sbin"
ln -s usr/lib "$root/lib"
ln -s usr/lib64 "$root/lib64"
for marker in opt srv mnt media; do
  echo "$marker" > "$root/$marker/host-marker"
done

cp "$BUSYBOX" "$root/usr/bin/busybox"
chmod 0755 "$root/usr/bin/busybox"
for applet in $("$BUSYBOX" --list); do
  [ -e "$root/usr/bin/$applet" ] || ln -s busybox "$root/usr/bin/$applet"
done
for tool in "$GIT_BIN"/*; do
  name=$(basename "$tool")
  rm -f "$root/usr/bin/$name"
  cp -L "$tool" "$root/usr/bin/$name"
  chmod 0755 "$root/usr/bin/$name"
done

printf 'root:x:0:0:root:/root:/bin/sh\nrunner:x:1000:1000:runner:/home/runner:/bin/sh\n' \
  > "$root/etc/passwd"
printf 'root:x:0:\nrunner:x:1000:\n' > "$root/etc/group"

touch "$root/usr/local/bin/repro" "$root/opt/old-allowlist/nix-user-chroot" \
  "$root/probe.sh" "$root/probe-nix-host.sh"
mkdir -p "$root/home/nixhost-positive" "$root/home/nixhost-negative"

# The stock launch, verbatim apart from the paths: arx has already cd'd into
# the extraction directory, and the stock nix-user-chroot starts repro there.
cat > "$root/opt/old-allowlist/bin/repro" <<EOF
#!/bin/sh
cd "\$HOME"/.cache/tmpx-*/dat || exit 127
exec /opt/old-allowlist/nix-user-chroot -n ./nix -- $REPRO_PROGRAM "\$@"
EOF
chmod 0755 "$root/opt/old-allowlist/bin/repro"

# run_bwrap <name> <log> <repro> <HOME> <PATH> [bwrap args...] -- <command...>
run_bwrap() {
  local name=$1 log=$2 repro=$3 home=$4 path=$5 status=0
  shift 5
  local extra=()
  while [ "$1" != -- ]; do extra+=("$1"); shift; done
  shift
  "$BWRAP" \
    --unshare-user --unshare-pid --uid 1000 --gid 1000 --die-with-parent \
    --bind "$root" / \
    --ro-bind "$repro" /usr/local/bin/repro \
    --ro-bind "$OLD_NUC" /opt/old-allowlist/nix-user-chroot \
    --ro-bind "$PROBE" /probe.sh \
    --ro-bind "$PROBE_NIX_HOST" /probe-nix-host.sh \
    "${extra[@]}" \
    --dev /dev --proc /proc --tmpfs /tmp \
    --chdir "$home" \
    --clearenv \
    --setenv HOME "$home" \
    --setenv USER runner \
    --setenv PATH "$path" \
    "$@" > "$log" 2>&1 || status=$?
  sed "s/^/[$name] /" "$log"
  echo "[$name] exit=$status"
}

run_probe() { # <name> <PATH> <log>
  run_bwrap "$1" "$3" "$BUNDLE" /home/runner "$2" -- \
    /bin/sh /probe.sh "/home/runner/work/$1"
}

# Nothing under test may see a /nix: the root has none, and the probe runs
# with a PATH that names none.
[ ! -e "$root/nix" ]

run_probe positive /usr/local/bin:/usr/bin:/bin "$WORK/positive.log"
run_probe negative /opt/old-allowlist/bin:/usr/local/bin:/usr/bin:/bin \
  "$WORK/negative.log"

# ---- the same root, on a host that has Nix ---------------------------------
# The unguarded bundle: the header the build wrote before the guard, then
# everything after the guard. Refuse to build a control from a bundle whose
# header is not exactly <header><guard>, or the control would be something else.
guarded_prefix="$HEADER_BEFORE_GUARD$NIX_HOST_GUARD"
prefix_len=$(printf '%s' "$guarded_prefix" | wc -c)
if ! head -c "$prefix_len" "$BUNDLE" | cmp -s - <(printf '%s' "$guarded_prefix"); then
  echo "the bundle's header is not <header><Nix-host guard>; cannot build the control" >&2
  exit 1
fi
{
  printf '%s' "$HEADER_BEFORE_GUARD"
  tail -c +"$((prefix_len + 1))" "$BUNDLE"
} > "$WORK/unguarded"
chmod 0555 "$WORK/unguarded"

hostnix="$WORK/hostnix"
mkdir -p "$hostnix/store" "$hostnix/var/nix/profiles/default/bin"
echo host > "$hostnix/store/host-nix-marker"
printf '#!/bin/sh\necho "nix (Nix) 2.99-host"\n' \
  > "$hostnix/var/nix/profiles/default/bin/nix"
chmod 0755 "$hostnix/var/nix/profiles/default/bin/nix"
mkdir -p "$root/nix"

nix_host_path=/usr/local/bin:/nix/var/nix/profiles/default/bin:/usr/bin:/bin
for side in positive negative; do
  if [ "$side" = positive ]; then repro=$BUNDLE; else repro=$WORK/unguarded; fi
  run_bwrap "nix-host-$side" "$WORK/nix-host-$side.log" "$repro" \
    "/home/nixhost-$side" "$nix_host_path" --ro-bind "$hostnix" /nix -- \
    /bin/sh /probe-nix-host.sh /home/runner/work/positive/ws
done

verdict=0
assert_runs() { # <positive-log> <negative-log> <property...>
  local pos=$1 neg=$2 property
  shift 2
  for property in "$@"; do
    if ! grep -qx "PASS $property" "$pos"; then
      echo "$(basename "$pos" .log): $property did not pass" >&2
      verdict=1
    fi
    if ! grep -qx "FAIL $property" "$neg"; then
      echo "$(basename "$neg" .log): $property did not fail -- the control does not discriminate" >&2
      verdict=1
    fi
  done
}
assert_runs "$WORK/positive.log" "$WORK/negative.log" "${properties[@]}"
assert_runs "$WORK/nix-host-positive.log" "$WORK/nix-host-negative.log" \
  "${nix_host_properties[@]}"
exit "$verdict"
