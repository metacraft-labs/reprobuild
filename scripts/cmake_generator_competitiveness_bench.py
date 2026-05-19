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


def run_command(args, cwd=None, env=None, check=True):
    start = time.perf_counter()
    proc = subprocess.run(
        [str(arg) for arg in args],
        cwd=str(cwd) if cwd else None,
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
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
    if not path.exists() or not os.access(path, os.X_OK):
        fail(f"missing executable for {label}: {path}")
    return path


def find_ninja():
    found = shutil.which("ninja")
    if found:
        return Path(found)
    candidates = sorted(glob.glob("/nix/store/*ninja*/bin/ninja"))
    if candidates:
        return Path(candidates[0])
    fail("ninja is required for the CMake generator competitiveness benchmark")


def cache_value(cmake, build_dir, name):
    if not build_dir.exists():
        return ""
    result = run_command([cmake, "-LA", "-N", build_dir], check=False)
    if result["exitCode"] != 0:
        return ""
    pattern = re.compile(rf"^{re.escape(name)}:[^=]*=(.*)$", re.MULTILINE)
    match = pattern.search(result["stdoutTail"])
    return match.group(1).strip() if match else ""


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
            with urllib.request.urlopen(url) as response, archive.open("wb") as output:
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


def configure_project(cmake, ninja, generator, source_dir, binary_dir, c_compiler,
                      cxx_compiler, install_prefix, configure_args):
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
    return run_command(args)


def build_command(cmake, binary_dir, target, parallel):
    args = [cmake, "--build", binary_dir]
    if target:
        args.extend(["--target", target])
    if parallel:
        args.extend(["--parallel", str(parallel)])
    return args


def run_build(cmake, binary_dir, target, parallel, env=None):
    result = run_command(build_command(cmake, binary_dir, target, parallel), env=env)
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
    for _ in range(100):
        if socket_path.exists():
            return proc, socket_path, log
        if proc.poll() is not None:
            break
        time.sleep(0.05)
    proc.terminate()
    log.close()
    fail(f"runquotad socket did not appear: {socket_path}")


def stop_runquota(proc, log):
    if proc.poll() is None:
        proc.terminate()
        try:
            proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            proc.kill()
    log.close()


def repro_env(base_env, rb_bin, runquota_socket, binary_dir, parallel):
    env = dict(base_env)
    env.update({
        "RUNQUOTA_SOCKET": str(runquota_socket),
        "REPROBUILD_WORK_ROOT": str(binary_dir / "CMakeFiles" / "reprobuild" / "work-root"),
        "REPROBUILD_REPRO": str(rb_bin),
        "REPROBUILD_SOURCE_ROOT": str(ROOT),
        "REPROBUILD_MAX_PARALLELISM": str(max(1, parallel)),
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


def append_comment(path, label):
    with path.open("a") as handle:
        handle.write(f"\n/* reprobuild benchmark edit {label} {time.time_ns()} */\n")


def append_seed(path, label):
    with path.open("a") as handle:
        handle.write(f"\n{label}-{time.time_ns()}\n")


def scenario_name_env(name):
    return "REPROBUILD_CMAKE_BENCH_MAX_RATIO_" + re.sub(r"[^A-Z0-9]+", "_", name.upper()).strip("_")


def ratio_record(project_key, scenario, ninja_result, rb_result):
    ratio = None
    if ninja_result["wallMs"] > 0:
        ratio = rb_result["wallMs"] / ninja_result["wallMs"]
    threshold_env = scenario_name_env(scenario)
    threshold = os.environ.get(threshold_env) or os.environ.get("REPROBUILD_CMAKE_BENCH_MAX_RATIO")
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
        "ratioReprobuildToNinja": round(ratio, 4) if ratio is not None else None,
        "ninjaWallMs": ninja_result["wallMs"],
        "reprobuildWallMs": rb_result["wallMs"],
        "threshold": threshold_value,
        "status": status,
    }


def add_pair(project_report, scenario, ninja_result, rb_result):
    project_report["scenarios"].append({"name": scenario, "generator": "Ninja", **ninja_result})
    project_report["scenarios"].append({"name": scenario, "generator": "Reprobuild", **rb_result})
    project_report["ratios"].append(ratio_record(project_report["key"], scenario, ninja_result, rb_result))


def benchmark_project(args, context, key, source_dir, configure_args, build_target,
                      compiled, source_needle, custom_seed=None):
    cmake = context["cmake"]
    ninja = context["ninja"]
    rb_bin = context["repro"]
    runquotad = context["runquotad"]
    c_compiler = context["cCompiler"]
    cxx_compiler = context["cxxCompiler"]
    parallel = args.parallel
    base_env = os.environ.copy()

    project_root = args.work_root / "projects" / key
    ninja_bin = project_root / "ninja-build"
    rb_bin_dir = project_root / "reprobuild-build"

    project_report = {
        "key": key,
        "sourceDir": str(source_dir),
        "buildTarget": build_target,
        "compiledProject": compiled,
        "scenarios": [],
        "ratios": [],
    }

    ninja_configure = configure_project(
        cmake, ninja, "Ninja", source_dir, ninja_bin, c_compiler, cxx_compiler,
        project_root / "ninja-install", configure_args)
    rb_configure = configure_project(
        cmake, ninja, "Reprobuild", source_dir, rb_bin_dir, c_compiler, cxx_compiler,
        project_root / "reprobuild-install", configure_args)
    add_pair(project_report, "configure", ninja_configure, rb_configure)

    rq_proc, rq_socket, rq_log = start_runquota(runquotad, project_root / "runquota")
    rb_env = repro_env(base_env, rb_bin, rq_socket, rb_bin_dir, parallel)
    try:
        ninja_clean = run_build(cmake, ninja_bin, build_target, parallel)
        rb_clean = run_build(cmake, rb_bin_dir, build_target, parallel, env=rb_env)
        add_pair(project_report, "clean_build", ninja_clean, rb_clean)

        ninja_noop = run_build(cmake, ninja_bin, build_target, parallel)
        rb_noop = run_build(cmake, rb_bin_dir, build_target, parallel, env=rb_env)
        add_pair(project_report, "noop_rebuild", ninja_noop, rb_noop)

        run_build(cmake, ninja_bin, "clean", parallel)
        run_build(cmake, rb_bin_dir, "clean", parallel, env=rb_env)
        ninja_after_clean = run_build(cmake, ninja_bin, build_target, parallel)
        rb_cache_hit = run_build(cmake, rb_bin_dir, build_target, parallel, env=rb_env)
        add_pair(project_report, "post_clean_rebuild", ninja_after_clean, rb_cache_hit)

        if compiled:
            edit_source = compile_command_source(ninja_bin, source_needle)
            if edit_source and edit_source.exists():
                append_comment(edit_source, key)
                ninja_incremental = run_build(cmake, ninja_bin, build_target, parallel)
                rb_incremental = run_build(cmake, rb_bin_dir, build_target, parallel, env=rb_env)
                project_report["incrementalSource"] = str(edit_source)
                add_pair(project_report, "single_source_incremental_rebuild", ninja_incremental, rb_incremental)
            else:
                project_report["incrementalSkipped"] = "compile command source not found"

        if custom_seed:
            append_seed(custom_seed, key)
            ninja_generated = run_build(cmake, ninja_bin, build_target, parallel)
            rb_generated = run_build(cmake, rb_bin_dir, build_target, parallel, env=rb_env)
            project_report["customCommandInput"] = str(custom_seed)
            add_pair(project_report, "generated_source_custom_command_rebuild", ninja_generated, rb_generated)
    finally:
        stop_runquota(rq_proc, rq_log)

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

    c_compiler = args.c_compiler or cache_value(cmake, cmake_root / "build", "CMAKE_C_COMPILER") or shutil.which("cc")
    cxx_compiler = args.cxx_compiler or cache_value(cmake, cmake_root / "build", "CMAKE_CXX_COMPILER") or shutil.which("c++")
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
            "thresholdControl": {
                "defaultEnv": "REPROBUILD_CMAKE_BENCH_MAX_RATIO",
                "scenarioEnvPrefix": "REPROBUILD_CMAKE_BENCH_MAX_RATIO_",
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
    parser.add_argument("--fresh", action=argparse.BooleanOptionalAction, default=True)
    return parser.parse_args()


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
