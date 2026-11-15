#!/usr/bin/env bash
# Write the dependency list a test checks a helper binary against
# (repro_test_support/fresh_binary; §13 decisions 65 and its round-6
# amendment in the ReproOS Add-On Mode spec), at
# <build>/nimcache/<name>/<name>.deps:
#
#   binary-sha256 <sha256 of <build>/bin/<name>>
#   module  <path>    every Nim module and included file (nim --genDeps)
#   csource <path>    every C file compiled with {.compile.} (Nim's record)
#   header  <path>    every header those C files include
#   read    <path>    every other file the compiler read: staticRead and
#                     slurp targets, what staticExec's commands read, and
#                     a workspace binary a staticExec command executed
#   listing <sha256> <dir>
#                     a directory the compiler or a staticExec command
#                     listed (getdents), with the sha256 of the names of
#                     its entries that can change what the compiler
#                     resolves (Nim sources, .nimble/.nims, nim.cfg,
#                     <project>.nim.cfg, nimble.paths, subdirectories;
#                     never .nimcache, build, .git, result, .direnv,
#                     .repro, nimcache, htmldocs, test-logs), sorted
#                     bytewise and joined by newlines: a changed listing
#                     refuses the binary (§13 decisions 80, 111, 114 and
#                     115). Besides the directories traced, every
#                     directory on the compiler's search path is listed
#                     (an absent one as the digest of no names), and in
#                     each of them the directories an import found
#                     elsewhere would be looked up in (decision 115 (A))
#   listing-full <sha256> <dir>
#                     as `listing`, for a directory a later component of
#                     an import path is looked up in: the fixed list counts
#                     there (a `build/` below `pkgx/` shadows
#                     `import pkgx/build/m`), so only an import's first
#                     component escapes it (round 12)
#   configs <sha256> <dir>
#                     the entry's directory and each of its parents up to
#                     /, with the sha256 of the names of its nim.cfg,
#                     config.nims and *.nims files: Nim reads the first
#                     two in every parent directory of the project
#                     (decision 115 (A)), so a new one refuses the binary
#   configs-probed <sha256> <dir>
#                     as `configs`, for a directory that cannot be listed
#                     (execute-only): the digest covers which of nim.cfg
#                     and config.nims exist there, looked up by name as
#                     Nim does (round 12)
#   user-config skipped|read
#                     whether the binary was built with --skipUserCfg;
#                     fresh_binary refuses "read" (§13 decision 142)
#
# Every `searchpath` and listed search directory is absolute: a relative
# --path is resolved against the directory the compiler ran in (round 12).
#   listing-filter <name>
#                     which entries the digests count ("resolution"; a
#                     falsifier run writes another), so fresh_binary
#                     digests the same way
#
# Each path is written with every backslash, control byte (a newline) and
# non-ASCII byte as \xNN, so a path is always one line; fresh_binary
# decodes it to the exact bytes of the name.
#
# Not recorded (§13 decisions 74 and 80): existence checks -- stat,
# access, `test -f`, fileExists. The Nim compiler's own module search makes
# many of them (one per search path per import); a module the search found
# is recorded as a module, and the directories the search probes and the
# config files it probes above the project are recorded as listings and
# configs lines (decision 115 (A)). A staticExec command whose output
# depends only on whether a file exists is the residual.
#
# Paths under /nix/store, /proc, /sys, /dev, /etc and /run, and the build
# directory, are left out (immutable, or not sources). Of what strace sees,
# only files in the directory the script runs from and its siblings (the
# workspace) count, outside any .git directory: a config.nims probe of a
# sibling's git metadata, the user's git config and shared caches are not
# sources of the binary.
#
#   scripts/write_helper_deps.sh <name> <entry.nim> [nim flags...]
#
# Pass the flags the binary was built with. How it works: nim's --genDeps
# (an alias of --genScript) runs the compiler's front end without
# compiling or linking, in a nimcache of its own, and writes
# <module>.deps. That run is traced with `strace -ff -y -xx` (one trace
# per process, each open's resolved path, every string as \xNN bytes),
# the only way to see what Nim does not record anywhere: staticRead
# targets, the files a staticExec command reads, the binaries it executes
# (execve) and the directories it lists (getdents). A traced workspace
# path that does not decode to a file that exists fails the run: no list
# is written (fail closed). So does a trace the writer cannot read: a line
# of a traced syscall that succeeded but is not in the -xx form it parses,
# or a trace without the compiler's own open of the entry module (the
# positive control). Each {.compile.} C file is compiled again with
# the C compiler's own depfile (-MD), which names its headers. The list starts with the sha256 of the binary it describes, and
# fresh_binary refuses a list written for another binary.
#
# The published list is removed first. A run that fails, for any reason,
# leaves NO list, and a test then refuses the binary. strace is required,
# from $REPRO_STRACE or PATH, and the one used is printed (stderr). It is
# a build-host tool, declared in repro.nim's `nativeBuildDeps:`: in
# `repro build .#apps` the edge's PATH carries the strace that declaration
# resolved, and the flake's dev shell (where scripts/build_apps.sh and the
# Nim 2.2.4 lane run) carries its pinned strace. Path mode resolves a
# nativeBuildDeps tool from the invoking PATH, so a build outside the dev
# shell uses the host's strace (as it does the host's gcc and python3).
# Without one nothing is written. strace is Linux only, so on other hosts
# this exits 1 and the guarded helpers' tests refuse the binary.
#
# REPRO_TEST_BUILD_DIR names another build directory (the Nim 2.2.4
# lane's). WRITE_HELPER_DEPS_MUTATION selects a falsifier: keep-old-list
# (the published list is left in place on failure), single-trace (one
# trace for every process, so a syscall split by another process's is
# lost), relative-to-script-dir (a traced path resolved against this
# script's directory, not the opening process's), list-for-earlier-binary
# (the list names another build's sha256), text-paths (strace's escaped
# strings taken literally, without -xx), no-execve (executed binaries not
# recorded), no-listing (listed directories not recorded),
# drop-unresolved (a traced path that does not decode to a file is
# skipped, not fatal), accept-unparsed (a trace the writer cannot read,
# or one without the entry module's open, yields a list anyway),
# suffix-is-failure (a successful line with text after its fd path, such
# as strace's `(deleted)`, is skipped as a failed syscall),
# deleted-is-unparsed (an open strace prints `(deleted)` -- an O_TMPFILE
# file, say -- is refused as unparseable rather than read),
# listing-digests-every-entry (round 8's digest of every name),
# listing-skips-subdirectories, listing-skips-project-cfg and
# listing-skips-nim-cfg (decision 114's rules, one each), no-parent-listings
# (the listings of the entry's parent directories, where a parent nim.cfg
# sits, not recorded), no-parent-configs (no `configs` lines: a config
# file above the package root not recorded), no-search-listings (search
# directories the compiler never listed not recorded; both decision 115
# (A)), listing-counts-tool-dirs (decision 114's fixed list without 115
# (B)'s tool directories), import-listings-exclude-tool-dirs (an import
# path's later components digested without the fixed list counted),
# configs-fail-unreadable (a parent that cannot be listed fails the list,
# as in round 11), relative-search-paths (a relative --path recorded as
# given). A file
# <build>/nimcache/<name>/write-helper-deps.mutation selects one too, for
# a run inside a graph edge, whose environment the engine sets; it is
# read only when present.
set -euo pipefail
name="${1:?usage: write_helper_deps.sh <name> <entry.nim> [nim flags...]}"
entry="${2:?usage: write_helper_deps.sh <name> <entry.nim> [nim flags...]}"
shift 2
build="${REPRO_TEST_BUILD_DIR:-build}"
published="${build}/nimcache/${name}/${name}.deps"
mutation_file="${build}/nimcache/${name}/write-helper-deps.mutation"
if [ -z "${WRITE_HELPER_DEPS_MUTATION:-}" ] && [ -f "${mutation_file}" ]; then
  WRITE_HELPER_DEPS_MUTATION="$(cat "${mutation_file}")"
  echo "write_helper_deps: FALSIFYING RUN: ${WRITE_HELPER_DEPS_MUTATION} (from ${mutation_file})" >&2
