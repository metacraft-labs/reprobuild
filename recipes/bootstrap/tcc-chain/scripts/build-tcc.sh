#!/bin/bash
# build-tcc.sh — Phase 6 (R4e): build the bootstrappable tinycc compiler
# from the janneke/tinycc fork using mes (Phase 5) + mes-libc.
#
# Ports nixpkgs's pkgs/os-specific/linux/minimal-bootstrap/tinycc/
# {bootstrappable.nix,common.nix}.  The bootstrappable tinycc fork
# compiles with mes-m2 + libc+tcc.a — unlike upstream tinycc which
# requires a real C compiler.  After this phase, we have a working
# `tcc` binary suitable for compiling C programs in the next milestone.
#
# Inputs (positional):
#   $1 = vendor dir       (contains tinycc-bootstrappable.tar.gz)
#   $2 = mes dir          (Phase 5 output: bin/mes, bin/mes-m2,
#                          bin/mescc.scm, lib/x86_64-mes/{libc-mini.a,
#                          libmescc.a, libc.a, libc+tcc.a, crt1.o},
#                          share/mes-0.27.1/{include,lib})
#   $3 = mescc-tools dir  (Phase 4 output: bin/{M1,M2-Mesoplanet,
#                          blood-elf,hex2,replace, mkdir,cp,chmod,...})
#   $4 = output dir       (will hold bin/tcc + lib/libtcc1.a +
#                          lib/{crt1,crti,crtn}.o + SHA256SUMS)
#
# Required env: SOURCE_DATE_EPOCH=1735689600 LC_ALL=C TZ=UTC.
#
# Build shape (per nixpkgs bootstrappable.nix):
#   Stage A — generate "mes-libc.a" via mes-libc.nix shape:
#     * concat the 130+ libc_gnu_SOURCES into a single libc.c
#     * concat libtcc1_SOURCES into libtcc1.c
#     * cp crt{1,n,i}.c from lib/linux/x86_64-mes-gcc/.
#     We need this libc layout because tinycc-bootstrappable uses
#     `${mes-libc}/lib/libc.c` (a synthetic one-file libc that gets
#     compiled by tcc itself).
#   Stage B — `tinycc-boot-mes`:
#     mes-m2 + mescc.scm compiles tcc.c -> tcc.s -> tcc binary,
#     linked against libc+tcc.a.  This is the FIRST tcc binary.
#   Stage C — `tinycc-boot-mes` libs:
#     use Stage-B tcc to recompile libc.a / libtcc1.a / crt{1,n,i}.o
#     for use by the NEXT stage's tcc -B path.
#   Stage D — Stage 1/2/3/Final tinycc-boot{0,1,2,3,bootstrappable}:
#     each stage rebuilds tcc from itself (the prev stage's tcc), with
#     progressively more features enabled (LONG_LONG, BITFIELD, FLOAT,
#     FLOAT_STUB, SETJMP).
#
# To keep the script manageable AND complete fast enough for the R4
# acceptance gate, we implement Stages A + B + C (the tinycc-boot-mes
# compiler), then for each Stage D step run the same recipe with the
# accumulated -D flags.

set -euo pipefail

: "${SOURCE_DATE_EPOCH:=1735689600}"
: "${LC_ALL:=C}"
: "${TZ:=UTC}"
export SOURCE_DATE_EPOCH LC_ALL TZ

VENDOR="${1:?usage: build-tcc.sh <vendor-dir> <mes-dir> <mescc-tools-dir> <out-dir>}"
MESDIR="${2:?usage: build-tcc.sh <vendor-dir> <mes-dir> <mescc-tools-dir> <out-dir>}"
MESCC_TOOLS="${3:?usage: build-tcc.sh <vendor-dir> <mes-dir> <mescc-tools-dir> <out-dir>}"
OUT="${4:?usage: build-tcc.sh <vendor-dir> <mes-dir> <mescc-tools-dir> <out-dir>}"

VENDOR_ABS="$(cd "$VENDOR" && pwd)"
MES_ABS="$(cd "$MESDIR" && pwd)"
MESCC_TOOLS_ABS="$(cd "$MESCC_TOOLS" && pwd)"
mkdir -p "$OUT"
OUT_ABS="$(cd "$OUT" && pwd)"

# Append mescc-tools to PATH (do NOT prepend — see build-mes.sh).
export PATH="$PATH:$MESCC_TOOLS_ABS/bin"

# Sanity-check mes outputs are present.
for f in bin/mes bin/mes-m2 bin/mescc.scm \
         lib/x86_64-mes/libc-mini.a \
         lib/x86_64-mes/libmescc.a \
         lib/x86_64-mes/libc.a \
         lib/x86_64-mes/libc+tcc.a \
         lib/x86_64-mes/crt1.o \
         share/mes-0.27.1/include \
         share/mes-0.27.1/lib; do
  if [ ! -e "$MES_ABS/$f" ]; then
    echo "[tcc] ERROR: missing mes output $MES_ABS/$f" >&2
    exit 1
  fi
done

if [ ! -f "$VENDOR_ABS/tinycc-bootstrappable.tar.gz" ]; then
  echo "[tcc] ERROR: missing $VENDOR_ABS/tinycc-bootstrappable.tar.gz" >&2
  exit 1
fi

# ---- A3 P4 cache prelude ---------------------------------------------------
_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_repo_root="$(cd "${_script_dir}/../../../.." && pwd)"
# shellcheck source=/dev/null
source "${_repo_root}/recipes/cache/scripts/cache-helper.sh"

