/* MSVC pedantically deprecates `fopen` / `strerror` / `strcpy` despite
 * their being portable C99. The launcher's hot path is Linux; the
 * Windows compile is a no-op stub so the secure-CRT alternatives are
 * Windows-only churn for no security benefit. Define is a no-op on
 * clang/gcc. */
#define _CRT_SECURE_NO_WARNINGS

/*
 * reprobuild-sandbox-launcher
 * ===========================
 *
 * C3: small native launcher that reads a runtime bind-mount manifest,
 * sets up a user + mount namespace, performs the bind mounts, then
 * execve()s the wrapped target binary.
 *
 * Language choice (C): tracker for C3 P1 deliverable.
 *
 *   * No extra toolchain (libc + Linux kernel headers only).
 *   * No allocator-runtime overhead -- the launcher's whole job is
 *     ``unshare/mount/execve`` and we want sub-100 ms wall clock.
 *   * Single static binary; ships under the package prefix without
 *     dragging in a Rust or Nim runtime.
 *
 * Manifest format (see ``MANIFEST-FORMAT.md`` next to this file)
 * --------------------------------------------------------------
 *
 *   Lines are UTF-8. Comments start with ``#``. Blank lines ignored.
 *   Each non-empty/non-comment line is one of:
 *
 *     <source>:<target>:<flags>
 *
 *   ``flags`` is a comma-separated set; currently supported:
 *
 *     ``bind``      MS_BIND
 *     ``rbind``     MS_BIND | MS_REC
 *     ``ro``        adds MS_RDONLY (applied via a remount second
 *                   mount(2) call -- Linux ignores MS_RDONLY on the
 *                   initial bind, hence the remount).
 *
 *   ``source`` and ``target`` MUST be absolute. ``target`` is
 *   evaluated inside the new mount namespace and is created via
 *   ``mkdir -p`` semantics under ``/`` if missing.
 *
 *   Two special directives may appear (no colon-separated arguments):
 *
 *     ``proc``       mount procfs at /proc (after the bind set is up)
 *     ``sys``        mount sysfs at /sys (no-op if not requested)
 *
 *   Special key/value lines (single key = value, no quoting):
 *
 *     ``exec=/abs/path/to/bin``      target binary (required; usually
 *                                    overridden via --exec on the CLI)
 *     ``cwd=/abs/path``              chdir after namespace setup
 *
 *   Empty / comment / unknown-key lines are tolerated for forward
 *   compatibility.
 *
 * CLI surface
 * -----------
 *
 *   reprobuild-sandbox-launcher
 *     --manifest <path>      manifest file (required)
 *     [--exec <path>]        override exec= line in manifest
 *     [--verbose]            log bind operations to stderr
 *     [--dry-run]            parse + validate; do not unshare/mount
 *     [-- <argv>...]         arguments forwarded to the target
 *
 * Exit codes
 * ----------
 *
 *   0    success (executed; child's exit code if --wait, else execve
 *        replaces the launcher).
 *   1    argument / manifest parse error.
 *   2    unshare(2) failed.
 *   3    mount(2) failed.
 *   4    execve(2) failed.
 *   5    other I/O error.
 *
 * Windows
 * -------
 *
 * Windows isn't the production target for the foreign-package sandbox
 * (Linux distros are the target). On Windows we compile a no-op stub
 * that just execve()s the target without setting up any namespaces;
 * the binary still parses the manifest so cross-platform tooling can
 * exercise the parser path.
 */

#define _GNU_SOURCE
#include <errno.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>

#ifdef _WIN32
#  include <process.h>
#  include <io.h>
#  define PATH_SEP_C '\\'
#else
#  include <fcntl.h>
#  include <sched.h>
#  include <signal.h>
#  include <sys/mount.h>
#  include <sys/wait.h>
#  include <unistd.h>
#  define PATH_SEP_C '/'
#endif

/* ---------------------------------------------------------------------- */
/* Constants                                                               */
/* ---------------------------------------------------------------------- */

