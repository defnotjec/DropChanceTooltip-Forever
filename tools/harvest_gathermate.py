#!/usr/bin/env python3
"""
Harvest GatherMate2's herb/ore node data into a bundled table for DropChanceTooltip's material
aggregation (hovering an herb/ore shows "Herbalism 50 . <zones>" instead of nothing).

GatherMate2 does not run on the Forever beta client, but its data files are plain Lua and classic
gathering nodes are unchanged on Forever, so we harvest them offline (same pattern as QuestieDrops).

Inputs (relative to the AddOns folder, two levels up from this script by default):
  - GatherMate2/Constants.lua           node name <-> node id  (herbs 40x, ore 20x)
  - GatherMate2_Data/Era/HerbalismData.lua   GatherMateData2HerbDB[uiMapId][pos] = nodeId
  - GatherMate2_Data/Era/MiningData.lua      GatherMateData2MineDB[uiMapId][pos] = nodeId

Output: Data/GatherNodes.lua
  DropChanceTooltip_GatherNodes = {
    herb = { ["Mageroyal"] = { ["Durotar"]=87, ["Mulgore"]=40, ... }, ... },
    ore  = { ["Copper Vein"] = { ... }, ... },
  }
Keyed by English node name; the addon resolves an item to its node name (herb item name == node name;
ore items use a small item->node map in the addon, e.g. Copper Ore -> Copper Vein).

Re-run after a GatherMate2_Data update: python3 tools/harvest_gathermate.py [--flavor Era|Classic|Tbc]
"""
import argparse
import os
import re

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
ADDONS_DIR = os.path.abspath(os.path.join(SCRIPT_DIR, "..", ".."))
OUT = os.path.join(SCRIPT_DIR, "..", "Data", "GatherNodes.lua")

# Classic UiMapIDs -> zone name (the ids GatherMate2's classic data is keyed by). Only the zones that
# carry gathering nodes are needed; unknown ids are reported so the table can be extended.
UIMAP_NAMES = {
    1411: "Durotar", 1412: "Mulgore", 1413: "The Barrens", 1416: "Alterac Mountains",
    1417: "Arathi Highlands", 1418: "Badlands", 1419: "Blasted Lands", 1420: "Tirisfal Glades",
    1421: "Silverpine Forest", 1422: "Western Plaguelands", 1423: "Eastern Plaguelands",
    1424: "Hillsbrad Foothills", 1425: "The Hinterlands", 1426: "Dun Morogh", 1427: "Searing Gorge",
    1428: "Burning Steppes", 1429: "Elwynn Forest", 1430: "Deadwind Pass", 1431: "Duskwood",
    1432: "Loch Modan", 1433: "Redridge Mountains", 1434: "Stranglethorn Vale",
    1435: "Swamp of Sorrows", 1436: "Westfall", 1437: "Wetlands", 1438: "Teldrassil",
    1439: "Darkshore", 1440: "Ashenvale", 1441: "Thousand Needles", 1442: "Stonetalon Mountains",
    1443: "Desolace", 1444: "Feralas", 1445: "Dustwallow Marsh", 1446: "Tanaris", 1447: "Azshara",
    1448: "Felwood", 1449: "Un'Goro Crater", 1450: "Moonglade", 1451: "Silithus", 1452: "Winterspring",
    1453: "Stormwind City", 1454: "Orgrimmar", 1455: "Ironforge", 1456: "Thunder Bluff",
    1457: "Darnassus", 1458: "Undercity",
}

NODE_DEF_RE = re.compile(r'\[NL\["([^"]+)"\]\]\s*=\s*(\d+)')
MAP_OPEN_RE = re.compile(r'^\s*\[(\d+)\]\s*=\s*\{')
NODE_VAL_RE = re.compile(r'=\s*(\d+)\s*,?\s*$')


def parse_node_ids(constants_path):
    """node id -> name, split into 'herb' (400-499) and 'ore' (200-299) categories."""
    id_to_name, category = {}, {}
    with open(constants_path, "r", encoding="utf-8") as f:
        for line in f:
            m = NODE_DEF_RE.search(line)
            if not m:
                continue
            name, nid = m.group(1), int(m.group(2))
            if 400 <= nid <= 499:
                cat = "herb"
            elif 200 <= nid <= 299:
                cat = "ore"
            else:
                continue
            id_to_name[nid] = name
            category[nid] = cat
    return id_to_name, category


