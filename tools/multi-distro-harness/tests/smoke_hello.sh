#!/bin/sh
# Repro multi-distro smoke test: write hello.c, compile with gcc, run it,
# assert the output. Distro label comes from /etc/os-release ID; the
# provisioning scripts feed an identical probe at the end of each
# provision-<distro>.ps1 so passing here means the host's gcc + glibc/musl
# is still consistent with what the provisioner verified.
#
# Exit 0 on PASS, 1 on FAIL. Stays POSIX-sh-compatible (Alpine minirootfs
# has no bash).

set -eu

# Pull the distro ID for the label. Fall back to "unknown" if /etc/os-release
# is missing (shouldn't happen on any provisioned repro-* instance).
if [ -r /etc/os-release ]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  label="${ID:-unknown}"
else
  label='unknown'
fi

cat >/tmp/hello.c <<EOF
#include <stdio.h>
int main(void) { printf("hello %s\n", "${label}"); return 0; }
EOF

gcc -O0 -o /tmp/hello /tmp/hello.c
out=$(/tmp/hello)
expected="hello ${label}"
if [ "$out" != "$expected" ]; then
  echo "smoke_hello: FAIL - got '$out', expected '$expected'" >&2
  exit 1
fi
echo "smoke_hello: OK ($out)"
exit 0
