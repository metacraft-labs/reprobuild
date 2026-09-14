# Release signing

M2 replaces reprobuild's same-origin `SHA256SUMS` with real trust:
OpenPGP signatures over the artifacts, natively-verifiable signed
repository metadata for apt / dnf / pacman, and a pre-install
verification step the installer runs before it unpacks anything.

Everything described here lives in `scripts/release-signing/`. The gate
tests that exercise it live in `tools/multi-distro-harness/tests/`.

## What was there before, and why it was not enough

`.github/workflows/release.yml` built `SHA256SUMS` and ran
`sha256sum -c` on it. That is an internal-consistency check: it proves
the bytes on a release page match a list published on the same release
page. An attacker who can replace one can replace both, and a mirror
that serves a modified tarball serves a matching manifest with it. It
catches transit corruption. It is not evidence of origin.

## The shape, and why it mirrors the verifiers we already trust

`apps/repro-harvest-apt/src/repro_harvest_apt/signature.nim` and
`apps/repro-harvest-dnf/src/repro_harvest_dnf/signature.nim` already
verify FOREIGN repositories the way apt and dnf do: shell out to `gpg`
on `$PATH` (or `$REPRO_GPG_BIN`), import a vendored key bundle into an
**ephemeral keyring**, then `gpg --verify`. The producer side is built
as the mirror image of that, and for the same reasons:

* **Shelling out to gpg** rather than linking an OpenPGP
  implementation means reprobuild signs with the same code its
  consumers verify with, and inherits libgcrypt's algorithm support.
* **`$REPRO_GPG_BIN`** is honoured identically, so pinning gpg for the
  verifier pins it for the signer.
* **The ephemeral keyring is load-bearing, not hygiene.** gpg is
  stateful. A verification run against the operator's `~/.gnupg`
  passes for any key that operator already trusts — including when the
  release key was never imported at all. Every signing and verifying
  path here creates its own `GNUPGHOME` and refuses to run without one.

### Where it deliberately departs

The harvesters fall back to a BLAKE3 fingerprint allowlist when gpg is
absent. That is right for a harvester pinned to a frozen upstream
snapshot — such a snapshot can be pinned by hash instead. It is wrong
here, and the producer and installer paths have no equivalent:

> A producer that cannot sign must fail. A verifier that cannot verify
> must fail. "gpg was missing, so we accepted it" is not a degraded
> check, it is no check.

`repro-verify-release.sh` therefore treats a missing `gpg`, a missing
signature file, and a missing manifest line as **rejections**. The gate
asserts each of those three, because a verification test that passes
when the signature is absent asserts nothing.

### Why shell, not Nim

Both callers must work with no reprobuild present:

* CI signs artifacts *before* any reprobuild is published; the only
  reprobuild on the runner is the one being released.
* The installer verifies *before* it installs. A verifier that is part
  of the payload it verifies has verified nothing.

So `repro-verify-release.sh` depends on nothing but a POSIX shell,
`sha256sum`, and `gpgv`/`gpg` — the same floor `apt-secure` and `dnf`
stand on.

## Key classification: release, test, unknown

`lib-signing.sh` classifies every key it is handed as exactly one of:

| class | how | may sign a release |
|---|---|---|
| `release` | fingerprint listed in `trusted-release-keys.txt` | yes |
| `test` | a UID contains the literal `REPROBUILD UNTRUSTED TEST KEY` | only with `REPRO_SIGNING_ALLOW_TEST_KEY=1`, and the output is marked |
| `unknown` | neither | **never** |

There is no fallback and no third escape hatch:

* An **unknown** key is refused even with
  `REPRO_SIGNING_ALLOW_TEST_KEY=1`. That variable admits test keys and
  nothing else, so a maintainer's personal key (or an attacker's)
  cannot acquire a test key's leniency.
* A **test**-signed bundle gets a `SIGNING-KEY-IS-A-TEST-KEY` file
  beside `SHA256SUMS`. `repro-verify-release.sh` refuses any bundle
  carrying it, and any keyring containing a test-marked key, unless
  passed `--allow-test-key`. So a test bundle copied somewhere else
  still cannot pass as a release.
* A key that is **both** listed and marked is a hard error rather than
  a coin toss.

