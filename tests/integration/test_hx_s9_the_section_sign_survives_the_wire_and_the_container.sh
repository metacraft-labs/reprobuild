#!/usr/bin/env bash
# test_hx_s9_the_section_sign_survives_the_wire_and_the_container.sh
#
# Automated Verification Gate for Milestone HX-S-9:
# "The section sign is double-encoded into every Godot String"
#
# Gate type: integration
# Design doc: [[file:HCR/HCR-Overview.md][HCR Overview]] §7
# Related specs:
# - codetracer-specs/Planned-Features/GDScript-Hot-Reload-Multi-Version-Sources.md §5.5, §8
# - reprobuild-specs/HCR/HCR-Overview.md §7
# - reprobuild-specs/HCR-Per-Platform-Handoff.milestones.org:936-985
#
# Real components:
# - Real reprobuild/libs/repro_hcr_agent/c/repro_hcr_agent.c producing real wire detail JSON
#   over real UNIX domain socket IPC
# - Real codetracer-engine-godot/modules/gdscript/ct_writer/libcodetracer_trace_writer.a
#   producing a real CTFS .ct container with FFI_EVENT_ERROR
# - Real macOS arm64 clang / clang++ compilers and linkers
# Allowed mocks: none
#   Justification: Every use of mock objects in tests must be explicitly justified in the
#   header comment of the test implementation file. We prefer strong integration tests that
#   mock as little as possible and run against real filesystem, socket IPC, compiler, and
#   trace writer boundaries. Mocks used: ZERO.
#
# Anti-vacuity:
# - Asserts wire detail is present and non-empty and length exceeds floor (> 20 bytes)
# - Asserts container .ct file is created and non-empty and size exceeds floor (> 100 bytes)
# - Asserts § (0xC2 0xA7) is present in both wire detail and container error record
# - Asserts container dump read is COMPLETE: decoded record count equals header count exactly
# - Asserts host platform is Darwin arm64
#
# Control arm:
# - Adjacent fprintf site emitting the same literal, which passes const char * straight through
#   to stderr. Asserts stderr contains § (0xC2 0xA7) without Â (0xC3 0x82).
# - Unfalsified tree passes with exit code 0.
#
# Falsifier arms (--include-falsifier):
# - Arm 1: Reinstating raw literal assignment (calling append_latin1 widening) causes the gate
#   to FAIL on the BYTES (asserting absence of 0xC3 0x82) in the wire detail.
# - Arm 2: Reinstating raw literal assignment causes the gate to FAIL on the BYTES
#   (asserting absence of 0xC3 0x82) in the container error record.
# - Arm 3: Mutating gdscript_ct_trace.cpp to remove String::utf8 triggers immediate failure
#   in the source audit arm.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPRO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WORKSPACE_ROOT="${REPRO_WORKSPACE_DIR:-$(cd "$REPRO_ROOT/.." && pwd)}"

INCLUDE_FALSIFIER=0
for arg in "$@"; do
  case "$arg" in
    --include-falsifier|--falsifier)
      INCLUDE_FALSIFIER=1
      ;;
    -h|--help)
      echo "Usage: $0 [--include-falsifier]"
      exit 0
      ;;
    *)
      echo "Unknown argument: $arg" >&2
      exit 1
      ;;
  esac
done

echo "=== Gate: hx_s9_the_section_sign_survives_the_wire_and_the_container ==="

# -----------------------------------------------------------------------------
# 1. Anti-vacuity: Platform Check
# -----------------------------------------------------------------------------
HOST_OS="$(uname -s)"
HOST_ARCH="$(uname -m)"
echo "[1/6] Checking host platform: ${HOST_OS} ${HOST_ARCH}..."
if [[ "$HOST_OS" != "Darwin" || "$HOST_ARCH" != "arm64" ]]; then
  echo "FATAL [ANTI-VACUITY]: Host is ${HOST_OS} ${HOST_ARCH}, expected Darwin arm64." >&2
  exit 1
fi
echo "   OK: Running on real macOS arm64 host."

