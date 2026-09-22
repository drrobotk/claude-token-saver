# token-saver

One conflict-aware toggle for the whole Claude Code token-saving stack.

There are a lot of good tools that cut Claude Code's token use — output filters, compression proxies, context gateways, code graphs, memory plugins. Installing several is easy. Knowing which of them are fighting each other, and getting back to a working setup when one of them breaks your CLI, is not.

`token-saver` installs them, toggles them, and refuses to let two tools own the same thing.

```
$ token-saver
token-saver v1.0.0  (cwd: ~/work/api)
TOOL                 STATE    BEST  NOTE
-----------------------------------------------------------------------
 tool-search         on       *     Defer MCP tool schemas until called
 lean-settings       off            Park per-call hooks that cost time and context
 rtk                 on       *     Rust CLI output compression via PreToolUse hook
 caveman             on       *     Terse assistant output style
 context-mode        on       *     Sandboxes verbose tool output outside context
 token-optimizer     off            HARD:context-mode | Caches and compresses repeated payloads
 code-review-graph   on       *     Tree-sitter knowledge graph of the repo
 serena              off            LSP symbol-level code retrieval and editing
 claude-mem          on       *     Cross-session memory so you re-explain less
 headroom            off            Local compression proxy in front of the API
 ...
```

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/drrobotk/claude-token-saver/main/install.sh | bash
```

That installs the CLI and nothing else. It does not touch `~/.claude` until you ask it to.

```bash
token-saver                 # what you have, and what is conflicting
token-saver conflicts       # which tools can never run together, before you install
token-saver install best    # install and enable the curated stack
token-saver doctor          # check for live interference
```

Requires `bash`, `git` and `python3`. Tested on macOS and Linux.

### Install with Claude Code

If you already have Claude Code, paste this and let it do the work:

> Install token-saver from https://github.com/drrobotk/claude-token-saver by running its install.sh, then add `~/.local/bin` to my PATH in my shell profile if it isn't already there. Then run `token-saver conflicts` and `token-saver` and show me the output. Read the NOTE column and tell me which of the tools I already have installed are overlapping or conflicting, and which of the curated-stack tools I am missing. Do not enable or install anything yet — recommend an order and wait for me to confirm. When I confirm, run `token-saver install best`, then `token-saver doctor`, and tell me what to restart.

## What it does

**Turning something off is reversible.** `off` never deletes configuration. It moves the tool's MCP server block, hook entries, plugin flags and shell stanzas into `~/.claude/.token-saver-state`, and `on` puts them back byte for byte, in the same scope they came from. Every file is backed up with a timestamp before it is written.

**Turning something on cannot break something else.** Each tool declares the resources it owns. Two tools that want the same exclusive resource can never both be on:

| Resource | Why one owner only |
|---|---|
| `env.ANTHROPIC_BASE_URL` | Two compression proxies, one variable. The second silently takes the route and the first's process lingers. |
| `hook.PreToolUse.Bash` | Two command rewriters means the second rewrites the first one's output, or drops its filtering. |
| `mcp.gateway` | A gateway rewrites the whole `mcpServers` block. Two of them and the loser's servers vanish on the next write. |
| `settings.hooks` | Bulk hook editing. `lean-settings` must never park a hook belonging to a tool that is currently on. |

Ports are deliberately *not* declared: they are per-profile and configurable, so a number in the registry would go stale. `doctor` checks the live one instead — a dead port in `ANTHROPIC_BASE_URL` takes Claude Code down entirely.

Conflicts are *derived* from those claims, never hand-listed pair by pair. Add a tool to `lib/registry.psv` and it is checked against every existing tool automatically. `token-saver selftest` fails if the curated stack ever stops being conflict-free.

Overlapping roles — three things all compressing file reads, four things all doing code retrieval — are surfaced as `SOFT` and left to you. They work; you are just paying schema tokens twice for one benefit.

**`doctor` checks what actually happened**, not just what was declared, because tools installed outside token-saver leave their own mess:

- two live owners of one exclusive resource
- `ANTHROPIC_BASE_URL` pointing at a port nothing answers on (the failure that bricks the CLI)
- more than one `PreToolUse` hook rewriting Bash, however it got there
- config files that no longer parse
- a tool reporting `on` while a parked copy of its config is still sitting in the state dir
- many MCP servers configured with `tool-search` off

## Tools

`*` marks the curated stack, which is verified to share no resource at all.

| Tool | What it saves | Kind |
|---|---|---|
| `tool-search` * | Defers MCP tool schemas until a tool is actually called. Recovers 50–70k tokens on heavy MCP setups, costs nothing. | setting |
| `rtk` * | Rewrites Bash commands to compressed equivalents. `npm install` goes from ~4,000 lines to ~15. | hook |
| `caveman` * | Makes the assistant's own output terse without losing technical substance. | plugin |
| `context-mode` * | Keeps verbose tool output outside the context window and passes only the meaningful part. | MCP |
| `code-review-graph` * | Tree-sitter graph of the repo: callers, dependents, impact radius, without reading whole files. | MCP + hooks |
| `graphify` * | Turns any input into a clustered knowledge graph you query instead of re-reading. | skill |
| `claude-mem` * | Cross-session memory, so you stop re-explaining the project every morning. | plugin + worker |
| `markitdown` * | PDF/DOCX/XLSX to lean Markdown instead of raw extraction sludge. | MCP |
| `serena` | Language-server symbol retrieval: one function costs one function, not one file. | MCP |
| `token-optimizer` | Caches and compresses repeated payloads. | MCP |
| `token-reducer` | Local BM25 + vector context compression, no API calls. | plugin |
| `claude-context` | Semantic code search over an indexed codebase. Needs OpenAI and Milvus keys. | MCP |
| `lean-ctx` | Compresses file reads before they land in context. | plugin |
| `ponytail` | YAGNI / minimal-code ruleset injected each turn. | plugin |
| `lean-settings` | Parks per-call hooks that cost wall-clock time and context. | custom |
| `toolhive` | Containerised MCP servers behind a single client registration. | gateway |
| `mcplex` | Semantic MCP gateway: one entry fronting many servers. | gateway |
| `headroom` | Local compression proxy in front of the API. | proxy |
| `claudeslim` | Local proxy compressing API calls. Best with API-key auth. | proxy |
| `token-compression` | RTK-backed MCP payload compression (organisation marketplace). | plugin |

Detail, install notes and the measured tradeoffs are in [docs/TOOLS.md](docs/TOOLS.md).

Some tools ship from private or organisation marketplaces. Those report `absent` and tell you what to run; token-saver manages them from then on.

## Commands

```
token-saver                    status of every tool, with live conflicts
token-saver best               enable the curated, conflict-free stack
token-saver install best       install then enable the whole stack
token-saver install <tool>     install one tool and its prerequisites
token-saver on <tool>          enable one (refuses to break another)
token-saver off <tool>         disable one, parking its config
token-saver off                kill switch — disable everything
token-saver doctor             check for live interference and breakage
token-saver conflicts          the full claim matrix
token-saver selftest           verify the registry and the curated stack
token-saver report             token spend via ccusage
```

`--force` skips confirmation prompts and is required when running non-interactively.

## Measure before you optimise

Every tool in this repo reports how many **tokens** it removed. That is the
wrong denominator, and following it leads you to optimise the cheapest thing on
the bill.

`token-saver cost` prices your actual usage from `~/.claude/projects/*.jsonl` —
the numbers the API itself reported, not an estimate:

```
$ token-saver cost 7

where the money goes
  $  469.25   60.0%  #######################    cache read    re-reading the conversation every turn
  $  212.92   27.2%  ##########                 cache write   rebuilding a prefix that changed
  $   98.90   12.6%  #####                      output        what the model writes
  $    1.08    0.1%                             input         prompt text that was never cached

median context per request: 135,579 tokens
```

That is one real week of heavy use. **87% of the bill was cache traffic and
0.1% was uncached input** — the pool that output filters and compression
proxies target. A proxy reporting "236,000 tokens compressed" was worth $1.18
against a $782 bill.

This does not make prompt-shrinking tools pointless: a token removed early is
never cached and never re-read, so `rtk` and `tool-search` pay off through the
cache pool rather than the input pool. It does mean you should judge them by
what happens to cache volume, and it means the biggest lever is elsewhere.

### The biggest lever: the context window

A `[1m]` context suffix lets a conversation reach 600-800k tokens before
anything compacts it, and every turn after that re-reads all of it. `token-saver
on economy` drops the suffix and pins effort to `high`:

| | before | after |
|---|---|---|
| model | `opus[1m]` | `opus` (200K window) |
| effort | `max` | `high` |

Same model and the same per-turn quality — compaction just happens sooner. It
is fully reversible with `token-saver off economy`, and it deliberately does
**not** switch you to a cheaper model: that is a real decision about your work,
and `token-saver cost` prints per-model spend so you can make it with numbers.

### The biggest lever of all: conversation length

`token-saver cost 7 --sessions` ranks your conversations and shows how cost per
request grows as one goes on:

```
  0-24         179 req   $ 0.1123   ############        1.0x
  275+       3,277 req   $ 0.1887   #####################  1.5x

most expensive conversations   ($798.93 across 11 of them)
  $  354.05  44.3%   1,179 req  $0.3003/req  1049237b
  $  269.89  33.8%   2,495 req  $0.1082/req  aab6f8ce
```

On that week **one conversation was 44% of the bill**, and 72% of all requests
were past turn 275 — where each one costs 1.5x what it costs at the start,
because every turn re-reads the whole prefix.

Starting a fresh conversation between unrelated tasks is worth more than every
tool in this repo combined. No setting can do it for you.

### Cache writes are a config-churn tax

Editing `settings.json` or toggling an MCP server mid-session rebuilds the
cached prefix, and rebuilding costs 1.25x what reading it costs 0.1x. If cache
writes are a large share of your bill, batch config changes between sessions
rather than during one.

## Proxy routing: which sessions get compressed

If you run a compression proxy (`headroom`, `claudeslim`), where its route lives
decides which sessions it applies to, and it is a genuine either/or:

| `token-saver route …` | Compressed | Remote Control |
|---|---|---|
| `settings` | every session, however it was launched | off everywhere |
| `shell` | only sessions started from an interactive shell — not VS Code, an IDE or the Dock | works in the rest |

There is no third option: the proxy is exactly what disables Remote Control.
`settings.json`'s `env` block also overrides the process environment, so under
`route settings` the usual `env -u ANTHROPIC_BASE_URL` escape hatch has nothing
to remove.

The default is `shell`, and the trap it sets is quiet: your IDE sessions run
uncompressed while `status` still says `headroom on`, because a route is
configured *somewhere*. `token-saver doctor` reports which side the current
session is on, and `token-saver route` prints the preference and this session's
actual routing. Sessions already open keep whatever they started with.

## Adding a tool

One line in [`lib/registry.psv`](lib/registry.psv):

```
name|kind|ref|best|claims|description
```

`kind` is `mcp` (drop a server spec in `lib/specs/<name>.json`), `plugin` (`<plugin>@<marketplace>`, repo in `lib/specs/<name>.market`), `env` (`VAR=value`), `hook` (a regex), or `custom` (a module in `lib/tools/<name>.sh` defining any of `state_`, `enable_`, `disable_`, `install_`; anything you omit falls back to the generic behaviour for the kind).

List what it owns in `claims` — `x:` for exclusive, `o:` for an overlapping role. Reuse an existing resource name if it takes the same thing; that is what makes the conflict check work. Then:

```bash
token-saver selftest
```

which fails if your tool is undispatchable, if it cannot report a state, or if it makes the curated stack conflict.

If your tool registers a hook, give the module a `hookpat_<name>` function returning a regex that matches its hook command. That is how `lean-settings` knows not to park it.

## Measuring

Percentage claims in this space are mostly vendor blogs and individual practitioners, not independent benchmarks. Get your own baseline before and after:

- `/context` in Claude Code — live breakdown of what is in the window, with per-element token counts
- `/usage` — which component is spending
- `token-saver report` — spend over time, via [ccusage](https://github.com/ryoppippi/ccusage)

Quality and efficiency are separate axes. A saving that makes the model fail the task is not a saving.

## Safety

- Every write is backup, validate, replace. Backups are timestamped and kept in `~/.claude/.token-saver-state`.
- A lock file prevents two runs from read-modify-writing over each other.
- Proxy tools verify the port answers before they point `ANTHROPIC_BASE_URL` at it, and clear the variable *before* stopping the process on the way down.
- `token-saver off` restores everything to the state it was parked in.

## License

MIT.
