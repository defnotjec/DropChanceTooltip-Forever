#!/usr/bin/env python3
"""
Build the Forever-specific NPC hit list for the Wowhead scraper, from QuestieDB's quest data.

Idea (per the plan): Forever-only quests point at Forever-new NPCs whose drop tables classic can't
have. We diff the Forever quest DB against the classic quest DB -> Forever-ONLY quests -> pull each
quest's associated NPC ids (givers, turn-ins, kill objectives) -> subtract NPCs that classic quests
already reference (those aren't new) -> the residual is the Forever-specific NPC hit list ->
tools/scrape_npcs.txt (fed to `wowhead_scrape.py --npcs`).

IMPORTANT DATA-ACCESS NOTE: the INSTALLED QuestieDB has NO plain quest-data file (it's packed into a
TOC store). The full plain-Lua data lives in the QuestieDB *repo* (Questie/QuestieDB). So by default
we fetch from the repo. Both files are `QuestieDB.questData = [[return { [id] = {...} }]]`.

Quest entry field layout (1-indexed): 1=name, 2=startedBy{creatureStart,objectStart,itemStart},
3=finishedBy{creatureEnd,objectEnd}, 10=objectives{creatureObjective,objectObjective,itemObjective,
reputationObjective,killCredit,spellObjective}. NPCs = creatureStart + creatureEnd +
creatureObjective[i][1] + killCredit[i][1][*].

Re-runnable: run at patch+~3 days (after Questie updates its Forever data). Python stdlib only.

Usage:
    python3 tools/forever_quest_npcs.py                      # fetch both DBs from the repo
    python3 tools/forever_quest_npcs.py --forever a.lua --classic b.lua   # use local copies
    python3 tools/forever_quest_npcs.py --selftest
"""
import argparse
import os
import re
import sys
import urllib.request

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
RAW = "https://raw.githubusercontent.com/Questie/QuestieDB/master/data/{}/{}QuestDB.lua"
FOREVER_URL = RAW.format("Forever", "forever")
CLASSIC_URL = RAW.format("Classic", "classic")
DEFAULT_OUT = os.path.join(SCRIPT_DIR, "scrape_npcs.txt")


# --- Minimal Lua-table-literal parser (subset: tables, numbers, strings, nil/true/false) ----------
class LuaParser:
    def __init__(self, s):
        self.s = s
        self.i = 0
        self.n = len(s)

    def _ws(self):
        while self.i < self.n:
            c = self.s[self.i]
            if c in " \t\r\n":
                self.i += 1
            elif c == "-" and self.s[self.i:self.i + 2] == "--":
                # skip line comment (rare in generated data, but be safe)
                nl = self.s.find("\n", self.i)
                self.i = self.n if nl < 0 else nl + 1
            else:
                break

    def parse(self):
        self._ws()
        return self._value()

    def _value(self):
        self._ws()
        c = self.s[self.i]
        if c == "{":
            return self._table()
        if c == '"' or c == "'":
            return self._string(c)
        if c == "[" and self.s[self.i + 1] == "[":
            return self._longstring()
        return self._scalar()

    def _table(self):
        self.i += 1  # {
        result = {}
        pos = 0
        while True:
            self._ws()
            if self.s[self.i] == "}":
                self.i += 1
                return result
            if self.s[self.i] == "[":
                # [key] = value
                self.i += 1
                self._ws()
                key = self._value()
                self._ws()
                assert self.s[self.i] == "]", f"expected ] at {self.i}"
                self.i += 1
                self._ws()
                assert self.s[self.i] == "=", f"expected = at {self.i}"
                self.i += 1
                result[key] = self._value()
            else:
                # positional value (nil still consumes a slot -> preserves field positions)
                pos += 1
                result[pos] = self._value()
            self._ws()
            if self.s[self.i] == ",":
                self.i += 1

    def _string(self, quote):
        self.i += 1
        out = []
        while self.i < self.n:
            c = self.s[self.i]
            if c == "\\":
                out.append(self.s[self.i:self.i + 2])
                self.i += 2
                continue
            if c == quote:
                self.i += 1
                break
            out.append(c)
            self.i += 1
        return "".join(out)

    def _longstring(self):
        end = self.s.find("]]", self.i + 2)
        val = self.s[self.i + 2:end]
        self.i = end + 2
        return val

    def _scalar(self):
        m = re.match(r"-?\d+\.?\d*(?:[eE][+-]?\d+)?|nil|true|false", self.s[self.i:])
        tok = m.group(0)
        self.i += len(tok)
        if tok == "nil":
            return None
        if tok == "true":
            return True
        if tok == "false":
            return False
        return float(tok) if ("." in tok or "e" in tok or "E" in tok) else int(tok)


def load_questdata(text):
    """text = a *QuestDB.lua file body -> { questId(int): entry(dict) }."""
    m = re.search(r"questData\s*=\s*\[\[return\s*(\{.*\})\s*\]\]", text, re.S)
    if not m:
        raise ValueError("questData [[return {...}]] block not found")
    return LuaParser(m.group(1)).parse()


