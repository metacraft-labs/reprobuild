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
##   * ``repro_attest/manifest`` — the ``reproos.attested-image.v1``
##     document: typed record, canonical renderer, strict parser.
##   * ``repro_attest/binding`` — the 64-byte report data an instance
##     binds into hardware evidence, constructed once for every backend.
##   * ``repro_attest/report`` — the ``reproos.attestation-report.v1``
##     envelope an instance answers a challenge with: typed record,
##     canonical renderer, strict parser, and the trust rules encoded in
##     the names a reader has to use.

import ./repro_attest/measurement
import ./repro_attest/manifest
import ./repro_attest/binding
import ./repro_attest/report

export measurement, manifest, binding, report
