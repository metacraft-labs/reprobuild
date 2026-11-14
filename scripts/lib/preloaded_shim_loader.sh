# shellcheck shell=bash
#
# scripts/lib/preloaded_shim_loader.sh — the invariant that keeps the monitor
# shim loadable into a process this repository did not build.
#
# WHAT A PRELOADED LIBRARY IS. Automatic monitoring exports
# `LD_PRELOAD=<…>/build/lib/librepro_monitor_shim.so` into every process a
# build action starts. Those processes are not ours: they are compilers,
# linkers, archivers, shells and package tools that came from somewhere else
# and were linked against whatever C runtime that somewhere else uses. The
# shim is a guest in each of them.
#
# THE RULE THAT FOLLOWS. A guest must not bring its own C runtime. When the
# shim carries a DT_RUNPATH naming a directory that holds `libc.so.6` and its
# satellites, the loader resolves the shim's own `libm` / `librt` / `libdl` /
# `libpthread` OUT OF THAT DIRECTORY — into a process whose `libc.so.6` came
# from somewhere else entirely. glibc's satellite libraries carry symbol
# versions their sibling `libc.so.6` defines, so a `libm.so.6` from one build
# landing beside a `libc.so.6` from another is refused by the loader before the
# program reaches `main`:
#
#   …/bash: …/glibc-A/lib/libc.so.6: version `GLIBC_ABI_DT_X86_64_PLT'
#     not found (required by …/glibc-B/lib/libm.so.6)
#
# and the build action dies with three loader lines and an "execution of an
# external program failed" that names the compiler, not the shim.
#
# The nixpkgs `ld` wrapper adds an rpath entry for every `-L` directory that
# supplies a library the link asked for, and the C runtime's directory always
# is one, so a shim linked with that wrapper acquires this defect BY DEFAULT.
# `NIX_DONT_SET_RPATH=1` on the shim's link (see `scripts/build_apps.sh` and
# the monitor-shim edge in `repro.nim`) is what stops it being added; the
# functions below are what refuses to ship the shim if it ever comes back.
#
# THE SECOND RULE: NO DT_RUNPATH AT ALL. A guest must also not stop its host
# from helping it. Any DT_RUNPATH on the shim, even one naming a directory that
# does not exist, switches off the host program's DT_RPATH for the shim's own
# dependencies, so a program that finds its C runtime through its DT_RPATH (a
# toolchain carrying its own glibc) cannot load the shim at all. Every shim
# built in a nixpkgs dev shell used to carry exactly that: `-rpath $out/lib`
# from stdenv's `NIX_LDFLAGS`, with `$out` the nonexistent
# `<checkout>/outputs/out`. The check for the first rule could not see it,
# because a directory that does not exist provides no C runtime.
# `preload_shim_link_without_rpath` is how the shim is linked;
# `preload_shim_search_path_findings` is the verdict every gate applies.
#
# WHY THIS IS NOT "the two glibcs must be the same". Two different C-runtime
# builds are not automatically a problem — measured on the host this was
# written on, three system tools run on a different glibc store path than the
# toolchain and are perfectly fine, because that build defines the symbol
# version the newer one requires. What decides the outcome is whether the host
# `libc.so.6` defines every version the imposed satellites require. So there
# are two questions here and both are asked:
#
#   * `preload_shim_imposed_runtime_dirs` — STRUCTURAL, and the one that holds
#     BY CONSTRUCTION. Does the shim's RUNPATH name a directory that provides a
#     C runtime at all? If it does not, no host process can ever be handed a
#     foreign one, whatever the two builds happen to be. This is the invariant
#     the fix establishes, and it is decidable from the artifact alone.
#
#   * `preload_shim_loader_conflicts` — the SYMBOL-VERSION comparison, which is
#     what makes the structural rule worth enforcing rather than a style
#     preference. It answers "would this shim actually break this subject",
#     which is the mismatch itself rather than one host's symptom of it. It is
#     also what keeps the gate honest on a host whose glibcs happen to be
#     compatible: on such a host the behavioural evidence is worthless and this
#     comparison is the only thing that still says something.
#
# Sourced from `scripts/build_apps.sh` (which refuses to publish a shim that
# imposes a runtime), `scripts/check_dev_shell_env.sh` (the `just lint` gate)
# and `tests/integration/t_preloaded_monitor_shim_is_loader_inert.nim`.