if cache_repro_binary_cache_client_bin >/dev/null 2>&1; then
  _tcc_deps=()
  _mes_keyfile="${MES_ABS}/.cache-key.hex"
  _mescc_keyfile="${MESCC_TOOLS_ABS}/.cache-key.hex"
  if [[ -f "${_mes_keyfile}" ]]; then
    _tcc_deps+=( --dep="$(cat "${_mes_keyfile}")" )
  fi
  if [[ -f "${_mescc_keyfile}" ]]; then
    _tcc_deps+=( --dep="$(cat "${_mescc_keyfile}")" )
  fi
  cache_phase_prepare "${BASH_SOURCE[0]}" "${OUT_ABS}" \
    --package-name=tinycc-bootstrappable \
    --package-version=ea3900f6 \
    --toolchain-name=mes \
    --toolchain-version=0.27.1 \
    "${_tcc_deps[@]}"
  echo "[tcc] cache-entry-key=${CACHE_KEY_HEX}"
  echo "${CACHE_KEY_HEX}" > "${OUT_ABS}/.cache-key.hex"
  if [[ "${CACHE_HIT}" == "1" ]]; then
    if [[ -d "${OUT_ABS}/prefix" ]]; then
      cp -a "${OUT_ABS}/prefix/." "${OUT_ABS}/"
      rm -rf "${OUT_ABS}/prefix"
      echo "[cache hit] tcc from cache"
      exit 0
    fi
    rm -rf "${OUT_ABS}/prefix"
  elif [[ "${CACHE_HIT}" == "2" ]]; then
    echo "[tcc] REPRO_CACHE_DRY_RUN=1; skipping build."
    exit 0
  fi
  echo "[tcc] cache miss; proceeding with build."
fi
# ---- /A3 P4 cache prelude --------------------------------------------------

WORK="$(mktemp -d -t reproos-r4e-tcc-XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
echo "[tcc] WORK=$WORK"
echo "[tcc] VENDOR=$VENDOR_ABS"
echo "[tcc] MES=$MES_ABS"
echo "[tcc] OUT=$OUT_ABS"

log() { echo "[tcc] $*"; }

# Phase 5 baked /repro/mes-0.27.1 paths into mes-m2 + mescc.scm.  Restore
# the symlink to point at the persisted mes share dir.  Also stage the
# tmpfs copy for fast mes-m2 reads (the bottleneck in this phase too).
log "restoring /repro/mes-0.27.1 + /repro/nyacc-1.09.1 symlinks"
STAGING="$WORK/staging"
mkdir -p "$STAGING/repro"
log "  staging mes share tree to $STAGING/repro/mes-0.27.1 (tmpfs)"
mkdir -p "$STAGING/repro/mes-0.27.1"
cp -r "$MES_ABS/share/mes-0.27.1/." "$STAGING/repro/mes-0.27.1/"
log "  staging nyacc to $STAGING/repro/nyacc-1.09.1"
mkdir -p "$STAGING/repro/nyacc-1.09.1"
cp -r "$MES_ABS/share/nyacc-1.09.1/." "$STAGING/repro/nyacc-1.09.1/"
log "  staging mes-m2 + mescc.scm to $STAGING/repro/bin"
mkdir -p "$STAGING/repro/bin"
cp "$MES_ABS/bin/mes-m2"   "$STAGING/repro/bin/mes-m2"
cp "$MES_ABS/bin/mes"      "$STAGING/repro/bin/mes"
cp "$MES_ABS/bin/mescc.scm" "$STAGING/repro/bin/mescc.scm"
chmod 0555 "$STAGING/repro/bin/mes-m2" "$STAGING/repro/bin/mes" "$STAGING/repro/bin/mescc.scm"

mkdir -p /repro 2>/dev/null || sudo mkdir -p /repro
rm -rf "/repro/mes-0.27.1" "/repro/nyacc-1.09.1" 2>/dev/null || true
ln -snf "$STAGING/repro/mes-0.27.1"   "/repro/mes-0.27.1"
ln -snf "$STAGING/repro/nyacc-1.09.1" "/repro/nyacc-1.09.1"
if [ ! -d "/repro/mes-0.27.1/include" ]; then
  echo "[tcc] ERROR: /repro/mes-0.27.1 staging symlink failed" >&2
  ls -la /repro/ >&2 || true
  exit 1
fi

# Stage A: build the synthetic mes-libc layout.
TCC_REV=ea3900f6d5e71776c5cfabcabee317652e3a19ee
log "unpacking tinycc-bootstrappable (rev $TCC_REV)"
tar -xzf "$VENDOR_ABS/tinycc-bootstrappable.tar.gz" -C "$WORK"
TCC_SRC="$WORK/tinycc-$TCC_REV"
if [ ! -d "$TCC_SRC" ]; then
  echo "[tcc] ERROR: expected $TCC_SRC after extract; got:" >&2
  ls "$WORK" >&2
  exit 1
fi

MES_SRC_PREFIX="$STAGING/repro/mes-0.27.1"  # tmpfs copy, fast reads
REPLACE="$MESCC_TOOLS_ABS/bin/replace"

# Stage A.1: apply tinycc patches from nixpkgs bootstrappable.nix.
log "patching tinycc source per nixpkgs bootstrappable.nix"
cd "$TCC_SRC"

# Copy the libtcc1.c from mes-libc into lib/.  nixpkgs does this from
# ${mes-libc}/lib/libtcc1.c; in our chain, libtcc1.c is just one file
# under mes share/.
cp "$MES_SRC_PREFIX/lib/libtcc1.c" "$TCC_SRC/lib/libtcc1.c"

