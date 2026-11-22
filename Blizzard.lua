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
  boss = { "BossTargetFrameContainer" },
  -- targettargettarget: Blizzard has no frame for it
}

Blizzard.hidden = {}

local function hideOne(name)
  local f = _G[name]
  if not f or Blizzard.hidden[name] then return end
  pcall(f.UnregisterAllEvents, f)
  pcall(f.Hide, f)
  pcall(f.SetParent, f, hiddenParent)
  Blizzard.hidden[name] = true
end

function Blizzard.Apply()
  NF.RunOOC("blizzard", function()
    for key, names in pairs(Blizzard.MAP) do
      local cfg = NF.profile.frames[key]
      if cfg and cfg.enabled then
        for _, name in ipairs(names) do hideOne(name) end
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
function Blizzard.PromptReload(text)
  if StaticPopupDialogs and StaticPopup_Show then
    StaticPopupDialogs.NYTEFRAMES_RELOAD = StaticPopupDialogs.NYTEFRAMES_RELOAD or {
      button1 = "Reload UI", button2 = "Later",
      OnAccept = function() ReloadUI() end,
      timeout = 0, whileDead = true, hideOnEscape = true,
    }
    StaticPopupDialogs.NYTEFRAMES_RELOAD.text = text or "Nyte Frames: reload the UI to swap between Nyte and Blizzard frames?"
    if pcall(StaticPopup_Show, "NYTEFRAMES_RELOAD") then return end
  end
  NF.Print("type /reload to apply.")
end
