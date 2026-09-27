# Drop-data pipeline

How DropChanceTooltip gets and refreshes its loot data. Goal: Forever-accurate drops without
continuously scraping Wowhead (they'd offer an API if that were acceptable).

## Sources & trust order

CLASSIC IS THE AUTHORITY FOR DROP RATES. The classic DB is huge and battle-tested; Forever is a thin
beta sample whose tables may be deliberately altered (nerfs/restrictions). So Forever data is used
ONLY to FILL what classic lacks (Forever-specific additions) -- it never overrides a classic rate.

Merge is therefore **gap-fill in this order (first present wins, none overrides classic):**

1. **LootDBLua** (runtime dependency) — broad classic coverage + rates. **Primary / authoritative.**
2. **Questie Forever harvest** (`Data/QuestieDrops.lua`) — fills quest-only drops classic omits.
3. **Wowhead /forever scrape** (`Data/WowheadForeverDrops.lua`) — fills the rest: Forever-specific
   items/mobs that neither classic nor Questie has. Built by `tools/wowhead_scrape.py`.

## Why we scrape at all (the gap = Forever-specific additions ONLY)

Not for better rates on existing items -- classic already has those. We scrape only for content that
is NEW in Forever and therefore absent from classic:
- items dropped by Forever-added mobs, or Forever-added drops on existing mobs;
- anything we surface in-game that has NO data in any classic source.

We do NOT re-scrape items classic already covers.

## How QuestieDB sources Forever data (upstream we piggyback on)

Mapped from `Questie/QuestieDB`'s `forever` branch (Sept 2026 commits + `docs/forever-data.md`):

- **Drop RATES**: QuestieDB's *own* Wowhead scraper (`External Scripts/dropdata/`) generates
  `support/Forever/DropTables/classicItemDrops.lua` = `wowheadData = [[return {[item]={[npc]=pct}}]]`.
  **This validates our `wowhead_scrape.py`** — same source, same method. Manual overrides live in
  `support/Forever/DropTables/itemDropCorrections.lua` (numeric pct or `DropKeys.WOWHEAD` refs).
- **Positions / entities / zones**: DBC conversion, NOT scraping — `tools/dbc/convert.py` reads the
  Forever client's DBC files (source repo `Questie-db/QuestieDB-DBC`, client build `1.60.1.69893`),
  provenance in `support/Forever/provenance.json`. Irrelevant to drop rates; it's why coordinates move.

**Current state (verified 2026-09-27):** QuestieDB's Forever layer was scaffolded Sept 18–21 2026 but
is still EMPTY of Forever-specific deltas — the `forever{NPC,Quest}Fixes.lua` are empty templates, and
the Forever drop tables are byte-identical to classic (proven by identical git blob SHAs). So today
there is nothing Forever-unique in QuestieDB to harvest beyond what classic already gives us.

## Finding the Forever-specific target list

Primary discovery is **proactive**, off QuestieDB's commits — NOT off in-game encounters (the runtime
gap collector is only a safety-net; relying on it as primary is reactive/incomplete):

1. **Watch QuestieDB's `forever` branch for divergence (primary).** Compare git blob SHAs of each
   Forever file vs its classic counterpart, and check the `forever*Fixes.lua` templates for non-empty
   `:Load()` returns. When a watched file diverges, re-harvest it — that's the Forever-specific delta.
   Files: `support/Forever/DropTables/{classicItemDrops,itemDropCorrections}.lua`,
   `src/corrections/Forever/forever{NPC,Quest,Item,Object}Fixes.lua`,
   `data/Forever/forever{Npc,Item,Object,Quest}DB.lua`.
2. **Manual curation** — operator adds known Forever additions by id.
3. **Runtime "no data" collector (safety-net, NOT primary)** — the addon records item/npc ids it could
   show nothing for into SavedVariables (`DropChanceTooltipDB.gaps`), with **name/zone/level/count/date**
   so the persisted log is human-readable. Catches holes QuestieDB hasn't covered yet; must not be the
   only discovery path.
   - **Persistence:** `DropChanceTooltipDB` is a declared SavedVariable, so gaps survive a clean
     logout/reload automatically — no need to export before quitting. WoW has **no API to force a
     mid-session disk flush** (only a full `ReloadUI` writes SavedVariables early), so an *unclean* exit
     (crash/Alt-F4) is the one lossy case. The addon nudges `/dct gaps export` on logout/quit
     (`PLAYER_CAMPING`/`PLAYER_QUITING`) and, throttled, on zone change.
   - **Consolidation (the crash-proof channel):** `/dct gaps export` opens a copyable block (FVO-style).
     Paste it into a GitHub issue via `ISSUE_TEMPLATE/gaps.yml`; the `collect-gaps.yml` workflow runs
     `tools/ingest_gaps.py` to merge new `npc:`/`item:` ids into the scrape lists and commit. Once
     pasted, the data is out of the game and can't be lost to a crash — and it consolidates gaps across
     sessions/players into one scan list.

That evidence list -> `tools/scrape_ids.txt` (items) and `tools/scrape_npcs.txt` (npcs) -> the scraper.

## Initial pass

1. Seed: merge LootDBLua + Questie into a baseline (offline, no network).
2. Compute the **gap list** = item ids we surface that the seed lacks or flags low-confidence →
   `tools/scrape_ids.txt`.
3. Scrape only that list (`python3 tools/wowhead_scrape.py --ids tools/scrape_ids.txt`), validate a
   small `--limit` batch first.

Open scope decision: trust LootDBLua's generic rates for non-quest items (tiny initial scrape) vs.
re-scrape all surfaced items on Forever (bigger, more accurate). Default = trust seeds, scrape residual.

## Recurrence

Event-driven, **not** continuous. Two triggers:
- **QuestieDB `forever`-branch divergence (preferred).** When a watched Forever file diverges from its
  classic counterpart (see "Finding the target list"), re-harvest it directly — no scraping needed,
  they've done the work. This is deterministic and doesn't wait on us encountering content.
- **Post-patch self-scrape (fallback, for what QuestieDB hasn't covered).** Run a few days after a
  Forever content patch (operator says "go"). The ~3-day offset lets Wowhead accumulate `count/outof`
  samples on new content so rates aren't noise.
- The scraper's manifest (`tools/.wowhead_manifest.json`) tracks per-item last-scrape; a re-run with
  `--max-age-days` only re-fetches stale/changed items. The HTML cache (`tools/.wowhead_cache/`)
  makes re-runs cheap. Both are gitignored.

## Etiquette

Conservative `--delay` (default 1.5s), a descriptive User-Agent, cache hits avoid re-fetching, and we
only ever scrape a targeted list. Never hammer Wowhead; never scrape the whole catalog.

## Files

- `tools/wowhead_scrape.py` — the scraper (requests + regex; `--selftest` validates the parser offline).
- `tools/harvest_questie_drops.py` — the Questie harvest (quest-only drops + names).
- `tools/ingest_gaps.py` — merges a pasted `/dct gaps export` block into the scrape hit lists (`--selftest`).
- `.github/ISSUE_TEMPLATE/gaps.yml` + `.github/workflows/collect-gaps.yml` — the GH intake automation.
- `Data/WowheadForeverDrops.lua`, `Data/QuestieDrops.lua` — generated, committed, do-not-edit.
- TODO companions: `tools/build_seed.py` (merge LootDBLua+Questie) and gap-list emitter.