# Patch 1: static-link by default.
"$REPLACE" --file libtcc.c --output libtcc.c \
  --match-on 's->ms_extensions = 1;' \
  --replace-with 's->ms_extensions = 1; s->static_link = 1;'

# Patch 2: max_align_t for mes-libc.
"$REPLACE" --file include/stddef.h --output include/stddef.h \
  --match-on 'void *alloca' \
  --replace-with '
typedef union { long double ld; long long ll; } max_align_t;
void *alloca'

# Patch 3: x86_64-gen VLA workaround (alloca is broken in mescc 0.27.1).
"$REPLACE" --file x86_64-gen.c --output x86_64-gen.c \
  --match-on 'char _onstack[nb_args], *onstack = _onstack;' \
  --replace-with 'char *onstack = tcc_malloc(nb_args);'

# Patch 4: abort() is not provided by mescc.
"$REPLACE" --file x86_64-gen.c --output x86_64-gen.c \
  --match-on 'abort();' \
  --replace-with '/* abort(); */'

# Patch 5: mescc bitfield arithmetic workaround.
"$REPLACE" --file x86_64-gen.c --output x86_64-gen.c \
  --match-on 'g(vtop->c.i & (ll ? 63 : 31));' \
  --replace-with 'if (ll) g(vtop->c.i & 63); else g(vtop->c.i & 31);'

# Patch 6: PLT relocation on x86_64.
"$REPLACE" --file tccelf.c --output tccelf.c \
  --match-on 'fill_got(s1);' \
  --replace-with '
{
  fill_got(s1);
  relocate_plt(s1);
}
'

# Stage A.2: build mes-libc (libc.c + libtcc1.c + crt{1,n,i}.c + headers).
# Per nixpkgs libc.nix: concat the first-100 + ldexpl.c, then concat
# rest.  We replicate that here.
log "synthesising mes-libc bundle (libc.c, libtcc1.c, crt*.c)"
MES_LIBC="$WORK/mes-libc"
mkdir -p "$MES_LIBC/lib" "$MES_LIBC/include"

# libtcc1.c — single file (sources.json[x86_64].linux.gcc.libtcc1_SOURCES).
cat "$MES_SRC_PREFIX/lib/libtcc1.c" > "$MES_LIBC/lib/libtcc1.c"

# crt{1,n,i}.c — from lib/linux/x86_64-mes-gcc/.
cp "$MES_SRC_PREFIX/lib/linux/x86_64-mes-gcc/crt1.c" "$MES_LIBC/lib/crt1.c"
cp "$MES_SRC_PREFIX/lib/linux/x86_64-mes-gcc/crtn.c" "$MES_LIBC/lib/crtn.c"
cp "$MES_SRC_PREFIX/lib/linux/x86_64-mes-gcc/crti.c" "$MES_LIBC/lib/crti.c"

# getopt.c (libgetopt source).
cp "$MES_SRC_PREFIX/lib/posix/getopt.c" "$MES_LIBC/lib/libgetopt.c"

# Headers — symlink the mes include dir (it has everything).
ln -s "$MES_SRC_PREFIX/include" "$MES_LIBC/include-link"

# libc.c — concat all 132 libc_gnu_SOURCES (x86_64) into a bundle,
# with ldexpl.c inserted after the first 100 (per nixpkgs libc.nix).
LIBC_GNU_SOURCES_HEAD=(
  lib/mes/__init_io.c
  lib/mes/eputs.c
  lib/mes/oputs.c
  lib/mes/globals.c
  lib/stdlib/exit.c
  lib/linux/x86_64-mes-gcc/_exit.c
  lib/linux/x86_64-mes-gcc/_write.c
  lib/stdlib/puts.c
  lib/string/strlen.c
  lib/ctype/isnumber.c
  lib/mes/abtol.c
  lib/mes/cast.c
  lib/mes/eputc.c
  lib/mes/fdgetc.c
  lib/mes/fdputc.c
  lib/mes/fdputs.c
  lib/mes/fdungetc.c
  lib/mes/itoa.c
  lib/mes/ltoa.c
  lib/mes/ltoab.c
  lib/mes/mes_open.c
  lib/mes/ntoab.c
  lib/mes/oputc.c
  lib/mes/ultoa.c
  lib/mes/utoa.c
  lib/stub/__raise.c
  lib/ctype/isdigit.c
  lib/ctype/isspace.c
  lib/ctype/isxdigit.c
  lib/mes/assert_msg.c
  lib/posix/write.c
  lib/stdlib/atoi.c
  lib/linux/lseek.c
  lib/dirent/__getdirentries.c
  lib/dirent/closedir.c
  lib/dirent/opendir.c
  lib/mes/__assert_fail.c
  lib/mes/__buffered_read.c
  lib/mes/__mes_debug.c
  lib/posix/execv.c
  lib/posix/getcwd.c
  lib/posix/getenv.c
  lib/posix/isatty.c
  lib/posix/open.c
  lib/posix/buffered-read.c
  lib/posix/setenv.c
  lib/posix/wait.c
  lib/stdio/fgetc.c
  lib/stdio/fputc.c
  lib/stdio/fputs.c
  lib/stdio/getc.c
  lib/stdio/getchar.c
  lib/stdio/putc.c
  lib/stdio/putchar.c
  lib/stdio/ungetc.c
  lib/stdlib/calloc.c
  lib/stdlib/free.c
  lib/stdlib/realloc.c
  lib/string/memchr.c
  lib/string/memcmp.c
  lib/string/memcpy.c
  lib/string/memmove.c
  lib/string/memset.c
  lib/string/strcmp.c
  lib/string/strcpy.c
  lib/string/strncmp.c
  lib/posix/raise.c
  lib/linux/access.c
  lib/linux/brk.c
  lib/linux/chdir.c
  lib/linux/chmod.c
  lib/linux/clock_gettime.c
  lib/linux/close.c
  lib/linux/dup.c
  lib/linux/dup2.c
  lib/linux/execve.c
  lib/linux/fcntl.c
  lib/linux/fork.c
  lib/linux/fstat.c
  lib/linux/fsync.c
  lib/linux/_getcwd.c
  lib/linux/getdents.c
  lib/linux/gettimeofday.c
  lib/linux/ioctl3.c
  lib/linux/link.c
  lib/linux/lstat.c
  lib/linux/_open3.c
  lib/linux/malloc.c
  lib/linux/mkdir.c
  lib/linux/nanosleep.c
  lib/linux/pipe.c
  lib/linux/_read.c
  lib/linux/readdir.c
  lib/linux/rename.c
  lib/linux/rmdir.c
  lib/linux/stat.c
  lib/linux/symlink.c
  lib/linux/time.c
  lib/linux/umask.c
  lib/linux/uname.c
  lib/linux/unlink.c
  lib/linux/utimensat.c
)

