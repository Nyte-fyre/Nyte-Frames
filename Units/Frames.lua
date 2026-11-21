-- Frames.lua: spawns the single-unit frames and keeps them current.
-- Milestone 2: player and target. Later milestones add to SINGLE.
local _, NF = ...
local Frames = {}
NF.Frames = Frames
local UB = NF.UnitButton

Frames.SINGLE = {
  { key = "player", unit = "player" },
  { key = "target", unit = "target" },
}
Frames.byKey = {}

-- First run on this profile: the defaults were measured on a 1037px-tall
-- screenshot. Scale them to this UI once and store absolute values, so
-- settings and import/export always deal in real sizes.
function Frames.Calibrate()
  local p = NF.profile
  if p.calibrated then return end
  local h = UIParent:GetHeight()
  if type(h) ~= "number" or h <= 0 then return end
  local s = h / NF.DB.REF_H
  for _, cfg in pairs(p.frames) do
    cfg.width = math.floor(cfg.width * s + 0.5)
    cfg.height = math.floor(cfg.height * s + 0.5)
    if cfg.refPos and not cfg.pos then
      cfg.pos = { point = "CENTER", relPoint = "CENTER",
        x = math.floor(cfg.refPos.x * s + 0.5), y = math.floor(cfg.refPos.y * s + 0.5) }
    end
  end
  p.calibrated = true
end

local function spawn(def)
  local cfg = NF.profile.frames[def.key]
  if not cfg or not cfg.enabled or Frames.byKey[def.key] then return end
  local b = UB.Create(def.key, def.unit)
  Frames.byKey[def.key] = b
  if def.unit == "player" then
    b:Show()
  else
    RegisterUnitWatch(b) -- shows/hides with the unit, combat-safe
  end
end

function Frames.Spawn()
  NF.RunOOC("spawn", function()
    Frames.Calibrate()
    for _, def in ipairs(Frames.SINGLE) do spawn(def) end
    Frames.UpdateAll()
  end)
end

-- Re-apply layout after a settings change (size parts wait for combat end).
function Frames.Refresh(key)
  if key then
    local b = Frames.byKey[key]
    if b then UB.Layout(b) end
    return
  end
  for _, b in pairs(Frames.byKey) do UB.Layout(b) end
end

function Frames.UpdateAll()
  for _, b in pairs(Frames.byKey) do
    local ok, err = pcall(UB.UpdateAll, b)
    if not ok then NF.Error("update " .. b.key, err) end
  end
end

NF.On("PLAYER_TARGET_CHANGED", function()
  local b = Frames.byKey.target
  if b then UB.UpdateAll(b) end
end)

NF.On("PLAYER_ENTERING_WORLD", function() Frames.UpdateAll() end)
