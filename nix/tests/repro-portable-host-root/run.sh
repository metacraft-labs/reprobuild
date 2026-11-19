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
# The positive run must PASS every property and the negative run must FAIL
# every one; a control that passes anything is not a control.
#
# Inputs (environment): BUNDLE, OLD_NUC, REPRO_PROGRAM, BUSYBOX, GIT_BIN,
# PROBE, BWRAP, WORK.
set -euo pipefail

: "${BUNDLE:?}" "${OLD_NUC:?}" "${REPRO_PROGRAM:?}" "${BUSYBOX:?}"
: "${GIT_BIN:?}" "${PROBE:?}" "${BWRAP:?}" "${WORK:?}"

properties=(
  repro-spawns-bin-sh
  repro-cwd-is-caller-cwd
  hooks-ensure-installs-post-checkout
  git-checkout-dispatches-post-checkout
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
  "$root/probe.sh"

# The stock launch, verbatim apart from the paths: arx has already cd'd into
# the extraction directory, and the stock nix-user-chroot starts repro there.
cat > "$root/opt/old-allowlist/bin/repro" <<EOF
#!/bin/sh
cd "\$HOME"/.cache/tmpx-*/dat || exit 127
exec /opt/old-allowlist/nix-user-chroot -n ./nix -- $REPRO_PROGRAM "\$@"
EOF
chmod 0755 "$root/opt/old-allowlist/bin/repro"

run_probe() { # <name> <PATH> <log>
  local status=0
  "$BWRAP" \
    --unshare-user --unshare-pid --uid 1000 --gid 1000 --die-with-parent \
    --bind "$root" / \
    --ro-bind "$BUNDLE" /usr/local/bin/repro \
    --ro-bind "$OLD_NUC" /opt/old-allowlist/nix-user-chroot \
    --ro-bind "$PROBE" /probe.sh \
    --dev /dev --proc /proc --tmpfs /tmp \
    --chdir /home/runner \
    --clearenv \
    --setenv HOME /home/runner \
    --setenv USER runner \
    --setenv PATH "$2" \
    /bin/sh /probe.sh "/home/runner/work/$1" > "$3" 2>&1 || status=$?
  sed "s/^/[$1] /" "$3"
  echo "[$1] exit=$status"
}

# Nothing under test may see a /nix: the root has none, and the probe runs
# with a PATH that names none.
[ ! -e "$root/nix" ]

run_probe positive /usr/local/bin:/usr/bin:/bin "$WORK/positive.log"
run_probe negative /opt/old-allowlist/bin:/usr/local/bin:/usr/bin:/bin \
  "$WORK/negative.log"

verdict=0
for property in "${properties[@]}"; do
  if ! grep -qx "PASS $property" "$WORK/positive.log"; then
    echo "positive: $property did not pass" >&2
    verdict=1
  fi
  if ! grep -qx "FAIL $property" "$WORK/negative.log"; then
    echo "negative control: $property did not fail -- the control does not discriminate" >&2
    verdict=1
  fi
done
exit "$verdict"
