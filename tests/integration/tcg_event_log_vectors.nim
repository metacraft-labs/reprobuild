## Pinned TCG event logs from real firmware, and the third-party
## readings that say what is in them.
##
## ## Where these bytes came from
##
## Both logs were read off ``/sys/kernel/security/tpm0/binary_bios_measurements``
## inside a transient QEMU guest, i.e. they are the copy the FIRMWARE
## wrote into memory and handed to the OS through ACPI. Nothing in this
## repository produced a byte of either one, which is the entire point:
## a log this codec's own writer emitted and its own reader accepts
## would prove that the code agrees with itself, which it would do just
## as happily if it were wrong.
##
## Two logs, because there are two wire shapes and a parser that handles
## only the modern one is not a parser of TCG event logs:
##
##   * ``AgileLogHex`` — **crypto-agile** (``TCG_PCR_EVENT2``), 6,882
##     bytes, 32 entries, four banks (SHA-1, SHA-256, SHA-384,
##     SHA-512). Written by **OVMF (edk2 202508.01) built with
##     ``-D TPM2_ENABLE``** — the ``OVMFFull`` variant; the ordinary
##     nixpkgs ``OVMF`` has no TPM support and produces no log at all,
##     which is worth knowing before anyone tries to regenerate this.
##   * ``LegacyLogHex`` — **TCG 1.2** (``TCG_PCR_EVENT``, SHA-1 only,
##     no header), 704 bytes, 15 entries. Written by **SeaBIOS** against
##     a **TPM 1.2** vTPM. This one is not a hand-written approximation
##     of an obsolete format: it is what a real firmware produced on a
##     real platform configuration, option-ROM and ACPI events and all.
##
## ## Regenerating them
##
## Both come from one script shape; the differences are listed after it.
## ``$SWTPM``, ``$TOOLS`` and ``$OVMF`` are store paths — none of the
## three packages is in this host's profile.
##
## ::
##
##   swtpm socket --tpm2 --ctrl type=unixio,path=$W/ctrl.sock \
##       --tpmstate dir=$W/tpmstate --flags not-need-init,startup-clear &
##
##   qemu-system-x86_64 -machine q35,accel=kvm:tcg,smm=on -m 2048 \
##       -global driver=cfi.pflash01,property=secure,value=on \
##       -drive if=pflash,format=raw,unit=0,readonly=on,file=$OVMF/OVMF_CODE.fd \
##       -drive if=pflash,format=raw,unit=1,file=$W/vars.fd \
##       -chardev socket,id=chrtpm,path=$W/ctrl.sock \
##       -tpmdev emulator,id=tpm0,chardev=chrtpm -device tpm-crb,tpmdev=tpm0 \
##       -virtfs local,path=/nix/store,mount_tag=nixstore,security_model=none,readonly=on \
##       -kernel $KERNEL -initrd $W/initramfs.cpio \
##       -append "console=ttyS0 qdata=$Q" -serial file:$W/serial.log
##
## The initramfs is a static BusyBox plus the stock kernel's ``tpm``,
## ``tpm_crb``, ``rng-core``, ``netfs``, ``9pnet``, ``virtio*`` and
## ``9p`` modules. Its ``init`` mounts ``securityfs``, hex-dumps
## ``binary_bios_measurements`` to the serial port, dumps all 24
## registers of every bank from ``/sys/class/tpm/tpm0/pcr-*/``, then
## mounts the host store over 9p and runs the host's tpm2-tools
## **inside the guest** to take a quote of the very registers it just
## printed.
##
## For ``LegacyLogHex``: ``swtpm`` without ``--tpm2`` (so a TPM **1.2**),
## ``-machine pc`` with no ``pflash`` (so SeaBIOS rather than OVMF), and
## ``-device tpm-tis`` with the ``tpm_tis``/``tpm_tis_core`` modules.
##
## Versions, all measured rather than assumed: QEMU **10.1.5**, swtpm
## **0.10.1** (libtpms, derived from the TCG reference implementation),
## tpm2-tools **5.7**, edk2 **202508.01**, SeaBIOS **1.17.0**, Linux
## **6.12.85**.
##
## ## What each fixture is anchored by, and by what that is not this code
##
##   * **The registers** — ``AgilePcrsSha1``/``…Sha256``/``…Sha384``/
##     ``…Sha512`` and ``LegacyPcrsSha1`` are all 24 registers of each
##     bank as the RUNNING KERNEL read them out of the TPM, transcribed
##     from ``/sys/class/tpm/tpm0/pcr-<alg>/<n>``. They are what libtpms
##     computed while the firmware was extending, not what anything
##     replayed afterwards. All 24 are pinned, not just the ones the log
##     touches, because the reset values of the registers NOTHING
##     touched are themselves a claim this code makes (PCRs 17–22 are
##     all-ones) and an unanchored claim is a comment.
##   * **An independent replay** — ``tpm2_eventlog`` (tpm2-tools 5.7)
##     parses both logs and computes the same register values from them.
##     It is a second implementation of everything in ``event_log.nim``,
##     written by other people, and it agrees. Its output is not pinned
##     here — it is a tool the regeneration recipe above names. It
##     reports only the registers some event touched, nine per bank in
##     the agile log and eight in the legacy one, and every one of them
##     equals the corresponding row of the ``*Pcrs*`` tables below.
##   * **A signed quote over the same boot** —
##     ``AgileQuoteAttestHex``/``AgileQuoteSignatureHex`` are a real
##     ``TPM2_Quote`` over ``sha256:0,1,2,3,4,5,6,7``, taken by
##     tpm2-tools *inside the guest* from the same TPM in the same boot,
##     minutes after the firmware finished extending it. ``tpm2_checkquote``
##     accepted it against ``AgileQuoteAkPublicHex`` — write the attest,
##     the signature and the key out and the tool exits 0 — and it refuses
##     a tampered attest, a tampered signature, a tampered key and a wrong
##     ``qualifyingData``, each with a non-zero exit. This is what makes
##     the headline gate a statement about SIGNED bytes rather than about
##     two things this repository printed.
##   * **The attestation key's PUBLIC KEY is pinned** —
##     ``AgileQuoteAkPublicHex`` is the key ``tpm2_createak`` wrote, in
##     the PEM ``SubjectPublicKeyInfo`` encoding: an ASN.1
##     ``id-ecPublicKey`` over ``prime256v1`` carrying a 65-byte
##     uncompressed point, base64'd between ``-----BEGIN PUBLIC KEY-----``
##     lines. It is **not** a ``TPM2B_PUBLIC``. Saying which encoding it
##     is matters, because a key's NAME is
##     ``nameAlg ‖ H_nameAlg(TPMT_PUBLIC)`` and a ``SubjectPublicKeyInfo``
##     carries the public POINT without the surrounding ``TPMT_PUBLIC``
##     that digest is taken over.
##
##     The dropped part is a template rather than a secret, though, so
##     ``AgileQuoteAkNameHex`` IS derivable after all, and
##     ``t_event_log_replay_reproduces_pcrs`` derives it: an attestation
##     key is a restricted ECDSA/SHA-256 signing key on NIST P-256 with
##     an empty auth policy and a fixed ``objectAttributes``
##     (``0x00050072``), so the ``TPMT_PUBLIC`` is rebuilt from the
##     pinned point plus that template and its SHA-256 must equal the
##     pinned name's digest. That binds the two constants to each other
##     BY VALUE — flip one byte of the point or of the name and the gate
##     reddens — which is what keeps them from being evidence-shaped
##     constants nothing reads.
##
##     Note that the attest's ``qualifiedSigner`` is the key's QUALIFIED
##     name — ``H(QN(parent) ‖ Name(object))`` — so it does not equal
##     ``AgileQuoteAkNameHex`` and is not supposed to. A reader who
##     expects them to be equal will read a correct fixture as a broken
##     one, which is why the gate asserts the inequality rather than
##     leaving it to be rediscovered.
##
##     The SIGNATURE is verified too, and no longer only out of band:
##     ``t_pinned_attestation_signatures`` checks this ``TPMT_SIGNATURE``
##     against this key with an ECDSA-P256 verifier, and reddens under a
##     one-byte change to the key, the attest or the signature. That is
##     a *test* doing it — ``repro_attest`` and ``repro_attest_verify``
##     still perform no public-key operation of any kind, so nothing a
##     verdict rests on has changed. The TPM2 codec's own quote vectors
##     pin qualified NAMES but no public keys, so a later reader cannot
##     re-check those pinned bytes. These they can.
##   * **``qualifyingData``** — ``AgileQuoteQualifyingHex`` is 64 bytes
##     drawn from the HOST's ``/dev/urandom`` at capture time and passed
##     to the guest on the kernel command line. Neither the TPM, the
##     firmware nor this codec had any say in them, and they are in this
##     file only so the quote can be re-checked.
##
## ## What these fixtures do NOT establish
##
## The guest booted with ``-kernel``, so there is no bootloader and no
## UKI in the agile log, and Secure Boot was enabled in the firmware
## build but has no keys enrolled — so its ``db``/``dbx`` variable events
## are present but empty, where on real hardware they dominate the log's
## size. swtpm is a TPM implementation rather than a discrete chip.
## Neither log contains a ``StartupLocality`` record or any DRTM event,
## so the replay's handling of those is exercised only by synthesized
## mutations of these logs, and is stated as a refusal rather than as an
## implementation.
##
## ## Mocking
##
## None.

