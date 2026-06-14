# ReproOS systemd unit fragments (B3)

These unit fragments wire `reproos-rebuild`'s plan-apply-record-confirm
loop into systemd. They are referenced by the
`ReproOS-Generations-And-Foreign-Packages.milestones.org` campaign
spec, **B3** milestone, P4 deliverable.

## `reproos-confirm-generation.service`

Runs **after** `multi-user.target` has been reached. If a
`<state>/staged-next` file is present, the unit calls
`reproos-rebuild confirm`, which:

1. Reads the staged generation number from `<state>/staged-next`.
2. Atomically rotates `<state>/current` (symlink on POSIX,
   `current.txt` on Windows) to point at the staged generation's
   directory.
3. Removes `<state>/staged-next`.

If the unit never runs (because the boot failed before
`multi-user.target`), the staged-next file is left in place, and the
next reboot loads the GRUB `boot-prev` entry — which references the
previously-confirmed generation. This is the B3 P4 "boot-failure
auto-rollback" contract.

Install path: `/etc/systemd/system/reproos-confirm-generation.service`.

## `reproos-boot-once-watchdog.service`

Polls `systemctl is-active multi-user.target` every 2 s for up to 60 s.
If the target is not reached within the budget, the watchdog calls
`reproos-rebuild watchdog --deadline 60`, which:

1. Clears `<state>/staged-next` (the staged generation is declared
   failed).
2. Rewrites `grub.cfg` so the default entry points back at the
   previously-confirmed generation.
3. Triggers `/sbin/reboot`. The next boot loads the rolled-back
   generation.

If `multi-user.target` reaches `active` before the deadline, the
watchdog exits cleanly without invoking the rollback.

Install path:
`/etc/systemd/system/reproos-boot-once-watchdog.service`.

## Wiring in a ReproOS image

The R9 ISO recipe ships these units in
`/etc/systemd/system/multi-user.target.wants/` (enabled by default).
The `apps/reproos-rebuild` binary lives at `/usr/local/bin/reproos-rebuild`.

## Local-test caveat

Real boot validation runs through `vm-harness` (Hyper-V Gen-2 UEFI).
The B3 P5 integration tests **simulate** the boot path by invoking
`reproos-rebuild confirm` / `reproos-rebuild watchdog` directly; a
real reboot test is part of Phase D's `t_d1_boot_reproos_mvp.nim`.
