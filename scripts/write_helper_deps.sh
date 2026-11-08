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
#                     slurp targets, and what staticExec's commands read
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
# <module>.deps. That run, and a compile of each {.compile.} C file, run
# under `strace -f`, so every file opened is seen: staticRead targets,
# files read by a staticExec command, and the headers the C compiler
# opens. The list starts with the sha256 of the binary it describes, and
# fresh_binary refuses a list written for another binary.
#
# The published list is removed first. A run that fails, for any reason,
# leaves NO list, and a test then refuses the binary. strace is required
# (from PATH, $REPRO_STRACE, or the flake's nixpkgs#strace): without it
# nothing is written. strace is Linux only, so on other hosts
# this exits 1 and the guarded helpers' tests refuse the binary.
#
# REPRO_TEST_BUILD_DIR names another build directory (the Nim 2.2.4
# lane's). WRITE_HELPER_DEPS_MUTATION=keep-old-list is the falsifier of
# the removal (the published list is then left in place on failure).
set -euo pipefail
name="${1:?usage: write_helper_deps.sh <name> <entry.nim> [nim flags...]}"
entry="${2:?usage: write_helper_deps.sh <name> <entry.nim> [nim flags...]}"
shift 2
build="${REPRO_TEST_BUILD_DIR:-build}"
published="${build}/nimcache/${name}/${name}.deps"
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
if [ -z "${strace_bin}" ] && command -v nix >/dev/null 2>&1 && [ "$(uname -s)" = Linux ]; then
  # The flake's own nixpkgs, as the Nim 2.2.4 lane resolves its Nim.
  repo="$(cd "$(dirname "$0")/.." && pwd)"
  strace_bin="$(nix build --no-link --print-out-paths --inputs-from "${repo}" nixpkgs#strace 2>/dev/null)/bin/strace" || strace_bin=""
  [ -x "${strace_bin}" ] || strace_bin=""
fi
if [ -z "${strace_bin}" ]; then
  echo "write_helper_deps: strace is required (staticRead inputs and C headers are seen only through it); no list written" >&2
  exit 1
fi
cache="${build}/nimcache/${name}-deps"
rm -rf "${cache}"
mkdir -p "${cache}" "${build}/nimcache/${name}"
"${strace_bin}" -f -qq -e trace=open,openat,openat2 -o "${cache}/front.trace" \
  nim c --hints:off --warnings:off "$@" --genDeps:on \
    --nimcache:"${cache}" --out:"${cache}/${name}" "${entry}"
module="$(basename "${entry}" .nim)"
if [ ! -s "${cache}/${module}.deps" ]; then
  echo "write_helper_deps: nim wrote no ${cache}/${module}.deps" >&2
  exit 1
fi
python3 - "${cache}" "${module}" "${build}" "${strace_bin}" "${binary}" \
    "${published}" <<'PY'
import hashlib, json, os, re, shlex, subprocess, sys
cache, module, build, strace, binary, published = sys.argv[1:7]
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
    r = subprocess.run([strace, "-f", "-qq", "-e", "trace=open,openat,openat2",
                        "-o", os.path.join(cache, "c%d.trace" % i)] + argv,
                       capture_output=True, text=True,
                       cwd=os.path.dirname(src))
    if r.returncode != 0:
        sys.exit("write_helper_deps: compiling a {.compile.} C file again "
                 "failed: " + r.stderr[-2000:])
opened = re.compile(r'open(?:at2?)?\((?:[^,]+, )?"([^"]+)".*\)\s+=\s+(\d+)')
for f in sorted(os.listdir(cache)):
    if not f.endswith(".trace"):
        continue
    for line in open(os.path.join(cache, f), errors="replace"):
        m = opened.search(line)
        if not m:
            continue
        ok, p = wanted(m.group(1))
        # What the compiler read that can be a source: files in the
        # directory the build runs from and its siblings (the workspace:
        # sibling checkouts sit beside the repository), outside any .git
        # directory. Git metadata a config.nims probe reads, the user's own
        # config files and shared caches are not sources of the binary.
        if (ok and p.startswith(workspace + "/") and "/.git/" not in p
                and p not in traced):
            traced.append(p)
h = hashlib.sha256()
with open(binary, "rb") as fh:
    for chunk in iter(lambda: fh.read(1 << 20), b""):
        h.update(chunk)
lines = ["binary-sha256 " + h.hexdigest()]
lines += ["module " + p for p in modules]
lines += ["csource " + p for p in csources]
seen = set(modules) | set(csources)
for p in traced:
    if p in seen:
        continue
    seen.add(p)
    kind = "header" if p.endswith((".h", ".hpp", ".hh", ".inc")) else "read"
    lines.append(kind + " " + p)
part = published + ".part"
with open(part, "w") as fh:
    fh.write("\n".join(lines) + "\n")
os.replace(part, published)
PY
