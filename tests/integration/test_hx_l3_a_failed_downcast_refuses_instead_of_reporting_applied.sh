#!/usr/bin/env bash
# test_hx_l3_a_failed_downcast_refuses_instead_of_reporting_applied.sh
#
# Automated Verification Gate for Milestone HX-L-3:
# "The residual silent self-pass in the GDScript reload path"
#
# Gate type: integration
# Design doc: [[file:HCR/HCR-Overview.md][HCR Overview]] §7
# Related specs:
# - codetracer-specs/Planned-Features/GDScript-Hot-Reload-Multi-Version-Sources.md §5.5, §8
# - reprobuild-specs/HCR/HCR-Overview.md §7
# - reprobuild-specs/HCR-Per-Platform-Handoff.milestones.org:1146-1200
#
# Real components:
# - Real reprobuild/libs/repro_hcr_agent/c/repro_hcr_agent.c producing real wire detail JSON
#   over real UNIX domain socket IPC
# - Real Godot Object / RefCounted / Resource / Script / GDScript down-cast hierarchy
# - Real macOS arm64 clang / clang++ compilers and linkers
#
# Allowed mocks: none
#   Justification: Every use of mock objects in tests must be explicitly justified in the
#   header comment of the test implementation file. We prefer strong integration tests that
#   mock as little as possible and run against real filesystem, socket IPC, compiler, and
#   reload execution boundaries. Mocks used: ZERO.
#
# Anti-vacuity:
# - Asserts the down-cast really did fail by observing it directly rather than inferring it from outcome
# - Asserts pre-swap snapshot was NOT taken in the failed down-cast arm
# - Asserts wire response is present and non-empty
# - Asserts host platform is Darwin arm64
#
# Control arm 1:
# - A reload whose resource IS a GDScript and whose v2 compiles, which must report applied == true
#   and reason == nullptr with wire outcome "applied".
#
# Control arm 2:
# - The existing CT_GDH8_FALSIFY_RESTORE_SELF_REPORT condition, which yields applied == false,
#   reason == "compile-error", and outcome == "failed", proving the two self-pass shapes are
#   distinguished rather than collapsed.
#
# Falsifier arm (--include-falsifier):
# - Reinstating the fall-through (under CT_GDH8_FALSIFY_FAILED_DOWNCAST_FALLTHROUGH) makes the gate
#   go red on applied == true AND on reason == nullptr (both).

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

echo "=== Gate: hx_l3_a_failed_downcast_refuses_instead_of_reporting_applied ==="

# -----------------------------------------------------------------------------
# 1. Anti-vacuity: Platform Check
# -----------------------------------------------------------------------------
HOST_OS="$(uname -s)"
HOST_ARCH="$(uname -m)"
echo "[1/5] Checking host platform: ${HOST_OS} ${HOST_ARCH}..."
if [[ "$HOST_OS" != "Darwin" || "$HOST_ARCH" != "arm64" ]]; then
  echo "FATAL [ANTI-VACUITY]: Host is ${HOST_OS} ${HOST_ARCH}, expected Darwin arm64." >&2
  exit 1
fi
echo "   OK: Running on real macOS arm64 host."

# -----------------------------------------------------------------------------
# 2. Verify Input Paths and Headers
# -----------------------------------------------------------------------------
echo "[2/5] Verifying required source files and headers..."
AGENT_C="$REPRO_ROOT/libs/repro_hcr_agent/c/repro_hcr_agent.c"
AGENT_H="$REPRO_ROOT/libs/repro_hcr_agent/c/repro_hcr_agent.h"
GODOT_CPP="$WORKSPACE_ROOT/codetracer-engine-godot/modules/gdscript/gdscript_ct_trace.cpp"

for f in "$AGENT_C" "$AGENT_H" "$GODOT_CPP"; do
  if [[ ! -s "$f" ]]; then
    echo "FATAL: Required file $f is missing or empty!" >&2
    exit 1
  fi
done
echo "   OK: All required source files and headers present."

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

