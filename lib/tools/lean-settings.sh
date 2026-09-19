#!/usr/bin/env bash
# lean-settings — park hooks that fire on every tool call.
#
# Interference note: this is the one tool that edits other tools' config, so it
# claims x:settings.hooks. It must never park a hook belonging to a token-saver
# tool that is currently ON — doing so would leave that tool reporting "on"
# while its hook sits in a backup file. The keep-list is therefore built from
# the live registry (hookpat_* in each module), not from a hard-coded string.

LEAN_PARKED="$STATE_DIR/lean-settings.json"

# Regex union of the hook signatures owned by every currently-enabled tool.
_lean_keep_pattern() {
    local t fn pats=() pat
    load_all_modules
    for t in $(tool_names); do
        [ "$t" = lean-settings ] && continue
        fn="$(fn_name "$t")"
        declare -f "hookpat_$fn" >/dev/null 2>&1 || continue
        [ "$(tool_state "$t")" = on ] || continue
        pat="$("hookpat_$fn")"
        [ -n "$pat" ] && pats+=("$pat")
    done
    [ -n "${TS_LEAN_KEEP:-}" ] && pats+=("$TS_LEAN_KEEP")
    local IFS='|'; printf '%s' "${pats[*]}"
}

state_lean_settings() { [ -f "$LEAN_PARKED" ] && echo on || echo off; }

enable_lean_settings() {
    [ -f "$LEAN_PARKED" ] && { warn "lean-settings already on"; return 0; }
    local keep; keep="$(_lean_keep_pattern)"
    info "  keeping hooks owned by enabled tools: ${keep:-<none>}"
    backup "$SETTINGS"
    TS_LEAN_PATTERN="$keep" py "
import re
keep_src = os.environ.get('TS_LEAN_PATTERN', '')
keep = re.compile(keep_src) if keep_src else None
s = load(SETTINGS)
hooks = s.get('hooks', {})
parked = {}
for ev in list(hooks):
    stay, park = [], []
    for e in hooks[ev]:
        cmds = ' '.join(h.get('command', '') for h in e.get('hooks', [])) + ' ' + str(e.get('command', ''))
        (stay if (keep and keep.search(cmds)) else park).append(e)
    if park: parked[ev] = park
    if stay: hooks[ev] = stay
    else: del hooks[ev]
if not parked:
    print('nothing to park — settings.json has no removable hooks'); raise SystemExit
save(os.path.join(STATE_DIR, 'lean-settings.json'), parked)
s['hooks'] = hooks
save(SETTINGS, s)
n = sum(len(v) for v in parked.values())
print('lean-settings on — parked %d hook entr%s' % (n, 'y' if n == 1 else 'ies'))
"
}

disable_lean_settings() {
    [ -f "$LEAN_PARKED" ] || { warn "lean-settings already off"; return 0; }
    backup "$SETTINGS"
    py "
path = os.path.join(STATE_DIR, 'lean-settings.json')
parked = load(path)
s = load(SETTINGS)
for ev, entries in parked.items():
    existing = s.setdefault('hooks', {}).setdefault(ev, [])
    for e in entries:
        if e not in existing:   # a tool may have re-registered its own hook meanwhile
            existing.append(e)
save(SETTINGS, s)
os.remove(path)
print('lean-settings off — hooks restored')
"
}

install_lean_settings() { enable_lean_settings; }