`trusted-release-keys.txt` is committed and currently lists **zero**
fingerprints. That is not an oversight — it is the correct state for a
repository that has no release key yet, and it means every release-mode
signing attempt from this checkout fails closed. The gate asserts the
list is empty, so adding a fingerprint is a change that has to be
noticed.

## Signed repository metadata

Signing the artifacts protects a direct download. It does nothing for a
user who installs through their package manager — so the repository
metadata is signed too, in each ecosystem's native form, and the emitted
client configuration turns the checks on.

### apt — `repro-sign-apt-repo.sh`

Emits `Packages{,.gz}`, a canonical `Release`, a clearsigned
`InRelease`, and a detached `Release.gpg`, plus a deb822 `.sources`
stanza with `Signed-By:` pinned to a binary keyring.

Both `InRelease` and `Release.gpg` are shipped: apt prefers the former
and falls back to the latter, and a mirror that mangles one may leave
the other intact. What apt then checks is a hash chain rooted in one
signature — `InRelease` → `Packages` → the `.deb` — which is why a
tampered `.deb` and a tampered index both surface as apt's own errors
with nothing for reprobuild to check at install time.

### rpm/dnf — `repro-sign-rpm-repo.sh`

Signs each package header with `rpmsign --addsign`, runs
`createrepo_c`, signs `repodata/repomd.xml` into `repomd.xml.asc`, and
writes a `.repo` with **both** `gpgcheck=1` and `repo_gpgcheck=1`.

Those two checks are independent and neither implies the other: a
tampered package with intact metadata is caught only by `gpgcheck`; a
tampered `repomd.xml` only by `repo_gpgcheck`. Fedora's own repositories
historically shipped `repo_gpgcheck=0`, which is why writing the client
config is part of signing here — a correctly signed repository consumed
with the check off is an unsigned repository.

The script asserts, via `rpm -Kv`, that each header really carries a
signature afterwards. `rpmsign` can exit 0 having signed nothing when a
macro expansion is wrong, and that would be a silently unsigned release.
(It also deliberately does **not** override `%__gpg_sign_cmd`:
overriding it was the first thing to break against rpm 6.0, whose own
macro quotes its positional placeholders.)

### pacman — `repro-sign-pacman-repo.sh`

Signs every package with a **binary** detached `.sig` (pacman feeds
`.sig` files to gpgme directly and rejects ASCII armour as malformed —
the one place here that does not use `--armor`), then `repo-add --sign`
for the database, then the `.db`/`.db.sig`/`.files`/`.files.sig`
symlinks pacman actually fetches. The emitted stanza asks for
`SigLevel = Required DatabaseRequired`.

Arch's default is `DatabaseOptional`, i.e. the sync database is **not**
verified. A repository that signs its packages but not its database is
one MITM away from having a package silently removed or downgraded, so
both are signed and both are required.

## The installer's pre-install verification

`repro-verify-release.sh` is M2's deliverable; the installer that calls
it is M3's. The contract:

```sh
sh scripts/release-signing/repro-verify-release.sh \
    --keyring /usr/share/keyrings/reprobuild-release.gpg \
    --dir "$download_dir" \
    --artifact "reprobuild-x86_64-linux.tar.gz" \
  || fail "signature verification failed; refusing to install"
```

called **before** anything downloaded is unpacked or executed. It:

1. requires `gpg`/`gpgv` and `sha256sum` — their absence is a rejection;
2. imports the keyring into a fresh `GNUPGHOME` and asserts at least one
   public key landed;
3. refuses test-marked keys and test-marked bundles unless
   `--allow-test-key`;
4. verifies `SHA256SUMS.asc` over `SHA256SUMS`, asserting on gpg's
   machine-readable `VALIDSIG` rather than on its exit code (gpg exits 0
   for a valid-but-untrusted signature);
5. for each artifact: requires a manifest line (a missing line is a
   rejection, or an attacker just deletes the line), requires exactly
   one such line, compares the digest, and verifies the artifact's own
   detached `.asc`;
6. refuses to report success having checked zero artifacts.

Per-artifact detached signatures are not redundant with the manifest
signature. A consumer that fetches one asset — which is what the
installer does — can verify it without the manifest; the manifest
signature is what binds the SET, so that *removing* an artifact is also
detectable.

## Where the external boundary falls

