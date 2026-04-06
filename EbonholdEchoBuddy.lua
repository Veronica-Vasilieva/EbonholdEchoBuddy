-------------------------------------------------------------------------------
-- EbonholdEchoBuddy  v4.0
--
-- Features:
--   1. BUILD ADVISOR          /eb  — full echo database ranked by class + role
--   2. AUTO-SELECT            Hooks PerkUI.Show; picks best echo automatically
--   3. AI LEARNING ENGINE     ELO + Run EMA + UCB1 with confidence blending
--
-- v4.0 improvements over v3.0:
--   • Build synergy bonus   — echoes matching families already in your build score higher
--   • Stack awareness       — at-cap echoes are excluded; near-cap echoes get a bonus
--   • Class-specific ELO    — data stored per class+role (e.g. WARRIOR_Tank)
--   • Per-role UCB1 fix     — exploration denominator is role-scoped, not global
--   • Run depth multiplier  — bonuses scale with how deep into a run you are
--   • Favourites system     — star echoes to boost and pin them to the top
--   • Toast top-3           — auto-select toast shows the 2nd and 3rd alternatives
--   • Spell cache           — GetSpellInfo results cached to avoid repeated lookups
--   • ELO stale decay       — small nudge toward 1200 each login prevents permanent outliers
--   • Run history / Stats   — last 50 runs recorded; Stats tab shows history + AI stats
--   • Hook safety guard     — InstallHook cannot fire twice
--   • SavedVar pruning      — zero-data entries cleaned from EchoBuddyLearnDB on login
--   • Difficulty presets    — Standard / Speedrun / Hardcore scoring multipliers
--   • Export / Import       — serialize and restore the entire AI learning database
--   • Tab-based GUI         — Advisor | Stats | Settings tabs in main window
--
-- Slash commands: /eb  /echobuild  /ebauto  /ebstats  /ebreset  /ebblacklist
-------------------------------------------------------------------------------

local ADDON = "EbonholdEchoBuddy"
local currentPlayerClass = "WARRIOR"   -- set from UnitClass at PLAYER_LOGIN

-------------------------------------------------------------------------------
-- 1. CONSTANTS
-------------------------------------------------------------------------------

local DB_DEFAULTS = {
    autoSelect        = false,
    selectedRole      = "Melee DPS",
    selectDelay       = 0.6,
    useAIScores       = true,
    difficulty        = "Standard",
    autoBanishReroll  = false,
    blacklistAction   = "banish",   -- "banish" | "reroll" | "banish_reroll"
}

local CLASS_MASK = {
    WARRIOR=1, PALADIN=2, HUNTER=4, ROGUE=8, PRIEST=16,
    DEATHKNIGHT=32, SHAMAN=64, MAGE=128, WARLOCK=256, DRUID=1024,
}
local CLASS_DISPLAY  = {"Warrior","Paladin","Hunter","Rogue","Priest","Death Knight","Shaman","Mage","Warlock","Druid"}
local CLASS_INTERNAL = {"WARRIOR","PALADIN","HUNTER","ROGUE","PRIEST","DEATHKNIGHT","SHAMAN","MAGE","WARLOCK","DRUID"}
local ROLES          = {"Tank","Healer","Melee DPS","Ranged DPS","Caster DPS"}

local QUALITY_BASE = {[0]=10,[1]=20,[2]=30,[3]=40,[4]=50}

local ROLE_CONFIG = {
    ["Tank"]      = {primaryFamilies={"Tank"},       secondaryFamilies={"Survivability"}, primaryBonus=40, secondaryBonus=20},
    ["Healer"]    = {primaryFamilies={"Healer"},      secondaryFamilies={"Survivability"}, primaryBonus=40, secondaryBonus=15},
    ["Melee DPS"] = {primaryFamilies={"Melee DPS"},   secondaryFamilies={"Survivability"}, primaryBonus=40, secondaryBonus=5},
    ["Ranged DPS"]= {primaryFamilies={"Ranged DPS"},  secondaryFamilies={"Survivability"}, primaryBonus=40, secondaryBonus=5},
    ["Caster DPS"]= {primaryFamilies={"Caster DPS"},  secondaryFamilies={"Survivability"}, primaryBonus=40, secondaryBonus=5},
}

local QUALITY_COLOR = {
    [0]={1,1,1}, [1]={0.12,1,0.12}, [2]={0,0.44,1}, [3]={0.78,0.40,1}, [4]={1,0.50,0},
}
local QUALITY_NAME = {[0]="Common",[1]="Uncommon",[2]="Rare",[3]="Epic",[4]="Legendary"}

local CLASS_COLOR = {
    WARRIOR={0.78,0.61,0.43}, PALADIN={0.96,0.55,0.73}, HUNTER={0.67,0.83,0.45},
    ROGUE={1,0.96,0.41},      PRIEST={1,1,1},            DEATHKNIGHT={0.77,0.12,0.23},
    SHAMAN={0,0.44,0.87},     MAGE={0.41,0.80,0.94},     WARLOCK={0.58,0.51,0.79},
    DRUID={1,0.49,0.04},
}

local CONF_COLORS = {
    {0.4,0.4,0.4},  -- 0: no data   (grey)
    {1,0.85,0},     -- 1: learning  (yellow)
    {1,0.55,0},     -- 2: building  (orange)
    {0.1,0.9,0.1},  -- 3: confident (green)
}

-- v4.0 new scoring constants
local FAMILY_SYNERGY_BONUS   = 8      -- pts per matching family already in build
local FAMILY_SYNERGY_CAP     = 3      -- max echoes per family that grant synergy
local STACK_COMPLETION_BONUS = 20     -- bonus when one pick away from maxStack
local FAVOURITE_BONUS        = 25     -- flat bonus for starred echoes
local DEPTH_PRIMARY_SCALE    = 0.30   -- primary bonus grows by this factor at max depth
local DEPTH_SECONDARY_SCALE  = 0.50   -- secondary bonus shrinks by this factor at max depth

-- ELO constants
local ELO_START  = 1200
local ELO_K_NEW  = 32
local ELO_K_EST  = 16
local RUN_ALPHA  = 0.30
local CONF_FULL  = 30
local UCB_C      = 8
local ELO_DECAY  = 0.02   -- nudge toward 1200 per login session

-- Run history
local MAX_RUN_HISTORY = 50

-- Difficulty presets: multipliers on primaryBonus and secondaryBonus
local DIFFICULTY_PRESETS = {
    ["Standard"] = {primaryMult=1.0, secondaryMult=1.0},
    ["Speedrun"]  = {primaryMult=1.4, secondaryMult=0.4},
    ["Hardcore"]  = {primaryMult=0.7, secondaryMult=1.8},
}
local DIFFICULTY_NAMES = {"Standard","Speedrun","Hardcore"}

-------------------------------------------------------------------------------
-- 2. SPELL CACHE
-------------------------------------------------------------------------------

local SPELL_CACHE = {}
local function GetCachedSpell(spellId)
    local c = SPELL_CACHE[spellId]
    if not c then
        local name, _, icon = GetSpellInfo(spellId)
        c = {
            name = name or ("Echo #"..spellId),
            icon = icon or "Interface\\Icons\\inv_misc_questionmark",
        }
        SPELL_CACHE[spellId] = c
    end
    return c
end

-------------------------------------------------------------------------------
-- 3. SAVED-VARIABLE HELPERS
-------------------------------------------------------------------------------

local function GetDB()
    EchoBuddyDB = EchoBuddyDB or {}
    for k,v in pairs(DB_DEFAULTS) do
        if EchoBuddyDB[k] == nil then EchoBuddyDB[k] = v end
    end
    if EchoBuddyDB.blacklist  == nil then EchoBuddyDB.blacklist  = {} end
    if EchoBuddyDB.favourites == nil then EchoBuddyDB.favourites = {} end
    if EchoBuddyDB.runHistory == nil then EchoBuddyDB.runHistory = {} end
    return EchoBuddyDB
end

local function SaveRole(r)  GetDB().selectedRole = r end
local function SaveAuto(v)  GetDB().autoSelect   = v end

-- Returns all spellIds that share the same groupId as the given spellId.
-- For ungrouped echoes (groupId nil or 0) returns just the single spellId.
-- This ensures blacklist/favourite actions apply to every rank of an echo.
local function GetGroupSpellIds(spellId)
    local perkDB = ProjectEbonhold and ProjectEbonhold.PerkDatabase
    if not perkDB then return {spellId} end
    local perk = perkDB[spellId]
    if not perk then return {spellId} end
    local gid = perk.groupId
    if not gid or gid == 0 then return {spellId} end
    local ids = {}
    for sid, p in pairs(perkDB) do
        if p.groupId == gid then table.insert(ids, sid) end
    end
    return ids
end

-- Blacklist helpers
local function IsBlacklisted(spellId)
    -- Check the direct entry first (fast path), then scan the whole group
    -- so legacy saves with only one rank stored are still handled correctly
    local bl = GetDB().blacklist
    if bl[spellId] == true then return true end
    for _, sid in ipairs(GetGroupSpellIds(spellId)) do
        if bl[sid] == true then return true end
    end
    return false
end
local function ToggleBlacklist(spellId)
    local db      = GetDB()
    local groupIds = GetGroupSpellIds(spellId)
    if db.blacklist[spellId] then
        -- Remove every rank in the group
        for _, sid in ipairs(groupIds) do
            db.blacklist[sid] = nil
        end
        return false
    else
        -- Add every rank in the group; a blacklisted echo cannot be a favourite
        for _, sid in ipairs(groupIds) do
            db.blacklist[sid]  = true
            db.favourites[sid] = nil
        end
        return true
    end
end
local function BlacklistCount()
    -- Count unique echoes (groups), not raw spellId entries
    local perkDB = ProjectEbonhold and ProjectEbonhold.PerkDatabase
    local bl     = GetDB().blacklist
    local seen, n = {}, 0
    for sid in pairs(bl) do
        local perk = perkDB and perkDB[sid]
        local gid  = perk and perk.groupId
        if gid and gid > 0 then
            if not seen[gid] then seen[gid] = true; n = n + 1 end
        else
            n = n + 1
        end
    end
    return n
end

-- Favourites helpers
local function IsFavourite(spellId)
    return GetDB().favourites[spellId] == true
end
local function ToggleFavourite(spellId)
    local db       = GetDB()
    local groupIds = GetGroupSpellIds(spellId)
    if db.favourites[spellId] then
        for _, sid in ipairs(groupIds) do
            db.favourites[sid] = nil
        end
        return false
    else
        for _, sid in ipairs(groupIds) do
            db.favourites[sid] = true
            db.blacklist[sid]  = nil
        end
        return true
    end
end
local function FavouriteCount()
    local perkDB = ProjectEbonhold and ProjectEbonhold.PerkDatabase
    local fv     = GetDB().favourites
    local seen, n = {}, 0
    for sid in pairs(fv) do
        local perk = perkDB and perkDB[sid]
        local gid  = perk and perk.groupId
        if gid and gid > 0 then
            if not seen[gid] then seen[gid] = true; n = n + 1 end
        else
            n = n + 1
        end
    end
    return n
end

-- Run history helpers
local function RecordRunHistory(classKey, role, levelReached, echoCount)
    local db = GetDB()
    table.insert(db.runHistory, {
        t = time(),
        c = classKey,
        r = role,
        l = levelReached,
        n = echoCount,
    })
    -- Trim to MAX_RUN_HISTORY
    while #db.runHistory > MAX_RUN_HISTORY do
        table.remove(db.runHistory, 1)
    end
end

-------------------------------------------------------------------------------
-- 4. LEARNING ENGINE
-------------------------------------------------------------------------------

local band = bit and bit.band or function(a,b)
    local r,bv=0,1
    while a>0 and b>0 do
        if a%2==1 and b%2==1 then r=r+bv end
        a=math.floor(a/2); b=math.floor(b/2); bv=bv*2
    end
    return r
end

local function GetLearnDB()
    EchoBuddyLearnDB = EchoBuddyLearnDB or {}
    return EchoBuddyLearnDB
end

-- classRole: e.g. "WARRIOR_Tank", "MAGE_Caster DPS"
local function GetLearnData(classRole, spellId)
    local ldb = GetLearnDB()
    ldb[classRole] = ldb[classRole] or {}
    local d = ldb[classRole][spellId]
    if not d then
        d = {elo=ELO_START, comparisons=0, wins=0, losses=0,
             runCount=0, runLevelAvg=0, lastSeen=0}
        ldb[classRole][spellId] = d
    end
    return d
end

