# EbonholdEchoBuddy

> **WoW 3.3.5a (WotLK) addon for the Project Ebonhold server**

A three-in-one echo companion: it advises the best build for your class and role, automatically selects echoes for you, and gets smarter with every run through a self-improving AI learning engine.

---

## Features

### Build Advisor
Browse the full echo database filtered by your class and role. Each echo is scored using a weighted algorithm that factors in quality tier, role-family relevance, build synergy, and stack awareness — so you always know what's worth taking.

- Supports all 10 classes and all 5 roles (Tank, Healer, Melee DPS, Ranged DPS, Caster DPS)
- Scores up to 50 echoes ranked highest-to-lowest
- Hover any row to see a full tooltip breakdown: base score, ELO adjustment, run adjustment, and AI confidence
- **Use My Character** button auto-fills your logged-in class
- Right-click any echo to **Favourite** or **Blacklist** it instantly

### Auto-Select
Hooks directly into the echo choice popup and automatically picks the highest-scoring option the moment it appears — no clicking required.

- Configurable delay before selecting (default 0.6 s) so the UI has time to render
- On-screen toast notification shows what was picked, why, and the **2nd and 3rd alternatives** considered
- Toggle on/off instantly with `/ebauto` or from the GUI
- **Auto-Select Level Cap** — configure a level at which auto-select turns itself off automatically, so you can take manual control of your Banishes and Rerolls from that point onward

### Auto-Banish / Auto-Reroll
When every offered echo is on your blacklist, the addon automatically fires Banish or Reroll (your choice) to get a fresh set of options — without you having to lift a finger.

- Enabled by default; toggle and mode selector in the **Settings tab**
- Three action modes: **Banish**, **Reroll**, or **Banish-then-Reroll** (tries Banish first, falls back to Reroll if banishes are exhausted)
- Loops automatically when multiple banishes are needed in a row — polls for the replacement offer after each server round-trip and fires again if the new choices are still all blacklisted
- When both Banishes and Rerolls are exhausted, silently falls back to picking the best available echo from the offered choices (no chat spam)
- **Manual Banish and Reroll buttons** are also available in the auto-select strip for instant one-click use while the selection screen is open

### AI Learning Engine
Every echo choice and every run outcome teaches the addon which echoes actually perform best. Three independent signals are combined:

| Signal | How it works |
|---|---|
| **ELO ratings** | Each time echoes are offered together, the chosen one "beats" the unchosen ones. Ratings update using chess-style ELO (K=32 for new echoes, K=16 once established). Stored **per class+role** (e.g. WARRIOR_Tank) so a Warrior's data never influences a Mage. |
| **Run EMA** | On death, every echo in that run gets its average level-reached updated: `avg = 0.70 * old + 0.30 * new`. Echoes that survive to higher levels score better. |
| **UCB1 exploration** | Rarely-seen echoes receive a small bonus to prevent the model permanently ignoring uncommon picks. The denominator is scoped per class+role for accurate exploration. |

**Confidence blending** means the advisor starts at 100% static scoring and gradually shifts toward AI scores as data accumulates. Full AI confidence is reached after 30 comparisons per echo. Confidence is shown on every row:

| Indicator | Meaning |
|---|---|
| Grey `(?)` | No data — static score only |
| Yellow `(~)` | Learning (3–9 comparisons) |
| Orange `(+)` | Building (10–29 comparisons) |
| Green `(AI)` | Confident (30+ comparisons) |

Learning data persists across sessions via `SavedVariables` and is stored per class+role, so your Warrior Tank data never pollutes your Mage Caster DPS data.

---

## Installation

> **Important:** The addon folder must be named exactly `EbonholdEchoBuddy`. If you download a zip from GitHub the extracted folder may be named something like `EbonholdEchoBuddy-main` or `EbonholdEchoBuddy_tmp_release` — rename it to `EbonholdEchoBuddy` before placing it in your AddOns directory, otherwise WoW will not load it.

### From the Releases page (recommended)

