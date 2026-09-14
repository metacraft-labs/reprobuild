# Hosting, native repositories, and the installer

M3. Where reprobuild is published, and how a machine gets it and then
keeps it up to date without running a script again.

M2 (`docs/release-signing.md`) made a release *verifiable*. M3 makes it
*installable*: per-ecosystem repositories, a release step that generates
and uploads their signed metadata, and an installer that registers the
repository so every later upgrade is the package manager's own business.

## The shape

```
                  scripts/release/repro-build-packages.sh
release tarball ──────────────────────────────────────────▶ .deb .rpm .pkg.tar.zst
                                                                    │
                  scripts/release/repro-publish-repos.sh            │
                  (calls M2's signers; --target is a VARIABLE) ◀────┘
                                    │
              ┌─────────────────────┼──────────────────────┬──────────────┐
              ▼                     ▼                      ▼              ▼
     deb.reprobuild.com    rpm.reprobuild.com    arch.reprobuild.com   keys.…
              │                     │                      │
              └─────────────────────┴──────────────────────┘
                                    │  registered by
                    scripts/install/repro-install.sh   (POSIX sh)
                    scripts/install/repro-install.ps1  (PowerShell / Scoop)
                                    │
                                    ▼
                    apt-get install / dnf install / pacman -S / scoop install
                                    │
                                    ▼
                    apt upgrade / dnf upgrade / scoop update   ← forever after
```

## The installer

`scripts/install/repro-install.sh` (POSIX `sh`, runs under `dash`) and
`scripts/install/repro-install.ps1` (PowerShell). Four steps:

1. **detect** — `/etc/os-release` `ID`/`ID_LIKE` → apt / dnf / pacman,
   `uname -m` → the arch token the release assets use. An unrecognised
   machine is an error, not a guess: silently installing an x86_64 build
   on something else fails later and further from the cause. A distro
   with no repository falls through to the tarball method rather than
   failing — it is still a distro reprobuild runs on.
2. **verify** — fetch the trust anchor and check it against a SHA-256
   **pinned in the installer**. See below.
3. **register** — write a deb822 `.sources` with `Signed-By:`, or a
   `.repo` with `gpgcheck=1` *and* `repo_gpgcheck=1`, or a fenced
   `[reprobuild]` block in `pacman.conf` with
   `SigLevel = Required DatabaseRequired`.
4. **install** — `apt-get install` / `dnf install` / `pacman -S` /
   `scoop install`. The package manager's own command, output and exit
   code. Nothing here re-checks what the manager already refuses.

### What the installer deliberately does NOT do

It does not verify repository metadata. apt, dnf and pacman do that
natively, from the anchor registered in step 3, on every transaction —
including ones months from now with this script long gone. Re-implementing
those checks would be redundant and weaker. The installer's job is to get
the **right anchor** onto the box and refuse to proceed when it cannot.

### The trust anchor, and why it is pinned by digest

Registering a repository installs a key that will be trusted for every
future upgrade. That key cannot be verified by a signature made with
itself, so the trust is rooted in two things: HTTPS to the keyring host,
**plus** `REPRO_KEYRING_SHA256` baked into the installer. The pin is what
makes a substituted keyring host insufficient, and it works because the
user fetched the installer over the same HTTPS they are about to distrust
— it forces an attacker to compromise both hosts consistently, and makes
the substitution show up in a diff of the file.

`REPRO_KEYRING_SHA256` is **empty**, exactly as M2's
`trusted-release-keys.txt` lists zero fingerprints, and for the same
reason: reprobuild has no release key yet. **Release-mode installs
therefore fail closed.** `REPRO_ALLOW_UNPINNED_KEYRING=1` is the only way
past it, is never set by default, and prints a warning naming what it
costs. The anchor is never fetched from the release page — verifying a
release against a key published beside it is circular.

### Where the configurable base URL lives

One variable: **`REPRO_BASE_URL`** (`-BaseUrl` in PowerShell), at the top
of each installer. Unset, the installer talks to the production
subdomains under `REPRO_DOMAIN` (default `reprobuild.com`). Set, *every*
fetch becomes a path under that one base:

| | |
| --- | --- |
| `$REPRO_BASE_URL/deb` | apt repository root |
| `$REPRO_BASE_URL/rpm` | dnf repository root |
| `$REPRO_BASE_URL/arch` | pacman repository root |
| `$REPRO_BASE_URL/downloads` | archives + `SHA256SUMS{,.asc}` |
| `$REPRO_BASE_URL/keys/…` | the trust anchor |

