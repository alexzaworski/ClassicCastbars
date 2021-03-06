local _, namespace = ...
local PoolManager = namespace.PoolManager

local addon = CreateFrame("Frame")
addon:RegisterEvent("PLAYER_LOGIN")
addon:SetScript("OnEvent", function(self, event, ...)
    return self[event](self, ...)
end)

local activeGUIDs = {}
local activeTimers = {} -- active cast data
local activeFrames = {}
local npcCastTimeCacheStart = {}
local npcCastTimeCache = {}
local npcCastUninterruptibleCache = {}

addon.AnchorManager = namespace.AnchorManager
addon.defaultConfig = namespace.defaultConfig
addon.activeFrames = activeFrames
addon.activeTimers = activeTimers
namespace.addon = addon
ClassicCastbars = addon -- global ref for ClassicCastbars_Options

-- upvalues for speed
local gsub = _G.string.gsub
local strfind = _G.string.find
local pairs = _G.pairs
local UnitGUID = _G.UnitGUID
local UnitAura = _G.UnitAura
local UnitClass = _G.UnitClass
local GetSpellTexture = _G.GetSpellTexture
local GetSpellInfo = _G.GetSpellInfo
local CombatLogGetCurrentEventInfo = _G.CombatLogGetCurrentEventInfo
local GetTime = _G.GetTime
local max = _G.math.max
local abs = _G.math.abs
local next = _G.next
local floor = _G.math.floor
local GetUnitSpeed = _G.GetUnitSpeed
local CastingInfo = _G.CastingInfo
local ChannelInfo = _G.ChannelInfo
local castTimeIncreases = namespace.castTimeIncreases
local pushbackBlacklist = namespace.pushbackBlacklist
local unaffectedCastModsSpells = namespace.unaffectedCastModsSpells
local uninterruptibleList = namespace.uninterruptibleList

local BARKSKIN = GetSpellInfo(22812)
local FOCUSED_CASTING = GetSpellInfo(14743)
local NATURES_GRACE = GetSpellInfo(16886)
local MIND_QUICKENING = GetSpellInfo(23723)
local BLINDING_LIGHT = GetSpellInfo(23733)
local BERSERKING = GetSpellInfo(20554)

function addon:GetUnitType(unitID)
    local unit = gsub(unitID or "", "%d", "")
    if unit == "nameplate-testmode" then
        unit = "nameplate"
    elseif unit == "party-testmode" then
        unit = "party"
    end

    return unit
end

function addon:CheckCastModifier(unitID, cast)
    if unitID == "focus" then return end
    if not self.db.pushbackDetect or not cast then return end
    if cast.unitGUID == self.PLAYER_GUID then return end -- modifiers already taken into account with CastingInfo()
    if unaffectedCastModsSpells[cast.spellID] then return end

    -- Debuffs
    if not cast.isChanneled and not cast.hasCastSlowModified and not cast.skipCastSlowModifier then
        for i = 1, 16 do
            local _, _, _, _, _, _, _, _, _, spellID = UnitAura(unitID, i, "HARMFUL")
            if not spellID then break end -- no more debuffs

            local slow = castTimeIncreases[spellID]
            if slow then -- note: multiple slows stack
                cast.endTime = cast.timeStart + (cast.endTime - cast.timeStart) * ((slow / 100) + 1)
                cast.hasCastSlowModified = true
            end
        end
    end

    -- Buffs
    local _, className = UnitClass(unitID)
    local _, raceFile = UnitRace(unitID)
    if className == "DRUID" or className == "PRIEST" or className == "MAGE" or className == "PALADIN" or raceFile == "Troll" then
        local libCD = LibStub and LibStub("LibClassicDurations", true)
        local libCDEnemyBuffs = libCD and libCD.enableEnemyBuffTracking

        for i = 1, 32 do
            local name
            if not libCDEnemyBuffs then
                name = UnitAura(unitID, i, "HELPFUL")
            else
                -- if LibClassicDurations happens to be loaded by some other addon, use it
                -- to get enemy buff data
                name = libCD.UnitAuraWithBuffs(unitID, i, "HELPFUL")
            end
            if not name then break end -- no more buffs

            -- TODO: gotta check how speed is calculated when both Curse of Tongues and Berserking is applied
            if name == BARKSKIN and not cast.hasBarkskinModifier then
                cast.endTime = cast.endTime + 1
                cast.hasBarkskinModifier = true
            elseif name == NATURES_GRACE and not cast.hasNaturesGraceModifier and not cast.isChanneled then
                cast.endTime = cast.endTime - 0.5
                cast.hasNaturesGraceModifier = true
            elseif (name == MIND_QUICKENING or name == BLINDING_LIGHT) and not cast.hasSpeedModifier and not cast.isChanneled then
                cast.endTime = cast.endTime - ((cast.endTime - cast.timeStart) * 33 / 100)
                cast.hasSpeedModifier = true
            elseif name == BERSERKING and not cast.hasBerserkingModifier and not cast.isChanneled then -- put this seperate as it can stack with other modifiers
                cast.endTime = cast.endTime - ((cast.endTime - cast.timeStart) * 0.1)
                cast.hasBerserkingModifier = true
            elseif name == FOCUSED_CASTING then
                cast.hasFocusedCastingModifier = true
            end
        end
    end
