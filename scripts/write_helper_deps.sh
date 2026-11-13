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
#                     listed (getdents), with the sha256 of its entry
#                     names, sorted bytewise and joined by newlines: a
#                     changed listing refuses the binary (§13 decision 80)
#
# Each path is written with every backslash, control byte (a newline) and
# non-ASCII byte as \xNN, so a path is always one line; fresh_binary
# decodes it to the exact bytes of the name.
#
# Not recorded (§13 decisions 74 and 80): existence checks -- stat,
# access, `test -f`, fileExists. The Nim compiler's own module search makes
# many of them (one per search path per import), so recording each would
# refuse the binary whenever any search directory changed; a module the
# search found is recorded as a module. A staticExec command whose output
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
# or one without the entry module's open, yields a list anyway). A file
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
module="$(basename "${entry}" .nim)"
if [ ! -s "${cache}/${module}.deps" ]; then
  echo "write_helper_deps: nim wrote no ${cache}/${module}.deps" >&2
  exit 1
fi
python3 - "${cache}" "${module}" "${build}" "${strace_bin}" "${binary}" \
    "${published}" "${entry}" <<'PY'
import hashlib, json, os, re, shlex, subprocess, sys
cache, module, build, strace, binary, published, entry = sys.argv[1:8]
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
listings = []   # (directory, sha256 of its sorted entry names)
unresolved = []

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
        if p not in [d for d, _ in listings]:
            names = sorted(os.listdir(os.fsencode(p)))
            listings.append((p, hashlib.sha256(b"\n".join(names)).hexdigest()))
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
                     "\n  ".join(l[:300] for l in unparsed[:10]) +
                     ("\n  ... and %d more" % (len(unparsed) - 10)
                      if len(unparsed) > 10 else ""))
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
    out = []
    for b in os.fsencode(p):
        if b == 0x5C or b < 0x20 or b >= 0x7F:
            out.append("\\x%02x" % b)
        else:
            out.append(chr(b))
    return "".join(out)
lines = ["binary-sha256 " + digest]
lines += ["module " + enc(p) for p in modules]
lines += ["csource " + enc(p) for p in csources]
seen = set(modules) | set(csources)
for p in traced:
    if p in seen:
        continue
    seen.add(p)
    kind = "header" if p.endswith((".h", ".hpp", ".hh", ".inc")) else "read"
    lines.append(kind + " " + enc(p))
for d, digest in listings:
    lines.append("listing " + digest + " " + enc(d))
part = published + ".part"
with open(part, "w") as fh:
    fh.write("\n".join(lines) + "\n")
os.replace(part, published)
PY