# After the first 100, nixpkgs inserts ldexpl.c.  See gen-sources.sh.
LIBC_GNU_SOURCES_TAIL=(
  lib/linux/wait4.c
  lib/linux/waitpid.c
  lib/linux/x86_64-mes-gcc/syscall.c
  lib/linux/getpid.c
  lib/linux/kill.c
  lib/ctype/islower.c
  lib/ctype/isupper.c
  lib/ctype/tolower.c
  lib/ctype/toupper.c
  lib/mes/abtod.c
  lib/mes/dtoab.c
  lib/mes/search-path.c
  lib/posix/execvp.c
  lib/stdio/fclose.c
  lib/stdio/fdopen.c
  lib/stdio/ferror.c
  lib/stdio/fflush.c
  lib/stdio/fopen.c
  lib/stdio/fprintf.c
  lib/stdio/fread.c
  lib/stdio/fseek.c
  lib/stdio/ftell.c
  lib/stdio/fwrite.c
  lib/stdio/printf.c
  lib/stdio/remove.c
  lib/stdio/snprintf.c
  lib/stdio/sprintf.c
  lib/stdio/sscanf.c
  lib/stdio/vfprintf.c
  lib/stdio/vprintf.c
  lib/stdio/vsnprintf.c
  lib/stdio/vsprintf.c
  lib/stdio/vsscanf.c
  lib/stdlib/qsort.c
  lib/stdlib/strtod.c
  lib/stdlib/strtof.c
  lib/stdlib/strtol.c
  lib/stdlib/strtold.c
  lib/stdlib/strtoll.c
  lib/stdlib/strtoul.c
  lib/stdlib/strtoull.c
  lib/string/memmem.c
  lib/string/strcat.c
  lib/string/strchr.c
  lib/string/strlwr.c
  lib/string/strncpy.c
  lib/string/strrchr.c
  lib/string/strstr.c
  lib/string/strupr.c
  lib/stub/sigaction.c
  lib/stub/ldexp.c
  lib/stub/mprotect.c
  lib/stub/localtime.c
  lib/stub/putenv.c
  lib/stub/realpath.c
  lib/stub/sigemptyset.c
  lib/x86_64-mes-gcc/setjmp.c
  lib/ctype/isalnum.c
  lib/ctype/isalpha.c
  lib/ctype/isascii.c
  lib/ctype/iscntrl.c
  lib/ctype/isgraph.c
  lib/ctype/isprint.c
  lib/ctype/ispunct.c
  lib/math/ceil.c
  lib/math/fabs.c
  lib/math/floor.c
  lib/mes/fdgets.c
  lib/posix/alarm.c
  lib/posix/execl.c
  lib/posix/execlp.c
  lib/posix/mktemp.c
  lib/posix/pathconf.c
  lib/posix/sbrk.c
  lib/posix/sleep.c
  lib/posix/unsetenv.c
  lib/stdio/clearerr.c
  lib/stdio/feof.c
  lib/stdio/fgets.c
  lib/stdio/fileno.c
  lib/stdio/freopen.c
  lib/stdio/fscanf.c
  lib/stdio/perror.c
  lib/stdio/vfscanf.c
  lib/stdlib/__exit.c
  lib/stdlib/abort.c
  lib/stdlib/abs.c
  lib/stdlib/alloca.c
  lib/stdlib/atexit.c
  lib/stdlib/atof.c
  lib/stdlib/atol.c
  lib/stdlib/mbstowcs.c
  lib/string/bcmp.c
  lib/string/bcopy.c
  lib/string/bzero.c
  lib/string/index.c
  lib/string/rindex.c
  lib/string/strcspn.c
  lib/string/strdup.c
  lib/string/strerror.c
  lib/string/strncat.c
  lib/string/strpbrk.c
  lib/string/strspn.c
  lib/stub/__cleanup.c
  lib/stub/atan2.c
  lib/stub/bsearch.c
  lib/stub/chown.c
  lib/stub/cos.c
  lib/stub/ctime.c
  lib/stub/exp.c
  lib/stub/fpurge.c
  lib/stub/freadahead.c
  lib/stub/frexp.c
  lib/stub/getgrgid.c
  lib/stub/getgrnam.c
  lib/stub/getlogin.c
  lib/stub/getpgid.c
  lib/stub/getpgrp.c
  lib/stub/getpwnam.c
  lib/stub/getpwuid.c
  lib/stub/gmtime.c
  lib/stub/log.c
  lib/stub/mktime.c
  lib/stub/modf.c
  lib/stub/pclose.c
  lib/stub/popen.c
  lib/stub/pow.c
  lib/stub/rand.c
  lib/stub/rewind.c
  lib/stub/setbuf.c
  lib/stub/setgrent.c
  lib/stub/setlocale.c
  lib/stub/setvbuf.c
  lib/stub/sigaddset.c
  lib/stub/sigblock.c
  lib/stub/sigdelset.c
  lib/stub/sigsetmask.c
  lib/stub/sin.c
  lib/stub/sqrt.c
  lib/stub/strftime.c
  lib/stub/sys_siglist.c
  lib/stub/system.c
  lib/stub/times.c
  lib/stub/ttyname.c
  lib/stub/utime.c
  lib/linux/getegid.c
  lib/linux/geteuid.c
  lib/linux/getgid.c
  lib/linux/getppid.c
  lib/linux/getrusage.c
  lib/linux/getuid.c
  lib/linux/ioctl.c
  lib/linux/mknod.c
  lib/linux/readlink.c
  lib/linux/setgid.c
  lib/linux/settimer.c
  lib/linux/setuid.c
  lib/linux/signal.c
  lib/linux/sigprogmask.c
)

