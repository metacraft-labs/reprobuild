# Per-archive keyrings (`--keyring`)

One binary OpenPGP keyring per archive, for `repro-harvest-apt --keyring`.
The harvester verifies an archive's `InRelease` against the keyring named for
that archive and nothing else — apt's `Signed-By=` model — so these files are
kept out of the parent directory, whose `*.gpg` files the key-bundle mode
imports together.

| File | Archive | Keys (primary fingerprint) | Obtained from |
|---|---|---|---|
| `debian-archive-trixie.gpg` | `deb.debian.org/debian`, `snapshot.debian.org/archive/debian/<ts>` (suite `trixie`) | `B8B8 0B5B 623E AB6A D877 5C45 B7C5 D7D6 3509 47F8` Debian Archive Automatic Signing Key (12/bookworm); `04B5 4C3C DCA7 9751 B16B C6B5 2256 29DF 75B1 88BD` Debian Archive Automatic Signing Key (13/trixie); `4158 7F7D B8C7 74BC CF13 1416 762F 67A0 B2C3 9DE4` Debian Stable Release Key (13/trixie) | `https://ftp-master.debian.org/keys/{archive-key-12,archive-key-13,release-13}.asc`, exported binary (2026-10-30) |
| `raspbian-archive-keyring.gpg` | `raspbian.raspberrypi.com/raspbian` | `A0DA 38D0 D76E 8B5D 6388 7281 9165 938D 90FD DD2E` Raspbian archive key | byte-identical to `/usr/share/keyrings/raspbian-archive-keyring.gpg` of Raspberry Pi OS trixie, cross-checked against `https://archive.raspbian.org/raspbian.public.key` (2026-10-30) |

A trixie `InRelease` on `snapshot.debian.org` carries signatures by all three
Debian keys; the bookworm automatic key is included because Debian keeps
signing with the previous release's automatic key during a release's life.

To add an archive: export its keyring in binary form, record the fingerprints
and the source here, and confirm them against the archive's published
fingerprint before committing.