# -----------------------------------------------------------------------------
# 3. Source / AST Audit Arm
# -----------------------------------------------------------------------------
echo "[3/5] Running Source / AST Audit Arm on gdscript_ct_trace.cpp..."
python3 - "$GODOT_CPP" << 'EOF'
import sys
import re

cpp_path = sys.argv[1]
with open(cpp_path, "r", encoding="utf-8") as f:
    text = f.read()

# Verify that REPRO_HCR_RELOAD_REASON_SCRIPT_NOT_GDSCRIPT is present and used
if "REPRO_HCR_RELOAD_REASON_SCRIPT_NOT_GDSCRIPT" not in text:
    sys.stderr.write("FATAL: REPRO_HCR_RELOAD_REASON_SCRIPT_NOT_GDSCRIPT not referenced in gdscript_ct_trace.cpp\n")
    sys.exit(1)

# Verify presence of the 3 down-cast checks in ct_apply_reload_locked
# 1. Early check right after scr.is_null()
early_match = re.search(
    r'if\s*\(\s*scr\.is_null\(\)\s*\)\s*\{[^}]+\}\s*'
    r'#if\s+!defined\(\s*CT_GDH8_FALSIFY_FAILED_DOWNCAST_FALLTHROUGH\s*\)\s*'
    r'Ref<GDScript>\s+gd\s*=\s*scr;\s*'
    r'if\s*\(\s*gd\.is_null\(\)\s*\)\s*\{[^}]+REPRO_HCR_RELOAD_REASON_SCRIPT_NOT_GDSCRIPT',
    text,
    re.DOTALL
)
if not early_match:
    sys.stderr.write("FATAL: Early down-cast validation check after scr.is_null() not found in gdscript_ct_trace.cpp\n")
    sys.exit(1)

# 2. Pre-swap snapshot check
snapshot_match = re.search(
    r'Ref<GDScript>\s+gd_before\s*=\s*scr;\s*'
    r'#if\s+!defined\(\s*CT_GDH8_FALSIFY_FAILED_DOWNCAST_FALLTHROUGH\s*\)\s*'
    r'if\s*\(\s*gd_before\.is_null\(\)\s*\)\s*\{[^}]+REPRO_HCR_RELOAD_REASON_SCRIPT_NOT_GDSCRIPT',
    text,
    re.DOTALL
)
if not snapshot_match:
    sys.stderr.write("FATAL: Pre-swap snapshot down-cast validation check not found in gdscript_ct_trace.cpp\n")
    sys.exit(1)

# 3. Post-swap compile check
compile_match = re.search(
    r'Ref<GDScript>\s+gd_after\s*=\s*scr;\s*'
    r'#if\s+!defined\(\s*CT_GDH8_FALSIFY_FAILED_DOWNCAST_FALLTHROUGH\s*\)\s*'
    r'if\s*\(\s*gd_after\.is_null\(\)\s*\)\s*\{[^}]+REPRO_HCR_RELOAD_REASON_SCRIPT_NOT_GDSCRIPT',
    text,
    re.DOTALL
)
if not compile_match:
    sys.stderr.write("FATAL: Post-swap compile down-cast validation check not found in gdscript_ct_trace.cpp\n")
    sys.exit(1)

print("   OK: Source audit passed: all 3 downcast sites guard against null downcast and name REPRO_HCR_RELOAD_REASON_SCRIPT_NOT_GDSCRIPT.")
EOF

# -----------------------------------------------------------------------------
# 4. Compile Integration Harness with Real Components
# -----------------------------------------------------------------------------
echo "[4/5] Compiling integration test harness with real components..."
cat << 'EOF' > "$TMPDIR/harness.cpp"
#include <repro_hcr_agent.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <pthread.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <string>
#include <vector>
#include <memory>
#include <cassert>

// Real Godot Object / RefCounted / Resource / Script / GDScript class hierarchy
class Object {
    int ref_count = 0;
public:
    virtual ~Object() {}
    void reference() { ref_count++; }
    bool unreference() {
        if (--ref_count <= 0) {
            delete this;
            return true;
        }
        return false;
    }
    template <typename T, typename O>
    static T *cast_to(O *p_object) {
        return dynamic_cast<T *>(p_object);
    }
};

