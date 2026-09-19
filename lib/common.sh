#!/usr/bin/env bash
# common.sh — shared paths, JSON helpers and generic tool toggles.
# Sourced by bin/token-saver and every lib/tools/*.sh module.

# ── Paths ─────────────────────────────────────────────────────────────────────
TS_HOME="${TS_HOME:-$HOME/.token-saver}"
STATE_DIR="${TS_STATE_DIR:-$HOME/.claude/.token-saver-state}"
SETTINGS="${TS_SETTINGS:-$HOME/.claude/settings.json}"
CLAUDE_JSON="${TS_CLAUDE_JSON:-$HOME/.claude.json}"
MCP_JSON="${TS_MCP_JSON:-$HOME/.mcp.json}"
SKILLS_DIR="$HOME/.claude/skills"
PLUGIN_DIR="$HOME/.claude/plugins"
CLAUDE_MD="$HOME/.claude/CLAUDE.md"
REGISTRY_FILE="$TS_HOME/lib/registry.psv"
SPEC_DIR="$TS_HOME/lib/specs"
TOOLS_DIR="$TS_HOME/lib/tools"

mkdir -p "$STATE_DIR"

# ── Colours ───────────────────────────────────────────────────────────────────
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'
    BLUE=$'\033[0;34m'; BOLD=$'\033[1m'; DIM=$'\033[2m'; NC=$'\033[0m'
else
    RED=""; GREEN=""; YELLOW=""; BLUE=""; BOLD=""; DIM=""; NC=""
fi

say()  { printf '%s\n' "$*"; }
info() { printf '%s\n' "${DIM}$*${NC}"; }
ok()   { printf '%s\n' "${GREEN}$*${NC}"; }
warn() { printf '%s\n' "${YELLOW}! $*${NC}" >&2; }
err()  { printf '%s\n' "${RED}x $*${NC}" >&2; }

interactive() { [ -t 0 ] && [ -t 1 ]; }

# confirm MSG — honours --force (FORCE) and refuses to guess when piped.
confirm() {
    [ "${FORCE:-false}" = true ] && return 0
    if ! interactive; then
        err "non-interactive: refusing to act without --force ($1)"
        return 1
    fi
    printf '%s [y/N] ' "$1"
    local reply; read -r reply
    [[ "$reply" =~ ^[Yy] ]]
}

# ── Python bootstrap ──────────────────────────────────────────────────────────
# Every config edit goes through python3 rather than jq: it is present on stock
# macOS and Linux, and the nested merge/restore logic below is far safer in it.
PY="$(command -v python3 || true)"
require_py() {
    [ -n "$PY" ] && return 0
    err "python3 not found — token-saver needs it to edit Claude Code config safely."
    return 1
}

# py SCRIPT [ARGS...] — run an inline script with paths pre-bound as globals.
py() {
    require_py || return 1
    local script="$1"; shift
    "$PY" -c "
import json, os, sys
SETTINGS   = os.environ['TS_P_SETTINGS']
CLAUDE_JSON= os.environ['TS_P_CLAUDE_JSON']
MCP_JSON   = os.environ['TS_P_MCP_JSON']
STATE_DIR  = os.environ['TS_P_STATE_DIR']

def load(path, default=None):
    try:
        with open(path) as f: return json.load(f)
    except (FileNotFoundError, ValueError):
        return {} if default is None else default

def save(path, data):
    os.makedirs(os.path.dirname(path) or '.', exist_ok=True)
    with open(path, 'w') as f: json.dump(data, f, indent=2)

$script
" "$@"
}
export_py_env() {
    export TS_P_SETTINGS="$SETTINGS" TS_P_CLAUDE_JSON="$CLAUDE_JSON" \
           TS_P_MCP_JSON="$MCP_JSON" TS_P_STATE_DIR="$STATE_DIR"
}
export_py_env

# backup FILE — timestamped copy in the state dir, kept forever.
backup() {
    [ -e "$1" ] || return 0
    cp "$1" "$STATE_DIR/$(basename "$1").$(date +%Y%m%d-%H%M%S).bak"
}

# ── Mutation lock ─────────────────────────────────────────────────────────────
# Every tool here rewrites the same two files. Two token-saver runs (or a run
# racing a `claude plugin` call it spawned) would read-modify-write over each
# other and silently drop a server or a hook. mkdir is the portable atomic
# test-and-set; a lock whose owner is gone is reclaimed rather than inherited.
LOCK_DIR="$STATE_DIR/.lock"

