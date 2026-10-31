#!/usr/bin/env python3
"""CONF-1, CONF-3 and CONF-4 for the Distributed-Execution worker unit.

deployment-security-architecture.md §4.4; threat model G33 (the shell version
of this check accepted wildcards for the list settings, read only the FIRST
occurrence of a key — so a later `ProtectSystem=no` passed — and counted any
`CONF-1 omission:` line that merely mentioned a key as its argument).

    check_daemon_worker_unit_confinement.py              check the shipped unit
    check_daemon_worker_unit_confinement.py --self-test  prove each rule bites
    check_daemon_worker_unit_confinement.py UNIT         check another unit file

1. CONF-1: the EFFECTIVE value of every floor setting — systemd semantics:
   the last assignment wins for a scalar, list settings accumulate and an
   empty assignment resets them — is the floor value, or is argued in the
   unit by a line `# CONF-1 omission: <Key>=<the effective value>` naming
   exactly that key and value. The list settings are validated, not
   wildcarded: `RestrictAddressFamilies` is an allow-list of the families the
   worker uses; `RestrictNamespaces` an allow-list of the namespaces a lease
   is built from; `SystemCallFilter` keeps `@system-service` and denies
   `@privileged @resources @obsolete`; `IPAddressDeny=any` with a specific
   `IPAddressAllow`.
2. CONF-3: the unit's re-allowed syscalls (its last `SystemCallFilter=`) are
   exactly recipes/repro-daemon-worker/syscalls, and (Linux) the lease
   floor's header is the one scripts/derive_lease_floor_syscalls.py derives.
3. CONF-4 (Linux): `systemd-analyze security --offline` of the rendered unit
   does not exceed recipes/repro-daemon-worker/confinement-threshold. The
   verdict is read from the analysis' own "Overall exposure level" line: a
   `systemd-analyze` that exits non-zero WITHOUT one did not analyse the unit
   (it could not start, could not parse it, ...) and is reported as that, never
   as an exposure over the threshold.

Both Linux checks run the dev shell's pinned `systemd-analyze`
(`$REPRO_SYSTEMD_ANALYZE`, resolved by derive_lease_floor_syscalls.py), never
the host's; see that script's docstring for why.
"""

import os
import re
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from derive_lease_floor_syscalls import SystemdAnalyzeUnavailable, systemd_analyze  # noqa: E402

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
UNIT = os.path.join(ROOT, "recipes", "repro-daemon-worker", "systemd-units",
                    "repro-daemon-worker.service")
SYSCALLS = os.path.join(ROOT, "recipes", "repro-daemon-worker", "syscalls")
THRESHOLD = os.path.join(ROOT, "recipes", "repro-daemon-worker", "confinement-threshold")

# Scalar floor settings and their floor value.
SCALAR_FLOOR = {
    "NoNewPrivileges": "yes", "ProtectSystem": "strict", "ProtectHome": "yes",
    "PrivateTmp": "yes", "PrivateDevices": "yes", "ProtectKernelTunables": "yes",
    "ProtectKernelModules": "yes", "ProtectKernelLogs": "yes",
    "ProtectControlGroups": "yes", "ProtectClock": "yes",
    "ProtectProc": "invisible", "ProcSubset": "pid", "RestrictRealtime": "yes",
    "RestrictSUIDSGID": "yes", "LockPersonality": "yes",
    "SystemCallArchitectures": "native", "MemoryDenyWriteExecute": "yes",
    "UMask": "0077", "IPAddressDeny": "any",
}
LIST_KEYS = {"SystemCallFilter", "RestrictAddressFamilies", "RestrictNamespaces",
             "IPAddressAllow", "IPAddressDeny", "CapabilityBoundingSet",
             "ReadWritePaths", "ExecPaths", "NoExecPaths"}
ALLOWED_FAMILIES = {"AF_INET", "AF_INET6", "AF_UNIX", "AF_NETLINK"}
ALLOWED_NAMESPACES = {"user", "mnt", "net", "pid", "ipc", "uts"}
SUBSTITUTIONS = {"@REPRO@": "/nix/store/0000000000000000000000000000000-reprobuild/bin/repro",
                 "@CIDR@": "100.83.0.0/16", "@IFACE@": "wt0",
                 "@SINK@": "100.83.0.10:7900", "@SINK_IP@": "100.83.0.10",
                 "@FLEET_CIDR@": "100.83.0.0/16", "@EGRESS_IPS@": "100.83.0.20",
                 "@SIGNER@": "100.83.0.11:7901", "@SIGNER_IP@": "100.83.0.11",
                 "@PATH@": "/run/current-system/sw/bin"}