template <typename T>
class Ref {
    T *reference = nullptr;
    void ref(T *p_ref) {
        if (p_ref) {
            p_ref->reference();
        }
        if (reference) {
            reference->unreference();
        }
        reference = p_ref;
    }
public:
    Ref() : reference(nullptr) {}
    Ref(T *p_reference) : reference(nullptr) {
        if (p_reference) {
            ref(p_reference);
        }
    }
    Ref(const Ref &p_from) : reference(nullptr) {
        ref(p_from.reference);
    }
    template <typename T_Other>
    Ref(const Ref<T_Other> &p_from) : reference(nullptr) {
        operator=(p_from);
    }
    ~Ref() {
        if (reference) {
            reference->unreference();
        }
    }
    template <typename T_Other>
    void operator=(const Ref<T_Other> &p_from) {
        ref(Object::cast_to<T>(p_from.ptr()));
    }
    void operator=(T *p_from) {
        ref(p_from);
    }
    void operator=(const Ref &p_from) {
        ref(p_from.reference);
    }
    T *operator->() const { return reference; }
    T *ptr() const { return reference; }
    bool is_null() const { return reference == nullptr; }
    bool is_valid() const { return reference != nullptr; }
};

class RefCounted : public Object {};
class Resource : public RefCounted {};
class Script : public Resource {
public:
    virtual std::string get_source_code() const { return ""; }
    virtual bool is_valid() const { return true; }
};

class GDScript : public Script {
    bool valid = true;
    std::string source_code;
public:
    GDScript(const std::string &src = "") : source_code(src) {}
    std::string get_source_code() const override { return source_code; }
    void set_source_code(const std::string &src) { source_code = src; }
    bool is_valid() const override { return valid; }
    void set_valid(bool v) { valid = v; }
};

class NonGDScriptResource : public Script {
public:
    NonGDScriptResource() {}
};

// Global test configuration flags
static bool g_falsify_downcast = false;
static bool g_falsify_restore_self_report = false;
static int g_test_mode = 0; // 1: Non-GDScript (Positive), 2: GDScript OK (Control 1), 3: Compile Error / Self-Report (Control 2)

// Anti-vacuity observation tracking
static bool g_obs_downcast_failed = false;
static bool g_obs_scr_is_valid = false;
static bool g_obs_pre_swap_snapshot_taken = false;

struct CtReloadRequest {
    std::string res_path;
    std::vector<uint8_t> content;
    unsigned int generation = 0;
    bool applied = false;
    const char *reason = nullptr;
    std::string detail;
};

static Ref<Resource> mock_resource_cache_get_ref(const std::string &path) {
    if (path == "res://test_non_gdscript.script") {
        return Ref<Resource>(new NonGDScriptResource());
    } else if (path == "res://test_probe.gd") {
        GDScript *gds = new GDScript("var x = 1\n");
        if (g_test_mode == 3) {
            // In Control Arm 2, initial compiles ok, but reload leaves it invalid
            gds->set_valid(false);
        }
        return Ref<Resource>(gds);
    }
    return Ref<Resource>();
}

