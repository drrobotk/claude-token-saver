# Tools

What each tool does, what it costs, how token-saver manages it, and what it is
allowed to touch. `*` marks a member of the curated stack.

Every entry lists its **claims** — see [the conflict model](#the-conflict-model)
at the bottom for why those matter.

---

## tool-search *

`ENABLE_TOOL_SEARCH=1` in `~/.claude/settings.json`.

Defers MCP tool schemas until a tool is actually called, so only tool *names*
enter the context at session start. On a setup with many servers this is the
single largest recovery available, it is built in, and it costs nothing. If you
change only one thing, change this one.

Claims: none. Install: `token-saver on tool-search`.

Caveat: connecting or disconnecting an MCP server mid-session invalidates the
prompt cache regardless, so toggle servers between sessions, not during one.

---

## rtk *

[Rust Token Killer](https://github.com/rtk-rs). A `PreToolUse` hook rewrites
Bash commands to a compressed `rtk <cmd>` equivalent before they run, so command
output arrives already summarised: `git status` from 119 to 28 characters,
`cargo test` from 155 lines to 3, `npm install` from ~4,000 lines to ~15.

Claims: `x:hook.PreToolUse.Bash`, `o:cli-output`. Only one thing may rewrite
Bash. A second rewriter receives an already-rewritten command and either
double-wraps it or drops the first one's filtering.

Install: `token-saver install rtk` (brew or cargo, then `rtk init -g
--auto-patch`). Disabling parks the hook entry; it takes effect on the next Bash
call, because a live session holds the old hook in memory.

Verify it is actually working with `rtk gain`. A registered hook that reports
0% savings usually means the hook exists in a backup but not in live settings.

---

## caveman *

[JuliusBrussee/caveman](https://github.com/JuliusBrussee/caveman). Compresses
the assistant's own output — drops articles, filler and hedging while keeping
every technical detail, code block and error string intact. Output tokens are
the cheapest thing to cut because nothing downstream depends on the prose.

Claims: `o:terse-style`. Install: `token-saver install caveman`.

---

## ponytail

A YAGNI / minimal-code ruleset injected each turn and into subagents. Cuts the
amount of speculative code generated, which cuts both output and the reading of
it later.

Claims: `o:terse-style` — overlaps caveman. Both work together; you are paying
for two rule injections that pull in the same direction.

Install: no canonical public marketplace at time of writing. Add yours with
`/plugin marketplace add <repo>` and token-saver will manage it from then on.

---

## context-mode *

MCP server (`npx -y context-mode`). Intercepts verbose tool output, keeps it
outside the context window, and passes through only the part that matters,
maintaining a running session log you can query.

Claims: `o:ctx-compress`. Pairs well with rtk: rtk handles shell output,
context-mode handles MCP output.

Install: `token-saver install context-mode`.

---

## token-optimizer

MCP server (`@ooples/token-optimizer-mcp`). Caches and compresses repeated
payloads so the same file content does not enter input tokens 18 times in a
20-turn session.

Claims: `o:ctx-compress`. Running it alongside context-mode and lean-ctx means
three servers' schemas for one benefit.

---

## lean-ctx

[yvgude/lean-ctx](https://github.com/yvgude/lean-ctx). Compresses file reads
before they land in context.

Claims: `o:ctx-compress`.

Install the plugin, not `lean-ctx onboard` — that adds a zsh hook that collides
with rtk's Bash rewriting.

---

## code-review-graph *

Persistent Tree-sitter knowledge graph of the repository: callers, callees,
imports, tests, impact radius, architecture overview. Answers "what breaks if I
change this" without reading whole files, which is where most read-tokens go.

Claims: `o:code-retrieval`. Lives in two places at once — an MCP server in
`.mcp.json` and hooks that keep the graph fresh — so token-saver moves both
together. Parking only one leaves hooks rebuilding a graph no server is serving.

Ships from an organisation marketplace. It reports `absent` until installed;
`serena` is the public tool in the same role.

---

## serena

[oraios/serena](https://github.com/oraios/serena). Language-server-backed
symbol-level retrieval and editing across 40+ languages. Asking for one function
costs one function instead of one file.

Claims: `o:code-retrieval`.

Install: `token-saver install serena` — `uv tool install -p 3.13 serena-agent`,
`serena init`, then `claude mcp add --scope user serena -- serena
start-mcp-server --context claude-code --project-from-cwd`.

Upstream explicitly asks you not to install it from an MCP or plugin
marketplace, as those carry outdated commands. token-saver uses the documented
path. If startup is slow, raise `MCP_TIMEOUT` in your shell profile.

---

## token-reducer

[Madhan230205/token-reducer](https://github.com/Madhan230205/token-reducer).
Local-first context compression — SQLite FTS5/BM25 plus vector search,
tree-sitter AST chunking, TextRank compression, import graph, 2-hop symbol
expansion. Runs entirely locally, no API calls. ML dependencies are optional;
without them it falls back to hash embeddings and regex chunking.

Claims: `o:code-retrieval`. Install: `token-saver install token-reducer`.

---

## claude-context

[zilliztech/claude-context](https://github.com/zilliztech/claude-context).
Semantic code search MCP over an indexed codebase.

Claims: `o:code-retrieval`.

Needs `OPENAI_API_KEY`, `MILVUS_ADDRESS` and `MILVUS_TOKEN` in your environment
and Node >= 20. The spec references those variables rather than storing them, so
nothing lands in a config file. Off the curated stack because it costs money and
needs an account.

---

## graphify *

A skill, not a server: turns any input — code, docs, papers, images — into a
clustered knowledge graph with an HTML/JSON output and an audit report, which
you query instead of re-reading the source.

Claims: none. Disabling moves the skill directory *and* its `CLAUDE.md` stanza
into the state dir, so neither costs context while off.

Install: `pipx install graphifyy && graphify install`.

---

## claude-mem *

[thedotmack/claude-mem](https://github.com/thedotmack/claude-mem). Cross-session
memory: observations from past sessions are searchable, so you stop re-explaining
the project at the start of every one.

Claims: `o:memory`. Plugin state plus a background worker that does the
summarising, so `off` stops the worker too — otherwise it keeps indexing
sessions you told it to stop watching.

---

## markitdown *

Microsoft MarkItDown as an MCP server (`uvx markitdown-mcp`). Converts PDF,
DOCX, XLSX, PPTX and more to lean Markdown rather than raw extraction sludge.

Claims: none.

---

## lean-settings

Not a third-party tool — token-saver's own. Parks hook entries that fire on
every tool call, each of which costs wall-clock time and context.

Claims: `x:settings.hooks`. This is the one tool that edits other tools'
configuration, so it must never park a hook belonging to a token-saver tool that
is currently on — that would leave the tool reporting `on` with its hook sitting
in a backup file. The keep-list is built at runtime from the `hookpat_*`
function of every enabled tool, not from a hard-coded string.

Add your own patterns with `TS_LEAN_KEEP='regex'`.

---

## toolhive

[stacklok/toolhive](https://github.com/stacklok/toolhive). Runs MCP servers in
containers behind a single client registration, so the client sees one entry
instead of N schema dumps.

Claims: `x:mcp.gateway`. Needs a container runtime — Docker or Podman. Without
one it can list config but cannot run a server, which token-saver reports rather
than showing a bare `on`.

---

## mcplex

Semantic MCP gateway: one client entry fronts every server and surfaces only the
tools a prompt actually needs.

Claims: `x:mcp.gateway`. Enabling it rewrites every entry in `~/.claude.json`,
so token-saver snapshots the whole file first and restores it verbatim on `off`.
A partial restore of a swapped config is worse than no gateway at all.

Ships as a release binary: download to `~/bin/mcplex`, `chmod +x`, then
`token-saver on mcplex`.

---

## headroom

**The route's location decides which sessions are compressed.** In your shell
profile it is picked up only by sessions launched from an interactive shell; a
session started by VS Code, an IDE or the Dock never sources that profile, so
it talks to the API directly — uncompressed, with Remote Control working. In
`settings.json` it applies to every session, and Remote Control is off
everywhere. There is no arrangement that gives you both in one session: the
proxy is exactly what disables Remote Control. `doctor` reports which side of
that split the current session is on, because "headroom on" cannot.

Also: enabling it moves the proxy route out of `settings.json` and into your
shell profile, so `env -u ANTHROPIC_BASE_URL claude --remote-control` still
works — `token-saver rc` does exactly that, and `token-saver rc install` adds a
`claude-rc()` function. A route in `settings.json` cannot be dropped per
session, because that file's `env` block overrides the process environment.

[chopratejas/headroom](https://github.com/chopratejas/headroom). A compression
proxy between Claude Code and the API.

Claims: `x:env.ANTHROPIC_BASE_URL`, `o:memory`.

The hazards, all handled:

- `off` must remove the routing **and** stop the process. A base URL pointing at
  a dead port breaks Claude Code completely, so `on` verifies the port answers
  before claiming success and `doctor` re-checks it live.
- Its durable hooks re-install the config on every session start, so they are
  parked too — and you must restart Claude Code after disabling, because a live
  session still holds the hook in memory.
- `headroom init` writes profiles with `proxy_mode=token` and telemetry on,
  which leaks into the shell env block. token-saver forces every profile to
  cache mode with telemetry off, and restores the shell stanza verbatim so the
  mode cannot drift.

Measured tradeoff worth knowing before you enable it: on one internal three-task
benchmark, ~41–48% token reduction at +64% to +128% wall-clock time. That is why
it is off the curated stack.

Behind a corporate TLS interceptor it needs a CA bundle to reach HuggingFace for
its compression model; set `SSL_CERT_FILE` / `REQUESTS_CA_BUNDLE` before
installing.

---

## claudeslim

[ClaudeSlim](https://github.com/buzzlair/ClaudeSlim). Local proxy that
intercepts and compresses API calls, reported at 60–85%.

Claims: `x:env.ANTHROPIC_BASE_URL` — mutually exclusive with headroom.

Reported to be incompatible with OAuth (subscription) authentication; works best
with API-key auth. token-saver clears the base URL *before* killing the process
on the way down, so a failed shutdown cannot leave you routed at a dead port.

---

## token-compression

RTK-backed MCP payload compression, shipped from an organisation marketplace.

Claims: `x:hook.PreToolUse.Bash`, `o:cli-output` — mutually exclusive with rtk,
which does the same job through the same hook.

---

# The conflict model

Each tool declares what it takes ownership of:

- `x:<resource>` — **exclusive**. Two live owners break each other. token-saver
  refuses to enable the second and offers to disable the first.
- `o:<role>` — **overlapping**. Both run correctly, but you are paying twice for
  one benefit, usually in MCP schema tokens. token-saver warns and leaves the
  decision to you.

Conflicts are derived from these claims. Nothing is hand-paired, so a tool added
to the registry is automatically checked against every existing tool, and the
curated stack is *verified* conflict-free by `token-saver selftest` rather than
assumed to be.

Resource names currently in use:

| Resource | Owners |
|---|---|
| `x:env.ANTHROPIC_BASE_URL` | headroom, claudeslim |
| `x:hook.PreToolUse.Bash` | rtk, token-compression |
| `x:mcp.gateway` | toolhive, mcplex |
| `x:settings.hooks` | lean-settings |
| `o:cli-output` | rtk, token-compression |
| `o:ctx-compress` | context-mode, token-optimizer, lean-ctx |
| `o:code-retrieval` | code-review-graph, serena, token-reducer, claude-context |
| `o:terse-style` | caveman, ponytail |
| `o:memory` | claude-mem, headroom |

Run `token-saver conflicts` for the live matrix, and `token-saver doctor` for
what has actually gone wrong.