end

function addon:StartCast(unitGUID, unitID)
    local cast = activeTimers[unitGUID]
    if not cast then return end

    local castbar = self:GetCastbarFrame(unitID)
    if not castbar then return end

    castbar._data = cast -- set ref to current cast data
    self:DisplayCastbar(castbar, unitID)
    self:CheckCastModifier(unitID, cast)
end

function addon:StopCast(unitID, noFadeOut)
    local castbar = activeFrames[unitID]
    if not castbar then return end

    if not castbar.isTesting then
        self:HideCastbar(castbar, unitID, noFadeOut)
    end

    castbar._data = nil
end

function addon:StartAllCasts(unitGUID)
    if not activeTimers[unitGUID] then return end

    for unitID, guid in pairs(activeGUIDs) do
        if guid == unitGUID then
            self:StartCast(guid, unitID)
        end
    end
end

function addon:StopAllCasts(unitGUID, noFadeOut)
    for unitID, guid in pairs(activeGUIDs) do
        if guid == unitGUID then
            self:StopCast(unitID, noFadeOut)
        end
    end
end

-- Store or refresh new cast data for unit, and start castbar(s)
function addon:StoreCast(unitGUID, unitName, spellName, spellID, iconTexturePath, castTime, isPlayer, isChanneled)
    local currTime = GetTime()

    if not activeTimers[unitGUID] then
        activeTimers[unitGUID] = {}
    end

    local cast = activeTimers[unitGUID]
    cast.spellName = spellName
    cast.spellID = spellID
    cast.icon = iconTexturePath
    cast.maxValue = castTime / 1000
    cast.endTime = currTime + (castTime / 1000)
    cast.isChanneled = isChanneled
    cast.unitGUID = unitGUID
    cast.timeStart = currTime
    cast.isPlayer = isPlayer
    cast.isUninterruptible = uninterruptibleList[spellName] or not isPlayer and npcCastUninterruptibleCache[unitName .. spellName]

    -- just nil previous values to avoid overhead of wiping table
    cast.hasCastSlowModified = nil
    cast.hasBarkskinModifier = nil
    cast.hasNaturesGraceModifier = nil
    cast.hasFocusedCastingModifier = nil
    cast.hasSpeedModifier = nil
    cast.hasBerserkingModifier = nil
    cast.skipCastSlowModifier = nil
    cast.pushbackValue = nil
    cast.isInterrupted = nil
    cast.isCastComplete = nil
    cast.isFailed = nil

    self:StartAllCasts(unitGUID)
end

-- Delete cast data for unit, and stop any active castbars
function addon:DeleteCast(unitGUID, isInterrupted, skipDeleteCache, isCastComplete, noFadeOut)
    if not unitGUID then return end

    local cast = activeTimers[unitGUID]
    if cast then
        cast.isInterrupted = isInterrupted -- just so we can avoid passing it as an arg for every function call
        cast.isCastComplete = isCastComplete -- SPELL_CAST_SUCCESS detected
        self:StopAllCasts(unitGUID, noFadeOut)
        activeTimers[unitGUID] = nil
    end

    -- Weak tables doesn't work with literal values so we need to manually handle memory for this cache :/
    if not skipDeleteCache and npcCastTimeCacheStart[unitGUID] then
        npcCastTimeCacheStart[unitGUID] = nil
    end