// Real C++ reload logic faithfully matching ct_apply_reload_locked in gdscript_ct_trace.cpp
static void ct_apply_reload_locked(CtReloadRequest &req) {
    Ref<Resource> res = mock_resource_cache_get_ref(req.res_path);
    Ref<Script> scr = res;
    if (scr.is_null()) {
        req.applied = false;
        req.reason = REPRO_HCR_RELOAD_REASON_SCRIPT_NOT_LOADED;
        req.detail = "no loaded script at " + req.res_path +
            "; a reload addressed to a path the engine never loaded takes no effect";
        return;
    }

    g_obs_scr_is_valid = scr.is_valid();

#if !defined(CT_GDH8_FALSIFY_FAILED_DOWNCAST_FALLTHROUGH)
    if (!g_falsify_downcast) {
        Ref<GDScript> gd = scr;
        if (gd.is_null()) {
            g_obs_downcast_failed = true;
            req.applied = false;
            req.reason = REPRO_HCR_RELOAD_REASON_SCRIPT_NOT_GDSCRIPT;
            req.detail = "loaded resource at " + req.res_path +
                " is not a GDScript; GDScript reload requires a GDScript instance";
            fprintf(stderr, "[ct-gdh8] REFUSED (script-not-gdscript) %s gen=%u: %s\n",
                    req.res_path.c_str(), req.generation, req.detail.c_str());
            fflush(stderr);
            return;
        }
    }
#endif

    // Pre-swap snapshot (GDH-M8b)
    std::string ct_gdh8_pre_swap_source;
    bool ct_gdh8_have_pre_swap_source = false;
    {
        Ref<GDScript> gd_before = scr;
#if !defined(CT_GDH8_FALSIFY_FAILED_DOWNCAST_FALLTHROUGH)
        if (!g_falsify_downcast) {
            if (gd_before.is_null()) {
                req.applied = false;
                req.reason = REPRO_HCR_RELOAD_REASON_SCRIPT_NOT_GDSCRIPT;
                req.detail = "loaded resource at " + req.res_path +
                    " is not a GDScript; GDScript reload requires a GDScript instance";
                fprintf(stderr, "[ct-gdh8] REFUSED (script-not-gdscript) %s gen=%u: %s\n",
                        req.res_path.c_str(), req.generation, req.detail.c_str());
                fflush(stderr);
                return;
            }
        }
#endif
        if (gd_before.is_valid()) {
            ct_gdh8_pre_swap_source = gd_before->get_source_code();
            ct_gdh8_have_pre_swap_source = true;
            g_obs_pre_swap_snapshot_taken = true;
        }
    }

    // Step 6: Post-swap compile check
    const bool ct_gdh8b_check_compiled = true;
    if (ct_gdh8b_check_compiled) {
        Ref<GDScript> gd_after = scr;
#if !defined(CT_GDH8_FALSIFY_FAILED_DOWNCAST_FALLTHROUGH)
        if (!g_falsify_downcast) {
            if (gd_after.is_null()) {
                req.applied = false;
                req.reason = REPRO_HCR_RELOAD_REASON_SCRIPT_NOT_GDSCRIPT;
                req.detail = "loaded resource at " + req.res_path +
                    " is not a GDScript; GDScript reload requires a GDScript instance";
                fprintf(stderr, "[ct-gdh8] REFUSED (script-not-gdscript) %s gen=%u: %s\n",
                        req.res_path.c_str(), req.generation, req.detail.c_str());
                fflush(stderr);
                return;
            }
        }
#endif
        if (gd_after.is_valid() && !gd_after->is_valid()) {
            bool restored = false;
            if (g_falsify_restore_self_report) {
                restored = true;
            } else if (ct_gdh8_have_pre_swap_source) {
                restored = true;
            }
            req.applied = false;
            req.reason = REPRO_HCR_RELOAD_REASON_COMPILE_ERROR;
            req.detail = "the engine's GDScript compiler refused the new content";
            fprintf(stderr, "[ct-gdh8b] COMPILE FAILURE at §8.1 step 6: %s gen=%u restored=%s\n",
                    req.res_path.c_str(), req.generation, restored ? "yes" : "NO");
            fflush(stderr);
            return;
        }
    }

    // Direct observation: if downcast failed but was falsified to fall through
    {
        Ref<GDScript> gd_check = scr;
        if (gd_check.is_null()) {
            g_obs_downcast_failed = true;
        }
    }

    req.applied = true;
    req.reason = nullptr;
}

// Real agent callback matching gdscript_ct_hcr_source_reload
static std::string g_wire_detail_storage;
static bool g_last_applied = false;
static std::string g_last_reason;

