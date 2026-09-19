# Taking one measured boot's own attestation evidence

`take-attested-boot-evidence.sh` assembles a unified kernel image, boots
it in a transient QEMU guest through TPM-enabled UEFI firmware with a
software TPM attached, has the guest quote its own registers, and brings
three artifacts home:

| file | what it is |
|---|---|
| `out/quote.msg` | the `TPMS_ATTEST` the TPM produced |
| `out/quote.sig` | the `TPMT_SIGNATURE` over it |
| `out/binary_bios_measurements` | the TCG event log **firmware** wrote |
| `out/pcrs.txt` | every register of every bank, read in the guest |
| `out/ak.pub.pem` | the attestation key's PUBLIC part, PEM `SubjectPublicKeyInfo` |
| `out/ak.pub.tss` | the same key as the TPM's own `TPM2B_PUBLIC` |
| `out/ak.name` | that key's `TPM2B_NAME`, as `tpm2_createak -n` wrote it |

Those are what `attested_boot_vectors.nim` pins, and what
`t_tpm_quote_verifies`, `t_tampered_uki_detected` and
`t_pinned_attestation_signatures` read.

## PIN THE KEY. A signature with no key is not evidence.

The last three rows are not optional extras. A `TPMT_SIGNATURE` pinned
without the public key it was made with **can never be checked by
anybody** — not by this build and not by a reader in five years. One
signature does not determine one key: recovery over a single `(attest,
signature)` pair yields several candidate public keys and *all of them
verify*, and the attestation structure carries only the key's
**qualified** name, `H(QN_parent ‖ Name)`, whose parent component this
harness never records. So there is no way back. Three boots were pinned
that way before this was noticed and they are unverifiable for good;
`PinnedBootEvidenceSet` names them and says why.

If you pin a capture, pin its key with it. The three artifacts check each
other — the name is `nameAlg ‖ SHA-256(TPMT_PUBLIC)`, the `TPM2B_PUBLIC`
carries the point, and the point is what the signature verifies under —
so a typo in any one of them is caught by the other two.

## Running it

Every input is named by an environment variable and the script **refuses
out loud** when one is missing, naming it. It does not skip: a run that
quietly did nothing is worse than one that failed. See the header of the
script for the full list.

The 64 bytes the quote binds are supplied by the caller in
`ATTEST_BOOT_BOUND_HEX`, derived through the binding discipline from a
nonce. They are handed to the guest over a channel **outside the
measurement**, so the guest can neither choose them nor derive them from
anything it measured.

## What is reproducible, and what is not

A fresh run creates a fresh TPM and a fresh attestation key, so the
attestation structure, the signature and the event log differ on every
run — they are that boot's, not this image's. That is exactly why the
key has to travel with them: it is destroyed with the guest.

What *is* a function of the image, and what the gates rest on, is the
**launch measurement**: the digests of the sections a stub measures. Two
runs of this harness with the same inputs produce the same `.linux`,
`.osrel`, `.cmdline`, `.uname` and `.sbat` digests, and therefore the
same PCR 11. The `.initrd` digest is a function of the initramfs this
script builds, which includes the text of the `init` it writes — so
editing this script changes the measurement, which is the system working
rather than a defect.

The initramfs is built with fixed mtimes and a sorted member list
precisely so that two runs differing only in the kernel command line
differ in **exactly one** section digest. Without that, every rebuild
would move `.initrd` too and "the command line moved the measurement"
would not be a claim the evidence supports.

## Why this is not wired as a build edge

It needs a hardware-accelerated hypervisor, a software TPM, TPM 2.0
command-line tools and TPM-enabled firmware, none of which are part of
this repository's toolchain, and one run takes minutes. It is driven by
hand, and the bytes it produces are pinned so the gates that read them
run offline in milliseconds.

## Two wiring facts that cost hours