#define MAX_LINE        4096
#define MAX_MOUNTS      512
#define MAX_PATH_LEN    1024
#define MAX_EXEC_ARGS   128

/* ---------------------------------------------------------------------- */
/* Types                                                                   */
/* ---------------------------------------------------------------------- */

typedef enum {
    OP_BIND,
    OP_RBIND,
    OP_PROC,
    OP_SYS
} mount_op_kind_t;

typedef struct {
    mount_op_kind_t kind;
    char source[MAX_PATH_LEN];
    char target[MAX_PATH_LEN];
    int  read_only;
} mount_op_t;

typedef struct {
    mount_op_t ops[MAX_MOUNTS];
    int        n_ops;
    char       exec_path[MAX_PATH_LEN];
    char       cwd[MAX_PATH_LEN];
} manifest_t;

static int g_verbose = 0;
static int g_dry_run = 0;

/* ---------------------------------------------------------------------- */
/* Logging                                                                 */
/* ---------------------------------------------------------------------- */

static void vlog(const char *fmt, ...) {
    if (!g_verbose) return;
    va_list ap;
    va_start(ap, fmt);
    fprintf(stderr, "[launcher] ");
    vfprintf(stderr, fmt, ap);
    fprintf(stderr, "\n");
    va_end(ap);
}

static void err_log(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    fprintf(stderr, "launcher error: ");
    vfprintf(stderr, fmt, ap);
    fprintf(stderr, "\n");
    va_end(ap);
}

/* ---------------------------------------------------------------------- */
/* String helpers                                                          */
/* ---------------------------------------------------------------------- */

static void rstrip(char *s) {
    size_t n = strlen(s);
    while (n > 0 && (s[n-1] == '\n' || s[n-1] == '\r' ||
                     s[n-1] == ' ' || s[n-1] == '\t')) {
        s[--n] = '\0';
    }
}

static char *lstrip(char *s) {
    while (*s == ' ' || *s == '\t') s++;
    return s;
}

static int starts_with(const char *s, const char *prefix) {
    return strncmp(s, prefix, strlen(prefix)) == 0;
}

static int copy_field(char *dst, size_t cap, const char *src) {
    size_t n = strlen(src);
    if (n + 1 > cap) {
        err_log("field too long (%zu chars, max %zu): %s", n, cap-1, src);
        return -1;
    }
    memcpy(dst, src, n + 1);
    return 0;
}

/* ---------------------------------------------------------------------- */
/* Manifest parsing                                                        */
/* ---------------------------------------------------------------------- */

static int parse_flags(const char *flags, int *ro) {
    *ro = 0;
    int saw_bind = 0;
    char buf[256];
    if (strlen(flags) + 1 > sizeof(buf)) return -1;
    memcpy(buf, flags, strlen(flags) + 1);

    char *p = buf;
    while (p && *p) {
        char *comma = strchr(p, ',');
        if (comma) *comma = '\0';
        if (strcmp(p, "bind") == 0) {
            saw_bind = 1;
        } else if (strcmp(p, "rbind") == 0) {
            saw_bind = 1;
        } else if (strcmp(p, "ro") == 0) {
            *ro = 1;
        } else if (strlen(p) == 0) {
            /* ignore */
        } else {
            err_log("unknown flag in manifest: '%s'", p);
            return -1;
        }
        if (comma) p = comma + 1;
        else break;
    }
    if (!saw_bind) {
        err_log("flags must include 'bind' or 'rbind'");
        return -1;
    }
    return 0;
}

/* Return non-zero if path looks absolute. POSIX = leading '/'.
 * Windows-friendly forms (used by the cross-platform smoke test):
 *   X:/foo, X:\foo  --  drive-letter absolute
 *   //host/share   --  UNC
 * We accept both shapes; the Windows launcher is a no-op stub so
 * the path just gets forwarded to _execv() unchanged.
 */
static int is_absolute_path(const char *s) {
    if (s[0] == '/') return 1;
#ifdef _WIN32
    if (s[0] != '\0' && s[1] == ':' &&
        (s[2] == '/' || s[2] == '\\')) return 1;
#endif
    return 0;
}