fi
export WRITE_HELPER_DEPS_MUTATION="${WRITE_HELPER_DEPS_MUTATION:-}"
# Was the binary built with --skipUserCfg (§13 decision 142)? The flags
# given here are the ones it was built with.
WRITE_HELPER_DEPS_USER_CONFIG=read
for a in "$@"; do
  case "$a" in
    --skipUserCfg|--skipUserCfg:on|--skipUserCfg:true) WRITE_HELPER_DEPS_USER_CONFIG=skipped ;;
  esac
done
export WRITE_HELPER_DEPS_USER_CONFIG
if [ "${WRITE_HELPER_DEPS_MUTATION:-}" != "keep-old-list" ]; then
  rm -f "${published}"
fi
binary="${build}/bin/${name}"
[ -f "${binary}" ] || binary="${binary}.exe"
if [ ! -f "${binary}" ]; then
  echo "write_helper_deps: no ${build}/bin/${name} to describe" >&2
  exit 1
fi
strace_bin="${REPRO_STRACE:-$(command -v strace || true)}"
if [ -z "${strace_bin}" ]; then
  echo "write_helper_deps: strace is required (staticRead inputs and C headers are seen only through it); no list written. Run inside the dev shell (nix develop), which carries it, or set REPRO_STRACE" >&2
  exit 1
