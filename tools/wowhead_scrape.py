#!/usr/bin/env python3
"""
Wowhead (Forever) drop-data scraper for DropChanceTooltip.

Fetches item pages from the Forever Wowhead domain and extracts each item's "dropped-by" data
(the crowdsourced count/outof samples embedded in the page's inline JS), turning them into drop
percentages. Output matches our bundled schema so it merges the same way as the Questie harvest.

DESIGN / OPERATING RULES (read tools/DATA_PIPELINE.md for the full plan):
  * Targeted, never the whole catalog. It scrapes ONLY the item IDs you feed it (--ids file), which
    should be the "residual" gap list (items we surface that the seed data doesn't cover well).
  * Event-driven, not continuous. Run it a few days AFTER a Forever content patch, when Wowhead has
    collected enough samples. There is no daily polling.
  * Gentle + resumable. Per-request delay, retries, an on-disk HTML cache, and a manifest so re-runs
    skip items already scraped recently. Respect Wowhead -- keep the delay conservative.

This runs on YOUR machine (needs network + `requests`); it is dev tooling, not shipped to players.
The GENERATED Lua file is committed so the addon needs no Python at runtime.

Usage:
    pip install requests
    python3 tools/wowhead_scrape.py --ids tools/scrape_ids.txt
    python3 tools/wowhead_scrape.py --ids tools/scrape_ids.txt --limit 20   # small test batch
    python3 tools/wowhead_scrape.py --selftest                              # parse a sample, no network
    python3 tools/wowhead_scrape.py --ids ... --force                       # ignore manifest freshness
"""
import argparse
import json
import os
import re
import sys
import time

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
ADDON_DIR = os.path.dirname(SCRIPT_DIR)

BASE_URL = "https://www.wowhead.com/forever/item={}"
NPC_URL = "https://www.wowhead.com/forever/npc={}"
CACHE_DIR = os.path.join(SCRIPT_DIR, ".wowhead_cache")     # raw HTML cache (gitignored)
MANIFEST_PATH = os.path.join(SCRIPT_DIR, ".wowhead_manifest.json")
DEFAULT_OUT = os.path.join(ADDON_DIR, "Data", "WowheadForeverDrops.lua")
USER_AGENT = "DropChanceTooltip-scraper/1.0 (personal addon data build; contact: defnotjec)"

# --- Parsers (mirror Questie's item_drop_spider technique) ------------------------------------
NAME_RE = re.compile(r'"name(?:_enus)?":"((?:[^"\\]|\\.)*)"')
# A Listview block by id, then each row's referenced id + count/outof under modes.0.
# On an ITEM page the 'dropped-by' block lists NPCs; on an NPC page the 'drops' block lists ITEMS.
DROPPEDBY_BLOCK_RE = re.compile(r"id:\s*'dropped-by'.*?data:\s*(\[.*?\])\s*\}\)", re.DOTALL)
NPC_DROPS_BLOCK_RE = re.compile(r"id:\s*'drops'.*?data:\s*(\[.*?\])\s*\}\)", re.DOTALL)
ROW_RE = re.compile(r'"id":(\d+).*?"modes":\{.*?"0":\{[^}]*?"count":(\d+)[^}]*?"outof":(\d+)', re.DOTALL)
# Per-row item name on an NPC drops listview, e.g. {"id":3157,"name_enus":"Darksoul Shackle",...}
ROW_NAME_RE = re.compile(r'"id":(\d+)[^}]*?"name(?:_enus)?":"((?:[^"\\]|\\.)*)"')


def _rows_to_pct(block_text):
    """{ id: pct } from a Listview data block. pct = count/outof*100."""
    out = {}
    for row in ROW_RE.finditer(block_text):
        rid = int(row.group(1))
        count, outof = int(row.group(2)), int(row.group(3))
        if outof > 0:
            out[rid] = round(count / outof * 100, 4)
    return out


def parse_item_page(html):
    """ITEM page -> (item_name, { npcId: pct })."""
    name = None
    nm = NAME_RE.search(html)
    if nm:
        name = nm.group(1).encode("utf-8").decode("unicode_escape")
    block = DROPPEDBY_BLOCK_RE.search(html)
    return name, (_rows_to_pct(block.group(1)) if block else {})


