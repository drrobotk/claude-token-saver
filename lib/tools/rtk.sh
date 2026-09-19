#!/usr/bin/env bash
# rtk — Rust Token Killer. A PreToolUse hook rewrites Bash commands to their
# compressed `rtk <cmd>` equivalent before they run, so build/test/git output
# reaches the context already summarised.
#
# Claims x:hook.PreToolUse.Bash: only one thing may rewrite Bash commands. A
# second rewriter receives an already-rewritten command and either double-wraps
# it or silently drops the first one's filtering.

hookpat_rtk() { echo 'rtk'; }

state_rtk() {
    command -v rtk >/dev/null 2>&1 || { echo absent; return; }
    local s; s="$(hook_state 'rtk')"
    [ "$s" = on ] && { echo on; return; }
    [ -f "$STATE_DIR/hooks-rtk.json" ] && echo off || echo off
}

enable_rtk() {
    command -v rtk >/dev/null 2>&1 || { err "rtk not installed — run: token-saver install rtk"; return 1; }
    hook_restore rtk && return 0
    # Nothing parked: let rtk write its own hook, then verify it landed.
    backup "$SETTINGS"
    rtk init -g --auto-patch >/dev/null 2>&1
    if [ "$(hook_state 'rtk')" = on ]; then
        ok "rtk enabled — PreToolUse hook registered. Restart Claude Code."
    else
        err "rtk init did not register a hook; see: rtk init -g --auto-patch"
        return 1
    fi
}

disable_rtk() {
    hook_park rtk 'rtk'
    info "  effective on the next Bash call; a live session keeps the old hook in memory."
}

install_rtk() {
    if command -v rtk >/dev/null 2>&1; then
        info "rtk binary already present ($(rtk --version 2>/dev/null | head -1))"
    elif command -v brew >/dev/null 2>&1; then
        brew install rtk || { err "brew install rtk failed"; return 1; }
    elif command -v cargo >/dev/null 2>&1; then
        cargo install rtk || { err "cargo install rtk failed"; return 1; }
    else
        err "install rtk first: brew install rtk   (or: cargo install rtk)"
        return 1
    fi
    enable_rtk
}