fi
echo "write_helper_deps: strace ${strace_bin} ($(readlink -f "${strace_bin}" 2>/dev/null || echo "${strace_bin}"))" >&2
cache="${build}/nimcache/${name}-deps"
rm -rf "${cache}"
mkdir -p "${cache}" "${build}/nimcache/${name}"
# One trace file per process (-ff), so no syscall is split across lines
# by another process's, and -y, so each successful open prints the
# absolute path of the file it opened (`= 3</abs/path>`): a staticExec
# command runs in the calling module's directory (Nim's gorgeimpl), and
# its relative opens resolve there, not here.
if [ "${WRITE_HELPER_DEPS_MUTATION:-}" = single-trace ]; then
  # FALSIFIER: one trace for every process, as before round 7.
  "${strace_bin}" -f -qq -e trace=open,openat,openat2 -o "${cache}/front.trace" \
    nim c --hints:off --warnings:off "$@" --genDeps:on \
      --nimcache:"${cache}" --out:"${cache}/${name}" "${entry}"
else
  # -xx: every string, -y paths included, as \xNN bytes, so a name with
  # non-ASCII bytes, `<`, `>`, `\` or a newline decodes without ambiguity.
  # execve/execveat: a workspace binary a staticExec command runs.
  # getdents/getdents64: a directory it lists (§13 decision 80).
  # chdir/fchdir/clone/fork: each process's working directory, for an
  # execve by a relative path.
  if [ "${WRITE_HELPER_DEPS_MUTATION:-}" = text-paths ]; then
    # FALSIFIER: strace's escaped text taken literally, as before round 8.
    "${strace_bin}" -ff -y -qq -e trace=open,openat,openat2 -o "${cache}/front.trace" \
      nim c --hints:off --warnings:off "$@" --genDeps:on \
        --nimcache:"${cache}" --out:"${cache}/${name}" "${entry}"
  else
    "${strace_bin}" -ff -y -xx -qq \
      -e trace=open,openat,openat2,execve,execveat,getdents,getdents64,chdir,fchdir,clone,clone3,fork,vfork \
      -o "${cache}/front.trace" \
      nim c --hints:off --warnings:off "$@" --genDeps:on \
        --nimcache:"${cache}" --out:"${cache}/${name}" "${entry}"
  fi
fi
# The compiler's search path, for the listing digests (§13 decision 111):
# `nim dump` prints its configuration as JSON on stdout, after whatever
# config.nims printed.
nim dump --dump.format:json --hints:off --warnings:off "$@" "${entry}" \
  > "${cache}/dump.out" 2>/dev/null || {
  echo "write_helper_deps: nim dump failed; no list written" >&2
  exit 1
}
module="$(basename "${entry}" .nim)"
if [ ! -s "${cache}/${module}.deps" ]; then
  echo "write_helper_deps: nim wrote no ${cache}/${module}.deps" >&2
  exit 1
fi
python3 - "${cache}" "${module}" "${build}" "${strace_bin}" "${binary}" \
    "${published}" "${entry}" <<'PY'
import hashlib, json, os, re, shlex, subprocess, sys
cache, module, build, strace, binary, published, entry = sys.argv[1:8]
entry = os.path.abspath(entry)
cache = os.path.abspath(cache)
build = os.path.abspath(build)
workspace = os.path.dirname(os.path.abspath(os.getcwd()))
excluded = ["/nix/store/", "/proc/", "/sys/", "/dev/", "/etc/", "/run/",
            build + "/"]

def wanted(p):
    p = os.path.abspath(p)
    return (not any(p.startswith(e) for e in excluded)
            and os.path.isfile(p)), p

modules, csources, traced = [], [], []
for line in open(os.path.join(cache, module + ".deps")):
    p = line.strip()
    ok, p = wanted(p) if p else (False, p)
    if ok and p not in modules:
        modules.append(p)
# Nim names its build record after the --out file (<name>.json), and the
# .deps file after the main module.
rec_path = os.path.join(cache, os.path.basename(published)[:-len(".deps")] + ".json")
if not os.path.exists(rec_path):
    rec_path = os.path.join(cache, module + ".json")