class Failure(Exception):
    pass


def parse_service(text):
    """(assignments in order, omission arguments) of the [Service] section."""
    assignments, omissions = [], {}
    section = None
    logical = ""
    for raw in text.splitlines():
        line = raw.rstrip()
        stripped = line.strip()
        m = re.match(r"^#\s*CONF-1 omission:\s*([A-Za-z]+)=(\S*)", stripped)
        if m:
            omissions.setdefault(m.group(1), []).append(m.group(2).rstrip(".,;"))
            continue
        if logical == "" and (stripped.startswith("#") or stripped.startswith(";") or not stripped):
            continue
        if stripped.startswith("[") and logical == "":
            section = stripped
            continue
        if line.endswith("\\"):
            logical += line[:-1] + " "
            continue
        logical += line
        if section == "[Service]" and "=" in logical:
            key, value = logical.split("=", 1)
            assignments.append((key.strip(), value.strip()))
        logical = ""
    return assignments, omissions


def effective(assignments):
    """systemd's resulting value per key: scalars last-wins; lists
    accumulate (an empty assignment resets)."""
    eff = {}
    for key, value in assignments:
        if key in LIST_KEYS:
            if value == "":
                eff[key] = []
            else:
                eff.setdefault(key, []).append(value)
        else:
            eff[key] = value
    return eff


def argued(omissions, key, value):
    return value in omissions.get(key, [])


def check_conf1(text):
    assignments, omissions = parse_service(text)
    eff = effective(assignments)
    for key, want in SCALAR_FLOOR.items():
        if key == "IPAddressDeny":
            continue
        if key not in eff:
            raise Failure("CONF-1: %s is neither set nor argued" % key)
        got = eff[key]
        if got != want and not argued(omissions, key, got):
            raise Failure("CONF-1: %s=%s is not the floor value (%s) and no "
                          "'# CONF-1 omission: %s=%s' line argues it" % (key, got, want, key, got))
    # User: a dedicated account, never root.
    user = eff.get("User", "")
    if user in ("", "root", "0") and not eff.get("DynamicUser") == "yes":
        raise Failure("CONF-1: the unit runs as root (User=%s)" % user)
    for key in ("StateDirectory", "ReadWritePaths"):
        if not eff.get(key):
            raise Failure("CONF-1: %s is not set" % key)
    for path in " ".join(eff.get("ReadWritePaths", [])).split():
        if path in ("/", "/var", "/var/lib", "/home", "/etc", "/nix"):
            raise Failure("CONF-1: ReadWritePaths includes %s" % path)
    # RestrictAddressFamilies: an allow-list of what the worker uses.
    fams = " ".join(eff.get("RestrictAddressFamilies", [])).split()
    if not fams or fams[0].startswith("~") or any(f.startswith("~") for f in fams):
        raise Failure("CONF-1: RestrictAddressFamilies must be an allow-list, got %r" % fams)
    if fams != ["none"] and not set(fams) <= ALLOWED_FAMILIES:
        raise Failure("CONF-1: RestrictAddressFamilies allows %s"
                      % sorted(set(fams) - ALLOWED_FAMILIES))
    # RestrictNamespaces: yes, or exactly the namespaces a lease is built of.
    ns = " ".join(eff.get("RestrictNamespaces", [])).split()
    if not ns or any(n.startswith("~") for n in ns) or "no" in ns or "false" in ns:
        raise Failure("CONF-1: RestrictNamespaces must restrict, got %r" % ns)
    if ns != ["yes"] and not set(ns) <= ALLOWED_NAMESPACES:
        raise Failure("CONF-1: RestrictNamespaces allows %s" % sorted(set(ns) - ALLOWED_NAMESPACES))
    # SystemCallFilter: @system-service kept, the floor's groups denied, and
    # nothing re-allowed wholesale.
    filters = eff.get("SystemCallFilter", [])
    if not filters:
        raise Failure("CONF-1: SystemCallFilter is not set (or reset by an empty assignment)")
    allows = [f for f in filters if not f.startswith("~")]
    denies = [f for f in filters if f.startswith("~")]
    if not any("@system-service" in a.split() for a in allows):
        raise Failure("CONF-1: SystemCallFilter does not keep @system-service")
    denied = set(" ".join(d[1:] for d in denies).split())
    for group in ("@privileged", "@resources", "@obsolete"):
        if group not in denied:
            raise Failure("CONF-1: SystemCallFilter does not deny %s" % group)
    for a in allows:
        for item in a.split():
            if item in ("@privileged", "@resources", "@obsolete", "@raw-io",
                        "@module", "@mount", "@reboot", "@swap", "@debug", "@cpu-emulation"):
                raise Failure("CONF-1: SystemCallFilter re-allows the group %s" % item)
    # IPAddressDeny=any and a specific allow-list.
    deny = " ".join(eff.get("IPAddressDeny", [])).split()
    if deny != ["any"]:
        raise Failure("CONF-1: IPAddressDeny must be exactly 'any', got %r" % deny)
    allow = " ".join(eff.get("IPAddressAllow", [])).split()
    if not allow:
        raise Failure("CONF-1: IPAddressAllow is empty")
    for a in allow:
        if a in ("any", "0.0.0.0/0", "::/0", "0.0.0.0", "::"):
            raise Failure("CONF-1: IPAddressAllow includes the wildcard %s" % a)
    # CapabilityBoundingSet: empty, or argued value by value.
    caps = " ".join(eff.get("CapabilityBoundingSet", [])).split()
    if any(c.startswith("~") for c in caps):
        raise Failure("CONF-1: CapabilityBoundingSet is a deny-list (~)")
    if caps and not argued(omissions, "CapabilityBoundingSet", caps[0]):
        raise Failure("CONF-1: CapabilityBoundingSet=%s is not empty and not argued" % " ".join(caps))
    for c in caps:
        if c not in ("CAP_SETUID", "CAP_SETGID"):
            raise Failure("CONF-1: CapabilityBoundingSet holds %s" % c)
    return eff