Per-surface overrides (`REPRO_DEB_URL`, …) exist for mirrors. The gate
sets only `REPRO_BASE_URL`, at a local HTTP server. **Nothing hardcodes a
production hostname in a way that can only be tested against the real
zone** — which matters because `reprobuild.com`'s delegation was still in
flight, and an installer testable only against DNS that does not exist is
an installer that cannot be tested.

### Idempotence, by construction

Every write is to a **fixed path** and is a **replacement**, never an
append: one keyring, one armoured copy of it, one sources file. The one
append-structured format, `pacman.conf`, is fenced by
`# >>> reprobuild installer >>>` markers and the block is stripped before
being re-appended — appending without the strip is how a third run gets
pacman's "duplicated database" error. Scoop's `bucket add` errors on an
existing name, so the PowerShell installer checks the buckets directory
(not `scoop bucket list`, whose output shape has changed across versions)
and skips.

### The repo-less fallback

`--method tarball` downloads the archive, `SHA256SUMS`, `SHA256SUMS.asc`
and the per-artifact `.asc`, then calls **M2's**
`repro-verify-release.sh` *before unpacking anything*. A missing gpg, a
missing signature, and a missing manifest line are all rejections. The
installer never re-implements that check and never continues past a
non-zero exit from it. If it cannot find the verifier, it fails — an
installer that unpacks because it could not find its verifier has no
security property at all.

A tarball install records every path it wrote to
`/var/lib/reprobuild/installed-files.txt`, so `--uninstall` removes
exactly those. A tarball uninstall that globbed `$prefix/bin` would
delete files it never installed.

### One real asymmetry, stated rather than papered over

On Linux the repository metadata carries OpenPGP signatures. **On Windows
it does not**: Scoop manifests carry artifact *hashes*, Scoop refuses a
download whose hash does not match, and there is no signature over the
manifest — bucket authenticity rests on HTTPS/git to the bucket host.
That is weaker than `InRelease`, and `repro-install.ps1` says so in its
header instead of implying a guarantee it does not provide. The
`-Method tarball` path on Windows *does* get the full M2 chain, and fails
closed when no POSIX shell is available to run the verifier.

## The release pipeline step

`scripts/release/repro-build-packages.sh` turns a published release
tarball into `.deb` / `.rpm` / `.pkg.tar.zst` — *repackaging*, so the
native packages and the tarball carry identical bytes, and adding an
ecosystem is packaging work rather than a new build-matrix leg. It refuses
an empty `bin/`: an empty payload installs cleanly, provides nothing, and
passes every "did it install?" check downstream.

`scripts/release/repro-publish-repos.sh` arranges the pool, calls **M2's**
signers (it reimplements no signing), asserts the new version really
landed in the generated index, and uploads.

### The upload target is a variable

`--target` / `$REPRO_PUBLISH_TARGET`:

| scheme | meaning |
| --- | --- |
| `local:<path>` | copy the tree to a directory — what the gate uses |
| `s3://<bucket>/<prefix>` | `aws s3 sync`; with an R2 endpoint this is R2 |
| `r2:<bucket>/<prefix>` | `rclone` against `$REPRO_RCLONE_REMOTE` |
| `none` | generate, upload nothing |

Generating signed metadata is local and fully tested. Pushing to R2 needs
credentials and a bucket that do not exist yet. Making the destination a
parameter is what lets the gate exercise **the same code path** production
will use, instead of testing a different one.

### The repository tree is stateful, and that is what makes upgrades work

`apt upgrade` can only move a user forward if the index lists the new
version *and* the pool is still a valid repository. So publishing 0.1.4 is
not "write a new repo", it is "add 0.1.4 to the existing pool and
regenerate the index over everything". `--fetch-existing` pulls the
current published tree down first. Without it, publishing 0.1.4 would
**delete** 0.1.3 — `apt upgrade` would work exactly once and every pinned
install would break. The S3/R2 uploads deliberately omit `--delete` for
the same reason.

`release.yml` runs this as the last step of `publish-release`, **after**
the release is visible: metadata referencing assets nobody can fetch yet
would make `apt update` succeed and `apt install` fail. It *skips with a
warning* when there is no signing key (an unsigned repository is worse
than none) or no `REPRO_PUBLISH_TARGET` (nowhere to publish).

