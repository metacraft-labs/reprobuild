/*
 * GDH-M4 real host process — a long-running session that serves MORE THAN ONE
 * reload.
 *
 * Design: `codetracer-specs/Planned-Features/`
 *         `GDScript-Hot-Reload-Multi-Version-Sources.md` §4.2-§4.4.
 * Milestone: the `GDH-M4` block of the campaign's `.milestones.org`.
 *
 * `allowed_mocks: none`, and this file is where that is cashed out. The host
 * is a real process linking the PRODUCTION C agent
 * (`libs/repro_hcr_agent/c/repro_hcr_agent.c`), speaking the real
 * `Content-Length` wire over a real `AF_UNIX` socket. Nothing here replies
 * without applying something:
 *
 *   * the agent verifies the notification's `snapshotDigest` against the bytes
 *     it decoded, and its `lineCount` against the bytes it counted, BEFORE the
 *     handler below is reached;
 *   * the handler WRITES the received content to disk, re-READS it back, and
 *     reports a digest recomputed over what came back off the filesystem.
 *
 * That last step is deliberate. A handler that hashed the pointer it was
 * handed would produce a digest that always matches, and the acknowledgement
 * would be a chain of `success: true` — which
 * `codetracer-specs/Testing/Verification-Harness-Traps.md` §2 states is not a
 * result. Round-tripping the bytes through the filesystem makes the reported
 * digest evidence that the content was actually taken in.
 *
 * The process also prints its OWN account of the session on stdout, so the
 * gate can check the wire transcript against something the host says
 * independently rather than grading the protocol with the protocol.
 *
 * Environment:
 *   REPRO_HCR_AGENT_SOCKET   the agent socket (read by the agent itself)
 *   GDH4_APPLY_DIR           where applied generations are written (required)
 *   GDH4_NO_SOURCE_RELOAD    when set and non-empty, NO handler is registered,
 *                            so the agent advertises no `source-reload` and
 *                            must answer `capability-not-negotiated`. This is
 *                            the control pairing for
 *                            `gdh4_unnegotiated_capability_is_refused_not_ignored`:
 *                            one binary, one flag, so the refusal is shown to
 *                            be caused by negotiation and not by anything else
 *                            differing between two programs.
 *   GDH4_MAX_WAIT_MS         how long to keep the session open (default 20000)
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/time.h>

#include "repro_hcr_agent.h"

#define GDH4_MAX_APPLIES 8

static char gdh4_apply_dir[1024];

struct gdh4_record {
  char source_path[512];
  unsigned int generation;
  char reload_id[128];
  char applied_digest[96];
  unsigned int applied_line_count;
  size_t byte_count;
};

static struct gdh4_record gdh4_records[GDH4_MAX_APPLIES];
static int gdh4_record_count = 0;
static int gdh4_refusal_count = 0;

/* Stable storage for the strings the agent reads back out of the outcome. */
static char gdh4_digest_slot[GDH4_MAX_APPLIES][96];
static char gdh4_reason_slot[128];
static char gdh4_detail_slot[2048];

static long long gdh4_now_ms(void) {
  struct timeval tv;
  gettimeofday(&tv, NULL);
  return (long long)tv.tv_sec * 1000LL + (long long)tv.tv_usec / 1000LL;
}

static void gdh4_json_escape(const char *value, char *out, size_t out_cap) {
  size_t used = 0;
  if (out_cap == 0) {
    return;
  }
  for (; value != NULL && *value != '\0' && used + 7 < out_cap; ++value) {
    unsigned char ch = (unsigned char)*value;
    if (ch == '"' || ch == '\\') {
      out[used++] = '\\';
      out[used++] = (char)ch;
    } else if (ch < 0x20) {
      used += (size_t)snprintf(out + used, out_cap - used, "\\u%04x", ch);
    } else {
      out[used++] = (char)ch;
    }
  }
  out[used] = '\0';
}

/*
 * The reload handler. Writes the new generation, reads it back, and reports a
 * digest over the bytes that came back.
 */