def parse_npc_page(html):
    """NPC page -> ({ itemId: pct }, { itemId: name }). Item names come from the drops rows."""
    block = NPC_DROPS_BLOCK_RE.search(html)
    if not block:
        return {}, {}
    body = block.group(1)
    drops = _rows_to_pct(body)
    names = {}
    for m in ROW_NAME_RE.finditer(body):
        try:
            names[int(m.group(1))] = m.group(2).encode("utf-8").decode("unicode_escape")
        except Exception:
            pass
    return drops, names


# Skinning: an ITEM page's 'skinned-from' listview lists the CREATURES you skin for that leather.
# We only need their npc ids -- the level range comes from Data/MobLevels.lua at runtime, so we don't
# depend on Wowhead's per-row level fields. Row objects start with {"id":<npcId>.
SKINNEDFROM_BLOCK_RE = re.compile(r"id:\s*'skinned-from'.*?data:\s*(\[.*?\])\s*\}\)", re.DOTALL)
ROW_LEAD_ID_RE = re.compile(r'\{"id":(\d+)')


def parse_skinned_from(html):
    """ITEM page -> (item_name, [npcId, ...]) of the creatures skinned for this leather."""
    name = None
    nm = NAME_RE.search(html)
    if nm:
        name = nm.group(1).encode("utf-8").decode("unicode_escape")
    block = SKINNEDFROM_BLOCK_RE.search(html)
    if not block:
        return name, []
    seen, ids = set(), []
    for m in ROW_LEAD_ID_RE.finditer(block.group(1)):
        nid = int(m.group(1))
        if nid not in seen:
            seen.add(nid)
            ids.append(nid)
    return name, ids


# The (small, stable) set of skinning leather/hide items to resolve to their source beasts.
DEFAULT_SKINNING_ITEMS = [
    2934,  # Ruined Leather Scraps
    2318,  # Light Leather
    783,   # Light Hide
    2319,  # Medium Leather
    4232,  # Medium Hide
    4234,  # Heavy Leather
    4235,  # Heavy Hide
    4304,  # Thick Leather
    8169,  # Thick Hide
    8170,  # Rugged Leather
    8171,  # Rugged Hide
]


