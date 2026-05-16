import std/[json]

import repro_hcr_linkgraph

type
  CJitRegistrationEvidence {.bycopy.} = object
    descriptorAddress: uint64
    descriptorVersion: uint32
    actionFlag: uint32
    relevantEntryAddress: uint64
    firstEntryAddress: uint64
    entryAddress: uint64
    entryNextAddress: uint64
    entryPrevAddress: uint64
    symfileAddress: uint64
    symfileSize: uint64
    retainedDebugObjectAddress: uint64
    retainedDebugObjectSize: uint64
    registerHookCallCount: uint64
    success: uint32

  CUnwindRegistrationEvidence {.bycopy.} = object
    payloadAddress: uint64
    payloadSize: uint64
    codeAddress: uint64
    codeSize: uint64
    api: uint32
    called: uint32
    patchedPcRelative: int64
    patchedRange: uint64

  JitRegistrationEvidence* = object
    descriptorAddress*: uint64
    descriptorVersion*: uint32
    actionFlag*: uint32
    relevantEntryAddress*: uint64
    firstEntryAddress*: uint64
    entryAddress*: uint64
    entryNextAddress*: uint64
    entryPrevAddress*: uint64
    symfileAddress*: uint64
    symfileSize*: uint64
    retainedDebugObjectAddress*: uint64
    retainedDebugObjectSize*: uint64
    registerHookCallCount*: uint64
    retainedDebugObjectDigest*: string
    retainedDebugObjectHexPrefix*: string
    success*: bool

  UnwindRegistrationEvidence* = object
    payloadAddress*: uint64
    payloadSize*: uint64
    codeAddress*: uint64
    codeSize*: uint64
    api*: string
    called*: bool
    patchedPcRelative*: int64
    patchedRange*: uint64
    payloadDigest*: string
    payloadHexPrefix*: string