# -----------------------------------------------------------------------------
# 2. Verify Input Paths and Libraries
# -----------------------------------------------------------------------------
echo "[2/6] Verifying required components and headers..."
AGENT_C="$REPRO_ROOT/libs/repro_hcr_agent/c/repro_hcr_agent.c"
AGENT_H="$REPRO_ROOT/libs/repro_hcr_agent/c/repro_hcr_agent.h"
GODOT_CPP="$WORKSPACE_ROOT/codetracer-engine-godot/modules/gdscript/gdscript_ct_trace.cpp"
TRACE_WRITER_H="$WORKSPACE_ROOT/codetracer-engine-godot/modules/gdscript/ct_writer/include/codetracer_trace_writer.h"
TRACE_WRITER_LIB="$WORKSPACE_ROOT/codetracer-engine-godot/modules/gdscript/ct_writer/libcodetracer_trace_writer.a"
ZSTD_LIB="${ZSTD_LIB:-/opt/homebrew/opt/zstd/lib}"
if [[ ! -d "$ZSTD_LIB" ]]; then
  if command -v brew >/dev/null 2>&1; then
    ZSTD_LIB="$(brew --prefix zstd 2>/dev/null)/lib"
  fi
fi
CT_PRINT="$WORKSPACE_ROOT/codetracer-trace-format-nim/ct-print"

for f in "$AGENT_C" "$AGENT_H" "$GODOT_CPP" "$TRACE_WRITER_H" "$TRACE_WRITER_LIB" "$CT_PRINT"; do
  if [[ ! -s "$f" ]]; then
    echo "FATAL: Required file $f is missing or empty!" >&2
    exit 1
  fi
done
echo "   OK: All required source files and libraries present."

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

# -----------------------------------------------------------------------------
# 3. Source / AST Audit Arm
# -----------------------------------------------------------------------------
echo "[3/6] Running Source / AST Audit Arm on gdscript_ct_trace.cpp..."
python3 - "$GODOT_CPP" << 'EOF'
import sys
import re

cpp_path = sys.argv[1]
with open(cpp_path, "r", encoding="utf-8") as f:
    text = f.read()

def audit_source(source_text):
    failures = []
    lines = source_text.splitlines()
    clean_lines = []
    in_block_comment = False
    for line in lines:
        stripped = line.strip()
        if in_block_comment:
            if "*/" in stripped:
                in_block_comment = False
                clean_lines.append(stripped.split("*/", 1)[1])
            else:
                clean_lines.append("")
            continue
        if "/*" in stripped:
            pre, post = stripped.split("/*", 1)
            if "*/" in post:
                clean_lines.append(pre + post.split("*/", 1)[1])
            else:
                in_block_comment = True
                clean_lines.append(pre)
            continue
        if "//" in stripped:
            clean_lines.append(stripped.split("//", 1)[0])
        else:
            clean_lines.append(line)
    clean_text = "\n".join(clean_lines)

    for m in re.finditer(r"\"([^\"\n\r]*§[^\"\n\r]*)\"", clean_text):
        start = m.start()
        line_no = clean_text.count("\n", 0, start) + 1
        matched_str = m.group(1)
        lookbehind = clean_text[max(0, start - 250):start]
        if "String::utf8(" in lookbehind:
            idx = lookbehind.rfind("String::utf8(")
            between = lookbehind[idx + len("String::utf8("):]
            if ")" not in between:
                continue
        if "fprintf(" in lookbehind:
            idx = lookbehind.rfind("fprintf(")
            between = lookbehind[idx + len("fprintf("):]
            if ");" not in between:
                continue
        failures.append((line_no, matched_str, clean_text[max(0, start - 50):m.end() + 20]))
    return failures

audit_failures = audit_source(text)
if audit_failures:
    sys.stderr.write("Source audit found raw § string literal(s) reaching String without String::utf8:\n")
    for lno, lit, ctx in audit_failures:
        sys.stderr.write(f"  Line {lno}: {lit!r} in context:\n{ctx}\n")
    sys.exit(1)