# Generate the synthetic libc.c bundle.
first_files=()
for src in "${LIBC_GNU_SOURCES_HEAD[@]}"; do
  first_files+=("$MES_SRC_PREFIX/$src")
done
# Inline our local ldexpl.c (copy of nixpkgs's ldexpl.c).
LDEXPL_C="$WORK/ldexpl.c"
cat > "$LDEXPL_C" <<'EOF'
#include <math.h>

long double
ldexpl (long double arg, int exp)
{
  if (exp > 0)
    do
      arg *= 2;
    while (--exp);
  else if (exp < 0)
    do
      arg /= 2;
    while (++exp);
  return arg;
}
EOF
first_files+=("$LDEXPL_C")

tail_files=()
for src in "${LIBC_GNU_SOURCES_TAIL[@]}"; do
  tail_files+=("$MES_SRC_PREFIX/$src")
done

log "concatenating libc.c bundle (${#first_files[@]} head + ${#tail_files[@]} tail files)"
cat "${first_files[@]}" "${tail_files[@]}" > "$MES_LIBC/lib/libc.c"

# Stage B: build tinycc-boot-mes (Stage-B tcc) via mes-m2 + mescc.scm.
log "Stage B: mes-m2 compiling tcc.c -> tcc.s (this is slow)"
cd "$WORK"
touch config.h  # nixpkgs uses `catm config.h` which makes an empty one.

MES="$STAGING/repro/bin/mes"
MES_M2="$STAGING/repro/bin/mes-m2"
MESCC_SCM="$STAGING/repro/bin/mescc.scm"
# Stage the mes libs on tmpfs too for the link step (drvfs reads would
# bottleneck the linker just like the compiles).  mescc.scm needs BOTH
# libname.a (object archive) AND libname.s (source archive); they live
# side-by-side in MES_ABS/lib/x86_64-mes/.
TMP_MES_LIB="$STAGING/repro/mes-libs/x86_64-mes"
mkdir -p "$TMP_MES_LIB"
for libname in libc-mini libmescc libc libc+tcc; do
  cp "$MES_ABS/lib/x86_64-mes/${libname}.a" "$TMP_MES_LIB/${libname}.a"
  cp "$MES_ABS/lib/x86_64-mes/${libname}.s" "$TMP_MES_LIB/${libname}.s"
done
cp "$MES_ABS/lib/x86_64-mes/crt1.o" "$TMP_MES_LIB/crt1.o"
cp "$MES_ABS/lib/x86_64-mes/crt1.s" "$TMP_MES_LIB/crt1.s"
MES_LIBS_DIR="$TMP_MES_LIB/.."
MES_INCLUDE="$MES_SRC_PREFIX/include"

# Per nixpkgs bootstrappable.nix Stage-B compiler step.
TCC_TARGET=X86_64
TCC_VERSION="0.9.28-unstable-2024-07-07"

log "Stage B compile: mes -e main mescc.scm -- -S -o tcc.s ..."
"$MES" --no-auto-compile -e main "$MESCC_SCM" -- \
  -S \
  -o "$WORK/tcc.s" \
  -I . \
  -D BOOTSTRAP=1 \
  -D HAVE_LONG_LONG=1 \
  -I "$TCC_SRC" \
  -D "TCC_TARGET_${TCC_TARGET}=1" \
  -D "inline=" \
  -D "CONFIG_TCCDIR=\"\"" \
  -D "CONFIG_SYSROOT=\"\"" \
  -D "CONFIG_TCC_CRTPREFIX=\"{B}\"" \
  -D "CONFIG_TCC_ELFINTERP=\"/mes/loader\"" \
  -D "CONFIG_TCC_LIBPATHS=\"{B}\"" \
  -D "CONFIG_TCC_SYSINCLUDEPATHS=\"${TCC_SRC}/include:${MES_LIBC}/include-link\"" \
  -D "TCC_LIBGCC=\"libc.a\"" \
  -D "TCC_LIBTCC1=\"libtcc1.a\"" \
  -D "CONFIG_TCC_LIBTCC1_MES=0" \
  -D "CONFIG_TCCBOOT=1" \
  -D "CONFIG_TCC_STATIC=1" \
  -D "CONFIG_USE_LIBGCC=1" \
  -D "TCC_MES_LIBC=1" \
  -D "TCC_VERSION=\"${TCC_VERSION}\"" \
  -D "ONE_SOURCE=1" \
  "$TCC_SRC/tcc.c" \
  > "$WORK/tcc-stageB-compile.log" 2>&1 || {
    rc=$?
    echo "[tcc] ERROR: Stage-B mescc compile failed (exit $rc); log tail:" >&2
    tail -40 "$WORK/tcc-stageB-compile.log" >&2
    exit "$rc"
  }