record = json.load(open(rec_path))
compiles = []
for src, cmd in record.get("compile", []):
    src = os.path.abspath(src)
    if src.startswith(cache + "/"):
        continue                       # a generated C file of a Nim module
    ok, p = wanted(src)
    if ok and p not in csources:
        csources.append(p)
        compiles.append((p, cmd))
# Each {.compile.} C file compiled again, into the scratch cache, under
# strace: the headers the compiler opens.
# Nim's record names the source relative to the directory it compiles
# in; the object goes to the scratch cache.
for i, (src, cmd) in enumerate(compiles):
    argv = shlex.split(cmd)
    for k, a in enumerate(argv):
        if a == "-o" and k + 1 < len(argv):
            argv[k + 1] = os.path.join(cache, "c%d.o" % i)
        elif os.path.basename(a) == os.path.basename(src) and not a.startswith("-"):
            argv[k] = src
    dep = os.path.join(cache, "c%d.d" % i)
    r = subprocess.run(argv + ["-MD", "-MF", dep], capture_output=True,
                       text=True, cwd=os.path.dirname(src))
    if r.returncode != 0:
        sys.exit("write_helper_deps: compiling a {.compile.} C file again "
                 "failed: " + r.stderr[-2000:])
    # The compiler's own depfile (make syntax): every header it included.
    text = open(dep).read().replace("\\\n", " ")
    for tok in text.split(":", 1)[1].split() if ":" in text else []:
        p = tok if os.path.isabs(tok) else os.path.join(os.path.dirname(src), tok)
        ok, p = wanted(p)
        if ok and p.startswith(workspace + "/") and p not in traced:
            traced.append(p)
mutation = os.environ.get("WRITE_HELPER_DEPS_MUTATION", "")
listings = []   # (directory, sha256 of its resolution-relevant entry names)
unresolved = []

# The compiler's search path (`nim dump`): its lib_paths and lazy paths.
dump = None
for line in open(os.path.join(cache, "dump.out"), errors="replace"):
    if line.startswith("{"):
        dump = json.loads(line)
if dump is None:
    sys.exit("write_helper_deps: nim dump printed no configuration; no list written")
# A relative entry (a relative --path given on the command line) is
# relative to the directory the compiler ran in, this one: it is recorded
# absolute, so the reader checks the same directory from any working
# directory (A11 code review round 12).
def absolute_search(p):
    if mutation == "relative-search-paths":
        return os.path.normpath(p)        # FALSIFIER: as given
    return os.path.normpath(os.path.join(os.getcwd(), p))
search = sorted({absolute_search(p) for p in dump.get("lib_paths", []) + dump.get("lazyPaths", [])})
search_set = set(search)

# The listing filter this list is written with; fresh_binary digests the
# way the list's `listing-filter` line says. Only falsifiers write another.
listing_filter = {
    "listing-digests-every-entry": "every-entry",        # round 8
    "listing-skips-subdirectories": "resolution-no-subdirs",
    "listing-skips-project-cfg": "resolution-no-project-cfg",
    "listing-skips-nim-cfg": "resolution-no-nim-cfg",
    "listing-counts-tool-dirs": "resolution-counts-tool-dirs",
}.get(mutation, "resolution")
# Entries that never change what the compiler resolves, whatever they are
# (§13 decision 114, extended by decision 115 (B)): build output, VCS
# metadata, a nix result link, and the tool directories of a checkout --
# direnv's cache, repro's state, a nimcache, generated docs, test logs.
# None of them is on a search path or holds a config the compiler reads;
# what is left is an import whose first component is one of these names
# (`import nimcache/x`), which no build here makes. `tmp` and `docs` are
# not on the list: a new one refuses (the cost decision 115 accepts).
never_counted = {b".nimcache", b"build", b".git", b"result",
                 b".direnv", b".repro", b"nimcache", b"htmldocs",
                 b"test-logs"}
if listing_filter == "resolution-counts-tool-dirs":
    # FALSIFIER: decision 114's list alone, before 115 (B).
    never_counted = {b".nimcache", b"build", b".git", b"result"}

