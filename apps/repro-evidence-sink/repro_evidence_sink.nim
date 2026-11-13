## `repro-evidence-sink` — the Evidence zone of the Distributed-Execution
## worker pool (deployment-security-architecture.md EVID-2, EVID-3, EVID-6,
## DET-5). Its own binary rather than a `repro` verb for the reason the
## attestation agent is: it runs on a different host from the workers it
## records, and what its operator trusts is its dependency closure.
##
##   repro-evidence-sink serve --dir D --identity DIR --anchors DIR
##                             --checkpoint-key DIR
##                             [--bind ADDR] [--port N] [--revoked FILE]
##                             [--retention-seconds N] [--ready-file F]
##                             [--segment-max-entries N]
##       Accepts appends (and only appends) from workers whose host CA is in
##       the anchor directory (re-read for every connection; `--revoked`
##       lists host ids refused at their next frame). `--identity` holds the
##       sink's own host CA (`host-ca.crt`, minted on first start; copy it
##       to every worker as `<tls dir>/evidence-sink.crt` — the one CA its
##       appender trusts). `--checkpoint-key` holds the checkpoint-signing
##       key and must not be inside `--dir`; copy its
##       `sink-checkpoint.crt` somewhere the operator keeps it, for
##       `verify`. Deletes segments past retention on its own.
##
##   repro-evidence-sink verify   --dir D --checkpoint-pub CERT
##                                [--receipt FILE ...] [--live]
##       hash chain, checkpoint signatures, no unanchored tail (unless
##       `--live`), and every receipt an appender kept still present
##   repro-evidence-sink liveness --dir D [--silence-factor N]
##                                [--expect FILE]
##       per (host, detector) DET-5 status; `--expect` lists the
##       detectors that must exist (`never-reported` otherwise)
##   repro-evidence-sink read     --dir D     one line per entry (operator use)
##   repro-evidence-sink payload  --dir D --seq N [--out FILE]
##       a record's captured payload, escaped, between markers (hostile data)
##   repro-evidence-sink ack      --dir D --seq N --operator NAME --reason TEXT
##       record that the detection at sequence N was handled
##   repro-evidence-sink addon-check --dir D --hosts FILE
##                                [--manifests DIR --deploy-signers FILE]
##                                [--published-artefacts SHA256SUMS]
##                                [--silence-factor N] [--now-ms MS]
##                                [--update-hosts]
##       the ReproOS add-on's off-host detectors over the store: every
##       add-on detection as an alert, silence (DET-5), attestation
##       mismatch and lag against the producer's published manifests. Exit
##       0 with no alert, 1 with one or more. --update-hosts writes each
##       host's attestation key and generation 0 into the hosts file the
##       first time its bootstrap record shows them, so they outlive the
##       store's retention.
##
## Every option takes its value as `--name=value` or `--name value`
## (``repro_addon/evidence_sink_cli``, where the command line lives so that
## a test can hold the published user guide's lines to it).
##
## The read-side commands open the store directory directly: reading is
## local to the sink host by design (EVID-3). There is no network read.

import std/os

import repro_addon/evidence_sink_cli

when isMainModule:
  quit(runSinkCli(commandLineParams()))
