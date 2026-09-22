"""Where the money actually goes, from Claude Code's own transcripts.

Every token-saving tool in this repo reports how many *tokens* it removed. That
is the wrong denominator: a token in the cached prefix is re-read on every
subsequent turn, while an uncached input token is read once. On a real week of
heavy use the split came out as 62% cache reads, 26% cache writes, 12% output
and 0.1% uncached input — so "tokens saved" and "money saved" can differ by
three orders of magnitude depending on which pool the token came from.

This reads ~/.claude/projects/*/*.jsonl, which is the usage the API itself
reported, and prices it. No estimates, no sampling.
"""

from __future__ import annotations

import collections
import datetime
import glob
import json
import os
import sys

# Published list prices, $ per million tokens. Cache writes are 1.25x input and
# cache reads 0.1x input, which is why a stable prefix matters so much more
# than a short one.
PRICES = {
    "claude-opus-5":    {"in": 5.00, "out": 25.00},
    "claude-opus-4-8":  {"in": 5.00, "out": 25.00},
    "claude-opus-4-7":  {"in": 5.00, "out": 25.00},
    "claude-opus-4-6":  {"in": 5.00, "out": 25.00},
    "claude-sonnet-5":  {"in": 2.00, "out": 10.00},
    "claude-sonnet-4-6": {"in": 3.00, "out": 15.00},
    "claude-haiku-4-5": {"in": 1.00, "out": 5.00},
    "claude-fable-5-1": {"in": 10.00, "out": 50.00},
    "claude-fable-5":   {"in": 10.00, "out": 50.00},
}
DEFAULT_PRICE = {"in": 5.00, "out": 25.00}


def price_for(model: str) -> dict:
    for name, p in PRICES.items():
        if model.startswith(name):
            return p
    return DEFAULT_PRICE


def cost_of(usage: dict, model: str) -> dict:
    p = price_for(model)
    return {
        "in": usage.get("input_tokens", 0) * p["in"] / 1e6,
        "out": usage.get("output_tokens", 0) * p["out"] / 1e6,
        "cw": usage.get("cache_creation_input_tokens", 0) * p["in"] * 1.25 / 1e6,
        "cr": usage.get("cache_read_input_tokens", 0) * p["in"] * 0.10 / 1e6,
    }


def scan_sessions(days: int) -> dict:
    """Per-conversation cost, and cost per request by position in it.

    Conversations are where the money is: the prefix is re-read every turn, so
    the same question costs more the later you ask it. Measuring that per
    session is the only way to see it — a daily total hides it completely.
    """
    root = os.path.expanduser(os.environ.get("TS_PROJECTS_DIR", "~/.claude/projects"))
    cutoff = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=days)
    sessions: dict[str, list[float]] = collections.defaultdict(list)

    for path in glob.glob(os.path.join(root, "*", "*.jsonl")):
        sid = os.path.basename(path)[:-6]
        try:
            handle = open(path, errors="ignore")
        except OSError:
            continue
        with handle:
            for line in handle:
                if '"usage"' not in line:
                    continue
                try:
                    entry = json.loads(line)
                except ValueError:
                    continue
                message = entry.get("message") or {}
                usage = message.get("usage") or {}
                if not usage:
                    continue
                try:
                    when = datetime.datetime.fromisoformat(
                        entry.get("timestamp", "").replace("Z", "+00:00"))
                except (ValueError, AttributeError):
                    continue
                if when < cutoff:
                    continue
                sessions[sid].append(sum(cost_of(usage, message.get("model", "")).values()))
    return sessions


