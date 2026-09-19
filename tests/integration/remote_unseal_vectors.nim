## One machine's evidence about state volumes it holds no key for.
##
## Every constant below is the verbatim output of one real run of
## `attested_boot/take-remote-unseal-evidence.sh`. The records are the
## flat `key=value` documents the guest, the client and the broker each
## wrote; the search record is the host's, written with no guest
## involved.
##
## ## Two runs, and why there have to be two
##
## The `RemoteUnseal*` constants come from ONE machine across THREE power
## cycles with the volumes persisting: it enrolled, it booted by
## attesting, and it was then refused.
##
## The `UnlockedDespiteRefusal*` constants come from a SECOND, SEPARATE
## run whose initramfs carries a local copy of the volume key — which is
## the arrangement this work removes. Its broker refuses in exactly the
## same way, with the same status and the same sentence, and its volumes
## open anyway and its boot completes. That is the only thing in this
## file that establishes that "the broker refused", "the volumes stayed
## locked" and "the encrypted root filesystem never ran" are three
## questions rather than one, and it establishes it with a boot rather
## than with an argument.
##
## The second run is a different machine with different volumes and a
## different key, and it has to be: a machine that never cached the key
## cannot be made to have cached it after the fact. What the two runs
## share is the image recipe, the broker, the policy and the refusal.
##
## ## NOTHING SECRET IS HERE
##
## The volume key existed only in the broker's memory, in one HPKE
## ciphertext, and on one process's standard input inside the guest. It
## appears in no constant below; what appears is its SHA-256, written
## independently by the broker that released it, by the client that
## opened it and by the host that searched for it, so that three
## producers can be shown to be talking about one value without
## publishing it.
##
## The sentinel is the same: the records carry its digest, the raw token
## reached only the console log and the inside of an encrypted volume,
## and neither is pinned.
##
## The `marker_*` values are 32-byte random values written INSIDE the
## volumes. They are useless without the key and they are what lets a
## later cycle say it opened the same volume rather than a freshly made
## one. The `raw_data_*` values are the ciphertext the block device
## carries at the LUKS data offset, read with no mapping in the way.
##
## ## Mocking
##
## None. Real QEMU guests, real LUKS2 volumes, a real broker in its own
## process on the other side of a socket, and a real `cryptsetup`.

