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
  focus = { "FocusFrame" },
  pet = { "PetFrame" },
  -- targettargettarget: Blizzard has no frame for it
}

Blizzard.hidden = {}

-- Safe to call again: a frame Blizzard re-parented (Edit Mode does this to
-- some) or created late (raid-style party frames) is hidden again.
local function hideOne(name)
  local f = _G[name]
  if not f then return end
  local okP, parent = pcall(f.GetParent, f)
  if Blizzard.hidden[name] and okP and parent == hiddenParent then return end
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

-- Frames can appear or be re-parented later (Edit Mode layout loads, raid-style
-- party frames are created on first group): re-check out of combat.
for _, e in ipairs({ "PLAYER_ENTERING_WORLD", "GROUP_ROSTER_UPDATE", "EDIT_MODE_LAYOUTS_UPDATED" }) do
  NF.On(e, function() if NF.profile then Blizzard.Apply() end end)
end

-- /nf blizzard: which Blizzard frame is hidden, shown or missing.
function Blizzard.Status()
  local rows = {}
  local keys = {}
  for key in pairs(Blizzard.MAP) do keys[#keys + 1] = key end
  table.sort(keys)
  local function state(name, wanted)
    local f = _G[name]
    if not f then return "|cff888888not on this client|r" end
    local okV, visible = pcall(f.IsVisible, f)
    local okP, parent = pcall(f.GetParent, f)
    local hidden = okP and parent == hiddenParent
    if wanted then
      if hidden and not (okV and visible) then return "|cff8be28bhidden|r" end
      return "|cffff6060SHOWING (should be hidden)|r"
    end
    return (okV and visible) and "shown (Blizzard's)" or "not showing (normal when there's no unit)"
  end
  for _, key in ipairs(keys) do
    local wanted = NF.profile.frames[key] and NF.profile.frames[key].enabled
    for _, name in ipairs(Blizzard.MAP[key]) do
      rows[#rows + 1] = string.format("  %s (%s): %s", name, wanted and "Nyte on" or "Nyte off", state(name, wanted))
    end
  end
  local p = NF.profile.frames.player
  local castWanted = p.enabled and p.castBar and NF.profile.general.hideBlizzardCastBar
  for _, name in ipairs({ "PlayerCastingBarFrame", "CastingBarFrame" }) do
    if _G[name] then rows[#rows + 1] = string.format("  %s (cast bar): %s", name, state(name, castWanted)) end
  end
  return rows
end

-- Ask for a reload after an Enabled toggle.
function Blizzard.PromptReload(text)
  if StaticPopupDialogs and StaticPopup_Show then
    StaticPopupDialogs.NYTEFRAMES_RELOAD = StaticPopupDialogs.NYTEFRAMES_RELOAD or {
      button1 = NF.L["Reload UI"], button2 = NF.L["Later"],
      OnAccept = function() ReloadUI() end,
      timeout = 0, whileDead = true, hideOnEscape = true,
    }
    StaticPopupDialogs.NYTEFRAMES_RELOAD.text = text or NF.L["Nyte Frames: reload the UI to swap between Nyte and Blizzard frames?"]
    if pcall(StaticPopup_Show, "NYTEFRAMES_RELOAD") then return end
  end
  NF.Print(NF.L["type /reload to apply."])
end
