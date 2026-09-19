#!/usr/bin/env bash
# serena — language-server-backed symbol retrieval. Asking for one function
# costs one function instead of one file, which is where most read-tokens go.
# Upstream asks you not to install it from an MCP marketplace, so this module
# uses the documented uv + `claude mcp add` path.

SERENA_BIN="$(command -v serena || echo "$HOME/.local/bin/serena")"

state_serena() {
    [ -x "$SERENA_BIN" ] || { echo absent; return; }
    mcp_state serena
}

enable_serena() {
    [ -x "$SERENA_BIN" ] || { err "serena not installed — run: token-saver install serena"; return 1; }
    if [ -f "$STATE_DIR/mcp-serena.json" ]; then mcp_enable serena; return; fi
    if [ -x "$CLAUDE_BIN" ]; then
        "$CLAUDE_BIN" mcp add --scope user serena -- serena start-mcp-server \
            --context claude-code --project-from-cwd >/dev/null 2>&1 \
            && ok "serena on (user scope) — restart Claude Code." && return 0
    fi
    mcp_install_from_spec serena
}

disable_serena() { mcp_disable serena; }

install_serena() {
    if [ ! -x "$SERENA_BIN" ]; then
        command -v uv >/dev/null 2>&1 || { err "needs uv: curl -LsSf https://astral.sh/uv/install.sh | sh"; return 1; }
        uv tool install -p 3.13 serena-agent || { err "uv tool install serena-agent failed"; return 1; }
        SERENA_BIN="$(command -v serena || echo "$HOME/.local/bin/serena")"
    fi
    "$SERENA_BIN" init >/dev/null 2>&1
    enable_serena
}