const
  RemoteUnsealEnrollReport* = """cycle=enroll
broker_url_present=1
eth0_up=1
tpm_devices=0
tpm_class_entries=0
local_key_files=0
format_rc=0
client_rc=0
mkfs_root_rc=0
enroll_mount_root_rc=0
rootfs_installed=1
mkfs_home_rc=0
enroll_mount_home_rc=0
probe_ran=0
probe_key_source=-
probe_root_rc=-1
probe_home_rc=-1
mapper_entries=reproos-state-home,reproos-state-root,
luks_uuid_root=a785d33f-06d3-4e78-b86d-010498f5315d
status_root=active
marker_root=90cf7622998acda3f47cf17ed6f9c8c1927c12437cf5a5de311e30dd6267f800
raw_magic_root=4c554b53babe
raw_data_root=704724f820e3deafee081bc4fb6cdc7ac6cd0b688857ffbc88a65a01defd0cd9141baf11459688e828ae1644d4220fb6a2b4f865bc9fcd8ff05efeb359acc843
luks_uuid_home=a7547d2f-fb42-4e5a-8352-597e84fed640
status_home=active
marker_home=cc041b432992f5b9f47ecb750f5acc5f1e8e28545bf25855825818c150f7ddb2
raw_magic_home=4c554b53babe
raw_data_home=58ffb396362ef2844c5a5499f13df0557467931af74275462009f4c900a19516f1b75d762c25d4ab681f84f9b566ced14c3b5823437ab3964eeb9979c4f21ae0
sysroot_mounted=1
switch_root_attempted=1
boot_outcome=handing-off
end=1
"""
  RemoteUnsealUnsealReport* = """cycle=unseal
broker_url_present=1
eth0_up=1
tpm_devices=0
tpm_class_entries=0
local_key_files=0
client_rc=0
probe_ran=0
probe_key_source=-
probe_root_rc=-1
probe_home_rc=-1
mapper_entries=reproos-state-home,reproos-state-root,
luks_uuid_root=a785d33f-06d3-4e78-b86d-010498f5315d
status_root=active
marker_root=90cf7622998acda3f47cf17ed6f9c8c1927c12437cf5a5de311e30dd6267f800
raw_magic_root=4c554b53babe
raw_data_root=704724f820e3deafee081bc4fb6cdc7ac6cd0b688857ffbc88a65a01defd0cd9141baf11459688e828ae1644d4220fb6a2b4f865bc9fcd8ff05efeb359acc843
luks_uuid_home=a7547d2f-fb42-4e5a-8352-597e84fed640
status_home=active
marker_home=cc041b432992f5b9f47ecb750f5acc5f1e8e28545bf25855825818c150f7ddb2
raw_magic_home=4c554b53babe
raw_data_home=58ffb396362ef2844c5a5499f13df0557467931af74275462009f4c900a19516f1b75d762c25d4ab681f84f9b566ced14c3b5823437ab3964eeb9979c4f21ae0
sysroot_mounted=1
switch_root_attempted=1
boot_outcome=handing-off
end=1
"""
  RemoteUnsealRefuseReport* = """cycle=refuse
broker_url_present=1
eth0_up=1
tpm_devices=0
tpm_class_entries=0
local_key_files=0
client_rc=3
probe_key_source=zero-filled
probe_ran=1
probe_root_rc=2
probe_home_rc=2
mapper_entries=
luks_uuid_root=a785d33f-06d3-4e78-b86d-010498f5315d
status_root=inactive
marker_root=-
raw_magic_root=4c554b53babe
raw_data_root=704724f820e3deafee081bc4fb6cdc7ac6cd0b688857ffbc88a65a01defd0cd9141baf11459688e828ae1644d4220fb6a2b4f865bc9fcd8ff05efeb359acc843
luks_uuid_home=a7547d2f-fb42-4e5a-8352-597e84fed640
status_home=inactive
marker_home=-
raw_magic_home=4c554b53babe
raw_data_home=58ffb396362ef2844c5a5499f13df0557467931af74275462009f4c900a19516f1b75d762c25d4ab681f84f9b566ced14c3b5823437ab3964eeb9979c4f21ae0
sysroot_mounted=0
switch_root_attempted=0
boot_outcome=failed
end=1
"""
  RemoteUnsealEnrollFormatClientReport* = """broker=http://10.0.2.2:42969
secret_name=state-volume-key
broker_status=200
challenge=0c8cf77850272ebbb3c48b026dfc4f6a79b0e7daced055b15cad92ff0c47cdb4
ephemeral_pub=4b57fbae8f8e0ac7f74e0a5631d337d581f71c0a3808387a53d30cf2d6779257
unseal_decision=unsealed
unseal_refusal=-
unseal_reason=-
released_key_bytes=64
action=format
volumes_requested=2
cryptsetup=/nix/store/4clffgqr9ygnpnm1hj8ggls4cs41ydm2-cryptsetup-2.8.6-bin/bin/cryptsetup
released_key_sha256=f3c6af6925dfac62e4bf49bed0930855a842bb18afc208a084e05f522a8142d7
open_reproos-state-root_rc=0
open_reproos-state-home_rc=0
opener_ran=1
volumes_opened=2
exit=0
end=1
"""
  RemoteUnsealEnrollOpenClientReport* = """broker=http://10.0.2.2:42969
secret_name=state-volume-key
broker_status=200
challenge=53cac3791812b2ade2b7e228e2b577ea7d0117b804beadf5309c9453f223189c
ephemeral_pub=355d1b81a48c29fd92f51721be6e9a9b60581f91bfde13ca7124bca53ab60104
unseal_decision=unsealed
unseal_refusal=-
unseal_reason=-
released_key_bytes=64
action=open
volumes_requested=2
cryptsetup=/nix/store/4clffgqr9ygnpnm1hj8ggls4cs41ydm2-cryptsetup-2.8.6-bin/bin/cryptsetup
released_key_sha256=f3c6af6925dfac62e4bf49bed0930855a842bb18afc208a084e05f522a8142d7
open_reproos-state-root_rc=0
open_reproos-state-home_rc=0
opener_ran=1
volumes_opened=2
exit=0
end=1
"""
  RemoteUnsealUnsealClientReport* = """broker=http://10.0.2.2:46341
secret_name=state-volume-key
broker_status=200
challenge=77e68326f36c7dc286b7d85a09bc823eec4955322766e224b9eafbdaa0350cee
ephemeral_pub=c96b4c44c84f8906bb7798c95f6401b35328c6918829caa239abceb08df33f06
unseal_decision=unsealed
unseal_refusal=-
unseal_reason=-
released_key_bytes=64
action=open
volumes_requested=2
cryptsetup=/nix/store/4clffgqr9ygnpnm1hj8ggls4cs41ydm2-cryptsetup-2.8.6-bin/bin/cryptsetup
released_key_sha256=f3c6af6925dfac62e4bf49bed0930855a842bb18afc208a084e05f522a8142d7
open_reproos-state-root_rc=0
open_reproos-state-home_rc=0
opener_ran=1
volumes_opened=2
exit=0
end=1
"""
  RemoteUnsealRefuseClientReport* = """broker=http://10.0.2.2:37415
secret_name=state-volume-key
broker_status=403
challenge=73e7931ac6fad6543ad9992443ac5452d051358ea257ba7b6cb2f3d436df62c3
ephemeral_pub=435540061f3ab1009ee0463fc275c1bcb17a1e802a44efca7c24ec9936f91038
unseal_decision=refused
unseal_refusal=release-status
unseal_reason=the broker refused to release "state-volume-key": Status 403: the verdict is accepted-without-a-root-of-trust, which establishes that the documents agree with each other and nothing about a machine; releasing against it is a deliberate opt-in this request did not make 
released_key_bytes=0
released_key_sha256=-
action=open
volumes_requested=2
cryptsetup=/nix/store/4clffgqr9ygnpnm1hj8ggls4cs41ydm2-cryptsetup-2.8.6-bin/bin/cryptsetup
opener_ran=0
volumes_opened=0
exit=3
end=1
"""
  RemoteUnsealUnsealBrokerRecord* = """request=1
secret_sha256=f3c6af6925dfac62e4bf49bed0930855a842bb18afc208a084e05f522a8142d7
secret_bytes=64
policy_digest=sha256:5501f5c42f19e6063671a23bd515be7db0d66c8aff0ac28dbd746199ba0cdb04
require_root_of_trust=0
asked_name=state-volume-key
challenge=77e68326f36c7dc286b7d85a09bc823eec4955322766e224b9eafbdaa0350cee
verdict=accepted-without-a-root-of-trust
release_decision=released
release_reason=the verdict is accepted-without-a-root-of-trust and the secret was encrypted to the ephemeral key that verdict's evidence binds
audit_challenge=77e68326f36c7dc286b7d85a09bc823eec4955322766e224b9eafbdaa0350cee
audit_ephemeral_pub=c96b4c44c84f8906bb7798c95f6401b35328c6918829caa239abceb08df33f06
audit_policy_digest=sha256:5501f5c42f19e6063671a23bd515be7db0d66c8aff0ac28dbd746199ba0cdb04
outcome=released
wrapped_bytes=204
wrapped_carries_plaintext=false
end=1
"""
  RemoteUnsealRefuseBrokerRecord* = """request=1
secret_sha256=f3c6af6925dfac62e4bf49bed0930855a842bb18afc208a084e05f522a8142d7
secret_bytes=64
policy_digest=sha256:5501f5c42f19e6063671a23bd515be7db0d66c8aff0ac28dbd746199ba0cdb04
require_root_of_trust=1
asked_name=state-volume-key
challenge=73e7931ac6fad6543ad9992443ac5452d051358ea257ba7b6cb2f3d436df62c3
verdict=accepted-without-a-root-of-trust
release_decision=withheld
release_reason=the verdict is accepted-without-a-root-of-trust, which establishes that the documents agree with each other and nothing about a machine; releasing against it is a deliberate opt-in this request did not make
audit_challenge=73e7931ac6fad6543ad9992443ac5452d051358ea257ba7b6cb2f3d436df62c3
audit_ephemeral_pub=435540061f3ab1009ee0463fc275c1bcb17a1e802a44efca7c24ec9936f91038
audit_policy_digest=sha256:5501f5c42f19e6063671a23bd515be7db0d66c8aff0ac28dbd746199ba0cdb04
outcome=withheld
wrapped_bytes=0
end=1
"""
  RemoteUnsealEnrollRootfsReport* = """cycle=enroll
rootfs_sentinel_sha256=9d32575fef60c48659d57dcd219cc9416363b33afcaa98221834f3a4f86992c0
rootfs_marker=90cf7622998acda3f47cf17ed6f9c8c1927c12437cf5a5de311e30dd6267f800
rootfs_init_sha256=e73f6b3bfd2524719cad386ef7dce63097ec370226a0219da30cb0e57f2f3194
end=1
"""
  RemoteUnsealUnsealRootfsReport* = """cycle=unseal
rootfs_sentinel_sha256=9d32575fef60c48659d57dcd219cc9416363b33afcaa98221834f3a4f86992c0
rootfs_marker=90cf7622998acda3f47cf17ed6f9c8c1927c12437cf5a5de311e30dd6267f800
rootfs_init_sha256=e73f6b3bfd2524719cad386ef7dce63097ec370226a0219da30cb0e57f2f3194
end=1
"""
  RemoteUnsealSearchRecord* = """volume_bytes=167772160
initrd_bytes=9711104
token_chars=64
key_sha256=f3c6af6925dfac62e4bf49bed0930855a842bb18afc208a084e05f522a8142d7
sentinel_sha256=9d32575fef60c48659d57dcd219cc9416363b33afcaa98221834f3a4f86992c0
rootfs_init_sha256=e73f6b3bfd2524719cad386ef7dce63097ec370226a0219da30cb0e57f2f3194
key_hits_root_volume=0
key_hits_home_volume=0
key_hits_initrd=0
sentinel_hits_root_volume=0
sentinel_hits_initrd=0
sentinel_hits_home_volume=0
key_coverage_root_volume=5/5
sentinel_coverage_root_volume=5/5
key_coverage_initrd=5/5
sentinel_coverage_initrd=5/5
key_hits_outshare=0
outshare_search_finds_a_planted_file=1
local_key_fallback=0
sentinel_in_share_before_enroll=1
sentinel_in_share_before_unseal=0
sentinel_in_share_before_refuse=0
console_sentinel_enroll=1
rootfs_report_enroll=1
handoff_enroll=1
key_hits_console_enroll=0
console_sentinel_unseal=1
rootfs_report_unseal=1
handoff_unseal=1
key_hits_console_unseal=0
console_sentinel_refuse=0
rootfs_report_refuse=0
handoff_refuse=0
key_hits_console_refuse=0
end=1
"""
  RemoteUnsealUnsealAuditLog* = """{"schema":"reproos.attestation-release-audit.v1","atMs":1789829294327,"challenge":"77e68326f36c7dc286b7d85a09bc823eec4955322766e224b9eafbdaa0350cee","measurement":"-","policyDigest":"sha256:5501f5c42f19e6063671a23bd515be7db0d66c8aff0ac28dbd746199ba0cdb04","manifestDigest":"","verdict":"accepted-without-a-root-of-trust","decision":"released","secretName":"state-volume-key","ephemeralPub":"c96b4c44c84f8906bb7798c95f6401b35328c6918829caa239abceb08df33f06","reason":"the verdict is accepted-without-a-root-of-trust and the secret was encrypted to the ephemeral key that verdict's evidence binds"}
"""
  RemoteUnsealRefuseAuditLog* = """{"schema":"reproos.attestation-release-audit.v1","atMs":1789829300639,"challenge":"73e7931ac6fad6543ad9992443ac5452d051358ea257ba7b6cb2f3d436df62c3","measurement":"-","policyDigest":"sha256:5501f5c42f19e6063671a23bd515be7db0d66c8aff0ac28dbd746199ba0cdb04","manifestDigest":"","verdict":"accepted-without-a-root-of-trust","decision":"withheld","secretName":"state-volume-key","ephemeralPub":"435540061f3ab1009ee0463fc275c1bcb17a1e802a44efca7c24ec9936f91038","reason":"the verdict is accepted-without-a-root-of-trust, which establishes that the documents agree with each other and nothing about a machine; releasing against it is a deliberate opt-in this request did not make"}
"""
  UnlockedDespiteRefusalReport* = """cycle=refuse
broker_url_present=1
eth0_up=1
tpm_devices=0
tpm_class_entries=0
local_key_files=1
client_rc=3
probe_key_source=cached-local-key
probe_ran=1
probe_root_rc=0
probe_home_rc=0
mapper_entries=reproos-state-home,reproos-state-root,
luks_uuid_root=adff577c-bffa-4c42-acc8-3e6f05384d49
status_root=active
marker_root=d0c6283303d2a9ece4f0da18b428c19d6963ed03f64e7c645c27795f1d724f88
raw_magic_root=4c554b53babe
raw_data_root=fe923677011124886a1a522e7938142ef75fc21c21e19e7079dbf46bc7c02a5f449a6262f7ca7aff60536a6eab12ee313161024d4366a17284bb45ff47a51250
luks_uuid_home=0b53b9af-3ab2-4958-bf45-63592f79a734
status_home=active
marker_home=6ebeeb7de1c6650a8e672d14068487a539c72e22802a646c91dd9a5c26843ebc
raw_magic_home=4c554b53babe
raw_data_home=0e715cc8b27898e371ad8f6a9f04789b629d117ededb75bd6dc6867a1f7723b2a798dd4c024f47908defa9af7477bfcf34bd8caf4b27e21dc0042eba0b1a650d
sysroot_mounted=1
switch_root_attempted=1
boot_outcome=handing-off
end=1
"""
  UnlockedDespiteRefusalClientReport* = """broker=http://10.0.2.2:43909
secret_name=state-volume-key
broker_status=403
challenge=bbe7d1af03aeb88e1f0617e1462638a748852b832872158edb2e0efa49e7e141
ephemeral_pub=530ec6bc005afc405347a1ebb83f859c64fac36c18ff809576105940df1bd570
unseal_decision=refused
unseal_refusal=release-status
unseal_reason=the broker refused to release "state-volume-key": Status 403: the verdict is accepted-without-a-root-of-trust, which establishes that the documents agree with each other and nothing about a machine; releasing against it is a deliberate opt-in this request did not make 
released_key_bytes=0
released_key_sha256=-
action=open
volumes_requested=2
cryptsetup=/nix/store/4clffgqr9ygnpnm1hj8ggls4cs41ydm2-cryptsetup-2.8.6-bin/bin/cryptsetup
opener_ran=0
volumes_opened=0
exit=3
end=1
"""
  UnlockedDespiteRefusalBrokerRecord* = """request=1
secret_sha256=1a1bbff423ab7b27186ecc358ec21cb7a1fa966f877d44c91931a409db6f328e
secret_bytes=64
policy_digest=sha256:5501f5c42f19e6063671a23bd515be7db0d66c8aff0ac28dbd746199ba0cdb04
require_root_of_trust=1
asked_name=state-volume-key
challenge=bbe7d1af03aeb88e1f0617e1462638a748852b832872158edb2e0efa49e7e141
verdict=accepted-without-a-root-of-trust
release_decision=withheld
release_reason=the verdict is accepted-without-a-root-of-trust, which establishes that the documents agree with each other and nothing about a machine; releasing against it is a deliberate opt-in this request did not make
audit_challenge=bbe7d1af03aeb88e1f0617e1462638a748852b832872158edb2e0efa49e7e141
audit_ephemeral_pub=530ec6bc005afc405347a1ebb83f859c64fac36c18ff809576105940df1bd570
audit_policy_digest=sha256:5501f5c42f19e6063671a23bd515be7db0d66c8aff0ac28dbd746199ba0cdb04
outcome=withheld
wrapped_bytes=0
end=1
"""
  UnlockedDespiteRefusalRootfsReport* = """cycle=refuse
rootfs_sentinel_sha256=91a0c76bc4a88e2c282ec18b175372555d3255bf0fece43d4515f8539dad3dbe
rootfs_marker=d0c6283303d2a9ece4f0da18b428c19d6963ed03f64e7c645c27795f1d724f88
rootfs_init_sha256=9c8d8048680c075da64c43beceb5e145594f896555d2c2f8e422ba3bc94154e4
end=1
"""
  UnlockedDespiteRefusalSearchRecord* = """volume_bytes=167772160
initrd_bytes=9711616
token_chars=64
key_sha256=1a1bbff423ab7b27186ecc358ec21cb7a1fa966f877d44c91931a409db6f328e
sentinel_sha256=91a0c76bc4a88e2c282ec18b175372555d3255bf0fece43d4515f8539dad3dbe
rootfs_init_sha256=9c8d8048680c075da64c43beceb5e145594f896555d2c2f8e422ba3bc94154e4
key_hits_root_volume=0
key_hits_home_volume=0
key_hits_initrd=1
sentinel_hits_root_volume=0
sentinel_hits_initrd=0
sentinel_hits_home_volume=0
key_coverage_root_volume=5/5
sentinel_coverage_root_volume=5/5
key_coverage_initrd=5/5
sentinel_coverage_initrd=5/5
key_hits_outshare=0
outshare_search_finds_a_planted_file=1
local_key_fallback=1
sentinel_in_share_before_enroll=1
sentinel_in_share_before_refuse=0
console_sentinel_enroll=1
rootfs_report_enroll=1
handoff_enroll=1
key_hits_console_enroll=0
console_sentinel_refuse=1
rootfs_report_refuse=1
handoff_refuse=1
key_hits_console_refuse=0
end=1
"""
