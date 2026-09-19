#!/usr/bin/env bash
# mcplex — semantic MCP gateway. One client entry fronts every server and only
# surfaces the tools a prompt actually needs, which is the single biggest cut
# available when you run many servers.
#
# Claims x:mcp.gateway. Turning it on rewrites every entry in ~/.claude.json, so
# the whole file is backed up first and restored verbatim on "off" — a partial
# restore of a swapped config is worse than no gateway at all.

MCPLEX_BIN="$(command -v mcplex || echo "$HOME/bin/mcplex")"
MCPLEX_FULL_BACKUP="$STATE_DIR/mcplex-full-claude-json.bak"

state_mcplex() {
    [ -x "$MCPLEX_BIN" ] || { echo absent; return; }
    mcp_state mcplex
}

enable_mcplex() {
    [ -x "$MCPLEX_BIN" ] || { err "mcplex not installed — see docs/TOOLS.md"; return 1; }
    confirm "mcplex rewrites every MCP server entry in ~/.claude.json. Snapshot and proceed?" || return 1
    cp "$CLAUDE_JSON" "$MCPLEX_FULL_BACKUP"
    "$MCPLEX_BIN" init >/dev/null 2>&1
    mcp_install_from_spec mcplex
    ok "mcplex on — full pre-swap config saved at $MCPLEX_FULL_BACKUP. Restart Claude Code."
}

disable_mcplex() {
    pkill -f "mcplex" >/dev/null 2>&1
    if [ -f "$MCPLEX_FULL_BACKUP" ]; then
        confirm "Restore ~/.claude.json from the pre-mcplex snapshot? Any MCP server added since is lost." || return 1
        backup "$CLAUDE_JSON"
        cp "$MCPLEX_FULL_BACKUP" "$CLAUDE_JSON"
        rm -f "$MCPLEX_FULL_BACKUP"
        ok "mcplex off — pre-swap config restored."
    else
        mcp_disable mcplex
        warn "no pre-swap snapshot found; removed the gateway entry only."
    fi
}

install_mcplex() {
    err "mcplex ships as a signed release binary. Download it to ~/bin/mcplex, chmod +x,"
    err "then: token-saver on mcplex"
    return 1
}
