# EbonholdEchoBuddy

> **WoW 3.3.5a (WotLK) addon for the Project Ebonhold private server**

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

1. Download or clone this repository
2. Copy the `EbonholdEchoBuddy` folder into your WoW addons directory:
   ```
   World of Warcraft\Interface\AddOns\EbonholdEchoBuddy\
   ```
3. The addon requires **ProjectEbonhold** to be present (it ships with the Valanior / Project Ebonhold client)
4. Log in and type `/eb` to open the window

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

ELO adjustment  = clamp((ELO - 1200) / 400 * 25,  -25, +25)
Run adjustment  = clamp((avgLevelReached / 80 - 0.5) * 30,  -15, +15)
UCB1 bonus      = min(8 * sqrt(ln(roleTotal) / comparisons),  10)

confidence      = min(1.0, comparisons / 30)

Final score     = StaticScore + Synergy + Stack + Favourite
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

The main window (`/eb`) is organised into three tabs:

### Advisor tab
The core echo browser. Select your class and role, click **Recommend Echoes**, and browse the ranked list. Right-click rows to Favourite or Blacklist. The AI stats bar at the bottom shows how much data the model has for the selected class+role.

### Stats tab
A live view of your AI learning progress:
- Per-role comparison counts, run counts, and echo coverage for your current character's class
- **Run history** — a scrollable list of your last 50 runs, showing date/time, class, role, and level reached

### Settings tab
All configuration options in one place:
- **Blend AI scores** toggle
- **Auto-select delay** (0.0 – 5.0 seconds)
- **Difficulty preset** selector (Standard / Speedrun / Hardcore)
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
| `EchoBuddyDB` | Settings: selected role, auto-select toggle, delay, AI toggle, difficulty preset, blacklist, favourites, run history |
| `EchoBuddyLearnDB` | Per class+role, per-echo AI data: ELO rating, wins, losses, run count, average level reached |

At each login, zero-data entries are automatically pruned from `EchoBuddyLearnDB` to keep the file lean, and all ELO ratings receive a small 2% nudge toward the baseline (1200) to prevent permanently extreme values from old data.

---

## Requirements

- WoW client: **3.3.5a (build 12340)**
- Server: **Project Ebonhold** (requires `ProjectEbonhold.PerkDatabase` and `ProjectEbonhold.PerkService`)
- The addon is a **passive observer** — it wraps existing server functions non-destructively and never modifies the base addon

---

## Version History

| Version | Changes |
|---|---|
| 4.1 | All-ranks blacklist/favourite (groupId-based, all quality tiers affected together) · Spell icons in Blacklist Manager rows · Deduplicated search results in Blacklist Manager (one entry per echo, highest quality shown) · Hardened IsBlacklisted with legacy save compatibility · ASCII symbol replacements throughout (WoW 3.3.5a font compatibility) · BlacklistCount/FavouriteCount now count unique echoes not raw spellId entries |
| 4.0 | Build synergy scoring · Stack awareness · Class-specific ELO keys · Per-role UCB1 fix · Run depth multiplier · Favourites system · Toast shows top-3 alternatives · Spell cache · ELO stale data decay · Run history & Stats tab · Hook safety guard · SavedVar pruning · Difficulty presets (Standard/Speedrun/Hardcore) · Export/Import AI data · Tab-based GUI (Advisor/Stats/Settings) |
| 3.0 | AI learning engine (ELO + EMA + UCB1), confidence blending, visual redesign, overflow fix |
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

**Nu/Veronica** — built for the Valanior / Project Ebonhold community.