# The glibc symbol-version tables live next door, in the loader-injection
# section of `dev_shell_overrides.sh`, together with the hard-won `readelf`
# section-heading parsing they depend on. Reused rather than reimplemented: a
# second copy of that parser could agree with the ELF files while disagreeing
# with the gate that ships, which is the one outcome neither file may have.
if ! declare -F dev_shell_glibc_defined_versions >/dev/null 2>&1; then
  # shellcheck source=scripts/lib/dev_shell_overrides.sh
  source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/dev_shell_overrides.sh"
fi

# The shared objects that make up a C runtime on Linux. A RUNPATH directory
# holding ANY of these can hand the host process a second one, so the presence
# of any single name is the finding.
#
# `libc.so.6` is in the list even though it is the one library the loader has
# already mapped by the time a preload object's dependencies are resolved: a
# directory that carries it is a C runtime's own `lib` directory, and that is
# precisely the directory that must not be on a guest's search path. The
# satellites are what actually get resolved through it.
PRELOAD_SHIM_C_RUNTIME_SONAMES=(
  libc.so.6
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

# Whether the ELF tools these functions need are on PATH. Callers report a
# missing tool as a FAILURE with its own remedy rather than skipping: this
# check exists because a shim that imposes a runtime looks exactly like one
# that does not until something reads it, and "we could not look" is how the
# defect lived.
preload_shim_have_elf_tools() {
  command -v patchelf >/dev/null 2>&1 && command -v readelf >/dev/null 2>&1
}

# The DT_RUNPATH / DT_RPATH entries of an ELF file, one per line, in order.
#
# `patchelf --print-rpath` prints either tag, colon-separated, which is what is
# wanted here: DT_RPATH and DT_RUNPATH differ in when the loader consults them,
# not in what they can drag in, and a shim carrying the runtime on the older
# tag is the same defect.
preload_shim_runpath_dirs() {
  local file="$1" raw
  [[ -f "$file" ]] || return 0
  raw="$(patchelf --print-rpath "$file" 2>/dev/null)" || return 0
  [[ -n "$raw" ]] || return 0
  tr ':' '\n' <<<"$raw" | grep -v '^[[:space:]]*$'
}

# The entries of a library's DT_RUNPATH tag ONLY, one per line, in order.
#
# Unlike `preload_shim_runpath_dirs` this separates the two tags, because for a
# PRELOADED library they differ in a way that matters: the presence of a
# DT_RUNPATH on the shim — whatever it names, even a directory that does not
# exist — switches off the HOST PROGRAM's DT_RPATH for the shim's own
# dependencies. glibc's loader consults the requesting object's DT_RPATH and
# then its loaders' DT_RPATHs only when the requesting object has no
# DT_RUNPATH (the search order in ld.so(8),
# https://man7.org/linux/man-pages/man8/ld.so.8.html, and `_dl_map_object` in
# glibc's elf/dl-load.c, which walks the loader chain's DT_RPATHs only under
# `loader->l_info[DT_RUNPATH] == NULL`, and then the executable's). A program
# whose libraries come from a C runtime of its own — its PT_INTERP and
# DT_RPATH rewritten to point at that runtime, the shape of a toolchain realized into a store with its sysroot
# glibc — then resolves the shim's `libm.so.6` & co. against the shim's
# RUNPATH and that loader's compiled-in defaults alone, finds nothing, and
# dies before `main`:
#
#   ar: error while loading shared libraries: libm.so.6: cannot open shared
#     object file: No such file or directory
#
# So for the shim ANY DT_RUNPATH entry is a defect, not just one that names a
# C runtime; `preload_shim_imposed_runtime_dirs` below cannot see this case,
# because a directory that does not exist provides nothing. Read with
# `readelf -d`, which names the tag; `patchelf --print-rpath` prints either.
preload_shim_runpath_tag_entries() {
  local file="$1" line raw
  [[ -f "$file" ]] || return 0
  while IFS= read -r line; do
    case "$line" in
      *"(RUNPATH)"*"Library runpath: ["*"]"*)
        raw="${line#*Library runpath: [}"
        raw="${raw%]*}"
        tr ':' '\n' <<<"$raw" | grep -v '^[[:space:]]*$'
        ;;
    esac
  done < <(LC_ALL=C readelf -d -W "$file" 2>/dev/null)
  return 0
}

