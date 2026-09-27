#!/usr/bin/env python3
"""
Ingest a pasted DropChanceTooltip "gaps" block (from `/dct gaps export` in-game) and append any new
npc/item ids to the scraper's hit lists. This is the consolidation half of the collector: players
paste their in-game export into a GitHub issue (ISSUE_TEMPLATE/gaps.yml); a workflow feeds the issue
body to this script, which merges the ids into tools/scrape_npcs.txt and tools/scrape_ids.txt so a
later `wowhead_scrape.py` run covers everything gathered across sessions/players. (Modelled on
ForeverVO's issue-template -> paste-string -> GH-automation flow.)

The export block has lines like:
    npc:1782  Moonrage Whitescalp  [Silverpine Forest]  lvl12  x5  (2026-09-27)
    item:3157  Darksoul Shackle  x2  (2026-09-27)
Only the leading `npc:<id>` / `item:<id>` token is authoritative; the rest is human context. We keep
each list sorted+deduped and preserve any leading `#` comment lines already in the file.

Usage:
    python3 tools/ingest_gaps.py < body.txt          # read block from stdin
    python3 tools/ingest_gaps.py --body-file b.txt
    python3 tools/ingest_gaps.py --selftest
"""
import argparse
import os
import re
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
NPCS_OUT = os.path.join(SCRIPT_DIR, "scrape_npcs.txt")
IDS_OUT = os.path.join(SCRIPT_DIR, "scrape_ids.txt")

NPC_RE = re.compile(r"^\s*npc:(\d+)", re.MULTILINE)
ITEM_RE = re.compile(r"^\s*item:(\d+)", re.MULTILINE)


def parse_block(text):
    """Return (npc_ids, item_ids) as sorted lists of ints from a pasted gaps block."""
    npcs = sorted({int(m) for m in NPC_RE.findall(text or "")})
    items = sorted({int(m) for m in ITEM_RE.findall(text or "")})
    return npcs, items


def _read_existing(path):
    """Return (comment_header_lines, set_of_existing_ids). Header = leading '#' lines."""
    header, ids = [], set()
    if not os.path.exists(path):
        return header, ids
    with open(path, "r", encoding="utf-8") as f:
        seen_id = False
        for line in f:
            s = line.strip()
            if not s:
                continue
            if s.startswith("#") and not seen_id:
                header.append(line.rstrip("\n"))
                continue
            m = re.match(r"^(\d+)", s)
            if m:
                seen_id = True
                ids.add(int(m.group(1)))
    return header, ids


def merge_into(path, new_ids, default_header):
    header, existing = _read_existing(path)
    if not header:
        header = default_header
    added = sorted(i for i in new_ids if i not in existing)
    allids = sorted(existing | set(new_ids))
    with open(path, "w", encoding="utf-8") as f:
        for h in header:
            f.write(h + "\n")
        for i in allids:
            f.write(f"{i}\n")
    return added, len(allids)


def run(text):
    npcs, items = parse_block(text)
    added_n, total_n = merge_into(
        NPCS_OUT, npcs, ["# NPC ids to scrape (wowhead_scrape.py --npcs). Fed by /dct gaps export via GH issues."]
    )
    added_i, total_i = merge_into(
        IDS_OUT, items, ["# Item ids to scrape (wowhead_scrape.py --ids). Fed by /dct gaps export via GH issues."]
    )
    print(f"npcs:  parsed {len(npcs)}, added {len(added_n)} new -> {total_n} total ({NPCS_OUT})")
    print(f"items: parsed {len(items)}, added {len(added_i)} new -> {total_i} total ({IDS_OUT})")
    if added_n:
        print("  new npcs:  " + " ".join(str(i) for i in added_n))
    if added_i:
        print("  new items: " + " ".join(str(i) for i in added_i))
    return added_n, added_i


SAMPLE = """DropChanceTooltip gaps | client 1.60.1 build 69893 | 2 npcs, 1 items
# Forever-specific candidates: hovered in-world with NO drop data in any source.
## NPCs
npc:1782  Moonrage Whitescalp  [Silverpine Forest]  lvl12  x5  (2026-09-27)
npc:990012  Big Bad Basher  [Barrens]  lvl22  x1  (2026-09-27)
## Items
item:3157  Darksoul Shackle  x2  (2026-09-27)
"""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--body-file", help="Read the pasted block from this file (default: stdin)")
    ap.add_argument("--selftest", action="store_true")
    args = ap.parse_args()

    if args.selftest:
        npcs, items = parse_block(SAMPLE)
        ok = npcs == [1782, 990012] and items == [3157]
        print(f"npcs={npcs} items={items}")
        print("PARSER OK" if ok else "PARSER FAILED")
        return 0 if ok else 1

    text = open(args.body_file, encoding="utf-8").read() if args.body_file else sys.stdin.read()
    run(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