log "Stage B compile OK, tcc.s = $(stat -c %s "$WORK/tcc.s") bytes"

log "Stage B link: mes -e main mescc.scm -- -L mes/lib -l c+tcc -o tcc tcc.s"
mkdir -p "$WORK/stageB/bin"
"$MES" --no-auto-compile -e main "$MESCC_SCM" -- \
  -L "$MES_LIBS_DIR" \
  -l c+tcc \
  -o "$WORK/stageB/bin/tcc" \
  "$WORK/tcc.s" \
  > "$WORK/tcc-stageB-link.log" 2>&1 || {
    rc=$?
    echo "[tcc] ERROR: Stage-B mescc link failed (exit $rc); log tail:" >&2
    tail -40 "$WORK/tcc-stageB-link.log" >&2
    exit "$rc"
  }
chmod 0555 "$WORK/stageB/bin/tcc"
log "Stage B link OK, Stage-B tcc = $(stat -c %s "$WORK/stageB/bin/tcc") bytes"

# Smoke: Stage-B tcc -version (just verifies executability).
"$WORK/stageB/bin/tcc" -version 2>&1 | head -3 || true

# Stage C: recompile libc.a / libtcc1.a / crt{1,n,i}.o using Stage-B tcc.
log "Stage C: recompiling libc/libtcc1/crt with Stage-B tcc"
mkdir -p "$WORK/stageB/lib"
TCC_B="$WORK/stageB/bin/tcc"
TCC_CFLAGS="-std=c11"

log "  Stage C: crt1.o / crtn.o / crti.o"
"$TCC_B" $TCC_CFLAGS -c -o "$WORK/stageB/lib/crt1.o" "$MES_LIBC/lib/crt1.c" \
  > "$WORK/tcc-stageC-crt.log" 2>&1 || {
    rc=$?
    echo "[tcc] ERROR: Stage-C crt1 failed (exit $rc); log tail:" >&2
    tail -40 "$WORK/tcc-stageC-crt.log" >&2
    exit "$rc"
  }
"$TCC_B" $TCC_CFLAGS -c -o "$WORK/stageB/lib/crtn.o" "$MES_LIBC/lib/crtn.c" \
  >> "$WORK/tcc-stageC-crt.log" 2>&1
"$TCC_B" $TCC_CFLAGS -c -o "$WORK/stageB/lib/crti.o" "$MES_LIBC/lib/crti.c" \
  >> "$WORK/tcc-stageC-crt.log" 2>&1

log "  Stage C: libtcc1.a"
"$TCC_B" -c -D "TCC_TARGET_${TCC_TARGET}=1" -D HAVE_LONG_LONG=1 \
  -o "$WORK/stageB/lib/libtcc1.o" "$TCC_SRC/lib/libtcc1.c" \
  > "$WORK/tcc-stageC-libtcc1.log" 2>&1 || {
    rc=$?
    echo "[tcc] ERROR: Stage-C libtcc1 failed (exit $rc); log tail:" >&2
    tail -40 "$WORK/tcc-stageC-libtcc1.log" >&2
    exit "$rc"
  }
"$TCC_B" -c -D "TCC_TARGET_${TCC_TARGET}=1" -D HAVE_LONG_LONG=1 \
  -o "$WORK/stageB/lib/va_list.o" "$TCC_SRC/lib/va_list.c" \
  >> "$WORK/tcc-stageC-libtcc1.log" 2>&1
"$TCC_B" -ar cr "$WORK/stageB/lib/libtcc1.a" \
  "$WORK/stageB/lib/libtcc1.o" "$WORK/stageB/lib/va_list.o"

log "  Stage C: libc.a"
"$TCC_B" $TCC_CFLAGS -c -o "$WORK/stageB/lib/libc.o" "$MES_LIBC/lib/libc.c" \
  > "$WORK/tcc-stageC-libc.log" 2>&1 || {
    rc=$?
    echo "[tcc] ERROR: Stage-C libc failed (exit $rc); log tail:" >&2
    tail -40 "$WORK/tcc-stageC-libc.log" >&2
    exit "$rc"
  }
"$TCC_B" -ar cr "$WORK/stageB/lib/libc.a" "$WORK/stageB/lib/libc.o"

log "  Stage C: libgetopt.a"
"$TCC_B" $TCC_CFLAGS -c -o "$WORK/stageB/lib/libgetopt.o" "$MES_LIBC/lib/libgetopt.c" \
  > "$WORK/tcc-stageC-libgetopt.log" 2>&1
"$TCC_B" -ar cr "$WORK/stageB/lib/libgetopt.a" "$WORK/stageB/lib/libgetopt.o"