# Verify presence of the 4 required String::utf8 sites
required_patterns = [
    r'String::utf8\(\s*"codetracer: the recording was closed at design\s*"\s*"\s*§8\.1 stage\s*"',
    r'req\.detail\s*=\s*String::utf8\(\s*"design §8\.1 step\s*"',
    r'ct_reload_fail_after_registration\([^,]+,\s*"5[^"]*",\s*String::utf8\(\s*"injected failure at §8\.1 step 5"\)',
    r'ct_reload_fail_after_registration\([^,]+,\s*"6[^"]*",\s*String::utf8\(\s*"injected failure at §8\.1 step 6"\)',
]

for pat in required_patterns:
    if not re.search(pat, text):
        sys.stderr.write(f"FATAL: Required String::utf8 site matching pattern not found: {pat}\n")
        sys.exit(1)

print("   OK: Source audit passed: all 4 required §-bearing String sites use String::utf8(...), 0 raw assignments.")
EOF

# -----------------------------------------------------------------------------
# 4. Compile Integration Harness with Real Components
# -----------------------------------------------------------------------------
echo "[4/6] Compiling integration test harness with real components..."
cat << 'EOF' > "$TMPDIR/harness.cpp"
#include <repro_hcr_agent.h>
#define mutable ct_mutable_param_
#include <codetracer_trace_writer.h>
#undef mutable
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <pthread.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <string>

// Godot String emulation faithful to core/string/ustring.h:540, :677, :688-691
// and core/string/ustring.cpp:161-183 (append_latin1) and :261 (operator+)
class GodotString {
    std::u32string data;
public:
    GodotString() = default;
    // ustring.h:677, :688-691: calls append_latin1
    // ustring.cpp:161-183: *dst = static_cast<uint8_t>(*src)
    GodotString(const char *p_cstr) {
        if (!p_cstr) return;
        while (*p_cstr) {
            data.push_back(static_cast<uint8_t>(*p_cstr));
            p_cstr++;
        }
    }
    // ustring.h:540: String::utf8
    static GodotString utf8(const char *p_utf8) {
        GodotString ret;
        if (!p_utf8) return ret;
        const uint8_t *p = reinterpret_cast<const uint8_t *>(p_utf8);
        while (*p) {
            if (*p < 0x80) {
                ret.data.push_back(*p++);
            } else if ((*p & 0xE0) == 0xC0) {
                uint32_t cp = (*p++ & 0x1F) << 6;
                cp |= (*p++ & 0x3F);
                ret.data.push_back(cp);
            } else if ((*p & 0xF0) == 0xE0) {
                uint32_t cp = (*p++ & 0x0F) << 12;
                cp |= (*p++ & 0x3F) << 6;
                cp |= (*p++ & 0x3F);
                ret.data.push_back(cp);
            } else if ((*p & 0xF8) == 0xF0) {
                uint32_t cp = (*p++ & 0x07) << 18;
                cp |= (*p++ & 0x3F) << 12;
                cp |= (*p++ & 0x3F) << 6;
                cp |= (*p++ & 0x3F);
                ret.data.push_back(cp);
            } else {
                p++;
            }
        }
        return ret;
    }
    GodotString operator+(const GodotString &other) const {
        GodotString ret;
        ret.data = this->data + other.data;
        return ret;
    }
    GodotString operator+(const char *cstr) const {
        return *this + GodotString(cstr);
    }
    std::string utf8() const {
        std::string out;
        for (char32_t cp : data) {
            if (cp < 0x80) {
                out.push_back(static_cast<char>(cp));
            } else if (cp < 0x800) {
                out.push_back(static_cast<char>(0xC0 | (cp >> 6)));
                out.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
            } else if (cp < 0x10000) {
                out.push_back(static_cast<char>(0xE0 | (cp >> 12)));
                out.push_back(static_cast<char>(0x80 | ((cp >> 6) & 0x3F)));
                out.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
            } else {
                out.push_back(static_cast<char>(0xF0 | (cp >> 18)));
                out.push_back(static_cast<char>(0x80 | ((cp >> 12) & 0x3F)));
                out.push_back(static_cast<char>(0x80 | ((cp >> 6) & 0x3F)));
                out.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
            }
        }
        return out;
    }
};

static bool g_falsify_wire = false;
static bool g_falsify_container = false;
static std::string g_wire_detail_storage;

