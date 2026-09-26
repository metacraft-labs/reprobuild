#!/usr/bin/env bash
# test_hax_m2_macho_lazy_symbol_and_vtable_interception.sh
#
# Automated Integration Verification Gate for Milestone HAX-M2:
# "Dispatch Table and Stub Interception"
#
# Design doc: reprobuild-specs/HCR/Dispatch-Table-Patching.md §1–§5
#             reprobuild-specs/HCR/Trampoline-Mechanics.md §7
# Related milestones:
# - reprobuild-specs/HCR-Advanced-Lifecycle-And-Tooling.milestones.org (HAX-M2)
#
# Gate type: e2e / integration
# Real components:
# - Real polymorphic C++ shared library with Itanium C++ ABI virtual method tables
# - Real imported dynamic C library call resolved through Mach-O __la_symbol_ptr
# - Real memory protection transitions (vm_protect with VM_PROT_COPY / mprotect)
# - Real transactional rollback log and atomic pointer updates
# - Real compiler toolchains (clang++, clang, nim)
#
# Allowed mocks: none
# Justification: Every use of mock objects in tests must be explicitly justified in the
# header comment of the test implementation file. We prefer strong integration tests that
# mock as little as possible and run against real filesystem, compiler, binary, and
# lifecycle execution boundaries. Mocks used: ZERO.
#
# Asserts:
# 1. Anti-vacuity arm: Initial calls invoke original virtual and non-virtual implementations;
#    verify calls dispatch through vtable.
# 2. Vtable Interception arm: Virtual method slot rewritten to point to replacement function;
#    calling shape->area() on existing and new instances executes replacement method
#    without modifying __TEXT.
# 3. Control arm: Non-virtual calls (shape->identity()) and unmodified virtual slots
#    (shape->perimeter(), rectangle->area()) continue executing original code.
# 4. Mach-O Lazy Symbol Pointer Interception arm: __la_symbol_ptr rewritten for external_metric_calc;
#    invocation from library executes replacement function.
# 5. Transactional Rollback arm: Rollback reverses all redirections; subsequent calls
#    return baseline results.
# 6. Falsifier arm (--falsify-wrong-slot): Deliberately overwrites wrong vtable slot index,
#    causing unexpected dispatch or trapping, caught by FALSIFIER-CAUGHT.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WORK_DIR="${TEST_WORK_DIR:-$(mktemp -d /tmp/hax_m2_gate_XXXXXX)}"

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

cleanup() {
  if [[ -z "${PRESERVE_WORK:-}" ]]; then
    rm -rf "$WORK_DIR"
  fi
}
trap cleanup EXIT

echo "=== Gate: test_hax_m2_macho_lazy_symbol_and_vtable_interception ==="
echo "Working directory: $WORK_DIR"

# -----------------------------------------------------------------------------
# 1. Verify compiler prerequisites
# -----------------------------------------------------------------------------
echo "[1/5] Checking compiler prerequisites..."
cd "$REPO_ROOT"

if ! command -v clang++ >/dev/null 2>&1; then
  echo "ERROR: clang++ compiler is required but not found in PATH" >&2
  exit 1
fi
if ! command -v clang >/dev/null 2>&1; then
  echo "ERROR: clang compiler is required but not found in PATH" >&2
  exit 1
fi
if ! command -v nim >/dev/null 2>&1; then
  echo "ERROR: nim compiler is required but not found in PATH" >&2
  exit 1
fi
echo "  [OK] Compilers available: clang++, clang, nim."

# -----------------------------------------------------------------------------
# 2. Compile real dynamic C metric library and C++ polymorphic shared library
# -----------------------------------------------------------------------------
echo "[2/5] Compiling real dynamic libraries with clang and clang++..."

METRIC_C="$WORK_DIR/metric.c"
cat << 'EOF' > "$METRIC_C"
#include <stdint.h>

int external_metric_calc(int x) {
    return x * 10;
}
EOF

METRIC_DYLIB="$WORK_DIR/libmetric.dylib"
clang -dynamiclib -fPIC -O2 "$METRIC_C" -o "$METRIC_DYLIB"
echo "  [OK] Metric dynamic library compiled: $METRIC_DYLIB"

SHAPE_CPP="$WORK_DIR/shape.cpp"
cat << 'EOF' > "$SHAPE_CPP"
#include <cstdint>
#include <cstring>

extern "C" int external_metric_calc(int x);

class Shape {
public:
    virtual int area() = 0;
    virtual int perimeter() = 0;
    virtual const char* describe() = 0;
    virtual ~Shape();
    int identity();
};

Shape::~Shape() {}
int Shape::identity() { return 42; }