# Stage D: 4 iterations of tinycc-boot{0,1,2,3} + final tinycc-bootstrappable.
# Each iteration rebuilds tcc using the previous-stage tcc, with
# progressively more features enabled.
#
# Per nixpkgs bootstrappable.nix:
#   tinycc-boot0:  HAVE_LONG_LONG, HAVE_SETJMP
#   tinycc-boot1:  HAVE_BITFIELD, HAVE_LONG_LONG, HAVE_SETJMP
#   tinycc-boot2:  HAVE_BITFIELD, HAVE_FLOAT_STUB, HAVE_LONG_LONG, HAVE_SETJMP
#   tinycc-boot3:  HAVE_BITFIELD, HAVE_FLOAT, HAVE_LONG_LONG, HAVE_SETJMP
#   tinycc-bootstrappable: (same as boot3)
build_tcc_iter() {
  local iter_name="$1" prev_bin="$2" prev_libdir="$3" outdir="$4"
  shift 4
  local build_opts=("$@")  # array of -D options
  log "Stage D iter $iter_name: building tcc using $prev_bin"
  mkdir -p "$outdir/bin" "$outdir/lib"
  cd "$WORK"
  : > config.h  # truncate to empty
  "$prev_bin" \
    -B "$prev_libdir" \
    -g -v \
    -o "$outdir/bin/tcc" \
    -D BOOTSTRAP=1 \
    "${build_opts[@]}" \
    -I . \
    -I "$TCC_SRC" \
    -D "TCC_TARGET_${TCC_TARGET}=1" \
    -D "CONFIG_TCCDIR=\"\"" \
    -D "CONFIG_SYSROOT=\"\"" \
    -D "CONFIG_TCC_CRTPREFIX=\"{B}\"" \
    -D "CONFIG_TCC_ELFINTERP=\"\"" \
    -D "CONFIG_TCC_LIBPATHS=\"{B}\"" \
    -D "CONFIG_TCC_SYSINCLUDEPATHS=\"${TCC_SRC}/include:${MES_LIBC}/include-link\"" \
    -D "TCC_LIBGCC=\"libc.a\"" \
    -D "TCC_LIBTCC1=\"libtcc1.a\"" \
    -D "CONFIG_TCCBOOT=1" \
    -D "CONFIG_TCC_STATIC=1" \
    -D "CONFIG_USE_LIBGCC=1" \
    -D "TCC_MES_LIBC=1" \
    -D "TCC_VERSION=\"${TCC_VERSION}\"" \
    -D "ONE_SOURCE=1" \
    "$TCC_SRC/tcc.c" \
    > "$WORK/tcc-${iter_name}-compile.log" 2>&1 || {
      rc=$?
      echo "[tcc] ERROR: Stage-D iter $iter_name compile failed (exit $rc); log tail:" >&2
      tail -40 "$WORK/tcc-${iter_name}-compile.log" >&2
      exit "$rc"
    }
  chmod 0555 "$outdir/bin/tcc"

  # Rebuild libtcc1.a using this iter's tcc + the buildOptions for
  # libtcc1 (basically just the architecture and HAVE_* defines).
  local libtcc1_opts=("-c" "-D" "TCC_TARGET_${TCC_TARGET}=1")
  # Add HAVE_LONG_LONG (most iters need it), HAVE_FLOAT*, etc per nixpkgs.
  case "$iter_name" in
    boot0|boot1|boot2|boot3|bootstrappable)
      libtcc1_opts+=("-D" "HAVE_LONG_LONG=1") ;;
  esac
  case "$iter_name" in
    boot2)
      libtcc1_opts+=("-D" "HAVE_FLOAT_STUB=1") ;;
    boot3|bootstrappable)
      libtcc1_opts+=("-D" "HAVE_FLOAT=1") ;;
  esac

  log "Stage D iter $iter_name: rebuilding libtcc1.a + libc.a + crt{1,n,i}"
  "$outdir/bin/tcc" "${libtcc1_opts[@]}" -o "$outdir/lib/libtcc1.o" \
    "$TCC_SRC/lib/libtcc1.c" \
    > "$WORK/tcc-${iter_name}-libtcc1.log" 2>&1 || {
      rc=$?
      echo "[tcc] ERROR: Stage-D iter $iter_name libtcc1 failed (exit $rc); log tail:" >&2
      tail -40 "$WORK/tcc-${iter_name}-libtcc1.log" >&2
      exit "$rc"
    }
  "$outdir/bin/tcc" "${libtcc1_opts[@]}" -o "$outdir/lib/va_list.o" \
    "$TCC_SRC/lib/va_list.c" \
    >> "$WORK/tcc-${iter_name}-libtcc1.log" 2>&1
  "$outdir/bin/tcc" -ar cr "$outdir/lib/libtcc1.a" \
    "$outdir/lib/libtcc1.o" "$outdir/lib/va_list.o"

  "$outdir/bin/tcc" $TCC_CFLAGS -c -o "$outdir/lib/crt1.o" "$MES_LIBC/lib/crt1.c" \
    > "$WORK/tcc-${iter_name}-crt.log" 2>&1
  "$outdir/bin/tcc" $TCC_CFLAGS -c -o "$outdir/lib/crtn.o" "$MES_LIBC/lib/crtn.c" \
    >> "$WORK/tcc-${iter_name}-crt.log" 2>&1
  "$outdir/bin/tcc" $TCC_CFLAGS -c -o "$outdir/lib/crti.o" "$MES_LIBC/lib/crti.c" \
    >> "$WORK/tcc-${iter_name}-crt.log" 2>&1
  "$outdir/bin/tcc" $TCC_CFLAGS -c -o "$outdir/lib/libc.o" "$MES_LIBC/lib/libc.c" \
    > "$WORK/tcc-${iter_name}-libc.log" 2>&1 || {
      rc=$?
      echo "[tcc] ERROR: Stage-D iter $iter_name libc failed (exit $rc); log tail:" >&2
      tail -40 "$WORK/tcc-${iter_name}-libc.log" >&2
      exit "$rc"
    }
  "$outdir/bin/tcc" -ar cr "$outdir/lib/libc.a" "$outdir/lib/libc.o"
  "$outdir/bin/tcc" $TCC_CFLAGS -c -o "$outdir/lib/libgetopt.o" "$MES_LIBC/lib/libgetopt.c" \
    > "$WORK/tcc-${iter_name}-libgetopt.log" 2>&1
  "$outdir/bin/tcc" -ar cr "$outdir/lib/libgetopt.a" "$outdir/lib/libgetopt.o"
}

