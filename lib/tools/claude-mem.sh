#!/usr/bin/env bash
# claude-mem — cross-session memory. Plugin state plus a background worker that
# does the summarising, so "off" has to stop the worker too; leaving it running
# means it keeps indexing sessions you told it to stop watching.

hookpat_claude_mem() { echo 'claude-mem'; }

state_claude_mem() { plugin_state "claude-mem@thedotmack"; }

enable_claude_mem() {
    plugin_toggle on "claude-mem@thedotmack"
    npx --yes claude-mem start >/dev/null 2>&1 &
    ok "claude-mem on — worker starting in the background."
}

disable_claude_mem() {
    plugin_toggle off "claude-mem@thedotmack"
    npx --yes claude-mem stop >/dev/null 2>&1
    ok "claude-mem off — worker stopped."
}

install_claude_mem() {
    plugin_install "claude-mem@thedotmack" "thedotmack/claude-mem" || return 1
    npx --yes claude-mem start >/dev/null 2>&1 &
}