def relevant(d, name, full=False):
    # §13 decisions 111, 114 and 115: an entry counts in a listing when
    # it can
    # change what the compiler resolves -- a Nim source, a .nimble or .nims
    # file, a Nim configuration file (nim.cfg, <project>.nim.cfg), a
    # nimble.paths, or a subdirectory (a package directory that shadows an
    # import is one) -- except the fixed list above.
    if listing_filter == "every-entry":
        return True           # FALSIFIER: round 8's digest of every name
    if name in never_counted and not full:
        return False
    if name.endswith((b".nim", b".nimble", b".nims")) or name == b"nimble.paths":
        return True
    if name == b"nim.cfg":
        return listing_filter != "resolution-no-nim-cfg"
    if name.endswith(b".nim.cfg"):
        return listing_filter != "resolution-no-project-cfg"
    full = os.path.normpath(os.path.join(d, os.fsdecode(name)))
    if full in search_set:
        return True
    if os.path.isdir(full):
        return listing_filter != "resolution-no-subdirs"
    return False

def listing_digest(d, full=False):
    # A directory that does not exist lists no names: a search directory
    # created later (decision 115 (A)) changes the digest. ``full``: the
    # fixed list counts too (a directory an import path's later component
    # is looked up in; decision 115 (B) as narrowed in round 12).
    if not os.path.isdir(d):
        return hashlib.sha256(b"").hexdigest()
    names = sorted(n for n in os.listdir(os.fsencode(d)) if relevant(d, n, full))
    return hashlib.sha256(b"\n".join(names)).hexdigest()

def configs_digest(d):
    # The configuration files Nim reads in a directory above the project
    # (`nim.cfg`, `config.nims`), and any other `.nims` (decision 115 (A)).
    names = sorted(n for n in os.listdir(os.fsencode(d))
                   if n in (b"nim.cfg", b"config.nims") or n.endswith(b".nims"))
    return hashlib.sha256(b"\n".join(names)).hexdigest()

def configs_probe_digest(d):
    # A directory that cannot be listed (execute-only, 0711 and the like):
    # Nim still opens nim.cfg and config.nims in it, so the writer looks up
    # those two names the same way, and the reader does too (A11 code
    # review round 12). A directory that cannot be searched either hides
    # them from Nim as well.
    names = sorted(n for n in (b"config.nims", b"nim.cfg")
                   if os.path.lexists(os.path.join(os.fsencode(d), n)))
    return hashlib.sha256(b"\n".join(names)).hexdigest()

def decode(text):
    # strace -xx prints a string as \xNN bytes; anything else is literal.
    out = bytearray()
    i = 0
    while i < len(text):
        if text.startswith("\\x", i) and i + 4 <= len(text):
            out.append(int(text[i + 2:i + 4], 16)); i += 4
        else:
            out += text[i].encode("utf-8", "surrogateescape"); i += 1
    return os.fsdecode(bytes(out))

def in_workspace(p):
    return (p.startswith(workspace + "/") and "/.git/" not in p
            and not any(p.startswith(e) for e in excluded))

def keep(kind, p):
    # A path in the workspace must be what it was traced as: a file read
    # or executed, a directory listed. Anything else -- a name that does
    # not decode to a file, a file gone since -- fails the list (round 8:
    # fail closed, never drop).
    if not in_workspace(p):
        return
    real = os.path.isdir(p) if kind == "listing" else os.path.isfile(p)
    if not real:
        if kind == "read" and os.path.isdir(p):
            return            # a directory opened, not listed: not a source
        if mutation == "drop-unresolved":
            return            # FALSIFIER: dropped silently, as before
        unresolved.append(kind + " " + p)
        return
    if kind == "listing":
        if mutation == "no-listing":
            return            # FALSIFIER
        if mutation == "no-parent-listings" and \
                os.path.dirname(entry).startswith(p.rstrip("/") + "/"):
            return            # FALSIFIER: a parent of the entry's directory
                              # (where a parent nim.cfg sits) not recorded
        if p not in [x[0] for x in listings]:
            listings.append((p, listing_digest(p), False))
        return
    if kind == "exec" and mutation == "no-execve":
        return                # FALSIFIER
    if p not in traced:
        traced.append(p)

if mutation in ("single-trace", "relative-to-script-dir", "text-paths"):
    # FALSIFIERS: the round-6/7 parsing, one line at a time.
    as_given = re.compile(r'open(?:at2?)?\((?:[^,]+, )?"([^"]+)".*\)\s+=\s+(\d+)')
    resolved_text = re.compile(r'^open(?:at2?)?\(.*\)\s+=\s+\d+<(.+)>\s*$')
    for f in sorted(os.listdir(cache)):
        if not f.startswith("front.trace"):
            continue
        for line in open(os.path.join(cache, f), errors="replace"):
            m = (resolved_text.match(line) if mutation == "text-paths"
                 else as_given.search(line))
            if m:
                p = os.path.abspath(m.group(1))
                if in_workspace(p) and os.path.isfile(p) and p not in traced:
                    traced.append(p)
