#!/usr/bin/env bash
# graphify — a skill, not a server: any input becomes a clustered knowledge
# graph you query instead of re-reading source. "off" moves the skill directory
# and its CLAUDE.md stanza into the state dir so neither costs context.

GRAPHIFY_DIR="$SKILLS_DIR/graphify"
GRAPHIFY_BACKUP="$STATE_DIR/graphify-skill"

state_graphify() {
    if [ -f "$GRAPHIFY_DIR/SKILL.md" ]; then echo on
    elif [ -d "$GRAPHIFY_BACKUP" ]; then echo off
    else echo absent; fi
}

disable_graphify() {
    [ -d "$GRAPHIFY_DIR" ] || { warn "graphify not installed"; return 0; }
    rm -rf "$GRAPHIFY_BACKUP"
    cp -r "$GRAPHIFY_DIR" "$GRAPHIFY_BACKUP"
    rm -rf "$GRAPHIFY_DIR"
    [ -f "$CLAUDE_MD" ] && py "
lines = open(os.path.expanduser('~/.claude/CLAUDE.md')).readlines()
kept, cut, in_section = [], [], False
for line in lines:
    if line.startswith('# graphify'): in_section = True
    elif in_section and line.startswith('# '): in_section = False
    (cut if in_section else kept).append(line)
if cut:
    open(os.path.join(STATE_DIR, 'graphify-claude-md.txt'), 'w').writelines(cut)
    while kept and not kept[-1].strip(): kept.pop()
    open(os.path.expanduser('~/.claude/CLAUDE.md'), 'w').writelines(kept)
"
    ok "graphify disabled"
}

enable_graphify() {
    [ -d "$GRAPHIFY_BACKUP" ] || { err "no parked graphify — run: token-saver install graphify"; return 1; }
    cp -r "$GRAPHIFY_BACKUP" "$GRAPHIFY_DIR"
    rm -rf "$GRAPHIFY_BACKUP"
    if [ -f "$STATE_DIR/graphify-claude-md.txt" ]; then
        printf '\n' >> "$CLAUDE_MD"
        cat "$STATE_DIR/graphify-claude-md.txt" >> "$CLAUDE_MD"
        rm -f "$STATE_DIR/graphify-claude-md.txt"
    fi
    ok "graphify enabled"
}

install_graphify() {
    if [ -d "$GRAPHIFY_BACKUP" ]; then enable_graphify; return; fi
    command -v graphify >/dev/null 2>&1 || {
        command -v pipx >/dev/null 2>&1 || { err "needs pipx: brew install pipx"; return 1; }
        pipx install graphifyy || { err "pipx install graphifyy failed"; return 1; }
    }
    graphify install || { err "graphify install failed"; return 1; }
    ok "graphify installed — use /graphify in Claude Code"
}