/* Split a "<source>:<target>:<flags>" line.
 *
 * On Linux the source is always POSIX-absolute (begins with '/'),
 * the target is always POSIX-absolute, and a simple left-to-right
 * strchr(':') walk works.
 *
 * On Windows the manifest writer (Nim's normSepsForward) translates
 * backslashes to forward slashes; sources may LOOK like
 * "D:/store/prefixes/foo" — the leading "D:" introduces a colon
 * that's NOT the source/target delimiter. We scan from the RIGHT to
 * find the LAST ':' (flags separator) and the previous ':' (target
 * separator), so a Windows drive-letter source ":<n>" survives
 * intact.
 */
static int split_mount_line(char *line, char **src, char **tgt,
                            char **flags) {
    size_t n = strlen(line);
    if (n == 0) return -1;
    /* Last ':' -> separator between target and flags. */
    char *last_colon = NULL;
    for (size_t i = n; i > 0; i--) {
        if (line[i-1] == ':') { last_colon = &line[i-1]; break; }
    }
    if (!last_colon || last_colon == line) return -1;
    /* Second-to-last ':' -> separator between source and target. */
    char *second_last = NULL;
    for (char *p = last_colon - 1; p >= line; p--) {
        if (*p == ':') { second_last = p; break; }
    }
    if (!second_last || second_last == line) return -1;
    *second_last = '\0';
    *last_colon  = '\0';
    *src   = line;
    *tgt   = second_last + 1;
    *flags = last_colon + 1;
    return 0;
}

static int parse_mount_line(manifest_t *m, char *line) {
    if (m->n_ops >= MAX_MOUNTS) {
        err_log("manifest exceeds MAX_MOUNTS (%d)", MAX_MOUNTS);
        return -1;
    }

    char *src, *tgt, *flags;
    if (split_mount_line(line, &src, &tgt, &flags) != 0) {
        err_log("malformed bind line (need 'src:tgt:flags'): %s", line);
        return -1;
    }

    if (!is_absolute_path(src)) {
        err_log("source must be absolute: %s", src);
        return -1;
    }
    if (!is_absolute_path(tgt)) {
        err_log("target must be absolute: %s", tgt);
        return -1;
    }

    int ro = 0;
    int is_rbind = (strstr(flags, "rbind") != NULL);
    if (parse_flags(flags, &ro) != 0) return -1;

    mount_op_t *op = &m->ops[m->n_ops++];
    op->kind = is_rbind ? OP_RBIND : OP_BIND;
    op->read_only = ro;
    if (copy_field(op->source, sizeof(op->source), src) != 0) return -1;
    if (copy_field(op->target, sizeof(op->target), tgt) != 0) return -1;
    return 0;
}

static int parse_manifest(const char *path, manifest_t *m) {
    FILE *fp = fopen(path, "r");
    if (!fp) {
        err_log("cannot open manifest '%s': %s", path, strerror(errno));
        return -1;
    }

    memset(m, 0, sizeof(*m));
    char line[MAX_LINE];
    int lineno = 0;
    while (fgets(line, sizeof(line), fp)) {
        lineno++;
        rstrip(line);
        char *p = lstrip(line);
        if (*p == '\0' || *p == '#') continue;

        if (starts_with(p, "exec=")) {
            if (copy_field(m->exec_path, sizeof(m->exec_path), p + 5) != 0) {
                fclose(fp); return -1;
            }
            continue;
        }
        if (starts_with(p, "cwd=")) {
            if (copy_field(m->cwd, sizeof(m->cwd), p + 4) != 0) {
                fclose(fp); return -1;
            }
            continue;
        }
        if (strcmp(p, "proc") == 0) {
            if (m->n_ops >= MAX_MOUNTS) { fclose(fp); return -1; }
            mount_op_t *op = &m->ops[m->n_ops++];
            op->kind = OP_PROC;
            strcpy(op->target, "/proc");
            continue;
        }
        if (strcmp(p, "sys") == 0) {
            if (m->n_ops >= MAX_MOUNTS) { fclose(fp); return -1; }
            mount_op_t *op = &m->ops[m->n_ops++];
            op->kind = OP_SYS;
            strcpy(op->target, "/sys");
            continue;
        }
        /* default: source:target:flags */
        if (parse_mount_line(m, p) != 0) {
            err_log("at %s:%d", path, lineno);
            fclose(fp);
            return -1;
        }
    }
    fclose(fp);
    return 0;
}