end

function addon:CastPushback(unitGUID)
    if not self.db.pushbackDetect then return end
    local cast = activeTimers[unitGUID]
    if not cast or cast.hasBarkskinModifier or cast.hasFocusedCastingModifier then return end
    if pushbackBlacklist[cast.spellName] then return end

    if not cast.isChanneled then
        -- https://wow.gamepedia.com/index.php?title=Interrupt&oldid=305918
        cast.pushbackValue = cast.pushbackValue or 1.0
        cast.maxValue = cast.maxValue + cast.pushbackValue
        cast.endTime = cast.endTime + cast.pushbackValue
        cast.pushbackValue = max(cast.pushbackValue - 0.5, 0.2)
    else
        -- channels are reduced by 25% per hit afaik
        cast.maxValue = cast.maxValue - (cast.maxValue * 25) / 100
        cast.endTime = cast.endTime - (cast.maxValue * 25) / 100
    end
end

SLASH_CCFOCUS1 = "/focus"
SLASH_CCFOCUS2 = "/castbarfocus"
SlashCmdList["CCFOCUS"] = function(msg)
    local unitID = msg == "mouseover" and "mouseover" or "target"
    local tarGUID = UnitGUID(unitID)
    if tarGUID then
        activeGUIDs.focus = tarGUID
        addon:StopCast("focus", true)
        addon:StartCast(tarGUID, "focus")
        addon:SetFocusDisplay(UnitName(unitID), unitID)
    else
        SlashCmdList["CCFOCUSCLEAR"]()
    end
end

SLASH_CCFOCUSCLEAR1 = "/clearfocus"
SlashCmdList["CCFOCUSCLEAR"] = function()
    if activeGUIDs.focus then
        activeGUIDs.focus = nil
        addon:StopCast("focus", true)
        addon:SetFocusDisplay(nil)
    end
end

local function GetSpellCastInfo(spellID)
    local _, _, icon, castTime = GetSpellInfo(spellID)
    if not castTime then return end

    if not unaffectedCastModsSpells[spellID] then
        local _, _, _, hCastTime = GetSpellInfo(8690) -- Hearthstone, normal cast time 10s
        if hCastTime and hCastTime ~= 10000 and hCastTime ~= 0 then -- If current cast time is not 10s it means the player has a casting speed modifier debuff applied on himself.
            -- Since the return values by GetSpellInfo() are affected by the modifier, we need to remove so it doesn't give modified casttimes for other peoples casts.
            return floor(castTime * 10000 / hCastTime), icon
        end
    end

    return castTime, icon
end

function addon:ToggleUnitEvents(shouldReset)
    if self.db.target.enabled then
        self:RegisterEvent("PLAYER_TARGET_CHANGED")
        if self.db.target.autoPosition then
            self:RegisterUnitEvent("UNIT_AURA", "target")
        end
    else
        self:UnregisterEvent("PLAYER_TARGET_CHANGED")
        self:UnregisterEvent("UNIT_AURA")
    end

    if self.db.nameplate.enabled then
        self:RegisterEvent("NAME_PLATE_UNIT_ADDED")
        self:RegisterEvent("NAME_PLATE_UNIT_REMOVED")
    else
        self:UnregisterEvent("NAME_PLATE_UNIT_ADDED")
        self:UnregisterEvent("NAME_PLATE_UNIT_REMOVED")
    end

    if self.db.party.enabled then
        self:RegisterEvent("GROUP_ROSTER_UPDATE")
        self:RegisterEvent("GROUP_JOINED")
    else
        self:UnregisterEvent("GROUP_ROSTER_UPDATE")
        self:UnregisterEvent("GROUP_JOINED")
    end

    if shouldReset then
        self:PLAYER_ENTERING_WORLD() -- wipe all data
    end
end

function addon:PLAYER_ENTERING_WORLD(isInitialLogin)
    if isInitialLogin then return end

    -- Reset all data on loading screens
    wipe(activeGUIDs)
    wipe(activeTimers)
    wipe(activeFrames)
    PoolManager:GetFramePool():ReleaseAll() -- also wipes castbar._data
    self:SetFocusDisplay(nil)

    if self.db.party.enabled and IsInGroup() then
        self:GROUP_ROSTER_UPDATE()
    end
end

