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

## Requirements

- **LootDBLua** (data dependency; kept as a separate, independent addon).

## Roadmap

- **Quest-only drops:** LootDBLua (wowhead-derived) omits items that only drop while on-quest, so
  they can't be shown yet. Planned: harvest Questie's quest/npc drop data into our own bundled
  supplemental table (build-time; no runtime Questie dependency).
- Material aggregation: for common mats, show mob-type + level ranges (needs per-mob level/type
  data; planned via QuestieDB cross-reference, later migrated into a bundled DB).

## Attribution / license

Original **DropChanceTooltip** and **LootDBLua** by **astroVermilion**. This is a personal Forever
port; upstream carries no explicit license in the distributed files. Do not redistribute publicly
without confirming the original author's license and preserving attribution.

[DropChanceTooltip]: https://www.curseforge.com/wow/addons (astroVermilion)