## The gate

Four arms, each driving the real package manager. Run:

```sh
scripts/run_multi_distro_tests.sh m3_install_apt m3-debian   # debian:trixie-slim rootfs
scripts/run_multi_distro_tests.sh m3_install_dnf fedora
scripts/run_multi_distro_tests.sh m3_install_pacman arch
pwsh -NoProfile -File tools/multi-distro-harness/tests/m3_install_scoop.ps1
```

| arm | host | tooling | result |
| --- | --- | --- | --- |
| `m3_install_apt` | `repro-m3-debian` (the `debian:trixie-slim` rootfs) | **apt 3.0.3**, dpkg 1.22.22, sqv 1.3.0 | **101 checks, 0 failures** |
| `m3_install_dnf` | `repro-fedora` | **dnf5 5.4.2.1, rpm 6.0.2**, gpg 2.4.9 | **96 checks, 0 failures** |
| `m3_install_pacman` | `repro-arch` | **pacman 7.0.0** (libalpm 15.0.0), libarchive 3.8.3, gpg 2.4.8 | **115 checks, 0 failures** |
| `m3_install_scoop` | Windows 11 | **Scoop 0.5.3**, git 2.55.0 | **58 checks, 0 failures** |

Each arm was run **twice back to back on the same box** and produced the
same counts, which is what makes it hermetic rather than first-run-only.

### Reproducing the clean Debian box

M2 recorded that `repro-debian` cannot mount the Windows drives and so
cannot see the checkout, and used a `debian:trixie-slim` **container**
instead. There is no container runtime on this host (no docker, no podman,
in any WSL instance), so the container's **filesystem** was fetched
directly from the registry and imported as a disposable WSL instance:

```sh
# the exact filesystem of debian:trixie-slim, image digest
# sha256:abc9cb88a5587630d7f915f47b23b0668fe250fbfc6457aa4d52b534c1bbf73f
python3 pull-image.py library/debian trixie-slim ./dtrixie   # registry API, one layer
wsl --import repro-m3-debian <dir> ./dtrixie/layer-0.tar.gz --version 2
```

It came up as Debian 13 trixie with **78 packages**, apt 3.0.3, `sqv`
present, and **no gpg, no gpgv, no curl** — the strict environment. The
arm then installs `curl gnupg dpkg-dev apt-utils python3` as **gate
preconditions**, which the arm's own comments label as such: `curl` is a
precondition of `curl … | sh` itself, and `dpkg-dev`/`apt-utils` are the
*repository generator's* tools, which live on a release runner rather than
a user's machine. None of them is installed by the installer.

The instance name starts with `repro-`, so the existing runner drives it
with no modification: `scripts/run_multi_distro_tests.sh m3_install_apt
m3-debian`. Nothing in `run_multi_distro_tests.sh` was changed.

### The upgrade clause, in apt's own words

```
Installed: 0.1.3-1        ← apt-cache policy, before
Candidate: 0.1.4-1
reprobuild/stable 0.1.4-1 amd64 [upgradable from: 0.1.3-1]   ← apt list --upgradable
...
Setting up reprobuild (0.1.4-1)                              ← apt-get upgrade
```

and dnf's:

```
Upgrading:
 reprobuild             x86_64 0:0.1.4-1.fc44 reprobuild
   replacing reprobuild x86_64 0:0.1.3-1.fc44 reprobuild
```

pacman's:

```
reprobuild 0.1.3-1 -> 0.1.4-1                 <- pacman -Qu, before
Packages (1) reprobuild-0.1.4-1               <- the pacman -Syu transaction
upgrading reprobuild...
```

and Scoop's:

```
reprobuild: 0.1.3 -> 0.1.4
Updating 'reprobuild' (0.1.3 -> 0.1.4)
```

## What would make each new assertion pass vacuously, and why it cannot

This is the part that matters. Fifteen false greens have been caught in
this campaign; two of the arms below were rewritten *because* they were
initially among them.