# Stage D iterations.
build_tcc_iter boot0 "$WORK/stageB/bin/tcc" "$WORK/stageB/lib" "$WORK/boot0" \
  "-D" "HAVE_LONG_LONG=1" "-D" "HAVE_SETJMP=1"

build_tcc_iter boot1 "$WORK/boot0/bin/tcc" "$WORK/boot0/lib" "$WORK/boot1" \
  "-D" "HAVE_BITFIELD=1" "-D" "HAVE_LONG_LONG=1" "-D" "HAVE_SETJMP=1"

build_tcc_iter boot2 "$WORK/boot1/bin/tcc" "$WORK/boot1/lib" "$WORK/boot2" \
  "-D" "HAVE_BITFIELD=1" "-D" "HAVE_FLOAT_STUB=1" "-D" "HAVE_LONG_LONG=1" "-D" "HAVE_SETJMP=1"

build_tcc_iter boot3 "$WORK/boot2/bin/tcc" "$WORK/boot2/lib" "$WORK/boot3" \
  "-D" "HAVE_BITFIELD=1" "-D" "HAVE_FLOAT=1" "-D" "HAVE_LONG_LONG=1" "-D" "HAVE_SETJMP=1"

build_tcc_iter bootstrappable "$WORK/boot3/bin/tcc" "$WORK/boot3/lib" "$WORK/bootstrappable" \
  "-D" "HAVE_BITFIELD=1" "-D" "HAVE_FLOAT=1" "-D" "HAVE_LONG_LONG=1" "-D" "HAVE_SETJMP=1"

# Install final tcc + libs.
log "installing final tinycc-bootstrappable artefacts to $OUT_ABS"
mkdir -p "$OUT_ABS/bin" "$OUT_ABS/lib"
cp "$WORK/bootstrappable/bin/tcc"  "$OUT_ABS/bin/tcc"
cp "$WORK/bootstrappable/lib/libtcc1.a" "$OUT_ABS/lib/libtcc1.a"
cp "$WORK/bootstrappable/lib/libc.a"    "$OUT_ABS/lib/libc.a"
cp "$WORK/bootstrappable/lib/libgetopt.a" "$OUT_ABS/lib/libgetopt.a"
cp "$WORK/bootstrappable/lib/crt1.o"    "$OUT_ABS/lib/crt1.o"
cp "$WORK/bootstrappable/lib/crtn.o"    "$OUT_ABS/lib/crtn.o"
cp "$WORK/bootstrappable/lib/crti.o"    "$OUT_ABS/lib/crti.o"
chmod 0555 "$OUT_ABS/bin/tcc"

# Smoke test (R4 acceptance gate).
log "ACCEPTANCE: tcc -o hello hello.c; ./hello (expect exit 42)"
echo 'int main() { return 42; }' > "$WORK/hello.c"
"$OUT_ABS/bin/tcc" -B "$OUT_ABS/lib" -o "$WORK/hello" "$WORK/hello.c" \
  > "$WORK/tcc-smoke.log" 2>&1 || {
    rc=$?
    echo "[tcc] ERROR: smoke compile failed (exit $rc); log tail:" >&2
    tail -40 "$WORK/tcc-smoke.log" >&2
    exit "$rc"
  }
# set -e would abort the script on hello returning non-zero (the test
# return value is exactly the smoke test's signal); capture explicitly.
rc=0
"$WORK/hello" || rc=$?
log "ACCEPTANCE: ./hello exit code = $rc (expected 42)"
if [ "$rc" -ne 42 ]; then
  echo "[tcc] ERROR: acceptance gate FAILED — expected exit 42, got $rc" >&2
  exit 1
fi

# Emit SHA256SUMS.
log "writing SHA256SUMS"
{
  cd "$OUT_ABS"
  printf "# Phase 6 (tinycc-bootstrappable, rev $TCC_REV) outputs sha256s — built %s\n" \
    "$(date -u --date="@$SOURCE_DATE_EPOCH" '+%Y-%m-%d')"
  for f in bin/tcc lib/libtcc1.a lib/libc.a lib/libgetopt.a \
           lib/crt1.o lib/crtn.o lib/crti.o; do
    if [ -f "$f" ]; then
      printf "%-20s %10d  %s\n" "$f" "$(stat -c %s "$f")" "$(sha256sum "$f" | awk '{print $1}')"
    else
      printf "%-20s MISSING\n" "$f"
    fi
  done
} > "$OUT_ABS/SHA256SUMS"
cat "$OUT_ABS/SHA256SUMS"
log "done; tcc binary at $OUT_ABS/bin/tcc"

# ---- A3 P4 cache postlude --------------------------------------------------
if [[ -n "${CACHE_KEY_HEX:-}" ]]; then
  cache_phase_publish "${OUT_ABS}"
fi
# ---- /A3 P4 cache postlude -------------------------------------------------