else:
    hexstr = r'((?:\\x[0-9a-f]{2})*)'
    open_re = re.compile(r'^open(?:at2?)?\(.*\)\s+=\s+\d+<' + hexstr + r'>\s*$')
    exec_re = re.compile(r'^execve\("' + hexstr + r'",.*\)\s+=\s+0\s*$')
    execat_re = re.compile(r'^execveat\((?:\d+<' + hexstr + r'>|AT_FDCWD<' + hexstr + r'>), "' + hexstr + r'",.*\)\s+=\s+0\s*$')
    dents_re = re.compile(r'^getdents(?:64)?\(\d+<' + hexstr + r'>,.*\)\s+=\s+[1-9]\d*\s*$')
    chdir_re = re.compile(r'^chdir\("' + hexstr + r'"\)\s+=\s+0\s*$')
    fchdir_re = re.compile(r'^fchdir\(\d+<' + hexstr + r'>\)\s+=\s+0\s*$')
    cwd_re = re.compile(r'AT_FDCWD<' + hexstr + r'>')
    child_re = re.compile(r'^(?:clone3?|v?fork)\(.*\)\s+=\s+([1-9]\d*)\s*$')
    events = {}
    for f in os.listdir(cache):
        if f.startswith("front.trace."):
            events[int(f.rsplit(".", 1)[1])] = open(os.path.join(cache, f), errors="replace").read().splitlines()
    # Positive control (issue 2026-11-13-helper-list-writer-publishes-a-
    # list-from-a-trace-it-could-not-parse). The patterns above record only
    # the lines they match, so a trace in another format -- a strace whose
    # -y paths are text, one that ignored -xx, or no trace at all -- would
    # otherwise yield a list of `module` entries alone that accepts the
    # binary after a staticRead input changed. So every line of a traced
    # syscall that succeeded must be one the patterns read, and the
    # compiler's own open of the entry module must be among the decoded
    # opens; otherwise no list is written.
    # A line strace -ff writes: a syscall `name(args) = ret`, a signal
    # (`--- SIG... ---`) or an exit (`+++ ... +++`), or the two halves of a
    # syscall another thread interrupted (`<unfinished ...>`, `<... name
    # resumed>`). The second half is judged like a whole line: the patterns
    # do not read it, so if it succeeded it fails the list.
    syscall_re = re.compile(r'^(?:<\.\.\. )?([a-z_][a-z0-9_]*)(?:\(| resumed>)')
    # Success is judged by the return value alone, whatever strace prints
    # after it: an fd path with `(deleted)` after its `>` (the file was
    # removed by the time strace read the fd), a `-T` duration. A line
    # that succeeded but carries such a suffix is not one the patterns
    # read, so it fails the list rather than passing as a failed syscall.
    succeeded_re = re.compile(r'\s=\s+(?:\d+|0x[0-9a-f]+)(?![0-9a-zA-Z])')
    if mutation == "suffix-is-failure":
        # FALSIFIER: a suffix after the fd path read as a failed syscall.
        succeeded_re = re.compile(r'\s=\s+(?:\d+|0x[0-9a-f]+)(?:<.*>)?\s*$')
    dents_any_re = re.compile(r'^getdents(?:64)?\(\d+<' + hexstr + r'>,.*\)\s+=\s+\d+\s*$')
    readers = {
        "open": [open_re], "openat": [open_re], "openat2": [open_re],
        "execve": [exec_re], "execveat": [execat_re],
        "getdents": [dents_any_re], "getdents64": [dents_any_re],
        "chdir": [chdir_re], "fchdir": [fchdir_re],
        "clone": [child_re], "clone3": [child_re], "fork": [child_re],
        "vfork": [child_re],
    }
    # An open whose fd strace prints `<path>(deleted)`: the kernel names
    # the fd `<path> (deleted)` and strace moves the marker after the `>`.
    # An O_TMPFILE open always looks like this (the file is anonymous from
    # the start: glibc tmpfile(), Python's tempfile.TemporaryFile()), and
    # is skipped wherever it is made: it cannot be a source. Any other
    # `(deleted)` open -- a later open of such a file through
    # /proc/self/fd, which carries no O_TMPFILE flag, or a file removed
    # by the time strace read the fd -- is skipped outside the workspace,
    # where nothing is recorded anyway, and fails the list inside it: the
    # build read it and the list could not check it. So an anonymous file
    # made in the workspace (TMPDIR there) and reopened by path also fails
    # the list; that errs toward refusing.
    open_deleted_re = re.compile(r'^open(?:at2?)?\((.*)\)\s+=\s+\d+<' + hexstr + r'>\(deleted\)\s*$')
    deleted_in_workspace = []
    unparsed = []
    entry_real = os.path.realpath(entry)
    entry_opened = False
    for pid in sorted(events):
        for line in events[pid]:
            if not line.strip() or line.startswith(("--- ", "+++ ")):
                continue
            m = syscall_re.match(line)
            if not m:
                unparsed.append("%d: %s" % (pid, line))
                continue
            if m.group(1) not in readers or "<unfinished ...>" in line:
                continue
            if not succeeded_re.search(line):
                continue      # failed (= -1 E...) or never returned (= ?)
            d = open_deleted_re.match(line)
            if d and mutation != "deleted-is-unparsed":   # FALSIFIER
                if "O_TMPFILE" in d.group(1):
                    continue  # an anonymous file: never a source
                gone = decode(d.group(2))
                if in_workspace(gone):
                    deleted_in_workspace.append("%d: %s" % (pid, gone))
                continue      # outside the workspace: not recorded anyway
            if not any(r.match(line) for r in readers[m.group(1)]):
                unparsed.append("%d: %s" % (pid, line))
                continue
            o = open_re.match(line)
            if o and decode(o.group(1)) == entry_real:
                entry_opened = True
    if mutation != "accept-unparsed":   # FALSIFIER: an unread trace accepted
        if unparsed:
            sys.exit("write_helper_deps: the strace that ran (" + strace +
                     ") printed lines the writer could not parse (it reads "
                     "only strace -ff -y -xx output); no list written:\n  " +
                     "\n  ".join(l if len(l) <= 400 else
                                  l[:200] + " ... " + l[-200:]
                                  for l in unparsed[:10]) +
                     ("\n  ... and %d more" % (len(unparsed) - 10)
                      if len(unparsed) > 10 else ""))
        if deleted_in_workspace:
            sys.exit("write_helper_deps: the trace shows workspace files "
                     "opened and then deleted (strace printed them "
                     "`(deleted)`), so the list could not check them; no "
                     "list written:\n  " + "\n  ".join(deleted_in_workspace))
        if not entry_opened:
            sys.exit("write_helper_deps: positive control failed: the trace "
                     "of the strace that ran (" + strace + ") does not show "
                     "the compiler opening the entry module " + entry_real +
                     ", so it cannot be trusted to show what else was read; "
                     "no list written")
    children = {}
    for pid, lines in events.items():
        for line in lines:
            m = child_re.match(line)
            if m: children.setdefault(pid, []).append(int(m.group(1)))
    is_child = {c for cs in children.values() for c in cs}
    def walk(pid, cwd):
        for line in events.get(pid, []):
            hint = cwd_re.search(line)
            if hint: cwd = decode(hint.group(1))
            m = open_re.match(line)
            if m: keep("read", decode(m.group(1))); continue
            m = exec_re.match(line)
            if m:
                keep("exec", os.path.normpath(os.path.join(cwd, decode(m.group(1))))); continue
            m = execat_re.match(line)
            if m:
                base = decode(m.group(1) or m.group(2))
                keep("exec", os.path.normpath(os.path.join(base, decode(m.group(3))))); continue
            m = dents_re.match(line)
            if m: keep("listing", decode(m.group(1))); continue
            m = chdir_re.match(line)
            if m: cwd = os.path.normpath(os.path.join(cwd, decode(m.group(1)))); continue
            m = fchdir_re.match(line)
            if m: cwd = decode(m.group(1)); continue
            m = child_re.match(line)
            if m: walk(int(m.group(1)), cwd)
    for pid in sorted(events):
        if pid not in is_child:
            walk(pid, os.getcwd())
    if unresolved:
        sys.exit("write_helper_deps: traced paths in the workspace that are "
                 "not what they were traced as (a name that does not decode "
                 "to a file, or a file gone since); no list written:\n  " +
                 "\n  ".join(unresolved))