static int gdh4_apply_source_reload(void *ctx, const char *reload_id,
                                    const char *language,
                                    const repro_hcr_source_changed_file *file,
                                    repro_hcr_source_reload_outcome *out) {
  char path[1536];
  FILE *handle;
  unsigned char *readback = NULL;
  long readback_len = 0;
  int slot = gdh4_record_count;

  (void)ctx;
  (void)language;

  if (slot >= GDH4_MAX_APPLIES) {
    out->applied = 0;
    out->reason = REPRO_HCR_RELOAD_REASON_WRITER_REFUSED;
    snprintf(gdh4_detail_slot, sizeof(gdh4_detail_slot),
             "this host records at most %d applied generations",
             GDH4_MAX_APPLIES);
    out->detail = gdh4_detail_slot;
    gdh4_refusal_count++;
    return -1;
  }

  snprintf(path, sizeof(path), "%s/applied-gen%u.gd", gdh4_apply_dir,
           file->generation);
  handle = fopen(path, "wb");
  if (handle == NULL) {
    out->applied = 0;
    out->reason = REPRO_HCR_RELOAD_REASON_WRITER_REFUSED;
    snprintf(gdh4_detail_slot, sizeof(gdh4_detail_slot),
             "cannot open %s for writing", path);
    out->detail = gdh4_detail_slot;
    gdh4_refusal_count++;
    return -1;
  }
  if (file->content_length > 0 &&
      fwrite(file->content, 1, file->content_length, handle) !=
          file->content_length) {
    fclose(handle);
    out->applied = 0;
    out->reason = REPRO_HCR_RELOAD_REASON_WRITER_REFUSED;
    snprintf(gdh4_detail_slot, sizeof(gdh4_detail_slot),
             "short write to %s", path);
    out->detail = gdh4_detail_slot;
    gdh4_refusal_count++;
    return -1;
  }
  fclose(handle);

  handle = fopen(path, "rb");
  if (handle == NULL) {
    out->applied = 0;
    out->reason = REPRO_HCR_RELOAD_REASON_WRITER_REFUSED;
    snprintf(gdh4_detail_slot, sizeof(gdh4_detail_slot),
             "cannot re-read %s", path);
    out->detail = gdh4_detail_slot;
    gdh4_refusal_count++;
    return -1;
  }
  fseek(handle, 0, SEEK_END);
  readback_len = ftell(handle);
  fseek(handle, 0, SEEK_SET);
  readback = (unsigned char *)malloc((size_t)(readback_len > 0 ? readback_len : 1));
  if (readback == NULL ||
      (readback_len > 0 &&
       fread(readback, 1, (size_t)readback_len, handle) !=
           (size_t)readback_len)) {
    fclose(handle);
    free(readback);
    out->applied = 0;
    out->reason = REPRO_HCR_RELOAD_REASON_WRITER_REFUSED;
    snprintf(gdh4_detail_slot, sizeof(gdh4_detail_slot),
             "short read back from %s", path);
    out->detail = gdh4_detail_slot;
    gdh4_refusal_count++;
    return -1;
  }
  fclose(handle);

  {
    char hex[65];
    if (repro_hcr_agent_sha256_hex(readback, (size_t)readback_len, hex,
                                   sizeof(hex)) != 0) {
      free(readback);
      out->applied = 0;
      out->reason = REPRO_HCR_RELOAD_REASON_DIGEST_ALGORITHM;
      snprintf(gdh4_reason_slot, sizeof(gdh4_reason_slot), "%s",
               REPRO_HCR_RELOAD_REASON_DIGEST_ALGORITHM);
      out->detail = "the host's sha256 failed its own self-test";
      gdh4_refusal_count++;
      return -1;
    }
    snprintf(gdh4_digest_slot[slot], sizeof(gdh4_digest_slot[slot]),
             "sha256:%s", hex);
  }

  {
    /* Count the lines in what came BACK off disk, not in what arrived. */
    unsigned int counted = readback_len == 0 ? 0u : 1u;
    long i;
    for (i = 0; i + 1 < readback_len; ++i) {
      if (readback[i] == '\n') {
        counted++;
      }
    }
    out->applied_line_count = counted;
    gdh4_records[slot].applied_line_count = counted;
  }

  snprintf(gdh4_records[slot].source_path,
           sizeof(gdh4_records[slot].source_path), "%s", file->source_path);
  snprintf(gdh4_records[slot].reload_id, sizeof(gdh4_records[slot].reload_id),
           "%s", reload_id == NULL ? "" : reload_id);
  snprintf(gdh4_records[slot].applied_digest,
           sizeof(gdh4_records[slot].applied_digest), "%s",
           gdh4_digest_slot[slot]);
  gdh4_records[slot].generation = file->generation;
  gdh4_records[slot].byte_count = (size_t)readback_len;
  gdh4_record_count++;

  free(readback);

  out->applied = 1;
  out->reason = "";
  out->detail = "";
  out->applied_digest = gdh4_digest_slot[slot];
  /* Stand-ins for the writer coordinates §4.3 wants. GDH-M4 is the protocol
   * milestone and this host has no trace writer; GDH-M5's engine host fills
   * these from `trace_writer_register_path_version` and
   * `trace_writer_next_step_index`. They are monotone here so that a gate can
   * still see two acknowledgements being about two different moments. */
  out->path_index = (unsigned long long)(slot + 1);
  out->step_index = (unsigned long long)((slot + 1) * 1000);
  out->unpreserved_count = 0;
  return 0;
}