| assertion | how it could pass vacuously | what rules it out |
| --- | --- | --- |
| **install works** (A3/R3/S1) | the client never checks signatures at all, so anything installs | **N0 control**: the byte-identical repository under a *different* trust anchor must be REJECTED. apt/dnf refuse it; Scoop's N0 is the hash pair. |
| **upgrade happened** (A6/R6/S4) | it was a first install, not a transition; or the installer, not the package manager, put 0.1.4 there | the old version is asserted installed *immediately before*; the upgrade is the manager's own `upgrade`/`update` with **no installer involvement**; the new version is asserted in **both** the package database **and** the installed payload (`repro --version`), so metadata alone cannot satisfy it |
| **idempotent** (A4/R4/S2) | the second run crashed early, so of course nothing changed | the second run's exit code is asserted **0**, and the manager is required to say "already the newest version" / "already installed" itself |
| **nothing changed** (A4/R4/S2) | counting files that do not exist | counts are compared to **numbers** (`= 1`, `= 2`), never truthiness, and the sha256 of each file is compared before/after |
| **tampered package rejected** (A7) | appending bytes trips the index's `Size:` field before any hash is consulted — *this is the exact false green that closed a previous milestone's test* | the tamper is **in-place and same-size**, asserted equal; and apt's own output shows `Filesize:1064` **identical on both sides** with only SHA256 differing |
| **tampered signature rejected** (A8) | flipping base64 inside the armour yields a *malformed packet*, and apt 3's `sqv` fails in its **parser** before any cryptography — proving the file was unparsable, not unauthentic | split into **A8a** (parser) and **A8b** (real): A8b leaves the signature armour **byte-for-byte identical** (asserted) and changes one hex digit of the **signed body**. apt reports `Message has been manipulated`, and a separate assertion requires **zero** `Malformed packet` lines |
| **tampered .rpm rejected** (R7) | claimed to test `gpgcheck` but the repodata checksum fired first, so the package header was never reached | R7 is **relabelled** as what it is (the signed-metadata checksum chain) and **R7b** added: signature *stripped* with `rpmsign --delsign`, metadata regenerated and `repomd.xml` re-signed so the checksum matches and `repo_gpgcheck` passes. dnf then says `The package is not signed.`, with an assertion that it said **nothing** about a checksum |
| **tampered metadata rejected** (R8) | a parse failure rather than a signature failure | the detached `.asc` is asserted byte-identical and the body is changed; dnf reports `Bad PGP signature` |
| **Scoop rejects a bad archive** (S5) | Scoop reinstalls from its **download cache**, never fetching the tampered bytes; or the tampered file is not the one the manifest points at | the cache is cleared and **asserted empty**; the target file is **derived from the live manifest's URL**, not hardcoded — it was hardcoded once, and while a prior step was failing it tampered 0.1.4 while 0.1.3 was installed, so Scoop happily installed an untouched archive |
| **uninstall left no trace** (A9/R9/S6) | nothing was installed in the first place | every removal step asserts presence **first**; and each arm begins with a **hermetic reset** whose success is itself asserted |
| **fail-closed / digest mismatch** (A1/A2/R1/R2) | any unrelated crash also exits non-zero | the **specific** diagnostic is matched (`no trust anchor digest is pinned`, `trust anchor digest MISMATCH`) *and* the absence of the sources file and keyring is asserted |
| **N0 rejects the adversary key** (dnf) | it rejected because `rpm --import` could not read a *binary* keyring — no repository was ever evaluated. **This happened.** | the adversary anchor is now ASCII-armoured like the real one (asserted), and a discriminator requires **zero** `not an armored public key` / `rpm --import … failed` lines |
| **the whole arm** | it threw an exception half-way and printed an all-PASS summary. **This happened** in the Scoop arm: "2 checks, 0 failure(s)". | the arm asserts a **minimum check count** at the end; a short run is a failure |
| **the Scoop arm** | it installed into the developer's real Scoop root, so "it works" says nothing about a clean box | `$env:SCOOP` is redirected and the redirect is **asserted**; the real root's bucket count is asserted unchanged at the end |
| **the tampered-tarball rejection** (A10) | the fixture was broken, so *any* bundle would fail | **A10a** installs the genuine signed tarball successfully first; only then does A10b tamper it (same size, asserted) and A10c remove the signature |

Two more properties worth naming:

* Every rejection is asserted **three ways**: a non-zero exit from the
  package manager, a **counted** match on the manager's own diagnostic
  (`grep -c` compared to a number — a grep matching zero lines is a
  vacuous pass), and the absence of the installed file.
