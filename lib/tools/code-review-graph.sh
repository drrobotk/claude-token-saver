#!/usr/bin/env bash
# code-review-graph — persistent Tree-sitter graph of the repo. Answers
# "who calls this / what breaks if I change it" without reading whole files.
# Lives in two places at once (an MCP server in .mcp.json and hooks that keep
# the graph fresh), so both must move together or the hooks rebuild a graph no
# server is serving.

CRG_MCP_BACKUP="$STATE_DIR/crg-mcp.json"
CRG_HOOK_BACKUP="$STATE_DIR/crg-hooks.json"

hookpat_code_review_graph() { echo 'code-review-graph'; }

state_code_review_graph() {
    local live
    live="$(py "
m = load(MCP_JSON)
c = load(CLAUDE_JSON)
hit = 'code-review-graph' in m.get('mcpServers', {}) or 'code-review-graph' in c.get('mcpServers', {})
print('on' if hit else 'off')
")"
    [ "$live" = on ] && { echo on; return; }
    [ -f "$CRG_MCP_BACKUP" ] && echo off || echo absent
}

disable_code_review_graph() {
    backup "$MCP_JSON"; backup "$SETTINGS"
    py "
m = load(MCP_JSON)
srv = m.get('mcpServers', {})
if 'code-review-graph' in srv:
    save(os.path.join(STATE_DIR, 'crg-mcp.json'),
         {'mcpServers': {'code-review-graph': srv.pop('code-review-graph')}})
    m['mcpServers'] = srv
    save(MCP_JSON, m)
s = load(SETTINGS)
hooks = s.get('hooks', {}); parked = {}
for ev in list(hooks):
    keep, drop = [], []
    for e in hooks[ev]:
        cmds = ' '.join(h.get('command', '') for h in e.get('hooks', [])) + ' ' + str(e.get('command', ''))
        (drop if 'code-review-graph' in cmds else keep).append(e)
    if drop: parked[ev] = drop
    if keep: hooks[ev] = keep
    else: del hooks[ev]
if parked: save(os.path.join(STATE_DIR, 'crg-hooks.json'), parked)
s['hooks'] = hooks
save(SETTINGS, s)
print('code-review-graph disabled')
"
}

enable_code_review_graph() {
    [ -f "$CRG_MCP_BACKUP" ] || { err "nothing parked — run: token-saver install code-review-graph"; return 1; }
    backup "$MCP_JSON"; backup "$SETTINGS"
    py "
bk_mcp = os.path.join(STATE_DIR, 'crg-mcp.json')
if os.path.exists(bk_mcp):
    bk = load(bk_mcp)
    m = load(MCP_JSON)
    m.setdefault('mcpServers', {}).update(bk['mcpServers'])
    save(MCP_JSON, m)
    os.remove(bk_mcp)
bk_hooks = os.path.join(STATE_DIR, 'crg-hooks.json')
if os.path.exists(bk_hooks):
    parked = load(bk_hooks)
    s = load(SETTINGS)
    for ev, entries in parked.items():
        existing = s.setdefault('hooks', {}).setdefault(ev, [])
        for e in entries:
            if e not in existing: existing.append(e)
    save(SETTINGS, s)
    os.remove(bk_hooks)
print('code-review-graph enabled')
"
}

install_code_review_graph() {
    if [ -f "$CRG_MCP_BACKUP" ]; then enable_code_review_graph; return; fi
    err "code-review-graph ships as a private/organisation plugin."
    err "Install it with: /plugin marketplace add <your-marketplace> && /plugin install code-review-graph"
    err "token-saver will manage it from then on. Public alternative in the same role: token-saver install serena"
    return 1
}