Two pieces of this milestone cannot be completed inside the repository,
and neither is stubbed.

### 1. The release key itself — governance, not code

`trusted-release-keys.txt` is empty. Every gate run above uses a
throwaway key generated by `make-test-key.sh`, whose UID carries
`REPROBUILD UNTRUSTED TEST KEY`, and whose output is marked so it cannot
be mistaken for a release.

**The procedure to cross this boundary is written down**, in
metacraft-labs/infra
`docs/runbooks/secret-rotation/reprobuild-release-signing-key.md` — minting,
sealing, registering, rotating and revoking, with the exact list of actions
that need a human. The two Actions secrets named in step 3 are registered in
that repo's `terraform/github/secrets-metacraft-prod/secrets/manifest.nix`
(rotation groups `reprobuild-release-signing` and
`reprobuild-release-signing-fingerprint`); their age sources are deliberately
**not** fabricated, so the pipeline stays in the fail-closed state below until
an operator mints a real key. In outline:

1. Generate the release key inside the governance secret pipeline, so
   the private half never touches a developer machine.
2. Add its fingerprint to `trusted-release-keys.txt` in a reviewed
   commit. Until this happens, release-mode signing fails closed.
3. Configure two repository secrets:
   `REPRO_RELEASE_SIGNING_KEY` (ASCII-armoured private key) and
   `REPRO_RELEASE_SIGNING_KEY_ID` (its fingerprint). The workflow
   imports the first into an ephemeral home and shreds it within the
   step. The preferred shape, if the pipeline supports it, is a
   forwarded `gpg-agent` socket and a prepared `GNUPGHOME` with **no
   key bytes on disk at all** — `repro-sign-release.sh` supports that by
   simply omitting `--secret-key-file`.
4. Publish the public key somewhere that is not the release page.
   Verifying a release against a key fetched from the same release is
   circular. `release.yml` holds to this: it exports the public key to
   `$RUNNER_TEMP`, not to `staging/`, so the key the CI well-formedness
   check verifies against is never uploaded as a release asset.

Until step 1, `release.yml` publishes exactly what it published before —
`SHA256SUMS` and nothing more — and says so with a `::warning::`. What
it must never do is publish something that *looks* signed.

### 2. cosign keyless / OIDC — needs a CI workload identity

Keyless signing derives the signer from an ambient OIDC token. There are
two places one can come from: a CI workload identity (on GitHub Actions,
`$ACTIONS_ID_TOKEN_REQUEST_URL` + `$ACTIONS_ID_TOKEN_REQUEST_TOKEN`,
exposed only to a job that declares `permissions: id-token: write`), or
an operator's interactive browser flow, which is not a release
mechanism. Neither can be produced on a developer machine.

`rs_cosign_sign_blob` implements the code path and **refuses** with a
specific diagnosis when no ambient identity exists, returning a distinct
exit code that callers treat as "keyless unavailable here" — never as
"keyless done". No token is fabricated and no Sigstore bundle is
written. The gate asserts exactly that: `--cosign` on a machine with no
OIDC identity produces a SKIPPED line naming what is missing, and **no**
`.sigstore` file.

To cross this boundary, three things are needed. The first is **now
wired**: `publish-release` declares `permissions: id-token: write` alongside
the `contents: write` it needs (a job-level `permissions:` block replaces the
workflow-level one rather than merging, so both are listed). That grant is
inert until something asks GitHub for a token, and nothing does yet.

The remaining two belong in their own reviewed change, deliberately not
bundled with the first release that has a real signing key: install cosign on
the runner, and pass `--cosign`. Landing them separately means the first
release signed with a real OpenPGP key is not also the first release to
exercise Sigstore — a path that can `rs_die` and take the release with it.

The first real run must then be inspected against Rekor — a
`cosign verify-blob` against the expected `--certificate-identity` and
`--certificate-oidc-issuer` — because a keyless signature that verifies
against *any* identity is not a signature, it is a timestamp.

**This has not been exercised.** It is code that has never had a real
token put through it.

## Running the gate

```sh
scripts/run_multi_distro_tests.sh m2_signing_keypolicy --all
scripts/run_multi_distro_tests.sh m2_signing_apt    ubuntu debian
scripts/run_multi_distro_tests.sh m2_signing_dnf    fedora
scripts/run_multi_distro_tests.sh m2_signing_pacman arch
```