* **The guest's TPM chardev must point at the software TPM's CONTROL
  socket, not its data socket.** Pointed at the data socket, the emulator
  handshake never completes, QEMU hangs before it creates any other
  character device, and the guest comes up with no TPM and every register
  at zero. That is the *same symptom* as firmware built without TPM
  support — two different causes, one appearance.
* **The firmware found the EFI system partition only on a SATA device.**
  With the image on a virtio block device — including with an explicit
  `bootindex=0` — the boot manager selected a "UEFI Non-Block Boot
  Device" and never reached it.

---

# Taking one machine's evidence about sealed state

`take-sealed-state-evidence.sh` is the sibling of the script above. That
one asks a guest what it measured; this one asks whether a secret its
TPM is holding can still be recovered after the machine is power cycled,
after its boot entry is replaced, and after its boot entry is **altered**.

One run is **one machine across five power cycles**. The software TPM's
state directory, the UEFI variable store and two LUKS2 block devices
persist across all five; only the image on the EFI system partition
changes.

| cycle | image | what the guest does |
|---|---|---|
| `enroll` | generation A | create two LUKS2 volumes with a key from the kernel's RNG, write a marker into each, seal the key under the register the stub measured the image into |
| `reboot` | generation A | recover the key, open both volumes |
| `reseal` | generation A | recover the key, then re-seal it under the register value generation B **will** produce, computed from B's image bytes |
| `switch` | generation B | recover the key from the new object; the old object must refuse |
| `tamper` | generation A with one character of kernel command line altered | both objects must refuse, and the volumes must stay locked |

It brings home, per cycle, `out/report-<cycle>.txt` (a flat `key=value`
record), the TCG event log that boot's firmware wrote, and — once each —
the sealed objects' public areas, their `TPM2B_NAME`s and the policy
digests the TPM's own trial sessions computed. Those are what
`sealed_state_vectors.nim` pins and what `t_seal_survives_reboot`,
`t_reseal_on_generation_switch` and `t_tampered_uki_fails_unseal` read.

## PIN THE PUBLIC AREA WITH THE NAME

Same discipline as the attestation key above, arriving at a different
structure. A sealed object's name is `nameAlg ‖ SHA-256(TPMT_PUBLIC)`, so
the two artifacts check each other and a typo in either is caught by the
other. A public area pinned alone is a byte string nothing contradicts.

**Nothing secret is brought home.** The volume key existed only inside
the guest and inside the sealed objects, which are ciphertext under a
parent the TPM destroyed with the guest. The markers are plaintext
32-byte values written to the front of each opened volume so a later
cycle can prove it opened the same volume; they are useless without the
key. The sealed objects' private areas are not pinned at all.

## The negative control, and why it has to be a real boot

`SEAL_RECOVERY_FALLBACK=1` enrols a second key slot holding a well-known
recovery key and has the guest fall back to it whenever the TPM refuses.
That is the failure mode the third gate exists to detect — a machine that
says "no" and opens the disk anyway — and running it produces evidence in
which the unseal failed with the *same* TPM status and the volumes opened
regardless. The gate feeds both reports to the same two predicates: the
refusal check must still be TRUE, and the locked check must be FALSE.

Without that capture, "it refused" and "it stayed locked" could be the
same check wearing two names, and nothing would show it. **Never use that
flag for a capture meant to represent correct behaviour.**

## The cycle is chosen outside the measurement

The guest's `init` is identical in every cycle and reads which cycle it
is from the shared directory. The kernel command line and the initramfs
are both inside the launch measurement, so an init that branched on
either would move the very value the experiment holds fixed.

## Two more wiring facts, on top of the three above

* **The EFI system partition must stay on SATA, so the encrypted volumes
  are virtio.** Same firmware constraint as above, from the other side.
* **`cbc` must be loaded before `dm-crypt`.** `dm-crypt` depends on
  `encrypted-keys`, which registers a `cbc(aes)` transform at init time
  and gives up if the template is not there yet. The symptom is
  `dm_crypt: Unknown symbol key_type_encrypted` followed by
  `crypt: unknown target type` — which reads like a missing `dm-crypt`
  module and is not one. There is no `modprobe` in this initramfs, so the
  order in `modules/load.order` is the only thing deciding it.