1. Go to the [Releases page](../../releases/latest) and download `EbonholdEchoBuddy-v4.16.zip`
2. Extract the zip — you will get a folder called `EbonholdEchoBuddy`
3. Copy that folder into your WoW AddOns directory:
   ```
   World of Warcraft\Interface\AddOns\EbonholdEchoBuddy\
   ```
4. The final path to the main file should look like:
   ```
   Interface\AddOns\EbonholdEchoBuddy\EbonholdEchoBuddy.lua
   ```
5. Log in and type `/eb` to open the window

### From source (git clone)

1. Clone the repository:
   ```
   git clone https://github.com/Veronica-Vasilieva/EbonholdEchoBuddy.git
   ```
2. Copy the cloned folder into your AddOns directory — the folder is already named `EbonholdEchoBuddy`, no rename needed
3. Log in and type `/eb` to open the window

> The addon requires **ProjectEbonhold** to be present — this ships with the Project Ebonhold client and loads automatically.

---

## Slash Commands

| Command | Effect |
|---|---|
| `/eb` or `/echobuild` | Open / close the main window |
| `/ebauto` | Toggle auto-select on or off |
| `/ebstats` | Print AI learning stats to chat for your current class |
| `/ebreset [role]` | Wipe AI data for your current class + role (or all if omitted) |
| `/ebblacklist` | List all blacklisted echoes |
| `/ebblacklist clear` | Remove all echoes from the blacklist |
| `/ebscan` | Dump `sendToServer` availability, current Banish/Reroll charges, and the active offer list with blacklist status — useful for diagnosing Banish/Reroll issues |
| `/eb help` | List all commands |

---

## Scoring Formula

```
Static score  =  QualityBase[quality]
               + primaryBonus   * difficultyMult * depthScale
               + secondaryBonus * difficultyMult * depthScale

Synergy bonus   = FAMILY_SYNERGY_BONUS (8) * min(echoes_in_build_with_same_family, 3)
Stack bonus     = +20 if one pick away from completing a stack
               = -999 if already at maxStack (echo excluded)
Favourite bonus = +25 if echo is starred by the player
Build bonus     = +50 if echo is on the active named build's priority list

ELO adjustment  = clamp((ELO - 1200) / 400 * 25,  -25, +25)
Run adjustment  = clamp((avgLevelReached / 80 - 0.5) * 30,  -15, +15)
UCB1 bonus      = min(8 * sqrt(ln(roleTotal) / comparisons),  10)

confidence      = min(1.0, comparisons / 30)

Final score     = StaticScore + Synergy + Stack + Favourite + Build
                + (ELO_adj + Run_adj) * confidence
                + UCB1_bonus * (1 - confidence)
```

**Depth scaling** — as you progress deeper into a run, primary role bonuses increase by up to +30% at level 80 and survivability bonuses decrease by up to 50%, rewarding offensive specialisation in the late game.

Quality base values: Common=10, Uncommon=20, Rare=30, Epic=40, Legendary=50
Role primary bonus: +40 | Secondary bonus: +5 to +20 depending on role

---

## Difficulty Presets

Switch between presets in the **Settings tab** to tune the scoring toward your playstyle:

| Preset | Primary mult | Secondary mult | Best for |
|---|---|---|---|
| **Standard** | x1.0 | x1.0 | General play |
| **Speedrun** | x1.4 | x0.4 | Maximum damage output |
| **Hardcore** | x0.7 | x1.8 | Maximum survivability |

---

## Role Configurations

| Role | Primary Family | Secondary Family |
|---|---|---|
| Tank | Tank | Survivability |
| Healer | Healer | Survivability |
| Melee DPS | Melee DPS | Survivability |
| Ranged DPS | Ranged DPS | Survivability |
| Caster DPS | Caster DPS | Survivability |

---

## Favourites & Blacklist

**Favourites** — Right-click any echo in the Advisor and select **Add to Favourites**. Starred echoes:
- Receive a flat +25 score bonus
- Are sorted to the top of the advisor list (above all other echoes)
- Display with a `*` prefix and highlighted row