# Run "$@" — a command that links the preload shim — with no rpath of the
# linker wrapper's making.
#
# Two nixpkgs mechanisms put an rpath on every library linked in a dev shell,
# and the shim must carry neither (see `preload_shim_runpath_tag_entries` for
# why ANY runpath breaks it):
#
#   * the `ld` wrapper adds an entry for every `-L` directory that supplied a
#     library, which always includes the C runtime's own `lib` directory.
#     `NIX_DONT_SET_RPATH=1` switches that off.
#   * stdenv's setup (`pkgs/stdenv/generic/setup.sh`, the `NIX_NO_SELF_RPATH`
#     block) puts `-rpath $out/lib` into `NIX_LDFLAGS` when the shell is
#     entered. In `nix develop`, `$out` is `<checkout>/outputs/out`, so every
#     shim built from a dev shell came out with a DT_RUNPATH naming a
#     directory of the build host that does not exist. `NIX_DONT_SET_RPATH`
#     does not touch it: it is an explicit linker argument, not one the
#     wrapper derives. `NIX_NO_SELF_RPATH` is read only when the shell is set
#     up, which is too late to help here.
#
# The shim's DT_NEEDED is the C runtime and nothing else, which the compiler
# driver locates on its own, so the link needs nothing that `NIX_LDFLAGS`
# carries: every `NIX_LDFLAGS*` variable (the plain one and the role-salted
# `NIX_LDFLAGS_<target>` / `_FOR_TARGET` / `_BEFORE` spellings the wrapper also
# reads) is removed from the link's environment. Inert under a toolchain that
# reads none of these variables; the artifact checks in this file, not this
# function, are the guarantee. `repro.nim`'s monitor-shim edge applies the same
# rule to the engine-built shim (`shimLinkEnvironment`).
#
# The names come from bash's `${!prefix@}` expansion, not `compgen -e`: the
# bash a nixpkgs dev shell provides is built without programmable completion,
# so `compgen` does not exist there, and the first version of this function
# silently removed nothing in exactly the shell it exists for.
#
# The loop variable is deliberately not called `name`: a dev shell EXPORTS
# `name` (the derivation's), a function-local of that name stays exported, and
# the link would then run with the shell's `name` overwritten.
preload_shim_link_without_rpath() {
  local -a unset_args=()
  local ldflags_var
  for ldflags_var in ${!NIX_LDFLAGS@}; do
    unset_args+=(-u "$ldflags_var")
  done
  env ${unset_args[@]+"${unset_args[@]}"} NIX_DONT_SET_RPATH=1 "$@"
}

# Every way a built shim's search path is wrong for a preloaded library, as
# `kind<TAB>detail` rows; empty for a shim that is inert. The kinds:
#
#   runpath<TAB><dir>                  any DT_RUNPATH entry (see above)
#   runtime<TAB><dir><TAB><sonames>    an RPATH/RUNPATH dir providing a C runtime
#
# This is the verdict the gates on the published shim apply
# (`scripts/build_apps.sh`, and `scripts/run_tests.sh` before and after the
# engine's own shim edge) and the one
# `tests/integration/t_preloaded_monitor_shim_carries_no_runpath.nim` asserts,
# so that no build path is checked by a weaker rule than another. The
# `just lint` gate (`scripts/check_dev_shell_env.sh`) applies the same two
# rules through the two listers it is built from. A pure lister, like
# `preload_shim_imposed_runtime_dirs`: always returns 0.
preload_shim_search_path_findings() {
  local file="$1" dir rest
  [[ -f "$file" ]] || return 0
  while IFS= read -r dir; do
    [[ -n "$dir" ]] || continue
    printf 'runpath\t%s\n' "$dir"
  done < <(preload_shim_runpath_tag_entries "$file")
  while IFS=$'\t' read -r dir rest; do
    [[ -n "$dir" ]] || continue
    printf 'runtime\t%s\t%s\n' "$dir" "$rest"
  done < <(preload_shim_imposed_runtime_dirs "$file")
  return 0
}

