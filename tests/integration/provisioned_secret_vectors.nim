## Evidence from one machine that was handed a secret over a network and
## then power cycled — and from a second machine that leaked the same
## secret onto its disk on purpose.
##
## Taken by `attested_boot/take-provisioned-secret-evidence.sh`, which
## boots a guest under QEMU, runs the attestation agent inside it,
## releases an HPKE-wrapped secret to it from the host over a forwarded
## TCP port, power cycles it, and then **searches the raw disk image**.
## Read the harness's header for what it does and, more importantly, for
## what it deliberately does not: there is no unified kernel image, no
## firmware, no TPM and no measured boot in this experiment. Its subject
## is where the plaintext went.
##
## ## Nothing secret is pinned here
##
## The released secret and the planted token were 64-character
## hexadecimal values drawn from the host's random source, they existed
## only in that run, and neither appears in this file. What is pinned is
## their SHA-256 — recorded independently by the host that released the
## secret, by the guest that decrypted it, and by the search — so the
## three can be shown to be talking about one value without anybody
## having to publish it.
##
## ## Why the second run exists
##
## "The secret was not found on the disk" is worth nothing from a search
## that cannot find anything. Three separate things answer that, and two
## of them are boots rather than arguments:
##
##   * the planted token, written by the same guest to the same
##     filesystem in the same cycle, IS found;
##   * the same search over the same image with the secret appended DOES
##     find it;
##   * and a whole second run of the harness, in which the guest copies
##     its released secret onto the disk, produces `secret_hits=1`.
##
## ## Mocking
##
## None. These are files a real machine and a real host wrote.