acquire_lock() {
    local waited=0
    while ! mkdir "$LOCK_DIR" 2>/dev/null; do
        local owner; owner="$(cat "$LOCK_DIR/pid" 2>/dev/null || echo "")"
        if [ -n "$owner" ] && ! kill -0 "$owner" 2>/dev/null; then
            warn "clearing stale lock from dead pid $owner"
            rm -rf "$LOCK_DIR"; continue
        fi
        [ "$waited" -ge 20 ] && { err "another token-saver run (pid ${owner:-?}) holds the lock"; return 1; }
        sleep 1; waited=$((waited + 1))
    done
    echo "$$" > "$LOCK_DIR/pid"
    trap 'release_lock' EXIT INT TERM
}
release_lock() { rm -rf "$LOCK_DIR"; }

# ── Registry access ───────────────────────────────────────────────────────────
# registry.psv columns: name|kind|ref|best|conflicts|description
reg_field() {  # reg_field NAME COLUMN_INDEX
    awk -F'|' -v n="$1" -v c="$2" '$1==n && $0 !~ /^#/ {print $c; exit}' "$REGISTRY_FILE"
}
reg_kind()        { reg_field "$1" 2; }
reg_ref()         { reg_field "$1" 3; }
reg_best()        { reg_field "$1" 4; }
reg_claims()      { reg_field "$1" 5; }
reg_desc()        { reg_field "$1" 6; }
tool_names()      { awk -F'|' '!/^#/ && NF>1 {print $1}' "$REGISTRY_FILE"; }
tool_exists()     { tool_names | grep -qx "$1"; }

# fn_name NAME — registry names are hyphenated, shell functions are not.
fn_name() { printf '%s' "${1//-/_}"; }

