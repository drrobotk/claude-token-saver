#!/usr/bin/env bash
# tests/run.sh — every assertion here is about interference: that a tool cannot
# corrupt another tool's config, and that off/on is lossless. Runs entirely
# against a sandbox config; it never reads or writes your real ~/.claude.
set -uo pipefail

TS_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

export TS_SETTINGS="$SANDBOX/settings.json"
export TS_CLAUDE_JSON="$SANDBOX/claude.json"
export TS_MCP_JSON="$SANDBOX/mcp.json"
export TS_STATE_DIR="$SANDBOX/state"
export NO_COLOR=1
TS="$TS_HOME/bin/token-saver"

PASS=0; FAIL=0
ok()   { printf 'ok   %s\n' "$1"; PASS=$((PASS + 1)); }
nope() { printf 'FAIL %s\n   %s\n' "$1" "${2:-}"; FAIL=$((FAIL + 1)); }
check() { if [ "$2" = "$3" ]; then ok "$1"; else nope "$1" "expected [$3], got [$2]"; fi; }

seed() {
    cat > "$TS_SETTINGS" <<'JSON'
{
  "model": "opus",
  "effortLevel": "max",
  "hooks": {
    "PreToolUse": [
      {"matcher": "Bash", "hooks": [{"type": "command", "command": "rtk hook"}]},
      {"matcher": "Bash", "hooks": [{"type": "command", "command": "unrelated-linter"}]}
    ],
    "SessionStart": [
      {"hooks": [{"type": "command", "command": "code-review-graph sync"}]}
    ]
  },
  "enabledPlugins": {"caveman@caveman": true}
}
JSON
    cat > "$TS_CLAUDE_JSON" <<'JSON'
{"mcpServers": {
  "markitdown": {"command": "uvx", "args": ["markitdown-mcp"]},
  "context-mode": {"command": "npx", "args": ["-y", "context-mode"]}
}}
JSON
    printf '%s\n' '{"mcpServers":{}}' > "$TS_MCP_JSON"
    rm -rf "$TS_STATE_DIR"; mkdir -p "$TS_STATE_DIR"
}

jqpy() { python3 -c "import json,sys;d=json.load(open(sys.argv[1]));print(eval(sys.argv[2],{'d':d}))" "$1" "$2"; }

# ── 1. the registry is coherent and the curated stack is conflict-free ────────
seed
"$TS" selftest >/dev/null 2>&1
check "selftest passes" "$?" "0"

# ── 2. every declared exclusive resource has more than one potential owner, or
#       it does not need to be exclusive at all ──────────────────────────────
dupes="$("$TS" conflicts 2>/dev/null | awk '$1=="HARD" && NF==4' | wc -l | tr -d ' ')"
[ "$dupes" -ge 3 ] && ok "hard conflict pairs are detected ($dupes)" \
    || nope "hard conflict pairs are detected" "found $dupes"

# ── 3. off/on round-trips an MCP server byte for byte ────────────────────────
seed
before="$(jqpy "$TS_CLAUDE_JSON" "d['mcpServers']['markitdown']")"
"$TS" off markitdown >/dev/null 2>&1
gone="$(jqpy "$TS_CLAUDE_JSON" "'markitdown' in d['mcpServers']")"
check "off parks the MCP server" "$gone" "False"
"$TS" on markitdown >/dev/null 2>&1
after="$(jqpy "$TS_CLAUDE_JSON" "d['mcpServers']['markitdown']")"
check "on restores it unchanged" "$after" "$before"

# ── 4. lean-settings never parks a hook owned by an enabled tool ─────────────
#      rtk's hook must survive; the unrelated one must be parked.
seed
TS_LEAN_KEEP='rtk|code-review-graph' "$TS" on lean-settings >/dev/null 2>&1
kept="$(jqpy "$TS_SETTINGS" "[h['command'] for e in d.get('hooks',{}).get('PreToolUse',[]) for h in e['hooks']]")"
case "$kept" in
    *rtk*)            ok "lean-settings keeps the rtk hook" ;;
    *)                nope "lean-settings keeps the rtk hook" "kept: $kept" ;;
esac
case "$kept" in
    *unrelated-linter*) nope "lean-settings parks unowned hooks" "kept: $kept" ;;
    *)                  ok "lean-settings parks unowned hooks" ;;