function addon:ZONE_CHANGED_NEW_AREA()
    wipe(npcCastTimeCacheStart)
    wipe(npcCastTimeCache)
end

-- Copies table values from src to dst if they don't exist in dst
local function CopyDefaults(src, dst)
    if type(src) ~= "table" then return {} end
    if type(dst) ~= "table" then dst = {} end

    for k, v in pairs(src) do
        if type(v) == "table" then
            dst[k] = CopyDefaults(v, dst[k])
        elseif type(v) ~= type(dst[k]) then
            dst[k] = v
        end
    end

    return dst
end

function addon:PLAYER_LOGIN()
    ClassicCastbarsDB = ClassicCastbarsDB or {}

    if ClassicCastbarsDB.version == "11" then
        ClassicCastbarsDB.party.position = nil
    elseif ClassicCastbarsDB.version == "12" then
        ClassicCastbarsDB.player = nil
    end

    -- Copy any settings from defaults if they don't exist in current profile
    self.db = CopyDefaults(namespace.defaultConfig, ClassicCastbarsDB)
    self.db.version = namespace.defaultConfig.version

    -- Reset fonts on game locale switched (fonts only works for certain locales)
    if self.db.locale ~= GetLocale() then
        self.db.locale = GetLocale()
        self.db.target.castFont = _G.STANDARD_TEXT_FONT
        self.db.nameplate.castFont = _G.STANDARD_TEXT_FONT
        self.db.npcCastUninterruptibleCache = {} -- NPC names are locale dependent
    end

    -- config is not needed anymore if options are not loaded
    if not IsAddOnLoaded("ClassicCastbars_Options") then
        self.defaultConfig = nil
        namespace.defaultConfig = nil
    end

    if self.db.player.enabled then
        self:SkinPlayerCastbar()
    end

    npcCastUninterruptibleCache = self.db.npcCastUninterruptibleCache
    self.PLAYER_GUID = UnitGUID("player")
    self:ToggleUnitEvents()
    self:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
    self:RegisterEvent("PLAYER_ENTERING_WORLD")
    self:RegisterEvent("ZONE_CHANGED_NEW_AREA")
    self:UnregisterEvent("PLAYER_LOGIN")
    self.PLAYER_LOGIN = nil
end

local auraRows = 0
function addon:UNIT_AURA()
    if not self.db.target.autoPosition then return end
    if auraRows == TargetFrame.auraRows then return end
    auraRows = TargetFrame.auraRows

    if activeFrames.target and activeGUIDs.target then
        local parentFrame = self.AnchorManager:GetAnchor("target")
        if parentFrame then
            self:SetTargetCastbarPosition(activeFrames.target, parentFrame)
        end
    end
end

-- Bind unitIDs to unitGUIDs so we can efficiently get unitIDs in CLEU events
function addon:PLAYER_TARGET_CHANGED()
    activeGUIDs.target = UnitGUID("target") or nil

    self:StopCast("target", true) -- always hide previous target's castbar
    self:StartCast(activeGUIDs.target, "target") -- Show castbar again if available
end

function addon:NAME_PLATE_UNIT_ADDED(namePlateUnitToken)
    local unitGUID = UnitGUID(namePlateUnitToken)
    activeGUIDs[namePlateUnitToken] = unitGUID

    self:StartCast(unitGUID, namePlateUnitToken)
end

function addon:NAME_PLATE_UNIT_REMOVED(namePlateUnitToken)
    activeGUIDs[namePlateUnitToken] = nil

    -- Release frame, but do not delete cast data
    local castbar = activeFrames[namePlateUnitToken]
    if castbar then
        PoolManager:ReleaseFrame(castbar)
        activeFrames[namePlateUnitToken] = nil
    end
end

function addon:GROUP_ROSTER_UPDATE()
    for i = 1, 5 do
        local unitID = "party"..i
        activeGUIDs[unitID] = UnitGUID(unitID) or nil

        if activeGUIDs[unitID] then
            self:StopCast(unitID, true)
        else
            local castbar = activeFrames[unitID]
            if castbar then
                PoolManager:ReleaseFrame(castbar)
                activeFrames[unitID] = nil
            end
        end
    end
end
addon.GROUP_JOINED = addon.GROUP_ROSTER_UPDATE