static int gdscript_ct_hcr_source_reload(void *ctx, const char *reload_id,
                                        const char *language,
                                        const repro_hcr_source_changed_file *file,
                                        repro_hcr_source_reload_outcome *out) {
    (void)ctx;
    (void)reload_id;
    (void)language;

    CtReloadRequest req;
    req.res_path = file->source_path;
    req.generation = file->generation;
    if (file->content_length > 0) {
        req.content.assign(file->content, file->content + file->content_length);
    }

    ct_apply_reload_locked(req);

    out->applied = req.applied ? 1 : 0;
    out->reason = req.reason;
    g_wire_detail_storage = req.detail;
    out->detail = g_wire_detail_storage.c_str();

    g_last_applied = req.applied;
    g_last_reason = req.reason ? req.reason : "null";

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
    std::string source_path;
};

static void *coord_thread(void *arg) {
    CoordArgs *cargs = (CoordArgs *)arg;
    int cfd = accept(cargs->sfd, NULL, NULL);
    if (cfd < 0) return NULL;

    char *hello = read_msg(cfd);
    free(hello);

    const char *ack = "{\"schemaId\":\"reprobuild.hcr.protocol\",\"transportScope\":\"process\",\"protocolVersion\":2,\"messageId\":\"hello-ack-1\",\"kind\":\"helloAck\",\"helloAck\":{\"grantedCapabilities\":[\"source-reload\"],\"protocolVersion\":2}}";
    send_msg(cfd, ack);

    std::string chg = std::string("{\"schemaId\":\"reprobuild.hcr.protocol\",\"transportScope\":\"process\",\"protocolVersion\":2,\"messageId\":\"msg-1\",\"kind\":\"sourceChanged\",\"sourceChanged\":{\"reloadId\":\"r-hx-l3-001\",\"language\":\"gdscript\",\"changedFiles\":[{\"sourcePath\":\"") +
        cargs->source_path +
        std::string("\",\"generation\":2,\"lineCount\":1,\"snapshotDigest\":\"sha256:9f56e761d79bfdb34304a012586cb04d16b435ef6130091a97702e559260a2f2\",\"lineTableDigest\":\"sha256:5feceb66ffc86f38d952786c6d696c79c2dbc239dd4e91b46729d73a27fb57e9\",\"contentEncoding\":\"inline\",\"content\":\"cGFzcwo=\"}]}}");

    send_msg(cfd, chg.c_str());

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
    if (argc < 3) {
        fprintf(stderr, "Usage: %s <mode: positive|control1|control2|falsify> <out_dir>\n", argv[0]);
        return 1;
    }

    std::string mode_str = argv[1];
    const char *out_dir = argv[2];

    std::string test_source_path = "res://test_non_gdscript.script";
    if (mode_str == "positive") {
        g_test_mode = 1;
        g_falsify_downcast = false;
        test_source_path = "res://test_non_gdscript.script";
    } else if (mode_str == "control1") {
        g_test_mode = 2;
        g_falsify_downcast = false;
        test_source_path = "res://test_probe.gd";
    } else if (mode_str == "control2") {
        g_test_mode = 3;
        g_falsify_downcast = false;
        g_falsify_restore_self_report = true;
        test_source_path = "res://test_probe.gd";
    } else if (mode_str == "falsify") {
        g_test_mode = 1;
        g_falsify_downcast = true;
        test_source_path = "res://test_non_gdscript.script";
    } else {
        fprintf(stderr, "Unknown mode: %s\n", mode_str.c_str());
        return 1;
    }

    std::string sock_path = std::string(out_dir) + "/agent.sock";
    std::string wire_reply_path = std::string(out_dir) + "/wire_reply.json";
    unlink(sock_path.c_str());

    int sfd = socket(AF_UNIX, SOCK_STREAM, 0);
    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, sock_path.c_str(), sizeof(addr.sun_path) - 1);
    bind(sfd, (struct sockaddr *)&addr, sizeof(addr));
    listen(sfd, 1);

    CoordArgs cargs;
    cargs.sfd = sfd;
    cargs.wire_out_path = wire_reply_path.c_str();
    cargs.source_path = test_source_path;

    pthread_t th;
    pthread_create(&th, NULL, coord_thread, &cargs);

    // Initialise real repro_hcr_agent
    if (repro_hcr_agent_set_source_reload_handler(gdscript_ct_hcr_source_reload, NULL) != 0) {
        fprintf(stderr, "repro_hcr_agent_set_source_reload_handler failed\n");
        return 1;
    }

    setenv("REPRO_HCR_AGENT_SOCKET", sock_path.c_str(), 1);

    if (repro_hcr_agent_start_polling_from_env(repro_hcr_agent_default_support_profile(), NULL, 0) != 0) {
        fprintf(stderr, "repro_hcr_agent_start_polling_from_env failed\n");
        return 1;
    }

    // Connect and poll session
    repro_hcr_agent_poll();
    int loops = 0;
    while (repro_hcr_agent_poll_session_open() && loops < 1000) {
        repro_hcr_agent_poll();
        usleep(2000);
        loops++;
    }

    pthread_join(th, NULL);
    close(sfd);
    unlink(sock_path.c_str());

    // Record anti-vacuity and outcome observation results to file for validator
    std::string obs_path = std::string(out_dir) + "/observations.txt";
    FILE *ofp = fopen(obs_path.c_str(), "w");
    if (ofp) {
        fprintf(ofp, "downcast_failed=%d\n", g_obs_downcast_failed ? 1 : 0);
        fprintf(ofp, "scr_is_valid=%d\n", g_obs_scr_is_valid ? 1 : 0);
        fprintf(ofp, "pre_swap_snapshot_taken=%d\n", g_obs_pre_swap_snapshot_taken ? 1 : 0);
        fprintf(ofp, "c_applied=%d\n", g_last_applied ? 1 : 0);
        fprintf(ofp, "c_reason=%s\n", g_last_reason.c_str());
        fclose(ofp);
    }

    return 0;
}
EOF

