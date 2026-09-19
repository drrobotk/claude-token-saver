#!/usr/bin/env bash
# toolhive — runs MCP servers in containers behind a single client registration,
# so the client sees one entry instead of N schema dumps.
#
# Claims x:mcp.gateway: a gateway rewrites the whole mcpServers block. Two of
# them fight over the same block and the loser's servers vanish on next write.

THV_BIN="$(command -v thv || echo /opt/homebrew/bin/thv)"

state_toolhive() {
    [ -x "$THV_BIN" ] || { echo absent; return; }
    "$THV_BIN" list >/dev/null 2>&1 && echo on || echo off
}

note_toolhive() {
    [ -x "$THV_BIN" ] || return 0
    "$THV_BIN" list >/dev/null 2>&1 || echo "no container runtime — start Docker or Podman"
}

enable_toolhive() {
    [ -x "$THV_BIN" ] || { err "toolhive not installed — run: token-saver install toolhive"; return 1; }
    if ! "$THV_BIN" list >/dev/null 2>&1; then
        err "toolhive needs a container runtime. Start Docker, or:"
        err "  podman machine init && podman machine start"
        return 1
    fi
    "$THV_BIN" client register claude-code >/dev/null 2>&1
    "$THV_BIN" restart --all >/dev/null 2>&1
    ok "toolhive on — servers started, claude-code registered. Restart Claude Code."
}

disable_toolhive() {
    [ -x "$THV_BIN" ] || { warn "thv absent"; return 0; }
    "$THV_BIN" stop --all >/dev/null 2>&1
    "$THV_BIN" client remove claude-code >/dev/null 2>&1
    ok "toolhive off — servers stopped and client entry removed."
}

install_toolhive() {
    if [ ! -x "$THV_BIN" ]; then
        command -v brew >/dev/null 2>&1 || { err "install thv from https://github.com/stacklok/toolhive"; return 1; }
        brew install stacklok/tap/thv || return 1
        THV_BIN="$(command -v thv)"
    fi
    enable_toolhive
}