/* ---------------------------------------------------------------------- */
/* Directory creation (mkdir -p inside the namespace)                      */
/* ---------------------------------------------------------------------- */

#ifdef _WIN32
/* Silence the unused-function warning on Windows where ensure_dir is
   only referenced from the Linux mount path. */
__attribute__((unused))
#endif
static int ensure_dir(const char *path) {
    /* mkdir -p semantics. ``path`` is absolute. */
    if (path[0] != '/') return -1;

    char buf[MAX_PATH_LEN];
    size_t n = strlen(path);
    if (n + 1 > sizeof(buf)) return -1;
    memcpy(buf, path, n + 1);

    /* iterate over each '/' and mkdir intermediate */
    for (size_t i = 1; i <= n; i++) {
        if (buf[i] == '/' || buf[i] == '\0') {
            char saved = buf[i];
            buf[i] = '\0';
#ifdef _WIN32
            /* MSYS/mingw provides a POSIX-style mkdir() with one
               argument; native MSVC has _mkdir(). We pick the POSIX
               form because that's what MSYS GCC produces by default,
               and the Windows path is a no-op stub anyway -- the
               launcher's Windows codepath never actually calls
               ensure_dir(). */
            extern int mkdir(const char *path);
            (void)mkdir(buf);
#else
            if (mkdir(buf, 0755) != 0 && errno != EEXIST) {
                /* tolerate EROFS on the read-only root */
                if (errno != EROFS) {
                    err_log("mkdir '%s' failed: %s", buf, strerror(errno));
                    return -1;
                }
            }
#endif
            buf[i] = saved;
        }
    }
    return 0;
}

/* ---------------------------------------------------------------------- */
/* Namespace + mount setup (Linux)                                         */
/* ---------------------------------------------------------------------- */

#ifndef _WIN32

static int write_file(const char *path, const char *content) {
    int fd = open(path, O_WRONLY);
    if (fd < 0) return -1;
    size_t n = strlen(content);
    ssize_t w = write(fd, content, n);
    close(fd);
    return (w == (ssize_t)n) ? 0 : -1;
}

static int setup_userns_id_map(uid_t outer_uid, gid_t outer_gid) {
    /* In a freshly created user namespace, we need to write uid_map +
       gid_map (after disabling setgroups). This makes the unprivileged
       caller appear as root *inside* the namespace, which is required
       for mount(2) calls. */
    if (write_file("/proc/self/setgroups", "deny") != 0) {
        /* This file appeared in Linux 3.19. Older kernels don't have
           it. We tolerate ENOENT; otherwise hard-fail. */
        if (errno != ENOENT) {
            err_log("setgroups deny failed: %s", strerror(errno));
            return -1;
        }
    }
    char buf[128];
    snprintf(buf, sizeof(buf), "0 %u 1\n", (unsigned)outer_uid);
    if (write_file("/proc/self/uid_map", buf) != 0) {
        err_log("uid_map write failed: %s", strerror(errno));
        return -1;
    }
    snprintf(buf, sizeof(buf), "0 %u 1\n", (unsigned)outer_gid);
    if (write_file("/proc/self/gid_map", buf) != 0) {
        err_log("gid_map write failed: %s", strerror(errno));
        return -1;
    }
    return 0;
}

