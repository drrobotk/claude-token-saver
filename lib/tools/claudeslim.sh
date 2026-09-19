#!/usr/bin/env bash
# claudeslim — local proxy that compresses API payloads on the way out.
# Same shape as headroom and the same hazard: it owns ANTHROPIC_BASE_URL and a
# localhost port, so the two can never both be on. Best with API-key auth;
# subscription OAuth sessions have been reported to break behind it.

CLAUDESLIM_DIR="${TS_CLAUDESLIM_DIR:-$HOME/.claudeslim}"
CLAUDESLIM_PORT="${TS_CLAUDESLIM_PORT:-8123}"
CLAUDESLIM_PID="$STATE_DIR/claudeslim.pid"
CLAUDESLIM_URL="http://127.0.0.1:$CLAUDESLIM_PORT"

state_claudeslim() {
    [ -d "$CLAUDESLIM_DIR" ] || { echo absent; return; }
    local url; url="$(py "print(load(SETTINGS).get('env', {}).get('ANTHROPIC_BASE_URL', ''))")"
    [ "$url" = "$CLAUDESLIM_URL" ] && echo on || echo off
}

enable_claudeslim() {
    [ -d "$CLAUDESLIM_DIR" ] || { err "claudeslim not installed — run: token-saver install claudeslim"; return 1; }
    local py_bin="$CLAUDESLIM_DIR/.venv/bin/python"
    [ -x "$py_bin" ] || py_bin="$(command -v python3)"
    ( cd "$CLAUDESLIM_DIR" && nohup "$py_bin" -m claudeslim --port "$CLAUDESLIM_PORT" \
        >"$STATE_DIR/claudeslim.log" 2>&1 & echo $! > "$CLAUDESLIM_PID" )
    local waited=0
    while [ "$waited" -lt 20 ]; do
        curl -fsS -m2 "$CLAUDESLIM_URL/health" >/dev/null 2>&1 && break
        sleep 2; waited=$((waited + 2))
    done
    if ! curl -fsS -m2 "$CLAUDESLIM_URL/health" >/dev/null 2>&1; then
        err "proxy did not come up — see $STATE_DIR/claudeslim.log. Not touching ANTHROPIC_BASE_URL."
        return 1
    fi
    env_set ANTHROPIC_BASE_URL "$CLAUDESLIM_URL"
    ok "claudeslim on at $CLAUDESLIM_URL — restart Claude Code."
}

disable_claudeslim() {
    # Remove the routing first: a dead port in ANTHROPIC_BASE_URL bricks the CLI.
    local url; url="$(py "print(load(SETTINGS).get('env', {}).get('ANTHROPIC_BASE_URL', ''))")"
    [ "$url" = "$CLAUDESLIM_URL" ] && env_unset ANTHROPIC_BASE_URL
    [ -f "$CLAUDESLIM_PID" ] && kill "$(cat "$CLAUDESLIM_PID")" 2>/dev/null
    rm -f "$CLAUDESLIM_PID"
    pkill -f "claudeslim" >/dev/null 2>&1
    ok "claudeslim off — proxy stopped and base URL cleared."
}

install_claudeslim() {
    if [ ! -d "$CLAUDESLIM_DIR" ]; then
        command -v git >/dev/null 2>&1 || { err "needs git"; return 1; }
        git clone --depth 1 https://github.com/buzzlair/ClaudeSlim.git "$CLAUDESLIM_DIR" || return 1
        ( cd "$CLAUDESLIM_DIR" && python3 -m venv .venv && .venv/bin/pip install -q -e . ) \
            || { err "claudeslim dependency install failed"; return 1; }
    fi
    enable_claudeslim
}