local function RecordComparison(winnerId, loserIds, classRole)
    if not winnerId or not loserIds or #loserIds == 0 then return end
    local winner = GetLearnData(classRole, winnerId)
    local K_w    = (winner.comparisons < 10) and ELO_K_NEW or ELO_K_EST
    local totalDelta = 0
    for _, lid in ipairs(loserIds) do
        local loser = GetLearnData(classRole, lid)
        local K_l   = (loser.comparisons < 10) and ELO_K_NEW or ELO_K_EST
        local expected = 1 / (1 + 10^((loser.elo - winner.elo) / 400))
        totalDelta       = totalDelta + K_w * (1 - expected)
        loser.elo        = loser.elo  + K_l * (0 - (1 - expected))
        loser.losses     = loser.losses   + 1
        loser.comparisons= loser.comparisons + 1
    end
    winner.elo        = winner.elo + totalDelta / math.max(1, #loserIds)
    winner.wins       = winner.wins + 1
    winner.comparisons= winner.comparisons + 1
end

local function RecordRunOutcome(echoSpellIds, levelReached, classRole)
    if not echoSpellIds or #echoSpellIds == 0 then return end
    local lvl = math.max(1, math.min(80, levelReached or 1))
    for _, sid in ipairs(echoSpellIds) do
        local d = GetLearnData(classRole, sid)
        if d.runCount == 0 then
            d.runLevelAvg = lvl
        else
            d.runLevelAvg = (1 - RUN_ALPHA) * d.runLevelAvg + RUN_ALPHA * lvl
        end
        d.runCount = d.runCount + 1
    end
end

-- Static score with difficulty and depth scaling
-- depth: 0.0 (start of run) → 1.0 (level 80)
local function StaticScore(spellId, quality, config, diffPreset, depth)
    local preset = DIFFICULTY_PRESETS[diffPreset or "Standard"] or DIFFICULTY_PRESETS["Standard"]
    local d = depth or 0
    local pMult = preset.primaryMult   * (1 + DEPTH_PRIMARY_SCALE   * d)
    local sMult = preset.secondaryMult * (1 - DEPTH_SECONDARY_SCALE * d)

    local score = QUALITY_BASE[quality] or 10
    local perkDB = ProjectEbonhold and ProjectEbonhold.PerkDatabase
    local fams   = (perkDB and perkDB[spellId] and perkDB[spellId].families) or {}
    for _, fam in ipairs(fams) do
        for _, pf in ipairs(config.primaryFamilies) do
            if fam == pf then score = score + config.primaryBonus * pMult; break end
        end
        for _, sf in ipairs(config.secondaryFamilies) do
            if fam == sf then score = score + config.secondaryBonus * sMult; break end
        end
    end
    return score, fams
end

-- Total comparisons for a specific classRole (fixes UCB1 denominator bug)
local function TotalComparisonsForRole(classRole)
    local ldb = GetLearnDB()
    local rd  = ldb[classRole]
    if not rd then return 1 end
    local n = 0
    for _, d in pairs(rd) do n = n + (d.comparisons or 0) end
    return math.max(1, n)
end

local function ConfidenceLevel(comparisons)
    if comparisons < 3  then return 0 end
    if comparisons < 10 then return 1 end
    if comparisons < 30 then return 2 end
    return 3
end

-- Full blended score: static + AI adjustments with confidence weighting
-- Returns: finalScore, staticBase, eloAdj, runAdj, confidence(0-1), confLevel(0-3)
local function BlendedScore(spellId, quality, config, classRole, depth, diffPreset)
    local base, _ = StaticScore(spellId, quality, config, diffPreset, depth)
    local d        = GetLearnData(classRole, spellId)
    local comps    = d.comparisons or 0
    local conf     = math.min(1.0, comps / CONF_FULL)
    local confLvl  = ConfidenceLevel(comps)

    if conf < 0.05 or not GetDB().useAIScores then
        return base, base, 0, 0, conf, confLvl
    end

    local eloAdj = math.max(-25, math.min(25, (d.elo - ELO_START) / 400 * 25))
    local runAdj = 0
    if (d.runCount or 0) > 0 then
        runAdj = math.max(-15, math.min(15, (d.runLevelAvg / 80 - 0.5) * 30))
    end

    local totalRole = TotalComparisonsForRole(classRole)
    local ucbBonus  = math.min(10, UCB_C * math.sqrt(math.log(totalRole) / math.max(1, comps)))

    local aiBonus = (eloAdj + runAdj) * conf + ucbBonus * (1 - conf)
    return base + aiBonus, base, eloAdj, runAdj, conf, confLvl
end

-- Stats summary for a classRole
local function LearnStats(classRole)
    local ldb = GetLearnDB()
    local rd  = ldb[classRole] or {}
    local totalComps, totalRuns, tracked = 0, 0, 0
    for _, d in pairs(rd) do
        totalComps = totalComps + (d.comparisons or 0)
        totalRuns  = totalRuns  + (d.runCount    or 0)
        tracked    = tracked + 1
    end
    return totalComps, totalRuns, tracked
end

local function ResetLearnData(classRole)
    if classRole then
        EchoBuddyLearnDB = EchoBuddyLearnDB or {}
        EchoBuddyLearnDB[classRole] = {}
    else
        EchoBuddyLearnDB = {}
    end
end

-- Nudge all echo ELO ratings 2% toward 1200 (prevents permanent extreme values)
local function ApplyEloDecay()
    local ldb = GetLearnDB()
    for _, roleData in pairs(ldb) do
        for _, d in pairs(roleData) do
            if d.comparisons and d.comparisons > 0 then
                d.elo = d.elo + ELO_DECAY * (ELO_START - d.elo)
            end
        end
    end
end

-- Remove entries that are completely default (never seen, no data)
local function PruneLearnDB()
    local ldb = GetLearnDB()
    for classRole, roleData in pairs(ldb) do
        for spellId, d in pairs(roleData) do
            if (d.comparisons or 0) == 0 and (d.runCount or 0) == 0
               and math.abs((d.elo or ELO_START) - ELO_START) < 0.01 then
                roleData[spellId] = nil
            end
        end
        -- Remove empty classRole tables
        local hasAny = false
        for _ in pairs(roleData) do hasAny = true; break end
        if not hasAny then ldb[classRole] = nil end
    end
end

-- Export entire learn database to a portable string
local function SerializeLearnDB()
    local parts = {"ECHOBUD4"}
    local ldb = GetLearnDB()
    for classRole, roleData in pairs(ldb) do
        local echoParts = {}
        for spellId, d in pairs(roleData) do
            if (d.comparisons or 0) > 0 or (d.runCount or 0) > 0 then
                table.insert(echoParts, string.format("%d:%.0f:%d:%d:%d:%d:%.1f",
                    spellId, d.elo or ELO_START,
                    d.comparisons or 0, d.wins or 0, d.losses or 0,
                    d.runCount or 0, d.runLevelAvg or 0))
            end
        end
        if #echoParts > 0 then
            table.insert(parts, classRole)
            table.insert(parts, table.concat(echoParts, "|"))
        end
    end
    if #parts <= 1 then return "" end
    return table.concat(parts, ";")
end

-- Import a serialized database string (merges, does not replace)
local function DeserializeLearnDB(str)
    if not str or #str < 8 then return false, "Empty or invalid input." end
    local parts = {}
    for p in str:gmatch("[^;]+") do table.insert(parts, p) end
    if parts[1] ~= "ECHOBUD4" then return false, "Not a valid Echo Buddy export string." end
    local ldb = GetLearnDB()
    local imported = 0
    local i = 2
    while i <= #parts - 1 do
        local classRole = parts[i]
        local echoData  = parts[i+1]
        i = i + 2
        if classRole and echoData then
            ldb[classRole] = ldb[classRole] or {}
            for entry in echoData:gmatch("[^|]+") do
                local sid, elo, comp, wins, losses, runs, avgLvl =
                    entry:match("(%d+):(%-?%d+%.?%d*):(%d+):(%d+):(%d+):(%d+):(%-?%d+%.?%d*)")
                if sid then
                    ldb[classRole][tonumber(sid)] = {
                        elo         = tonumber(elo)    or ELO_START,
                        comparisons = tonumber(comp)   or 0,
                        wins        = tonumber(wins)   or 0,
                        losses      = tonumber(losses) or 0,
                        runCount    = tonumber(runs)   or 0,
                        runLevelAvg = tonumber(avgLvl) or 0,
                        lastSeen    = 0,
                    }
                    imported = imported + 1
                end
            end
        end
    end
    return true, imported .. " entries imported successfully."
end

-------------------------------------------------------------------------------
-- 5. RUN TRACKING STATE
-------------------------------------------------------------------------------

local currentOfferedChoices  = nil  -- {spellId, quality} pairs for current offer
local currentRunEchoes       = {}   -- spellIds picked this run
local currentRunStackCounts  = {}   -- [spellId] = times picked this run
local lastTrackedLevel       = 0    -- last known player level

-------------------------------------------------------------------------------
-- 6. AUTO-SELECT ENGINE
-------------------------------------------------------------------------------

local function After(sec, fn)
    local t=0
    local f=CreateFrame("Frame")
    f:SetScript("OnUpdate",function(self,dt)
        t=t+dt
        if t>=sec then self:SetScript("OnUpdate",nil); self:Hide(); fn() end
    end)
    f:Show()
end

-- Toast notification — now shows up to 2 alternatives (top-3 total)
local toastFrame
local function ShowToast(pickedName, score, infoLine, alts)
    -- alts: optional list of up to 2 {name, score} tables for 2nd/3rd picks
    if not toastFrame then
        local hasAlts = alts and #alts > 0
        toastFrame = CreateFrame("Frame","EBBToastFrame",UIParent)
        toastFrame:SetSize(400, 82)
        toastFrame:SetPoint("TOP",UIParent,"TOP",0,-175)
        toastFrame:SetFrameStrata("DIALOG")
        toastFrame:SetBackdrop({
            bgFile  ="Interface\\DialogFrame\\UI-DialogBox-Background",
            edgeFile="Interface\\DialogFrame\\UI-DialogBox-Border",
            tile=true,tileSize=32,edgeSize=22,
            insets={left=7,right=8,top=7,bottom=7}
        })
        toastFrame:SetBackdropColor(0.04,0.04,0.12,0.96)
        local t1=toastFrame:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
        t1:SetPoint("TOP",toastFrame,"TOP",0,-11); t1:SetTextColor(0.5,0.5,0.5)
        t1:SetText("Echo Buddy — Auto Selected"); toastFrame._t1=t1
        local t2=toastFrame:CreateFontString(nil,"OVERLAY","GameFontNormal")
        t2:SetPoint("TOP",toastFrame,"TOP",0,-26); toastFrame._t2=t2
        local t3=toastFrame:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
        t3:SetPoint("TOP",toastFrame,"TOP",0,-46); toastFrame._t3=t3
        local t4=toastFrame:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
        t4:SetPoint("TOP",toastFrame,"TOP",0,-63); toastFrame._t4=t4
    end

    toastFrame._t2:SetText("|cff00CCFF"..pickedName.."|r")
    toastFrame._t3:SetText(infoLine or "")

    if alts and #alts > 0 then
        local altStrs = {}
        for _, a in ipairs(alts) do
            table.insert(altStrs, a.name .. " |cff666677(" .. math.floor(a.score) .. ")|r")
        end
        toastFrame._t4:SetText("|cff555566Also: |r" .. table.concat(altStrs, "  |cff333344·|r  "))
    else
        toastFrame._t4:SetText("")
    end

    toastFrame:SetAlpha(1); toastFrame:Show()
    local e=0
    toastFrame:SetScript("OnUpdate",function(self,dt)
        e=e+dt
        if e>3.5 then
            local a=1-((e-3.5)/0.7)
            if a<=0 then self:SetAlpha(0);self:Hide();self:SetScript("OnUpdate",nil)
            else self:SetAlpha(a) end
        end
    end)
end

-- Attempts to banish or reroll the current echo offer via PerkService.
-- Probes several naming conventions since the server source isn't exposed.
-- Returns true if an action was successfully called, false otherwise.
local function TryBanishReroll()
    local svc    = ProjectEbonhold and ProjectEbonhold.PerkService
    if not svc then
        print("|cffFF4444[Echo Buddy]|r Cannot banish/reroll: PerkService not found.")
        return false
    end
    local action = GetDB().blacklistAction or "banish"

    -- Banish attempt — try every known name variant
    local function DoBanish()
        local fn = svc.BanishPerk or svc.Banish or svc.BanishPerks
                or svc.SkipPerk  or svc.SkipPerks or svc.Skip
        if fn then fn() return true end
        return false
    end
    -- Reroll attempt — try every known name variant
    local function DoReroll()
        local fn = svc.RerollPerk or svc.Reroll or svc.RerollPerks
                or svc.RefreshPerks or svc.RefreshPerk or svc.Refresh
        if fn then fn() return true end
        return false
    end

    if action == "banish" then
        if DoBanish() then return true end
        print("|cffFF4444[Echo Buddy]|r Banish unavailable — no matching PerkService function found.")
        return false
    elseif action == "reroll" then
        if DoReroll() then return true end
        print("|cffFF4444[Echo Buddy]|r Reroll unavailable — no matching PerkService function found.")
        return false
    else  -- "banish_reroll": try banish first, fall back to reroll
        if DoBanish() then return true end
        if DoReroll() then
            print("|cffFFD700[Echo Buddy]|r Banish unavailable, used Reroll instead.")
            return true
        end
        print("|cffFF4444[Echo Buddy]|r Neither Banish nor Reroll found in PerkService.")
        return false
    end
end

local function DoAutoSelect(choices)
    local db     = GetDB()
    local role   = db.selectedRole or "Melee DPS"
    local config = ROLE_CONFIG[role]
    if not config then return end
    local classRole  = currentPlayerClass .. "_" .. role
    local depth      = lastTrackedLevel > 0 and (lastTrackedLevel / 80) or 0
    local diffPreset = db.difficulty or "Standard"
    local perkDB     = ProjectEbonhold and ProjectEbonhold.PerkDatabase

    -- Build family counts from current run for synergy
    local famCounts = {}
    if perkDB then
        for _, sid in ipairs(currentRunEchoes) do
            local perk = perkDB[sid]
            if perk and perk.families then
                for _, fam in ipairs(perk.families) do
                    famCounts[fam] = (famCounts[fam] or 0) + 1
                end
            end
        end
    end

    -- Score each offered echo
    local scored = {}
    for _, choice in ipairs(choices) do
        local sid   = choice.spellId
        if not IsBlacklisted(sid) then
            local perk    = perkDB and perkDB[sid]
            local quality = choice.quality or (perk and perk.quality) or 0
            local score   = BlendedScore(sid, quality, config, classRole, depth, diffPreset)

            -- Stack penalty / completion bonus
            if perk and perk.maxStack and perk.maxStack > 1 then
                local cur = currentRunStackCounts[sid] or 0
                if cur >= perk.maxStack then
                    score = -999
                elseif cur == perk.maxStack - 1 then
                    score = score + STACK_COMPLETION_BONUS
                end
            end

            -- Synergy bonus
            if perkDB and perk and perk.families then
                for _, fam in ipairs(perk.families) do
                    local cnt = math.min(famCounts[fam] or 0, FAMILY_SYNERGY_CAP)
                    score = score + cnt * FAMILY_SYNERGY_BONUS
                end
            end

            -- Favourite bonus
            if IsFavourite(sid) then score = score + FAVOURITE_BONUS end

            local name = GetCachedSpell(sid).name
            table.insert(scored, {spellId=sid, score=score, name=name, quality=quality})
        end
    end

    if #scored == 0 then
        -- Every offered echo is blacklisted. Attempt auto-banish/reroll if enabled.
        if GetDB().autoBanishReroll then
            local actionLabel = ({banish="Banish", reroll="Reroll", banish_reroll="Banish/Reroll"})[GetDB().blacklistAction or "banish"] or "Banish"
            After(GetDB().selectDelay or 0.6, function()
                if TryBanishReroll() then
                    ShowToast("All choices blacklisted", 0,
                        actionLabel.." triggered automatically", {})
                end
            end)
        end
        return
    end
    table.sort(scored, function(a,b) return a.score > b.score end)

    local best = scored[1]
    if not best or best.score <= -900 then return end

    -- Alternatives for toast (2nd and 3rd picks, if score > -900)
    local alts = {}
    for i = 2, math.min(3, #scored) do
        if scored[i].score > -900 then
            table.insert(alts, {name=scored[i].name, score=scored[i].score})
        end
    end

    local d       = GetLearnData(classRole, best.spellId)
    local comps   = d.comparisons or 0
    local confPct = math.floor(math.min(100, comps / CONF_FULL * 100))
    local srcTag  = confPct >= 10 and ("AI "..confPct.."% conf") or "Static"
    local infoLine= "Score: "..math.floor(best.score).."  ·  "..role.."  ·  "..srcTag

    After(db.selectDelay or 0.6, function()
        local svc = ProjectEbonhold and ProjectEbonhold.PerkService
        if svc and svc.SelectPerk then
            svc.SelectPerk(best.spellId)
            ShowToast(best.name, best.score, infoLine, alts)
        end
    end)
end

-------------------------------------------------------------------------------
-- 7. HOOK INSTALLATION
-------------------------------------------------------------------------------

local hookInstalled = false   -- safety guard: never double-hook

local function InstallHook()
    if hookInstalled then return end

    if not (ProjectEbonhold and ProjectEbonhold.PerkUI and ProjectEbonhold.PerkUI.Show) then
        print("|cffFF4444[Echo Buddy]|r PerkUI.Show not found — auto-select disabled.")
        return
    end
    if not (ProjectEbonhold.PerkService and ProjectEbonhold.PerkService.SelectPerk) then
        print("|cffFF4444[Echo Buddy]|r PerkService.SelectPerk not found — learning disabled.")
        return
    end

    hookInstalled = true

    -- Hook PerkUI.Show: store offered choices and trigger auto-select
    local origShow = ProjectEbonhold.PerkUI.Show
    ProjectEbonhold.PerkUI.Show = function(choices)
        origShow(choices)
        if choices and #choices > 0 then
            currentOfferedChoices = choices
        end
        if GetDB().autoSelect and choices and #choices > 0 then
            DoAutoSelect(choices)
        end
    end

    -- Hook PerkService.SelectPerk: capture every pick (manual or auto) for learning
    local origSelect = ProjectEbonhold.PerkService.SelectPerk
    ProjectEbonhold.PerkService.SelectPerk = function(spellId)
        local result = origSelect(spellId)  -- call original first (it is void / returns nil)

        -- Record learning regardless of return value
        -- (origSelect is a void function — gating on result silently drops all data)
        if currentOfferedChoices then
            local db   = GetDB()
            local role = db.selectedRole or "Melee DPS"
            local classRole = currentPlayerClass .. "_" .. role

            local losers = {}
            for _, c in ipairs(currentOfferedChoices) do
                if c.spellId ~= spellId then
                    table.insert(losers, c.spellId)
                end
            end
            if #losers > 0 then
                RecordComparison(spellId, losers, classRole)
            end

            table.insert(currentRunEchoes, spellId)
            currentRunStackCounts[spellId] = (currentRunStackCounts[spellId] or 0) + 1
            GetLearnData(classRole, spellId).lastSeen = GetTime()
            currentOfferedChoices = nil
        end

        return result
    end
end

-------------------------------------------------------------------------------
-- 8. DEATH / RUN-END EVENTS
-------------------------------------------------------------------------------

local runEventFrame = CreateFrame("Frame")
runEventFrame:RegisterEvent("PLAYER_DEAD")
runEventFrame:RegisterEvent("PLAYER_LEVEL_UP")
runEventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")

runEventFrame:SetScript("OnEvent", function(self, event, arg1)
    if event == "PLAYER_DEAD" then
        local level = UnitLevel and UnitLevel("player") or 1
        local db    = GetDB()
        local role  = db.selectedRole or "Melee DPS"
        local classRole = currentPlayerClass .. "_" .. role

        if #currentRunEchoes > 0 then
            RecordRunOutcome(currentRunEchoes, level, classRole)
            RecordRunHistory(currentPlayerClass, role, level, #currentRunEchoes)
        end
        currentRunEchoes      = {}
        currentRunStackCounts = {}
        lastTrackedLevel      = 0

    elseif event == "PLAYER_LEVEL_UP" then
        local newLevel = tonumber(arg1) or (UnitLevel and UnitLevel("player")) or 1
        if newLevel <= 2 and lastTrackedLevel > 5 then
            currentRunEchoes      = {}
            currentRunStackCounts = {}
        end
        lastTrackedLevel = newLevel

    elseif event == "PLAYER_ENTERING_WORLD" then
        local lvl = UnitLevel and UnitLevel("player") or 1
        if lvl <= 1 then
            currentRunEchoes      = {}
            currentRunStackCounts = {}
        end
        lastTrackedLevel = lvl
    end
end)

-------------------------------------------------------------------------------
-- 9. DATABASE SCORING  (used by Advisor)
-------------------------------------------------------------------------------

local function ScoreFullDatabase(classMask, role, classRole)
    local perkDB = ProjectEbonhold and ProjectEbonhold.PerkDatabase
    if not perkDB then return nil, "ProjectEbonhold.PerkDatabase not available." end
    local config = ROLE_CONFIG[role]
    if not config then return nil, "Unknown role: "..tostring(role) end

    local db         = GetDB()
    local depth      = lastTrackedLevel > 0 and (lastTrackedLevel / 80) or 0
    local diffPreset = db.difficulty or "Standard"

    -- Build family counts from current run for synergy
    local famCounts = {}
    for _, sid in ipairs(currentRunEchoes) do
        local perk = perkDB[sid]
        if perk and perk.families then
            for _, fam in ipairs(perk.families) do
                famCounts[fam] = (famCounts[fam] or 0) + 1
            end
        end
    end

    -- Collect class-eligible perks
    local eligible = {}
    for spellId, perk in pairs(perkDB) do
        if band(perk.classMask, classMask) ~= 0 then
            table.insert(eligible, {spellId=spellId, perk=perk})
        end
    end

    -- Dedup by groupId (highest quality variant per group)
    local bestByGroup, ungrouped = {}, {}
    for _, e in ipairs(eligible) do
        local gid = e.perk.groupId
        if gid and gid > 0 then
            if not bestByGroup[gid] or e.perk.quality > bestByGroup[gid].perk.quality then
                bestByGroup[gid] = e
            end
        else
            table.insert(ungrouped, e)
        end
    end
    local pool = {}
    for _, e in pairs(bestByGroup) do table.insert(pool, e) end
    for _, e in ipairs(ungrouped)   do table.insert(pool, e) end

    -- Score each perk
    local scored = {}
    for _, e in ipairs(pool) do
        local sid  = e.spellId
        local perk = e.perk
        local final, base, eloAdj, runAdj, conf, confLvl =
            BlendedScore(sid, perk.quality, config, classRole, depth, diffPreset)

        -- Stack penalty / completion bonus
        local stackPenalty = false
        if perk.maxStack and perk.maxStack > 1 then
            local cur = currentRunStackCounts[sid] or 0
            if cur >= perk.maxStack then
                final = -999; stackPenalty = true
            elseif cur == perk.maxStack - 1 then
                final = final + STACK_COMPLETION_BONUS
            end
        end

        -- Synergy bonus (only if not already at-cap)
        if not stackPenalty and perk.families then
            for _, fam in ipairs(perk.families) do
                local cnt = math.min(famCounts[fam] or 0, FAMILY_SYNERGY_CAP)
                final = final + cnt * FAMILY_SYNERGY_BONUS
            end
        end

        -- Favourite bonus
        local isFav = IsFavourite(sid)
        if isFav and not stackPenalty then
            final = final + FAVOURITE_BONUS
        end

        table.insert(scored, {
            spellId    = sid,
            perk       = perk,
            score      = final,
            base       = base,
            eloAdj     = eloAdj,
            runAdj     = runAdj,
            conf       = conf,
            confLevel  = confLvl,
            blacklisted= IsBlacklisted(sid),
            favourite  = isFav,
        })
    end

    -- Sort: Favourites first → Normal → Blacklisted; then by score
    table.sort(scored, function(a, b)
        if a.blacklisted ~= b.blacklisted then return not a.blacklisted end
        if a.favourite   ~= b.favourite   then return a.favourite end
        if a.score       ~= b.score       then return a.score > b.score end
        if a.perk.quality ~= b.perk.quality then return a.perk.quality > b.perk.quality end
        return (GetCachedSpell(a.spellId).name) < (GetCachedSpell(b.spellId).name)
    end)
    return scored, nil
end

-------------------------------------------------------------------------------
-- 10. GUI HELPERS
-------------------------------------------------------------------------------

local mainFrame     = nil
local resultRows    = {}
local scrollChild   = nil
local infoText      = nil
local aiStatsBar    = nil
local autoCheckbox  = nil
local blBtn         = nil
local activeTabPane = nil

-- Blacklist frame state
local blFrame       = nil
local blSearchRows  = {}
local blListRows    = {}
local blSearchChild = nil
local blListChild   = nil
local blSearchQuery = ""
local blResultLabel = nil
local blListLabel   = nil

local selectedClassIdx = 1
local selectedRoleIdx  = 1

local MAX_RESULTS = 50
local ROW_H       = 30

local CONF_CHAR = "|cff%02x%02x%02x*|r"
local function ConfDot(level)
    local c = CONF_COLORS[level+1] or CONF_COLORS[1]
    return CONF_CHAR:format(c[1]*255, c[2]*255, c[3]*255)
end

-- Forward declaration (RefreshBlListRows uses it before it's defined)
local RefreshBlSearchResults

local function GetOrCreateRow(index)
    if resultRows[index] then return resultRows[index] end

    local row = CreateFrame("Frame", nil, scrollChild)
    row:SetSize(600, ROW_H)

    local bg = row:CreateTexture(nil,"BACKGROUND"); bg:SetAllPoints(); row._bg = bg

    local rank = row:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
    rank:SetSize(26,ROW_H); rank:SetPoint("LEFT",row,"LEFT",4,0)
    rank:SetJustifyH("RIGHT"); row._rank = rank

    local icon = row:CreateTexture(nil,"ARTWORK")
    icon:SetSize(22,22); icon:SetPoint("LEFT",row,"LEFT",33,0)
    icon:SetTexCoord(0.08,0.92,0.08,0.92); row._icon = icon

    local nameText = row:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
    nameText:SetSize(210,ROW_H); nameText:SetPoint("LEFT",row,"LEFT",59,0)
    nameText:SetJustifyH("LEFT"); row._name = nameText

    local qualText = row:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
    qualText:SetSize(75,ROW_H); qualText:SetPoint("LEFT",row,"LEFT",275,0)
    qualText:SetJustifyH("LEFT"); row._qual = qualText

    local famText = row:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
    famText:SetSize(160,ROW_H); famText:SetPoint("LEFT",row,"LEFT",355,0)
    famText:SetJustifyH("LEFT"); famText:SetTextColor(0.60,0.55,0.75); row._fam = famText

    local dotText = row:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
    dotText:SetSize(14,ROW_H); dotText:SetPoint("LEFT",row,"LEFT",520,0); row._dot = dotText

    local scoreText = row:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
    scoreText:SetSize(48,ROW_H); scoreText:SetPoint("LEFT",row,"LEFT",534,0)
    scoreText:SetJustifyH("RIGHT"); row._score = scoreText

    row:EnableMouse(true)

    row:SetScript("OnEnter", function(self)
        self._bg:SetTexture("Interface\\Buttons\\WHITE8X8")
        self._bg:SetVertexColor(0.18,0.12,0.36); self._bg:SetAlpha(0.65)
        if self._spellId then
            GameTooltip:SetOwner(self,"ANCHOR_RIGHT")
            GameTooltip:SetHyperlink("spell:"..self._spellId)
            GameTooltip:AddLine(" ")
            local pct = math.floor((self._conf or 0)*100)
            GameTooltip:AddLine(string.format(
                "|cffFFD700Score: %d|r  (Base %d  ELO%+.0f  Run%+.0f  Conf %d%%)",
                math.floor(self._scoreVal or 0), math.floor(self._base or 0),
                self._eloAdj or 0, self._runAdj or 0, pct))
            local d = self._classRole and GetLearnData(self._classRole, self._spellId)
            if d then
                GameTooltip:AddLine(string.format(
                    "|cff888888Picks: %d W / %d L  ·  Runs: %d  ·  Avg lvl: %.0f|r",
                    d.wins or 0, d.losses or 0, d.runCount or 0, d.runLevelAvg or 0))
                GameTooltip:AddLine(string.format("|cff888888ELO: %.0f|r", d.elo or ELO_START))
            end
            if self._families and #self._families > 0 then
                GameTooltip:AddLine("|cff888888"..table.concat(self._families,"  •  ").."|r")
            end
            local favHint = IsFavourite(self._spellId)
                and "|cffFFD700* Right-click to Remove Favourite|r"
                 or "|cff888888* Right-click to Add Favourite / Blacklist|r"
            GameTooltip:AddLine(" "); GameTooltip:AddLine(favHint)
            GameTooltip:Show()
        end
    end)

    row:SetScript("OnLeave", function(self)
        if self._blacklisted then
            self._bg:SetTexture("Interface\\Buttons\\WHITE8X8")
            self._bg:SetVertexColor(0.16,0.03,0.03); self._bg:SetAlpha(0.55)
        elseif self._favourite then
            self._bg:SetTexture("Interface\\Buttons\\WHITE8X8")
            self._bg:SetVertexColor(0.16,0.14,0.02); self._bg:SetAlpha(0.55)
        elseif self._isEven then
            self._bg:SetTexture("Interface\\Buttons\\WHITE8X8")
            self._bg:SetVertexColor(0.06,0.04,0.18); self._bg:SetAlpha(0.45)
        else
            self._bg:SetAlpha(0)
        end
        GameTooltip:Hide()
    end)

    -- Right-click context menu
    row:SetScript("OnMouseUp", function(self, button)
        if button ~= "RightButton" or not self._spellId then return end
        local sid   = self._spellId
        local sName = GetCachedSpell(sid).name
        local isbl  = IsBlacklisted(sid)
        local isfav = IsFavourite(sid)
        if not _G["EBBContextMenu"] then
            CreateFrame("Frame","EBBContextMenu",UIParent,"UIDropDownMenuTemplate")
        end
        local menuList = {
            {text=sName, isTitle=true, notCheckable=true},
            {
                text = isfav
                    and "|cffFFD700* Remove from Favourites|r"
                     or "|cff888855* Add to Favourites|r",
                notCheckable=true,
                func=function()
                    ToggleFavourite(sid)
                    RunRecommendation()
                end,
            },
            {
                text = isbl
                    and "|cff44FF44Remove from Blacklist|r"
                     or "|cffFF5555Add to Blacklist|r",
                notCheckable=true,
                func=function()
                    ToggleBlacklist(sid)
                    RunRecommendation()
                end,
            },
            {text="Cancel", notCheckable=true, func=function() end},
        }
        EasyMenu(menuList, _G["EBBContextMenu"], "cursor", 0, 0, "MENU")
    end)

    resultRows[index] = row
    return row
end

local function DisplayResults(results, className, role)
    local shown = math.min(#results, MAX_RESULTS)
    for i = shown+1, #resultRows do resultRows[i]:Hide() end

    for i = 1, shown do
        local e       = results[i]
        local perk    = e.perk
        local quality = perk.quality
        local fams    = perk.families or {}
        local sp      = GetCachedSpell(e.spellId)
        local sn      = sp.name
        local si      = sp.icon
        local qc      = QUALITY_COLOR[quality] or QUALITY_COLOR[0]
        local isEven  = (i%2==0)
        local isbl    = e.blacklisted
        local isfav   = e.favourite

        local row = GetOrCreateRow(i)
        row:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", 0, -(i-1)*ROW_H)
        row._spellId   = e.spellId
        row._scoreVal  = e.score
        row._base      = e.base
        row._eloAdj    = e.eloAdj
        row._runAdj    = e.runAdj
        row._conf      = e.conf
        row._families  = fams
        row._isEven    = isEven
        row._classRole = CLASS_INTERNAL[selectedClassIdx] .. "_" .. role
        row._blacklisted= isbl
        row._favourite  = isfav

        row._icon:SetTexture(si)

        -- Row background
        if isbl then
            row._bg:SetTexture("Interface\\Buttons\\WHITE8X8")
            row._bg:SetVertexColor(0.16,0.03,0.03); row._bg:SetAlpha(0.55)
        elseif isfav then
            row._bg:SetTexture("Interface\\Buttons\\WHITE8X8")
            row._bg:SetVertexColor(0.16,0.14,0.02); row._bg:SetAlpha(0.55)
        elseif isEven then
            row._bg:SetTexture("Interface\\Buttons\\WHITE8X8")
            row._bg:SetVertexColor(0.06,0.04,0.18); row._bg:SetAlpha(0.45)
        else
            row._bg:SetAlpha(0)
        end

        if isbl then
            row._rank:SetText("|cffAA2222-|r")
            row._icon:SetDesaturated(true)
            row._name:SetTextColor(0.40,0.38,0.38); row._name:SetText(sn)
            row._qual:SetTextColor(0.40,0.38,0.38); row._qual:SetText(QUALITY_NAME[quality] or "?")
            row._fam:SetTextColor(0.35,0.33,0.33);  row._fam:SetText(table.concat(fams," • "))
            row._dot:SetText("")
            row._score:SetTextColor(0.38,0.35,0.35); row._score:SetText(math.floor(e.score))
        elseif isfav then
            row._rank:SetText("|cffFFD700*|r")
            row._icon:SetDesaturated(false)
            row._name:SetTextColor(1,0.9,0.3); row._name:SetText("* "..sn)
            row._qual:SetTextColor(qc[1],qc[2],qc[3]); row._qual:SetText(QUALITY_NAME[quality] or "?")
            row._fam:SetTextColor(0.60,0.55,0.75); row._fam:SetText(table.concat(fams," • "))
            row._dot:SetText(ConfDot(e.confLevel or 0))
            row._score:SetTextColor(1,0.85,0.1); row._score:SetText(math.floor(e.score))
        else
            row._rank:SetText("|cff555577#"..i.."|r")
            row._icon:SetDesaturated(false)
            row._name:SetTextColor(qc[1],qc[2],qc[3]); row._name:SetText(sn)
            row._qual:SetTextColor(qc[1],qc[2],qc[3]); row._qual:SetText(QUALITY_NAME[quality] or "?")
            row._fam:SetTextColor(0.60,0.55,0.75); row._fam:SetText(table.concat(fams," • "))
            row._dot:SetText(ConfDot(e.confLevel or 0))
            local ratio = math.min(1, math.max(0, e.score / 80))
            row._score:SetTextColor(1 - ratio*0.5, 0.7 + ratio*0.3, 0)
            row._score:SetText(math.floor(e.score))
        end

        row:SetSize(600, ROW_H); row:Show()
    end

    scrollChild:SetHeight(math.max(1, shown * ROW_H))

    -- Info bar
    if infoText then
        local ci  = CLASS_INTERNAL[selectedClassIdx]
        local cc  = CLASS_COLOR[ci] or {1,1,1}
        local blc = BlacklistCount()
        local fvc = FavouriteCount()
        local extras = ""
        if fvc > 0 then extras = extras .. "  ·  |cffFFD700* "..fvc.." starred|r" end
        if blc > 0 then extras = extras .. "  ·  |cffAA2222- "..blc.." blacklisted|r" end
        infoText:SetText(string.format(
            "Showing |cffFFD700%d|r echoes  ·  |cff%02x%02x%02x%s|r  |cff888888›|r  |cff00CCFF%s|r%s",
            shown, cc[1]*255, cc[2]*255, cc[3]*255, className, role, extras))
    end
    if blBtn then
        local blc = BlacklistCount()
        blBtn:SetText(blc > 0 and ("Blacklist ("..blc..")") or "Blacklist")
    end
    if aiStatsBar then
        local classRole = CLASS_INTERNAL[selectedClassIdx] .. "_" .. role
        local tc,tr,te  = LearnStats(classRole)
        aiStatsBar:SetText(string.format(
            "|cff888888AI: %d comparisons · %d runs · %d echoes tracked  (%s · %s)|r",
            tc, tr, te, CLASS_INTERNAL[selectedClassIdx], role))
    end
end

-- RunRecommendation declared here for use by row context menus; defined below
local RunRecommendation

RunRecommendation = function()
    local classKey  = CLASS_INTERNAL[selectedClassIdx]
    local className = CLASS_DISPLAY[selectedClassIdx]
    local role      = ROLES[selectedRoleIdx]
    local mask      = CLASS_MASK[classKey] or 0
    local classRole = classKey .. "_" .. role
    local results, err = ScoreFullDatabase(mask, role, classRole)
    if not results then
        if infoText then infoText:SetText("|cffFF4444"..(err or "Error").."|r") end
        return
    end
    DisplayResults(results, className, role)
end

-- Role dropdown helper
local function OnRoleChanged(label)
    SaveRole(label)
    for _, ddname in ipairs({"EBBAutoRoleDD","EBBAdvRoleDD"}) do
        local dd = _G[ddname]
        if dd then UIDropDownMenu_SetText(dd, label) end
    end
end

local function MakeRoleDD(frameName, parent, pointArgs)
    local dd = CreateFrame("Frame", frameName, parent, "UIDropDownMenuTemplate")
    dd:SetPoint(unpack(pointArgs))
    UIDropDownMenu_SetWidth(dd, 118)
    UIDropDownMenu_SetText(dd, ROLES[selectedRoleIdx])
    UIDropDownMenu_Initialize(dd, function()
        for i, label in ipairs(ROLES) do
            local info = UIDropDownMenu_CreateInfo()
            info.text = label; info.value = i
            info.func = function()
                selectedRoleIdx = i
                OnRoleChanged(label)
                CloseDropDownMenus()
            end
            UIDropDownMenu_AddButton(info)
        end
    end)
    return dd
end

local function ShowConfirm(msg, onYes)
    StaticPopupDialogs["EBB_CONFIRM"] = {
        text=msg, button1="Yes", button2="No",
        OnAccept=onYes, timeout=0, whileDead=true, hideOnEscape=true,
    }
    StaticPopup_Show("EBB_CONFIRM")
end

-------------------------------------------------------------------------------
-- 11. BLACKLIST FRAME
-------------------------------------------------------------------------------

local function SearchEchoes(query)
    if not query or #query < 2 then return {} end
    query = query:lower()
    local perkDB = ProjectEbonhold and ProjectEbonhold.PerkDatabase
    if not perkDB then return {} end

    -- Collect all name-matching perks, then deduplicate by groupId (highest quality wins)
    -- This prevents the same echo appearing multiple times due to rank/variant entries
    local bestByGroup, ungrouped = {}, {}
    for spellId, perk in pairs(perkDB) do
        local name = GetCachedSpell(spellId).name
        if name:lower():find(query, 1, true) then
            local gid = perk.groupId
            if gid and gid > 0 then
                if not bestByGroup[gid] or (perk.quality or 0) > bestByGroup[gid].quality then
                    bestByGroup[gid] = {spellId=spellId, name=name, quality=perk.quality or 0}
                end
            else
                table.insert(ungrouped, {spellId=spellId, name=name, quality=perk.quality or 0})
            end
        end
    end

    local out = {}
    for _, e in pairs(bestByGroup) do table.insert(out, e) end
    for _, e in ipairs(ungrouped)   do table.insert(out, e) end

    table.sort(out, function(a, b)
        if a.name ~= b.name then return a.name < b.name end
        return a.quality > b.quality
    end)

    -- Cap results after dedup
    if #out > 20 then for i = 21, #out do out[i] = nil end end
    return out
end

local function GetOrCreateBlRow(parent, cache, index, rowW)
    if cache[index] then return cache[index] end
    local row = CreateFrame("Frame", nil, parent)
    row:SetSize(rowW, 22)
    local bg = row:CreateTexture(nil,"BACKGROUND"); bg:SetAllPoints(); row._bg = bg

    -- Spell icon (left edge)
    local icon = row:CreateTexture(nil,"ARTWORK")
    icon:SetSize(18,18); icon:SetPoint("LEFT",row,"LEFT",4,0)
    icon:SetTexCoord(0.08,0.92,0.08,0.92); row._icon = icon

    -- Label shifted right to make room for the icon (4px left + 18px icon + 4px gap = 26px)
    local lbl = row:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
    lbl:SetPoint("LEFT",row,"LEFT",26,0); lbl:SetSize(rowW-130,22)
    lbl:SetJustifyH("LEFT"); row._lbl = lbl

    local btn = CreateFrame("Button",nil,row,"GameMenuButtonTemplate")
    btn:SetSize(92,18); btn:SetPoint("RIGHT",row,"RIGHT",-4,0); row._btn = btn
    cache[index] = row
    return row
end

local function RefreshBlCount()
    local n = BlacklistCount()
    if blBtn then
        blBtn:SetText(n>0 and ("Blacklist ("..n..")") or "Blacklist")
    end
    if blListLabel then
        blListLabel:SetText("|cffAA8833Currently Blacklisted|r |cff666666("..n..")|r")
    end
end

local function RefreshBlListRows()
    local bl     = GetDB().blacklist
    local perkDB = ProjectEbonhold and ProjectEbonhold.PerkDatabase
    -- Deduplicate by groupId: show one row per echo, using the highest-quality rank
    local seenGroups = {}
    local entries    = {}
    for sid in pairs(bl) do
        local perk = perkDB and perkDB[sid]
        local gid  = perk and perk.groupId
        if gid and gid > 0 then
            local existing = seenGroups[gid]
            if not existing then
                seenGroups[gid] = {spellId=sid, name=GetCachedSpell(sid).name, quality=perk.quality or 0}
                table.insert(entries, seenGroups[gid])
            elseif (perk.quality or 0) > existing.quality then
                -- Upgrade to the higher-quality representative for display
                existing.spellId = sid
                existing.name    = GetCachedSpell(sid).name
                existing.quality = perk.quality or 0
            end
        else
            table.insert(entries, {spellId=sid, name=GetCachedSpell(sid).name, quality=0})
        end
    end
    table.sort(entries, function(a,b) return a.name < b.name end)
    for i = #entries+1, #blListRows do
        if blListRows[i] then blListRows[i]:Hide() end
    end
    local rowW = (blListChild and blListChild:GetWidth()>10 and blListChild:GetWidth()) or 374
    for i, e in ipairs(entries) do
        local row = GetOrCreateBlRow(blListChild, blListRows, i, rowW)
        row:SetPoint("TOPLEFT",blListChild,"TOPLEFT",0,-(i-1)*22)
        row._bg:SetTexture("Interface\\Buttons\\WHITE8X8")
        row._bg:SetVertexColor(i%2==0 and 0.16 or 0.12, 0.03, 0.03)
        row._bg:SetAlpha(i%2==0 and 0.55 or 0.45)
        row._icon:SetTexture(GetCachedSpell(e.spellId).icon)
        row._icon:SetDesaturated(true)
        row._lbl:SetTextColor(0.80,0.36,0.36)
        row._lbl:SetText("|cffAA2222-|r "..e.name)
        row._btn:SetText("Remove")
        local sid = e.spellId
        row._btn:SetScript("OnClick", function()
            ToggleBlacklist(sid)
            RefreshBlListRows()
            RefreshBlCount()
            if blSearchQuery and #blSearchQuery >= 2 then
                RefreshBlSearchResults(blSearchQuery)
            end
            RunRecommendation()
        end)
        row:SetSize(rowW,22); row:Show()
    end
    blListChild:SetHeight(math.max(1, #entries*22))
    RefreshBlCount()
end

RefreshBlSearchResults = function(query)
    blSearchQuery = query or ""
    local results = SearchEchoes(query)
    for i = #results+1, #blSearchRows do
        if blSearchRows[i] then blSearchRows[i]:Hide() end
    end
    local rowW = (blSearchChild and blSearchChild:GetWidth()>10 and blSearchChild:GetWidth()) or 374
    for i, e in ipairs(results) do
        local row  = GetOrCreateBlRow(blSearchChild, blSearchRows, i, rowW)
        row:SetPoint("TOPLEFT",blSearchChild,"TOPLEFT",0,-(i-1)*22)
        local isbl = IsBlacklisted(e.spellId)
        local qc   = QUALITY_COLOR[e.quality] or QUALITY_COLOR[0]
        local qn   = QUALITY_NAME[e.quality]  or "?"
        row._bg:SetTexture("Interface\\Buttons\\WHITE8X8")
        row._bg:SetVertexColor(i%2==0 and 0.06 or 0, i%2==0 and 0.04 or 0, i%2==0 and 0.16 or 0)
        row._bg:SetAlpha(i%2==0 and 0.40 or 0)
        row._icon:SetTexture(GetCachedSpell(e.spellId).icon)
        if isbl then
            row._icon:SetDesaturated(true)
            row._lbl:SetTextColor(0.40,0.36,0.36)
            row._lbl:SetText("|cffAA2222-|r "..e.name.." |cff555555("..qn..")|r")
            row._btn:SetText("Remove")
        else
            row._icon:SetDesaturated(false)
            row._lbl:SetTextColor(qc[1],qc[2],qc[3])
            row._lbl:SetText(e.name.." |cff665599("..qn..")|r")
            row._btn:SetText("+ Blacklist")
        end
        local sid = e.spellId
        row._btn:SetScript("OnClick", function()
            ToggleBlacklist(sid)
            RefreshBlSearchResults(blSearchQuery)
            RefreshBlListRows()
            RunRecommendation()
        end)
        row:SetSize(rowW,22); row:Show()
    end
    blSearchChild:SetHeight(math.max(1, #results*22))
    if blResultLabel then
        blResultLabel:SetText(
            #results>0
            and ("|cffAA8833Search Results|r |cff666666("..#results..")|r")
             or "|cff665599Search Results|r |cff444444— type 2 or more characters|r")
    end
end

local function BuildBlacklistFrame()
    local BW, BH = 440, 440
    blFrame = CreateFrame("Frame","EBBBlacklistFrame",UIParent)
    blFrame:SetSize(BW,BH)
    blFrame:SetPoint("LEFT",mainFrame,"RIGHT",8,20)
    blFrame:SetMovable(true); blFrame:EnableMouse(true)
    blFrame:RegisterForDrag("LeftButton")
    blFrame:SetScript("OnDragStart",blFrame.StartMoving)
    blFrame:SetScript("OnDragStop",blFrame.StopMovingOrSizing)
    blFrame:SetFrameStrata("HIGH")
    blFrame:SetBackdrop({
        bgFile="Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile="Interface\\DialogFrame\\UI-DialogBox-Border",
        tile=true,tileSize=32,edgeSize=32,
        insets={left=11,right=12,top=12,bottom=11},
    })
    blFrame:SetBackdropColor(0.03,0.02,0.12,0.98)
    blFrame:SetBackdropBorderColor(0.40,0.25,0.70,1.0)

    local hdrBand = blFrame:CreateTexture(nil,"BORDER")
    hdrBand:SetTexture("Interface\\Buttons\\WHITE8X8")
    hdrBand:SetPoint("TOPLEFT",blFrame,"TOPLEFT",12,-12)
    hdrBand:SetPoint("TOPRIGHT",blFrame,"TOPRIGHT",-12,-12)
    hdrBand:SetHeight(46)
    hdrBand:SetGradientAlpha("VERTICAL",0.14,0.08,0.36,0.95,0.03,0.02,0.12,0)

    local title = blFrame:CreateFontString(nil,"OVERLAY","GameFontHighlightLarge")
    title:SetPoint("TOP",blFrame,"TOP",0,-18)
    title:SetText("|cffFFD700Blacklist Manager|r")

    local closeBtn = CreateFrame("Button",nil,blFrame,"UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT",blFrame,"TOPRIGHT",-4,-4)
    closeBtn:SetScript("OnClick",function() blFrame:Hide() end)

    local hdrLine = blFrame:CreateTexture(nil,"ARTWORK")
    hdrLine:SetTexture("Interface\\Buttons\\WHITE8X8")
    hdrLine:SetPoint("TOPLEFT",blFrame,"TOPLEFT",15,-56)
    hdrLine:SetPoint("TOPRIGHT",blFrame,"TOPRIGHT",-15,-56)
    hdrLine:SetHeight(1); hdrLine:SetVertexColor(0.88,0.72,0.18,1.0)
    local hdrGlow = blFrame:CreateTexture(nil,"ARTWORK")
    hdrGlow:SetTexture("Interface\\Buttons\\WHITE8X8")
    hdrGlow:SetPoint("TOPLEFT",blFrame,"TOPLEFT",15,-57)
    hdrGlow:SetPoint("TOPRIGHT",blFrame,"TOPRIGHT",-15,-57)
    hdrGlow:SetHeight(6)
    hdrGlow:SetGradientAlpha("VERTICAL",0.88,0.72,0.18,0.20,0.88,0.72,0.18,0)
    hdrGlow:SetBlendMode("ADD")

    local function GD(yOff)
        local line = blFrame:CreateTexture(nil,"ARTWORK")
        line:SetTexture("Interface\\Buttons\\WHITE8X8")
        line:SetPoint("TOPLEFT",blFrame,"TOPLEFT",15,yOff)
        line:SetPoint("TOPRIGHT",blFrame,"TOPRIGHT",-15,yOff)
        line:SetHeight(1); line:SetVertexColor(0.88,0.72,0.18,0.65)
        local glow = blFrame:CreateTexture(nil,"ARTWORK")
        glow:SetTexture("Interface\\Buttons\\WHITE8X8")
        glow:SetPoint("TOPLEFT",blFrame,"TOPLEFT",15,yOff-1)
        glow:SetPoint("TOPRIGHT",blFrame,"TOPRIGHT",-15,yOff-1)
        glow:SetHeight(5)
        glow:SetGradientAlpha("VERTICAL",0.88,0.72,0.18,0.16,0.88,0.72,0.18,0)
        glow:SetBlendMode("ADD")
    end

    local function SP(yTop, h)
        local p = CreateFrame("Frame",nil,blFrame)
        p:SetPoint("TOPLEFT",blFrame,"TOPLEFT",14,yTop)
        p:SetPoint("TOPRIGHT",blFrame,"TOPRIGHT",-14,yTop)
        p:SetHeight(h)
        p:SetBackdrop({
            bgFile="Interface\\Tooltips\\UI-Tooltip-Background",
            edgeFile="Interface\\Tooltips\\UI-Tooltip-Border",
            tile=true,tileSize=16,edgeSize=12,
            insets={left=3,right=3,top=3,bottom=3},
        })
        p:SetBackdropColor(0.07,0.04,0.20,0.50)
        p:SetBackdropBorderColor(0.38,0.26,0.62,0.45)
        return p
    end

    SP(-60,58)
    local srchLbl = blFrame:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
    srchLbl:SetPoint("TOPLEFT",blFrame,"TOPLEFT",24,-73)
    srchLbl:SetTextColor(0.65,0.50,0.90); srchLbl:SetText("Echo name:")

    local searchBox = CreateFrame("EditBox","EBBBlSearchBox",blFrame,"InputBoxTemplate")
    searchBox:SetSize(220,20); searchBox:SetPoint("TOPLEFT",blFrame,"TOPLEFT",106,-71)
    searchBox:SetAutoFocus(false); searchBox:SetMaxLetters(60)
    searchBox:SetScript("OnTextChanged",function(self,userInput)
        if userInput then RefreshBlSearchResults(self:GetText()) end
    end)
    searchBox:SetScript("OnEnterPressed",function(self)
        RefreshBlSearchResults(self:GetText()); self:ClearFocus()
    end)
    searchBox:SetScript("OnEscapePressed",function(self)
        self:SetText(""); self:ClearFocus(); RefreshBlSearchResults("")
    end)

    local clearBtn = CreateFrame("Button",nil,blFrame,"UIPanelButtonTemplate")
    clearBtn:SetSize(48,20); clearBtn:SetPoint("LEFT",searchBox,"RIGHT",4,0)
    clearBtn:SetText("Clear")
    clearBtn:SetScript("OnClick",function()
        searchBox:SetText(""); searchBox:ClearFocus(); RefreshBlSearchResults("")
    end)

    local hintLbl = blFrame:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
    hintLbl:SetPoint("TOPLEFT",blFrame,"TOPLEFT",24,-96)
    hintLbl:SetTextColor(0.38,0.32,0.52)
    hintLbl:SetText("Type 2+ chars · or right-click any echo in the main list")

    GD(-122)

    blResultLabel = blFrame:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
    blResultLabel:SetPoint("TOPLEFT",blFrame,"TOPLEFT",20,-132)
    blResultLabel:SetText("|cff665599Search Results|r |cff444444— type 2 or more characters|r")

    local srchSF = CreateFrame("ScrollFrame","EBBBlSearchSF",blFrame,"UIPanelScrollFrameTemplate")
    srchSF:SetPoint("TOPLEFT",blFrame,"TOPLEFT",16,-146)
    srchSF:SetPoint("TOPRIGHT",blFrame,"TOPRIGHT",-34,-146)
    srchSF:SetHeight(112)
    blSearchChild = CreateFrame("Frame","EBBBlSearchChild",srchSF)
    blSearchChild:SetSize(374,1); srchSF:SetScrollChild(blSearchChild)

    GD(-264)

    blListLabel = blFrame:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
    blListLabel:SetPoint("TOPLEFT",blFrame,"TOPLEFT",20,-274)
    blListLabel:SetText("|cffAA8833Currently Blacklisted|r |cff666666(0)|r")

    local clearAllBtn = CreateFrame("Button",nil,blFrame,"GameMenuButtonTemplate")
    clearAllBtn:SetSize(94,20); clearAllBtn:SetPoint("TOPRIGHT",blFrame,"TOPRIGHT",-18,-272)
    clearAllBtn:SetText("Clear All")
    clearAllBtn:SetScript("OnClick",function()
        ShowConfirm("Clear the entire blacklist?\nAll echoes will become available again.",
            function()
                GetDB().blacklist = {}
                RefreshBlListRows()
                RefreshBlSearchResults(blSearchQuery)
                RunRecommendation()
            end)
    end)

    local listSF = CreateFrame("ScrollFrame","EBBBlListSF",blFrame,"UIPanelScrollFrameTemplate")
    listSF:SetPoint("TOPLEFT",blFrame,"TOPLEFT",16,-290)
    listSF:SetPoint("BOTTOMRIGHT",blFrame,"BOTTOMRIGHT",-34,14)
    blListChild = CreateFrame("Frame","EBBBlListChild",listSF)
    blListChild:SetSize(374,1); listSF:SetScrollChild(blListChild)

    RefreshBlListRows()
    blFrame:Show()
end

-------------------------------------------------------------------------------
-- 12. BUILD MAIN FRAME  (Advisor | Stats | Settings tabs)
-------------------------------------------------------------------------------

local function BuildMainFrame()
    local W, H = 660, 640

    mainFrame = CreateFrame("Frame","EbonholdEchoBuddyFrame",UIParent)
    mainFrame:SetSize(W,H); mainFrame:SetPoint("CENTER")
    mainFrame:SetMovable(true); mainFrame:EnableMouse(true)
    mainFrame:RegisterForDrag("LeftButton")
    mainFrame:SetScript("OnDragStart",mainFrame.StartMoving)
    mainFrame:SetScript("OnDragStop",mainFrame.StopMovingOrSizing)
    mainFrame:SetFrameStrata("HIGH")
    mainFrame:SetBackdrop({
        bgFile="Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile="Interface\\DialogFrame\\UI-DialogBox-Border",
        tile=true,tileSize=32,edgeSize=32,
        insets={left=11,right=12,top=12,bottom=11},
    })
    mainFrame:SetBackdropColor(0.03,0.02,0.12,0.98)
    mainFrame:SetBackdropBorderColor(0.40,0.25,0.70,1.0)

    -- Header gradient
    local hdrBand = mainFrame:CreateTexture(nil,"BORDER")
    hdrBand:SetTexture("Interface\\Buttons\\WHITE8X8")
    hdrBand:SetPoint("TOPLEFT",mainFrame,"TOPLEFT",12,-12)
    hdrBand:SetPoint("TOPRIGHT",mainFrame,"TOPRIGHT",-12,-12)
    hdrBand:SetHeight(54)
    hdrBand:SetGradientAlpha("VERTICAL",0.14,0.08,0.36,0.95,0.03,0.02,0.12,0)

    -- Gold rule under header
    local hdrLine = mainFrame:CreateTexture(nil,"ARTWORK")
    hdrLine:SetTexture("Interface\\Buttons\\WHITE8X8")
    hdrLine:SetPoint("TOPLEFT",mainFrame,"TOPLEFT",15,-64)
    hdrLine:SetPoint("TOPRIGHT",mainFrame,"TOPRIGHT",-15,-64)
    hdrLine:SetHeight(1); hdrLine:SetVertexColor(0.88,0.72,0.18,1.0)
    local hdrGlow = mainFrame:CreateTexture(nil,"ARTWORK")
    hdrGlow:SetTexture("Interface\\Buttons\\WHITE8X8")
    hdrGlow:SetPoint("TOPLEFT",mainFrame,"TOPLEFT",15,-65)
    hdrGlow:SetPoint("TOPRIGHT",mainFrame,"TOPRIGHT",-15,-65)
    hdrGlow:SetHeight(8)
    hdrGlow:SetGradientAlpha("VERTICAL",0.88,0.72,0.18,0.22,0.88,0.72,0.18,0)
    hdrGlow:SetBlendMode("ADD")

    -- Corner accents
    local function Corner(point,ox,oy,cw,ch)
        local t=mainFrame:CreateTexture(nil,"OVERLAY")
        t:SetTexture("Interface\\Buttons\\WHITE8X8")
        t:SetPoint(point,mainFrame,point,ox,oy)
        t:SetSize(cw,ch); t:SetVertexColor(0.90,0.75,0.20,0.90)
    end
    Corner("TOPLEFT",15,-14,30,2);  Corner("TOPLEFT",15,-14,2,24)
    Corner("TOPRIGHT",-45,-14,30,2);Corner("TOPRIGHT",-17,-14,2,24)

    -- Bottom fade
    local botFade = mainFrame:CreateTexture(nil,"BORDER")
    botFade:SetTexture("Interface\\Buttons\\WHITE8X8")
    botFade:SetPoint("BOTTOMLEFT",mainFrame,"BOTTOMLEFT",12,12)
    botFade:SetPoint("BOTTOMRIGHT",mainFrame,"BOTTOMRIGHT",-12,12)
    botFade:SetHeight(30)
    botFade:SetGradientAlpha("VERTICAL",0.03,0.02,0.10,0,0.03,0.02,0.10,0.60)

    -- Title
    local title = mainFrame:CreateFontString(nil,"OVERLAY","GameFontHighlightLarge")
    title:SetPoint("TOP",mainFrame,"TOP",0,-22)
    title:SetText("|cffFFD700Echo Buddy|r  |cff554477v4|r")
    local sub = mainFrame:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
    sub:SetPoint("TOP",title,"BOTTOM",0,-3)
    sub:SetTextColor(0.55,0.45,0.78)
    sub:SetText("Build Advisor  ·  Auto-Select  ·  AI Learning")
    local closeBtn = CreateFrame("Button",nil,mainFrame,"UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT",mainFrame,"TOPRIGHT",-4,-4)
    closeBtn:SetScript("OnClick",function() mainFrame:Hide() end)

    -- Divider helper
    local function GoldDivider(yOff)
        local glowA = mainFrame:CreateTexture(nil,"ARTWORK")
        glowA:SetTexture("Interface\\Buttons\\WHITE8X8")
        glowA:SetPoint("TOPLEFT",mainFrame,"TOPLEFT",15,yOff+5)
        glowA:SetPoint("TOPRIGHT",mainFrame,"TOPRIGHT",-15,yOff+5)
        glowA:SetHeight(5)
        glowA:SetGradientAlpha("VERTICAL",0.88,0.72,0.18,0,0.88,0.72,0.18,0.20)
        glowA:SetBlendMode("ADD")
        local line = mainFrame:CreateTexture(nil,"ARTWORK")
        line:SetTexture("Interface\\Buttons\\WHITE8X8")
        line:SetPoint("TOPLEFT",mainFrame,"TOPLEFT",15,yOff)
        line:SetPoint("TOPRIGHT",mainFrame,"TOPRIGHT",-15,yOff)
        line:SetHeight(1); line:SetVertexColor(0.88,0.72,0.18,0.85)
        local glowB = mainFrame:CreateTexture(nil,"ARTWORK")
        glowB:SetTexture("Interface\\Buttons\\WHITE8X8")
        glowB:SetPoint("TOPLEFT",mainFrame,"TOPLEFT",15,yOff-1)
        glowB:SetPoint("TOPRIGHT",mainFrame,"TOPRIGHT",-15,yOff-1)
        glowB:SetHeight(6)
        glowB:SetGradientAlpha("VERTICAL",0.88,0.72,0.18,0.20,0.88,0.72,0.18,0)
        glowB:SetBlendMode("ADD")
    end

    local function SectionPanel(yTop, panelH)
        local p = CreateFrame("Frame",nil,mainFrame)
        p:SetPoint("TOPLEFT",mainFrame,"TOPLEFT",14,yTop)
        p:SetPoint("TOPRIGHT",mainFrame,"TOPRIGHT",-14,yTop)
        p:SetHeight(panelH)
        p:SetBackdrop({
            bgFile="Interface\\Tooltips\\UI-Tooltip-Background",
            edgeFile="Interface\\Tooltips\\UI-Tooltip-Border",
            tile=true,tileSize=16,edgeSize=12,
            insets={left=3,right=3,top=3,bottom=3},
        })
        p:SetBackdropColor(0.07,0.04,0.20,0.50)
        p:SetBackdropBorderColor(0.38,0.26,0.62,0.45)
        return p
    end

    GoldDivider(-66)

    ---------------------------------------------------------------------------
    -- AUTO-SELECT STRIP  (always visible, y -70 … -122)
    ---------------------------------------------------------------------------
    SectionPanel(-70,52)

    local asLbl = mainFrame:CreateFontString(nil,"OVERLAY","GameFontNormal")
    asLbl:SetPoint("TOPLEFT",mainFrame,"TOPLEFT",24,-82)
    asLbl:SetText("|cffBB88FFAuto-Select|r")

    local cb = CreateFrame("CheckButton","EBBAutoCheck",mainFrame,"UICheckButtonTemplate")
    cb:SetPoint("TOPLEFT",mainFrame,"TOPLEFT",136,-78); cb:SetSize(26,26)
    _G["EBBAutoCheckText"]:SetText("|cffDDDDDDEnable|r")
    cb:SetChecked(GetDB().autoSelect)
    autoCheckbox = cb

    local autoRoleLbl = mainFrame:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
    autoRoleLbl:SetPoint("TOPLEFT",mainFrame,"TOPLEFT",488,-84)
    autoRoleLbl:SetTextColor(0.65,0.50,0.90); autoRoleLbl:SetText("Role:")
    MakeRoleDD("EBBAutoRoleDD",mainFrame,{"TOPLEFT",mainFrame,"TOPLEFT",508,-72})

    local statusText = mainFrame:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
    statusText:SetPoint("TOPLEFT",mainFrame,"TOPLEFT",24,-106)
    statusText:SetTextColor(0.50,0.42,0.65)

    local function RefreshStatus()
        local db=GetDB()
        if db.autoSelect then
            statusText:SetText("|cff44FF44[ON]|r Auto-picking best echo for |cff00CCFF"..(db.selectedRole or "?").."|r")
        else
            statusText:SetText("|cffFF6666[OFF]|r Enable above to auto-pick echoes.")
        end
    end

    cb:SetScript("OnClick",function(self)
        local en=self:GetChecked() and true or false
        SaveAuto(en); RefreshStatus()
        if en then
            print("|cffFFD700[Echo Buddy]|r Auto-select |cff00FF00ON|r · |cff00CCFF"..(GetDB().selectedRole or "?").."|r")
        else
            print("|cffFFD700[Echo Buddy]|r Auto-select |cffFF4444OFF|r")
        end
    end)

    GoldDivider(-124)

    ---------------------------------------------------------------------------
    -- TAB BUTTONS  (y -130 … -160)
    ---------------------------------------------------------------------------

    local tabPanes = {}
    local tabButtons = {}

    local function SetActiveTab(idx)
        for i, pane in ipairs(tabPanes) do
            if i == idx then pane:Show() else pane:Hide() end
        end
        for i, tbtn in ipairs(tabButtons) do
            local bg  = tbtn._bg
            local ind = tbtn._indicator
            local txt = tbtn._txt
            if i == idx then
                bg:SetVertexColor(0.10,0.06,0.28); bg:SetAlpha(0.80)
                ind:Show()
                txt:SetText("|cffFFD700"..tbtn._label.."|r")
            else
                bg:SetAlpha(0)
                ind:Hide()
                txt:SetText("|cff666677"..tbtn._label.."|r")
            end
        end
        activeTabPane = idx
    end

    local tabLabels = {"Advisor", "Stats", "Settings"}
    local tabW = 196
    for i, lbl in ipairs(tabLabels) do
        local tbtn = CreateFrame("Button",nil,mainFrame)
        tbtn:SetSize(tabW,30)
        tbtn:SetPoint("TOPLEFT",mainFrame,"TOPLEFT",14+(i-1)*(tabW+4),-130)
        tbtn:EnableMouse(true)

        local bg = tbtn:CreateTexture(nil,"BACKGROUND")
        bg:SetAllPoints(); bg:SetTexture("Interface\\Buttons\\WHITE8X8")
        bg:SetVertexColor(0.10,0.06,0.28); bg:SetAlpha(0)
        tbtn._bg = bg

        local ind = tbtn:CreateTexture(nil,"OVERLAY")
        ind:SetTexture("Interface\\Buttons\\WHITE8X8")
        ind:SetPoint("BOTTOMLEFT",tbtn,"BOTTOMLEFT",0,0)
        ind:SetPoint("BOTTOMRIGHT",tbtn,"BOTTOMRIGHT",0,0)
        ind:SetHeight(2); ind:SetVertexColor(0.88,0.72,0.18,1.0); ind:Hide()
        tbtn._indicator = ind

        local txt = tbtn:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
        txt:SetAllPoints()
        txt:SetText("|cff666677"..lbl.."|r")
        tbtn._txt = txt
        tbtn._label = lbl

        local capturedI = i
        tbtn:SetScript("OnClick",function() SetActiveTab(capturedI) end)
        tbtn:SetScript("OnEnter",function(self)
            if activeTabPane ~= capturedI then
                self._bg:SetAlpha(0.35)
            end
        end)
        tbtn:SetScript("OnLeave",function(self)
            if activeTabPane ~= capturedI then
                self._bg:SetAlpha(0)
            end
        end)

        -- Thin border on tab button
        local border = tbtn:CreateTexture(nil,"BORDER")
        border:SetTexture("Interface\\Buttons\\WHITE8X8")
        border:SetPoint("BOTTOMLEFT",tbtn,"BOTTOMLEFT",0,0)
        border:SetPoint("BOTTOMRIGHT",tbtn,"BOTTOMRIGHT",0,0)
        border:SetHeight(1); border:SetVertexColor(0.38,0.26,0.62,0.50)

        table.insert(tabButtons, tbtn)
    end

    -- Thin rule beneath tabs
    local tabRule = mainFrame:CreateTexture(nil,"ARTWORK")
    tabRule:SetTexture("Interface\\Buttons\\WHITE8X8")
    tabRule:SetPoint("TOPLEFT",mainFrame,"TOPLEFT",14,-160)
    tabRule:SetPoint("TOPRIGHT",mainFrame,"TOPRIGHT",-14,-160)
    tabRule:SetHeight(1); tabRule:SetVertexColor(0.38,0.26,0.62,0.50)

    ---------------------------------------------------------------------------
    -- TAB PANE CONTAINER
    ---------------------------------------------------------------------------
    -- All 3 panes occupy the same area: y=-163 to bottom
    local function MakePane()
        local p = CreateFrame("Frame",nil,mainFrame)
        p:SetPoint("TOPLEFT",mainFrame,"TOPLEFT",0,-163)
        p:SetPoint("BOTTOMRIGHT",mainFrame,"BOTTOMRIGHT",0,0)
        p:Hide()
        return p
    end

    ---------------------------------------------------------------------------
    -- PANE 1: ADVISOR
    ---------------------------------------------------------------------------
    local advisorPane = MakePane()
    table.insert(tabPanes, advisorPane)

    -- Controls strip
    local classLbl = advisorPane:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
    classLbl:SetPoint("TOPLEFT",advisorPane,"TOPLEFT",26,-12)
    classLbl:SetTextColor(0.65,0.50,0.88); classLbl:SetText("Class:")

    local classDD = CreateFrame("Frame","EBBClassDropdown",advisorPane,"UIDropDownMenuTemplate")
    classDD:SetPoint("TOPLEFT",advisorPane,"TOPLEFT",56,-4)

    -- Sync advisor role DD with auto-select role
    local advRoleLbl = advisorPane:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
    advRoleLbl:SetPoint("TOPLEFT",advisorPane,"TOPLEFT",272,-12)
    advRoleLbl:SetTextColor(0.65,0.50,0.88); advRoleLbl:SetText("Role:")
    MakeRoleDD("EBBAdvRoleDD",advisorPane,{"TOPLEFT",advisorPane,"TOPLEFT",300,-0})

    local selfBtn = CreateFrame("Button",nil,advisorPane,"GameMenuButtonTemplate")
    selfBtn:SetSize(140,24); selfBtn:SetPoint("TOPLEFT",advisorPane,"TOPLEFT",468,-8)
    selfBtn:SetText("Use My Character")
    selfBtn:SetScript("OnClick",function()
        local _,pc=UnitClass("player")
        if pc then
            for i,c in ipairs(CLASS_INTERNAL) do
                if c==pc then
                    selectedClassIdx=i
                    UIDropDownMenu_SetText(classDD,CLASS_DISPLAY[i])
                    break
                end
            end
        end
    end)

    blBtn = CreateFrame("Button",nil,advisorPane,"GameMenuButtonTemplate")
    blBtn:SetSize(148,24); blBtn:SetPoint("TOPLEFT",advisorPane,"TOPLEFT",20,-42)
    blBtn:SetText("Blacklist")
    blBtn:SetScript("OnClick",function()
        if not blFrame then BuildBlacklistFrame(); return end
        if blFrame:IsShown() then blFrame:Hide() else blFrame:Show() end
    end)
    blBtn:SetScript("OnEnter",function(self)
        GameTooltip:SetOwner(self,"ANCHOR_BOTTOM")
        GameTooltip:SetText("Open Blacklist Manager.\nBlacklisted echoes are excluded\nfrom auto-select and ranked last.",nil,nil,nil,nil,true)
        GameTooltip:Show()
    end)
    blBtn:SetScript("OnLeave",function() GameTooltip:Hide() end)

    local recBtn = CreateFrame("Button",nil,advisorPane,"GameMenuButtonTemplate")
    recBtn:SetSize(172,28); recBtn:SetPoint("TOPLEFT",advisorPane,"TOPLEFT",185,-40)
    recBtn:SetText(">> Recommend Echoes")
    recBtn:SetScript("OnClick",RunRecommendation)

    local resetBtn = CreateFrame("Button",nil,advisorPane,"GameMenuButtonTemplate")
    resetBtn:SetSize(120,24); resetBtn:SetPoint("TOPRIGHT",advisorPane,"TOPRIGHT",-20,-42)
    resetBtn:SetText("Reset AI Data")
    resetBtn:SetScript("OnClick",function()
        local classKey  = CLASS_INTERNAL[selectedClassIdx]
        local role      = ROLES[selectedRoleIdx]
        local classRole = classKey.."_"..role
        ShowConfirm(
            "Reset AI data for |cff00CCFF"..classKey.."/"..role.."|r?\nThis cannot be undone.",
            function()
                ResetLearnData(classRole)
                print("|cffFFD700[Echo Buddy]|r AI data reset for "..classKey.."/"..role)
                RunRecommendation()
            end
        )
    end)
    resetBtn:SetScript("OnEnter",function(self)
        GameTooltip:SetOwner(self,"ANCHOR_BOTTOM")
        GameTooltip:SetText("Wipe learned ELO and run data\nfor the selected class + role.",nil,nil,nil,nil,true)
        GameTooltip:Show()
    end)
    resetBtn:SetScript("OnLeave",function() GameTooltip:Hide() end)

    -- Gold divider within pane (relative to pane top)
    local advDiv = advisorPane:CreateTexture(nil,"ARTWORK")
    advDiv:SetTexture("Interface\\Buttons\\WHITE8X8")
    advDiv:SetPoint("TOPLEFT",advisorPane,"TOPLEFT",15,-72)
    advDiv:SetPoint("TOPRIGHT",advisorPane,"TOPRIGHT",-15,-72)
    advDiv:SetHeight(1); advDiv:SetVertexColor(0.88,0.72,0.18,0.60)

    -- Column headers
    local function Hdr(text,x)
        local h=advisorPane:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
        h:SetPoint("TOPLEFT",advisorPane,"TOPLEFT",x,-80)
        h:SetText("|cffAA8833"..text.."|r")
    end
    Hdr("#",20); Hdr("Echo Name",64); Hdr("Quality",279)
    Hdr("Families",359); Hdr("AI",522); Hdr("Score",538)

    local hdrRule = advisorPane:CreateTexture(nil,"ARTWORK")
    hdrRule:SetTexture("Interface\\Buttons\\WHITE8X8")
    hdrRule:SetPoint("TOPLEFT",advisorPane,"TOPLEFT",16,-94)
    hdrRule:SetPoint("TOPRIGHT",advisorPane,"TOPRIGHT",-34,-94)
    hdrRule:SetHeight(1); hdrRule:SetVertexColor(0.35,0.22,0.55,0.70)

    -- AI stats bar
    aiStatsBar = advisorPane:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
    aiStatsBar:SetPoint("BOTTOMLEFT",advisorPane,"BOTTOMLEFT",20,28)
    aiStatsBar:SetText("|cff665599AI: no data yet — play runs to build the model.|r")

    -- Info bar
    infoText = advisorPane:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
    infoText:SetPoint("BOTTOMLEFT",advisorPane,"BOTTOMLEFT",20,14)
    infoText:SetText("|cff665599Choose a class and role, then click Recommend.|r")

    -- Scroll frame
    local sf = CreateFrame("ScrollFrame","EBBScrollFrame",advisorPane,"UIPanelScrollFrameTemplate")
    sf:SetPoint("TOPLEFT",advisorPane,"TOPLEFT",16,-97)
    sf:SetPoint("BOTTOMRIGHT",advisorPane,"BOTTOMRIGHT",-34,42)
    scrollChild = CreateFrame("Frame","EBBScrollChild",sf)
    scrollChild:SetSize(600,1); sf:SetScrollChild(scrollChild)

    -- Init class dropdown
    UIDropDownMenu_SetWidth(classDD,148)
    UIDropDownMenu_SetText(classDD,CLASS_DISPLAY[selectedClassIdx])
    UIDropDownMenu_Initialize(classDD,function()
        for i,label in ipairs(CLASS_DISPLAY) do
            local info=UIDropDownMenu_CreateInfo()
            info.text=label; info.value=i
            info.func=function()
                selectedClassIdx=i
                UIDropDownMenu_SetText(classDD,label)
                CloseDropDownMenus()
            end
            UIDropDownMenu_AddButton(info)
        end
    end)

    -- Auto-detect player class for class DD
    local _,pc=UnitClass("player")
    if pc then
        for i,c in ipairs(CLASS_INTERNAL) do
            if c==pc then
                selectedClassIdx=i
                UIDropDownMenu_SetText(classDD,CLASS_DISPLAY[i])
                break
            end
        end
    end

    ---------------------------------------------------------------------------
    -- PANE 2: STATS
    ---------------------------------------------------------------------------
    local statsPane = MakePane()
    table.insert(tabPanes, statsPane)

    local statsText = statsPane:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
    statsText:SetPoint("TOPLEFT",statsPane,"TOPLEFT",20,-12)
    statsText:SetPoint("TOPRIGHT",statsPane,"TOPRIGHT",-20,-12)
    statsText:SetHeight(200)
    statsText:SetJustifyH("LEFT"); statsText:SetJustifyV("TOP")
    statsText:SetText("|cff665599Loading...|r")

    -- Run history scroll frame
    local histDiv = statsPane:CreateTexture(nil,"ARTWORK")
    histDiv:SetTexture("Interface\\Buttons\\WHITE8X8")
    histDiv:SetPoint("TOPLEFT",statsPane,"TOPLEFT",15,-218)
    histDiv:SetPoint("TOPRIGHT",statsPane,"TOPRIGHT",-15,-218)
    histDiv:SetHeight(1); histDiv:SetVertexColor(0.88,0.72,0.18,0.60)

    local histLabel = statsPane:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
    histLabel:SetPoint("TOPLEFT",statsPane,"TOPLEFT",20,-228)
    histLabel:SetText("|cffAA8833Recent Run History (newest first)|r")

    local histSF = CreateFrame("ScrollFrame","EBBHistSF",statsPane,"UIPanelScrollFrameTemplate")
    histSF:SetPoint("TOPLEFT",statsPane,"TOPLEFT",16,-244)
    histSF:SetPoint("BOTTOMRIGHT",statsPane,"BOTTOMRIGHT",-34,14)
    local histChild = CreateFrame("Frame","EBBHistChild",histSF)
    histChild:SetSize(600,1); histSF:SetScrollChild(histChild)

    local histRows = {}
    local function RefreshStatsPane()
        -- AI stats text
        local lines = {}
        table.insert(lines,"|cffFFD700AI Learning Stats — "..currentPlayerClass.."|r")
        table.insert(lines," ")
        for _, role in ipairs(ROLES) do
            local cr        = currentPlayerClass.."_"..role
            local tc,tr,te  = LearnStats(cr)
            if tc>0 or tr>0 then
                table.insert(lines,string.format(
                    "|cff00CCFF%-14s|r  %d comparisons · %d runs · %d echoes tracked",
                    role, tc, tr, te))
            else
                table.insert(lines,string.format(
                    "|cff444455%-14s|r  No data yet", role))
            end
        end
        local totalRuns = #GetDB().runHistory
        table.insert(lines," ")
        table.insert(lines,"|cff888888Total runs recorded: "..totalRuns.." (max "..MAX_RUN_HISTORY..")|r")
        statsText:SetText(table.concat(lines,"\n"))

        -- Run history rows
        local history = GetDB().runHistory
        local count   = #history
        for i = #histRows+1, count do histRows[i] = nil end
        -- Hide excess rows
        for i = count+1, #histRows do
            if histRows[i] then histRows[i]:Hide() end
        end

        local rowH = 22
        for idx = 1, count do
            local e = history[count - idx + 1]  -- newest first
            if not histRows[idx] then
                local r = CreateFrame("Frame",nil,histChild)
                r:SetSize(600,rowH)
                local bg2 = r:CreateTexture(nil,"BACKGROUND")
                bg2:SetAllPoints(); bg2:SetTexture("Interface\\Buttons\\WHITE8X8")
                bg2:SetVertexColor(0.06,0.04,0.18); bg2:SetAlpha(idx%2==0 and 0.45 or 0)
                local lbl2 = r:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
                lbl2:SetPoint("LEFT",r,"LEFT",8,0); lbl2:SetSize(580,rowH)
                lbl2:SetJustifyH("LEFT"); r._lbl = lbl2
                histRows[idx] = r
            end
            local r = histRows[idx]
            r:SetPoint("TOPLEFT",histChild,"TOPLEFT",0,-(idx-1)*rowH)
            local timeStr = date("%m/%d %H:%M", e.t or 0)
            local cc      = CLASS_COLOR[e.c or "WARRIOR"] or {1,1,1}
            local cr2     = string.format("%02x%02x%02x",cc[1]*255,cc[2]*255,cc[3]*255)
            r._lbl:SetText(string.format(
                "|cff888888%s|r  |cff%s%s|r  |cff00CCFF%-14s|r  Reached |cffFFD700Lv.%d|r  |cff666677(%d echoes)|r",
                timeStr, cr2, e.c or "?", e.r or "?", e.l or 0, e.n or 0))
            r:SetSize(600,rowH); r:Show()
        end
        if count == 0 then
            if not histRows._empty then
                local r = CreateFrame("Frame",nil,histChild)
                r:SetSize(600,22)
                local lbl2 = r:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
                lbl2:SetPoint("LEFT",r,"LEFT",8,0); lbl2:SetSize(580,22)
                lbl2:SetText("|cff444455No runs recorded yet. Die in a run to record it!|r")
                histRows._empty = r
            end
            histRows._empty:SetPoint("TOPLEFT",histChild,"TOPLEFT",0,0)
            histRows._empty:Show()
        elseif histRows._empty then
            histRows._empty:Hide()
        end
        histChild:SetHeight(math.max(1, count * 22))
    end

    statsPane:SetScript("OnShow", RefreshStatsPane)

    ---------------------------------------------------------------------------
    -- PANE 3: SETTINGS
    ---------------------------------------------------------------------------
    local settingsPane = MakePane()
    table.insert(tabPanes, settingsPane)

    local function SettingsLabel(text, yOff)
        local lbl = settingsPane:CreateFontString(nil,"OVERLAY","GameFontNormal")
        lbl:SetPoint("TOPLEFT",settingsPane,"TOPLEFT",24,yOff)
        lbl:SetText(text); return lbl
    end

    SettingsLabel("|cffBB88FFAuto-Select Settings|r", -14)

    -- Use AI scores checkbox
    local aiCB = CreateFrame("CheckButton","EBBAICheck",settingsPane,"UICheckButtonTemplate")
    aiCB:SetPoint("TOPLEFT",settingsPane,"TOPLEFT",24,-38); aiCB:SetSize(26,26)
    _G["EBBAICheckText"]:SetText("|cffDDDDDDBlend AI scores into recommendations|r")
    aiCB:SetChecked(GetDB().useAIScores)
    aiCB:SetScript("OnClick",function(self)
        GetDB().useAIScores = self:GetChecked() and true or false
    end)
    aiCB:SetScript("OnEnter",function(self)
        GameTooltip:SetOwner(self,"ANCHOR_BOTTOM")
        GameTooltip:SetText("Blend ELO/Run EMA learned scores with static scoring.\nDisable to use static quality/family scoring only.",nil,nil,nil,nil,true)
        GameTooltip:Show()
    end)
    aiCB:SetScript("OnLeave",function() GameTooltip:Hide() end)

    -- Select delay
    local delayLbl = settingsPane:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
    delayLbl:SetPoint("TOPLEFT",settingsPane,"TOPLEFT",24,-72)
    delayLbl:SetTextColor(0.65,0.50,0.90)
    delayLbl:SetText("Auto-select delay (seconds):")

    local delayBox = CreateFrame("EditBox","EBBDelayBox",settingsPane,"InputBoxTemplate")
    delayBox:SetSize(52,20); delayBox:SetPoint("TOPLEFT",settingsPane,"TOPLEFT",230,-70)
    delayBox:SetAutoFocus(false); delayBox:SetMaxLetters(4)
    delayBox:SetText(tostring(GetDB().selectDelay or 0.6))
    delayBox:SetScript("OnEnterPressed",function(self)
        local v=tonumber(self:GetText())
        if v and v>=0 and v<=5 then
            GetDB().selectDelay=v
            print("|cffFFD700[Echo Buddy]|r Select delay set to "..v.."s")
        else
            self:SetText(tostring(GetDB().selectDelay or 0.6))
        end
        self:ClearFocus()
    end)
    delayBox:SetScript("OnEscapePressed",function(self)
        self:SetText(tostring(GetDB().selectDelay or 0.6))
        self:ClearFocus()
    end)

    local delayHint = settingsPane:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
    delayHint:SetPoint("LEFT",delayBox,"RIGHT",6,0)
    delayHint:SetTextColor(0.40,0.38,0.55)
    delayHint:SetText("(0.0 – 5.0 seconds)")

    -- Divider
    local setDiv1 = settingsPane:CreateTexture(nil,"ARTWORK")
    setDiv1:SetTexture("Interface\\Buttons\\WHITE8X8")
    setDiv1:SetPoint("TOPLEFT",settingsPane,"TOPLEFT",15,-94)
    setDiv1:SetPoint("TOPRIGHT",settingsPane,"TOPRIGHT",-15,-94)
    setDiv1:SetHeight(1); setDiv1:SetVertexColor(0.88,0.72,0.18,0.50)

    SettingsLabel("|cffBB88FFDifficulty Preset|r", -104)

    local diffDesc = settingsPane:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
    diffDesc:SetPoint("TOPLEFT",settingsPane,"TOPLEFT",24,-124)
    diffDesc:SetTextColor(0.50,0.45,0.65)
    diffDesc:SetText("Standard: balanced  ·  Speedrun: push damage  ·  Hardcore: maximise survivability")

    local diffButtons = {}
    local function RefreshDiffButtons()
        local cur = GetDB().difficulty or "Standard"
        for _, btn2 in ipairs(diffButtons) do
            if btn2._preset == cur then
                btn2:SetText("|cffFFD700["..btn2._preset.."]|r")
            else
                btn2:SetText("|cff888877"..btn2._preset.."|r")
            end
        end
    end

    for i, preset in ipairs(DIFFICULTY_NAMES) do
        local btn2 = CreateFrame("Button",nil,settingsPane,"GameMenuButtonTemplate")
        btn2:SetSize(130,26)
        btn2:SetPoint("TOPLEFT",settingsPane,"TOPLEFT",20+(i-1)*140,-142)
        btn2:SetText(preset); btn2._preset = preset
        btn2:SetScript("OnClick",function()
            GetDB().difficulty = preset
            RefreshDiffButtons()
        end)
        btn2:SetScript("OnEnter",function(self)
            local p = DIFFICULTY_PRESETS[self._preset]
            GameTooltip:SetOwner(self,"ANCHOR_BOTTOM")
            GameTooltip:SetText(self._preset.."\nPrimary bonus x"..p.primaryMult
                .."  ·  Secondary bonus x"..p.secondaryMult,nil,nil,nil,nil,true)
            GameTooltip:Show()
        end)
        btn2:SetScript("OnLeave",function() GameTooltip:Hide() end)
        table.insert(diffButtons, btn2)
    end
    RefreshDiffButtons()

    -- Divider
    local setDiv2 = settingsPane:CreateTexture(nil,"ARTWORK")
    setDiv2:SetTexture("Interface\\Buttons\\WHITE8X8")
    setDiv2:SetPoint("TOPLEFT",settingsPane,"TOPLEFT",15,-178)
    setDiv2:SetPoint("TOPRIGHT",settingsPane,"TOPRIGHT",-15,-178)
    setDiv2:SetHeight(1); setDiv2:SetVertexColor(0.88,0.72,0.18,0.50)

    SettingsLabel("|cffBB88FFExport / Import AI Learning Data|r", -188)

    local expHint = settingsPane:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
    expHint:SetPoint("TOPLEFT",settingsPane,"TOPLEFT",24,-208)
    expHint:SetTextColor(0.40,0.38,0.55)
    expHint:SetText("Export your AI data to share with others, or import someone else's data to merge with yours.")

    local exportBtn = CreateFrame("Button",nil,settingsPane,"GameMenuButtonTemplate")
    exportBtn:SetSize(100,24); exportBtn:SetPoint("TOPLEFT",settingsPane,"TOPLEFT",24,-228)
    exportBtn:SetText("Export Data")

    local exportBox = CreateFrame("EditBox","EBBExportBox",settingsPane,"InputBoxTemplate")
    exportBox:SetSize(490,20); exportBox:SetPoint("LEFT",exportBtn,"RIGHT",8,0)
    exportBox:SetAutoFocus(false); exportBox:SetMaxLetters(0)
    exportBox:SetText("Click Export to generate a string...")
    exportBtn:SetScript("OnClick",function()
        local str = SerializeLearnDB()
        if str == "" then
            exportBox:SetText("|cffFF4444No AI data to export.|r")
        else
            exportBox:SetText(str)
            exportBox:SetFocus()
            exportBox:HighlightText()
        end
    end)

    local importLbl = settingsPane:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
    importLbl:SetPoint("TOPLEFT",settingsPane,"TOPLEFT",24,-262)
    importLbl:SetTextColor(0.65,0.50,0.90)
    importLbl:SetText("Paste import string here, then click Import:")

    local importBox = CreateFrame("EditBox","EBBImportBox",settingsPane,"InputBoxTemplate")
    importBox:SetSize(490,20); importBox:SetPoint("TOPLEFT",settingsPane,"TOPLEFT",24,-282)
    importBox:SetAutoFocus(false); importBox:SetMaxLetters(0)
    importBox:SetText("")

    local importBtn = CreateFrame("Button",nil,settingsPane,"GameMenuButtonTemplate")
    importBtn:SetSize(100,24); importBtn:SetPoint("LEFT",importBox,"RIGHT",8,0)
    importBtn:SetText("Import Data")
    importBtn:SetScript("OnClick",function()
        local str = importBox:GetText()
        local ok, msg = DeserializeLearnDB(str)
        if ok then
            print("|cffFFD700[Echo Buddy]|r Import successful: "..msg)
            importBox:SetText("")
        else
            print("|cffFF4444[Echo Buddy]|r Import failed: "..msg)
        end
    end)

    -- Divider + Reset All section
    local setDiv3 = settingsPane:CreateTexture(nil,"ARTWORK")
    setDiv3:SetTexture("Interface\\Buttons\\WHITE8X8")
    setDiv3:SetPoint("TOPLEFT",settingsPane,"TOPLEFT",15,-314)
    setDiv3:SetPoint("TOPRIGHT",settingsPane,"TOPRIGHT",-15,-314)
    setDiv3:SetHeight(1); setDiv3:SetVertexColor(0.88,0.72,0.18,0.50)

    local resetAllBtn = CreateFrame("Button",nil,settingsPane,"GameMenuButtonTemplate")
    resetAllBtn:SetSize(180,26); resetAllBtn:SetPoint("TOPLEFT",settingsPane,"TOPLEFT",24,-328)
    resetAllBtn:SetText("|cffFF4444Reset ALL AI Data|r")
    resetAllBtn:SetScript("OnClick",function()
        ShowConfirm("Reset ALL AI learning data for every class and role?\nThis cannot be undone.",
            function()
                ResetLearnData(nil)
                print("|cffFFD700[Echo Buddy]|r All AI data wiped.")
            end)
    end)

    local resetHint = settingsPane:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
    resetHint:SetPoint("LEFT",resetAllBtn,"RIGHT",10,0)
    resetHint:SetTextColor(0.40,0.35,0.50)
    resetHint:SetText("Wipes all ELO + run data for every class and role.")

    -- Divider
    local setDiv4 = settingsPane:CreateTexture(nil,"ARTWORK")
    setDiv4:SetTexture("Interface\\Buttons\\WHITE8X8")
    setDiv4:SetPoint("TOPLEFT",settingsPane,"TOPLEFT",15,-368)
    setDiv4:SetPoint("TOPRIGHT",settingsPane,"TOPRIGHT",-15,-368)
    setDiv4:SetHeight(1); setDiv4:SetVertexColor(0.88,0.72,0.18,0.50)

    SettingsLabel("|cffBB88FFBlacklist Behaviour|r", -378)

    -- Auto-banish/reroll checkbox
    local brCB = CreateFrame("CheckButton","EBBBanishRerollCheck",settingsPane,"UICheckButtonTemplate")
    brCB:SetPoint("TOPLEFT",settingsPane,"TOPLEFT",24,-402); brCB:SetSize(26,26)
    _G["EBBBanishRerollCheckText"]:SetText("|cffDDDDDDAuto-banish/reroll when all choices are blacklisted|r")
    brCB:SetChecked(GetDB().autoBanishReroll)
    brCB:SetScript("OnClick",function(self)
        GetDB().autoBanishReroll = self:GetChecked() and true or false
    end)
    brCB:SetScript("OnEnter",function(self)
        GameTooltip:SetOwner(self,"ANCHOR_BOTTOM")
        GameTooltip:SetText("When auto-select is on and every offered echo is blacklisted,\nautomatically trigger the Banish or Reroll action instead\nof picking a blacklisted echo.",nil,nil,nil,nil,true)
        GameTooltip:Show()
    end)
    brCB:SetScript("OnLeave",function() GameTooltip:Hide() end)

    -- Action selector: Banish / Reroll / Banish then Reroll
    local brActionLbl = settingsPane:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
    brActionLbl:SetPoint("TOPLEFT",settingsPane,"TOPLEFT",24,-434)
    brActionLbl:SetTextColor(0.65,0.50,0.90)
    brActionLbl:SetText("Action when all blacklisted:")

    local BR_ACTIONS = {
        {key="banish",       label="Banish"},
        {key="reroll",       label="Reroll"},
        {key="banish_reroll",label="Banish, then Reroll"},
    }
    local brActionBtns = {}
    local function RefreshBRButtons()
        local cur = GetDB().blacklistAction or "banish"
        for _, b in ipairs(brActionBtns) do
            if b._key == cur then
                b:SetText("|cffFFD700["..b._label.."]|r")
            else
                b:SetText("|cff888877"..b._label.."|r")
            end
        end
    end
    local brBtnX = 220
    for i, entry in ipairs(BR_ACTIONS) do
        local bw = i == 3 and 160 or 90
        local btn3 = CreateFrame("Button",nil,settingsPane,"GameMenuButtonTemplate")
        btn3:SetSize(bw,24)
        btn3:SetPoint("TOPLEFT",settingsPane,"TOPLEFT",brBtnX,-432)
        brBtnX = brBtnX + bw + 6
        btn3:SetText(entry.label); btn3._key = entry.key; btn3._label = entry.label
        btn3:SetScript("OnClick",function()
            GetDB().blacklistAction = entry.key
            RefreshBRButtons()
        end)
        local tip = {
            banish        = "Call Banish when all choices are blacklisted.",
            reroll        = "Call Reroll when all choices are blacklisted.",
            banish_reroll = "Try Banish first; if unavailable, fall back to Reroll.",
        }
        btn3:SetScript("OnEnter",function(self)
            GameTooltip:SetOwner(self,"ANCHOR_BOTTOM")
            GameTooltip:SetText(tip[entry.key],nil,nil,nil,nil,true)
            GameTooltip:Show()
        end)
        btn3:SetScript("OnLeave",function() GameTooltip:Hide() end)
        table.insert(brActionBtns, btn3)
    end
    RefreshBRButtons()

    local brNote = settingsPane:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
    brNote:SetPoint("TOPLEFT",settingsPane,"TOPLEFT",24,-462)
    brNote:SetTextColor(0.40,0.38,0.55)
    brNote:SetText("Note: requires the server to expose a Banish or Reroll function on PerkService.")

    ---------------------------------------------------------------------------
    -- Activate Advisor tab by default
    ---------------------------------------------------------------------------
    SetActiveTab(1)
    RefreshStatus()
    mainFrame:Show()
end

local function OpenAddon()
    if not mainFrame then
        BuildMainFrame()
    else
        if mainFrame:IsShown() then mainFrame:Hide() else mainFrame:Show() end
    end
end

-------------------------------------------------------------------------------
-- 13. SLASH COMMANDS
-------------------------------------------------------------------------------

SLASH_ECHOBUILD1="/echobuild"; SLASH_ECHOBUILD2="/eb"
SlashCmdList["ECHOBUILD"] = function(msg)
    local cmd = (msg or ""):lower():match("^%s*(%S*)")
    if cmd == "help" then
        print("|cffFFD700Echo Buddy v4.0 commands:|r")
        print("  |cff00CCFF/eb|r                    Open / close the window")
        print("  |cff00CCFF/ebauto|r                Toggle auto-select on/off")
        print("  |cff00CCFF/ebstats|r               Print AI stats to chat")
        print("  |cff00CCFF/ebreset [role]|r        Wipe AI data for current class+role (or all)")
        print("  |cff00CCFF/ebblacklist|r            List blacklisted echoes")
        print("  |cff00CCFF/ebblacklist clear|r      Clear the entire blacklist")
    else
        OpenAddon()
    end
end

SLASH_EBBLACKLIST1="/ebblacklist"
SlashCmdList["EBBLACKLIST"] = function(msg)
    local arg = (msg or ""):lower():match("^%s*(.-)%s*$")
    if arg == "clear" then
        ShowConfirm("Clear the entire blacklist?\nAll echoes will become selectable again.",
            function()
                GetDB().blacklist = {}
                print("|cffFFD700[Echo Buddy]|r Blacklist cleared.")
                RunRecommendation()
            end)
    else
        local bl   = GetDB().blacklist
        local list = {}
        for sid in pairs(bl) do
            table.insert(list, GetCachedSpell(sid).name)
        end
        if #list == 0 then
            print("|cffFFD700[Echo Buddy]|r Blacklist is empty.")
        else
            table.sort(list)
            print("|cffFFD700[Echo Buddy]|r Blacklisted echoes ("..#list.."):")
            for _, name in ipairs(list) do print("  |cffAA2222-|r "..name) end
            print("|cff888888Right-click echoes in the Advisor, or use /ebblacklist clear|r")
        end
    end
end

SLASH_EBAUTO1="/ebauto"
SlashCmdList["EBAUTO"] = function()
    local db=GetDB(); local v=not db.autoSelect; SaveAuto(v)
    if autoCheckbox then autoCheckbox:SetChecked(v) end
    if v then
        print("|cffFFD700[Echo Buddy]|r Auto-select |cff00FF00ON|r · |cff00CCFF"..(db.selectedRole or "?").."|r")
    else
        print("|cffFFD700[Echo Buddy]|r Auto-select |cffFF4444OFF|r")
    end
end

SLASH_EBSTATS1="/ebstats"
SlashCmdList["EBSTATS"] = function()
    print("|cffFFD700[Echo Buddy] AI Learning Stats — "..currentPlayerClass.."|r")
    for _, role in ipairs(ROLES) do
        local cr       = currentPlayerClass.."_"..role
        local tc,tr,te = LearnStats(cr)
        if tc>0 or tr>0 then
            print(string.format("  |cff00CCFF%-12s|r  %d comparisons · %d runs · %d echoes",
                role, tc, tr, te))
        end
    end
    print("|cff888888Use /eb - Stats tab for full run history.|r")
end

SLASH_EBRESET1="/ebreset"
SlashCmdList["EBRESET"] = function(msg)
    local arg = (msg or ""):match("^%s*(.-)%s*$")
    if arg == "" then
        ShowConfirm("Reset ALL AI learning data for every class and role?\nThis cannot be undone.",
            function()
                ResetLearnData(nil)
                print("|cffFFD700[Echo Buddy]|r All AI data wiped.")
            end)
    else
        local matched = nil
        for _, r in ipairs(ROLES) do
            if r:lower():find(arg:lower(),1,true) then matched=r; break end
        end
        if matched then
            local classRole = currentPlayerClass.."_"..matched
            ResetLearnData(classRole)
            print("|cffFFD700[Echo Buddy]|r AI data wiped for "..currentPlayerClass.."/"..matched)
        else
            print("|cffFF4444[Echo Buddy]|r Unknown role: '"..arg.."'  Valid: "..table.concat(ROLES,", "))
        end
    end
end

-------------------------------------------------------------------------------
-- 14. INITIALISATION
-------------------------------------------------------------------------------

local initFrame = CreateFrame("Frame")
initFrame:RegisterEvent("PLAYER_LOGIN")
initFrame:RegisterEvent("ADDON_LOADED")

initFrame:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" and arg1 == ADDON then
        GetDB()
        -- Restore selected role index
        local savedRole = EchoBuddyDB.selectedRole
        if savedRole then
            for i, r in ipairs(ROLES) do
                if r == savedRole then selectedRoleIdx=i; break end
            end
        end
        -- Prune zero-data learn entries to keep SavedVariables lean
        PruneLearnDB()

    elseif event == "PLAYER_LOGIN" then
        local _,pc = UnitClass("player")
        if pc then
            currentPlayerClass = pc
            for i, c in ipairs(CLASS_INTERNAL) do
                if c == pc then selectedClassIdx=i; break end
            end
        end

        -- Nudge ELO ratings toward baseline (prevents permanent extreme values)
        ApplyEloDecay()

        InstallHook()

        print("|cffFFD700[Echo Buddy]|r v4.0 Ready — "
            .."|cff00CCFF/eb|r to open  ·  "
            .."|cff00CCFF/ebauto|r to toggle  ·  "
            .."|cff00CCFF/ebstats|r for AI data")
        self:UnregisterEvent("PLAYER_LOGIN")
    end
end)