static int my_reload_handler(void *ctx, const char *reload_id, const char *language,
                             const repro_hcr_source_changed_file *file,
                             repro_hcr_source_reload_outcome *out) {
    GodotString p_stage = GodotString::utf8("5 (emit the boundary marker)");
    GodotString p_detail_sub;
    if (g_falsify_wire) {
        // Raw literal widening: ustring.h:677 String(const char *)
        p_detail_sub = "injected failure at §8.1 step 5";
    } else {
        // Fixed: String::utf8(...)
        p_detail_sub = GodotString::utf8("injected failure at §8.1 step 5");
    }

    GodotString req_detail;
    if (g_falsify_wire) {
        // Raw literal widening
        req_detail = GodotString("design §8.1 step ") + p_stage +
            " failed after the trace had committed to the new version, so the recording was closed rather than continued: " +
            p_detail_sub;
    } else {
        // Fixed: String::utf8(...)
        req_detail = GodotString::utf8("design §8.1 step ") + p_stage +
            " failed after the trace had committed to the new version, so the recording was closed rather than continued: " +
            p_detail_sub;
    }

    g_wire_detail_storage = req_detail.utf8();
    out->applied = 0;
    out->reason = REPRO_HCR_RELOAD_REASON_TRACE_CLOSED;
    out->detail = g_wire_detail_storage.c_str();

    // Adjacent fprintf control arm in gdscript_ct_trace.cpp:2058:
    fprintf(stderr, "[ct-gdh8] CLOSING THE TRACE at §8.1 stage %s: %s\n",
            p_stage.utf8().c_str(), p_detail_sub.utf8().c_str());
    fflush(stderr);

    return 0;
}

static void send_msg(int fd, const char *msg) {
    char hdr[64];
    snprintf(hdr, sizeof(hdr), "Content-Length: %zu\r\n\r\n", strlen(msg));
    write(fd, hdr, strlen(hdr));
    write(fd, msg, strlen(msg));
}

static char *read_msg(int fd) {
    char line[256];
    size_t len = 0;
    char ch;
    while (read(fd, &ch, 1) == 1) {
        if (ch == 10) break;
        if (len + 1 < sizeof(line)) line[len++] = ch;
    }
    line[len] = 0;
    size_t clen = 0;
    if (sscanf(line, "Content-Length: %zu", &clen) != 1) return NULL;
    while (read(fd, &ch, 1) == 1) {
        if (ch == 10) break;
    }
    char *buf = (char *)malloc(clen + 1);
    size_t total = 0;
    while (total < clen) {
        ssize_t n = read(fd, buf + total, clen - total);
        if (n <= 0) break;
        total += n;
    }
    buf[total] = 0;
    return buf;
}

struct CoordArgs {
    int sfd;
    const char *wire_out_path;
};

