## Attestation support: expected launch measurements and the documents
## that carry them.
##
## The image build emits a measurement manifest; a verifier compares a
## running machine's evidence against it. Both halves need the same
## schema and the same calculators, so both live here rather than in
## either consumer.
##
## Submodules:
##   * ``repro_attest/measurement`` — precomputation of a unified kernel
##     image's PCR 11 from the image bytes, and the replay template that
##     lets a verifier re-derive it without the image.
##   * ``repro_attest/snp_launch`` — precomputation of the launch
##     measurement a confidential guest's security processor will report,
##     from the firmware image and the parameters of the launch.
##   * ``repro_attest/tdx_launch`` — precomputation of the initial-memory
##     measurement a trust domain reports, from the firmware image, and
##     the replay of the four runtime registers from the log the domain
##     wrote.
##   * ``repro_attest/manifest`` — the ``reproos.attested-image.v1``
##     document: typed record, canonical renderer, strict parser.
##   * ``repro_attest/tpm2`` — the TPM 2.0 structure codec: the
##     big-endian TLV a measured-boot machine signs, plus recomputation
##     of a quote's PCR composite digest.
##   * ``repro_attest/event_log`` — the TCG event log: both wire shapes
##     (TCG 1.2 and crypto-agile), and the replay that recomputes a
##     machine's PCR values from it so a quote can be checked against
##     what the log claims produced it.
##   * ``repro_attest/binding`` — the 64-byte report data an instance
##     binds into hardware evidence, constructed once for every backend.
##   * ``repro_attest/report`` — the ``reproos.attestation-report.v1``
##     envelope an instance answers a challenge with: typed record,
##     canonical renderer, strict parser, and the trust rules encoded in
##     the names a reader has to use.
##   * ``repro_attest/driver`` — the backend seam: what the agent asks a
##     root of trust for, and the little it is allowed to tell it.
##   * ``repro_attest/provision`` — the framed document a released secret
##     travels in, and the two context strings that bind it to one key
##     agreement. Bytes in, bytes out: it composes no ciphertext, so it
##     needs no cryptography and is re-exported here.
##   * ``repro_attest/mock_backend`` — a backend for a root of trust that
##     does not exist, so every other layer runs unmodified without one.
##   * ``repro_attest/sealing`` — the policy a TPM requires before it
##     releases a secret bound to a launch measurement, computed from
##     the image's bytes, plus the reader for the sealed object that
##     carries it.
##   * ``repro_attest/hpke`` — RFC 9180 hybrid public key encryption,
##     which is how a secret gets to the machine an attestation just
##     established the identity of. Not re-exported, and deliberately: it
##     links BearSSL, and ``repro_attest`` is compiled into recipe
##     accessor contexts that are staged without a ``nim-bearssl`` on the
##     path. Import ``repro_attest/hpke`` directly.
##   * ``repro_attest/x25519_kem`` — the mechanism itself: the ephemeral
##     key source the agent mints key agreements with, and the opener
##     that recovers what was released to one. Not re-exported, for the
##     same reason ``hpke`` is not — it is built on it.
##   * ``repro_attest/tpm2_backend`` — the measured-boot backend: the
##     ``reproos.tpm2-evidence.v1`` composite that carries a quote, its
##     signature and the TCG event log as one blob, and the driver that
##     assembles it.
##   * ``repro_attest/tsm_report`` — the kernel's unified
##     attestation-report directory: the write-then-read pass a
##     confidential guest makes over it, and the counter discipline that
##     makes the document it reads back an answer to the question it
##     asked rather than to a question another process asked.
##   * ``repro_attest/snp_backend`` — the security-processor backend:
##     the driver that hands over the document a confidential guest's
##     firmware signed, the checks that establish it answers THIS
##     request, and the reader that turns the host's GUID-indexed
##     certificate table into the list of certificates an envelope
##     carries.
##   * ``repro_attest/cloud_launch`` — describing a launch on a public
##     cloud: the parameters a provider is asked for, which of them reach
##     the expectation a verifier compares against, the provider
##     invocation such a launch would be made with, and the seam that
##     invocation would have to travel through. It performs no launch and
##     this build ships nothing that could.
##   * ``repro_attest/tdx_backend`` — the trust-domain backend: the
##     driver that hands over the quote a quoting enclave produced, and
##     the checks that establish it answers THIS request. It bundles no
##     certificates, because a trust-domain quote carries its own chain
##     inside the signed document.

import ./repro_attest/measurement
import ./repro_attest/snp_launch
import ./repro_attest/tdx_launch
import ./repro_attest/tpm2
import ./repro_attest/event_log
import ./repro_attest/manifest
import ./repro_attest/binding
import ./repro_attest/report
import ./repro_attest/driver
import ./repro_attest/provision
import ./repro_attest/mock_backend
import ./repro_attest/tpm2_backend
import ./repro_attest/tsm_report
import ./repro_attest/snp_backend
import ./repro_attest/tdx_backend
import ./repro_attest/sealing
import ./repro_attest/cloud_launch

export measurement, snp_launch, tdx_launch, tpm2, event_log, manifest,
       binding, report, driver, provision, mock_backend, tpm2_backend,
       tsm_report, snp_backend, tdx_backend, sealing, cloud_launch