**Blacklist** — Right-click any echo and select **Add to Blacklist**, or open the **Blacklist Manager** with the `Blacklist` button. Blacklisted echoes:
- Are completely excluded from auto-select
- Appear at the very bottom of the advisor list with a muted red style
- Can be removed individually or all at once with **Clear All**

**All-ranks behaviour** — echoes exist in multiple quality tiers (Common through Epic) that share the same underlying ability. Blacklisting or favouriting any rank of an echo applies to **all ranks simultaneously**, so you never need to handle each quality separately. The same rule applies when removing from the list.

An echo cannot be both Favourited and Blacklisted at the same time — adding to one automatically removes from the other.

**Spell icons** — every row in the Blacklist Manager displays the echo's spell icon for quick visual identification, matching the style used elsewhere in the game UI.

---

## GUI Tabs

The main window (`/eb`) is organised into five tabs:

### Advisor tab
The core echo browser. Select your class and role, click **Recommend Echoes**, and browse the ranked list. Right-click rows to Favourite or Blacklist. The AI stats bar at the bottom shows how much data the model has for the selected class+role.

### Stats tab
A live view of your AI learning progress:
- Per-role comparison counts, run counts, and echo coverage for your current character's class
- **Run history** — a scrollable list of your last 50 runs, showing date/time, class, role, and level reached

### Discovery tab
Novelty Mode — boosts the score of echoes you have not yet picked this run, encouraging wider build variety.
- Toggle on/off with the checkbox
- Three bonus strength presets: **Mild** (+20), **Normal** (+35), **Strong** (+50)
- Live **Current Run Echoes** list showing every echo acquired so far with stack counts

### Builds tab
Create and manage named echo priority lists.
- Add up to 20 named builds, each containing any echoes you want to prioritise
- Set an active build — matching echoes receive a **+50 score bonus** in auto-select (rank-agnostic: any quality tier of the same echo counts)
- Search for echoes by name and add them to a build with one click
- Remove individual echoes or delete an entire build
- **Per-build blacklist** — each build has its own independent blacklist shown side-by-side with its priority list
  - Toggle between **[Priority]** and **[Blacklist]** mode using the buttons next to the search box to control which list search results are added to
  - The per-build blacklist applies to all quality ranks of an echo (groupId-aware, same as the global blacklist)
  - Both the global blacklist and the active build's per-build blacklist are checked during auto-select — echoes on either list are excluded

### Settings tab
All configuration options in one place (scrollable — content is fully accessible even on smaller screens):
- **Blend AI scores** toggle
- **Auto-select delay** (0.0 – 5.0 seconds)
- **Difficulty preset** selector (Standard / Speedrun / Hardcore)
- **Blacklist behaviour** — choose Banish, Reroll, or Banish-then-Reroll when all choices are blacklisted
- **Auto-Select Level Cap** — enter a level and click **Set** to have auto-select turn itself off when you reach that level, freeing you to spend your Banishes and Rerolls manually. Click **Clear** to disable the cap. A status line confirms whether a cap is active.
- **Export / Import** learning data — share your AI model with guildmates or back it up between clients

---

## Export / Import

Your entire AI learning database can be exported to a compact string and imported on another client or shared with other players.

1. Open `/eb` -> **Settings** tab
2. Click **Export Data** — the string appears in the box (Ctrl+A, Ctrl+C to copy)
3. On the target client, paste the string into the Import box and click **Import Data**

Importing **merges** with existing data rather than replacing it, so you can safely combine databases from multiple characters.

---

## Saved Variables

| Variable | Contents |
|---|---|
| `EchoBuddyDB` | Settings: selected role, auto-select toggle, delay, AI toggle, difficulty preset, blacklist, favourites, builds, run history, auto-disable level cap |
| `EchoBuddyLearnDB` | Per class+role, per-echo AI data: ELO rating, wins, losses, run count, average level reached |