esac
"$TS" off lean-settings >/dev/null 2>&1
restored="$(jqpy "$TS_SETTINGS" "sorted(h['command'] for e in d.get('hooks',{}).get('PreToolUse',[]) for h in e['hooks'])")"
check "lean-settings restores every parked hook" "$restored" "['rtk hook', 'unrelated-linter']"

# ── 5. a tool that owns hooks in two files moves both or neither ─────────────
seed
printf '%s\n' '{"mcpServers":{"code-review-graph":{"command":"crg","args":["mcp"]}}}' > "$TS_MCP_JSON"
"$TS" off code-review-graph >/dev/null 2>&1
srv="$(jqpy "$TS_MCP_JSON" "'code-review-graph' in d.get('mcpServers',{})")"
hk="$(jqpy "$TS_SETTINGS" "any('code-review-graph' in h['command'] for e in d.get('hooks',{}).get('SessionStart',[]) for h in e['hooks'])")"
check "server and hooks leave together (server)" "$srv" "False"
check "server and hooks leave together (hooks)"  "$hk"  "False"
"$TS" on code-review-graph >/dev/null 2>&1
srv="$(jqpy "$TS_MCP_JSON" "'code-review-graph' in d.get('mcpServers',{})")"
hk="$(jqpy "$TS_SETTINGS" "any('code-review-graph' in h['command'] for e in d.get('hooks',{}).get('SessionStart',[]) for h in e['hooks'])")"
check "server and hooks come back together (server)" "$srv" "True"
check "server and hooks come back together (hooks)"  "$hk"  "True"

# ── 6. doctor catches a dead proxy route and a double Bash rewriter ──────────
seed
python3 - <<'PY'
import json, os
p = os.environ['TS_SETTINGS']; s = json.load(open(p))
s['env'] = {'ANTHROPIC_BASE_URL': 'http://127.0.0.1:59999'}
s['hooks']['PreToolUse'].append(
    {"matcher": "Bash", "hooks": [{"type": "command", "command": "token-compression filter"}]})
json.dump(s, open(p, 'w'), indent=2)
PY
out="$("$TS" doctor 2>&1)"; rc=$?
check "doctor exits non-zero on interference" "$rc" "1"
case "$out" in *"nothing is listening"*) ok "doctor flags a dead proxy route" ;;
               *) nope "doctor flags a dead proxy route" "$out" ;; esac
case "$out" in *"rewrite Bash"*) ok "doctor flags two Bash rewriters" ;;
               *) nope "doctor flags two Bash rewriters" "$out" ;; esac

# ── 7. a corrupt config is reported, not silently overwritten ───────────────
seed
printf '%s' 'not json' > "$TS_CLAUDE_JSON"
out="$("$TS" doctor 2>&1)"
case "$out" in *"not valid JSON"*) ok "doctor flags unparseable config" ;;
               *) nope "doctor flags unparseable config" "$out" ;; esac

# ── 8. every write leaves a timestamped backup ──────────────────────────────
seed
"$TS" off markitdown >/dev/null 2>&1
n="$(find "$TS_STATE_DIR" -name '*.bak' | wc -l | tr -d ' ')"
[ "$n" -ge 1 ] && ok "a backup is written before every edit" \
    || nope "a backup is written before every edit" "found $n"

# ── 9. the lock refuses a concurrent run rather than racing it ──────────────
seed
mkdir -p "$TS_STATE_DIR/.lock"; echo 999999 > "$TS_STATE_DIR/.lock/pid"
kill -0 999999 2>/dev/null && ok "skipped: pid 999999 exists" || {
    "$TS" off markitdown >/dev/null 2>&1
    still="$(jqpy "$TS_CLAUDE_JSON" "'markitdown' in d['mcpServers']")"
    # pid is dead, so the stale lock is reclaimed and the edit proceeds
    check "a stale lock is reclaimed" "$still" "False"
}
mkdir -p "$TS_STATE_DIR/.lock"; echo $$ > "$TS_STATE_DIR/.lock/pid"
timeout 5 "$TS" off context-mode >/dev/null 2>&1
held="$(jqpy "$TS_CLAUDE_JSON" "'context-mode' in d['mcpServers']")"
check "a live lock blocks a second run" "$held" "True"
rm -rf "$TS_STATE_DIR/.lock"