Each arm runs the real package manager, and each rejection is the
package manager's own — its message, its exit code. Each arm also runs
a **control** that would fail if the check under test were not running
at all:

* apt/dnf/pacman `N0`: the same genuine repository under a *different*
  trust anchor must be rejected. Without this, an "accepted" result
  would also be produced by a client that never checks.
* pacman `G3c`: the same unsigned database syncs fine under
  `DatabaseOptional`, proving `G3b`'s rejection is caused by the
  `SigLevel` the signer emits.
* `G4d`/`G4e`/`G4f`/`G4g`: the pre-install verifier must reject an
  untrusted signer, a test-key bundle without the opt-in, a bundle with
  no signature, and any run where gpg is unavailable.
* `P2`: the bundle rejected in release mode must be *accepted* with
  `--allow-test-key`, so the rejection is about the key class and not
  about a broken signature.

## Where the gate has actually been run

| arm | host | tool version | result |
| --- | --- | --- | --- |
| `m2_signing_keypolicy` | `repro-ubuntu` | gpg 2.2.27 | 25 checks, 0 failures |
| `m2_signing_keypolicy` | `repro-fedora` | gpg 2.4.9 | 25 checks, 0 failures |
| `m2_signing_keypolicy` | `repro-arch` | gpg 2.4.8 | 25 checks, 0 failures |
| `m2_signing_apt` | `repro-ubuntu` | apt 2.4.13 | 24 checks, 0 failures |
| `m2_signing_apt` | `debian:trixie-slim` | **apt 3.0.3** | 24 checks, 0 failures |
| `m2_signing_dnf` | `repro-fedora` | dnf5 5.4.2, rpm 6.0.2 | 16 checks, 0 failures |
| `m2_signing_pacman` | `repro-arch` | pacman 7.0.0 | 21 checks, 0 failures |

The `debian:trixie-slim` row matters on its own. apt 3.x replaced `gpgv`
with Sequoia's `sqv`, so every diagnostic the arm greps for changed
wording: `NO_PUBKEY <id>` became
`Sub-process /usr/bin/sqv returned an error code (1) ... Missing key <fpr>`,
and `BADSIG` became `Verifying signature: Message has been manipulated`.
The arm's patterns are deliberately alternations wide enough to cover
both, and the `E: The repository ... is not signed.` line is unchanged in
both, so the same 24 checks pass on both apt generations. An rsa3072
signing key is accepted by `sqv`; a SHA-1-era key would not be, which is
the other reason `make-test-key.sh` pins the algorithm.

`repro-debian` could not be used: its WSL instance fails to mount the
Windows drives (`Failed to mount M:\`) and so cannot see the checkout.
The trixie container is the substitute, and is the stricter of the two.

## Linting

`shellcheck --shell=sh --severity=style` over all 11 scripts reports zero
errors. The residual findings are `SC1091` (cannot follow `lib-signing.sh`
without `-x`), `SC2016` (`$REPRO_GPG_BIN` and `$GNUPGHOME` named
literally inside single-quoted diagnostics — intended), `SC2317`
(false "unreachable" on functions reached only through a trap) and
`SC2015` on the `[ -f x ] && bad ... || ok ...` idiom, which is sound
here only because `bad()` always exits 0.

The one `warning`-severity finding is real and deliberate:
`repro-sign-pacman-repo.sh` builds `repo-add`'s argument list by
unquoted word splitting, because POSIX `sh` has no arrays. It is correct
for pacman package filenames, which cannot contain whitespace.

`shellcheck` is already a declared dev-shell tool (`flake.nix`), but no
repo-wide shellcheck lint exists and M2 does not add one — it would have
to pass on ~250 pre-existing shell scripts first.

## A note on the executable bit

Every entry point here is invoked as `sh <script>` — by the workflow, by
the gate arms, and in the examples above — so none of them depends on
the executable bit surviving a checkout or a `git apply`. It is set
anyway on the six entry points and the four gate arms, matching the
convention of the directories they live in (13 of 14 scripts in
`tools/multi-distro-harness/tests/` are executable), because these are
scripts people will run by hand. `lib-signing.sh` is left non-executable
because it is only ever sourced, matching `scripts/lib/*.sh`.
