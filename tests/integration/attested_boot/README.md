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

Those three are what `attested_boot_vectors.nim` pins, and what
`t_tpm_quote_verifies` and `t_tampered_uki_detected` verify.

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
run — they are that boot's, not this image's.

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
