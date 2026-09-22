#!/usr/bin/env bash
# economy — the cost profile, aimed at what `token-saver cost` actually measures.
#
# On a real week of heavy use the bill split 60% cache reads, 27% cache writes,
# 13% output, 0.1% uncached input. Every other tool here shrinks the prompt;
# that pool is the 0.1%. What drives the other 87% is how many tokens get
# re-read on every single turn, and that is a function of the context window.
#
# So this profile changes two things and nothing else:
#
#   model       drops a [1m] context suffix. A 1M window lets a conversation
#               reach 600-800k tokens before anything compacts it, and every
#               turn after that re-reads all of it at the cache-read rate. The
#               200k window caps that. Same model, same per-turn quality —
#               compaction simply happens sooner.
#
#   effort      pins "high" rather than "max". Anthropic's own guidance puts
#               high at the quality/efficiency sweet spot; max is for when
#               correctness matters more than cost.
#
# It deliberately does NOT switch you to a cheaper model. That is a real
# quality decision about your work, and it is yours to make — `token-saver
# cost` prints the per-model spend so you can make it with numbers.

ECONOMY_BACKUP="$STATE_DIR/economy.json"

state_economy() { [ -f "$ECONOMY_BACKUP" ] && echo on || echo off; }

note_economy() {
    local model; model="$(py "print(load(SETTINGS).get('model',''))" 2>/dev/null)"
    case "$model" in
        *"[1m]"*) echo "1M context: every turn re-reads up to 1M tokens" ;;
    esac
}

enable_economy() {
    [ -f "$ECONOMY_BACKUP" ] && { warn "economy already on"; return 0; }
    backup "$SETTINGS"
    py "
s = load(SETTINGS)
before = {'model': s.get('model'), 'effortLevel': s.get('effortLevel')}
save(os.path.join(STATE_DIR, 'economy.json'), before)

model = s.get('model') or ''
changed = []
if '[1m]' in model:
    s['model'] = model.replace('[1m]', '')
    changed.append('context window 1M -> 200K (%s -> %s)' % (model, s['model']))
if s.get('effortLevel') != 'high':
    was = s.get('effortLevel', 'default')
    s['effortLevel'] = 'high'
    changed.append('effort %s -> high' % was)
save(SETTINGS, s)
if changed:
    for c in changed:
        print('  ' + c)
else:
    print('  already economical: no [1m] suffix and effort already high')
"
    ok "economy on — restart Claude Code; open sessions keep their current window."
    info "  Reverse with: token-saver off economy"
}

disable_economy() {
    [ -f "$ECONOMY_BACKUP" ] || { warn "economy already off"; return 0; }
    backup "$SETTINGS"
    py "
before = load(os.path.join(STATE_DIR, 'economy.json'))
s = load(SETTINGS)
for key, value in before.items():
    if value is None:
        s.pop(key, None)
    else:
        s[key] = value
save(SETTINGS, s)
os.remove(os.path.join(STATE_DIR, 'economy.json'))
print('  restored model=%s effort=%s' % (before.get('model'), before.get('effortLevel')))
"
    ok "economy off — restart Claude Code."
}

install_economy() { enable_economy; }