const
  ProvisionedSecretProvisionCycleReport* = """cycle=provision
leak_requested=0
eth0_up=1
state_mount_rc=0
state_fstype=ext4
run_fstype=tmpfs
agent_pid=109
waited_seconds=3
secret_present=1
secret_bytes=64
secret_sha256=1290766b0cca1f8a04892befc81a86822e5e50846f16490c19603b0c502b7d56
secret_mode=-rw-------
secrets_dir_fstype=tmpfs
planted_bytes=64
leaked_to_disk=0
state_files=24
done=1"""
    ## The `provision` cycle of the honest run, as the guest wrote it from
  ## inside itself.

  ProvisionedSecretAfterRebootCycleReport* = """cycle=after-reboot
leak_requested=0
eth0_up=1
state_mount_rc=0
state_fstype=ext4
run_fstype=tmpfs
secrets_dir_present=0
secrets_dir_entries=0
planted_on_disk=1
planted_matches=1
state_files=24
leaked_on_disk=0
done=1"""
    ## The same machine's second boot. The tmpfs is gone and the disk is not.

  ProvisionedSecretDiskSearchRecord* = """image=state.img
image_bytes=100663296
token_chars=64
secret_sha256=1290766b0cca1f8a04892befc81a86822e5e50846f16490c19603b0c502b7d56
planted_sha256=763c8a7fac4033a2984452bb946ae54fbdbe6edbc99dbfca959572572bcbd682
secret_hits=0
planted_hits=1
leak_requested=0
secret_hits_when_planted=1"""
    ## What the HOST found when it searched the raw block device after the
  ## machine had been power cycled. This is the assertion; everything
  ## above it is corroboration.

  ProvisionedSecretReleaserReport* = """agent=http://127.0.0.1:24222
secret_bytes=64
secret_sha256=1290766b0cca1f8a04892befc81a86822e5e50846f16490c19603b0c502b7d56
secret_name=released-credential
policy_digest=sha256:a6033a4b0522ade8846ac48aa4709102e9610709bbaef2cf2b56031a3c125de3
health_backend=mock
health_tier=mock
health_key_agreement=hpke-x25519-hkdf-sha256-aes128gcm
health_can_release=true
health_secrets_dir=/run/attested-secrets
challenge=b4d251ab09d1ab807f02a857a373648e0dd859d5cbbe015af21681877993f93b
challenge_issued_at=2026-09-19T03:50:49Z
key_agreement_status=200
report_purpose=key-agreement
report_ephemeral_pub=dd58d771c8c3900226d02f7fc9a9df3c30fa82db7dfa432200c08d379c6c2f39
report_binds_challenge=true
verdict=accepted-without-a-root-of-trust
release_decision=released
wrapped_secret_sha256=8d122ebf28e6dfe33172231af20592b255febe0f30d393a56148cdde23b7ca4c
wrapped_secret_base64_len=204
wrapped_carries_plaintext=false
provision_status=200
provision_path=/run/attested-secrets/released-credential
provision_bytes=64
replay_status=404"""
    ## The verifier's own account of the release, written on the host.

  ProvisionedSecretReleaseAuditLog* = """{"schema":"reproos.attestation-release-audit.v1","atMs":1789789849928,"challenge":"b4d251ab09d1ab807f02a857a373648e0dd859d5cbbe015af21681877993f93b","measurement":"-","policyDigest":"sha256:a6033a4b0522ade8846ac48aa4709102e9610709bbaef2cf2b56031a3c125de3","manifestDigest":"","verdict":"accepted-without-a-root-of-trust","decision":"released","secretName":"released-credential","ephemeralPub":"dd58d771c8c3900226d02f7fc9a9df3c30fa82db7dfa432200c08d379c6c2f39","reason":"the verdict is accepted-without-a-root-of-trust and the secret was encrypted to the ephemeral key that verdict's evidence binds"}"""
    ## Every release decision the verifier made, as `FileAuditSink` appended
  ## them.

  ProvisionedSecretLeakingProvisionCycleReport* = """cycle=provision
leak_requested=1
eth0_up=1
state_mount_rc=0
state_fstype=ext4
run_fstype=tmpfs
agent_pid=109
waited_seconds=3
secret_present=1
secret_bytes=64
secret_sha256=c25bdf4cf788c44c00acb865f33d22b91f4b19b95345d3b37ddba8116a0f368b
secret_mode=-rw-------
secrets_dir_fstype=tmpfs
planted_bytes=64
leaked_to_disk=1
state_files=24
done=1"""
    ## THE NEGATIVE CONTROL, and it is a real boot: a second full run of the
  ## same harness in which the guest copies the released secret onto the
  ## persistent disk.

  ProvisionedSecretLeakingDiskSearchRecord* = """image=state.img
image_bytes=100663296
token_chars=64
secret_sha256=c25bdf4cf788c44c00acb865f33d22b91f4b19b95345d3b37ddba8116a0f368b
planted_sha256=c4b32324a587b5eec9b57b7974538562fae9a5bbacb11b3dd19f149e56294edf
secret_hits=1
planted_hits=1
leak_requested=1
secret_hits_when_planted=2"""
    ## The same search, over that run's image. It FINDS the secret.

  ProvisionedSecretLeakingReleaserReport* = """agent=http://127.0.0.1:22556
secret_bytes=64
secret_sha256=c25bdf4cf788c44c00acb865f33d22b91f4b19b95345d3b37ddba8116a0f368b
secret_name=released-credential
policy_digest=sha256:a6033a4b0522ade8846ac48aa4709102e9610709bbaef2cf2b56031a3c125de3
health_backend=mock
health_tier=mock
health_key_agreement=hpke-x25519-hkdf-sha256-aes128gcm
health_can_release=true
health_secrets_dir=/run/attested-secrets
challenge=43de47ba07b764e3fba2e772deec6020b981c2d29c4c0dd9fef7c0e6fd14b4c4
challenge_issued_at=2026-09-19T03:51:51Z
key_agreement_status=200
report_purpose=key-agreement
report_ephemeral_pub=f21ef2e42ab13df88e2ae01e687ebe0bdb2dd8624a9783998d913141098cbc27
report_binds_challenge=true
verdict=accepted-without-a-root-of-trust
release_decision=released
wrapped_secret_sha256=9e961c53a0c8c36d8d38042c661363f06d04c13c2536534a5a28c24a0c227843
wrapped_secret_base64_len=204
wrapped_carries_plaintext=false
provision_status=200
provision_path=/run/attested-secrets/released-credential
provision_bytes=64
replay_status=404"""
    ## The leaking run's verifier record, so the two runs can be shown to be
  ## two runs rather than one reported twice.