def report_sessions(days: int) -> None:
    sessions = scan_sessions(days)
    if not sessions:
        print("no conversations found in that window")
        return

    buckets: dict[int, list] = collections.defaultdict(lambda: [0.0, 0])
    for costs in sessions.values():
        for i, c in enumerate(costs):
            b = min(i // 25, 11)
            buckets[b][0] += c
            buckets[b][1] += 1

    print(f"\n\033[1mcost per request, by position in the conversation\033[0m  (last {days} days)\n")
    base = None
    for b in sorted(buckets):
        total, n = buckets[b]
        avg = total / n
        base = avg if base is None else base
        label = f"{b*25}-{b*25+24}" if b < 11 else "275+"
        print(f"  {label:<10}{n:>8,} req   ${avg:>7.4f}   {'#' * int(avg / 0.005):<40} {avg/base:.1f}x")

    ranked = sorted(((sum(c), len(c), s) for s, c in sessions.items()), reverse=True)
    grand = sum(r[0] for r in ranked)
    print(f"\n\033[1mmost expensive conversations\033[0m   (${grand:,.2f} across {len(ranked)} of them)\n")
    for cost, n, sid in ranked[:8]:
        share = 100 * cost / grand if grand else 0
        print(f"  ${cost:>8.2f}  {share:>4.1f}%  {n:>6,} req  ${cost/n:.4f}/req  {sid[:8]}")

    top, topn, _ = ranked[0]
    print(f"\n\033[1mwhat that means\033[0m")
    print(f"  One conversation was {100*top/grand:.0f}% of the bill. Cost per request climbs with")
    print("  conversation length because every turn re-reads the whole prefix, so the")
    print("  same question is cheaper asked early. Starting a fresh conversation between")
    print("  unrelated tasks is worth more than any tool in this repo.")
    print()


def scan(days: int) -> tuple[dict, dict, dict, int]:
    root = os.path.expanduser(os.environ.get("TS_PROJECTS_DIR", "~/.claude/projects"))
    cutoff = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=days)

    by_day: dict[str, collections.Counter] = collections.defaultdict(collections.Counter)
    by_model: dict[str, collections.Counter] = collections.defaultdict(collections.Counter)
    totals = collections.Counter()
    contexts: list[int] = []

    for path in glob.glob(os.path.join(root, "*", "*.jsonl")):
        try:
            handle = open(path, errors="ignore")
        except OSError:
            continue
        with handle:
            for line in handle:
                if '"usage"' not in line:
                    continue
                try:
                    entry = json.loads(line)
                except ValueError:
                    continue
                message = entry.get("message") or {}
                usage = message.get("usage") or {}
                if not usage:
                    continue
                try:
                    when = datetime.datetime.fromisoformat(
                        entry.get("timestamp", "").replace("Z", "+00:00")
                    )
                except (ValueError, AttributeError):
                    continue
                if when < cutoff:
                    continue

                model = message.get("model", "unknown")
                money = cost_of(usage, model)
                day = when.date().isoformat()

                for bucket in (by_day[day], by_model[model], totals):
                    bucket["n"] += 1
                    bucket["in"] += usage.get("input_tokens", 0)
                    bucket["out"] += usage.get("output_tokens", 0)
                    bucket["cw"] += usage.get("cache_creation_input_tokens", 0)
                    bucket["cr"] += usage.get("cache_read_input_tokens", 0)
                    for k, v in money.items():
                        bucket["$" + k] += v
                contexts.append(
                    usage.get("cache_read_input_tokens", 0)
                    + usage.get("cache_creation_input_tokens", 0)
                    + usage.get("input_tokens", 0)
                )

    return by_day, by_model, totals, (sorted(contexts)[len(contexts) // 2] if contexts else 0)


def money(counter: collections.Counter) -> float:
    return sum(counter["$" + k] for k in ("in", "out", "cw", "cr"))


def main(argv: list[str]) -> int:
    args = [a for a in argv[1:] if not a.startswith("-")]
    days = int(args[0]) if args else 7
    if "--sessions" in argv or "-s" in argv:
        report_sessions(days)
        return 0
    by_day, by_model, totals, median_ctx = scan(days)

    if not totals["n"]:
        print("no usage found in ~/.claude/projects for that window")
        return 0

    print(f"\n\033[1mtoken-saver cost\033[0m — last {days} days, from your own transcripts\n")
    print(f"{'date':<12}{'msgs':>7}{'output':>11}{'cache write':>14}{'cache read':>15}{'$':>10}")
    for day in sorted(by_day):
        d = by_day[day]
        print(f"{day:<12}{d['n']:>7,}{d['out']:>11,}{d['cw']:>14,}{d['cr']:>15,}{money(d):>10.2f}")
    print("-" * 69)
    print(f"{'total':<12}{totals['n']:>7,}{totals['out']:>11,}{totals['cw']:>14,}"
          f"{totals['cr']:>15,}{money(totals):>10.2f}")

    total = money(totals)
    print("\n\033[1mwhere the money goes\033[0m")
    labels = {
        "cr": "cache read    re-reading the conversation every turn",
        "cw": "cache write   rebuilding a prefix that changed",
        "out": "output        what the model writes",
        "in": "input         prompt text that was never cached",
    }
    for key in ("cr", "cw", "out", "in"):
        amount = totals["$" + key]
        share = 100 * amount / total if total else 0
        bar = "#" * int(share / 2.5)
        print(f"  ${amount:>8.2f}  {share:>5.1f}%  {bar:<40} {labels[key]}")

    print("\n\033[1mby model\033[0m")
    for model, m in sorted(by_model.items(), key=lambda kv: -money(kv[1])):
        print(f"  {model:<22}{m['n']:>7,} msgs   ${money(m):>8.2f}")

    print(f"\nmedian context per request: {median_ctx:,} tokens")

    # The advice has to follow the measurement, not a prior about which tool is
    # fashionable. Input-token tools are the famous ones and are often noise.
    print("\n\033[1mwhat that means here\033[0m")
    cache_share = 100 * (totals["$cr"] + totals["$cw"]) / total if total else 0
    if cache_share > 60:
        print(f"  {cache_share:.0f}% of the bill is cache traffic, which scales with how big the")
        print("  conversation is and how often its prefix changes — not with how many")
        print("  tokens your prompts contain.")
    if median_ctx > 300_000:
        print(f"  The median request re-reads {median_ctx:,} tokens. A smaller context window")
        print("  caps that: same model, same per-turn quality, compaction sooner.")
        print("  Try:  token-saver economy on")
    if totals["$in"] / total < 0.02 if total else False:
        print(f"  Uncached input is ${totals['$in']:.2f} ({100*totals['$in']/total:.1f}%). Tools that shrink the")
        print("  prompt still pay off — a token removed early is never cached and never")
        print("  re-read — but judge them by cache volume, not by tokens removed.")
    if totals["$cw"] / total > 0.2 if total else False:
        print(f"  Cache writes are ${totals['$cw']:.2f} ({100*totals['$cw']/total:.0f}%): the prefix is being rebuilt a lot.")
        print("  Editing settings.json or toggling an MCP server mid-session does that,")
        print("  so batch config changes between sessions rather than during one.")
    print()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
