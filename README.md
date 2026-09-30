# DropChanceTooltip — Forever port

Adds **drop-chance and drop-source information to item and mob tooltips** on the
**WoW: Forever** client (Interface `16001`), plus owned-item counts across your
characters and a material-source summariser for gathered/crafted goods.

This is a port and substantial enhancement of **astroVermilion's**
`DropChanceTooltip`, which targeted TBC (Interface `20504`) and no longer loads on
Forever. It reads its loot data from **LootDBLua** (also by astroVermilion).

> [!IMPORTANT]
> **This addon requires [LootDBLua](#requirements--installation).** It is a hard
> dependency — without it installed and enabled, WoW will not load
> DropChanceTooltip. See installation below.

<!-- Media: screenshots / GIFs go here (item tooltip, mob tooltip, material summary). -->

---

## Contents

- [Requirements & installation](#requirements--installation)
- [Features](#features)
  - [Item tooltips](#item-tooltips)
  - [Mob tooltips](#mob-tooltips)
  - [Owned counts](#owned-counts)
  - [Material aggregation](#material-aggregation)
- [Usage](#usage)
  - [Options panel](#options-panel)
  - [Slash commands](#slash-commands)
  - [Keybind & macro](#keybind--macro)
- [Contributing drop-data gaps](#contributing-drop-data-gaps)
- [Data & tooling](#data--tooling)
- [Forever port notes](#forever-port-notes)
- [Attribution & license](#attribution--license)

---

## Requirements & installation

| Requirement | Notes |
|---|---|
| **WoW: Forever client** | Interface `16001`. |
| **[LootDBLua](https://github.com/) by astroVermilion** | **Required.** The item→source loot database (~10 MB). DropChanceTooltip reads it at runtime; it is never modified. |

**Install:**

1. Install **LootDBLua** into `Interface/AddOns/LootDBLua`.
2. Install **DropChanceTooltip** into `Interface/AddOns/DropChanceTooltip`.
3. Make sure **both** are enabled at the character-select AddOns screen.
4. Log in. Hover an item or an open-world mob — the extra tooltip lines appear.

If DropChanceTooltip is greyed out / "Dependencies" in the addon list, LootDBLua is
missing or disabled.

---

## Features

### Item tooltips

- **Rarity-scaled source list.** Rather than dumping every source (Linen Cloth has
  ~860), the tooltip shows the **top N sources by drop %**, where N scales with the
  item's rarity (grey 3 → epic 15 → legendary+ 20; tunable in `sourceCountByRarity`).
  **Hold Shift** to expand the full list.
- **Owned counts** — how many you own, across characters (see [below](#owned-counts)).
- **Material summary** — for gathered/crafted/skinned/mined goods, a single
  summarised line instead of a mob list (see [below](#material-aggregation)).

### Mob tooltips

Hover an open-world mob to see its notable drops, in priority order:

1. **Quest Items** — shown only for quests you're currently on (overridable).
2. **Blue / epic** items, individually.
3. The **main common drops** — top N by %, with a configurable **minimum-%
   floor** so vendor junk is hidden.
4. Collapsible **"various X"** groups — gems / patterns / schematics / enchants /
   recipes / scrolls / greens — each independently **show / collapse / hide** in
   options.

**Hold Shift** to reveal everything. Built on a source→items reverse index derived
from LootDBLua at runtime (LootDBLua itself is untouched).

### Owned counts

Hovering an item shows how many you own. By default it's a single grand total:

```
You have        54
```

Hold **Shift** to expand — everything on-person first (you, then each other
character), a blank line, then a **Bank** section per character:

```
You have        34
  Alt            8

Bank
  You           20
```

Counts come from live `GetItemCount` for the current character, plus per-character
bag/bank snapshots recorded as you play (and open the bank on) each one. Five
toggles, in the options panel (Item column) or via `/dct count`:

- `selfbags`, `selfbank`, `altsbags`, `altsbank` — what's included in the total and
  the breakdown.
- `consolidate` — show the split on the collapsed line too:
  `You have  54 (34 bags, 20 bank)`.

Alt counts appear only for characters you've logged into since installing; bank
figures update when you open that character's bank.

### Material aggregation

For trade materials, showing a long list of individual mobs isn't useful — you want
to know **where to farm**. With material aggregation on (default; toggle
`/dct materials`), the tooltip collapses those sources into one summarised line:

| Material kind | Line | Example right-hand text |
|---|---|---|
| Herbs / ore | **Gathered** | top zones, each with its level range |
| Ore → bars | **Smelted** | `Mining <skill>` |
| Stone / raw ore | **Mined** | `Mining <level range>` |
| Leather / hides | **Skinning** | beast type + level range |
| Cloth | *(mob summary)* | normal-mob type + level range (e.g. `21–36`) |
| Crafted goods | **Crafted** | `<Profession> <skill>` (Tailoring / Alchemy / Engineering …) |

**Hold Shift** on a gathered material for the densest zones, each with its level
range colour-coded by difficulty. Level ranges are derived from per-mob level data
with a configurable drop-% floor and an option to use **trash mobs only** (so a
rare/elite outlier doesn't widen the range). All of this data is **bundled** — see
[Data & tooling](#data--tooling).

---

## Usage

### Options panel

Open with **`/dct`** (or Esc → Options → AddOns → DropChanceTooltip). Covers: master
toggle, rarity filters, per-group show/collapse/hide, "expand all", "always show
quest items", the minimum-% slider, the owned-count toggles, and the
material-aggregation toggles.

### Slash commands

| Command | Description |
|---|---|
| `/dct` | Open the options panel. |
| `/dct toggle` \| `on` \| `off` | Master enable toggle. |
| `/dct count [selfbags\|selfbank\|altsbags\|altsbank\|consolidate]` | Toggle owned-count options. |
| `/dct materials` \| `mats` | Toggle material aggregation (summary vs. full mob list). |
| `/dct matmin <pct>` | Minimum drop-% for a mob to count toward a material's level range. |
| `/dct mattrash` | Use trash mobs only when computing level ranges. |
| `/dct various` | Toggle the "various X" grouped mob-drop sections. |
| `/dct gaps [export\|clear\|test]` | The drop-data gap collector (see below). |
| `/dct npc [id]` | Show the raw indexed drops for the targeted / given mob. |
| `/dct diag` | Load / hook diagnostics. |
| `/dct prof` | Profession-source diagnostics. |
| `/dct matdump` | Dump the computed material aggregation for the hovered item. |
| `/dct whoami` | Character-name probe (owned-count debugging). |
| `/dct debugchat` | Toggle verbose debug output. |

### Keybind & macro

- **Keybind:** "Toggle Drop Tooltips" (category *AddOns*), from `Bindings.xml`.
- **Macro:** `/run DropChanceTooltip_Toggle()`.

---

## Contributing drop-data gaps

When you hover an open-world mob (or item) with **no drop data in any source**, the
addon quietly records it — name / zone / level / count — into its SavedVariables.
These "gaps" are the Forever-specific candidates a targeted scrape should cover.
They **persist across sessions**, so you don't have to export before logging out.

- `/dct gaps` — list what's been collected.
- `/dct gaps export` — open a copyable block (Ctrl+C). Paste it into a new issue via
  the **Drop-data gaps** template at
  `github.com/defnotjec/DropChanceTooltip-Forever/issues/new?template=gaps.yml`.
- `/dct gaps test` — inject a synthetic entry to preview the flow; `/dct gaps clear`
  to reset.

A GitHub Action (`.github/workflows/collect-gaps.yml`) parses submitted issues with
`tools/ingest_gaps.py` and merges new IDs into the scrape hit-lists — consolidating
gaps across sessions and players into one scan list. NPC gaps are high-signal (a mob
with no drop table is a real candidate); item gaps are noisier (worn / quest /
vendor gear that was never a mob drop). See `tools/DATA_PIPELINE.md`.

---

## Data & tooling

All lookup data ships **bundled as Lua** in `Data/` — the addon needs no Python at
runtime. The `tools/` scripts regenerate these files from upstream sources and are
committed for reproducibility.

| File | Contents | Regenerate with |
|---|---|---|
| `Data/QuestieDrops.lua` | Quest-only drops LootDBLua omits (item→npc %, names), harvested from QuestieDB. Merged into the mob index at load, seeding only where LootDBLua has nothing. **No runtime Questie dependency.** | `tools/harvest_questie_drops.py` |
| `Data/GatherNodes.lua` | Herb / ore → zones. | `tools/harvest_gathermate.py` |
| `Data/MobLevels.lua` | NPC → level range. | `tools/harvest_mob_levels.py` |
| `Data/SkinningSources.lua`, `SkinningLevels.lua` | Leather → beasts / levels. | `tools/wowhead_scrape.py --skinning` |
| `Data/AlchemyRecipes.lua`, `CraftRecipes.lua` | Crafted goods → profession + skill. | `tools/` converters |
| `Data/MiningProducts.lua` | Ore → bars / smelting. | `tools/` converters |

Generated files carry an "auto-generated — do not edit" header; re-run the tool
after the upstream source updates.

---

## Forever port notes

What this version changes versus astroVermilion's original:

- **Tooltip hooks** moved from the removed `OnTooltipSetItem` / `OnTooltipSetUnit`
  scripts to `TooltipDataProcessor.AddTooltipPostCall` (legacy path kept as a
  fallback). Item / NPC IDs are read from the post-call `data` (`.id` / `.guid`).
- **`GetItemInfo`** (removed as a global on this client) is shimmed to
  `C_Item.GetItemInfo`.
- **`## Interface`** bumped to `16001`.
- **`Bindings.xml` is intentionally *not* listed in the `.toc`** — this client
  auto-loads it from the addon folder; listing it double-loads and throws
  "Unrecognized XML: Binding" on login.
- Added the rarity-scaled source list, mob tooltips, owned counts, material
  aggregation, the options panel, and the drop-data gap collector.

---

## Attribution & license

Original **DropChanceTooltip** and **LootDBLua** by **astroVermilion**. This is a
personal Forever port and enhancement.

> Upstream carries no explicit license in the distributed files. **Do not
> redistribute LootDBLua** (or upstream code) without confirming the original
> author's license and preserving attribution. This repository distributes only the
> port's own code and the bundled, independently-generated `Data/` tables.
