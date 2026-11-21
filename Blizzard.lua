-- Blizzard.lua: hide the default frame for each Nyte frame that's enabled.
-- Hiding = unregister events, hide, re-parent to a hidden frame (the usual
-- unit-frame-addon approach). Live restore isn't clean without taint, so
-- turning a frame off asks for a UI reload instead.
local _, NF = ...
local Blizzard = {}
NF.Blizzard = Blizzard

local hiddenParent = CreateFrame("Frame")
hiddenParent:Hide()
Blizzard.hiddenParent = hiddenParent

-- frame key -> Blizzard globals it replaces
Blizzard.MAP = {
  player = { "PlayerFrame" },
  target = { "TargetFrame" },
  targettarget = { "TargetFrameToT" },
  party = { "PartyFrame", "CompactPartyFrame" },
  raid = { "CompactRaidFrameContainer", "CompactRaidFrameManager" },
  -- targettargettarget: Blizzard has no frame for it
}

-- With Blizzard aura icons on (general.blizzardAuras), these are "ghosted"
-- instead: kept alive and updating (so their aura icons keep working in
-- combat, where addons can't read auras) but invisible and click-through.
-- Nyte Frames moves their aura icons onto its own frames (AuraBridge.lua).
Blizzard.GHOST = {
  TargetFrame = true, CompactPartyFrame = true,
  CompactRaidFrameContainer = true, CompactRaidFrameManager = true,
}

Blizzard.hidden, Blizzard.ghosted = {}, {}

local function hideOne(name)
  local f = _G[name]
  if not f or Blizzard.hidden[name] then return end
  pcall(f.UnregisterAllEvents, f)
  pcall(f.Hide, f)
  pcall(f.SetParent, f, hiddenParent)
  Blizzard.hidden[name] = true
end

local function ghostOne(name)
  local f = _G[name]
  if not f then return end
  pcall(f.SetAlpha, f, 0)
  pcall(f.EnableMouse, f, false)
  if name == "CompactRaidFrameManager" then
    -- the side panel has its own buttons: park it off screen
    pcall(f.ClearAllPoints, f)
    pcall(f.SetPoint, f, "TOPRIGHT", UIParent, "TOPLEFT", -400, 0)
  end
  Blizzard.ghosted[name] = true
end
Blizzard.GhostOne = ghostOne

function Blizzard.Apply()
  NF.RunOOC("blizzard", function()
    local ghostOK = NF.profile.general.blizzardAuras
    for key, names in pairs(Blizzard.MAP) do
      local cfg = NF.profile.frames[key]
      if cfg and cfg.enabled then
        for _, name in ipairs(names) do
          if ghostOK and Blizzard.GHOST[name] then ghostOne(name) else hideOne(name) end
        end
      end
    end
    Blizzard.ApplyCastBar()
  end)
end

-- Blizzard's player cast bar goes away when ours is on.
function Blizzard.ApplyCastBar()
  local p = NF.profile.frames.player
  if p.enabled and p.castBar and NF.profile.general.hideBlizzardCastBar then
    hideOne("PlayerCastingBarFrame")
    hideOne("CastingBarFrame")
  end
end

-- Ask for a reload after an Enabled toggle.
function Blizzard.PromptReload()
  if StaticPopupDialogs and StaticPopup_Show then
    StaticPopupDialogs.NYTEFRAMES_RELOAD = StaticPopupDialogs.NYTEFRAMES_RELOAD or {
      text = "Nyte Frames: reload the UI to swap between Nyte and Blizzard frames?",
      button1 = "Reload UI", button2 = "Later",
      OnAccept = function() ReloadUI() end,
      timeout = 0, whileDead = true, hideOnEscape = true,
    }
    if pcall(StaticPopup_Show, "NYTEFRAMES_RELOAD") then return end
  end
  NF.Print("type /reload to apply.")
end