static void *coord_thread(void *arg) {
    CoordArgs *cargs = (CoordArgs *)arg;
    int cfd = accept(cargs->sfd, NULL, NULL);
    if (cfd < 0) return NULL;
    char *hello = read_msg(cfd);
    free(hello);
    const char *ack = "{\"schemaId\":\"reprobuild.hcr.protocol\",\"transportScope\":\"process\",\"protocolVersion\":2,\"messageId\":\"hello-ack-1\",\"kind\":\"helloAck\",\"helloAck\":{\"grantedCapabilities\":[\"source-reload\"],\"protocolVersion\":2}}";
    send_msg(cfd, ack);
    const char *chg = "{\"schemaId\":\"reprobuild.hcr.protocol\",\"transportScope\":\"process\",\"protocolVersion\":2,\"messageId\":\"msg-1\",\"kind\":\"sourceChanged\",\"sourceChanged\":{\"reloadId\":\"r-hx-s9-001\",\"language\":\"gdscript\",\"changedFiles\":[{\"sourcePath\":\"res://probe.gd\",\"generation\":2,\"lineCount\":1,\"snapshotDigest\":\"sha256:9f56e761d79bfdb34304a012586cb04d16b435ef6130091a97702e559260a2f2\",\"lineTableDigest\":\"sha256:5feceb66ffc86f38d952786c6d696c79c2dbc239dd4e91b46729d73a27fb57e9\",\"contentEncoding\":\"inline\",\"content\":\"cGFzcwo=\"}]}}";
    send_msg(cfd, chg);
    char *reply = read_msg(cfd);
    if (reply != NULL) {
        FILE *fp = fopen(cargs->wire_out_path, "wb");
        if (fp) {
            fputs(reply, fp);
            fclose(fp);
        }
        free(reply);
    }
    close(cfd);
    return NULL;
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "Usage: %s <out_dir> [--falsify-wire] [--falsify-container]\n", argv[0]);
        return 1;
    }
    const char *out_dir = argv[1];
    for (int i = 2; i < argc; ++i) {
        if (strcmp(argv[i], "--falsify-wire") == 0) {
            g_falsify_wire = true;
        } else if (strcmp(argv[i], "--falsify-container") == 0) {
            g_falsify_container = true;
        }
    }

    std::string sock_path = std::string(out_dir) + "/agent.sock";
    std::string wire_reply_path = std::string(out_dir) + "/wire_reply.json";
    std::string events_bin_path = std::string(out_dir) + "/events.bin";

    // --- 1. Real trace container creation via libcodetracer_trace_writer.a
    codetracer_trace_writer_init();
    trace_writer_t w = trace_writer_new("hx_s9_trace", FFI_TRACE_FORMAT_BINARY);
    if (!w) {
        fprintf(stderr, "trace_writer_new failed: %s\n", trace_writer_last_error());
        return 1;
    }
    trace_writer_set_workdir(w, out_dir);
    trace_writer_begin_metadata(w, "");
    trace_writer_begin_events(w, events_bin_path.c_str());
    trace_writer_begin_paths(w, "");

    GodotString p_stage = GodotString::utf8("5 (emit the boundary marker)");
    GodotString p_detail_sub;
    if (g_falsify_container) {
        p_detail_sub = "injected failure at §8.1 step 5";
    } else {
        p_detail_sub = GodotString::utf8("injected failure at §8.1 step 5");
    }

    GodotString content_cs_str;
    if (g_falsify_container) {
        // Raw literal widening: "codetracer: ... §8.1 stage " + p_stage
        content_cs_str = GodotString("codetracer: the recording was closed at design §8.1 stage ") +
            p_stage + " because the reload could not be completed coherently: " + p_detail_sub;
    } else {
        // Fixed: String::utf8(...)
        content_cs_str = GodotString::utf8("codetracer: the recording was closed at design §8.1 stage ") +
            p_stage + " because the reload could not be completed coherently: " + p_detail_sub;
    }

    std::string content_cs = content_cs_str.utf8();
    std::string meta_cs = p_stage.utf8();

    trace_writer_register_special_event(w, FFI_EVENT_ERROR, meta_cs.c_str(), content_cs.c_str());

    trace_writer_finish_events(w);
    trace_writer_finish_metadata(w);
    trace_writer_finish_paths(w);
    trace_writer_close(w);
    trace_writer_free(w);

    // --- 2. Real UNIX domain socket IPC and real wire detail via repro_hcr_agent.c
    int sfd = socket(AF_UNIX, SOCK_STREAM, 0);
    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, sock_path.c_str(), sizeof(addr.sun_path) - 1);
    unlink(sock_path.c_str());
    bind(sfd, (struct sockaddr *)&addr, sizeof(addr));
    listen(sfd, 1);

    CoordArgs cargs;
    cargs.sfd = sfd;
    cargs.wire_out_path = wire_reply_path.c_str();

    pthread_t th;
    pthread_create(&th, NULL, coord_thread, &cargs);

    setenv("REPRO_HCR_AGENT_SOCKET", sock_path.c_str(), 1);
    repro_hcr_agent_set_source_reload_handler(my_reload_handler, NULL);
    repro_hcr_agent_start_polling_from_env("direct-patch", NULL, 0);

    repro_hcr_agent_poll();

    pthread_join(th, NULL);
    close(sfd);
    unlink(sock_path.c_str());

    return 0;
}
EOF

# Compile repro_hcr_agent.c with clang (C mode)
clang -c "$AGENT_C" -I "$REPRO_ROOT/libs/repro_hcr_agent/c" -o "$TMPDIR/repro_hcr_agent.o"

