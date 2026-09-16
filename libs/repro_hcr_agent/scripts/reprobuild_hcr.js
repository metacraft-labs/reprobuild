/**
 * Reprobuild HCR WinDbg Extension (reprobuild_hcr.js)
 *
 * Automates symbol reloading and debugger registration for dynamic patches on Windows.
 *
 * Milestone HX-W-6 References:
 *   - reprobuild-specs/HCR-Per-Platform-Handoff.milestones.org (HX-W-6)
 *   - reprobuild-specs/HCR/Debugger-Integration.md §7.1, §7.4, §7.8, §8.4
 *   - reprobuild-specs/HCR/HCR-Overview.md §14.3, §15
 *
 * ARCHITECTURAL CONTEXT:
 *
 * 1. WinDbg Dynamic Patch Registration:
 *    Unlike Linux/macOS (__jit_debug_register_code), Windows does not provide a single
 *    in-process JIT registration API. Instead, the Reprobuild HCR agent synthesizes a
 *    minimal PE header containing:
 *      - IMAGE_DIRECTORY_ENTRY_EXCEPTION (pointing to relocated .pdata)
 *      - IMAGE_DIRECTORY_ENTRY_DEBUG (pointing to CV_INFO_PDB70 RSDS record)
 *    at the base of the dynamic patch allocation.
 *
 * 2. Reload Automation:
 *    WinDbg discovers the dynamic module upon executing:
 *      .reload <module_name>=<base_address>,<size>
 *    When .reload runs, WinDbg reads the synthesized PE header, resolves the PDB via
 *    the CodeView record, and reads the exception directory (.pdata) directly from target
 *    memory for stack unwinding without requiring OutOfProcessCallbackDll.
 *
 * 3. Visual Studio Concord Standing Refusal:
 *    Visual Studio Concord native debugger discovers modules exclusively through Win32
 *    LOAD_DLL_DEBUG_EVENT emitted on LoadLibrary. Direct patch injection under Visual Studio
 *    is refused with named diagnostic "refused-visual-studio-direct-debugging".
 */

"use strict";

// Determine if running inside WinDbg JS host environment
const isWinDbg = (typeof host !== "undefined" && typeof host.namespace !== "undefined");

/**
 * Format the WinDbg .reload command for a dynamic module.
 * @param {string} moduleName - Name of module (e.g. "patch1")
 * @param {number|bigint|string} baseAddress - Base address of patch allocation
 * @param {number|bigint|string} size - Size in bytes of patch allocation
 * @returns {string} The formatted command: ".reload <module>=0x<base>,0x<size>"
 */
function formatReloadCommand(moduleName, baseAddress, size) {
    if (!moduleName) {
        throw new Error("Invalid moduleName");
    }

    let baseHex;
    if (typeof baseAddress === "number" || typeof baseAddress === "bigint") {
        baseHex = "0x" + baseAddress.toString(16);
    } else {
        const s = baseAddress.toString();
        baseHex = s.startsWith("0x") || s.startsWith("0X") ? s : "0x" + s;
    }

    let sizeHex;
    if (typeof size === "number" || typeof size === "bigint") {
        sizeHex = "0x" + size.toString(16);
    } else {
        const s = size.toString();
        sizeHex = s.startsWith("0x") || s.startsWith("0X") ? s : "0x" + s;
    }

    return `.reload ${moduleName}=${baseHex},${sizeHex}`;
}

/**
 * Execute a debugger reload command in WinDbg.
 * @param {string} moduleName - Name of module
 * @param {number|bigint|string} baseAddress - Base address
 * @param {number|bigint|string} size - Size
 * @returns {string} The executed command string
 */
function executeReload(moduleName, baseAddress, size) {
    const cmd = formatReloadCommand(moduleName, baseAddress, size);
    if (isWinDbg) {
        try {
            host.diagnostics.debugLog(`[reprobuild_hcr] Executing: ${cmd}\n`);
            host.namespace.Debugger.Utility.Control.ExecuteCommand(cmd);
        } catch (e) {
            host.diagnostics.debugLog(`[reprobuild_hcr] Command execution error: ${e}\n`);
            throw e;
        }
    }
    return cmd;
}

/**
 * Handler invoked upon dynamic patch publication event.
 * @param {number} patchIndex - 1-based index of the patch
 * @param {number|bigint|string} baseAddress - Base address
 * @param {number|bigint|string} size - Allocation size
 * @param {string} pdbPath - Path to matching PDB
 * @returns {object} Event metadata and executed reload command
 */
function onPatchPublished(patchIndex, baseAddress, size, pdbPath) {
    const moduleName = `patch${patchIndex}`;
    const cmd = executeReload(moduleName, baseAddress, size);
    return {
        moduleName: moduleName,
        baseAddress: baseAddress,
        size: size,
        pdbPath: pdbPath,
        reloadCommand: cmd,
        status: "reloaded"
    };
}

/**
 * Validates debugger and patch mode compatibility per the HX-W-6 selection rule.
 * @param {string} debuggerName - Debugger name ("windbg", "visual_studio", etc.)
 * @param {string} patchMode - Patch delivery mode ("direct", "shared_library")
 * @returns {object} { allowed: boolean, refusalReason: string|null, message: string }
 */
function checkDebuggerCompatibility(debuggerName, patchMode) {
    const dbg = (debuggerName || "").toLowerCase();
    const mode = (patchMode || "direct").toLowerCase();

    if (dbg === "visual_studio" || dbg === "vs" || dbg === "concord" || dbg === "msvc") {
        if (mode === "direct" || mode === "direct-patch-injection") {
            return {
                allowed: false,
                refusalReason: "refused-visual-studio-direct-debugging",
                message: "Visual Studio Concord native debugger discovers modules exclusively through Win32 LOAD_DLL_DEBUG_EVENT on LoadLibrary; direct in-memory synthetic PE injection is refused by decision."
            };
        }
    }

    return {
        allowed: true,
        refusalReason: null,
        message: "Debugger mode compatible with selected patch delivery mode."
    };
}

/**
 * WinDbg Extension Lifecycle entry points
 */
function initializeScript() {
    if (isWinDbg) {
        host.diagnostics.debugLog("[reprobuild_hcr] Reprobuild HCR WinDbg Extension initialized.\n");
    }
    return [
        new host.apiVersionSupport(1, 7)
    ];
}

function uninitializeScript() {
    if (isWinDbg) {
        host.diagnostics.debugLog("[reprobuild_hcr] Reprobuild HCR WinDbg Extension uninitialized.\n");
    }
}

// Module export for CLI / Node.js test harness
if (typeof module !== "undefined" && module.exports) {
    module.exports = {
        formatReloadCommand,
        executeReload,
        onPatchPublished,
        checkDebuggerCompatibility,
        initializeScript,
        uninitializeScript
    };
}
