# nim-check: skip
#
# Linux-Distro-Recipe-Validation M7 — multi-distro system-profile
# fixture for `repro infra plan`. Exercises the EXISTING generic-Linux
# system-scope primitives that the Dotfiles-Migration-Completion
# campaign sidestepped via the NixOS-only `linux.nixosSystemModule`
# escape-hatch driver:
#
#   * `systemd.systemUnit` — a minimal one-shot hello.service unit.
#   * `fs.systemFile` — a managed file under `/etc/m7-test/` so the
#     gate doesn't touch any path the host distro itself owns.
#   * `os.timezone` — declared as `Etc/UTC`, the IANA value virtually
#     every Linux WSL instance is already at, so an apply (NOT
#     exercised here) would be a no-op too. Plan-time is read-only.
#
# `passwd.user` and `linux.firewallRule` are deliberately skipped:
#
#   * `passwd.user` plan-time observation requires the planner to
#     read `/etc/passwd` (a live system query). Under WSL --import
#     the file always exists but the result is a `create` action for
#     any name we'd invent; the observation itself is cheap.
#     EXCLUDED to keep the gate focused on the three primitives M7's
#     brief lists as the goal set; a real apply would need elevation
#     (M82 broker) which is out of M7 scope per the brief's
#     "DO NOT run `repro infra apply`" rule.
#   * `linux.firewallRule` requires the planner to probe the live
#     iptables/nftables chain via the elevation-gated probe helper
#     even at plan time on some distros; the brief allows skipping
#     primitives that require live system query in `--plan` mode.
#
# The fixture is intentionally bare. `system.nim` profiles do NOT
# have `activity` / `hosts` blocks at the M69 parser level; the
# typed-DSL macro library accepts them but the system-scope
# adapter (`profileIntentToSystemProfile`) ignores anything that
# isn't a system-scope resource. So we declare only `resources:`.

import repro_profile

profile "m7-multi-distro-system-profile":

  resources:
    # 1. systemd.systemUnit — a minimal oneshot unit. The content is
    #    valid systemd unit-file syntax; the planner does NOT execute
    #    it at plan time (plan is read-only). Apply would invoke
    #    `systemctl daemon-reload` + `enable`, both elevation-gated
    #    and out of M7 scope.
    systemdSystemUnit(name = "m7-hello.service",
      content = "[Unit]\nDescription=M7 multi-distro test unit\n[Service]\nType=oneshot\nExecStart=/bin/true\n[Install]\nWantedBy=multi-user.target\n",
      enabled = false,
      address = "m7HelloUnit")

    # 2. fs.systemFile — a managed file under `/etc/m7-test/`. The
    #    planner reports `create` (the file doesn't exist on a fresh
    #    WSL instance) at plan time without writing anything; apply
    #    would write the bytes at mode 0644 under elevation.
    fsSystemFile(path = "/etc/m7-test/marker",
      content = "m7: managed by repro infra apply\n",
      mode = "0644",
      address = "m7Marker")

    # 3. os.timezone — declared as Etc/UTC (the IANA value WSL
    #    instances default to). Plan-time observation reads the live
    #    timezone via `timedatectl` / `/etc/localtime` and reports
    #    `no-op` when it already matches.
    osTimezone(tz = "Etc/UTC",
      address = "m7Timezone")
