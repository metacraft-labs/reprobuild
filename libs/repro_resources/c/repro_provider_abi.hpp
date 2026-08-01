/*
 * repro_provider_abi.hpp — reference C++ RAII wrapper over the Reprobuild
 * C-ABI provider-library transport (Low-Level-Provider-Protocol.md §6.4).
 *
 * Header-only. This is the DOCUMENTED PATTERN for a C++ consumer, not a full
 * client: it binds the two owned resources of the ABI (the provider handle and
 * a result buffer) to scope so the callee's EXPORTED free is called on scope
 * exit and a leak / double-free is hard to write (§6.2). Rust (`Drop`) and
 * Python (context manager / finalizer) follow the SAME shape when a consumer
 * in those languages actually appears; they are deferred until then.
 *
 * Ownership, restated for C++ (§6.2): the provider allocates on its own heap;
 * you MUST release its handle via repro_provider_close and its buffers via
 * repro_buffer_free — never `delete` / `free` them yourself. These wrappers do
 * exactly that in their deleter / destructor.
 */
#ifndef REPRO_PROVIDER_ABI_HPP
#define REPRO_PROVIDER_ABI_HPP

#include "repro_provider_abi.h"

#include <memory>
#include <stdexcept>
#include <string>

namespace repro {

/* A unique_ptr whose deleter is the callee-EXPORTED repro_provider_close, so
 * the provider handle is closed on scope exit through the correct allocator. */
struct ProviderHandleDeleter {
  void operator()(repro_provider_session *h) const noexcept {
    repro_provider_close(h);
  }
};
using ProviderHandle =
    std::unique_ptr<repro_provider_session, ProviderHandleDeleter>;

/* Open a provider session; throws on a non-OK status (never leaks the out
 * handle — on error the ABI leaves it NULL, §6.2). */
inline ProviderHandle open_provider(uint32_t abi_version = REPRO_ABI_VERSION) {
  repro_provider_handle_t raw = nullptr;
  repro_status_t st = repro_provider_open(abi_version, &raw);
  if (st != REPRO_OK) {
    throw std::runtime_error("repro_provider_open failed with status " +
                             std::to_string(static_cast<int>(st)));
  }
  return ProviderHandle(raw);
}

/* A scope-bound owner of a callee-allocated result buffer. The destructor
 * calls the EXPORTED repro_buffer_free (idempotent, resets to {NULL,0}), so
 * the buffer is released through the provider's own allocator and a
 * double-free is a no-op. Move-only, matching the single-owner contract. */
class Buffer {
public:
  Buffer() : buf_{nullptr, 0} {}
  ~Buffer() { repro_buffer_free(&buf_); }

  Buffer(const Buffer &) = delete;
  Buffer &operator=(const Buffer &) = delete;
  Buffer(Buffer &&o) noexcept : buf_{o.buf_.data, o.buf_.len} {
    o.buf_.data = nullptr;
    o.buf_.len = 0;
  }
  Buffer &operator=(Buffer &&o) noexcept {
    if (this != &o) {
      repro_buffer_free(&buf_);
      buf_ = o.buf_;
      o.buf_.data = nullptr;
      o.buf_.len = 0;
    }
    return *this;
  }

  /* Address to hand an ABI op as its `out_buf` out-parameter. */
  repro_buffer_t *out() noexcept { return &buf_; }
  const uint8_t *data() const noexcept { return buf_.data; }
  size_t size() const noexcept { return buf_.len; }

private:
  repro_buffer_t buf_;
};

/* Typed convenience over the resource ops: inputs are BORROWED (the wrappers
 * never take ownership of them); the OWNED result lands in a scope-bound
 * Buffer. Throws on a non-OK status. */
inline Buffer digest(const ProviderHandle &h, const void *inst, size_t inst_len) {
  Buffer out;
  repro_status_t st =
      repro_resource_digest(h.get(), inst, inst_len, out.out());
  if (st != REPRO_OK) {
    throw std::runtime_error(std::string("repro_resource_digest: ") +
                             repro_last_error(h.get()));
  }
  return out;
}

} // namespace repro

#endif /* REPRO_PROVIDER_ABI_HPP */