# Directories the compiler resolves imports in but may never list
# (§13 decision 115 (A)). Nim resolves `import a/b/m` by testing
# <dir>/a/b/m.nim in each search directory, an existence probe and not a
# listing, so a new file in a search directory the build found nothing in
# shadows a module found later. Every search directory outside the
# immutable prefixes is listed, and in each of them the directories an
# import found elsewhere would be looked up in (a/ and a/b/ above) where
# they exist; an absent one is covered by its parent's listing. Those
# directories are digested with the fixed list counted (``full``): an
# absent `build/` below `a/` shadows `import a/build/m` as well as any
# other name would (A11 code review round 12, narrowing decision 115 (B)
# to an import path's first component).
def recordable(d):
    return (not any(d.startswith(e) for e in excluded)
            and "/.git/" not in d + "/")

def add_listing(d, full=False):
    if mutation == "import-listings-exclude-tool-dirs":
        full = False                      # FALSIFIER: decision 115 (B) as first written
    for i, x in enumerate(listings):
        if x[0] == d:
            if full and not x[2]:
                listings[i] = (d, listing_digest(d, True), True)
            return
    listings.append((d, listing_digest(d, full), full))

if mutation != "no-search-listings":
    roots = [d for d in search if recordable(d + "/")]
    for d in roots:
        add_listing(d)
    for m in modules:
        for s in search:
            if not m.startswith(s + "/"):
                continue
            parts = os.path.dirname(os.path.relpath(m, s)).split(os.sep)
            parts = [x for x in parts if x not in ("", ".")]
            for d in roots:
                for k in range(1, len(parts) + 1):
                    sub = os.path.join(d, *parts[:k])
                    if os.path.isdir(sub):
                        add_listing(sub, full=True)
