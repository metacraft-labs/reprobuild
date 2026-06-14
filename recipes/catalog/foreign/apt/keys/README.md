# Debian archive GPG keys (C1 placeholder)

This directory holds the vendored Debian archive GPG keys the C2 apt
harvester uses to verify `InRelease` + `Release.gpg` before trusting any
`Packages` index it fetches from `snapshot.debian.org`.

C1 ships only this placeholder README so the structure is in place;
**C2 lands the actual key bundle + threat-model documentation**.

## Threat model (sketched here for C2 to land in full)

The harvester reaches out to `snapshot.debian.org` over TLS, downloads
the `InRelease` (clearsigned suite metadata) + `Packages` (sha256-keyed
package index), and trusts those bytes to drive a `.deb` fetch loop. The
trust chain has three independent failure modes:

1. **TLS interception.** Defense: certificate pinning on the snapshot
   host. The harvester already gets this from the host's CA store; no
   action here.
2. **`InRelease` signature forgery.** Defense: verify the clearsigned
   payload against the vendored Debian archive key bundle (this
   directory). This is what C2 actually adds.
3. **Replay of a stale `InRelease`.** Defense: enforce the `Valid-Until`
   field declared inside the signed suite metadata. C2 wires this into
   the harvest loop.

## Key bundle to land (C2)

C2 vendors the keys from `debian-archive-keyring` (current and the past
~5 years of release keys) under this directory as a static asset. The
harvester:

- imports them into an ephemeral GPG keyring at harvest time (NOT the
  operator's keyring),
- verifies the signed `InRelease`,
- discards the keyring at process exit.

The keyring file naming convention (C2 to formalize): one
`<key-id>.gpg` file per key (binary public-key blob), plus a
`MANIFEST.txt` listing the (key-id, valid-from, valid-until) tuples for
audit.

## Mirror trust policy (C2)

`snapshot.debian.org` is the only trusted source for the C1 + C2
milestones. C2 may add a mirror policy later (e.g. trust
`snapshot-cdn.debian.org` as a CDN-fronted alias signed by the same
keys). Operator-supplied mirrors are NOT in scope; harvest from a
mirror requires the operator to vendor that mirror's keys themselves.