when defined(macosx) and defined(arm64):
  {.emit: """
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>

enum {
  REPRO_HCR_JIT_NOACTION = 0,
  REPRO_HCR_JIT_REGISTER_FN = 1,
  REPRO_HCR_JIT_UNREGISTER_FN = 2
};

struct jit_code_entry {
  struct jit_code_entry *next_entry;
  struct jit_code_entry *prev_entry;
  const char *symfile_addr;
  uint64_t symfile_size;
};

struct jit_descriptor {
  uint32_t version;
  uint32_t action_flag;
  struct jit_code_entry *relevant_entry;
  struct jit_code_entry *first_entry;
};

struct repro_hcr_jit_record {
  struct jit_code_entry entry;
  uint8_t *debug_bytes;
  uint64_t debug_size;
};

typedef struct {
  uint64_t descriptorAddress;
  uint32_t descriptorVersion;
  uint32_t actionFlag;
  uint64_t relevantEntryAddress;
  uint64_t firstEntryAddress;
  uint64_t entryAddress;
  uint64_t entryNextAddress;
  uint64_t entryPrevAddress;
  uint64_t symfileAddress;
  uint64_t symfileSize;
  uint64_t retainedDebugObjectAddress;
  uint64_t retainedDebugObjectSize;
  uint64_t registerHookCallCount;
  uint32_t success;
} CJitRegistrationEvidence;

typedef struct {
  uint64_t payloadAddress;
  uint64_t payloadSize;
  uint64_t codeAddress;
  uint64_t codeSize;
  uint32_t api;
  uint32_t called;
  int64_t patchedPcRelative;
  uint64_t patchedRange;
} CUnwindRegistrationEvidence;

__attribute__((used, visibility("default")))
struct jit_descriptor __jit_debug_descriptor = {
  1,
  REPRO_HCR_JIT_NOACTION,
  0,
  0
};

static pthread_mutex_t repro_hcr_jit_mutex = PTHREAD_MUTEX_INITIALIZER;
static uint64_t repro_hcr_jit_register_hook_calls = 0;

__attribute__((noinline, used, visibility("default")))
void __jit_debug_register_code(void) {
  repro_hcr_jit_register_hook_calls += 1;
  __asm__ volatile("" ::: "memory");
}

static void repro_hcr_fill_jit_evidence(
    struct repro_hcr_jit_record *record,
    CJitRegistrationEvidence *out) {
  memset(out, 0, sizeof(*out));
  out->descriptorAddress = (uint64_t)(uintptr_t)&__jit_debug_descriptor;
  out->descriptorVersion = __jit_debug_descriptor.version;
  out->actionFlag = __jit_debug_descriptor.action_flag;
  out->relevantEntryAddress =
      (uint64_t)(uintptr_t)__jit_debug_descriptor.relevant_entry;
  out->firstEntryAddress =
      (uint64_t)(uintptr_t)__jit_debug_descriptor.first_entry;
  if (record != 0) {
    out->entryAddress = (uint64_t)(uintptr_t)&record->entry;
    out->entryNextAddress = (uint64_t)(uintptr_t)record->entry.next_entry;
    out->entryPrevAddress = (uint64_t)(uintptr_t)record->entry.prev_entry;
    out->symfileAddress = (uint64_t)(uintptr_t)record->entry.symfile_addr;
    out->symfileSize = record->entry.symfile_size;
    out->retainedDebugObjectAddress = (uint64_t)(uintptr_t)record->debug_bytes;
    out->retainedDebugObjectSize = record->debug_size;
  }
  out->registerHookCallCount = repro_hcr_jit_register_hook_calls;
  out->success = 1;
}

int repro_hcr_register_jit_debug_object(
    const uint8_t *bytes,
    uint64_t size,
    CJitRegistrationEvidence *out) {
  if (bytes == 0 || size == 0 || out == 0) {
    return -1;
  }

  struct repro_hcr_jit_record *record =
      (struct repro_hcr_jit_record *)calloc(1, sizeof(*record));
  if (record == 0) {
    return -2;
  }

  record->debug_bytes = (uint8_t *)malloc((size_t)size);
  if (record->debug_bytes == 0) {
    free(record);
    return -3;
  }
  memcpy(record->debug_bytes, bytes, (size_t)size);
  record->debug_size = size;
  record->entry.symfile_addr = (const char *)record->debug_bytes;
  record->entry.symfile_size = size;

  pthread_mutex_lock(&repro_hcr_jit_mutex);
  record->entry.next_entry = __jit_debug_descriptor.first_entry;
  record->entry.prev_entry = 0;
  if (__jit_debug_descriptor.first_entry != 0) {
    __jit_debug_descriptor.first_entry->prev_entry = &record->entry;
  }
  __jit_debug_descriptor.first_entry = &record->entry;
  __jit_debug_descriptor.relevant_entry = &record->entry;
  __jit_debug_descriptor.action_flag = REPRO_HCR_JIT_REGISTER_FN;
  __jit_debug_register_code();
  repro_hcr_fill_jit_evidence(record, out);
  pthread_mutex_unlock(&repro_hcr_jit_mutex);
  return 0;
}

extern void __register_frame(const void *) __attribute__((weak_import));
extern void __unw_add_dynamic_eh_frame_section(const void *)
    __attribute__((weak_import));

int repro_hcr_register_dynamic_eh_frame(
    const uint8_t *bytes,
    uint64_t size,
    uint64_t code_address,
    uint64_t code_size,
    CUnwindRegistrationEvidence *out) {
  if (bytes == 0 || size == 0 || out == 0) {
    return -1;
  }

  uint8_t *retained = (uint8_t *)malloc((size_t)size);
  if (retained == 0) {
    return -2;
  }
  memcpy(retained, bytes, (size_t)size);

  int64_t patched_pc_relative = 0;
  uint64_t patched_range = code_size;
  if (size >= 0x2c && code_address != 0 && code_size != 0) {
    patched_pc_relative =
        (int64_t)code_address - (int64_t)((uintptr_t)retained + 0x1c);
    memcpy(retained + 0x1c, &patched_pc_relative, sizeof(patched_pc_relative));
    memcpy(retained + 0x24, &patched_range, sizeof(patched_range));
  }

  memset(out, 0, sizeof(*out));
  out->payloadAddress = (uint64_t)(uintptr_t)retained;
  out->payloadSize = size;
  out->codeAddress = code_address;
  out->codeSize = code_size;
  out->patchedPcRelative = patched_pc_relative;
  out->patchedRange = patched_range;

  if (__unw_add_dynamic_eh_frame_section != 0) {
    __unw_add_dynamic_eh_frame_section(retained);
    out->api = 1;
    out->called = 1;
    return 0;
  }

  if (__register_frame != 0) {
    __register_frame(retained);
    out->api = 2;
    out->called = 1;
    return 0;
  }

  out->api = 0;
  out->called = 0;
  return -3;
}
""".}

  proc cRegisterJitDebugObject(bytes: ptr UncheckedArray[byte]; size: uint64;
                               outEvidence: ptr CJitRegistrationEvidence):
                               cint {.
    importc: "repro_hcr_register_jit_debug_object", nodecl.}

  proc cRegisterDynamicEhFrame(bytes: ptr UncheckedArray[byte]; size: uint64;
                               codeAddress: uint64; codeSize: uint64;
                               outEvidence: ptr CUnwindRegistrationEvidence):
                               cint {.
    importc: "repro_hcr_register_dynamic_eh_frame", nodecl.}

proc hexPrefix(bytes: openArray[byte]; maxBytes: int): string =
  let count = min(bytes.len, maxBytes)
  bytesHex(bytes.toOpenArray(0, count - 1))

