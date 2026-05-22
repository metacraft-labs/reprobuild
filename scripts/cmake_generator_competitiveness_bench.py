#!/usr/bin/env python3
import argparse
import datetime
import glob
import hashlib
import json
import os
import platform
import re
import shutil
import socket
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.request
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
WORKSPACE = ROOT.parent
DEFAULT_CMAKE_ROOT = WORKSPACE / "reprobuild-cmake"
DEFAULT_RUNQUOTA_ROOT = WORKSPACE / "runquota"
GENERATED_FIXTURE = ROOT / "benchmarks" / "fixtures" / "cmake-generated-custom-command"
HEADER_INCREMENTAL_CANDIDATES = {
    "CMake": [
        "Source/cmSystemTools.h",
        "Source/cmValue.h",
        "Source/cmStringAlgorithms.h",
    ],
    "fmt": ["include/fmt/format.h"],
    "libuv": ["include/uv.h"],
    "protobuf": ["src/google/protobuf/message.h"],
    "zlib": ["zlib.h"],
}

# Per-command wall-clock ceiling. A hung subprocess (e.g. a build step that
# never returns) must not stall the whole benchmark indefinitely.
COMMAND_TIMEOUT_SECONDS = int(
    os.environ.get("REPROBUILD_CMAKE_BENCH_COMMAND_TIMEOUT", "600"))


def json_now():
    return datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat()


def fail(message):
    raise RuntimeError(message)


def shlex_join(args):
    return subprocess.list2cmdline([str(arg) for arg in args])


def tail(text, limit=6000):
    if len(text) <= limit:
        return text
    return text[-limit:]