-- Upvalues for combat log events
local bit_band = _G.bit.band
local COMBATLOG_OBJECT_CONTROL_PLAYER = _G.COMBATLOG_OBJECT_CONTROL_PLAYER
local COMBATLOG_OBJECT_TYPE_PLAYER = _G.COMBATLOG_OBJECT_TYPE_PLAYER
local channeledSpells = namespace.channeledSpells
local castTimeTalentDecreases = namespace.castTimeTalentDecreases
local crowdControls = namespace.crowdControls
local castedSpells = namespace.castedSpells
local stopCastOnDamageList = namespace.stopCastOnDamageList
local playerInterrupts = namespace.playerInterrupts
local ARCANE_MISSILES = GetSpellInfo(5143)
local ARCANE_MISSILE = GetSpellInfo(7268)
local DIVINE_SHIELD = GetSpellInfo(642)
local DIVINE_PROTECTION = GetSpellInfo(498)

function addon:COMBAT_LOG_EVENT_UNFILTERED()
    local _, eventType, _, srcGUID, srcName, srcFlags, _, dstGUID, dstName, dstFlags, _, _, spellName, _, missType = CombatLogGetCurrentEventInfo()

    if eventType == "SPELL_CAST_START" then
        local spellID = castedSpells[spellName]
        if not spellID then return end

        local castTime, icon = GetSpellCastInfo(spellID)
        if not castTime then return end

        -- is player or player pet or mind controlled
        local isPlayer = bit_band(srcFlags, COMBATLOG_OBJECT_CONTROL_PLAYER) > 0

        if srcGUID ~= self.PLAYER_GUID then
            if isPlayer then
                -- Use hardcoded talent reduced cast time for certain player spells
                local reducedTime = castTimeTalentDecreases[spellName]
                if reducedTime then
                    castTime = reducedTime
                end
            else
                local cachedTime = npcCastTimeCache[srcName .. spellName]
                if cachedTime then
                    -- Use cached time stored from earlier sightings for NPCs.
                    -- This is because mobs have various cast times, e.g a lvl 20 mob casting Frostbolt might have
                    -- 3.5 cast time but another lvl 40 mob might have 2.5 cast time instead for Frostbolt.
                    castTime = cachedTime
                else
                    npcCastTimeCacheStart[srcGUID] = GetTime()
                end
            end
        else
            local _, _, _, startTime, endTime = CastingInfo()
            if endTime and startTime then
                castTime = endTime - startTime
            end
        end

        -- Note: using return here will make the next function (StoreCast) reuse the current stack frame which is slightly more performant
        return self:StoreCast(srcGUID, srcName, spellName, spellID, icon, castTime, isPlayer)
    elseif eventType == "SPELL_CAST_SUCCESS" then
        local channelCast = channeledSpells[spellName]
        local spellID = castedSpells[spellName]
        if not channelCast and not spellID then
            -- Stop cast on new ability used while castbar is shown
            if activeTimers[srcGUID] and GetTime() - activeTimers[srcGUID].timeStart > 0.25 then
                return self:StopAllCasts(srcGUID)
            end

            return -- not a cast
        end

        local isPlayer = bit_band(srcFlags, COMBATLOG_OBJECT_CONTROL_PLAYER) > 0

        -- Auto correct cast times for mobs
        if not isPlayer and not channelCast then
            if not strfind(srcGUID, "Player-") then -- incase player is mind controlled by an NPC
                local cachedTime = npcCastTimeCache[srcName .. spellName]
                if not cachedTime then
                    local cast = activeTimers[srcGUID]
                    if not cast or (cast and not cast.hasCastSlowModified and not cast.hasSpeedModifier and not cast.hasBerserkingModifier) then
                        local restoredStartTime = npcCastTimeCacheStart[srcGUID]
                        if restoredStartTime then
                            local castTime = (GetTime() - restoredStartTime) * 1000
                            local origCastTime = 0
                            if spellID then
                                local cTime = GetSpellCastInfo(spellID)
                                origCastTime = cTime or 0
                            end

                            local castTimeDiff = abs(castTime - origCastTime)
                            if castTimeDiff <= 4000 and castTimeDiff > 250 then -- heavy lag might affect this so only store time if the diff isn't too big
                                npcCastTimeCache[srcName .. spellName] = castTime
                            end
                        end
                    end
                end
            end
        end

        -- Channeled spells are started on SPELL_CAST_SUCCESS instead of stopped
        -- Also there's no castTime returned from GetSpellInfo for channeled spells so we need to get it from our own list
        if channelCast then
            -- Arcane Missiles triggers this event for every tick so ignore after first tick has been detected
            if (spellName == ARCANE_MISSILES or spellName == ARCANE_MISSILE) and activeTimers[srcGUID] then
                if activeTimers[srcGUID].spellName == ARCANE_MISSILES or activeTimers[srcGUID].spellName == ARCANE_MISSILE then return end
            end

            return self:StoreCast(srcGUID, srcName, spellName, spellID, GetSpellTexture(spellID), channelCast, isPlayer, true)
        end

        -- non-channeled spell, finish it.
        -- We also check the expiration timer in OnUpdate script just incase this event doesn't trigger when i.e unit is no longer in range.
        return self:DeleteCast(srcGUID, nil, nil, true)
    elseif eventType == "SPELL_AURA_APPLIED" then
        if crowdControls[spellName] and activeTimers[dstGUID] then
            -- Aura that interrupts cast was applied
            activeTimers[dstGUID].isFailed = true
            return self:DeleteCast(dstGUID)
        elseif castTimeIncreases[spellName] and activeTimers[dstGUID] then
            -- Cast modifiers doesnt modify already active casts, only the next time the player casts
            activeTimers[dstGUID].skipCastSlowModifier = true
        end
    elseif eventType == "SPELL_AURA_REMOVED" then
        -- Channeled spells has no SPELL_CAST_* event for channel stop,
        -- so check if aura is gone instead since most channels has an aura effect.
        if channeledSpells[spellName] and srcGUID == dstGUID then
            return self:DeleteCast(srcGUID, nil, nil, true)
        end
    elseif eventType == "SPELL_CAST_FAILED" then
        local cast = activeTimers[srcGUID]
        if cast then
            if srcGUID == self.PLAYER_GUID then
                -- Spamming cast keybinding triggers SPELL_CAST_FAILED so check if actually casting or not for the player
                -- Using Arcane Missiles on a target that is currenly LoS also seem to trigger SPELL_CAST_FAILED for some reason...
                if not CastingInfo() and not ChannelInfo() then
                    if not cast.isChanneled then
                        cast.isFailed = true
                    end
                    return self:DeleteCast(srcGUID, nil, nil, cast.isChanneled) -- note: channels shows finish anim on cast failed
                end
            else
                if not cast.isChanneled then
                    cast.isFailed = true
                end
                return self:DeleteCast(srcGUID, nil, nil, cast.isChanneled)
            end
        end
    elseif eventType == "PARTY_KILL" or eventType == "UNIT_DIED" or eventType == "SPELL_INTERRUPT" then
        return self:DeleteCast(dstGUID, eventType == "SPELL_INTERRUPT")
    elseif eventType == "SWING_DAMAGE" or eventType == "ENVIRONMENTAL_DAMAGE" or eventType == "RANGE_DAMAGE" or eventType == "SPELL_DAMAGE" then
        if bit_band(dstFlags, COMBATLOG_OBJECT_TYPE_PLAYER) > 0 then -- is player, and not pet
            local cast = activeTimers[dstGUID]
            if cast then
                if stopCastOnDamageList[cast.spellName] and activeTimers[dstGUID] then
                    activeTimers[dstGUID].isFailed = true
                    return self:DeleteCast(dstGUID)
                end

                return self:CastPushback(dstGUID)
            end
        end
    elseif eventType == "SPELL_MISSED" then
        -- TODO: check if Improved Counterspell has same name as normal Counterspell here
        if missType == "IMMUNE" and playerInterrupts[spellName] then
            local cast = activeTimers[dstGUID]
            if not cast then return end
            if npcCastUninterruptibleCache[dstName .. cast.spellName] then return end -- already added

            if bit_band(dstFlags, COMBATLOG_OBJECT_CONTROL_PLAYER) <= 0 then -- dest unit is not a player
                if bit_band(srcFlags, COMBATLOG_OBJECT_CONTROL_PLAYER) > 0 then -- source unit is player
                    -- Check for bubble immunity
                    local libCD = LibStub and LibStub("LibClassicDurations", true)
                    if libCD and libCD.buffCache then
                        local buffCacheHit = libCD.buffCache[dstGUID]
                        if buffCacheHit then
                            for i = 1, #buffCacheHit do
                                if buffCacheHit[i].name == DIVINE_SHIELD or buffCacheHit[i].name == DIVINE_PROTECTION then
                                    return
                                end
                            end
                        end
                    end

                    npcCastUninterruptibleCache[dstName .. cast.spellName] = true
                end
            end
        end
    end