# Print `preload_shim_search_path_findings` for a human, on stderr, with the
# remedy. Shared by every gate so the explanation cannot drift between them.
preload_shim_report_search_path_findings() {
  local shim="$1" findings="$2" kind dir sonames
  echo "" >&2
  echo "monitor shim: ${shim} has a search path a preloaded library must not have:" >&2
  while IFS=$'\t' read -r kind dir sonames; do
    [[ -n "$kind" ]] || continue
    case "$kind" in
      runpath)
        echo "  DT_RUNPATH ${dir}" >&2 ;;
      runtime)
        echo "  carries a C runtime on its own search path: ${dir}" >&2
        echo "      provides: ${sonames}" >&2 ;;
    esac
  done <<EOF
${findings}
EOF
  echo "  This library is LD_PRELOADed into processes built elsewhere, so its C" >&2
  echo "  runtime dependencies must resolve through the process that loads it." >&2
  echo "  Any DT_RUNPATH on it switches off that process's DT_RPATH for them, so a" >&2
  echo "  program on a C runtime of its own dies before main ('libm.so.6: cannot" >&2
  echo "  open shared object file'); a directory that provides a C runtime hands" >&2
  echo "  the process a second one. Remedy: link the shim through" >&2
  echo "  preload_shim_link_without_rpath (scripts/lib/preloaded_shim_loader.sh)," >&2
  echo "  or shimLinkEnvironment for the repro.nim edge; do not relax this check." >&2
}

# The RUNPATH entries of a preloaded library that would hand a host process a C
# runtime, as `dir<TAB>soname[,soname…]` rows. Prints nothing for a library that
# is inert, which is the state this repository ships.
#
# A pure lister: it always returns 0 and the EMPTINESS of its output is the
# verdict. Deliberate — it is read through `< <(…)` and `$(…)` from scripts
# running under `set -e`, where a status nobody can see would either be lost or
# abort the caller, and a listing that means "clean" only when a status
# survived the pipeline is a listing that will one day mean something else.
#
# The directory is resolved through `$ORIGIN` where the library uses it, since
# an `$ORIGIN`-relative entry pointing at a runtime is the same finding wearing
# a different spelling.
preload_shim_imposed_runtime_dirs() {
  local file="$1" dir soname sonames
  [[ -f "$file" ]] || return 0
  local origin
  origin="$(cd -- "$(dirname -- "$file")" && pwd)"
  while read -r dir; do
    [[ -n "$dir" ]] || continue
    dir="${dir//\$ORIGIN/$origin}"
    dir="${dir//\$\{ORIGIN\}/$origin}"
    [[ -d "$dir" ]] || continue
    sonames=""
    for soname in "${PRELOAD_SHIM_C_RUNTIME_SONAMES[@]}"; do
      if [[ -e "$dir/$soname" ]]; then
        sonames="${sonames:+$sonames,}$soname"
      fi
    done
    [[ -n "$sonames" ]] || continue
    printf '%s\t%s\n' "$dir" "$sonames"
  done < <(preload_shim_runpath_dirs "$file")
  return 0
}