def parse_node_data(data_path):
    """Count nodes per (nodeId, uiMapId) from a GatherMate2 data DB. -> {nodeId: {uiMapId: count}}."""
    counts = {}
    cur_map = None
    with open(data_path, "r", encoding="utf-8") as f:
        for line in f:
            mo = MAP_OPEN_RE.match(line)
            if mo:
                cur_map = int(mo.group(1))
                continue
            if cur_map is None:
                continue
            mv = NODE_VAL_RE.search(line)
            if mv and "[" in line:  # a "[pos] = nodeId," row
                nid = int(mv.group(1))
                counts.setdefault(nid, {}).setdefault(cur_map, 0)
                counts[nid][cur_map] += 1
    return counts


def build(flavor):
    constants = os.path.join(ADDONS_DIR, "GatherMate2", "Constants.lua")
    herb_data = os.path.join(ADDONS_DIR, "GatherMate2_Data", flavor, "HerbalismData.lua")
    mine_data = os.path.join(ADDONS_DIR, "GatherMate2_Data", flavor, "MiningData.lua")

    id_to_name, category = parse_node_ids(constants)
    herb_counts = parse_node_data(herb_data)
    mine_counts = parse_node_data(mine_data)

    unknown_maps = set()
    result = {"herb": {}, "ore": {}}

    def fold(counts):
        for nid, zones in counts.items():
            name, cat = id_to_name.get(nid), category.get(nid)
            if not name or not cat:
                continue
            bucket = result[cat].setdefault(name, {})
            for uimap, n in zones.items():
                zname = UIMAP_NAMES.get(uimap)
                if not zname:
                    unknown_maps.add(uimap)
                    continue
                bucket[zname] = bucket.get(zname, 0) + n

    fold(herb_counts)
    fold(mine_counts)
    return result, unknown_maps


def emit_lua(result):
    lines = [
        "-- AUTO-GENERATED by tools/harvest_gathermate.py from GatherMate2_Data. DO NOT EDIT BY HAND.",
        "-- Herb/ore gathering nodes -> node name -> { zone name = node count }. Classic data is",
        "-- authoritative for Forever (gathering nodes are unchanged there).",
        "DropChanceTooltip_GatherNodes = {",
    ]
    for cat in ("herb", "ore"):
        lines.append('    ["%s"] = {' % cat)
        for name in sorted(result[cat]):
            zones = result[cat][name]
            parts = ", ".join('["%s"]=%d' % (z, zones[z]) for z in sorted(zones, key=lambda z: -zones[z]))
            lines.append('        ["%s"] = { %s },' % (name, parts))
        lines.append("    },")
    lines.append("}")
    return "\n".join(lines) + "\n"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--flavor", default="Era", choices=["Era", "Classic", "Tbc"])
    ap.add_argument("--selftest", action="store_true")
    args = ap.parse_args()

    if args.selftest:
        ids, cats = {}, {}
        sample = '\t\t[NL["Copper Vein"]] \t= 201,\n\t\t[NL["Mageroyal"]] \t= 404,\n'
        for line in sample.splitlines():
            m = NODE_DEF_RE.search(line)
            if m:
                nid = int(m.group(2))
                ids[nid] = m.group(1)
        ok = ids.get(201) == "Copper Vein" and ids.get(404) == "Mageroyal"
        # data parse
        data = 'GatherMateData2HerbDB = {\n\t[1411] = {\n\t\t[3570284000] = 404,\n\t\t[3570285000] = 404,\n\t},\n}\n'
        cur, cnt = None, {}
        for line in data.splitlines():
            mo = MAP_OPEN_RE.match(line)
            if mo:
                cur = int(mo.group(1)); continue
            mv = NODE_VAL_RE.search(line)
            if mv and "[" in line and cur:
                cnt.setdefault(int(mv.group(1)), {}).setdefault(cur, 0)
                cnt[int(mv.group(1))][cur] += 1
        ok = ok and cnt.get(404, {}).get(1411) == 2
        print("PARSER OK" if ok else "PARSER FAILED")
        return 0 if ok else 1

    result, unknown = build(args.flavor)
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w", encoding="utf-8") as f:
        f.write(emit_lua(result))
    nherb, nore = len(result["herb"]), len(result["ore"])
    print("wrote %s: %d herbs, %d ores (flavor=%s)" % (os.path.relpath(OUT, SCRIPT_DIR), nherb, nore, args.flavor))
    if unknown:
        print("WARNING: unknown uiMapIds (add to UIMAP_NAMES): %s" % sorted(unknown))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