* The distro's own repositories are moved aside for the *rejection*
  phases only. With `deb.debian.org` in scope a flaky mirror produces the
  same non-zero exit as a rejected signature. The *acceptance* phases keep
  them enabled, because that is the configuration a real user has.

### The fixture payload, stated plainly

The package the gate installs carries a **shell script** named `repro`
that prints its version, not a compiled reprobuild. Building real
reprobuild is a heavy compile, and another milestone's two full suite arms
were occupying this host — which OOM-kills under memory pressure — for the
duration of this work.

* **What that costs:** these arms do **not** prove reprobuild builds, or
  that a real reprobuild binary runs once installed.
* **What they still prove:** the version the *installed payload* reports
  changes across the upgrade, so the upgrade replaced real installed bytes
  and not merely a database row. Everything about hosting, repository
  metadata, trust anchors, registration, upgrade and removal is exercised
  against the genuine package managers.

### What the pacman arm found

The arm was written for this review because pacman/arch was implemented and
had never been executed. The first run failed, twice, on **product code**
rather than on the test:

1. **Every `.pkg.tar.zst` the release pipeline produced was unreadable.**
   `repro-build-packages.sh` built it with `bsdtar -cf - --zstd ... > file`.
   When bsdtar compresses internally *and* writes to stdout it pads the
   **compressed** stream out to its 10240-byte blocking factor, so the file
   is a valid zstd frame followed by NUL padding. libzstd rejects the
   trailing bytes and the channel dies two scripts later, inside
   `repo-add`, wearing a signing error's clothes:

   ```
   bsdtar: Error opening archive: Zstd decompression failed: Unknown frame descriptor
   ==> ERROR: 'reprobuild-0.1.3-1-x86_64.pkg.tar.zst' is not a package file, skipping
   repro-sign: FATAL: repo-add --sign failed
   ```

   Fixed by writing to a named file (`bsdtar --zstd -cf "$pkg" ...`), which
   applies the blocking to the tar stream, before compression, where it
   belongs.

2. **The package installed successfully and installed nothing.** The
   payload was added as `./usr`, and libalpm matches member names
   verbatim: with a `./` prefix it matches nothing. pacman printed
   `installing reprobuild...`, exited **0**, wrote a local database entry
   — and `pacman -Ql reprobuild` came back empty with no `/usr/bin/repro`
   on disk. This is the same shape as this campaign's rpm `%files` glob
   defect, and only an assertion on the **installed payload** catches it;
   every exit-code and "is it in the database" check passes.

`repro-build-packages.sh` now reads the package back after building it and
refuses one whose listing has no `.PKGINFO`, no `usr/bin/` member, or any
`./`-prefixed member — because the failure otherwise surfaces far from its
cause.

### What the pacman arm asserts, and what could have made it vacuous