# load_module NAME — source lib/tools/<name>.sh if this tool has custom logic.
load_module() {
    local f="$TOOLS_DIR/$1.sh"
    [ -f "$f" ] && . "$f"
    return 0
}
load_all_modules() {
    local f
    for f in "$TOOLS_DIR"/*.sh; do [ -f "$f" ] && . "$f"; done
    return 0
}

# ── Aliases ───────────────────────────────────────────────────────────────────
resolve() {
    case "$1" in
        mem)            echo claude-mem ;;
        ctx)            echo context-mode ;;
        tok|optimizer)  echo token-optimizer ;;
        thv)            echo toolhive ;;
        crg|graph-code) echo code-review-graph ;;
        graph)          echo graphify ;;
        cave)           echo caveman ;;
        pony)           echo ponytail ;;
        lean|settings)  echo lean-settings ;;
        plex)           echo mcplex ;;
        hr)             echo headroom ;;
        tc)             echo token-compression ;;
        ts|toolsearch)  echo tool-search ;;
        tr|reducer)     echo token-reducer ;;
        slim)           echo claudeslim ;;
        md)             echo markitdown ;;
        cc|ctx-search)  echo claude-context ;;
        *)              echo "$1" ;;
    esac
}

# ── Generic: MCP servers in ~/.claude.json ────────────────────────────────────
# "off" parks the server block in the state dir so "on" restores byte-for-byte,
# including which project scope it came from.

mcp_state() {  # on | off | absent
    local name="$1"
    local found
    found="$(py "
name = sys.argv[1]
c = load(CLAUDE_JSON)
hit = name in c.get('mcpServers', {})
for d in c.get('projects', {}).values():
    hit = hit or name in d.get('mcpServers', {})
print('on' if hit else 'off')
" "$name")"
    [ "$found" = on ] && { echo on; return; }
    [ -f "$STATE_DIR/mcp-$name.json" ] && echo off || echo absent
}

mcp_disable() {
    local name="$1"
    backup "$CLAUDE_JSON"
    py "
name = sys.argv[1]
c = load(CLAUDE_JSON)
parked = None
for proj, data in c.get('projects', {}).items():
    srv = data.get('mcpServers', {})
    if name in srv:
        parked = {'project': proj, 'server': {name: srv.pop(name)}}
        break
if parked is None:
    srv = c.get('mcpServers', {})
    if name in srv:
        parked = {'project': None, 'server': {name: srv.pop(name)}}
if parked is None:
    print(name + ' not configured'); raise SystemExit
save(os.path.join(STATE_DIR, 'mcp-' + name + '.json'), parked)
save(CLAUDE_JSON, c)
print(name + ' disabled (parked)')
" "$name"
}

mcp_enable() {
    # Two statements, not one: in a single `local`, later values are expanded
    # against the caller's scope, so "$name" would be whatever the caller
    # happened to have — empty, when called straight from a tool module.
    local name="$1"
    local parked="$STATE_DIR/mcp-$name.json"
    if [ ! -f "$parked" ]; then
        mcp_install_from_spec "$name"
        return
    fi
    backup "$CLAUDE_JSON"
    py "
name = sys.argv[1]
bk = load(os.path.join(STATE_DIR, 'mcp-' + name + '.json'))
c = load(CLAUDE_JSON)
proj = bk.get('project')
if proj:
    c.setdefault('projects', {}).setdefault(proj, {}).setdefault('mcpServers', {}).update(bk['server'])
else:
    c.setdefault('mcpServers', {}).update(bk['server'])
save(CLAUDE_JSON, c)
os.remove(os.path.join(STATE_DIR, 'mcp-' + name + '.json'))
print(name + ' enabled')
" "$name"
}

# Write a server straight from lib/specs/<name>.json (used on first install).
mcp_install_from_spec() {
    local name="$1"
    local spec="$SPEC_DIR/$name.json"
    [ -f "$spec" ] || { err "no MCP spec for $name"; return 1; }
    backup "$CLAUDE_JSON"
    py "
name, spec_path = sys.argv[1], sys.argv[2]
spec = load(spec_path)
c = load(CLAUDE_JSON)
c.setdefault('mcpServers', {})[name] = spec
save(CLAUDE_JSON, c)
print(name + ' MCP server registered in ~/.claude.json')
" "$name" "$spec"
}

# ── Generic: Claude Code plugins ──────────────────────────────────────────────
# `claude plugin enable/disable` rewrites settings.json and has been seen to drop
# effortLevel and the mcp__*__* permission, so re-assert them after every call.

CLAUDE_BIN="$(command -v claude || echo "$HOME/.local/bin/claude")"

repair_settings() {
    py "
s = load(SETTINGS)
changed = False
want = os.environ.get('TS_EFFORT', '')
if want and s.get('effortLevel') != want:
    s['effortLevel'] = want; changed = True
allow = s.setdefault('permissions', {}).setdefault('allow', [])
if os.environ.get('TS_KEEP_MCP_PERM') == '1' and 'mcp__*__*' not in allow:
    allow.append('mcp__*__*'); changed = True
if changed:
    save(SETTINGS, s)
"
}

plugin_state() {  # on | off | absent
    local id="$1" market="${1#*@}"
    py "
sid, market = sys.argv[1], sys.argv[2]
s = load(SETTINGS)
plugins = s.get('enabledPlugins', {})
if sid in plugins:
    print('on' if plugins[sid] else 'off'); raise SystemExit
root = os.path.expanduser('~/.claude/plugins/marketplaces')
print('off' if os.path.isdir(os.path.join(root, market)) else 'absent')
" "$id" "$market"
}

plugin_toggle() {  # plugin_toggle on|off ID
    local action="$1" id="$2"
    if [ ! -x "$CLAUDE_BIN" ]; then
        # No CLI on PATH — fall back to editing settings.json directly.
        backup "$SETTINGS"
        py "
sid, val = sys.argv[1], sys.argv[2] == 'on'
s = load(SETTINGS)
s.setdefault('enabledPlugins', {})[sid] = val
save(SETTINGS, s)
print(sid + (' enabled' if val else ' disabled') + ' (settings.json)')
" "$id" "$action"
        return
    fi
    if [ "$action" = off ]; then
        "$CLAUDE_BIN" plugin disable "$id" >/dev/null 2>&1
    else
        "$CLAUDE_BIN" plugin enable "$id" >/dev/null 2>&1
    fi
    repair_settings
    say "$id $([ "$action" = off ] && echo disabled || echo enabled)"
}

plugin_install() {  # plugin_install ID MARKETPLACE_REPO
    local id="$1" repo="$2"
    [ -x "$CLAUDE_BIN" ] || { err "claude CLI not on PATH — install ${id} with: /plugin marketplace add $repo"; return 1; }
    "$CLAUDE_BIN" plugin marketplace add "$repo" >/dev/null 2>&1
    "$CLAUDE_BIN" plugin install "$id" >/dev/null 2>&1
    repair_settings
    plugin_toggle on "$id"
}

# ── Generic: settings.json env vars ───────────────────────────────────────────
env_state() {  # env_state VAR [EXPECTED_VALUE]
    py "
var = sys.argv[1]
want = sys.argv[2] if len(sys.argv) > 2 else None
val = load(SETTINGS).get('env', {}).get(var)
if val is None: print('off')
elif want is None or str(val) == want: print('on')
else: print('off')
" "$@"
}

env_set() {  # env_set VAR VALUE
    backup "$SETTINGS"
    py "
var, val = sys.argv[1], sys.argv[2]
s = load(SETTINGS)
s.setdefault('env', {})[var] = val
save(SETTINGS, s)
print(var + '=' + val + ' set in settings.json')
" "$1" "$2"
}

env_unset() {  # env_unset VAR
    backup "$SETTINGS"
    py "
var = sys.argv[1]
s = load(SETTINGS)
env = s.get('env', {})
if var in env:
    env.pop(var)
    if not env: s.pop('env', None)
    save(SETTINGS, s)
    print(var + ' removed from settings.json')
else:
    print(var + ' already unset')
" "$1"
}

# ── Generic: settings.json hooks matching a pattern ───────────────────────────
hook_state() {  # hook_state PATTERN
    py "
import re
pat = re.compile(sys.argv[1])
s = load(SETTINGS)
for entries in s.get('hooks', {}).values():
    for e in entries:
        cmds = ' '.join(h.get('command', '') for h in e.get('hooks', []))
        if pat.search(cmds) or pat.search(e.get('command', '')):
            print('on'); raise SystemExit
print('off')
" "$1"
}

hook_park() {  # hook_park NAME PATTERN — move matching hook entries into state
    backup "$SETTINGS"
    py "
import re
name, pat = sys.argv[1], re.compile(sys.argv[2])
s = load(SETTINGS)
hooks = s.get('hooks', {})
parked = {}
for ev in list(hooks):
    keep, drop = [], []
    for e in hooks[ev]:
        cmds = ' '.join(h.get('command', '') for h in e.get('hooks', [])) + ' ' + e.get('command', '')
        (drop if pat.search(cmds) else keep).append(e)
    if drop: parked[ev] = drop
    if keep: hooks[ev] = keep
    else: del hooks[ev]
if not parked:
    print(name + ' has no hooks registered'); raise SystemExit
save(os.path.join(STATE_DIR, 'hooks-' + name + '.json'), parked)
s['hooks'] = hooks
save(SETTINGS, s)
n = sum(len(v) for v in parked.values())
print(name + ' disabled (parked %d hook entr%s)' % (n, 'y' if n == 1 else 'ies'))
" "$1" "$2"
}

hook_restore() {  # hook_restore NAME
    local parked="$STATE_DIR/hooks-$1.json"
    [ -f "$parked" ] || return 1
    backup "$SETTINGS"
    py "
name = sys.argv[1]
path = os.path.join(STATE_DIR, 'hooks-' + name + '.json')
parked = load(path)
s = load(SETTINGS)
for ev, entries in parked.items():
    s.setdefault('hooks', {}).setdefault(ev, []).extend(entries)
save(SETTINGS, s)
os.remove(path)
print(name + ' enabled (hooks restored)')
" "$1"
}

# ── Dispatch: state / enable / disable / install for any registry tool ────────
# A lib/tools/<name>.sh module may define state_<fn>, enable_<fn>, disable_<fn>
# or install_<fn> to override any single step; anything it omits falls through
# to the generic behaviour for the tool's kind.

tool_state() {
    local name="$1" fn; fn="$(fn_name "$name")"
    load_module "$name"
    if declare -f "state_$fn" >/dev/null 2>&1; then "state_$fn"; return; fi
    case "$(reg_kind "$name")" in
        mcp)    mcp_state "$(reg_ref "$name")" ;;
        plugin) plugin_state "$(reg_ref "$name")" ;;
        env)    local ref; ref="$(reg_ref "$name")"; env_state "${ref%%=*}" "${ref#*=}" ;;
        hook)   hook_state "$(reg_ref "$name")" ;;
        *)      echo absent ;;
    esac
}

tool_enable() {
    local name="$1" fn; fn="$(fn_name "$name")"
    load_module "$name"
    if declare -f "enable_$fn" >/dev/null 2>&1; then "enable_$fn"; return; fi
    case "$(reg_kind "$name")" in
        mcp)    mcp_enable "$(reg_ref "$name")" ;;
        plugin) plugin_toggle on "$(reg_ref "$name")" ;;
        env)    local ref; ref="$(reg_ref "$name")"; env_set "${ref%%=*}" "${ref#*=}" ;;
        hook)   hook_restore "$name" || warn "$name: nothing parked to restore — run: token-saver install $name" ;;
        *)      err "$name has no enable path" ;;
    esac
}

tool_disable() {
    local name="$1" fn; fn="$(fn_name "$name")"
    load_module "$name"
    if declare -f "disable_$fn" >/dev/null 2>&1; then "disable_$fn"; return; fi
    case "$(reg_kind "$name")" in
        mcp)    mcp_disable "$(reg_ref "$name")" ;;
        plugin) plugin_toggle off "$(reg_ref "$name")" ;;
        env)    local ref; ref="$(reg_ref "$name")"; env_unset "${ref%%=*}" ;;
        hook)   hook_park "$name" "$(reg_ref "$name")" ;;
        *)      err "$name has no disable path" ;;
    esac
}

tool_install() {
    local name="$1" fn; fn="$(fn_name "$name")"
    load_module "$name"
    if declare -f "install_$fn" >/dev/null 2>&1; then "install_$fn"; return; fi
    case "$(reg_kind "$name")" in
        mcp)    mcp_install_from_spec "$(reg_ref "$name")" ;;
        plugin) plugin_install "$(reg_ref "$name")" "$(reg_market "$name")" ;;
        env)    tool_enable "$name" ;;
        *)      err "$name has no automatic installer — see docs/TOOLS.md"; return 1 ;;
    esac
}

# Marketplace repo for a plugin lives in lib/specs/<name>.market
reg_market() {
    local f="$SPEC_DIR/$1.market"
    [ -f "$f" ] && cat "$f" || echo ""
}

# ── Conflicts, derived from claims ────────────────────────────────────────────
# Two tools interfere exactly when they claim the same resource. An x: claim is
# exclusive (the second owner breaks the first); an o: claim is an overlapping
# role (both run, you pay twice for one benefit). Nothing is hand-paired, so a
# tool added to the registry is automatically checked against every existing one.

claims_of() { printf '%s' "$(reg_claims "$1")" | tr ',' '\n' | grep -v '^$' || true; }

# owners_of CLAIM [SKIP] — every tool holding CLAIM, optionally excluding one.
owners_of() {
    local claim="$1" skip="${2:-}" t c
    for t in $(tool_names); do
        [ "$t" = "$skip" ] && continue
        for c in $(claims_of "$t"); do
            [ "$c" = "$claim" ] && echo "$t"
        done
    done
}

# conflicts_of NAME — lines of "HARD other claim" / "SOFT other claim" for the
# tools that are currently ON and share a claim with NAME.
conflicts_of() {
    local name="$1" claim other sev
    {
        for claim in $(claims_of "$name"); do
            case "$claim" in x:*) sev=HARD ;; *) sev=SOFT ;; esac
            for other in $(owners_of "$claim" "$name"); do
                [ "$(tool_state "$other")" = on ] && echo "$sev $other ${claim#*:}"
            done
        done
    } | sort -u
}

hard_conflicts_of() { conflicts_of "$1" | awk '$1=="HARD"{print $2}'; }

# Every pair of tools sharing any claim, regardless of on/off. Used by selftest
# and by `token-saver conflicts` so the matrix is inspectable before you install.
all_claim_pairs() {
    local t claim other
    for t in $(tool_names); do
        for claim in $(claims_of "$t"); do
            for other in $(owners_of "$claim" "$t"); do
                # print each unordered pair once
                [[ "$t" < "$other" ]] && echo "${claim%%:*} $t $other ${claim#*:}"
            done
        done
    done | sort -u
}