# The configuration files above the project (§13 decision 115 (A)): Nim
# reads nim.cfg and config.nims in the project's directory and in every
# parent of it up to /, unless --skipParentCfg; a config file that does
# not exist is an existence probe, never traced. Each of those directories
# is recorded with the names of its config files.
configs = []
if mutation != "no-parent-configs":
    d = os.path.dirname(entry)
    while True:
        try:
            configs.append((d, configs_digest(d), "configs"))
        except OSError as e:
            if mutation == "configs-fail-unreadable":
                # FALSIFIER: round 11, which failed the build here.
                sys.exit("write_helper_deps: cannot list %s for its Nim "
                         "configuration files (%s); no list written" % (d, e))
            configs.append((d, configs_probe_digest(d), "configs-probed"))
        parent = os.path.dirname(d)
        if parent == d:
            break
        d = parent
h = hashlib.sha256()
with open(binary, "rb") as fh:
    for chunk in iter(lambda: fh.read(1 << 20), b""):
        h.update(chunk)
digest = h.hexdigest()
if mutation == "list-for-earlier-binary":
    # FALSIFIER: a list written for another build of the binary.
    digest = hashlib.sha256(b"an earlier build").hexdigest()
def enc(p):
    # A path is one line of the list, so every byte that could break the
    # line or the encoding -- a backslash, a control byte (a newline), DEL,
    # and every non-ASCII byte -- is written as \xNN; fresh_binary.nim
    # decodes it back to the exact bytes of the name.
    # A space is escaped too (round 9): the list's fields are split at
    # spaces, and a name that ends in one must come back with it.
    raw = os.fsencode(p)
    if mutation == "trim-edge-spaces":
        raw = raw.strip(b" ")     # FALSIFIER: round 8's strip() of the line
    out = []
    for b in raw:
        if b == 0x5C or b <= 0x20 or b >= 0x7F:
            out.append("\\x%02x" % b)
        else:
            out.append(chr(b))
    return "".join(out)
lines = ["binary-sha256 " + digest]
# The search path the listing digests were filtered by (decision 111):
# fresh_binary filters a listing the same way.
lines += ["searchpath " + enc(p) for p in search]
# Which entries the listing digests cover. fresh_binary digests a listing
# the way the list says; only the falsifier writes "every-entry".
lines.append("listing-filter " + listing_filter)
lines += ["module " + enc(p) for p in modules]
lines += ["csource " + enc(p) for p in csources]
seen = set(modules) | set(csources)
for p in traced:
    if p in seen:
        continue
    seen.add(p)
    kind = "header" if p.endswith((".h", ".hpp", ".hh", ".inc")) else "read"
    lines.append(kind + " " + enc(p))
for d, digest, full in listings:
    lines.append(("listing-full " if full else "listing ") + digest + " " + enc(d))
for d, digest, kind in configs:
    lines.append(kind + " " + digest + " " + enc(d))
# Whether the compiler read the user's Nim configuration (§13 decision
# 142): a guarded helper is built with --skipUserCfg, and fresh_binary
# refuses a list that says otherwise.
lines.append("user-config " + os.environ.get("WRITE_HELPER_DEPS_USER_CONFIG", "read"))
part = published + ".part"
with open(part, "w") as fh:
    fh.write("\n".join(lines) + "\n")
os.replace(part, published)
PY