proc registerJitDebugObject*(bytes: openArray[byte]): JitRegistrationEvidence =
  if bytes.len == 0:
    raise newException(ValueError, "JIT debug object payload is empty")
  when defined(macosx) and defined(arm64):
    var c: CJitRegistrationEvidence
    let rc = cRegisterJitDebugObject(
      cast[ptr UncheckedArray[byte]](unsafeAddr bytes[0]),
      uint64(bytes.len), addr c)
    if rc != 0:
      raise newException(ValueError, "JIT debug registration failed: " & $rc)
    result = JitRegistrationEvidence(
      descriptorAddress: c.descriptorAddress,
      descriptorVersion: c.descriptorVersion,
      actionFlag: c.actionFlag,
      relevantEntryAddress: c.relevantEntryAddress,
      firstEntryAddress: c.firstEntryAddress,
      entryAddress: c.entryAddress,
      entryNextAddress: c.entryNextAddress,
      entryPrevAddress: c.entryPrevAddress,
      symfileAddress: c.symfileAddress,
      symfileSize: c.symfileSize,
      retainedDebugObjectAddress: c.retainedDebugObjectAddress,
      retainedDebugObjectSize: c.retainedDebugObjectSize,
      registerHookCallCount: c.registerHookCallCount,
      retainedDebugObjectDigest: byteDigest(bytes),
      retainedDebugObjectHexPrefix: hexPrefix(bytes, 32),
      success: c.success != 0
    )
  else:
    raise newException(ValueError, "JIT debug registration currently requires macOS arm64")

proc registerDynamicEhFrame*(bytes: openArray[byte]; codeAddress: uint64;
                             codeSize: uint64): UnwindRegistrationEvidence =
  if bytes.len == 0:
    raise newException(ValueError, "dynamic .eh_frame payload is empty")
  when defined(macosx) and defined(arm64):
    var c: CUnwindRegistrationEvidence
    let rc = cRegisterDynamicEhFrame(
      cast[ptr UncheckedArray[byte]](unsafeAddr bytes[0]),
      uint64(bytes.len), codeAddress, codeSize, addr c)
    if rc != 0:
      raise newException(ValueError, "dynamic .eh_frame registration failed: " & $rc)
    let api =
      case c.api
      of 1: "__unw_add_dynamic_eh_frame_section"
      of 2: "__register_frame"
      else: "unavailable"
    result = UnwindRegistrationEvidence(
      payloadAddress: c.payloadAddress,
      payloadSize: c.payloadSize,
      codeAddress: c.codeAddress,
      codeSize: c.codeSize,
      api: api,
      called: c.called != 0,
      patchedPcRelative: c.patchedPcRelative,
      patchedRange: c.patchedRange,
      payloadDigest: byteDigest(bytes),
      payloadHexPrefix: hexPrefix(bytes, 32)
    )
  else:
    raise newException(ValueError, "dynamic .eh_frame registration currently requires macOS arm64")

proc jitRegistrationJson*(evidence: JitRegistrationEvidence): JsonNode =
  %*{
    "descriptorAddress": evidence.descriptorAddress,
    "descriptorVersion": evidence.descriptorVersion,
    "actionFlag": evidence.actionFlag,
    "relevantEntryAddress": evidence.relevantEntryAddress,
    "firstEntryAddress": evidence.firstEntryAddress,
    "entryAddress": evidence.entryAddress,
    "entryNextAddress": evidence.entryNextAddress,
    "entryPrevAddress": evidence.entryPrevAddress,
    "symfileAddress": evidence.symfileAddress,
    "symfileSize": evidence.symfileSize,
    "retainedDebugObjectAddress": evidence.retainedDebugObjectAddress,
    "retainedDebugObjectSize": evidence.retainedDebugObjectSize,
    "registerHookCallCount": evidence.registerHookCallCount,
    "retainedDebugObjectDigest": evidence.retainedDebugObjectDigest,
    "retainedDebugObjectHexPrefix": evidence.retainedDebugObjectHexPrefix,
    "success": evidence.success
  }

proc unwindRegistrationJson*(evidence: UnwindRegistrationEvidence): JsonNode =
  %*{
    "payloadAddress": evidence.payloadAddress,
    "payloadSize": evidence.payloadSize,
    "codeAddress": evidence.codeAddress,
    "codeSize": evidence.codeSize,
    "api": evidence.api,
    "called": evidence.called,
    "patchedPcRelative": evidence.patchedPcRelative,
    "patchedRange": evidence.patchedRange,
    "payloadDigest": evidence.payloadDigest,
    "payloadHexPrefix": evidence.payloadHexPrefix
  }

proc minimalAarch64EhFrameTemplate*(): seq[byte] =
  @[
    0x10'u8, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x01, 0x7a, 0x52, 0x00, 0x01, 0x78, 0x1e, 0x01,
    0x10, 0x0c, 0x1f, 0x00, 0x28, 0x00, 0x00, 0x00,
    0x18, 0x00, 0x00, 0x00, 0xe4, 0xff, 0xff, 0xff,
    0xff, 0xff, 0xff, 0xff, 0x14, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x44, 0x0e, 0x10,
    0x9d, 0x02, 0x9e, 0x01, 0x44, 0x0d, 0x1d, 0x48,
    0x0c, 0x1f, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
  ]