def creature_ids_from_quest(entry):
    """Collect NPC ids referenced by one quest entry (givers, turn-ins, kill objectives)."""
    npcs = set()

    def collect_flat(tbl):
        if isinstance(tbl, dict):
            for v in tbl.values():
                if isinstance(v, (int, float)):
                    npcs.add(int(v))
                elif isinstance(v, dict):
                    collect_flat(v)

    started_by = entry.get(2)      # {creatureStart, objectStart, itemStart}
    finished_by = entry.get(3)     # {creatureEnd, objectEnd}
    objectives = entry.get(10)     # {creatureObjective, objectObjective, ...}

    if isinstance(started_by, dict) and isinstance(started_by.get(1), dict):
        collect_flat(started_by[1])          # creatureStart
    if isinstance(finished_by, dict) and isinstance(finished_by.get(1), dict):
        collect_flat(finished_by[1])         # creatureEnd
    if isinstance(objectives, dict):
        creature_obj = objectives.get(1)     # {{creatureID, text, icon}, ...}
        if isinstance(creature_obj, dict):
            for row in creature_obj.values():
                if isinstance(row, dict) and isinstance(row.get(1), (int, float)):
                    npcs.add(int(row[1]))
        kill_credit = objectives.get(5)      # {{{creature,...}, base, text, icon}, ...}
        if isinstance(kill_credit, dict):
            for row in kill_credit.values():
                if isinstance(row, dict) and isinstance(row.get(1), dict):
                    collect_flat(row[1])
    return npcs


def all_creature_ids(questdata):
    ids = set()
    for entry in questdata.values():
        if isinstance(entry, dict):
            ids |= creature_ids_from_quest(entry)
    return ids


def read_source(url, local):
    if local:
        with open(local, "r", encoding="utf-8") as f:
            return f.read()
    print(f"  fetching {url}")
    req = urllib.request.Request(url, headers={"User-Agent": "DropChanceTooltip-tools"})
    with urllib.request.urlopen(req, timeout=60) as r:
        return r.read().decode("utf-8")


SAMPLE = r'''
QuestieDB.questData = [[return {
[6] = {"Bounty on Garrick Padfoot",{{823}},{{823}},2,5,77,nil,{"Kill Garrick Padfoot."},nil,{nil,nil,{{182}}},nil},
[900001] = {"Big Bad Basher Quest",{{990010}},{{990011}},20,22,77,nil,{"Slay the Elite Quilboar."},nil,{{{990012}}},nil},
}]]
'''


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--forever", help="Local foreverQuestDB.lua (default: fetch from repo)")
    ap.add_argument("--classic", help="Local classicQuestDB.lua (default: fetch from repo)")
    ap.add_argument("--out", default=DEFAULT_OUT)
    ap.add_argument("--include-shared", action="store_true",
                    help="Also include NPCs that classic quests reference (not just Forever-new)")
    ap.add_argument("--selftest", action="store_true")
    args = ap.parse_args()

    if args.selftest:
        qd = load_questdata(SAMPLE)
        assert set(qd.keys()) == {6, 900001}, qd.keys()
        npcs6 = creature_ids_from_quest(qd[6])
        npcs_bbb = creature_ids_from_quest(qd[900001])
        print(f"quest 6 npcs: {sorted(npcs6)}")
        print(f"quest 900001 (Big Bad Basher) npcs: {sorted(npcs_bbb)}")
        ok = npcs6 == {823} and npcs_bbb == {990010, 990011, 990012}
        print("PARSER OK" if ok else "PARSER FAILED")
        return 0 if ok else 1

    forever = load_questdata(read_source(FOREVER_URL, args.forever))
    classic = load_questdata(read_source(CLASSIC_URL, args.classic))

    forever_ids = set(forever.keys())
    classic_ids = set(classic.keys())
    forever_only = forever_ids - classic_ids
    print(f"quests: forever={len(forever_ids)} classic={len(classic_ids)} forever-only={len(forever_only)}")

    npcs = set()
    for qid in forever_only:
        npcs |= creature_ids_from_quest(forever[qid])

    if not args.include_shared:
        classic_npcs = all_creature_ids(classic)
        before = len(npcs)
        npcs -= classic_npcs
        print(f"npcs from forever-only quests: {before}; after removing classic-quest npcs: {len(npcs)}")

    npcs = sorted(n for n in npcs if n > 0)
    with open(args.out, "w", encoding="utf-8") as f:
        f.write("# Forever-specific NPC hit list (from Forever-only quests, minus classic-quest npcs).\n")
        f.write("# Regenerate: python3 tools/forever_quest_npcs.py ; feed to wowhead_scrape.py --npcs\n")
        for n in npcs:
            f.write(f"{n}\n")
    print(f"wrote {args.out}: {len(npcs)} candidate Forever NPCs")
    return 0


if __name__ == "__main__":
    sys.exit(main())
