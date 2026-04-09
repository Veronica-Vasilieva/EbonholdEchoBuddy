## [4.7] - 2026-04-09

### Added
- **Auto-Select Level Cap** (Settings tab) — set a level at which auto-select turns itself off automatically
  - New "Disable at level" input with **Set** and **Clear** buttons in a dedicated Settings section
  - When the player reaches the configured level, auto-select is disabled, the checkbox in the Advisor tab is unchecked, and a chat notification is printed
  - Notification text: "Auto-select disabled at level N. You can now use your Banishes and Rerolls manually."
  - Setting persists across sessions via SavedVariables (`autoDisableLevel`); Clear sets it back to 0 (disabled)
  - Live status line below the input shows whether a cap is active and at which level

## [4.6] - 2026-04-08

### Added
- Per-build blacklist in the Builds tab editor
  - Each build now has its own blacklist stored in `build.buildBlacklist` (separate from the global blacklist)
  - **[Priority] / [Blacklist]** mode toggle buttons next to the search box control where search results are added
  - Build Blacklist panel shown side-by-side with the Priority List in the lower editor section
  - Adding to the build blacklist applies to all ranks of an echo (groupId-aware, same as the global blacklist)
  - Remove button per row; deduplicates display by groupId
  - Active build's per-build blacklist is checked alongside the global blacklist in auto-select — echoes on either list are excluded
  - `IsBuildBlacklisted(spellId)` helper performs the per-build check with legacy-save compatibility (group scan fallback)
- Vertical mid-divider separates Priority List and Build Blacklist columns visually

### Changed
- Search box narrowed slightly (210px → 180px) to make room for the mode toggle buttons

## [4.5] - 2026-04-07

### Fixed
- Main window enlarged from 660x640 to 780x680 to reduce text crowding
- Builds tab: [Deactivate] button re-anchored to TOPRIGHT so it no longer overlaps the right column editor
- Builds tab: editor pane shifted down to y=-44 so the "Build Name" row no longer overlaps the "Active Build" header row
- Builds tab: column divider x adjusted to match new right-column start position

## [4.4] - 2026-04-07

### Added
- **Discovery tab** — "Novelty Mode" prioritises echoes not yet acquired in the current run
  - Checkbox toggle: "Prioritize echoes not yet in current run"
  - Three bonus strength presets: Mild (+20), Normal (+35), Strong (+50)
  - Live "Current Run Echoes" scroll list showing every echo acquired so far with stack counts
  - Deduplicates by groupId so multi-rank echoes appear as one entry
- **Builds tab** — users can create named priority build lists
  - Left column: scrollable list of saved builds; [Set]/[ON] to activate, [X] to delete
  - Right column: build editor — name input, echo search (type 2+ chars), up to 6 instant search results (click to add), scrollable priority list with per-echo Remove button, Delete Build button
  - Active build name shown at top; [Deactivate] to clear
  - Cap of 20 saved builds
  - Builds persist via `EchoBuddyDB.builds` SavedVariable
- Auto-select scoring now applies **novelty bonus** to echoes not yet in `currentRunStackCounts`
- Auto-select scoring now applies **+50 build priority bonus** to echoes matching the active build list (groupId-aware via `SameGroup`)
- `SameGroup(sidA, sidB)` helper — true if both spellIds are identical or share a groupId
- `GetActiveBuild()` helper — returns `db.builds[db.activeBuildIdx]` or nil
- Two new DB keys: `prioritizeNew` (boolean), `noveltyStrength` ("Mild"/"Normal"/"Strong")
- Tab bar now shows 5 tabs (Advisor | Stats | Discovery | Builds | Settings), each 120px wide

## [4.3] - 2026-04-06

### Fixed
- Banish and Reroll now click the actual `PerkChoiceN` UI buttons directly rather than relying solely on guessed PerkService function names
  - Frame-stack inspection confirmed both Banish and Reroll are rendered as `PerkChoice2` (PerkChoiceN template) buttons
  - `ClickPerkChoiceByText()` scans `PerkChoice1`–`PerkChoice9`, strips colour codes from button text, and clicks the one whose label contains "banish" or "reroll"
  - Checks both `GetText()` on the button and the child `PerkChoiceNText` FontString for compatibility with different button templates
  - PerkService API name-probing is retained as a secondary fallback if the button is not visible

## [4.2] - 2026-04-06

### Added
- Auto-banish/reroll when all offered choices are blacklisted
  - New toggle in Settings tab: "Auto-banish/reroll when all choices are blacklisted"
  - Three action modes selectable in Settings: Banish, Reroll, or Banish-then-Reroll fallback
  - `TryBanishReroll()` probes PerkService at runtime for all known naming variants (BanishPerk, Banish, BanishPerks, SkipPerk, RerollPerk, Reroll, RerollPerks, RefreshPerks, etc.) since the server source is not accessible
  - On-screen toast confirms the action was triggered
  - Clear error message printed to chat if the required PerkService function cannot be found
- Two new SavedVariables keys: `autoBanishReroll` (boolean) and `blacklistAction` ("banish" | "reroll" | "banish_reroll")

## [4.1] - 2026-04-05

### Added
- Spell icons in Blacklist Manager rows (both search results and active blacklist entries)
- `GetGroupSpellIds()` helper — resolves any spellId to all sibling spellIds sharing the same groupId

### Changed
- Blacklisting or favouriting any rank of an echo now applies to all ranks simultaneously (groupId-based)
- `BlacklistCount` and `FavouriteCount` now count unique echoes (by groupId) instead of raw spellId entries
- Deduplicated Blacklist Manager search results — one entry per echo, showing highest quality rank
- Hardened `IsBlacklisted` with legacy save compatibility: checks direct spellId first (fast path), then scans the full group (handles saves that only stored one rank)

### Fixed
- Duplicate entries appearing in Blacklist Manager search when multiple quality tiers of the same echo matched the query
- Blacklisting one rank of an echo not affecting other ranks in auto-select or scoring

### Security
- All unsupported Unicode characters replaced with ASCII equivalents throughout for WoW 3.3.5a font compatibility (FRIZQT__.TTF does not render: star, circle, arrow, gear, blackout symbols)

## [4.0] - 2026-04-04

### Added
- Full rewrite of scoring, learning, and GUI
- Build synergy scoring (family bonus stacks per run)
- Stack awareness (maxStack penalty / completion bonus)
- Class-specific ELO keys (per class+role, not global)
- Per-role UCB1 denominator fix
- Run depth multiplier (primary bonus scales with level progress)
- Favourites system with +25 score bonus and pinned-to-top display
- Toast shows top-3 alternatives on auto-select
- Spell cache (GetSpellInfo results cached per spellId)
- ELO stale data decay at login (2% nudge toward 1200)
- Run history (last 50 runs) with Stats tab
- Hook safety guard (never double-hooks PerkUI.Show)
- SavedVar pruning at login (zero-data entries removed)
- Difficulty presets: Standard / Speedrun / Hardcore
- Export / Import AI learning data (merge-safe serialization format)
- Tab-based GUI: Advisor | Stats | Settings
