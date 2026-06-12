#!/usr/bin/env python3
"""Boot-test harness CLI entrypoint.

Subcommands:

  validate --backend=<hyperv|wsl2|qemu>
      Smoke-check that the named backend's external dependency is
      reachable. Exits 0 if usable, non-zero otherwise. Used by R0
      verification + CI to skip end-to-end tests that can't run.

  list
      Enumerate which backends are usable on the current host.

  boot --backend=<…> --image=<path> [--expect=<json>] [--dry-run]
      Boot ``--image`` in the named backend, run the assertions in the
      ``--expect`` JSON file, write the JSON outcome under
      ``boot-harness-out/<image-sha256>/<timestamp>.json``, exit 0 on
      PASS / non-zero otherwise. With ``--dry-run``, only the Hyper-V
      backend is meaningful: it creates + destroys a VM with no boot
      media to verify lifecycle plumbing.
"""

from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path

_HERE = Path(__file__).resolve().parent
if str(_HERE) not in sys.path:
    sys.path.insert(0, str(_HERE))

from lib import backends as backends_pkg  # noqa: E402
from lib.assertions import BootAssertion, BootAssertionError  # noqa: E402
from lib.outcome import Outcome, default_out_root, sha256_file, utc_now_iso  # noqa: E402


BACKENDS = ("hyperv", "wsl2", "qemu")


def cmd_validate(args: argparse.Namespace) -> int:
    mod = backends_pkg.load(args.backend)
    ok, msg = mod.validate()
    prefix = "OK" if ok else "FAIL"
    print(f"[validate {args.backend}] {prefix}: {msg}")
    return 0 if ok else 2


def cmd_list(_args: argparse.Namespace) -> int:
    rc = 0
    for name in BACKENDS:
        mod = backends_pkg.load(name)
        ok, msg = mod.validate()
        flag = "OK" if ok else "--"
        print(f"  {flag:<3} {name:<7} {msg}")
        if not ok:
            rc = rc or 0  # listing is informational; never fail.
    return rc


def _load_assertions(path: Path) -> list[BootAssertion]:
    raw = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(raw, list):
        raise ValueError(f"expect file must be a JSON array, got {type(raw).__name__}")
    out: list[BootAssertion] = []
    for item in raw:
        out.append(
            BootAssertion(
                expect_line=item.get("expect_line"),
                timeout_s=float(item.get("timeout_s", 60.0)),
                expect_within=item.get("expect_within"),
                send_after_match=item.get("send_after_match"),
                description=item.get("description", ""),
            )
        )
    return out


def _build_session(backend: str, image: Path | None, *, dry_run: bool):
    if backend == "qemu":
        from lib.backends.qemu import QEMUConfig, QEMUSession
        if image is None:
            raise ValueError("qemu backend requires --image")
        cfg = QEMUConfig(image_path=image, image_kind="iso")
        return QEMUSession(cfg)
    if backend == "wsl2":
        from lib.backends.wsl2 import WSL2Config, WSL2Session
        if image is None:
            raise ValueError("wsl2 backend requires --image (tarball rootfs)")
        return WSL2Session(WSL2Config(rootfs_tar=image))
    if backend == "hyperv":
        from lib.backends.hyperv import HyperVConfig, HyperVSession
        return HyperVSession(HyperVConfig(image_path=image, dry_run=dry_run,
                                          image_kind="iso" if image else "iso"))
    raise ValueError(f"unknown backend {backend!r}")


def cmd_boot(args: argparse.Namespace) -> int:
    image: Path | None = Path(args.image).resolve() if args.image else None
    if image is not None and not image.is_file():
        print(f"image not found: {image}", file=sys.stderr)
        return 4

    image_sha = sha256_file(image) if image is not None else "dry-run"
    image_str = str(image) if image is not None else ""
    out_root = default_out_root(_HERE.parents[1])

    assertions: list[BootAssertion] = []
    if args.expect:
        assertions = _load_assertions(Path(args.expect))

    started = utc_now_iso()
    error_message = ""
    records: list = []
    vm_name = ""
    serial_log_path = ""
    status = "ERROR"

    session = None
    try:
        session = _build_session(args.backend, image, dry_run=args.dry_run)
        vm_name = session.cfg.vm_name
        serial_log_path = str(session.cfg.serial_log_path) if session.cfg.serial_log_path else ""
        session.start()
        if args.dry_run:
            # Lifecycle smoke: nothing to assert. Sleep briefly to ensure
            # state has stabilised on the Hyper-V side, then close.
            time.sleep(1.0)
            status = "PASS"
        else:
            records = session.run_assertions(assertions)
            n_failed = sum(1 for r in records if not r.matched)
            status = "PASS" if n_failed == 0 and records else ("FAIL" if records else "PASS")
    except BootAssertionError as exc:
        status = "TIMEOUT" if "timeout" in str(exc).lower() else "FAIL"
        error_message = str(exc)
    except Exception as exc:  # noqa: BLE001
        status = "ERROR"
        error_message = f"{type(exc).__name__}: {exc}"
    finally:
        if session is not None:
            try:
                session.close()
            except Exception as exc:  # noqa: BLE001
                error_message = (error_message + f"\nclose: {exc}").strip()

    finished = utc_now_iso()
    outcome = Outcome(
        backend=args.backend,
        image_sha256=image_sha,
        image_path=image_str,
        started_at=started,
        finished_at=finished,
        outcome=status,
        assertions_passed=sum(1 for r in records if r.matched),
        assertions_failed=sum(1 for r in records if not r.matched),
        serial_log_path=serial_log_path,
        vm_name=vm_name,
        error_message=error_message,
        assertions=[r.to_dict() for r in records],
    )
    target = outcome.write(out_root)
    print(f"[boot {args.backend}] {status}; wrote {target}")
    if error_message:
        print(f"  error: {error_message}", file=sys.stderr)
    return 0 if status == "PASS" else 1


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(prog="harness.py", description=__doc__)
    sub = p.add_subparsers(dest="cmd", required=True)

    v = sub.add_parser("validate", help="check backend availability")
    v.add_argument("--backend", required=True, choices=BACKENDS)
    v.set_defaults(func=cmd_validate)

    l = sub.add_parser("list", help="list backend availability")
    l.set_defaults(func=cmd_list)

    b = sub.add_parser("boot", help="boot image, run assertions, emit JSON outcome")
    b.add_argument("--backend", required=True, choices=BACKENDS)
    b.add_argument("--image", default=None, help="path to ISO/VHDX/rootfs.tar")
    b.add_argument("--expect", default=None, help="path to assertion JSON file")
    b.add_argument("--dry-run", action="store_true", help="lifecycle smoke only (hyperv)")
    b.set_defaults(func=cmd_boot)

    args = p.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
