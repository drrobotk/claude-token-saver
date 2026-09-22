#!/usr/bin/env bash
# headroom — a compression proxy that sits between Claude Code and the API.
#
# Claims x:env.ANTHROPIC_BASE_URL. Two proxies cannot both own
# the base URL, and "off" must remove the routing AND stop the process: leaving
# ANTHROPIC_BASE_URL pointed at a dead port breaks Claude Code completely. Its
# durable hooks re-install the config on every session start, so they come out
# too, and the shell env block is saved verbatim so proxy mode cannot drift.

HEADROOM_BIN="${TS_HEADROOM_BIN:-$(command -v headroom || echo "$HOME/.local/bin/headroom")}"
HEADROOM_HOME="$HOME/.headroom"
HEADROOM_BACKUP="$STATE_DIR/headroom.json"
SHELL_RC="${TS_SHELL_RC:-$HOME/.zshrc}"

hookpat_headroom() { echo 'headroom'; }

# Where the route lives matters more than that it exists — see _headroom_route.
_headroom_url_settings() { py "print(load(SETTINGS).get('env', {}).get('ANTHROPIC_BASE_URL', ''))"; }
_headroom_url_shell() {
    [ -f "$SHELL_RC" ] || return 0
    sed -n 's/^[[:space:]]*export ANTHROPIC_BASE_URL=["'"'"']\{0,1\}\([^"'"'"']*\).*/\1/p' "$SHELL_RC" | tail -1
}
_headroom_url() {
    local u; u="$(_headroom_url_settings)"
    [ -n "$u" ] && { printf '%s' "$u"; return; }
    _headroom_url_shell
}

state_headroom() {
    [ -x "$HEADROOM_BIN" ] || { echo absent; return; }
    [ -n "$(_headroom_url)" ] && echo on || echo off
}

# Where the proxy route lives decides which sessions are compressed, and it is
# a real either/or:
#
#   settings  ~/.claude/settings.json env. Read by EVERY session however it was
#             launched — VS Code, an IDE, the Dock, a terminal. That block also
#             overrides the process environment, so Remote Control cannot be
#             recovered per session: `env -u ANTHROPIC_BASE_URL` has nothing to
#             remove. Everything is compressed; Remote Control is off.
#
#   shell     an export in your shell profile. Only sessions launched from an
#             interactive shell pick it up; a GUI-launched session never sources
#             it and runs uncompressed with Remote Control working.
#
# There is no third option: the proxy is exactly what disables Remote Control.
# The preference is stored rather than inferred, because both "my IDE isn't
# being compressed" and "Remote Control stopped working" are states a user can
# arrive at by accident and then not be able to explain.
ROUTE_PREF_FILE="$STATE_DIR/headroom-route"
DEFAULT_ROUTE=shell

_headroom_route_pref() {
    if [ -n "${TS_HEADROOM_ROUTE:-}" ]; then printf '%s' "$TS_HEADROOM_ROUTE"; return; fi
    if [ -f "$ROUTE_PREF_FILE" ]; then tr -d '[:space:]' < "$ROUTE_PREF_FILE"; return; fi
    printf '%s' "$DEFAULT_ROUTE"
}

_headroom_set_route_pref() {
    printf '%s\n' "$1" > "$ROUTE_PREF_FILE"
}

# Put the route where the preference says it belongs, and take it out of the
# other place. Leaving a copy behind is how you end up unable to tell which one
# is in force.
_headroom_apply_route() {
    local pref url
    pref="$(_headroom_route_pref)"
    url="$(_headroom_url)"
    [ -n "$url" ] || return 0

    if [ "$pref" = settings ]; then
        env_set ANTHROPIC_BASE_URL "$url" >/dev/null
        ok "  every session is routed through $url, however it is launched"
        info "  Remote Control is off while this is set; token-saver route shell reverses it."
        info "  Sessions already open keep their old routing — restart them to pick this up."
        return 0
    fi

    # shell: the settings copy must go, or it would win and nothing would change
    if [ -n "$(_headroom_url_settings)" ]; then
        env_unset ANTHROPIC_BASE_URL >/dev/null
    fi
    if [ "$(_headroom_url_shell)" = "$url" ]; then
        info "  route exported from $(basename "$SHELL_RC"); no settings.json copy"
    else
        printf '\n# Added by token-saver: keep the proxy route in the shell, not in\n# settings.json, so `env -u ANTHROPIC_BASE_URL claude --remote-control` works.\nexport ANTHROPIC_BASE_URL="%s"\n' "$url" >> "$SHELL_RC"
        info "  moved the route to $(basename "$SHELL_RC") — open a new shell for it to apply"
    fi
    ok "  Remote Control is reachable: env -u ANTHROPIC_BASE_URL claude --remote-control"
    warn "  sessions launched outside a shell (VS Code, the Dock) are NOT compressed;"
    warn "  token-saver route settings compresses those too, at the cost of Remote Control."
}

