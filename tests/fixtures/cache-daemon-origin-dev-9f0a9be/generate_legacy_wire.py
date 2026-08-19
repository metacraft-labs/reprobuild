#!/usr/bin/env python3
"""Materialize the minimally backported legacy-wire cache peer sources.

The seven inputs are immutable blobs from origin/dev 9f0a9be. Five outputs
are byte-identical copies. The top-level and segment modules receive only the
Darwin authoritative-boot-ID/fail-closed and v2 lifecycle-name backports.
Every replacement is cardinality checked so upstream fixture drift fails hard.
"""

from __future__ import annotations

import argparse
import hashlib
from pathlib import Path


FIXTURE_ROOT = Path(__file__).resolve().parent
ORIGIN_ROOT = FIXTURE_ROOT / "origin"

EXPECTED_SHA256 = {
    "libs/repro_shm_index/src/repro_shm_index.nim":
        "57bf88eefa2aeb56aef99d6d55c4389bb9259eb4c62e2c7eb5f169f514bd50a7",
    "libs/repro_shm_index/src/repro_shm_index/atomics_shm.nim":
        "a89a51f03c392cd19eaf62ab98ed3c9230b21c4241de440fe08041a3d5e84db3",
    "libs/repro_shm_index/src/repro_shm_index/daemon.nim":
        "784ce21505438b1ea3f8a8852c7e3b9a15b77deef262f79efe86dddde596c38d",
    "libs/repro_shm_index/src/repro_shm_index/layout.nim":
        "daa2e5ad60068a870c540330f17d048166ea2a94f2503b59211a71d4f468ca90",
    "libs/repro_shm_index/src/repro_shm_index/mapping.nim":
        "69b386e94f361ef3ef022d41fab410e1fcd71f59b005d8123e1a672af42d0d7e",
    "libs/repro_shm_index/src/repro_shm_index/ring.nim":
        "5abcfc356548c2ed4cca29383e0e2743ba591fd771abc806d0618f4f607cf61a",
    "libs/repro_shm_index/src/repro_shm_index/segment.nim":
        "7ef1f67fad11de6b698b5201d95d6e7f2d5e85db521e5d8d6b24053416c23a4b",
}

MAC_BOOT_HELPER = '''
when defined(macosx):
  {.emit: """
    #include <stdint.h>
    #include <sys/sysctl.h>
    #include <sys/time.h>
    static uint64_t repro_legacy_wire_boot_id(void) {
      struct timeval boot_time;
      size_t size = sizeof(boot_time);
      if (sysctlbyname("kern.boottime", &boot_time, &size, NULL, 0) != 0 ||
          size != sizeof(boot_time) || boot_time.tv_sec <= 0 ||
          boot_time.tv_usec < 0 || boot_time.tv_usec >= 1000000) {
        return 0;
      }
      return (((uint64_t)boot_time.tv_sec) << 20) |
             (uint64_t)boot_time.tv_usec;
    }
  """.}
  proc macBootId(): uint64
    {.importc: "repro_legacy_wire_boot_id", nodecl.}
'''

OLD_BOOT_ID = '''proc bootId*(): uint64 =
  ## A per-boot identity used to invalidate stale shm regions after a reboot
  ## (§4.1 creatorBootId). On Linux the kernel boot_id; elsewhere a stable-per-
  ## boot fallback derived from a monotonic reference. Zero is never returned.
  when defined(linux):
    try:
      let raw = readFile("/proc/sys/kernel/random/boot_id")
      var h: uint64 = 1469598103934665603'u64      # FNV-1a offset basis
      for ch in raw:
        if ch != '-' and ch != '\\n':
          h = (h xor uint64(ord(ch))) * 1099511628211'u64
      return (h or 1'u64)
    except CatchableError:
      discard
  # Fallback: boot time inferred as (now - uptime) rounded to seconds. Stable
  # across a single boot, changes across reboots.
  let secs = uint64(epochTime().int64)
  (secs or 1'u64)
'''

