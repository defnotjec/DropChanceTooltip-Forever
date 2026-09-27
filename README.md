# DropChanceTooltip (Forever port)

Shows item drop-chance data in tooltips on the **WoW: Forever** client (Interface `16001`).

This is a port + enhancement of **astroVermilion's** [DropChanceTooltip], which targeted TBC
(Interface `20504`) and no longer worked on Forever. It reads loot data from **LootDBLua** (also
by astroVermilion), which must be installed alongside it.

## What this version changes vs. upstream

- **Forever/modern API port**
  - Tooltip hooks moved from the removed `OnTooltipSetItem/Unit` scripts to
    `TooltipDataProcessor.AddTooltipPostCall` (with the legacy path kept as a fallback). Item/NPC
    IDs are read from the post-call `data` (`.id` / `.guid`).
  - `GetItemInfo` (removed as a global on this client) is shimmed to `C_Item.GetItemInfo`.
  - `## Interface` bumped to `16001`; `Bindings.xml` is **not** listed in the `.toc` (this client
    auto-loads it — listing it double-loads and errors).
- **Master toggle** — `enabled` (default on). Toggle via `/dct toggle | on | off`, a keybind
  ("Toggle Drop Tooltips"), or a macro (`/run DropChanceTooltip_Toggle()`).
- **Rarity-scaled source list** — instead of dumping every source (e.g. ~860 for Linen Cloth),
  the item tooltip shows the **top N sources by drop %**, where N scales with the item's rarity
  (grey 3 → epic 15 → legendary+ 20; configurable in `sourceCountByRarity`). Shift expands.
- **Mob tooltips** (open-world only) — hover a mob → its notable drops:
  - A **Quest Items** section (shown only for quests you're currently on; overridable), then
  - **blue/epic** individually, then the **main common drops** (top N by %, with a configurable
    **min‑% floor** so junk is hidden), then collapsible **"various X"** groups
    (gems / patterns / schematics / enchants / recipes / scrolls / greens), each independently
    **show / collapse / hide** in options. Shift reveals everything.
  - Built on a source→items reverse index derived from LootDBLua at runtime (LootDBLua untouched).
- **Options panel** — open with `/dct` (or Esc → Options → AddOns → DropChanceTooltip): rarity
  filters, per-group show/collapse/hide, "expand all", "always show quest items", and the min‑%
  slider.
- `/dct diag`, `/dct npc [id]` — diagnostics (load/hook state; raw indexed drops for a mob).
- `/dct gaps [export|clear|test]` — the drop-data gap collector (see below).

## Requirements

- **LootDBLua** (data dependency; kept as a separate, independent addon).

## Quest-only drops (harvested data)

LootDBLua (wowhead-derived) omits items that only drop while on-quest (e.g. Darksoul Shackle).
We fill that gap with a **bundled** supplemental table harvested from QuestieDB's Forever drop
tables — **no runtime Questie dependency**.

- `Data/QuestieDrops.lua` is generated (item→npc drop %, plus item names). It is merged into the
  mob-drop index at load, seeding only where LootDBLua has nothing.
- **Re-run after QuestieDB updates:** `python3 tools/harvest_questie_drops.py` (regenerates the file
  in place; it's committed so the addon needs no Python at runtime). The generated file is
  auto-generated — do not edit it by hand.

## Contributing drop-data gaps

When you hover an open-world mob (or an item) that has **no drop data in any source**, the addon
quietly records it — with name/zone/level/count — into its SavedVariables. These "gaps" are the
Forever-specific candidates a targeted scrape should cover. They **persist across sessions**, so you
don't have to export before logging out.

- `/dct gaps` — list what's been collected.
- `/dct gaps export` — open a copyable block (Ctrl+C). Paste it into a new issue via the **Drop-data
  gaps** template at `github.com/defnotjec/DropChanceTooltip-Forever/issues/new?template=gaps.yml`.
- `/dct gaps test` — inject a synthetic entry to see the flow; `/dct gaps clear` to reset.

A GitHub Action (`.github/workflows/collect-gaps.yml`) parses submitted issues with `tools/ingest_gaps.py`
and merges new ids into the scrape hit lists — consolidating gaps across sessions/players into one
scan list. NPC gaps are high-signal (a mob with no drop table is a real candidate); item gaps are
noisier (worn/quest/vendor gear that was never a mob drop). See `tools/DATA_PIPELINE.md`.

## Roadmap

- Material aggregation: for common mats, show mob-type + level ranges (needs per-mob level/type
  data; planned via QuestieDB cross-reference, later migrated into a bundled DB).

## Attribution / license

Original **DropChanceTooltip** and **LootDBLua** by **astroVermilion**. This is a personal Forever
port; upstream carries no explicit license in the distributed files. Do not redistribute publicly
without confirming the original author's license and preserving attribution.

[DropChanceTooltip]: https://www.curseforge.com/wow/addons (astroVermilion)