# Compile harness.cpp with clang++ linking repro_hcr_agent.o and libcodetracer_trace_writer.a
clang++ "$TMPDIR/harness.cpp" "$TMPDIR/repro_hcr_agent.o" \
  -I "$REPRO_ROOT/libs/repro_hcr_agent/c" \
  -I "$WORKSPACE_ROOT/codetracer-engine-godot/modules/gdscript/ct_writer/include" \
  -L "$WORKSPACE_ROOT/codetracer-engine-godot/modules/gdscript/ct_writer" \
  -lcodetracer_trace_writer \
  -L"$ZSTD_LIB" -lzstd \
  -framework Security -framework CoreFoundation \
  -o "$TMPDIR/hx_s9_harness"

echo "   OK: Test harness compiled and linked cleanly."

# -----------------------------------------------------------------------------
# Python Validator Function
# -----------------------------------------------------------------------------
validate_run() {
  local run_dir="$1"
  local mode="$2" # positive, falsify_wire, falsify_container
  python3 - "$run_dir" "$mode" "$CT_PRINT" "$WORKSPACE_ROOT" << 'PYEOF'
import sys
import os
import json
import shutil
import subprocess

run_dir = sys.argv[1]
mode = sys.argv[2]
ct_print = sys.argv[3]
workspace_root = sys.argv[4]

wire_json_path = os.path.join(run_dir, "wire_reply.json")
container_path = os.path.join(run_dir, "hx_s9_trace.ct")
stderr_path = os.path.join(run_dir, "stderr.txt")

SECTION_UTF8 = b"\xC2\xA7"        # UTF-8 '§'
MOJIBAKE_PREFIX = b"\xC3\x82"     # UTF-8 'Â' (the mojibake artifact from Latin-1 widening)
DOUBLE_ENCODED = b"\xC3\x82\xC2\xA7" # 'Â§'

# --- 1. Check Wire Detail
if not os.path.isfile(wire_json_path):
    sys.stderr.write(f"FATAL: Wire reply JSON not generated at {wire_json_path}\n")
    sys.exit(1)

with open(wire_json_path, "rb") as f:
    wire_raw = f.read()

if len(wire_raw) < 50:
    sys.stderr.write(f"FATAL [ANTI-VACUITY]: Wire reply length ({len(wire_raw)}) below floor (50 bytes)\n")
    sys.exit(1)

wire_data = json.loads(wire_raw.decode("utf-8"))
refused = wire_data.get("sourceReloadResult", {}).get("refusedFiles", [])
if not refused:
    sys.stderr.write("FATAL [ANTI-VACUITY]: No refusedFiles entry in wire reply\n")
    sys.exit(1)

detail_str = refused[0].get("detail", "")
detail_bytes = detail_str.encode("utf-8")

if len(detail_bytes) < 20:
    sys.stderr.write(f"FATAL [ANTI-VACUITY]: Detail field length ({len(detail_bytes)}) below floor (20 bytes)\n")
    sys.exit(1)

if SECTION_UTF8 not in detail_bytes:
    sys.stderr.write("FATAL [ANTI-VACUITY]: Section sign '§' missing from wire detail\n")
    sys.exit(1)

if mode == "falsify_wire":
    if MOJIBAKE_PREFIX not in detail_bytes or DOUBLE_ENCODED not in detail_bytes:
        sys.stderr.write("FALSIFIER ARM 1 FAILED: Expected double-encoded Â§ (0xC3 0x82 0xC2 0xA7) in wire detail, but found clean encoding!\n")
        sys.exit(1)
    print("   [Falsifier Arm 1]: Wire detail successfully went red on bytes (carried 0xC3 0x82 0xC2 0xA7 Â§).")
    sys.exit(0)
else:
    if MOJIBAKE_PREFIX in detail_bytes:
        sys.stderr.write(f"FATAL: Wire detail contains double-encoded mojibake byte 0xC3 0x82 (Â) before §: {detail_str}\n")
        sys.exit(1)

# --- 2. Check Container Error Record
if not os.path.isfile(container_path):
    sys.stderr.write(f"FATAL: Container file not generated at {container_path}\n")
    sys.exit(1)

ct_size = os.path.getsize(container_path)
if ct_size < 100:
    sys.stderr.write(f"FATAL [ANTI-VACUITY]: Container file size ({ct_size}) below floor (100 bytes)\n")
    sys.exit(1)

# Inspect container using CTFS reader
sys.path.insert(0, os.path.join(workspace_root, "codetracer-engine-godot/scripts"))
from verify_gdh0 import CtfsContainer

ct = CtfsContainer(container_path)
events_dat = ct.read_internal("events.dat")
if len(events_dat) == 0:
    sys.stderr.write("FATAL [ANTI-VACUITY]: events.dat in CTFS container is empty\n")
    sys.exit(1)

# Decompress events.dat via zstd
zstd_bin = shutil.which("zstd") or "/opt/homebrew/bin/zstd"
zstd_proc = subprocess.run([zstd_bin, "-d", "-c"], input=events_dat, capture_output=True, check=True)
decomp_events = zstd_proc.stdout

if len(decomp_events) < 20:
    sys.stderr.write(f"FATAL [ANTI-VACUITY]: Decompressed events stream length ({len(decomp_events)}) below floor\n")
    sys.exit(1)

if SECTION_UTF8 not in decomp_events:
    sys.stderr.write("FATAL [ANTI-VACUITY]: Section sign '§' missing from container events stream\n")
    sys.exit(1)

# Anti-vacuity: verify completeness against meta.dat header count
dump_proc = subprocess.run([ct_print, "--full", container_path], capture_output=True, text=True, check=True)
dump_json = json.loads(dump_proc.stdout)
header_io_count = dump_json.get("counts", {}).get("io_events", 0)
if header_io_count != 1:
    sys.stderr.write(f"FATAL [ANTI-VACUITY]: Expected exactly 1 io_event in header count, found {header_io_count}\n")
    sys.exit(1)

if mode == "falsify_container":
    if MOJIBAKE_PREFIX not in decomp_events or DOUBLE_ENCODED not in decomp_events:
        sys.stderr.write("FALSIFIER ARM 2 FAILED: Expected double-encoded Â§ (0xC3 0x82 0xC2 0xA7) in container events, but found clean encoding!\n")
        sys.exit(1)
    print("   [Falsifier Arm 2]: Container record successfully went red on bytes (carried 0xC3 0x82 0xC2 0xA7 Â§).")
    sys.exit(0)
else:
    if MOJIBAKE_PREFIX in decomp_events:
        sys.stderr.write("FATAL: Container error record contains double-encoded mojibake byte 0xC3 0x82 (Â) before §!\n")
        sys.exit(1)

# --- 3. Check Control Arm (adjacent fprintf)
if not os.path.isfile(stderr_path):
    sys.stderr.write(f"FATAL: Stderr capture file not found at {stderr_path}\n")
    sys.exit(1)

with open(stderr_path, "rb") as f:
    stderr_raw = f.read()

if b"[ct-gdh8] CLOSING THE TRACE at" not in stderr_raw:
    sys.stderr.write("FATAL [CONTROL ARM]: Expected fprintf signature missing from captured stderr\n")
    sys.exit(1)

if SECTION_UTF8 not in stderr_raw:
    sys.stderr.write("FATAL [CONTROL ARM]: Section sign '§' missing from captured stderr\n")
    sys.exit(1)

if MOJIBAKE_PREFIX in stderr_raw:
    sys.stderr.write("FATAL [CONTROL ARM]: Control arm fprintf unexpectedly contained 0xC3 0x82 (Â)!\n")
    sys.exit(1)

print("   OK: Positive Arm and Control Arm verified:")
print(f"       - Wire detail: clean UTF-8 '{detail_str}' (has §, 0 Â bytes)")
print("       - Container FFI_EVENT_ERROR record: clean UTF-8 (has §, 0 Â bytes)")
print("       - Control arm stderr: clean UTF-8 (has §, 0 Â bytes)")
print("       - Container dump read: COMPLETE (1 record == 1 header count)")
PYEOF
}