NEW_BOOT_ID = '''proc bootId*(): uint64 =
  ## The Linux behavior is the pinned implementation. Darwin alone receives
  ## the authoritative kernel boot identity required by lifecycle namespace 2.
  when defined(linux):
    try:
      let raw = readFile("/proc/sys/kernel/random/boot_id")
      var h: uint64 = 1469598103934665603'u64      # FNV-1a offset basis
      for ch in raw:
        if ch != '-' and ch != '\\n':
          h = (h xor uint64(ord(ch))) * 1099511628211'u64
      return (h or 1'u64)
    except CatchableError:
      discard
  elif defined(macosx):
    return macBootId()
  # Preserve the pinned fallback on every other platform (and on Linux when
  # its authoritative boot-id file is unavailable).
  let secs = uint64(epochTime().int64)
  (secs or 1'u64)
'''


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise RuntimeError(f"{label}: expected one replacement, found {count}")
    return text.replace(old, new)


def transformed(relative: str, raw: bytes) -> bytes:
    if relative not in {
        "libs/repro_shm_index/src/repro_shm_index.nim",
        "libs/repro_shm_index/src/repro_shm_index/segment.nim",
    }:
        return raw

    text = raw.decode("utf-8")
    if relative.endswith("src/repro_shm_index.nim"):
        anchor = "  export mapping.MappedRegion, mapping.isValid, mapping.detach\n"
        text = replace_once(text, anchor, anchor + MAC_BOOT_HELPER, "boot helper")
        text = replace_once(text, OLD_BOOT_ID, NEW_BOOT_ID, "boot identity")
        text = replace_once(
            text,
            '  proc ctlPath*(cacheRoot: string): string =\n'
            '    cacheRoot / "action-index.ctl"\n',
            '  proc ctlPath*(cacheRoot: string): string =\n'
            '    when defined(macosx):\n'
            '      cacheRoot / "action-index-v2.ctl"\n'
            '    else:\n'
            '      cacheRoot / "action-index.ctl"\n',
            "control namespace",
        )
        text = replace_once(
            text,
            "    let boot = bootId()\n    createDir(cacheRoot)\n",
            "    let boot = bootId()\n"
            "    if boot == 0:\n      return\n"
            "    createDir(cacheRoot)\n",
            "boot identity fail closed",
        )
    else:
        text = replace_once(
            text,
            'proc segPath*(cacheRoot: string; gen: uint32): string =\n'
            '  cacheRoot / ("action-index." & $gen & ".seg")\n',
            'proc segPath*(cacheRoot: string; gen: uint32): string =\n'
            '  when defined(macosx):\n'
            '    cacheRoot / ("action-index-v2." & $gen & ".seg")\n'
            '  else:\n'
            '    cacheRoot / ("action-index." & $gen & ".seg")\n',
            "segment namespace",
        )
    return text.encode("utf-8")


def origin_sources() -> dict[str, bytes]:
    result: dict[str, bytes] = {}
    for relative, expected in EXPECTED_SHA256.items():
        raw = (ORIGIN_ROOT / relative).read_bytes()
        actual = hashlib.sha256(raw).hexdigest()
        if actual != expected:
            raise RuntimeError(
                f"origin fixture drift for {relative}: {actual} != {expected}"
            )
        result[relative] = raw
    return result


def materialize(output_root: Path, sources: dict[str, bytes]) -> None:
    tree_digest = hashlib.sha256()
    for relative in sorted(sources):
        output = transformed(relative, sources[relative])
        destination = output_root / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        if not destination.exists() or destination.read_bytes() != output:
            destination.write_bytes(output)
        tree_digest.update(relative.encode("utf-8") + b"\0" + output)
    print(f"legacy_wire_tree_sha256={tree_digest.hexdigest()}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check-origin", action="store_true")
    parser.add_argument("--output-root", type=Path)
    args = parser.parse_args()
    if not args.check_origin and args.output_root is None:
        parser.error("one of --check-origin or --output-root is required")
    sources = origin_sources()
    if args.output_root is not None:
        materialize(args.output_root, sources)
    else:
        print(f"verified_origin_file_count={len(sources)}")


if __name__ == "__main__":
    main()