# Kept as the name the enable paths call.
_headroom_route_via_shell() { _headroom_apply_route; }

# The mirror of the above. Moving the route to the shell means "off" has to take
# it out of the shell too — a leftover export points every NEW shell at a proxy
# that is no longer running, which is the one failure that breaks Claude Code
# outright. Removed unconditionally, whichever way the route was written.
_headroom_unroute_shell() {
    [ -f "$SHELL_RC" ] || return 0
    TS_SHELL_RC="$SHELL_RC" py "
import re
z = os.environ['TS_SHELL_RC']
t = open(z).read()
orig = t
# the stanza token-saver appends, comments and all
t = re.sub(r'\n*# Added by token-saver: keep the proxy route[^\n]*\n(?:#[^\n]*\n)*export ANTHROPIC_BASE_URL=[^\n]*\n', '\n', t)
# and any bare export left by an earlier setup
t = re.sub(r'\n?^[ \t]*export ANTHROPIC_BASE_URL=[^\n]*\n', '\n', t, flags=re.M)
if t != orig:
    open(os.path.join(STATE_DIR, 'headroom-route-shell.txt'), 'w').write(orig)
    open(z, 'w').write(t)
    print('  removed the proxy export from ' + os.path.basename(z) + ' (previous file saved in the state dir)')
"
}

_headroom_profiles() {
    [ -d "$HEADROOM_HOME/deploy" ] || return
    local d
    for d in "$HEADROOM_HOME/deploy"/*/; do [ -d "$d" ] && basename "$d"; done
}

# The 'default' profile is supervised by a launchd job that revives the proxy
# every 300s, so `install stop` refuses to touch it — bootout the job first.
_headroom_stop() {
    local uid p plist pidfile; uid="$(id -u)"
    for p in $(_headroom_profiles); do
        plist="$HOME/Library/LaunchAgents/com.headroom.$p.plist"
        [ -f "$plist" ] && launchctl bootout "gui/$uid/com.headroom.$p" >/dev/null 2>&1
        "$HEADROOM_BIN" install stop --profile "$p" >/dev/null 2>&1
        pidfile="$HEADROOM_HOME/deploy/$p/runner.pid"
        [ -f "$pidfile" ] && kill "$(cat "$pidfile")" >/dev/null 2>&1
    done
    sleep 1
    pkill -f "headroom.cli proxy" >/dev/null 2>&1
    return 0
}

_headroom_start() {
    local uid p plist; uid="$(id -u)"
    for p in $(_headroom_profiles); do
        plist="$HOME/Library/LaunchAgents/com.headroom.$p.plist"
        if [ -f "$plist" ]; then
            launchctl bootstrap "gui/$uid" "$plist" >/dev/null 2>&1
            launchctl kickstart "gui/$uid/com.headroom.$p" >/dev/null 2>&1
            return 0
        fi
    done
    for p in $(_headroom_profiles); do
        "$HEADROOM_BIN" install start --profile "$p" >/dev/null 2>&1
        return 0
    done
}

# `headroom init` writes profiles with proxy_mode=token and telemetry ON, which
# then leaks into the shell env block. Force every profile to the deployed one.
_headroom_align_profiles() {
    py "
import glob
for p in glob.glob(os.path.expanduser('~/.headroom/deploy/*/manifest.json')):
    m = load(p)
    if m.get('proxy_mode') == 'cache' and m.get('telemetry_enabled') is False: continue
    m['proxy_mode'] = 'cache'; m['telemetry_enabled'] = False
    be = m.setdefault('base_env', {})
    be['HEADROOM_MODE'] = 'cache'; be['HEADROOM_TELEMETRY'] = 'off'
    save(p, m)
"
}