# ── 10. helpers work when called from a module, not just from the dispatcher ─
#       (a single `local a=$1 b=...$a...` expands b against the *caller's*
#       scope, so these paths only appeared to work from one call path)
seed
printf '%s\n' '{"mcpServers":{}}' > "$TS_CLAUDE_JSON"
( TS_HOME="$TS_HOME"; . "$TS_HOME/lib/common.sh"; mcp_install_from_spec markitdown >/dev/null 2>&1 )
wrote="$(jqpy "$TS_CLAUDE_JSON" "d['mcpServers']['markitdown']['command']")"
check "mcp_install_from_spec works from a bare scope" "$wrote" "uvx"
( TS_HOME="$TS_HOME"; . "$TS_HOME/lib/common.sh"; mcp_disable markitdown >/dev/null 2>&1; mcp_enable markitdown >/dev/null 2>&1 )
back="$(jqpy "$TS_CLAUDE_JSON" "'markitdown' in d['mcpServers']")"
check "mcp_enable works from a bare scope" "$back" "True"

# ── 11. restoring a hook the tool already re-registered must not double it ──
seed
( TS_HOME="$TS_HOME"; . "$TS_HOME/lib/common.sh"; hook_park rtk 'rtk' >/dev/null 2>&1 )
python3 - <<'PY'
import json, os
p = os.environ['TS_SETTINGS']; s = json.load(open(p))
s.setdefault('hooks', {}).setdefault('PreToolUse', []).append(
    {"matcher": "Bash", "hooks": [{"type": "command", "command": "rtk hook"}]})
json.dump(s, open(p, 'w'), indent=2)
PY
( TS_HOME="$TS_HOME"; . "$TS_HOME/lib/common.sh"; hook_restore rtk >/dev/null 2>&1 )
n="$(jqpy "$TS_SETTINGS" "sum('rtk' in h['command'] for e in d['hooks']['PreToolUse'] for h in e['hooks'])")"
check "a re-registered hook is not restored twice" "$n" "1"

# ── 12. the proxy route moves to the shell, and comes back out ─────────────
#       A route in settings.json cannot be dropped per session, so Remote
#       Control stays off; a route left in the shell after "off" points every
#       new shell at a dead proxy. Both directions matter.
seed
RC="$SANDBOX/rc"; : > "$RC"
python3 - <<'PY'
import json, os
p = os.environ['TS_SETTINGS']; s = json.load(open(p))
s['env'] = {'ANTHROPIC_BASE_URL': 'http://127.0.0.1:8787'}
json.dump(s, open(p, 'w'), indent=2)
PY
( TS_HOME="$TS_HOME"; TS_SHELL_RC="$RC"; . "$TS_HOME/lib/common.sh"; . "$TS_HOME/lib/tools/headroom.sh"
  _headroom_route_via_shell >/dev/null 2>&1 )
left="$(jqpy "$TS_SETTINGS" "d.get('env',{}).get('ANTHROPIC_BASE_URL','')")"
check "the route leaves settings.json" "$left" ""
grep -q 'export ANTHROPIC_BASE_URL="http://127.0.0.1:8787"' "$RC" \
    && ok "the route lands in the shell profile" \
    || nope "the route lands in the shell profile" "$(cat "$RC")"

( TS_HOME="$TS_HOME"; TS_SHELL_RC="$RC"; . "$TS_HOME/lib/common.sh"; . "$TS_HOME/lib/tools/headroom.sh"
  _headroom_unroute_shell >/dev/null 2>&1 )
grep -q 'ANTHROPIC_BASE_URL' "$RC" \
    && nope "off removes the shell export" "$(cat "$RC")" \
    || ok "off removes the shell export"

doctor_out="$(TS_SHELL_RC="$RC" "$TS" doctor 2>&1)"
seed
python3 - <<'PY'
import json, os
p = os.environ['TS_SETTINGS']; s = json.load(open(p))
s['env'] = {'ANTHROPIC_BASE_URL': 'http://127.0.0.1:8787'}
json.dump(s, open(p, 'w'), indent=2)
PY
out="$("$TS" doctor 2>&1)"
case "$out" in *"disables Remote Control"*) ok "doctor flags a route in settings.json" ;;
               *) nope "doctor flags a route in settings.json" "$out" ;; esac

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