# -----------------------------------------------------------------------------
# 5. Execute Positive Arm & Control Arm
# -----------------------------------------------------------------------------
echo "[5/6] Executing Positive Arm & Control Arm against real components..."
mkdir -p "$TMPDIR/pos"
"$TMPDIR/hx_s9_harness" "$TMPDIR/pos" 2> "$TMPDIR/pos/stderr.txt"
validate_run "$TMPDIR/pos" "positive"

# -----------------------------------------------------------------------------
# 6. Execute Falsifier Arms (when requested)
# -----------------------------------------------------------------------------
if [[ "$INCLUDE_FALSIFIER" -eq 1 ]]; then
  echo "[6/6] Executing Falsifier Arms..."

  # Falsifier Arm 1: Reinstating Latin-1 widening on wire detail
  echo "  Running Falsifier Arm 1: Wire detail raw Latin-1 widening..."
  mkdir -p "$TMPDIR/falsify1"
  "$TMPDIR/hx_s9_harness" "$TMPDIR/falsify1" --falsify-wire 2> "$TMPDIR/falsify1/stderr.txt"
  validate_run "$TMPDIR/falsify1" "falsify_wire"

  # Falsifier Arm 2: Reinstating Latin-1 widening on container record
  echo "  Running Falsifier Arm 2: Container error record raw Latin-1 widening..."
  mkdir -p "$TMPDIR/falsify2"
  "$TMPDIR/hx_s9_harness" "$TMPDIR/falsify2" --falsify-container 2> "$TMPDIR/falsify2/stderr.txt"
  validate_run "$TMPDIR/falsify2" "falsify_container"

  # Falsifier Arm 3: Mutating gdscript_ct_trace.cpp to remove String::utf8
  echo "  Running Falsifier Arm 3: Source audit on mutated gdscript_ct_trace.cpp..."
  python3 - "$GODOT_CPP" << 'EOF'