# The C-runtime store prefixes a preloaded library imposes, one per line.
#
# Only prefixes the version machinery can read are printed: a directory that
# provides a runtime but is not a recognisable glibc store path (a
# `/usr/lib`-style path, a build tree) cannot be version-compared, and
# `preload_shim_imposed_runtime_dirs` above is what reports THOSE. Splitting
# them keeps the version comparison from silently passing over the case it
# cannot evaluate.
preload_shim_imposed_glibcs() {
  local file="$1" dir _sonames
  while IFS=$'\t' read -r dir _sonames; do
    [[ -n "$dir" ]] || continue
    _dev_shell_glibc_prefixes "$dir"
  done < <(preload_shim_imposed_runtime_dirs "$file") | sort -u
}

# Would this shim break these subjects? One row per finding:
#
#   conflict<TAB>subject<TAB>subject-glibc<TAB>runpath-dir<TAB>imposed-glibc<TAB>missing-versions
#   unreadable<TAB>glibc-prefix<TAB>which
#
# Returns 1 when there is at least one row of either kind.
#
# `unreadable` is a finding and not a silent skip for the same reason it is one
# in the dev-shell check: every comparison here is "the subject's libc does not
# define X", so a libc whose version table could not be read presents as a libc
# that defines NOTHING — a conflict against every imposed runtime, with a
# missing-list naming every version there is. That is indistinguishable from a
# real finding to whoever reads the output.
#
# A subject with no store interpreter (a script, a static binary, a non-nix
# host) is passed over in silence: nothing here can say anything about it, and
# saying nothing is more honest than either verdict.
preload_shim_loader_conflicts() {
  local shim="$1"
  shift
  local -a imposed=()
  mapfile -t imposed < <(preload_shim_imposed_glibcs "$shim")
  [[ ${#imposed[@]} -gt 0 ]] || return 0

  local subject host glibc dir sonames missing found=0 rc
  local -A defined_cache=() required_cache=() unreadable=() origin_of=()
  while IFS=$'\t' read -r dir sonames; do
    [[ -n "$dir" ]] || continue
    while read -r glibc; do
      [[ -n "$glibc" ]] || continue
      origin_of["$glibc"]="$dir"
    done < <(_dev_shell_glibc_prefixes "$dir")
  done < <(preload_shim_imposed_runtime_dirs "$shim")

  for subject in "$@"; do
    [[ -f "$subject" ]] || continue
    host="$(dev_shell_elf_glibc "$subject")"
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
    for glibc in "${imposed[@]}"; do
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
      printf 'conflict\t%s\t%s\t%s\t%s\t%s\n' \
        "$subject" "$host" "${origin_of[$glibc]:-$glibc/lib}" "$glibc" \
        "$missing"
      found=1
    done
  done
  return $((found == 0 ? 0 : 1))
}

# Every C-runtime store prefix on this machine that carries a `lib/libc.so.6`,
# one per line.
#
# The `-glibc-<digit>` shape is not cosmetic: it is the shape
# `_dev_shell_glibc_prefixes` recognises, and everything downstream compares
# against what that function extracts. Relaxing it to a bare `-glibc-` picks up
# the bootstrap runtime — a real libc whose satellites require `GLIBC_2.0`,
# which a modern libc genuinely cannot satisfy — so the pair search below would
# hand back a "conflict" the checks are right to ignore. `getent-glibc-…` and
# `locale-glibc-…` are excluded by the `lib/libc.so.6` requirement.
#
# Restricted to runtimes of the RUNNING machine's ELF class and architecture.
# This store carries an i686 glibc beside the x86-64 one, and the two define
# genuinely different symbol-version sets, so an unfiltered search reports them
# as an "incompatible pair" within seconds — a pair no process could ever be in,
# because no loader would ever put them together. A gate fabricated from it
# would still exercise the comparison, and would still be describing something
# that cannot happen, which is the kind of evidence that survives review once
# and is quietly wrong forever after.
_preload_shim_elf_arch() {
  local file="$1" bytes
  [[ -r "$file" ]] || return 0
  # e_ident[EI_CLASS] at offset 4, e_machine at offsets 18-19. Read as bytes so
  # this needs no readelf and no endianness assumption beyond ELF's own.
  bytes="$(od -An -t u1 -j 4 -N 1 "$file" 2>/dev/null)$(
    od -An -t u1 -j 18 -N 2 "$file" 2>/dev/null)" || return 0
  printf '%s\n' "$(tr -s ' ' <<<"$bytes" | tr -d '\n')"
}

preload_shim_store_glibc_prefixes() {
  local store="${NIX_STORE:-/nix/store}" dir host
  [[ -d "$store" ]] || return 0
  # `/proc/self/exe` is the bash running this function: the one ELF on the
  # machine that is certainly of the architecture everything here is about.
  host="$(_preload_shim_elf_arch /proc/self/exe)"
  for dir in "$store"/*-glibc-[0-9]*; do
    [[ -d "$dir" ]] || continue
    [[ -f "$dir/lib/libc.so.6" ]] || continue
    if [[ -n "$host" ]]; then
      [[ "$(_preload_shim_elf_arch "$dir/lib/libc.so.6")" == "$host" ]] ||
        continue
    fi
    printf '%s\n' "$dir"
  done
}

# Search this machine for a REAL pair of C runtimes that cannot share a
# process: one whose `libc.so.6` fails to define a symbol version the other's
# satellite libraries require. Prints, in order:
#
#   examined<TAB><count>          runtimes considered
#   readable<TAB><count>          …of which the version table could be read
#   pair<TAB><older><TAB><newer><TAB><missing,…>   at most one, if found
#
# This exists so a gate can FABRICATE the defect out of real files instead of
# asserting against whichever runtimes a given host's toolchain happens to
# carry. A gate of the latter kind passes on any host where the two happen to
# be compatible — which is precisely the state that let this defect ship — and
# stops describing the invariant the moment a pin moves.
#
# `examined` and `readable` are printed rather than kept private because the
# difference between them is load-bearing: a caller that finds no pair among
# runtimes whose tables it could not read has learnt nothing, and must say so
# rather than report a clean bill of health.
preload_shim_find_incompatible_glibc_pair() {
  local -a prefixes=()
  mapfile -t prefixes < <(preload_shim_store_glibc_prefixes)
  printf 'examined\t%d\n' "${#prefixes[@]}"

  local p readable=0
  local -A defined=() required=()
  for p in ${prefixes[@]+"${prefixes[@]}"}; do
    defined["$p"]="$(dev_shell_glibc_defined_versions "$p" || true)"
    required["$p"]="$(dev_shell_glibc_required_versions "$p" || true)"
    [[ -n "${defined[$p]}" ]] && readable=$((readable + 1))
  done
  printf 'readable\t%d\n' "$readable"

  local older newer missing
  for older in ${prefixes[@]+"${prefixes[@]}"}; do
    [[ -n "${defined[$older]}" ]] || continue
    for newer in ${prefixes[@]+"${prefixes[@]}"}; do
      [[ "$older" != "$newer" ]] || continue
      [[ -n "${required[$newer]}" ]] || continue
      missing="$(comm -23 \
        <(printf '%s\n' "${required[$newer]}" | grep -v '^$' | sort -u) \
        <(printf '%s\n' "${defined[$older]}" | grep -v '^$' | sort -u) |
        paste -sd, -)"
      [[ -n "$missing" ]] || continue
      printf 'pair\t%s\t%s\t%s\n' "$older" "$newer" "$missing"
      return 0
    done
  done
  return 0
}

# The compiler drivers on this machine that an imposing shim would actually
# break, as `driver<TAB>interpreter<TAB>runtime<TAB>missing,…` rows.
#
# WHY THIS IS A SEARCH AND NOT A CONSTANT. The process that has to survive the
# preload is usually not the compiler: a nixpkgs `gcc` is a shell script, so
# the process is its `#!` INTERPRETER, and that interpreter is linked against
# whichever C runtime built the wrapper — routinely not the one anything else
# here was built against. Naming one wrapper would make a gate about this host.
#
# "Would break" is decided the same way everything else here is decided: a
# driver is listed when its own runtime fails to define a symbol version that
# SOME runtime present on this machine requires — i.e. when there exists a shim
# that could be built here which this driver could not survive. A driver on a
# runtime that satisfies everything present is not listed, and that is not an
# oversight: it is a driver about which a preload proves nothing.
#
# The rows are the subjects a behavioural gate should run under the shim, and
# the reason a gate can say something on a host whose toolchains all agree —
# there, the list is empty and the gate says so instead of passing vacuously.
preload_shim_vulnerable_toolchain_wrappers() {
  local store="${NIX_STORE:-/nix/store}"
  local -a prefixes=()
  mapfile -t prefixes < <(preload_shim_store_glibc_prefixes)
  [[ ${#prefixes[@]} -gt 0 ]] || return 0

  local p all_required=""
  local -A defined=()
  for p in "${prefixes[@]}"; do
    defined["$p"]="$(dev_shell_glibc_defined_versions "$p" || true)"
    all_required+="$(dev_shell_glibc_required_versions "$p" || true)"$'\n'
  done
  all_required="$(printf '%s\n' "$all_required" | grep -v '^$' | sort -u)"

  local -A missing_for=()
  for p in "${prefixes[@]}"; do
    [[ -n "${defined[$p]}" ]] || continue
    missing_for["$p"]="$(comm -23 \
      <(printf '%s\n' "$all_required") \
      <(printf '%s\n' "${defined[$p]}" | grep -v '^$' | sort -u) |
      paste -sd, -)"
  done

  local driver shebang interp runtime seen_runtime
  local -A reported=()
  for driver in "$store"/*-gcc-wrapper-*/bin/gcc \
    "$store"/*-clang-wrapper-*/bin/clang; do
    [[ -f "$driver" ]] || continue
    IFS= read -r shebang <"$driver" 2>/dev/null || continue
    [[ "$shebang" == '#!'* ]] || continue
    interp="${shebang#\#!}"
    interp="${interp#"${interp%%[![:space:]]*}"}"
    interp="${interp%% *}"
    [[ -n "$interp" && -f "$interp" ]] || continue
    runtime="$(dev_shell_elf_glibc "$interp")"
    [[ -n "$runtime" ]] || continue
    [[ -n "${missing_for[$runtime]:-}" ]] || continue
    # One representative per runtime: a host carries a dozen wrappers on three
    # runtimes, and running twelve subprocesses to learn three things is noise
    # in a gate somebody has to read.
    seen_runtime="${reported[$runtime]:-}"
    [[ -z "$seen_runtime" ]] || continue
    reported["$runtime"]=1
    printf '%s\t%s\t%s\t%s\n' \
      "$driver" "$interp" "$runtime" "${missing_for[$runtime]}"
  done
}

# The C compiler drivers a build action started by this engine can end up
# running, resolved on PATH, one absolute path per line.
#
# These are the SUBJECTS of the version comparison, and they are the right ones
# for an unglamorous reason: on a nixpkgs host `gcc` is a bash script, so the
# process that actually has to survive the preload is its INTERPRETER, and that
# interpreter is linked against whichever C runtime built the wrapper — which
# is routinely not the one the shim was linked against. Every `#!`-line
# interpreter is therefore resolved and reported alongside the driver itself.
preload_shim_toolchain_subjects() {
  local name path shebang interp
  for name in cc gcc c++ g++ clang clang++ ld; do
    path="$(command -v "$name" 2>/dev/null)" || continue
    [[ -n "$path" ]] || continue
    path="$(readlink -f "$path" 2>/dev/null || printf '%s' "$path")"
    printf '%s\n' "$path"
    IFS= read -r shebang <"$path" 2>/dev/null || continue
    [[ "$shebang" == '#!'* ]] || continue
    interp="${shebang#\#!}"
    interp="${interp#"${interp%%[![:space:]]*}"}"
    interp="${interp%% *}"
    [[ -n "$interp" && -f "$interp" ]] && printf '%s\n' "$interp"
  done | sort -u
}