class Circle : public Shape {
    int radius;
public:
    Circle(int r);
    ~Circle() override;
    int area() override;
    int perimeter() override;
    const char* describe() override;
};

Circle::Circle(int r) : radius(r) {}
Circle::~Circle() {}
int Circle::area() { return 314 * radius * radius / 100; }
int Circle::perimeter() { return 628 * radius / 100; }
const char* Circle::describe() { return "Circle"; }

class Rectangle : public Shape {
    int width, height;
public:
    Rectangle(int w, int h);
    ~Rectangle() override;
    int area() override;
    int perimeter() override;
    const char* describe() override;
};

Rectangle::Rectangle(int w, int h) : width(w), height(h) {}
Rectangle::~Rectangle() {}
int Rectangle::area() { return width * height; }
int Rectangle::perimeter() { return 2 * (width + height); }
const char* Rectangle::describe() { return "Rectangle"; }

extern "C" {
    Shape* create_circle(int r) { return new Circle(r); }
    Shape* create_rectangle(int w, int h) { return new Rectangle(w, h); }
    void destroy_shape(Shape *s) { delete s; }

    int call_shape_area(Shape *s) { return s->area(); }
    int call_shape_perimeter(Shape *s) { return s->perimeter(); }
    const char* call_shape_describe(Shape *s) { return s->describe(); }
    int call_shape_identity(Shape *s) { return s->identity(); }
    int call_shape_metric(Shape *s) { return external_metric_calc(s->area()); }

    void read_text_bytes(const void *func_ptr, uint8_t *out_buf, size_t count) {
        memcpy(out_buf, func_ptr, count);
    }
}
EOF

SHAPE_DYLIB="$WORK_DIR/libshape.dylib"
clang++ -dynamiclib -fPIC -O2 \
  -undefined dynamic_lookup \
  "$SHAPE_CPP" \
  -L"$WORK_DIR" -lmetric \
  -o "$SHAPE_DYLIB"

echo "  [OK] Polymorphic shape shared library compiled: $SHAPE_DYLIB"

# -----------------------------------------------------------------------------
# 3. Build the Nim integration test driver
# -----------------------------------------------------------------------------
echo "[3/5] Compiling Nim integration test driver..."

DRIVER_SRC="$REPO_ROOT/tests/fixtures/hcr/dispatch_table_driver.nim"
DRIVER_BIN="$WORK_DIR/test_hax_m2_driver"

nim c --hints:off --warnings:off \
  --nimcache:"$WORK_DIR/nimcache" \
  --path:"$REPO_ROOT/libs/repro_hcr_agent/src" \
  -o:"$DRIVER_BIN" \
  "$DRIVER_SRC"

echo "  [OK] Test driver compiled: $DRIVER_BIN"

# -----------------------------------------------------------------------------
# 4. Execute test driver: Anti-vacuity, Vtable, Control, Mach-O, Rollback arms
# -----------------------------------------------------------------------------
echo "[4/5] Running test driver (Anti-vacuity, Vtable Interception, Control, Mach-O, Rollback)..."

"$DRIVER_BIN" "$METRIC_DYLIB" "$SHAPE_DYLIB"

echo "  [OK] All test driver verification arms passed."

# -----------------------------------------------------------------------------
# 5. Falsifiers
# -----------------------------------------------------------------------------
if [[ $INCLUDE_FALSIFIER -eq 1 ]]; then
  echo "[5/5] Executing falsifier arm..."
  echo "  Testing Falsifier: Simulating wrong vtable slot index rewrite (--falsify-wrong-slot)..."

  set +e
  "$DRIVER_BIN" --falsify-wrong-slot "$METRIC_DYLIB" "$SHAPE_DYLIB" > "$WORK_DIR/falsifier.log" 2>&1
  FALSIFIER_RC=$?
  set -e

  if [[ $FALSIFIER_RC -eq 0 ]]; then
    echo "ERROR: Falsifier unexpectedly succeeded!" >&2
    cat "$WORK_DIR/falsifier.log" >&2
    exit 1
  fi

  if ! grep -q "FALSIFIER-CAUGHT" "$WORK_DIR/falsifier.log"; then
    echo "ERROR: Falsifier did not emit expected FALSIFIER-CAUGHT diagnostic!" >&2
    cat "$WORK_DIR/falsifier.log" >&2
    exit 1
  fi
  echo "  [OK] Falsifier caught: $(grep "FALSIFIER-CAUGHT" "$WORK_DIR/falsifier.log")"
else
  echo "[5/5] Falsifier execution skipped (pass --include-falsifier to enable)."
fi

echo ""
echo "=== Gate PASSED: test_hax_m2_macho_lazy_symbol_and_vtable_interception ==="