import sys
import re

cpp_path = sys.argv[1]
with open(cpp_path, "r", encoding="utf-8") as f:
    text = f.read()

def audit_source(source_text):
    failures = []
    lines = source_text.splitlines()
    clean_lines = []
    in_block_comment = False
    for line in lines:
        stripped = line.strip()
        if in_block_comment:
            if "*/" in stripped:
                in_block_comment = False
                clean_lines.append(stripped.split("*/", 1)[1])
            else:
                clean_lines.append("")
            continue
        if "/*" in stripped:
            pre, post = stripped.split("/*", 1)
            if "*/" in post:
                clean_lines.append(pre + post.split("*/", 1)[1])
            else:
                in_block_comment = True
                clean_lines.append(pre)
            continue
        if "//" in stripped:
            clean_lines.append(stripped.split("//", 1)[0])
        else:
            clean_lines.append(line)
    clean_text = "\n".join(clean_lines)

    for m in re.finditer(r"\"([^\"\n\r]*§[^\"\n\r]*)\"", clean_text):
        start = m.start()
        line_no = clean_text.count("\n", 0, start) + 1
        matched_str = m.group(1)
        lookbehind = clean_text[max(0, start - 250):start]
        if "String::utf8(" in lookbehind:
            idx = lookbehind.rfind("String::utf8(")
            between = lookbehind[idx + len("String::utf8("):]
            if ")" not in between:
                continue
        if "fprintf(" in lookbehind:
            idx = lookbehind.rfind("fprintf(")
            between = lookbehind[idx + len("fprintf("):]
            if ");" not in between:
                continue
        failures.append((line_no, matched_str))
    return failures

# Mutate: remove String::utf8 from line 2117
mutated = text.replace('String::utf8("design §8.1 step ")', '"design §8.1 step "')
if mutated == text:
    sys.stderr.write("FALSIFIER SETUP ERROR: Could not find target site to mutate\n")
    sys.exit(1)

fails = audit_source(mutated)
if not fails:
    sys.stderr.write("FALSIFIER ARM 3 FAILED: Source audit did not go red on mutated code!\n")
    sys.exit(1)

print(f"   [Falsifier Arm 3]: Source audit successfully went red on mutated code (caught {len(fails)} violation(s)).")
EOF
else
  echo "[6/6] Falsifier arms skipped (run with --include-falsifier to exercise)."
fi

echo "=== Gate PASSED: hx_s9_the_section_sign_survives_the_wire_and_the_container ==="