def run_command(args, cwd=None, env=None, check=True,
                timeout=COMMAND_TIMEOUT_SECONDS):
    start = time.perf_counter()
    try:
        proc = subprocess.run(
            [str(arg) for arg in args],
            cwd=str(cwd) if cwd else None,
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired as exc:
        elapsed_ms = (time.perf_counter() - start) * 1000.0
        result = {
            "command": [str(arg) for arg in args],
            "commandLine": shlex_join(args),
            "cwd": str(cwd) if cwd else None,
            "exitCode": None,
            "status": "timeout",
            "timeoutSeconds": timeout,
            "wallMs": round(elapsed_ms, 3),
            "stdoutTail": tail(exc.stdout or ""),
            "stderrTail": tail(exc.stderr or ""),
        }
        if check:
            raise CommandFailure(result)
        return result
    elapsed_ms = (time.perf_counter() - start) * 1000.0
    result = {
        "command": [str(arg) for arg in args],
        "commandLine": shlex_join(args),
        "cwd": str(cwd) if cwd else None,
        "exitCode": proc.returncode,
        "status": "succeeded" if proc.returncode == 0 else "failed",
        "wallMs": round(elapsed_ms, 3),
        "stdoutTail": tail(proc.stdout),
        "stderrTail": tail(proc.stderr),
    }
    if check and proc.returncode != 0:
        raise CommandFailure(result)
    return result


def repeated_result(run_once, runs):
    if runs <= 1:
        return run_once()
    samples = []
    for _ in range(runs):
        samples.append(run_once())
    ordered = sorted(samples, key=lambda item: item["wallMs"])
    median = ordered[len(ordered) // 2]
    result = dict(median)
    wall_values = [sample["wallMs"] for sample in samples]
    result["timingSamples"] = wall_values
    result["timingSummary"] = {
        "runs": runs,
        "firstWallMs": wall_values[0],
        "bestWallMs": min(wall_values),
        "medianWallMs": median["wallMs"],
        "worstWallMs": max(wall_values),
        "meanWallMs": round(sum(wall_values) / len(wall_values), 3),
    }
    return result


def parse_stats_table(output):
    metrics = []
    in_metrics = False
    metric_line = re.compile(
        r"^(?P<name>.+?)\s+"
        r"(?P<count>\d+)\s+"
        r"(?P<avg>[-+]?(?:\d+(?:\.\d*)?|\.\d+))\s+"
        r"(?P<total>[-+]?(?:\d+(?:\.\d*)?|\.\d+))\s*$"
    )

    for line in output.splitlines():
        stripped = line.strip()
        if not stripped:
            if in_metrics:
                break
            continue
        if re.match(r"^metric\s+count\s+avg \(us\)\s+total \(ms\)\s*$", stripped):
            in_metrics = True
            continue
        if not in_metrics:
            continue
        match = metric_line.match(stripped)
        if not match:
            continue
        metrics.append({
            "name": match.group("name").strip(),
            "count": int(match.group("count")),
            "avgUs": float(match.group("avg")),
            "totalMs": float(match.group("total")),
        })

    return {"metrics": metrics}


def parse_ninja_stats(output):
    return parse_stats_table(output)


def parse_reprobuild_stats(output):
    return parse_stats_table(output)


def enrich_ninja_stats_result(result):
    combined = result["stdoutTail"] + "\n" + result["stderrTail"]
    result["ninjaDiagnostics"] = {
        "mode": "stats",
        **parse_ninja_stats(combined),
    }


def enrich_reprobuild_stats_result(result):
    combined = result["stdoutTail"] + "\n" + result["stderrTail"]
    result["reprobuildDiagnostics"] = {
        "mode": "stats",
        **parse_reprobuild_stats(combined),
    }


class CommandFailure(Exception):
    def __init__(self, result):
        self.result = result
        super().__init__(
            "command failed: {}\nstdout:\n{}\nstderr:\n{}".format(
                result["commandLine"], result["stdoutTail"], result["stderrTail"]
            )
        )


def parse_cmake_set_values(body):
    values = []
    for match in re.finditer(r'"([^"]*)"|([^\s()#]+)', body):
        values.append(match.group(1) if match.group(1) is not None else match.group(2))
    return values


def parse_locks(lock_file):
    text = lock_file.read_text()
    variables = {}
    for match in re.finditer(r"set\(\s*([A-Za-z0-9_]+)\s*(.*?)\)", text, re.DOTALL):
        variables[match.group(1)] = parse_cmake_set_values(match.group(2))

    project_fields = [
        "EXPECT_REPROBUILD_CONFIGURE_FAILURE_NEEDLE",
        "EXPECT_REPROBUILD_INSTALL_FAILURE_NEEDLE",
        "EXPECT_NINJA_BUILD_FAILURE_NEEDLE",
        "EXPECT_REPROBUILD_CONFIGURE_FAILURE",
        "EXPECT_REPROBUILD_INSTALL_FAILURE",
        "EXPECT_NINJA_BUILD_FAILURE",
        "COMPILE_COMMAND_NEEDLE",
        "EXPECT_COMPILE_ACTIONS",
        "CONFIGURE_ARGS",
        "INSTALL_OUTPUTS",
        "BUILD_OUTPUTS",
        "INSTALL_TARGET",
        "BUILD_TARGET",
        "SOURCE_SUBDIR",
        "VERSION",
        "PROFILE",
        "SHA256",
        "NAME",
        "URL",
    ]
    projects = {}
    for var, values in variables.items():
        prefix = "M11_PROJECT_"
        if not var.startswith(prefix):
            continue
        rest = var[len(prefix):]
        for field in project_fields:
            suffix = "_" + field
            if rest.endswith(suffix):
                key = rest[:-len(suffix)]
                projects.setdefault(key, {})[field] = values
                break
    return variables, projects


def bool_field(project, name):
    values = project.get(name, [])
    return bool(values and values[0].upper() in ("1", "ON", "TRUE", "YES"))


def one(project, name, default=""):
    values = project.get(name, [])
    return values[0] if values else default


def many(project, name):
    return project.get(name, [])


def resolve_executable(path, label):
    path = Path(path)
    # Windows: the benchmark's default paths are extensionless (cmake, repro,
    # runquotad) but the built binaries carry a .exe suffix.
    if not path.exists() and os.name == "nt" and path.suffix == "":
        exe = path.with_suffix(".exe")
        if exe.exists():
            path = exe
    if not path.exists() or not os.access(path, os.X_OK):
        fail(f"missing executable for {label}: {path}")
    return path


def which_first(*names):
    for name in names:
        found = shutil.which(name)
        if found:
            return found
    return ""


def find_ninja():
    found = shutil.which("ninja")
    if found:
        return Path(found)
    candidates = sorted(glob.glob("/nix/store/*ninja*/bin/ninja"))
    if candidates:
        return Path(candidates[0])
    fail("ninja is required for the CMake generator competitiveness benchmark")


def cache_value(cmake, build_dir, name):
    # Read CMakeCache.txt directly. `cmake -LA -N` output can exceed the
    # captured stdout tail (the cache is large), which silently dropped
    # early entries such as CMAKE_C_COMPILER.
    cache_file = Path(build_dir) / "CMakeCache.txt"
    if not cache_file.exists():
        return ""
    pattern = re.compile(rf"^{re.escape(name)}:[^=]*=(.*)$")
    for line in cache_file.read_text(errors="replace").splitlines():
        match = pattern.match(line)
        if match:
            return match.group(1).strip()
    return ""


def command_version(args):
    try:
        result = run_command(args, check=False)
        combined = (result["stdoutTail"] + "\n" + result["stderrTail"]).strip()
        return combined.splitlines()[0] if combined else "unknown"
    except Exception:
        return "unknown"


def ensure_archive(project_key, project, cache_dir):
    url = one(project, "URL")
    sha = one(project, "SHA256")
    if not url or not sha:
        fail(f"project {project_key} is missing URL or SHA256 in real-project locks")
    cache_dir.mkdir(parents=True, exist_ok=True)
    archive = cache_dir / f"{project_key}.tar.gz"
    if not archive.exists():
        print(f"fetching pinned source for {project_key}", file=sys.stderr)
        try:
            with urllib.request.urlopen(url, timeout=120) as response, archive.open("wb") as output:
                shutil.copyfileobj(response, output)
        except Exception:
            curl = shutil.which("curl")
            if not curl:
                raise
            run_command([curl, "-L", "--fail", "--silent", "--show-error", "-o", archive, url])
    actual = hashlib.sha256(archive.read_bytes()).hexdigest()
    if actual != sha:
        fail(f"hash mismatch for {project_key}: expected {sha}, got {actual}")
    return archive


def extract_project(project_key, project, archive, sources_root):
    subdir = one(project, "SOURCE_SUBDIR")
    if not subdir:
        fail(f"project {project_key} is missing SOURCE_SUBDIR")
    dest_root = sources_root / project_key
    if dest_root.exists():
        shutil.rmtree(dest_root)
    dest_root.mkdir(parents=True)
    with tarfile.open(archive, "r:gz") as tar:
        try:
            tar.extractall(dest_root, filter="data")
        except TypeError:
            tar.extractall(dest_root)
    source = dest_root / subdir
    if not source.exists():
        fail(f"extracted source directory not found for {project_key}: {source}")
    return source


def copy_generated_fixture(dest):
    if dest.exists():
        shutil.rmtree(dest)
    shutil.copytree(GENERATED_FIXTURE, dest)
    return dest


def copy_source_tree(source_dir, dest):
    if dest.exists():
        shutil.rmtree(dest)
    shutil.copytree(source_dir, dest, symlinks=True)
    return dest


def configure_project(cmake, ninja, generator, source_dir, binary_dir,
                      c_compiler, cxx_compiler, install_prefix,
                      configure_args, env=None):
    if binary_dir.exists():
        shutil.rmtree(binary_dir)
    args = [
        cmake,
        "-S", source_dir,
        "-B", binary_dir,
        "-G", generator,
        "-DCMAKE_BUILD_TYPE=Debug",
        f"-DCMAKE_C_COMPILER={c_compiler}",
        f"-DCMAKE_CXX_COMPILER={cxx_compiler}",
        f"-DCMAKE_INSTALL_PREFIX={install_prefix}",
        "-DCMAKE_EXPORT_COMPILE_COMMANDS=ON",
    ]
    if generator == "Ninja":
        args.append(f"-DCMAKE_MAKE_PROGRAM={ninja}")
    args.extend(configure_args)
    return run_command(args, env=env)


def build_command(cmake, binary_dir, target, parallel, native_args=None):
    args = [cmake, "--build", binary_dir]
    if target:
        args.extend(["--target", target])
    if parallel:
        args.extend(["--parallel", str(parallel)])
    if native_args:
        args.append("--")
        args.extend(native_args)
    return args


def direct_ninja_build_command(ninja, binary_dir, target, parallel, native_args=None):
    args = [ninja, "-C", binary_dir]
    if parallel:
        args.extend(["-j", str(parallel)])
    if native_args:
        args.extend(native_args)
    if target:
        args.append(target)
    return args


def reprobuild_provider_dir(binary_dir):
    return Path(binary_dir) / "CMakeFiles" / "reprobuild"


def direct_reprobuild_build_command(repro, binary_dir, target,
                                    reprobuild_diagnostics="none"):
    args = [repro, "build"]
    if target:
        args.append(f"{binary_dir}#{target}")
    args.extend([
        "--tool-provisioning=path",
        f"--work-root={reprobuild_provider_dir(binary_dir)}",
    ])
    if reprobuild_diagnostics == "stats":
        args.append("--stats")
    return args


def read_reprobuild_provider_metadata(binary_dir):
    metadata_file = reprobuild_provider_dir(binary_dir) / "provider.meta"
    if not metadata_file.exists():
        fail(f"missing Reprobuild provider metadata: {metadata_file}")
    metadata = {}
    for line in metadata_file.read_text().splitlines():
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        metadata[key] = value
    return metadata


def prepend_path(env, prefix):
    env = dict(env)
    old_path = env.get("PATH", "")
    sep = ";" if platform.system() == "Windows" else ":"
    env["PATH"] = str(prefix) if not old_path else f"{prefix}{sep}{old_path}"
    return env


def direct_reprobuild_env(env, binary_dir):
    metadata = read_reprobuild_provider_metadata(binary_dir)
    wrapper_path = metadata.get("wrapper_path")
    if not wrapper_path:
        fail(f"missing wrapper_path in {reprobuild_provider_dir(binary_dir) / 'provider.meta'}")
    return prepend_path(env, wrapper_path)


def run_build(cmake, binary_dir, target, parallel, env=None,
              ninja_diagnostics="none", reprobuild_diagnostics="none"):
    native_args = []
    if ninja_diagnostics == "stats":
        native_args.extend(["-d", "stats"])
    result = run_command(build_command(cmake, binary_dir, target, parallel, native_args), env=env)
    if ninja_diagnostics == "stats":
        enrich_ninja_stats_result(result)
    if reprobuild_diagnostics == "stats":
        enrich_reprobuild_stats_result(result)
    enrich_reprobuild_result(result)
    return result


def run_direct_ninja_build(ninja, binary_dir, target, parallel,
                           ninja_diagnostics="none"):
    native_args = []
    if ninja_diagnostics == "stats":
        native_args.extend(["-d", "stats"])
    result = run_command(
        direct_ninja_build_command(ninja, binary_dir, target, parallel,
                                   native_args))
    if ninja_diagnostics == "stats":
        enrich_ninja_stats_result(result)
    return result


def run_direct_reprobuild_build(repro, binary_dir, target, env=None,
                                reprobuild_diagnostics="none"):
    result = run_command(
        direct_reprobuild_build_command(repro, binary_dir, target,
                                        reprobuild_diagnostics),
        cwd=binary_dir,
        env=direct_reprobuild_env(env or os.environ.copy(), binary_dir))
    if reprobuild_diagnostics == "stats":
        enrich_reprobuild_stats_result(result)
    enrich_reprobuild_result(result)
    return result


def enrich_reprobuild_result(result):
    combined = result["stdoutTail"] + "\n" + result["stderrTail"]
    match = re.search(r"buildReport:\s*([^\r\n]+)", combined)
    if not match:
        return
    report_path = Path(match.group(1).strip())
    result["reprobuildReport"] = str(report_path)
    if report_path.exists():
        report_text = report_path.read_text(errors="replace")
        result["reprobuildEvidence"] = {
            "cacheHitMentions": report_text.count('"cacheDecision": "cdHit"'),
            "depfileInputMentions": report_text.count('"depfileInputs"'),
            "runQuotaSocketMentioned": '"runQuotaSocket"' in report_text,
        }


def run_direct_reprobuild_clean(binary_dir):
    start = time.perf_counter()
    metadata = read_reprobuild_provider_metadata(binary_dir)
    clean_manifest = metadata.get("clean_manifest")
    if not clean_manifest:
        fail(f"missing clean_manifest in {reprobuild_provider_dir(binary_dir) / 'provider.meta'}")
    manifest_path = Path(clean_manifest)
    if not manifest_path.exists():
        fail(f"missing Reprobuild clean manifest: {manifest_path}")
    removed = 0
    for line in manifest_path.read_text().splitlines():
        path = Path(line)
        if not path.exists() and not path.is_symlink():
            continue
        if path.is_dir() and not path.is_symlink():
            shutil.rmtree(path)
        else:
            path.unlink()
        removed += 1
    elapsed_ms = (time.perf_counter() - start) * 1000.0
    return {
        "command": ["<benchmark-harness>", "reprobuild-clean", str(binary_dir)],
        "commandLine": f"<benchmark-harness> reprobuild-clean {binary_dir}",
        "cwd": None,
        "exitCode": 0,
        "status": "succeeded",
        "wallMs": round(elapsed_ms, 3),
        "stdoutTail": f"removed {removed} paths\n",
        "stderrTail": "",
    }


def start_runquota(runquotad, root):
    root.mkdir(parents=True, exist_ok=True)
    socket_hash = hashlib.sha256(str(root).encode("utf-8")).hexdigest()[:16]
    socket_path = Path(tempfile.gettempdir()) / f"rbcmake-{socket_hash}.sock"
    log_path = root / "runquotad.log"
    if socket_path.exists():
        socket_path.unlink()
    log = log_path.open("w")
    proc = subprocess.Popen(
        [
            str(runquotad),
            "--socket", str(socket_path),
            "--cpu-milli", "8000",
            "--memory-bytes", str(16 * 1024 * 1024 * 1024),
            "--pool", "console=1",
        ],
        stdout=log,
        stderr=subprocess.STDOUT,
    )
    # runquotad prints "runquotad listening <endpoint>" (and flushes stdout)
    # once it has bound its endpoint. Poll its log for that line rather than
    # waiting for a socket file to appear: on Windows the transport is a
    # named pipe, which creates no `.sock` file on disk.
    deadline = time.time() + 15.0
    while time.time() < deadline:
        try:
            if "runquotad listening" in log_path.read_text(errors="replace"):
                return proc, socket_path, log
        except OSError:
            pass
        if proc.poll() is not None:
            break
        time.sleep(0.05)
    proc.terminate()
    log.close()
    fail(f"runquotad did not report readiness within 15s "
         f"(socket={socket_path}); see {log_path}")


def stop_runquota(proc, log):
    if proc.poll() is None:
        proc.terminate()
        try:
            proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            proc.kill()
    log.close()


def repro_env(base_env, rb_bin, runquota_socket, binary_dir, parallel,
              reprobuild_diagnostics):
    env = dict(base_env)
    env.update({
        "RUNQUOTA_SOCKET": str(runquota_socket),
        "REPROBUILD_WORK_ROOT": str(binary_dir / "CMakeFiles" / "reprobuild" / "work-root"),
        "REPROBUILD_REPRO": str(rb_bin),
        "REPROBUILD_SOURCE_ROOT": str(ROOT),
        "REPROBUILD_MAX_PARALLELISM": str(max(1, parallel)),
        "REPROBUILD_STATS": "1" if reprobuild_diagnostics == "stats" else "0",
        "REPROBUILD_REPORT": "none",
        "REPROBUILD_LOG": "quiet",
    })
    return env


def compile_command_source(binary_dir, needle):
    commands = binary_dir / "compile_commands.json"
    if not commands.exists() or not needle:
        return None
    data = json.loads(commands.read_text())
    for entry in data:
        file_path = entry.get("file", "")
        command = entry.get("command", "")
        if needle in file_path or needle in command:
            return Path(file_path)
    return None


def header_incremental_source(project_key, source_dir):
    for relative in HEADER_INCREMENTAL_CANDIDATES.get(project_key, []):
        path = source_dir / relative
        if path.exists():
            return path
    return None


def append_comment(path, label):
    with path.open("a") as handle:
        handle.write(f"\n/* reprobuild benchmark edit {label} {time.time_ns()} */\n")


def append_seed(path, label):
    with path.open("a") as handle:
        handle.write(f"\n{label}-{time.time_ns()}\n")


def scenario_name_env(name):
    return "REPROBUILD_CMAKE_BENCH_MAX_RATIO_" + re.sub(r"[^A-Z0-9]+", "_", name.upper()).strip("_")


def execution_mode_name_env(execution_mode, scenario):
    return scenario_name_env(f"{execution_mode}_{scenario}")


def ratio_record(project_key, scenario, execution_mode, ninja_result, rb_result):
    ratio = None
    if ninja_result["wallMs"] > 0:
        ratio = rb_result["wallMs"] / ninja_result["wallMs"]
    threshold_env = execution_mode_name_env(execution_mode, scenario)
    scenario_threshold_env = scenario_name_env(scenario)
    threshold = (
        os.environ.get(threshold_env) or
        os.environ.get(scenario_threshold_env) or
        os.environ.get("REPROBUILD_CMAKE_BENCH_MAX_RATIO")
    )
    status = "recorded"
    if threshold and ratio is not None:
        try:
            threshold_value = float(threshold)
        except ValueError:
            fail(f"{threshold_env} must be a number")
        status = "pass" if ratio <= threshold_value else "fail"
    else:
        threshold_value = None
    return {
        "project": project_key,
        "scenario": scenario,
        "executionMode": execution_mode,
        "ratioReprobuildToNinja": round(ratio, 4) if ratio is not None else None,
        "ninjaWallMs": ninja_result["wallMs"],
        "reprobuildWallMs": rb_result["wallMs"],
        "threshold": threshold_value,
        "status": status,
    }


def add_pair(project_report, scenario, execution_mode, ninja_result, rb_result):
    project_report["scenarios"].append({
        "name": scenario,
        "executionMode": execution_mode,
        "generator": "Ninja",
        **ninja_result,
    })
    project_report["scenarios"].append({
        "name": scenario,
        "executionMode": execution_mode,
        "generator": "Reprobuild",
        **rb_result,
    })
    project_report["ratios"].append(
        ratio_record(project_report["key"], scenario, execution_mode,
                     ninja_result, rb_result))


def selected_execution_modes(mode):
    if mode == "both":
        return ["cmake-driver", "direct"]
    return [mode]


def benchmark_project_mode(args, context, project_report, key, source_dir,
                           execution_mode, configure_args, build_target,
                           compiled, source_needle, custom_seed=None):
    cmake = context["cmake"]
    ninja = context["ninja"]
    repro = context["repro"]
    runquotad = context["runquotad"]
    c_compiler = context["cCompiler"]
    cxx_compiler = context["cxxCompiler"]
    parallel = args.parallel
    base_env = os.environ.copy()

    mode_root = args.work_root / "projects" / key / execution_mode
    mode_source = copy_source_tree(source_dir, mode_root / "source")
    ninja_bin = mode_root / "ninja-build"
    rb_bin_dir = mode_root / "reprobuild-build"

    ninja_configure = configure_project(
        cmake, ninja, "Ninja", mode_source, ninja_bin, c_compiler,
        cxx_compiler, mode_root / "ninja-install", configure_args)
    configure_repro_env = dict(base_env)
    configure_repro_env.update({
        "REPROBUILD_REPRO": str(repro),
        "REPROBUILD_SOURCE_ROOT": str(ROOT),
    })
    rb_configure = configure_project(
        cmake, ninja, "Reprobuild", mode_source, rb_bin_dir, c_compiler,
        cxx_compiler, mode_root / "reprobuild-install", configure_args,
        env=configure_repro_env)
    add_pair(project_report, "configure", execution_mode, ninja_configure,
             rb_configure)

    rq_proc, rq_socket, rq_log = start_runquota(runquotad, mode_root / "runquota")
    rb_env = repro_env(base_env, repro, rq_socket, rb_bin_dir, parallel,
                       args.reprobuild_diagnostics)
    if execution_mode == "direct":
        ninja_build = lambda target: run_direct_ninja_build(
            ninja, ninja_bin, target, parallel,
            ninja_diagnostics=args.ninja_diagnostics)
        rb_build = lambda target: run_direct_reprobuild_build(
            repro, rb_bin_dir, target, env=rb_env,
            reprobuild_diagnostics=args.reprobuild_diagnostics)
        ninja_clean = lambda: run_direct_ninja_build(
            ninja, ninja_bin, "clean", parallel,
            ninja_diagnostics=args.ninja_diagnostics)
        rb_clean = lambda: run_direct_reprobuild_clean(rb_bin_dir)
    else:
        ninja_build = lambda target: run_build(
            cmake, ninja_bin, target, parallel,
            ninja_diagnostics=args.ninja_diagnostics)
        rb_build = lambda target: run_build(
            cmake, rb_bin_dir, target, parallel, env=rb_env,
            reprobuild_diagnostics=args.reprobuild_diagnostics)
        ninja_clean = lambda: run_build(
            cmake, ninja_bin, "clean", parallel,
            ninja_diagnostics=args.ninja_diagnostics)
        rb_clean = lambda: run_build(
            cmake, rb_bin_dir, "clean", parallel, env=rb_env,
            reprobuild_diagnostics=args.reprobuild_diagnostics)
    try:
        ninja_clean_build = ninja_build(build_target)
        rb_clean_build = rb_build(build_target)
        add_pair(project_report, "clean_build", execution_mode,
                 ninja_clean_build, rb_clean_build)

        ninja_noop = repeated_result(lambda: ninja_build(build_target),
                                     args.noop_runs)
        rb_noop = repeated_result(lambda: rb_build(build_target),
                                  args.noop_runs)
        add_pair(project_report, "noop_rebuild", execution_mode,
                 ninja_noop, rb_noop)

        ninja_clean()
        rb_clean()
        ninja_after_clean = ninja_build(build_target)
        rb_cache_hit = rb_build(build_target)
        add_pair(project_report, "post_clean_rebuild", execution_mode,
                 ninja_after_clean, rb_cache_hit)

        if compiled:
            edit_source = compile_command_source(ninja_bin, source_needle)
            if edit_source and edit_source.exists():
                append_comment(edit_source, key)
                ninja_incremental = ninja_build(build_target)
                rb_incremental = rb_build(build_target)
                project_report.setdefault("incrementalSources", {})[
                    execution_mode] = str(edit_source)
                add_pair(project_report, "single_source_incremental_rebuild",
                         execution_mode, ninja_incremental, rb_incremental)
            else:
                project_report.setdefault("incrementalSkipped", {})[
                    execution_mode] = "compile command source not found"

            edit_header = header_incremental_source(key, mode_source)
            if edit_header and edit_header.exists():
                append_comment(edit_header, key)
                ninja_header_incremental = ninja_build(build_target)
                rb_header_incremental = rb_build(build_target)
                project_report.setdefault("incrementalHeaders", {})[
                    execution_mode] = str(edit_header)
                add_pair(project_report, "single_header_incremental_rebuild",
                         execution_mode, ninja_header_incremental,
                         rb_header_incremental)
            else:
                project_report.setdefault("incrementalHeaderSkipped", {})[
                    execution_mode] = "header benchmark source not found"

        if custom_seed:
            mode_custom_seed = mode_source / custom_seed.relative_to(source_dir)
            append_seed(mode_custom_seed, key)
            ninja_generated = ninja_build(build_target)
            rb_generated = rb_build(build_target)
            project_report.setdefault("customCommandInputs", {})[
                execution_mode] = str(mode_custom_seed)
            add_pair(project_report, "generated_source_custom_command_rebuild",
                     execution_mode, ninja_generated, rb_generated)
    finally:
        stop_runquota(rq_proc, rq_log)


def benchmark_project(args, context, key, source_dir, configure_args, build_target,
                      compiled, source_needle, custom_seed=None):
    project_report = {
        "key": key,
        "sourceDir": str(source_dir),
        "buildTarget": build_target,
        "compiledProject": compiled,
        "executionModes": selected_execution_modes(args.execution_mode),
        "scenarios": [],
        "ratios": [],
    }
    for execution_mode in selected_execution_modes(args.execution_mode):
        benchmark_project_mode(
            args, context, project_report, key, source_dir, execution_mode,
            configure_args, build_target, compiled, source_needle, custom_seed)
    return project_report


def selected_projects(profile, explicit):
    if explicit:
        return explicit
    if profile == "quick":
        return ["zlib"]
    if profile == "default":
        return ["zlib", "fmt", "nlohmann_json"]
    if profile == "medium":
        return ["zlib", "fmt", "nlohmann_json", "libuv"]
    fail(f"unknown profile: {profile}")


def build_report(args):
    cmake_root = args.cmake_root
    lock_file = cmake_root / "Tests" / "RunCMake" / "ReprobuildGenerator" / "real-project-locks.cmake"
    if not lock_file.exists():
        fail(f"missing real-project lock file: {lock_file}")
    _, locks = parse_locks(lock_file)

    cmake = resolve_executable(args.cmake, "forked cmake")
    repro = resolve_executable(args.repro, "repro")
    runquotad = resolve_executable(args.runquotad, "runquotad")
    ninja = find_ninja()

    c_compiler = args.c_compiler or cache_value(cmake, cmake_root / "build", "CMAKE_C_COMPILER") or which_first("cc", "gcc", "clang")
    cxx_compiler = args.cxx_compiler or cache_value(cmake, cmake_root / "build", "CMAKE_CXX_COMPILER") or which_first("c++", "g++", "clang++")
    if not c_compiler or not cxx_compiler:
        fail("could not resolve C and CXX compilers")

    if args.work_root.exists() and args.fresh:
        shutil.rmtree(args.work_root)
    args.work_root.mkdir(parents=True, exist_ok=True)
    source_cache = args.work_root / "source-cache"
    sources_root = args.work_root / "sources"
    generated_source = copy_generated_fixture(args.work_root / "fixtures" / "generated-custom-command")

    context = {
        "cmake": cmake,
        "ninja": ninja,
        "repro": repro,
        "runquotad": runquotad,
        "cCompiler": c_compiler,
        "cxxCompiler": cxx_compiler,
    }

    report = {
        "schema": "reprobuild.cmake-generator-competitiveness.v1",
        "generatedAt": json_now(),
        "profile": args.profile,
        "metadata": {
            "host": {
                "hostname": socket.gethostname(),
                "platform": platform.platform(),
                "machine": platform.machine(),
                "processor": platform.processor(),
                "cpuCount": os.cpu_count(),
            },
            "paths": {
                "reprobuildRoot": str(ROOT),
                "cmakeRoot": str(cmake_root),
                "workRoot": str(args.work_root),
                "lockFile": str(lock_file),
            },
            "tools": {
                "cmake": {"path": str(cmake), "version": command_version([cmake, "--version"])},
                "ninja": {"path": str(ninja), "version": command_version([ninja, "--version"])},
                "repro": {"path": str(repro), "version": command_version([repro, "--version"])},
                "runquotad": {"path": str(runquotad), "version": command_version([runquotad, "--help"])},
                "cCompiler": {"path": str(c_compiler), "version": command_version([c_compiler, "--version"])},
                "cxxCompiler": {"path": str(cxx_compiler), "version": command_version([cxx_compiler, "--version"])},
            },
            "parallel": args.parallel,
            "executionModes": selected_execution_modes(args.execution_mode),
            "noopRuns": args.noop_runs,
            "ninjaDiagnostics": {
                "enabled": args.ninja_diagnostics != "none",
                "mode": args.ninja_diagnostics,
            },
            "reprobuildDiagnostics": {
                "enabled": args.reprobuild_diagnostics != "none",
                "mode": args.reprobuild_diagnostics,
            },
            "reproBuildMode": os.environ.get("REPROBUILD_BUILD_MODE", ""),
            "thresholdControl": {
                "defaultEnv": "REPROBUILD_CMAKE_BENCH_MAX_RATIO",
                "scenarioEnvPrefix": "REPROBUILD_CMAKE_BENCH_MAX_RATIO_",
                "modeScenarioEnvPrefix": "REPROBUILD_CMAKE_BENCH_MAX_RATIO_",
                "defaultBehavior": "record-only",
            },
        },
        "projects": [],
        "ratioSummary": [],
    }

    project_keys = selected_projects(args.profile, args.projects)
    for key in project_keys:
        if key not in locks:
            fail(f"project {key} is not present in {lock_file}")
        project = locks[key]
        archive = ensure_archive(key, project, source_cache)
        source_dir = extract_project(key, project, archive, sources_root)
        compiled = bool_field(project, "EXPECT_COMPILE_ACTIONS")
        project_report = benchmark_project(
            args,
            context,
            key,
            source_dir,
            many(project, "CONFIGURE_ARGS"),
            one(project, "BUILD_TARGET", "all"),
            compiled,
            one(project, "COMPILE_COMMAND_NEEDLE"),
        )
        project_report["version"] = one(project, "VERSION")
        project_report["profile"] = one(project, "PROFILE")
        project_report["archive"] = str(archive)
        project_report["sha256"] = one(project, "SHA256")
        if key == "nlohmann_json":
            project_report["coverageNote"] = "header-only; not compile-performance proof"
        report["projects"].append(project_report)
        report["ratioSummary"].extend(project_report["ratios"])

    generated_report = benchmark_project(
        args,
        context,
        "generated_custom_command",
        generated_source,
        [],
        "genbench",
        True,
        "main.c",
        custom_seed=generated_source / "seed.txt",
    )
    generated_report["coverageNote"] = "local generated-source/custom-command fixture"
    report["projects"].append(generated_report)
    report["ratioSummary"].extend(generated_report["ratios"])

    failed_thresholds = [r for r in report["ratioSummary"] if r["status"] == "fail"]
    missing_ratios = [r for r in report["ratioSummary"] if r["ratioReprobuildToNinja"] is None]
    if missing_ratios:
        fail(f"missing ratio records: {missing_ratios}")
    if failed_thresholds:
        fail(f"benchmark ratio threshold failures: {failed_thresholds}")
    return report


def parse_args():
    parser = argparse.ArgumentParser(description=__doc__)
    default_parallel = int(os.environ.get("REPROBUILD_CMAKE_BENCH_PARALLEL", "1"))
    parser.add_argument("--profile", choices=["quick", "default", "medium"], default="default")
    parser.add_argument("--projects", nargs="*", default=None,
                        help="explicit real-project keys from real-project-locks.cmake")
    parser.add_argument("--work-root", type=Path,
                        default=ROOT / "build" / "cmake-generator-competitiveness")
    parser.add_argument("--output", type=Path,
                        default=ROOT / "bench-results" / "cmake-generator-competitiveness.json")
    parser.add_argument("--cmake-root", type=Path, default=DEFAULT_CMAKE_ROOT)
    parser.add_argument("--cmake", type=Path, default=DEFAULT_CMAKE_ROOT / "build" / "bin" / "cmake")
    parser.add_argument("--repro", type=Path, default=ROOT / "build" / "bin" / "repro")
    parser.add_argument("--runquotad", type=Path, default=DEFAULT_RUNQUOTA_ROOT / "build" / "bin" / "runquotad")
    parser.add_argument("--c-compiler", default="")
    parser.add_argument("--cxx-compiler", default="")
    parser.add_argument("--parallel", type=int, default=max(1, default_parallel))
    parser.add_argument("--execution-mode",
                        choices=["cmake-driver", "direct", "both"],
                        default="both",
                        help="build through cmake --build, direct native tools, or both")
    parser.add_argument("--ninja-diagnostics", choices=["stats", "none"], default="stats",
                        help="collect Ninja native diagnostics for Ninja build scenarios")
    parser.add_argument("--reprobuild-diagnostics", choices=["stats", "none"], default="stats",
                        help="collect Reprobuild diagnostics for Reprobuild build scenarios")
    parser.add_argument("--noop-runs", type=int,
                        default=int(os.environ.get(
                            "REPROBUILD_CMAKE_BENCH_NOOP_RUNS", "5")),
                        help="repeat no-op rebuild scenarios and report the median wall time")
    parser.add_argument("--fresh", action=argparse.BooleanOptionalAction, default=True)
    args = parser.parse_args()
    if args.noop_runs <= 0:
        fail("--noop-runs must be greater than zero")
    args.work_root = args.work_root.expanduser().resolve()
    args.output = args.output.expanduser().resolve()
    args.cmake_root = args.cmake_root.expanduser().resolve()
    args.cmake = args.cmake.expanduser().resolve()
    args.repro = args.repro.expanduser().resolve()
    args.runquotad = args.runquotad.expanduser().resolve()
    return args


def main():
    args = parse_args()
    try:
        report = build_report(args)
    except CommandFailure as exc:
        payload = {
            "schema": "reprobuild.cmake-generator-competitiveness.v1",
            "generatedAt": json_now(),
            "status": "failed",
            "failure": exc.result,
        }
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
        raise
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    print(str(args.output))


if __name__ == "__main__":
    main()