---

# Taking one machine's evidence about where a released secret went

`take-provisioned-secret-evidence.sh` is the third harness here, and it
asks the question the other two do not: a machine is handed a secret
over a network **while it is running** — where does the plaintext end
up, and what is left on its disk after it is power cycled?

One run is **one machine across two power cycles**. A single raw disk
image is attached as a virtio block device and persists across both;
nothing else does.

| cycle | what the guest does |
|---|---|
| `provision` | bring up the attestation agent, let the host verify a key agreement and hand back an HPKE-wrapped secret, decrypt it into the runtime directory, write bulk data **and a planted token** to the disk, power off |
| `after-reboot` | boot again, report that the runtime directory is empty and that the disk still carries what the first cycle wrote, power off |

The host is the verifier and it is genuinely a different party: it runs
in its own process, talks to the guest over a forwarded TCP port, mints
the nonce, verifies the report against a policy, and encrypts to the
ephemeral key the evidence bound. The guest never sees the plaintext
except as something it decrypted.

## THE ASSERTION IS A SEARCH OF THE DISK, NOT A READING OF THE GUEST

After the second cycle the host greps the raw image for two tokens: the
**secret**, which must be absent, and the **planted token**, which must
be present. The guest's own account of itself is corroboration; it is
not the claim.

Both tokens are 64 printable hexadecimal characters drawn from the
host's random source. That is a realistic shape for a released
credential, and it makes the search auditable — anyone can re-run the
grep by hand.

## "Not found" is worth nothing from a search that finds nothing

Three separate answers, and two of them are boots rather than arguments:

1. the planted token, written by the same guest to the same filesystem
   in the same cycle, **is** found;
2. the same search over the same image with the secret appended **does**
   find it — the harness does this explicitly and records the count;
3. `PROVISION_LEAK=1` runs the whole harness again with a guest that
   copies its released secret onto the disk. That is the failure this
   gate exists to detect, and the search then reports `secret_hits=1`.

**Never use that flag for a capture meant to represent correct
behaviour.**

## Nothing secret is brought home

The secret and the planted token existed only in that run and are in
none of the pinned artifacts. What is recorded is their SHA-256 — by the
host that released the secret, by the guest that decrypted it, and by
the search — so `provisioned_secret_vectors.nim` can establish that all
three are talking about one value without publishing it.

## What this harness deliberately does NOT do

* **No unified kernel image, no firmware, no TPM, no measured boot.**
  The guest boots straight into an initramfs and its root of trust is a
  software one; the pinned verdict says
  `accepted-without-a-root-of-trust` out loud. Binding a release to
  hardware evidence is a different question, asked by a different gate.
* **The disk is an ordinary unencrypted ext4 filesystem.** That is the
  conservative choice: an encrypted volume would make "the secret is not
  on the disk" true for a reason that has nothing to do with the
  property under test.

## Two wiring facts

* **`busybox` must be a build that actually has applets.** Several of
  the static `busybox` derivations in a Nix store report an *empty*
  `--list`, and an initramfs built from one comes up, runs `init`, and
  answers every command with `applet not found` — which reads like a
  broken script and is not one. Check `busybox --list | wc -l` before
  blaming anything else.
* **The guest's network is QEMU's user-mode stack, configured
  statically.** There is no DHCP client in this initramfs; the guest
  sets `10.0.2.15` and a default route to `10.0.2.2` by hand, which is
  what `-netdev user` expects, and the host reaches the agent through
  `hostfwd`.

## Why this is not wired as a build edge

Same reason as its two siblings: it needs a hardware-accelerated
hypervisor, a host kernel and module tree, and one run takes minutes. It
is driven by hand, and the records it produces are pinned so the gate
that reads them runs offline in milliseconds.