end

local refresh = 0
local castStopBlacklist = namespace.castStopBlacklist
addon:SetScript("OnUpdate", function(self, elapsed)
    if not next(activeTimers) then return end
    local currTime = GetTime()
    local pushbackEnabled = self.db.pushbackDetect

    refresh = refresh - elapsed
    if refresh < 0 then
        if next(activeGUIDs) then
            -- Check if unit is moving to stop castbar, thanks to Cordankos for this idea
            for unitID, unitGUID in pairs(activeGUIDs) do
                if unitID ~= "focus" then
                    local cast = activeTimers[unitGUID]
                    -- Only stop cast for players since some mobs runs while casting, also because
                    -- of lag we have to only stop it if the cast has been active for atleast 0.25 sec
                    if cast and cast.isPlayer and currTime - cast.timeStart > 0.25 then
                        if not castStopBlacklist[cast.spellName] and GetUnitSpeed(unitID) ~= 0 then
                            local castAlmostFinishied = ((currTime - cast.timeStart) > cast.maxValue - 0.1)
                            -- due to lag its possible that the cast is successfuly casted but still shows interrupted
                            -- unless we ignore the last few miliseconds here
                            if not castAlmostFinishied then
                                if not cast.isChanneled then
                                    cast.isFailed = true
                                end
                                self:DeleteCast(unitGUID, nil, nil, cast.isChanneled)
                            end
                        end
                    end
                end
            end
        end
        refresh = 0.1
    end

    -- Update all shown castbars in a single OnUpdate call
    for unit, castbar in pairs(activeFrames) do
        local cast = castbar._data
        if cast then
            local castTime = cast.endTime - currTime

            if (castTime > 0) then
                if not castbar.showCastInfoOnly then
                    local maxValue = cast.endTime - cast.timeStart
                    local value = currTime - cast.timeStart
                    if cast.isChanneled then -- inverse
                        value = maxValue - value
                    end

                    if pushbackEnabled then
                        -- maxValue is only updated dynamically when pushback detect is enabled
                        castbar:SetMinMaxValues(0, maxValue)
                    end

                    castbar:SetValue(value)
                    castbar.Timer:SetFormattedText("%.1f", castTime)
                    local sparkPosition = (value / maxValue) * castbar:GetWidth()
                    castbar.Spark:SetPoint("CENTER", castbar, "LEFT", sparkPosition, 0)
                end
            else
                -- slightly adjust color of the castbar when its not 100% sure if the cast is casted or failed
                -- (gotta put it here to run before fadeout anim)
                if not cast.isCastComplete and not cast.isInterrupted and not cast.isFailed then
                    castbar.Spark:SetAlpha(0)
                    if not cast.isChanneled then
                        local c = self.db[self:GetUnitType(unit)].statusColor
                        castbar:SetStatusBarColor(c[1], c[2] + 0.1, c[3], c[4])
                        castbar:SetMinMaxValues(0, 1)
                        castbar:SetValue(1)
                    else
                        castbar:SetValue(0)
                    end
                end

                -- Delete cast incase stop event wasn't detected in CLEU
                if castTime <= -0.25 then -- wait atleast 0.25s before deleting incase CLEU stop event is happening at same time
                    if cast.isChanneled and not cast.isCastComplete and not cast.isInterrupted and not cast.isFailed then
                        -- show finish animation on channels that doesnt have CLEU stop event
                        -- Note: channels always have finish animations on stop, even if it was an early stop
                        local skipFade = ((currTime - cast.timeStart) > cast.maxValue + 0.4) -- skips fade anim on castbar being RESHOWN if the cast is expired
                        self:DeleteCast(cast.unitGUID, false, true, true, skipFade)
                    else
                        local skipFade = ((currTime - cast.timeStart) > cast.maxValue + 0.25)
                        self:DeleteCast(cast.unitGUID, false, true, false, skipFade)
                    end
                end
            end
        end
    end
end)