At each login, zero-data entries are automatically pruned from `EchoBuddyLearnDB` to keep the file lean, and all ELO ratings receive a small 2% nudge toward the baseline (1200) to prevent permanently extreme values from old data.

---

## Requirements

- WoW client: **3.3.5a (build 12340)**
- Server: **Project Ebonhold** (requires `ProjectEbonhold.PerkDatabase` and `ProjectEbonhold.PerkService`, both of which ship with the Project Ebonhold client)
- The addon folder must be named **`EbonholdEchoBuddy`** exactly — see Installation above
- The addon is a **passive observer** — it wraps existing server functions non-destructively and never modifies the base addon

---

## Version History

| Version | Changes |
|---|---|
| 4.16 | No chat spam when Banish/Reroll charges are exhausted — falls back silently to auto-selecting the best available echo instead |
| 4.15 | Auto-banish/reroll no longer gets stuck after the first action — self-rescheduling loop polls for new choices after each server round-trip and fires again if they are still blacklisted |
| 4.14 | Banish now sends the correct perk index to the server instead of the spell ID |
| 4.13 | Banish and Reroll now check remaining charges before sending — banish_reroll mode correctly falls through to Reroll when Banishes are exhausted |
| 4.12 | Banish and Reroll use the confirmed server protocol (`sendToServer`) directly — eliminates all frame-click unreliability · `/ebscan` diagnostic command added |
| 4.11 | Removed `IsVisible()` guard from Banish/Reroll button detection · per-card button scan fallback added · existing installs with auto-banish disabled are silently migrated to enabled |
| 4.10 | Auto-banish/reroll fires independently of auto-select (triggers whenever all offers are blacklisted, even during manual play) · enabled by default |
| 4.9 | Manual Banish and Reroll buttons added to the auto-select strip · `/ebscan` slash command for diagnosing Banish/Reroll state |
| 4.8 | Settings tab wrapped in a scroll frame — content below the window edge (e.g. Auto-Select Level Cap) is now fully accessible |
| 4.7 | Auto-Select Level Cap — set a level at which auto-select turns itself off so you can spend Banishes/Rerolls manually |
| 4.6 | Per-build blacklist in the Builds tab — each build has its own independent blacklist checked alongside the global blacklist during auto-select |
| 4.5 | Main window enlarged (660x640 to 780x680) · Builds tab layout overlap fixes (Deactivate button and Build Name row no longer collide) |
| 4.4 | Discovery tab (Novelty Mode, live run echo list) · Builds tab (named priority build lists, +50 score bonus, rank-agnostic groupId matching) · Novelty and build bonuses integrated into auto-select scoring · 5-tab GUI |
| 4.3 | Banish/Reroll now clicks PerkChoiceN buttons directly (confirmed via frame-stack) rather than guessing API names |
| 4.2 | Auto-banish/reroll when all choices are blacklisted · Settings: action mode selector (Banish / Reroll / Banish then Reroll) |
| 4.1 | All-ranks blacklist/favourite (groupId-based) · Spell icons in Blacklist Manager · Deduplicated search results · Hardened IsBlacklisted with legacy save compatibility · ASCII symbol fixes for WoW 3.3.5a font |
| 4.0 | Full rewrite: build synergy scoring · stack awareness · class-specific ELO · per-role UCB1 · depth scaling · favourites · toast top-3 · spell cache · ELO decay · run history · difficulty presets · export/import · tabbed GUI |
| 3.0 | AI learning engine (ELO + EMA + UCB1), confidence blending, visual redesign |
| 2.0 | Auto-select engine, PerkUI hook, toast notifications, blacklist manager |
| 1.0 | Build Advisor GUI, static scoring, class/role filtering |

---

## Contributors

| Contributor | Contribution |
|---|---|
| **Nu/Veronica** | Author — all core development |
| **SypherRed** | PR #2 — independently proposed the grouped-rank IsBlacklisted defensive check; their hardened approach was adopted for legacy save compatibility |

---

## Author

**Nu/Veronica** — built for the Project Ebonhold community.