static int do_bind(const mount_op_t *op) {
    if (g_dry_run) {
        vlog("dry-run bind: %s -> %s%s", op->source, op->target,
             op->read_only ? " (ro)" : "");
        return 0;
    }
    if (ensure_dir(op->target) != 0) return -1;

    unsigned long flags = MS_BIND;
    if (op->kind == OP_RBIND) flags |= MS_REC;
    if (mount(op->source, op->target, NULL, flags, NULL) != 0) {
        err_log("bind mount %s -> %s failed: %s",
                op->source, op->target, strerror(errno));
        return -1;
    }
    if (op->read_only) {
        flags |= MS_REMOUNT | MS_RDONLY;
        if (mount(op->source, op->target, NULL, flags, NULL) != 0) {
            err_log("remount ro %s failed: %s",
                    op->target, strerror(errno));
            return -1;
        }
    }
    vlog("bind: %s -> %s%s", op->source, op->target,
         op->read_only ? " (ro)" : "");
    return 0;
}

static int do_proc(void) {
    if (g_dry_run) { vlog("dry-run proc"); return 0; }
    if (ensure_dir("/proc") != 0) return -1;
    if (mount("proc", "/proc", "proc", 0, NULL) != 0) {
        err_log("mount /proc failed: %s", strerror(errno));
        return -1;
    }
    return 0;
}

static int do_sys(void) {
    if (g_dry_run) { vlog("dry-run sys"); return 0; }
    if (ensure_dir("/sys") != 0) return -1;
    if (mount("sysfs", "/sys", "sysfs", 0, NULL) != 0) {
        err_log("mount /sys failed: %s", strerror(errno));
        return -1;
    }
    return 0;
}

static int setup_namespace(const manifest_t *m) {
    uid_t outer_uid = getuid();
    gid_t outer_gid = getgid();
    /* Decide whether we need CLONE_NEWUSER. We only need it when the
     * caller is unprivileged — mount(2) inside a mount namespace
     * requires CAP_SYS_ADMIN, and an unprivileged user gets it only
     * via a freshly-created user namespace where we are root.
     *
     * When the caller is already real root (e.g. inside ReproOS
     * where root auto-logs in to a getty + invokes the shim), the
     * mount(2)s are allowed in the host user namespace and we skip
     * CLONE_NEWUSER entirely. This also works around kernels built
     * without CONFIG_USER_NS (which would otherwise fail unshare
     * with EINVAL). */
    int need_userns = (outer_uid != 0);

    if (g_dry_run) {
        vlog("dry-run: would unshare(%sCLONE_NEWNS)",
             need_userns ? "CLONE_NEWUSER|" : "");
    } else {
        int clone_flags = CLONE_NEWNS;
        if (need_userns) clone_flags |= CLONE_NEWUSER;
        if (unshare(clone_flags) != 0) {
            err_log("unshare(%sNEWNS) failed: %s",
                    need_userns ? "NEWUSER|" : "", strerror(errno));
            return -2;
        }
        if (need_userns) {
            if (setup_userns_id_map(outer_uid, outer_gid) != 0) return -2;
        }
        /* Make the mount namespace's propagation private so bind mounts
           don't leak back to the host. */
        if (mount("none", "/", NULL, MS_REC | MS_PRIVATE, NULL) != 0) {
            err_log("remount-private failed: %s", strerror(errno));
            return -3;
        }
    }

    for (int i = 0; i < m->n_ops; i++) {
        const mount_op_t *op = &m->ops[i];
        int rc = 0;
        switch (op->kind) {
            case OP_BIND:
            case OP_RBIND: rc = do_bind(op);  break;
            case OP_PROC:  rc = do_proc();    break;
            case OP_SYS:   rc = do_sys();     break;
        }
        if (rc != 0) return -3;
    }

    if (m->cwd[0] != '\0' && !g_dry_run) {
        if (chdir(m->cwd) != 0) {
            err_log("chdir '%s' failed: %s", m->cwd, strerror(errno));
            return -5;
        }
    }
    return 0;
}

#endif /* !_WIN32 */

/* ---------------------------------------------------------------------- */
/* Argument parsing + main                                                 */
/* ---------------------------------------------------------------------- */