import std/strutils

const
  AgileLogHex* =
    "000000000300000000000000000000000000000000000000000000002d0000005370" &
    "6563204944204576656e74303300000000000002000204000000040014000b002000" &
    "0c0030000d0040000000000000080000000400000004001489f923c4dca729178b3e" &
    "3233458550d8dddf290b0096a296d224f285c67bee93c30f8a309157f0daa35dc5b8" &
    "7e410b78630a09cfc70c001dd6f7b457ad880d840d41c961283bab688e94e4b59359" &
    "ea45686581e90feccea3c624b1226113f824f315eb60ae0a7c0d005ea71dc6d0b4f5" &
    "7bf39aadd07c208c35f06cd2bac5fde210397f70de11d439c62ec1cdf3183758865f" &
    "d387fcea0bada2f6c37a4a17851dd1d78fefe6f204ee540200000000000000000008" &
    "000080040000000400ce7047e99c57bd869fa124116b6c96c5d415de630b00619473" &
    "875638b48d6eff48e3d1e6333c7bdd37c84144480f402c7c98750284110c0007fd9e" &
    "05020912debb3fca369061cb0a90cb7598db4509011dd8cad2aa2a7bd77bcb6855fd" &
    "c5589acf749921a5ee91fc0d004502fba33806e6bc681c4c7541a6cfe9dc4e0eba84" &
    "ec3ada9e0414a60e97fbe4cb1ae3e0fd497810a1c851123b2455d2c6197c080d085b" &
    "21a5b7e0f763167a3410000000000082000000000000000d00000000000000000008" &
    "0000800400000004008922ba670a59a06104bc461da783a59a27daefd20b00b2147e" &
    "98d132bc6af9f9cd5c276ea4c7f7154c193fca6ff83320d52078dfb57c0c00880d76" &
    "53df88527acc80ed1826952c13140e9884db5d4712cc67c43d250df8cd1692c1b88d" &
    "179a69774a707dcac2a76b0d00a527af5e407caa27d59bcf937e909819f84612c739" &
    "d25dd92bfc6e38448f431e3a5295b2f6c87ab3bdf522d723314bdc6b159b5ce55dd2" &
    "b58949c8bf4536a4651000000000009000000000000000e800000000000700000001" &
    "00008004000000040057cd4dc19442475aa82743484f3b1caa88e142b80b00115aa8" &
    "27dbccfb44d216ad9ecfda56bdea620b860a94bed5b7a27bba1c4d02d80c00cfa4e2" &
    "c606f572627bf06d5669cc2ab1128358d27b45bc63ee9ea56ec109cfafb7194006f8" &
    "47a6a74b5eaed6b73332ec0d00d64901b6e1018f31046cbe3a09c36b1e5f2226fc1d" &
    "dee9b893176d439a62fca8acd1c2b91ae25e99086087d72481ea9e05caa76e1777c0" &
    "af75ad7e6ab82ce2253500000061dfe48bca93d211aa0d00e098032b8c0a00000000" &
    "000000010000000000000053006500630075007200650042006f006f007400000700" &
    "0000010000800400000004009b1387306ebb7ff8e795e7be77563666bbf4516e0b00" &
    "dea7b80ab53a3daaa24d5cc46c64e1fa9ffd03739f90aadbd8c0867c4a5b48900c00" &
    "6f2e3cbc14f9def86980f5f66fd85e99d63e69a73014ed8a5633ce56eca5b64b6921" &
    "08c56110e22acadcef58c3250f1b0d00a102c0fdb43102c5546fb04758a70acc5f5e" &
    "798597d62bd2376cdeab37dddfb3b0ca67febc8c4e6069800449baebf9e0bbe7f063" &
    "a7304a45652392f8c8bc7d172400000061dfe48bca93d211aa0d00e098032b8c0200" &
    "000000000000000000000000000050004b0007000000010000800400000004009afa" &
    "86c507419b8570c62167cb9486d9fc8097580b00e670e121fcebd473b8bc41bb8013" &
    "01fc1d9afa33904f06f7149b74f12c47a68f0c00d607c0efb41c0d757d69bca0615c" &
    "3a9ac0b1db06c557d992e906c6b7dee40e0e031640c7bfd7bcd35844ef9edeadc6f9" &
    "0d0090bd5dac05d43171be2f1a705d7fc1937a566aab71031baab64ae6106160a148" &
    "a8110d3326f5e22854a1823ad2131dea3556026601f8dd7628b37152ae97a68e2600" &
    "000061dfe48bca93d211aa0d00e098032b8c03000000000000000000000000000000" &
    "4b0045004b0007000000010000800400000004005bf8faa078d40ffbd03317c93398" &
    "b01229a0e1e00b00baf89a3ccace52750c5f0128351e0422a41597a1adfd50822aa3" &
    "63b9d124ea7c0c0008a74f8963b337acb6c93682f934496373679dd26af1089cb4ea" &
    "f0c30cf260a12e814856385ab8843e56a9acea19e1270d0012152f5b5970582242a7" &
    "ef7087f2a728b87eb9e58db8ca48b0921951a574e29e60887bf45bc00c15f6b96016" &
    "a835b541bb80122a0409d37dbe6143c56207ed5a24000000cbb219d73a3d9645a3bc" &
    "dad00e67656f02000000000000000000000000000000640062000700000001000080" &
    "040000000400734424c9fe8fc71716c42096f4b74c88733b175e0b009f75b6823bff" &
    "6af1024a4e2036719cdd548d3cbc2bf1de8e7ef4d0ed01f94bf90c0018cc6e01f0c6" &
    "ea99aa23f8a280423e94ad81d96d0aeb5180504fc0f7a40cb3619dd39bd6a95ec168" &
    "0a86ed6ab0f9828d0d00621bc3ee7b43730d1a34c7e9508b537204a1ce1fe5910dd7" &
    "7b5aada7e7a5f335de760b18cdd41dbf96c2588fa4652e35e2c1ca619646cae4f8aa" &
    "d51c953e77bd26000000cbb219d73a3d9645a3bcdad00e67656f0300000000000000" &
    "000000000000000064006200780007000000040000000400000004009069ca78e745" &
    "0a285173431b3e52c5c25299e4730b00df3f619804a92fdb4057192dc43dd748ea77" &
    "8adc52bc498ce80524c014b811190c00394341b7182cd227c5c6b07ef8000cdfd861" &
    "36c4292b8e576573ad7ed9ae41019f5818b4b971c9effc60e1ad9f1289f00d00ec2d" &
    "57691d9b2d40182ac565032054b7d784ba96b18bcb5be0bb4e70e3fb041eff582c8a" &
    "f66ee50256539f2181d7f9e53627c0189da7e75a4d5ef10ea93b20b3040000000000" &
    "0000010000000a0000000400000004007a1967c5906815cc2bea4abd839dd930ca34" &
    "a7820b00d04837003ee2a6456441585c71312012c6537d41a1c6a5ac6af5f5d5e576" &
    "b1eb0c0082b6a31d70c1bb6ad5620ed8adfa5cf8d8c28bf7cfae49218c98d8b16eff" &
    "13e6fb5dc24082c001a2344311a2d7f7d2080d006d80ad7ed280d09fc952ca4d0d11" &
    "6d0458f567dbc12628f9e425efccf9c32010c36835cb0e959dd71ea23d9124077850" &
    "7dc64f56432e52112719edf4a03f3ef009000000414350492044415441010000000a" &
    "000000040000000400a42bb2332710383dc92ed97d53e007d30ee3ae7c0b008f44bc" &
    "e5921c584aa6f68cf1c5c54b286977d58558ac32dbfedfe943264ca28e0c00f032e5" &
    "e36637ab7481ed02bdf546da95c4e3cb32cb544963e6e4550ac11819b599d338f2b3" &
    "5e904a1cec561e3050410a0d003f73f6d0fa51be0c59004d6932049f99a7fd799daa" &
    "62d4dec42401565c19a469d7046f04619e806d771356224afbd6fe8d26af6affbf43" &
    "2cbd4ecf3a6283cb8909000000414350492044415441010000000a00000004000000" &
    "04001adc95bebe9eea8c112d40cd04ab7a8d75c4f9610b00de2f256064a0af797747" &
    "c2b97505dc0b9f3df0de4f489eac731c23ae9ca9cc310c0069fca46943118a952e4f" &
    "165e122a47f2b7b5336fa8fa1674a26437d183a7e947f15a4a0afabece6d6b28e3c8" &
    "4f60fac20d0073e4153936dab198397b74ee9efc26093dda721eaab2f8d927868911" &
    "53b45b04265a161b169c988edb0db2c53124607b6eaaa816559c5ce54f3dbc9fa6a7" &
    "a4b209000000414350492044415441010000000a0000000400000004008856478a5d" &
    "b58d9251a48fe056410db03ec665e10b00802970a34c7769a05aeff6b562b3fb7895" &
    "4cffc70d93b99ddc73659a24d677320c0058c4eead7ab4f140cb5697afaddc70d08a" &
    "3f485455a71347577931a49247653f864ec3ac6329183c6f7f9bd767ecb53f0d00aa" &
    "e66d2be9cebed36b8ce6dd7b922e15c73d3305887667c0a4129128e252630d8398e3" &
    "edd627a74029c991d28fad47a3870ea5e0edd762e22668915bc25c954e0900000041" &
    "43504920444154410200000004000080040000000400d0c49e86f994a65fcfc3176c" &
    "bb67d88c6891b13b0b0002455ba6e0a9fc78dd840a456dc68a0c4aa51db58823abcf" &
    "904681052fd9d2970c005413672a5376ce2a170f67c56f883f9e0972054be667c3cf" &
    "6dc69f51d1efe2517a7bf023d79526a7ab755d53d1de73f80d00f0363b111680540f" &
    "e9f7399fa4e238acde6e337ebd051e91856f9e0032aad42d371b2cef838dac1b1247" &
    "ac638c0ff6e61b228b3c631e325910c7c0bd873eb91c4e00000018b0777c00000000" &
    "e06002000000000000000000000000002e0000000000000002010c00d041030a0000" &
    "00000101060000020408180000000000000c010000000000ff6d0200000000007fff" &
    "040004000000030000800400000004005ba803b2ba6cb983746b33d0eb00fcadb2f3" &
    "ed3b0b0070db7fbee1943b731d65346a06d515414ab3d8e5df91810d6a807aff1f5a" &
    "20ea0c007c9cd62baef58e6d8b035be45256f11b513c3df800c7893ac304746bbf91" &
    "ce992777bd8d93703274252351f49557a8b80d004fbebf85f15ca515d66827b5a161" &
    "08524ac2ffcfcc6d724d9fabeb25b3955fc1f50e31291d6831d3180c564db2037be3" &
    "8546c25c963f1193b4ca28608149ac544a00000018b0967b0000000000c2be000000" &
    "000000000000000000002a000000000000000403140072f728144ab61e44b8c39ebd" &
    "d7f893c7040412006b00650072006e0065006c0000007fff04000100000002000080" &
    "040000000400a33f5b5fd6b1caddf4a4adee107a3cc91d2d14d20b006b1e73a0094b" &
    "7b812d3b9e22cffb4f8239319847522c4fa103753b6950020f930c0052b9a02de946" &
    "b947364b57d8210c63113b9058996e2a3ba7cead54af11ae0873b085d1e52bc01e4f" &
    "ebe57ca05ca1332b0d00523bb85dadc2834175740990383658ebc9b3d8d4426c6095" &
    "7f501a4668e65b0f806402e1bfa63f9ac4c180b2f7ccdef624900fbdeb7e68e16adb" &
    "49798301b1683600000061dfe48bca93d211aa0d00e098032b8c0900000000000000" &
    "040000000000000042006f006f0074004f0072006400650072000000010001000000" &
    "02000080040000000400d27fa5467668d1c330457262f3d38ddbe8308bf80b007cec" &
    "d39025081ffa990dbe7078111b2c15102f9da7ac85f25ce54935b9ae0a960c005068" &
    "e6a9ded2a1c3a8ebb5d26004410ea8670742d8f444c5c3d161b76c66fa23a7b1d2fb" &
    "3f9840570b675384b5818f2d0d00e97a48110c191a92803b9221f4b3ba898a486037" &
    "0f7f60cdfc054acc52504ab982cf730716538dcac2ad03a7fb65816739e6aadc7cf1" &
    "d006cb198e8fced35c3a8800000061dfe48bca93d211aa0d00e098032b8c08000000" &
    "00000000580000000000000042006f006f0074003000300030003000090100002c00" &
    "42006f006f0074004d0061006e0061006700650072004d0065006e00750041007000" &
    "7000000004071400c9bdb87cebf8344faaea3ee4af6516a104061400dc5bc2eef267" &
    "954db1d5f81b2039d11d7fff040001000000020000800400000004005027f07abd8b" &
    "3e979aa5121e014c3c36236cc0d30b00e52e99d0e07a49d2553de3de65e8da30fa0b" &
    "ddf34002a1fa17e8c79356c2e1900c00dd424f2eeb35f3e8a2c2f50f6cc87ff90b75" &
    "77e92ce63e13a22869d07d104fd5ea9800e6e4f12c5058fc4eaa78374f200d0031db" &
    "46afb8b1ae9ec593eb5dcc95109cbff4a063334dd91701a6e6faadb5654d67b27260" &
    "0a7c1619444ff12629d726534253c814d01a7c38bcca258ce5eb07e58800000061df" &
    "e48bca93d211aa0d00e098032b8c0800000000000000580000000000000042006f00" &
    "6f0074003000300030003100010100002c0045004600490020004600690072006d00" &
    "7700610072006500200053006500740075007000000004071400c9bdb87cebf8344f" &
    "aaea3ee4af6516a10406140021aa2c4614760345836e8ab6f46623317fff04000400" &
    "000007000080040000000400cd0fdb4531a6ec41be2753ba042637d6e5f7f2560b00" &
    "3d6772b4f84ed47595d72a2c4c5ffd15f5bb72c7507fe26f2aaee2c69d5633ba0c00" &
    "77a0dab2312b4e1e57a84d865a21e5b2ee8d677a21012ada819d0a98988078d3d740" &
    "f6346bfe0abaa938ca20439a8d710d0003020279c5ea3676d6630c82a9931343225e" &
    "8eab81529b65c786aeb6a445d3852a34dd193178f938b6b47345a72d4b647df309c9" &
    "71f7c02f0ede296a136a10862800000043616c6c696e6720454649204170706c6963" &
    "6174696f6e2066726f6d20426f6f74204f7074696f6e000000000400000004000000" &
    "04009069ca78e7450a285173431b3e52c5c25299e4730b00df3f619804a92fdb4057" &
    "192dc43dd748ea778adc52bc498ce80524c014b811190c00394341b7182cd227c5c6" &
    "b07ef8000cdfd86136c4292b8e576573ad7ed9ae41019f5818b4b971c9effc60e1ad" &
    "9f1289f00d00ec2d57691d9b2d40182ac565032054b7d784ba96b18bcb5be0bb4e70" &
    "e3fb041eff582c8af66ee50256539f2181d7f9e53627c0189da7e75a4d5ef10ea93b" &
    "20b3040000000000000001000000040000000400000004009069ca78e7450a285173" &
    "431b3e52c5c25299e4730b00df3f619804a92fdb4057192dc43dd748ea778adc52bc" &
    "498ce80524c014b811190c00394341b7182cd227c5c6b07ef8000cdfd86136c4292b" &
    "8e576573ad7ed9ae41019f5818b4b971c9effc60e1ad9f1289f00d00ec2d57691d9b" &
    "2d40182ac565032054b7d784ba96b18bcb5be0bb4e70e3fb041eff582c8af66ee502" &
    "56539f2181d7f9e53627c0189da7e75a4d5ef10ea93b20b304000000000000000200" &
    "0000040000000400000004009069ca78e7450a285173431b3e52c5c25299e4730b00" &
    "df3f619804a92fdb4057192dc43dd748ea778adc52bc498ce80524c014b811190c00" &
    "394341b7182cd227c5c6b07ef8000cdfd86136c4292b8e576573ad7ed9ae41019f58" &
    "18b4b971c9effc60e1ad9f1289f00d00ec2d57691d9b2d40182ac565032054b7d784" &
    "ba96b18bcb5be0bb4e70e3fb041eff582c8af66ee50256539f2181d7f9e53627c018" &
    "9da7e75a4d5ef10ea93b20b304000000000000000300000004000000040000000400" &
    "9069ca78e7450a285173431b3e52c5c25299e4730b00df3f619804a92fdb4057192d" &
    "c43dd748ea778adc52bc498ce80524c014b811190c00394341b7182cd227c5c6b07e" &
    "f8000cdfd86136c4292b8e576573ad7ed9ae41019f5818b4b971c9effc60e1ad9f12" &
    "89f00d00ec2d57691d9b2d40182ac565032054b7d784ba96b18bcb5be0bb4e70e3fb" &
    "041eff582c8af66ee50256539f2181d7f9e53627c0189da7e75a4d5ef10ea93b20b3" &
    "040000000000000004000000040000000400000004009069ca78e7450a285173431b" &
    "3e52c5c25299e4730b00df3f619804a92fdb4057192dc43dd748ea778adc52bc498c" &
    "e80524c014b811190c00394341b7182cd227c5c6b07ef8000cdfd86136c4292b8e57" &
    "6573ad7ed9ae41019f5818b4b971c9effc60e1ad9f1289f00d00ec2d57691d9b2d40" &
    "182ac565032054b7d784ba96b18bcb5be0bb4e70e3fb041eff582c8af66ee5025653" &
    "9f2181d7f9e53627c0189da7e75a4d5ef10ea93b20b3040000000000000005000000" &
    "040000000400000004009069ca78e7450a285173431b3e52c5c25299e4730b00df3f" &
    "619804a92fdb4057192dc43dd748ea778adc52bc498ce80524c014b811190c003943" &
    "41b7182cd227c5c6b07ef8000cdfd86136c4292b8e576573ad7ed9ae41019f5818b4" &
    "b971c9effc60e1ad9f1289f00d00ec2d57691d9b2d40182ac565032054b7d784ba96" &
    "b18bcb5be0bb4e70e3fb041eff582c8af66ee50256539f2181d7f9e53627c0189da7" &
    "e75a4d5ef10ea93b20b3040000000000000006000000040000000400000004009069" &
    "ca78e7450a285173431b3e52c5c25299e4730b00df3f619804a92fdb4057192dc43d" &
    "d748ea778adc52bc498ce80524c014b811190c00394341b7182cd227c5c6b07ef800" &
    "0cdfd86136c4292b8e576573ad7ed9ae41019f5818b4b971c9effc60e1ad9f1289f0" &
    "0d00ec2d57691d9b2d40182ac565032054b7d784ba96b18bcb5be0bb4e70e3fb041e" &
    "ff582c8af66ee50256539f2181d7f9e53627c0189da7e75a4d5ef10ea93b20b30400" &
    "00000000000001000000090000800400000004000b12e798b91f68d2b14c6d9f70a2" &
    "b009747516e90b008dc8dfa208ca80fc9455cf83cfb3fb653a015e09cdf6e8b3ecaa" &
    "80de3eb21ec60c007d8eb4d2fe8057f92cffb0367f3a12ceb5dd2c9b449c4617ff18" &
    "1da4a9c948199a2b0c524f1309d0bbadf066106d0f620d00965c1ce239c00c8c5470" &
    "e660f6a3744437d21d310fffc7b2229102df4649d1325abffd388aff49651e6e8407" &
    "41c1168d9c1877689334758e2b00ea9c94f58532200000000100000000000000312d" &
    "9deb882dd3119a160090273fc14d00509d7e00000000090000000600000004000000" &
    "0400561071f547a047b9773695d8d8c424f20d2129d40b006b592e8efcdf49a76365" &
    "9f090346c9eb2038862e10a2688ee2e802741bd57aaf0c00273e22c60321c6eb885b" &
    "d652e24799b13bbb1b06a13bddb26864d66f333f3e642c9721b8002d980838bd90f8" &
    "01460aa20d00b792dfc40ef5944ccefac2ededaeb729b7552ad4c55292113552711e" &
    "c38c93fa667ca14a3eab6a8c6b9ec73577e29032101042766549a47abb8fd8dc3150" &
    "806622000000ed223b8f1a0000004c4f414445445f494d4147453a3a4c6f61644f70" &
    "74696f6e73000900000006000000040000000400e10493fcaf9d38bb0d89e60e01da" &
    "963434afdd9a0b00a8c6b6a2673e9b497a3744839b6d8e92ea96fe3ce8fe9bfd6039" &
    "21096233dd500c00aa2ba501fffc9e8571f7d973d19913406d109e5f52fedf102a88" &
    "349cb98d628f525525dd060c98ecb251eb362d9ce4a30d00a8ea64c77d232e5a7256" &
    "03309e183b30f0b1124dd435855ec5e596b7f2893e8e63a938a4492f1a1d507b52ac" &
    "c3b3af81fc9ff784fbfab19a81e50ba89363861a15000000ec223b8f0d0000004c69" &
    "6e757820696e69747264000500000007000080040000000400443a6b7b82b7af564f" &
    "2e393cd9d5a388b7fa4a980b00d8043d6b7b85ad358eb3b6ae6a873ab7ef23a26352" &
    "c5dc4faa5aeedacf5eb41b0c00214b0bef1379756011344877743fdc2a5382bac6e7" &
    "0362d624ccf3f654407c1b4badf7d8f9295dd3dabdef65b27677e00d000fed3a4c95" &
    "52021436534d27f3adb481e22b50b29e4b37a63f518540a651a174f149b69f500b0b" &
    "db2cb3bf4e0e21e0781451090af33e88f6bee4cbebd15c16681d0000004578697420" &
    "426f6f7420536572766963657320496e766f636174696f6e05000000070000800400" &
    "00000400475545ddc978d7bfd036facc7e2e987f48189f0d0b00b54f7542cbd872a8" &
    "1a9d9dea839b2b8d747c7ebd5ea6615c40f42f44a6dbeba00c000a2e01c85deae718" &
    "a530ad8c6d20a84009babe6c8989269e950d8cf440c6e997695e64d455c4174a652c" &
    "d080f6230b740d001bb30cdbd6da78fe2a8a161ef51176e22d64dce305b40b472436" &
    "73af64a2b16fca6182116433e3891be94773f6d7d411275721d5bf7d40ea51a274d5" &
    "c891637c280000004578697420426f6f742053657276696365732052657475726e65" &
    "6420776974682053756363657373"

  LegacyLogHex* =
    "0100000006000000f26d0cbfc291d877070fa5e3750ae4f0c794c5841c0000000100" &
    "000014000000a00e880b194a6796999dbb7096d4038aadb979780200000005000000" &
    "9dbd87163112e5670378abe4510491259a61f411150000005374617274204f707469" &
    "6f6e20524f4d205363616e020000000600000004391495bdb9686d56b3594684f4cf" &
    "ad2715a9c220000000070000001800000000000000359becb4c1dcd61c139ab37869" &
    "83da96406777010200000006000000335b69a74806847108a6afaba11b64f4509dd4" &
    "6320000000070000001800000000000000b49784000930f4069de49dc938676cd204" &
    "bea58302000000060000007d1535d93aa9e88efa15076f9a330f92b02dabc1200000" &
    "000700000018000000000000000bff50c10727bd9c85c831ea92b7a5269995999202" &
    "00000006000000f02e2c264e57bf5347254f77e75492ec3052645120000000070000" &
    "001800000000000000670c9cc79b4859944705eece710dc332188b79b40400000005" &
    "000000c1e25c3f6b0dc78d57296aa2870ca6f782ccf80f0f00000043616c6c696e67" &
    "20494e54203139680000000004000000d9be6524a5f5047db5866813acf3277892a7" &
    "a30a04000000ffffffff0100000004000000d9be6524a5f5047db5866813acf32778" &
    "92a7a30a04000000ffffffff0200000004000000d9be6524a5f5047db5866813acf3" &
    "277892a7a30a04000000ffffffff0300000004000000d9be6524a5f5047db5866813" &
    "acf3277892a7a30a04000000ffffffff0400000004000000d9be6524a5f5047db586" &
    "6813acf3277892a7a30a04000000ffffffff0500000004000000d9be6524a5f5047d" &
    "b5866813acf3277892a7a30a04000000ffffffff0600000004000000d9be6524a5f5" &
    "047db5866813acf3277892a7a30a04000000ffffffff0700000004000000d9be6524" &
    "a5f5047db5866813acf3277892a7a30a04000000ffffffff"

  AgileQuoteAttestHex* =
    "ff54434780180022000b40b907fcd4380012d2cc1539ba8aba959ce0ca38fb36f323" &
    "c1046ecec01bc0960040690c31806609fe7fbc1c783175b3b7ab71cfbaa3d48e0191" &
    "62db57336f9acf83690c31806609fe7fbc1c783175b3b7ab71cfbaa3d48e019162db" &
    "57336f9acf83000000000000450c0000000100000001012024012500120000000000" &
    "01000b03ff0000002052e2d80002744dea991200f3e2f517e985714e60aac2b5d9ac" &
    "ad79bca3d154ec"

  AgileQuoteSignatureHex* =
    "0018000b00200e0423edaa41376bc5ad30481d780fcd461e2a43dbaa123bc4f364d3" &
    "7c0313b000206fd38bb08df81acbc592db8e99a1143948efa1a51bee8d74d6b0e215" &
    "1436c5ee"

  AgileQuoteAkPublicHex* =
    "2d2d2d2d2d424547494e205055424c4943204b45592d2d2d2d2d0a4d466b77457759" &
    "484b6f5a497a6a3043415159494b6f5a497a6a3044415163445167414570796f7679" &
    "414b3961736a6b4e58755337627835414b3042777959690a70755562506f49783164" &
    "686f5541595163575a6543532b316a78467179624a794647306f534355694f664873" &
    "4d5566554249446333546f3272773d3d0a2d2d2d2d2d454e44205055424c4943204b" &
    "45592d2d2d2d2d0a"

  AgileQuoteAkNameHex* =
    "000b5989c5e75939146f43b16803ddb0e04dfa4223ccdc1f4a66aaeacc0deead0dbf"

  AgileQuoteQualifyingHex* =
    "690c31806609fe7fbc1c783175b3b7ab71cfbaa3d48e019162db57336f9acf83" &
    "690c31806609fe7fbc1c783175b3b7ab71cfbaa3d48e019162db57336f9acf83"

  AgilePcrsSha1* = [
    "c75181b2e2a694ecef46a13f1dca35f8a668cb85",   # PCR 0
    "a358f180d3935e6dcdec5cf9ceb26d2fd3dcf566",   # PCR 1
    "d0478c27cd207de087786c7ac011bc80a0dbcd02",   # PCR 2
    "b2a83b0ebf2f8374299a5b2bdfc31ea955ad7236",   # PCR 3
    "620658d21f88c83c97b172e061549fe38131c709",   # PCR 4
    "d16d7e629fd8d08ca256f9ad3a3a1587c9e6cc1b",   # PCR 5
    "b2a83b0ebf2f8374299a5b2bdfc31ea955ad7236",   # PCR 6
    "518bd167271fbb64589c61e43d8c0165861431d8",   # PCR 7
    "0000000000000000000000000000000000000000",   # PCR 8
    "6110bbbde4215120d0c7f114cd43fede3f89168e",   # PCR 9
    "0000000000000000000000000000000000000000",   # PCR 10
    "0000000000000000000000000000000000000000",   # PCR 11
    "0000000000000000000000000000000000000000",   # PCR 12
    "0000000000000000000000000000000000000000",   # PCR 13
    "0000000000000000000000000000000000000000",   # PCR 14
    "0000000000000000000000000000000000000000",   # PCR 15
    "0000000000000000000000000000000000000000",   # PCR 16
    "ffffffffffffffffffffffffffffffffffffffff",   # PCR 17
    "ffffffffffffffffffffffffffffffffffffffff",   # PCR 18
    "ffffffffffffffffffffffffffffffffffffffff",   # PCR 19
    "ffffffffffffffffffffffffffffffffffffffff",   # PCR 20
    "ffffffffffffffffffffffffffffffffffffffff",   # PCR 21
    "ffffffffffffffffffffffffffffffffffffffff",   # PCR 22
    "0000000000000000000000000000000000000000",   # PCR 23
  ]

  AgilePcrsSha256* = [
    "7da18bac0eea20175f86dce9cc23beab07ac7cfa8c5ab9dd45326fa779e7263e",   # PCR 0
    "83db77774ba10b33629edd40d9d513837dc35061de4f711f56d3f108effd906c",   # PCR 1
    "e3cbf180a079ea20d9431e4a07db22abed744c1e66f2fcc9872f092021082c73",   # PCR 2
    "3d458cfe55cc03ea1f443f1562beec8df51c75e14a9fcf9a7234a13f198e7969",   # PCR 3
    "58ad793e02f8ae8e0e3adcc5bfb64be82276d174309156a5b743b66df63a80d4",   # PCR 4
    "a5ceb755d043f32431d63e39f5161464620a3437280494b5850dc1b47cc074e0",   # PCR 5
    "3d458cfe55cc03ea1f443f1562beec8df51c75e14a9fcf9a7234a13f198e7969",   # PCR 6
    "65caf8dd1e0ea7a6347b635d2b379c93b9a1351edc2afc3ecda700e534eb3068",   # PCR 7
    "0000000000000000000000000000000000000000000000000000000000000000",   # PCR 8
    "207301dceef8b9e3f59dd52bfd09e8d0217af76269fa0f7e64dae896576b0e7a",   # PCR 9
    "0000000000000000000000000000000000000000000000000000000000000000",   # PCR 10
    "0000000000000000000000000000000000000000000000000000000000000000",   # PCR 11
    "0000000000000000000000000000000000000000000000000000000000000000",   # PCR 12
    "0000000000000000000000000000000000000000000000000000000000000000",   # PCR 13
    "0000000000000000000000000000000000000000000000000000000000000000",   # PCR 14
    "0000000000000000000000000000000000000000000000000000000000000000",   # PCR 15
    "0000000000000000000000000000000000000000000000000000000000000000",   # PCR 16
    "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",   # PCR 17
    "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",   # PCR 18
    "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",   # PCR 19
    "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",   # PCR 20
    "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",   # PCR 21
    "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",   # PCR 22
    "0000000000000000000000000000000000000000000000000000000000000000",   # PCR 23
  ]

  AgilePcrsSha384* = [
    "551f2e164116f548bcc2a8cb2268746b6f4c564ccd8e25669ea45df378fa5b55f3b0e8ce2ed6746cb3c90f4cc0700efc",   # PCR 0
    "9a86beb3921a6e0afa462457bfd143bc3f057a85500bff5050237c8193303ec2d47765729d3b599da5f5bc1c7fee764c",   # PCR 1
    "2d232069af7199c334b67bf8cb58591d5ffe603f43b7c08f1b5f3ccc35e216284850edf2d5831ac0fc4f6783cd49a1db",   # PCR 2
    "518923b0f955d08da077c96aaba522b9decede61c599cea6c41889cfbea4ae4d50529d96fe4d1afdafb65e7f95bf23c4",   # PCR 3
    "6e27d8aaa07d89a5f2125d0d93d02133efdddc08658f6de55e07dcc2569f88bdc3cf7542425c797059c4c6122570a0b0",   # PCR 4
    "c50b529497c7f441ea47305587d6ce83e2e31f7b4fab6c13dc0b0c3c900e1d0caf0768321100927862df142bf0465ee4",   # PCR 5
    "518923b0f955d08da077c96aaba522b9decede61c599cea6c41889cfbea4ae4d50529d96fe4d1afdafb65e7f95bf23c4",   # PCR 6
    "98441c7f7625d10058c47683aec486ce311c633235eb555593a7ee791121e3578ae72d04ecef661f272d59058b77af35",   # PCR 7
    "000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000",   # PCR 8
    "07f030ea9bc7d53c0270ade60a9671e75ee57cf9f9133e8b5a7aa727ad1a09c6320787c21e7d6aa99de8a242a346bd95",   # PCR 9
    "000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000",   # PCR 10
    "000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000",   # PCR 11
    "000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000",   # PCR 12
    "000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000",   # PCR 13
    "000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000",   # PCR 14
    "000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000",   # PCR 15
    "000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000",   # PCR 16
    "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",   # PCR 17
    "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",   # PCR 18
    "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",   # PCR 19
    "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",   # PCR 20
    "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",   # PCR 21
    "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",   # PCR 22
    "000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000",   # PCR 23
  ]

  AgilePcrsSha512* = [
    "64580a111f8e21b88e56d8b0077b11d7ab53f6f9fb1243cd44c46a6e25577c564c5b8f28128241d9f61aac912b85da68b459912a05aeecf6cb4c325b9095b45c",   # PCR 0
    "502279f0c456a3e5df1203319fe226f268039d2c70ce4e3eb4e6e398ecf5674700b7ddfecf99766f86c23b4851230cf907dd427ad4bfcf70f4a861ef25185e20",   # PCR 1
    "098e83088b94802ac397c832c9c49d338aa61ef62b11d7f47480f24d68936c99f6354ff29308d3146b3329c8982b5513516e2566503c650dfa71c797ad3989e8",   # PCR 2
    "27ec091533c4b9eea38dd14c3a3ecdef0a99c1e564cbe66dfe008250154e7839b0b75228fe8debcc4ca330e6aebc1abc74070bc9c9c1e26b939c9d916e45e13c",   # PCR 3
    "b2ffb24dba9106e3ded2ceee63f9b61f34711ef2bdbf8eddfecba4a9f31f4458859b4fa899b5656cf420cf4a9534bb50b4273afaacb2b082097de988d063d73a",   # PCR 4
    "e1625f0f32e9d099c03b7818ab8d7dbff32175c6482deb5a852aa0792ed365f52fa48e7f3143c5070bd0fd3f9fc78ee3ce62fd0f9c0945ec40448cda934affde",   # PCR 5
    "27ec091533c4b9eea38dd14c3a3ecdef0a99c1e564cbe66dfe008250154e7839b0b75228fe8debcc4ca330e6aebc1abc74070bc9c9c1e26b939c9d916e45e13c",   # PCR 6
    "7793d61d41cf40ae7cbf782dcac336ab5d8546d8b6c369fba740c784e16d4ec83247af2043f6352790a9eb9aab9c95ef318e5dd22c788e0848a10f8c87472a3e",   # PCR 7
    "00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000",   # PCR 8
    "d282f941bb5d0715693e405b5038b8909601ec74ccb133c48f041ae891d16b4995f34725a0ff9e89f3ee73faf505f461c825c51103178c3cf85305f869811616",   # PCR 9
    "00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000",   # PCR 10
    "00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000",   # PCR 11
    "00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000",   # PCR 12
    "00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000",   # PCR 13
    "00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000",   # PCR 14
    "00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000",   # PCR 15
    "00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000",   # PCR 16
    "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",   # PCR 17
    "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",   # PCR 18
    "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",   # PCR 19
    "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",   # PCR 20
    "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",   # PCR 21
    "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",   # PCR 22
    "00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000",   # PCR 23
  ]

  LegacyPcrsSha1* = [
    "3a3f780f11a4b49969fcaa80cd6e3957c33b2275",   # PCR 0
    "51066157543c7cc374554d3389704c8e88cfb1f3",   # PCR 1
    "233bf7821486475056ceab3c27eda8c2dfc9d975",   # PCR 2
    "3a3f780f11a4b49969fcaa80cd6e3957c33b2275",   # PCR 3
    "a9fdeb07a0c479c74e3db3e9493d2c3189766507",   # PCR 4
    "3a3f780f11a4b49969fcaa80cd6e3957c33b2275",   # PCR 5
    "3a3f780f11a4b49969fcaa80cd6e3957c33b2275",   # PCR 6
    "3a3f780f11a4b49969fcaa80cd6e3957c33b2275",   # PCR 7
    "0000000000000000000000000000000000000000",   # PCR 8
    "0000000000000000000000000000000000000000",   # PCR 9
    "0000000000000000000000000000000000000000",   # PCR 10
    "0000000000000000000000000000000000000000",   # PCR 11
    "0000000000000000000000000000000000000000",   # PCR 12
    "0000000000000000000000000000000000000000",   # PCR 13
    "0000000000000000000000000000000000000000",   # PCR 14
    "0000000000000000000000000000000000000000",   # PCR 15
    "0000000000000000000000000000000000000000",   # PCR 16
    "ffffffffffffffffffffffffffffffffffffffff",   # PCR 17
    "ffffffffffffffffffffffffffffffffffffffff",   # PCR 18
    "ffffffffffffffffffffffffffffffffffffffff",   # PCR 19
    "ffffffffffffffffffffffffffffffffffffffff",   # PCR 20
    "ffffffffffffffffffffffffffffffffffffffff",   # PCR 21
    "ffffffffffffffffffffffffffffffffffffffff",   # PCR 22
    "0000000000000000000000000000000000000000",   # PCR 23
  ]

proc unhex*(s: string): string =
  ## The pinned hex, as bytes. A tiny helper rather than an inline
  ## ``parseHexStr`` at every use site, so a gate reads as a statement
  ## about a log rather than about string handling.
  parseHexStr(s)

proc agileLog*(): string = unhex(AgileLogHex)
proc legacyLog*(): string = unhex(LegacyLogHex)
proc agileQuoteAttest*(): string = unhex(AgileQuoteAttestHex)
proc agileQuoteSignature*(): string = unhex(AgileQuoteSignatureHex)
proc agileQuoteQualifying*(): string = unhex(AgileQuoteQualifyingHex)
proc agileQuoteAkPublic*(): string = unhex(AgileQuoteAkPublicHex)
proc agileQuoteAkName*(): string = unhex(AgileQuoteAkNameHex)