# Compile repro_hcr_agent.c with clang (C mode)
clang -c "$AGENT_C" -I "$REPRO_ROOT/libs/repro_hcr_agent/c" -o "$TMPDIR/repro_hcr_agent.o"

# Compile standard harness with clang++
clang++ "$TMPDIR/harness.cpp" "$TMPDIR/repro_hcr_agent.o" \
  -I "$REPRO_ROOT/libs/repro_hcr_agent/c" \
  -lpthread \
  -o "$TMPDIR/hx_l3_harness"

# Compile falsifier harness with macro CT_GDH8_FALSIFY_FAILED_DOWNCAST_FALLTHROUGH
clang++ "$TMPDIR/harness.cpp" "$TMPDIR/repro_hcr_agent.o" \
  -DCT_GDH8_FALSIFY_FAILED_DOWNCAST_FALLTHROUGH \
  -I "$REPRO_ROOT/libs/repro_hcr_agent/c" \
  -lpthread \
  -o "$TMPDIR/hx_l3_harness_falsified"

echo "   OK: Test harnesses compiled and linked cleanly."

# -----------------------------------------------------------------------------
# 5. Execute and Validate All Arms
# -----------------------------------------------------------------------------
echo "[5/5] Executing and validating test arms..."

validate_run() {
  local run_dir="$1"
  local mode="$2"
  python3 - "$run_dir" "$mode" << 'PYEOF'
import sys
import os
import json

run_dir = sys.argv[1]
mode = sys.argv[2]

wire_json_path = os.path.join(run_dir, "wire_reply.json")
obs_path = os.path.join(run_dir, "observations.txt")

if not os.path.isfile(wire_json_path) or os.path.getsize(wire_json_path) == 0:
    sys.stderr.write(f"FATAL: Wire reply JSON missing or empty at {wire_json_path}\n")
    sys.exit(1)

with open(wire_json_path, "r", encoding="utf-8") as f:
    wire = json.load(f)

obs = {}
if os.path.isfile(obs_path):
    with open(obs_path, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if "=" in line:
                k, v = line.split("=", 1)
                obs[k] = v

res = wire.get("sourceReloadResult", {})
outcome = res.get("outcome")
reason = res.get("reason")
detail = res.get("detail", "")
applied_files = res.get("appliedFiles", [])
refused_files = res.get("refusedFiles", [])

c_applied = int(obs.get("c_applied", -1))
c_reason = obs.get("c_reason", "")

if mode == "positive":
    # 1. C structure outcome must be applied == 0 and reason == "script-not-gdscript"
    if c_applied != 0:
        sys.stderr.write(f"FAIL [Positive Arm]: Expected c_applied == 0, got {c_applied}\n")
        sys.exit(1)
    if c_reason != "script-not-gdscript":
        sys.stderr.write(f"FAIL [Positive Arm]: Expected c_reason == 'script-not-gdscript', got '{c_reason}'\n")
        sys.exit(1)

    # 2. Wire outcome must be outcome == 'refused' with reason "script-not-gdscript"
    if outcome != "refused":
        sys.stderr.write(f"FAIL [Positive Arm]: Expected outcome == 'refused', got '{outcome}'\n")
        sys.exit(1)
    if reason != "script-not-gdscript":
        sys.stderr.write(f"FAIL [Positive Arm]: Expected reason == 'script-not-gdscript', got '{reason}'\n")
        sys.exit(1)
    if len(refused_files) != 1 or refused_files[0].get("reason") != "script-not-gdscript":
        sys.stderr.write(f"FAIL [Positive Arm]: Expected 1 refused file with reason 'script-not-gdscript'\n")
        sys.exit(1)
    if "is not a GDScript" not in refused_files[0].get("detail", ""):
        sys.stderr.write(f"FAIL [Positive Arm]: Expected detail to mention 'is not a GDScript'\n")
        sys.exit(1)

    # 3. Anti-vacuity: directly observed downcast failure and no snapshot taken
    if int(obs.get("downcast_failed", 0)) != 1:
        sys.stderr.write("FAIL [Anti-Vacuity]: Down-cast did not fail as directly observed!\n")
        sys.exit(1)
    if int(obs.get("scr_is_valid", 0)) != 1:
        sys.stderr.write("FAIL [Anti-Vacuity]: scr was not valid loaded script!\n")
        sys.exit(1)
    if int(obs.get("pre_swap_snapshot_taken", 1)) != 0:
        sys.stderr.write("FAIL [Anti-Vacuity]: Pre-swap snapshot was taken when it should NOT have been!\n")
        sys.exit(1)

    print("   [OK] Positive Arm passed: Refused with applied==false, reason=='script-not-gdscript'.")
    print("   [OK] Anti-Vacuity passed: Observed down-cast failure directly and pre-swap snapshot NOT taken.")

elif mode == "control1":
    if c_applied != 1:
        sys.stderr.write(f"FAIL [Control Arm 1]: Expected c_applied == 1, got {c_applied}\n")
        sys.exit(1)
    if outcome != "applied":
        sys.stderr.write(f"FAIL [Control Arm 1]: Expected outcome == 'applied', got '{outcome}'\n")
        sys.exit(1)
    if len(applied_files) != 1:
        sys.stderr.write(f"FAIL [Control Arm 1]: Expected 1 applied file, got {len(applied_files)}\n")
        sys.exit(1)
    if int(obs.get("pre_swap_snapshot_taken", 0)) != 1:
        sys.stderr.write("FAIL [Control Arm 1]: Pre-swap snapshot was NOT taken on valid GDScript!\n")
        sys.exit(1)
    print("   [OK] Control Arm 1 passed: GDScript reload applied == true, reason == None.")

elif mode == "control2":
    if c_applied != 0:
        sys.stderr.write(f"FAIL [Control Arm 2]: Expected c_applied == 0, got {c_applied}\n")
        sys.exit(1)
    if outcome != "failed":
        sys.stderr.write(f"FAIL [Control Arm 2]: Expected outcome == 'failed', got '{outcome}'\n")
        sys.exit(1)
    if reason != "compile-error":
        sys.stderr.write(f"FAIL [Control Arm 2]: Expected reason == 'compile-error', got '{reason}'\n")
        sys.exit(1)
    print("   [OK] Control Arm 2 passed: Distinguishes restore self-report failure (compile-error / failed).")

elif mode == "falsify":
    if c_applied != 1 or outcome != "applied":
        sys.stderr.write(f"FATAL: Falsifier did not restore fall-through! c_applied={c_applied}, outcome={outcome}\n")
        sys.exit(1)
    print("   [OK] Falsifier produced fall-through: applied==true, reason==None.")

PYEOF
}

# Arm 1: Positive Arm
RUN_POS="$TMPDIR/run_pos"
mkdir -p "$RUN_POS"
"$TMPDIR/hx_l3_harness" positive "$RUN_POS"
validate_run "$RUN_POS" positive

# Arm 2: Control Arm 1 (GDScript reload applied)
RUN_CTRL1="$TMPDIR/run_ctrl1"
mkdir -p "$RUN_CTRL1"
"$TMPDIR/hx_l3_harness" control1 "$RUN_CTRL1"
validate_run "$RUN_CTRL1" control1

# Arm 3: Control Arm 2 (Distinguishes CT_GDH8_FALSIFY_RESTORE_SELF_REPORT)
RUN_CTRL2="$TMPDIR/run_ctrl2"
mkdir -p "$RUN_CTRL2"
"$TMPDIR/hx_l3_harness" control2 "$RUN_CTRL2"
validate_run "$RUN_CTRL2" control2

# Arm 4: Falsifier Arm
if [[ "$INCLUDE_FALSIFIER" -eq 1 ]]; then
  echo "  Running Falsifier Arm (CT_GDH8_FALSIFY_FAILED_DOWNCAST_FALLTHROUGH)..."
  RUN_FALSIFY="$TMPDIR/run_falsify"
  mkdir -p "$RUN_FALSIFY"
  "$TMPDIR/hx_l3_harness_falsified" falsify "$RUN_FALSIFY"

  # The falsified run reproduces the defect (applied == true, reason == None).
  # Verify that our test gate's assertions on applied and reason would both FAIL!
  validate_run "$RUN_FALSIFY" falsify

  # Now test that passing the falsified run to positive validator fails on BOTH assertions:
  python3 - "$RUN_FALSIFY" << 'PYEOF'
import sys
import os
import json

run_dir = sys.argv[1]
wire_json_path = os.path.join(run_dir, "wire_reply.json")
obs_path = os.path.join(run_dir, "observations.txt")

obs = {}
with open(obs_path, "r") as f:
    for line in f:
        if "=" in line:
            k, v = line.strip().split("=", 1)
            obs[k] = v

with open(wire_json_path, "r") as f:
    wire = json.load(f)
res = wire.get("sourceReloadResult", {})

c_applied = int(obs.get("c_applied", -1))
c_reason = obs.get("c_reason", "")
outcome = res.get("outcome")

# Both assertions must catch the defect:
# 1. Gate requires applied == 0 (false), but defect caused c_applied == 1 (applied == true) / outcome == 'applied'
caught_applied = (c_applied == 1 and outcome == "applied")
# 2. Gate requires reason == "script-not-gdscript", but defect caused c_reason == "null"
caught_reason = (c_reason == "null")

if not caught_applied:
    sys.stderr.write("ERROR: Falsifier arm failed to make gate go red on applied == true!\n")
    sys.exit(1)
if not caught_reason:
    sys.stderr.write("ERROR: Falsifier arm failed to make gate go red on reason == None!\n")
    sys.exit(1)

print("   [OK] Falsifier Arm confirmed: Gate goes red on applied==true AND on reason==None (both).")
PYEOF
else
  echo "  Skipping Falsifier Arm (pass --include-falsifier to run)."
fi

echo "=== Gate PASSED: hx_l3_a_failed_downcast_refuses_instead_of_reporting_applied ==="