| assertion | how it could pass vacuously | what rules it out |
| --- | --- | --- |
| **tampered package rejected** (P7) | appending bytes trips the signed database's `size` field first: pacman says `Maximum file size exceeded` and never hashes anything. M2's pacman arm passed for exactly this reason once | the tamper is in place at **constant length**, asserted equal; the match is on `invalid or corrupted package` and **not** on the generic `failed to commit transaction` (which the size path also prints); and a discriminator requires **zero** `Maximum file size exceeded` lines. Verified by deliberately re-appending six bytes: the length assertion fails and the discriminator fires |
| **package signature checked** (P7b) | P7 proves the *checksum chain*, not `SigLevel = Required` — pacman discards the download before reading the package's `.sig` | P7b keeps the genuine bytes, re-signs them with the **adversary** key, and regenerates + re-signs the **database** with the good key so size and sha256 both match. pacman then says `required key missing from keyring`, with an assertion that it said **nothing** about a checksum or a size |
| **database signature checked** (P8) | a missing `.sig` is also a rejection, and `DatabaseOptional` (Arch's default) would not check at all | the tamper is constant-length, the detached `.sig` is asserted **byte-identical**, and the restored database is required to sync cleanly again |
| **upgrade happened** (P5/P6) | it was a first install, not a transition | `0.1.3-1` asserted installed immediately before; the upgrade is `pacman -Syu` with no installer involvement; `0.1.4-1` asserted after in **both** pacman's database and `repro --version` |
| **publish was additive** (P5) | a pacman sync database holds exactly **one** entry per package name, so "both versions in the index" is not a property pacman has | the database is asserted to hold exactly one entry (a count, compared to a number) **and** the old `0.1.3-1` package **file** is asserted still fetchable over HTTP, which is the additive property that does exist |
| **idempotent** (P4) | a second run that crashed also changes nothing | exit code asserted 0, six observations compared before/after, pacman required to say so itself — and a **third** run, because `pacman.conf` is the one append-structured config and a missing strip is how run three earns `duplicated database` |
| **N0 rejects the adversary anchor** | the installer merely failed to add the key to pacman's keyring, so pacman never evaluated the repository — the dnf arm's actual false green | a discriminator requires **zero** `pacman-key --add ... failed` / `no OpenPGP key found` lines |
| **the whole arm** | it aborted after the last assertion and printed a short all-PASS summary | a minimum check count is asserted at the end |

## Where the external boundary falls

Nothing below is stubbed or faked. Each is a thing that cannot be done
from this checkout.

1. **DNS / the zone.** `reprobuild.com`'s delegation was in flight. No
   hostname in it resolves yet. The gate serves the repositories over a
   local HTTP server and points the installers at it with
   `REPRO_BASE_URL`.
2. **R2 buckets.** Cannot be provisioned without Cloudflare credentials.
   `--target local:<path>` and `--target r2:<bucket>` are the same code
   path; only the scheme differs.
3. **Terraform.** The root is written and reviewable, but **it does not
   live in this repository.** It was first authored here under
   `infra/terraform/cloudflare/reprobuild-prod/`, which was the wrong
   place: Cloudflare changes go through the documented Terraform
   workflow in **`metacraft-labs/infra`**, so it was ported to
   `terraform/cloudflare/reprobuild-prod/` there — beside the
   `codetracer-prod` root, with its own `backends/cloudflare-reprobuild-prod.hcl`,
   its own agenix token pair under
   `machines/ci/secrets/cloudflare/reprobuild_api_token_*.age`, and a `root` matrix
   leg in that repo's `.github/workflows/terraform-cloudflare-ci.yml` —
   and the copy here was deleted. Nothing in this repository configures
   Cloudflare any more.

   `tofu validate` **passes** against the real
   `cloudflare/cloudflare v5.25.0` provider and `fmt -check` is clean —
   neither needs credentials. **`plan` was NOT run against real
   credentials, and `apply` was not run.** See that root's README, which
   also records that `cloudflare/metacraft-prod` does not exist (the real
   precedent is `codetracer-prod`) and that **there is no
   `deb.codetracer.com`/`rpm.codetracer.com` configuration anywhere in the
   workspace to mirror** — the per-ecosystem bucket layout is new work.

   Re-checked independently for the M3 review with **OpenTofu 1.11.6**
   (nixpkgs would have had to build `terraform` itself from source on a
   host that could not afford the compile): `init -backend=false` resolves
   `cloudflare/cloudflare` **v5.25.0**, `validate` reports *Success! The
   configuration is valid.*, `fmt -check -diff` is clean, and no `plan` or
   `apply` was run. The v4 finding was reproduced as a control: the same
   configuration pinned to `~> 4.52` fails `validate` with **nine** errors,
   **five** of them `Invalid resource type ... cloudflare_r2_custom_domain`
   — one per bucket — and the rest `cloudflare_zone` schema changes
   (`zone` and `account_id` required, `name` unsupported). So the v5
   requirement is forced by more than one resource.

   Re-confirmed a second time after the port, from the root's new home in
   `infra`, with **OpenTofu 1.9.1** (`nix shell nixpkgs#opentofu`, the
   form `docs/runbooks/Add-New-Environment.runbook.md` prescribes; the
   repo's dev shell ships `opentofu` and no HashiCorp `terraform`):
   identical results — `init -backend=false` resolves v5.25.0,
   `validate` succeeds, `fmt -check -diff` is clean, and the `~> 4.52`
   control still fails with exactly nine errors, five of them
   `Invalid resource type`.

   Somebody still has to reconcile the pin with `codetracer-prod`'s
   `~> 4.52`: that root's own `main.tf` carries a **commented-out**
   `cloudflare_r2_custom_domain` template which **cannot be uncommented
   under its current pin**, so it is independently blocked on the same
   v4 → v5 upgrade. That is now recorded as a known open item in
   `infra`'s `docs/runbooks/Cloudflare-Resource-Lifecycle.runbook.md` §4
   and in `terraform/cloudflare/reprobuild-prod/versions.tf`. Upgrading
   `codetracer-prod` is a state migration on a root that has been
   applied, and was deliberately left out of the porting change.
4. **The release key.** M2's boundary, inherited. While
   `trusted-release-keys.txt` is empty and `REPRO_KEYRING_SHA256` is
   empty, release-mode signing and release-mode installs both fail closed.
   All gate work uses M2's throwaway test key.
5. **A Scoop bucket and a Homebrew tap** are **git repositories**;
   `scoop bucket add` and `brew tap` clone them, and R2 serves objects,
   not git. They need `metacraft-labs/scoop-reprobuild` and
   `metacraft-labs/homebrew-reprobuild`, which do not exist. The gate
   stands up a **real local bucket** (a git repo) rather than leaving
   runquota's `@SCOOP_URL@` placeholder, so the manifest generator is
   exercised with a real URL and a real hash.

### `install.` vs `get.`, unresolved on purpose

The milestone names `install.reprobuild.com`. The repository already has
**`get.reprobuild.com`** — chosen to follow the internal
`product-install-domains.md` policy (`get.<product>.<tld>`, `/sh` and
`/pwsh`), already built by `get/build-get.sh` and deployed by
`.github/workflows/deploy-get.yml`. Both can point at the same Pages
project, and the Terraform attaches both. **Which is canonical is a
decision for a human**, not something this work should quietly settle.

`get/build-get.sh` now also publishes the M3 installer at **`/repo-sh`**,
and `/pwsh` is the real PowerShell installer instead of the coming-soon
stub. `/sh` still serves the legacy nix/local-prefix
`install-on-distributions.sh`, because the M3 installer fails closed with
no pinned anchor and serving it at `/sh` today would replace a working
one-liner with one that refuses to run for everybody. The switch-over is a
single variable — `REPRO_GET_SH_SOURCE=repo` — and belongs in the same
commit that populates the anchor pin.

## Not done

* ~~pacman/arch has no gate arm~~ — **closed.**
  `tools/multi-distro-harness/tests/m3_install_pacman.sh` now exists and
  passes (115 checks, 0 failures, twice back to back on `repro-arch`,
  driven by the unmodified runner). See "What the pacman arm found" above:
  running it for the first time turned up **two defects that made the
  whole arch channel non-functional**, which is what "implemented but
  never run" is worth.
* **The installer's trust-anchor re-encoding is not covered by any arm.**
  `armour_keyring_to()` in `repro-install.sh` converts a **binary** keyring
  to ASCII armour because `rpm --import` accepts only armour. It is real,
  and it is necessary: M2's apt signer exports binary
  (`gpg --export`) while its rpm and pacman signers export armoured
  (`gpg --armor --export`), so a box served the apt-shaped anchor and
  registering the dnf repository needs the conversion. But **neither the
  dnf arm nor the pacman arm exercises it**: both are handed an
  already-armoured anchor, so the function takes its `cp` fast path. The
  conversion was verified by hand for this review (a binary anchor logs
  `trust anchor re-encoded as ASCII armour for rpm --import` and
  `rpm --import` then succeeds; with the conversion removed, `rpm --import`
  fails with `key 1 not an armored public key` and dnf never evaluates the
  repository) — but hand verification is not a gate, and this deserves a
  step of its own.
* **`release.yml`'s repo-metadata step has never run, and needs five tools
  the job does not install.** `--ecosystem all` reaches
  `rpmbuild` (rpm-build), `createrepo_c`, `dpkg-scanpackages` (dpkg-dev),
  `apt-ftparchive` (apt-utils) and `repo-add` — and `repo-add` ships only
  with **pacman**, so on anything but an Arch runner the arch leg will
  `die` and take the step with it. The step is currently gated off
  (`REPRO_PUBLISH_TARGET` is unset, so it skips with a warning), which is
  why nothing has noticed. Whoever turns it on must either install those
  tools on `eph-linux-x64`, split the ecosystems across runners, or make
  the step skip per ecosystem the way it already skips per missing
  credential — that is a choice about runners, not a bug with one obvious
  fix, so it is recorded rather than guessed at here.
* **Homebrew** has no manifest generator at all.
* `apt 2.x` was not exercised by the M3 arms; only apt 3.0.3. The
  diagnostic patterns are alternations covering both wordings (M2 verified
  both generations), but that is an inherited claim here, not a measured
  one.