def write_skinning_lua(out_path, sources, names):
    """sources: {itemID: [npcId,...]}, names: {itemID: name} -> DropChanceTooltip_SkinningSources.lua"""
    lines = [
        "-- AUTO-GENERATED by tools/wowhead_scrape.py --skinning. DO NOT EDIT BY HAND.",
        "-- Leather/hide item -> creatures you skin it from (npc ids). Level range resolved at runtime",
        "-- via Data/MobLevels.lua. Classic skinning sources are unchanged on Forever.",
        "DropChanceTooltip_SkinningSources = {",
    ]
    for iid in sorted(sources):
        npcs = sources[iid]
        if not npcs:
            continue
        comment = (" -- " + names[iid]) if names.get(iid) else ""
        lines.append("    [%d] = { %s },%s" % (iid, ", ".join(str(n) for n in npcs), comment))
    lines.append("}")
    with open(out_path, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")
    return sum(1 for v in sources.values() if v)


# Back-compat alias for the self-test.
def parse_page(html):
    return parse_item_page(html)


# --- Manifest (freshness / resume) ------------------------------------------------------------
def load_manifest():
    if os.path.isfile(MANIFEST_PATH):
        try:
            with open(MANIFEST_PATH, "r", encoding="utf-8") as f:
                return json.load(f)
        except Exception:
            pass
    return {"items": {}}   # itemID(str) -> {"scraped": epoch, "npcs": int}


def save_manifest(m):
    with open(MANIFEST_PATH, "w", encoding="utf-8") as f:
        json.dump(m, f, indent=0)


def fetch(kind, obj_id, session, delay, retries, now):
    """Fetch an item or npc page (kind='item'|'npc'), using the on-disk cache. HTML text or None."""
    cache_file = os.path.join(CACHE_DIR, f"{kind}_{obj_id}.html")
    if os.path.isfile(cache_file):
        with open(cache_file, "r", encoding="utf-8") as f:
            return f.read()
    url = (NPC_URL if kind == "npc" else BASE_URL).format(obj_id)
    for attempt in range(1, retries + 1):
        try:
            resp = session.get(url, headers={"User-Agent": USER_AGENT}, timeout=30)
            if resp.status_code == 200:
                os.makedirs(CACHE_DIR, exist_ok=True)
                with open(cache_file, "w", encoding="utf-8") as f:
                    f.write(resp.text)
                time.sleep(delay)   # be gentle -- only after a real network hit
                return resp.text
            if resp.status_code == 404:
                return ""
            print(f"  item {item_id}: HTTP {resp.status_code} (attempt {attempt}/{retries})")
        except Exception as e:  # noqa: BLE001
            print(f"  item {item_id}: {e} (attempt {attempt}/{retries})")
        time.sleep(delay * attempt)
    return None


def read_ids(path):
    ids = []
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            line = line.split("#", 1)[0].strip()
            if line.isdigit():
                ids.append(int(line))
    return ids


def write_lua(out_path, drops_by_item, names):
    item_count = len(drops_by_item)
    pair_count = sum(len(v) for v in drops_by_item.values())
    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    lines = [
        "-- AUTO-GENERATED by tools/wowhead_scrape.py -- DO NOT EDIT BY HAND.",
        "-- Source: wowhead.com/forever item pages (crowdsourced count/outof -> drop %).",
        "-- Re-run at patch+~3 days on the residual id list. See tools/DATA_PIPELINE.md.",
        f"-- Items: {item_count}  item:npc pairs: {pair_count}",
        "DropChanceTooltip_WowheadDrops = {",
    ]
    for item_id in sorted(drops_by_item):
        npcs = drops_by_item[item_id]
        parts = ", ".join(f"[{npc}]={pct:g}" for npc, pct in sorted(npcs.items()))
        lines.append(f"    [{item_id}] = {{ {parts} }},")
    lines.append("}")
    lines.append("")
    lines.append("DropChanceTooltip_WowheadItemNames = {")
    for item_id in sorted(names):
        nm = names[item_id].replace("\\", "\\\\").replace('"', '\\"')
        lines.append(f'    [{item_id}] = "{nm}",')
    lines.append("}")
    with open(out_path, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")
    return item_count, pair_count


SAMPLE_ITEM_HTML = r'''
<script>WH.Gatherer.addData(3, 1, {"3157":{"name":"Darksoul Shackle","quality":1}});</script>
<script>
    var tabsRelated = [];
    new Listview({id: 'dropped-by', data: [{"id":1782,"name":"Moonrage Darksoul","modes":{"0":{"count":468,"outof":999}}}]})
</script>
'''

SAMPLE_NPC_HTML = r'''
<script>
    new Listview({id: 'drops', data: [{"id":3157,"name_enus":"Darksoul Shackle","modes":{"0":{"count":468,"outof":999}}},
                                       {"id":2287,"name_enus":"Haunch of Meat","modes":{"0":{"count":48,"outof":999}}}]})
</script>
'''

SAMPLE_SKINNED_HTML = r'''
<script>WH.Gatherer.addData(3, 1, {"2319":{"name":"Medium Leather","quality":1}});</script>
<script>
    new Listview({id: 'skinned-from', data: [{"id":1132,"name":"Snapjaw","minlevel":25,"maxlevel":26,"modes":{"0":{"count":80,"outof":100}}},
                                              {"id":1133,"name":"Elder Snapjaw","minlevel":30,"maxlevel":31,"modes":{"0":{"count":70,"outof":100}}}]})
</script>
'''


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ids", help="File of ITEM ids to scrape (item pages -> item->npc)")
    ap.add_argument("--npcs", help="File of NPC ids to scrape (npc pages -> npc->items)")
    ap.add_argument("--out", default=DEFAULT_OUT)
    ap.add_argument("--delay", type=float, default=1.5, help="Seconds between network requests")
    ap.add_argument("--retries", type=int, default=3)
    ap.add_argument("--limit", type=int, default=0, help="Only process the first N ids per list (test)")
    ap.add_argument("--max-age-days", type=float, default=30.0,
                    help="Skip ids scraped more recently than this (manifest freshness)")
    ap.add_argument("--force", action="store_true", help="Ignore manifest freshness")
    ap.add_argument("--skinning", action="store_true",
                    help="Scrape skinned-from for the leather item set -> Data/SkinningSources.lua")
    ap.add_argument("--skinning-out", default=os.path.join(SCRIPT_DIR, "..", "Data", "SkinningSources.lua"))
    ap.add_argument("--selftest", action="store_true", help="Parse the built-in samples; no network")
    args = ap.parse_args()

    if args.selftest:
        iname, idrops = parse_item_page(SAMPLE_ITEM_HTML)
        ndrops, nnames = parse_npc_page(SAMPLE_NPC_HTML)
        sname, snpcs = parse_skinned_from(SAMPLE_SKINNED_HTML)
        exp = round(468 / 999 * 100, 4)
        ok_item = iname == "Darksoul Shackle" and idrops.get(1782) == exp
        ok_npc = ndrops.get(3157) == exp and nnames.get(3157) == "Darksoul Shackle" and 2287 in ndrops
        ok_skin = snpcs == [1132, 1133]
        print(f"item page: name={iname!r} drops={idrops}")
        print(f"npc page : drops={ndrops} names={nnames}")
        print(f"skinned  : name={sname!r} npcs={snpcs}")
        print("PARSER OK" if (ok_item and ok_npc and ok_skin) else "PARSER FAILED")
        return 0 if (ok_item and ok_npc and ok_skin) else 1

    if args.skinning:
        try:
            import requests
        except ImportError:
            print("ERROR: pip install requests", file=sys.stderr)
            return 2
        session = requests.Session()
        now = time.time()
        sources, names = {}, {}
        for iid in DEFAULT_SKINNING_ITEMS:
            html = fetch("item", iid, session, args.delay, args.retries, now)
            if not html:
                print(f"  item {iid}: no data")
                continue
            nm, npcs = parse_skinned_from(html)
            if nm:
                names[iid] = nm
            sources[iid] = npcs
            print(f"  item {iid} ({nm}): {len(npcs)} source creatures")
        n = write_skinning_lua(args.skinning_out, sources, names)
        print(f"wrote {args.skinning_out}: {n} leather items with sources")
        return 0

    if not args.ids and not args.npcs:
        print("ERROR: pass --ids, --npcs, or --skinning (or --selftest). See tools/DATA_PIPELINE.md.", file=sys.stderr)
        return 2

    try:
        import requests
    except ImportError:
        print("ERROR: pip install requests", file=sys.stderr)
        return 2

    manifest = load_manifest()
    manifest.setdefault("items", {})
    manifest.setdefault("npcs", {})
    now = time.time()
    max_age = args.max_age_days * 86400
    session = requests.Session()

    drops_by_item, names = {}, {}
    scraped, skipped, empty = 0, 0, 0

    def fresh(kind, obj_id):
        rec = manifest[kind].get(str(obj_id))
        return rec and not args.force and (now - rec.get("scraped", 0)) < max_age

    # ITEM pages -> item -> { npc: pct }
    if args.ids:
        ids = read_ids(args.ids)
        if args.limit:
            ids = ids[:args.limit]
        for i, item_id in enumerate(ids, 1):
            if fresh("item", item_id):
                skipped += 1
                continue
            html = fetch("item", item_id, session, args.delay, args.retries, now)
            if html is None:
                continue
            name, drops = parse_item_page(html)
            if name:
                names.setdefault(item_id, name)
            if drops:
                dst = drops_by_item.setdefault(item_id, {})
                for npc, pct in drops.items():
                    dst[npc] = pct
            else:
                empty += 1
            manifest["items"][str(item_id)] = {"scraped": now, "npcs": len(drops)}
            scraped += 1
            if i % 25 == 0:
                print(f"  items ...{i}/{len(ids)} (scraped {scraped}, skipped {skipped})")
                save_manifest(manifest)

    # NPC pages -> { item: pct }, inverted into item -> { npc: pct }
    if args.npcs:
        npcs = read_ids(args.npcs)
        if args.limit:
            npcs = npcs[:args.limit]
        for i, npc_id in enumerate(npcs, 1):
            if fresh("npc", npc_id):
                skipped += 1
                continue
            html = fetch("npc", npc_id, session, args.delay, args.retries, now)
            if html is None:
                continue
            drops, item_names = parse_npc_page(html)
            for item_id, pct in drops.items():
                drops_by_item.setdefault(item_id, {})[npc_id] = pct
            for item_id, nm in item_names.items():
                names.setdefault(item_id, nm)
            if not drops:
                empty += 1
            manifest["npcs"][str(npc_id)] = {"scraped": now, "items": len(drops)}
            scraped += 1
            if i % 25 == 0:
                print(f"  npcs ...{i}/{len(npcs)} (scraped {scraped}, skipped {skipped})")
                save_manifest(manifest)

    save_manifest(manifest)
    item_count, pair_count = write_lua(args.out, drops_by_item, names)
    print(f"done: {scraped} scraped, {skipped} fresh-skipped, {empty} had no drop data")
    print(f"wrote {args.out}: {item_count} items, {pair_count} item:npc pairs")
    return 0


if __name__ == "__main__":
    sys.exit(main())