static void print_help(void) {
    fputs(
"reprobuild-sandbox-launcher -- C3 sandbox launcher\n"
"\n"
"Usage:\n"
"  reprobuild-sandbox-launcher --manifest=<path> [options] -- <argv>...\n"
"\n"
"Options:\n"
"  --manifest=<path>   bind-mount manifest (required)\n"
"  --exec=<path>       override exec= line from the manifest\n"
"  --verbose           log every bind operation to stderr\n"
"  --dry-run           parse + validate the manifest; do not unshare\n"
"  --help              this message\n"
"\n"
"Everything after a literal ``--`` is forwarded to the wrapped binary\n"
"as argv[1..].\n",
        stdout);
}

int main(int argc, char **argv) {
    const char *manifest_path = NULL;
    const char *exec_override = NULL;
    int i = 1;
    int double_dash = -1;
    for (; i < argc; i++) {
        if (strcmp(argv[i], "--") == 0) { double_dash = i; break; }
        if (strcmp(argv[i], "--help") == 0 || strcmp(argv[i], "-h") == 0) {
            print_help(); return 0;
        } else if (strcmp(argv[i], "--verbose") == 0) {
            g_verbose = 1;
        } else if (strcmp(argv[i], "--dry-run") == 0) {
            g_dry_run = 1;
        } else if (starts_with(argv[i], "--manifest=")) {
            manifest_path = argv[i] + strlen("--manifest=");
        } else if (strcmp(argv[i], "--manifest") == 0 && i + 1 < argc) {
            manifest_path = argv[++i];
        } else if (starts_with(argv[i], "--exec=")) {
            exec_override = argv[i] + strlen("--exec=");
        } else if (strcmp(argv[i], "--exec") == 0 && i + 1 < argc) {
            exec_override = argv[++i];
        } else {
            err_log("unknown argument: %s", argv[i]);
            return 1;
        }
    }
    if (!manifest_path) {
        err_log("--manifest is required");
        print_help();
        return 1;
    }

    manifest_t m;
    if (parse_manifest(manifest_path, &m) != 0) return 1;

    if (exec_override) {
        if (copy_field(m.exec_path, sizeof(m.exec_path), exec_override) != 0) {
            return 1;
        }
    }
    if (m.exec_path[0] == '\0') {
        err_log("no exec= line in manifest and no --exec override");
        return 1;
    }

    vlog("manifest=%s exec=%s n_ops=%d",
         manifest_path, m.exec_path, m.n_ops);

#ifdef _WIN32
    /* Windows: stub. Validate parsed manifest, then exec the target. */
    vlog("windows: namespace setup skipped (no-op stub)");
#else
    int rc = setup_namespace(&m);
    if (rc != 0) {
        return -rc;  /* exit code: -(-2) = 2, etc. */
    }
#endif

    /* Build argv for the child. m.exec_path is argv[0]; remaining args
       come from after the ``--`` delimiter. */
    char *child_argv[MAX_EXEC_ARGS];
    int ci = 0;
    child_argv[ci++] = m.exec_path;
    if (double_dash >= 0) {
        for (int j = double_dash + 1; j < argc && ci < MAX_EXEC_ARGS - 1; j++) {
            child_argv[ci++] = argv[j];
        }
    }
    child_argv[ci] = NULL;

    if (g_dry_run) {
        vlog("dry-run: would execve(%s)", m.exec_path);
        for (int j = 0; j < ci; j++) {
            vlog("  argv[%d]=%s", j, child_argv[j]);
        }
        return 0;
    }

#ifdef _WIN32
    /* _execv on Windows replaces the current process. */
    if (_execv(m.exec_path, (const char *const *)child_argv) < 0) {
        err_log("_execv '%s' failed: %s", m.exec_path, strerror(errno));
        return 4;
    }
#else
    if (execv(m.exec_path, child_argv) < 0) {
        err_log("execv '%s' failed: %s", m.exec_path, strerror(errno));
        return 4;
    }
#endif
    return 4; /* unreachable */
}
