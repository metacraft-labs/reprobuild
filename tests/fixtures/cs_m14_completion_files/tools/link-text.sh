#!/bin/sh
# Stands in for the linker of `csm14-describe`'s compile in one case of
# test_cs_m14_package_build_generates_completion_files: it writes, where the
# binary goes, a text file that is not a program and is not executable, the
# way a binary for another machine cannot be run on the build host. The
# compile before it (Nim's, which writes the entry list) is the real one.
out=""
# A long link line reaches the linker as `@<response file>`: read it too.
args="$*"
for arg in "$@"; do
  case "$arg" in
    @*)
      while IFS= read -r line || [ -n "$line" ]; do
        args="$args $line"
      done < "${arg#@}"
      ;;
  esac
done
# shellcheck disable=SC2086 # split the collected words on purpose
set -- $args
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift ;;
    -o?*) out="${1#-o}" ;;
  esac
  shift
done
if [ -z "$out" ]; then
  echo "link-text: no -o <output> on the command line" >&2
  exit 1
fi
# Shell built-ins only: the compile's PATH names Nim and the C compiler, no
# coreutils. A file a redirection creates is never executable (its mode is
# 0666 under the umask).
printf 'not a program: the completion edge must not need one\n' > "$out"