def check_conf3(eff):
    derived = sorted({l.strip() for l in open(SYSCALLS) if l.strip() and not l.startswith("#")})
    last = eff.get("SystemCallFilter", [""])[-1]
    in_unit = sorted(set(last.split()))
    if derived != in_unit:
        raise Failure("CONF-3: the unit's re-allowed syscalls (%s) differ from the derived "
                      "list (%s); re-run scripts/profile_daemon_worker_syscalls.sh"
                      % (" ".join(in_unit), " ".join(derived)))


def render(text):
    for k, v in SUBSTITUTIONS.items():
        text = text.replace(k, v)
    return text


# systemd-analyze's closing verdict line, e.g.
# `→ Overall exposure level for repro-daemon-worker.service: 2.6 OK 🙂`
# (src/analyze/analyze-security.c).
EXPOSURE_LINE = re.compile(r"Overall exposure level for \S+: (\d+)\.(\d)\b")


def check_conf4(text):
    with open(THRESHOLD) as f:
        threshold = f.read().strip()
    try:
        analyze = systemd_analyze()
    except SystemdAnalyzeUnavailable as err:
        raise Failure("CONF-4: " + str(err))
    with tempfile.TemporaryDirectory() as tmp:
        path = os.path.join(tmp, "repro-daemon-worker.service")
        with open(path, "w") as f:
            f.write(render(text))
        out = subprocess.run([analyze, "security", "--offline=true",
                              "--threshold=" + threshold, path],
                             capture_output=True, text=True)
    output = out.stdout + out.stderr
    verdict = EXPOSURE_LINE.search(output)
    if verdict is None:
        # No analysis happened, so there is no exposure to report: saying
        # "exceeds the threshold" here sent a reader to the unit for what was
        # a loader crash of the binary (the glibc mix under LD_LIBRARY_PATH).
        tail = "\n".join(output.splitlines()[-25:])
        raise Failure("CONF-4: %s failed to analyse repro-daemon-worker.service (exit %d, "
                      "no exposure verdict in its output):\n%s"
                      % (analyze, out.returncode, tail))
    exposure = int(verdict.group(1)) * 10 + int(verdict.group(2))
    if exposure > int(threshold):
        sys.stderr.write("\n".join(output.splitlines()[-25:]) + "\n")
        raise Failure("CONF-4: exposure of repro-daemon-worker.service, %d.%d, exceeds the "
                      "committed threshold %s (%s)"
                      % (exposure // 10, exposure % 10, threshold, analyze))
    if out.returncode != 0:
        # `--threshold` makes systemd-analyze fail only above it; failing at
        # or below it is some other error, and is reported as one.
        raise Failure("CONF-4: %s exited %d although it measured %d.%d, within the "
                      "threshold %s:\n%s"
                      % (analyze, out.returncode, exposure // 10, exposure % 10, threshold,
                         "\n".join(output.splitlines()[-25:])))
    print(verdict.group(0) + " (" + analyze + ")")
    return threshold


def check(text, linux_checks):
    eff = check_conf1(text)
    check_conf3(eff)
    if not linux_checks:
        return None
    threshold = check_conf4(text)
    deriver = os.path.join(ROOT, "scripts", "derive_lease_floor_syscalls.py")
    out = subprocess.run([sys.executable, deriver, "--check"], capture_output=True, text=True)
    if out.returncode != 0:
        raise Failure("CONF-3 (lease floor): " + (out.stderr or out.stdout).strip())
    return threshold


def self_test():
    """Every rule bites: each mutation of the shipped unit must fail, and the
    shipped unit must pass."""
    text = open(UNIT).read()
    check_conf1(text)
    mutations = {
        "a later ProtectSystem=no": text.replace("[Install]", "ProtectSystem=no\n\n[Install]"),
        "a mention that is not an argument": text.replace(
            "ProtectHome=yes", "# CONF-1 omission: this mentions ProtectHome\nProtectHome=no"),
        "an argument for another value": re.sub(r"(?m)^MemoryDenyWriteExecute=no$",
                                                "MemoryDenyWriteExecute=false", text),
        "a deny-list of families": re.sub(r"(?m)^RestrictAddressFamilies=.*$",
                                          "RestrictAddressFamilies=~AF_PACKET", text),
        "a family nothing uses": re.sub(r"(?m)^RestrictAddressFamilies=.*$",
                                        "RestrictAddressFamilies=AF_INET AF_PACKET", text),
        "namespaces unrestricted": re.sub(r"(?m)^RestrictNamespaces=.*$",
                                          "RestrictNamespaces=no", text),
        "a cgroup namespace": re.sub(r"(?m)^RestrictNamespaces=.*$",
                                     "RestrictNamespaces=user mnt net pid ipc uts cgroup", text),
        "the filter reset": text.replace("[Install]", "SystemCallFilter=\n\n[Install]"),
        "a group re-allowed": text.replace("[Install]", "SystemCallFilter=@mount\n\n[Install]"),
        "@privileged no longer denied": text.replace(
            "SystemCallFilter=~@privileged @resources @obsolete",
            "SystemCallFilter=~@resources @obsolete"),
        "a wildcard IPAddressAllow": text.replace("[Install]", "IPAddressAllow=any\n\n[Install]"),
        "IPAddressDeny weakened": re.sub(r"(?m)^IPAddressDeny=.*$", "IPAddressDeny=", text),
        "a capability nobody argued": re.sub(r"(?m)^CapabilityBoundingSet=.*$",
                                             "CapabilityBoundingSet=CAP_SETUID CAP_SYS_ADMIN", text),
        "root": re.sub(r"(?m)^User=.*$", "User=root", text),
        "ReadWritePaths=/": re.sub(r"(?m)^ReadWritePaths=.*$", "ReadWritePaths=/", text),
    }
    failures = []
    for name, mutated in mutations.items():
        if mutated == text:
            failures.append("mutation did not apply: " + name)
            continue
        try:
            check_conf1(mutated)
            failures.append("NOT caught: " + name)
        except Failure:
            pass
    if failures:
        for f in failures:
            sys.stderr.write("self-test: " + f + "\n")
        return 1
    print("self-test ok: %d mutations of the unit each fail CONF-1; the unit passes" % len(mutations))
    return 0


def main(argv):
    if "--self-test" in argv:
        return self_test()
    path = next((a for a in argv if not a.startswith("--")), UNIT)
    for p in (path, SYSCALLS, THRESHOLD):
        if not os.path.exists(p):
            sys.stderr.write("error: missing " + p + "\n")
            return 1
    text = open(path).read()
    linux = sys.platform.startswith("linux")
    try:
        threshold = check(text, linux)
    except Failure as err:
        sys.stderr.write("error: %s\n" % err)
        return 1
    if not linux:
        print("CONF-1/CONF-3 ok; CONF-4 (systemd-analyze security) and the lease floor "
              "derivation run on Linux, not on " + sys.platform)
    else:
        print("CONF-1/CONF-3/CONF-4 ok (threshold %s)" % threshold)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
