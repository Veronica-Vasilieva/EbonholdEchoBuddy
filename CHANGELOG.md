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
