local _, namespace = ...
local AnchorManager = {}
namespace.AnchorManager = AnchorManager

local anchors = {
    target = {
        "SUFUnittarget",
        "XPerl_TargetportraitFrame",
        "ElvUF_Target",
        "oUF_TukuiTarget",
        "btargetUnitFrame",
        "DUF_TargetFrame",
        "GwTargetUnitFrame",
        "PitBull4_Frames_Target",
        "oUF_Target",
        "SUI_targetFrame",
        "gUI4_UnitTarget",
        "oUF_Adirelle_Target",
        "oUF_AftermathhTarget",
        "LUFUnittarget",
        "TargetFrame", -- Blizzard frame should always be last
    },
}

local cache = {}
local _G = _G
local strfind = _G.string.find
local GetNamePlateForUnit = _G.C_NamePlate.GetNamePlateForUnit

local function GetUnitFrameForUnit(unitType)
    local anchorNames = anchors[unitType]
    if not anchorNames then return end

    for i = 1, #anchorNames do
        local name = anchorNames[i]
        if _G[name] then return _G[name] end
    end
end

function AnchorManager:GetAnchor(unitID, getDefault)
    if cache[unitID] and not getDefault then
        return cache[unitID]
    end

    -- Get nameplate
    if unitID == "nameplate-testmode" then
        return GetNamePlateForUnit("target")
    elseif strfind(unitID, "nameplate") then
        return GetNamePlateForUnit(unitID)
    end

    -- Get unit frame
    local frame = GetUnitFrameForUnit(unitID)
    if frame and not getDefault then
        cache[unitID] = frame
    end

    return frame
end