int main(void) {
  const char *dir = getenv("GDH4_APPLY_DIR");
  const char *no_reload = getenv("GDH4_NO_SOURCE_RELOAD");
  const char *max_wait = getenv("GDH4_MAX_WAIT_MS");
  long long deadline_ms = 20000;
  long long started;
  int start_rc;
  int poll_rc;
  int handler_registered = 0;
  int i;

  if (dir == NULL || dir[0] == '\0') {
    fprintf(stderr, "GDH4-HOST-FAIL: GDH4_APPLY_DIR is required\n");
    return 2;
  }
  snprintf(gdh4_apply_dir, sizeof(gdh4_apply_dir), "%s", dir);
  if (max_wait != NULL && max_wait[0] != '\0') {
    deadline_ms = strtoll(max_wait, NULL, 10);
  }

  if (no_reload == NULL || no_reload[0] == '\0') {
    if (repro_hcr_agent_set_source_reload_handler(gdh4_apply_source_reload,
                                                  NULL) != 0) {
      fprintf(stderr, "GDH4-HOST-FAIL: handler registration refused\n");
      return 2;
    }
    handler_registered = 1;
  }

  start_rc = repro_hcr_agent_start_polling_from_env(
      repro_hcr_agent_default_support_profile(), NULL, 0);
  if (start_rc != 0) {
    fprintf(stderr, "GDH4-HOST-FAIL: start_polling_from_env rc %d\n", start_rc);
    return 2;
  }

  /* The first poll performs the handshake and blocks for the first frame; the
   * loop then drains. This is the shape GDH-M5's engine seam uses, exercised
   * here by a host that is nothing but the seam. */
  poll_rc = repro_hcr_agent_poll();
  started = gdh4_now_ms();
  while (repro_hcr_agent_poll_session_open() &&
         gdh4_now_ms() - started < deadline_ms) {
    repro_hcr_agent_poll();
    usleep(2000);
  }

  printf("{\"schemaId\":\"reprobuild.hcr.gdh4.source-reload-host-result.v1\","
         "\"startRc\":%d,\"pollRc\":%d,"
         "\"handlerRegistered\":%s,"
         "\"advertisesSourceReload\":%s,"
         "\"messagesHandled\":%d,"
         "\"sessionStillOpen\":%s,"
         "\"refusals\":%d,"
         "\"applied\":[",
         start_rc, poll_rc, handler_registered ? "true" : "false",
         repro_hcr_agent_advertises_source_reload() ? "true" : "false",
         repro_hcr_agent_poll_messages_handled(),
         repro_hcr_agent_poll_session_open() ? "true" : "false",
         gdh4_refusal_count);
  for (i = 0; i < gdh4_record_count; ++i) {
    char path_esc[1024];
    char reload_esc[256];
    gdh4_json_escape(gdh4_records[i].source_path, path_esc, sizeof(path_esc));
    gdh4_json_escape(gdh4_records[i].reload_id, reload_esc, sizeof(reload_esc));
    printf("%s{\"sourcePath\":\"%s\",\"reloadId\":\"%s\",\"generation\":%u,"
           "\"appliedDigest\":\"%s\",\"appliedLineCount\":%u,\"byteCount\":%zu}",
           i == 0 ? "" : ",", path_esc, reload_esc, gdh4_records[i].generation,
           gdh4_records[i].applied_digest, gdh4_records[i].applied_line_count,
           gdh4_records[i].byte_count);
  }
  printf("]}\n");
  fflush(stdout);
  return 0;
}