disable_headroom() {
    [ -x "$HEADROOM_BIN" ] || { warn "headroom not installed"; return 0; }
    # Save the shell env block before stopping: `install stop` strips it.
    TS_SHELL_RC="$SHELL_RC" py "
import re
z = os.environ['TS_SHELL_RC']
try: t = open(z).read()
except FileNotFoundError: raise SystemExit
m = re.search(r'\n?# >>> headroom persistent env >>>.*?# <<< headroom persistent env <<<\n?', t, re.S)
if m:
    open(os.path.join(STATE_DIR, 'headroom-shellrc.txt'), 'w').write(m.group(0))
    open(z, 'w').write(t[:m.start()] + t[m.end():])
"
    _headroom_unroute_shell
    _headroom_stop
    backup "$SETTINGS"; backup "$CLAUDE_JSON"
    py "
bk = {}
s = load(SETTINGS)
env = s.get('env', {})
if 'ANTHROPIC_BASE_URL' in env:
    bk['env'] = {'ANTHROPIC_BASE_URL': env.pop('ANTHROPIC_BASE_URL')}
    if env: s['env'] = env
    else: s.pop('env', None)
hooks = s.get('hooks', {}); bk_hooks = {}
for ev in list(hooks):
    keep, drop = [], []
    for e in hooks[ev]:
        cmds = ' '.join(h.get('command', '') for h in e.get('hooks', []))
        (drop if 'headroom' in cmds else keep).append(e)
    if drop: bk_hooks[ev] = drop
    if keep: hooks[ev] = keep
    else: del hooks[ev]
if bk_hooks: bk['hooks'] = bk_hooks
plugins = s.get('enabledPlugins', {})
for k in [k for k in plugins if 'headroom' in k]:
    bk.setdefault('enabledPlugins', {})[k] = plugins.pop(k)
mkts = s.get('extraKnownMarketplaces', {})
for k in [k for k in mkts if 'headroom' in k]:
    bk.setdefault('extraKnownMarketplaces', {})[k] = mkts.pop(k)
save(SETTINGS, s)
c = load(CLAUDE_JSON)
srv = c.get('mcpServers', {})
if 'headroom' in srv:
    bk['mcpServer'] = {'headroom': srv.pop('headroom')}
    save(CLAUDE_JSON, c)
save(os.path.join(STATE_DIR, 'headroom.json'), bk)
print('headroom disabled — base URL removed and proxy stopped')
"
    warn "Restart Claude Code now: a live session still holds headroom's durable hook"
    warn "in memory and will re-install it on the next tool call."
}

enable_headroom() {
    [ -x "$HEADROOM_BIN" ] || { err "headroom not installed — run: token-saver install headroom"; return 1; }
    if [ ! -f "$HEADROOM_BACKUP" ]; then
        info "no parked config — rebuilding via headroom's own installers"
        "$HEADROOM_BIN" deploy --no-docker --memory --no-telemetry >/dev/null 2>&1
        "$HEADROOM_BIN" init --global --memory claude >/dev/null 2>&1
        _headroom_align_profiles
        repair_settings
        _headroom_start
        _headroom_route_via_shell
        _headroom_verify
        return
    fi
    backup "$SETTINGS"; backup "$CLAUDE_JSON"
    py "
bk = load(os.path.join(STATE_DIR, 'headroom.json'))
s = load(SETTINGS)
s.setdefault('env', {}).update(bk.get('env', {}))
for ev, entries in bk.get('hooks', {}).items():
    s.setdefault('hooks', {}).setdefault(ev, []).extend(entries)
s.setdefault('enabledPlugins', {}).update(bk.get('enabledPlugins', {}))
s.setdefault('extraKnownMarketplaces', {}).update(bk.get('extraKnownMarketplaces', {}))
save(SETTINGS, s)
if 'mcpServer' in bk:
    c = load(CLAUDE_JSON)
    c.setdefault('mcpServers', {}).update(bk['mcpServer'])
    save(CLAUDE_JSON, c)
os.remove(os.path.join(STATE_DIR, 'headroom.json'))
print('headroom config restored')
"
    # Restore the shell env block verbatim so proxy mode / telemetry cannot drift
    TS_SHELL_RC="$SHELL_RC" py "
z = os.environ['TS_SHELL_RC']
bk = os.path.join(STATE_DIR, 'headroom-shellrc.txt')
if os.path.exists(bk):
    block = open(bk).read()
    t = open(z).read() if os.path.exists(z) else ''
    if 'headroom persistent env' not in t:
        open(z, 'a').write(block if block.startswith('\n') else '\n' + block)
    os.remove(bk)
"
    _headroom_align_profiles
    repair_settings
    _headroom_start
    _headroom_route_via_shell
    _headroom_verify
}

# A base URL pointing at a port nothing is listening on bricks Claude Code, so
# never leave `on` claiming success without a live answer on the other end.
_headroom_verify() {
    local url waited=0
    url="$(_headroom_url)"
    if [ -z "$url" ]; then err "headroom did not set ANTHROPIC_BASE_URL"; return 1; fi
    while [ "$waited" -lt 30 ]; do
        if curl -fsS -m2 "$url/health" >/dev/null 2>&1 || curl -fsS -m2 "$url" >/dev/null 2>&1; then
            ok "headroom on — proxy answering at $url"
            return 0
        fi
        sleep 3; waited=$((waited + 3))
    done
    err "ANTHROPIC_BASE_URL is set to $url but nothing answers there."
    err "Claude Code will fail to reach the API. Fix or run: token-saver off headroom"
    return 1
}

install_headroom() {
    if [ -x "$HEADROOM_BIN" ]; then info "headroom already installed"; else
        command -v uv >/dev/null 2>&1 || { err "needs uv: curl -LsSf https://astral.sh/uv/install.sh | sh"; return 1; }
        uv tool install 'headroom-ai[all]' || { err "uv tool install headroom-ai failed"; return 1; }
        HEADROOM_BIN="$(command -v headroom || echo "$HOME/.local/bin/headroom")"
    fi
    enable_headroom
}
