-- Frames.lua: spawns the single-unit frames and keeps them current.
-- player, target, target of target (event-driven) and target of target of
-- target (no events exist for it: a throttled 0.1s poll while it's shown).
local _, NF = ...
local Frames = {}
NF.Frames = Frames
local UB = NF.UnitButton

Frames.SINGLE = {
  { key = "player", unit = "player" },
  { key = "target", unit = "target" },
  { key = "targettarget", unit = "targettarget" },
  { key = "targettargettarget", unit = "targettargettarget", poll = 0.1 },
}
Frames.byKey = {}

-- First run on this profile: the defaults were measured on a 1037px-tall
-- screenshot. Scale them to this UI once and store absolute values, so
-- settings and import/export always deal in real sizes.
local function scale()
  local h = UIParent:GetHeight()
  if type(h) ~= "number" or h <= 0 then return nil end
  return h / NF.DB.REF_H
end

-- Scale one frame's reference defaults to this UI and store real values.
function Frames.ScaleFrame(cfg)
  local s = scale() or 1
  cfg.width = math.floor(cfg.width * s + 0.5)
  cfg.height = math.floor(cfg.height * s + 0.5)
  if cfg.refPos and not cfg.pos then
    cfg.pos = { point = "CENTER", relPoint = "CENTER",
      x = math.floor(cfg.refPos.x * s + 0.5), y = math.floor(cfg.refPos.y * s + 0.5) }
  end
end

function Frames.Calibrate()
  local p = NF.profile
  if p.calibrated or not scale() then return end
  for _, cfg in pairs(p.frames) do Frames.ScaleFrame(cfg) end
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
  if def.poll then
    -- OnUpdate only runs while the frame is shown (i.e. the unit exists)
    local elapsed = 0
    b:SetScript("OnUpdate", function(self, e)
      elapsed = elapsed + e
      if elapsed < def.poll then return end
      elapsed = 0
      local ok, err = pcall(UB.UpdateAll, self)
      if not ok then NF.Error("poll " .. self.key, err) end
    end)
  end
end

function Frames.Spawn()
  NF.RunOOC("spawn", function()
    Frames.Calibrate()
    for _, def in ipairs(Frames.SINGLE) do spawn(def) end
    Frames.UpdateAll()
    NF.Party.Apply()
    NF.Raid.Apply()
    NF.CastBar.Apply()
    NF.AuraBridge.Init()
  end)
end

-- Back to the default size and position (keeps the Enabled choice).
function Frames.ResetFrame(key)
  local old = NF.profile.frames[key]
  local def = NF.DB.Copy(NF.DB.DEFAULTS.frames[key])
  Frames.ScaleFrame(def)
  if old then def.enabled = old.enabled end
  NF.profile.frames[key] = def
  Frames.Refresh(key)
end

-- Move a frame (center offset from the screen center) and/or resize it.
function Frames.SetGeometry(key, x, y, w, h)
  local cfg = NF.profile.frames[key]
  if not cfg then return end
  if x and y then cfg.pos = { point = "CENTER", relPoint = "CENTER", x = x, y = y } end
  if w then cfg.width = w end
  if h then cfg.height = h end
  Frames.Refresh(key)
end

-- Re-apply layout after a settings change (size parts wait for combat end).
function Frames.Refresh(key)
  if key == "party" then NF.Party.Refresh() return end
  if key == "raid" then NF.Raid.Refresh() return end
  if key then
    local b = Frames.byKey[key]
    if b then UB.Layout(b) end
    -- the party column hangs off the player frame
    if key == "player" then NF.Party.Refresh() NF.Raid.Refresh() end
    if key == "player" or key == "target" then NF.CastBar.Apply() pcall(NF.AuraBridge.LayoutTarget) end
    return
  end
  for _, b in pairs(Frames.byKey) do UB.Layout(b) end
  NF.Party.Refresh()
  NF.Raid.Refresh()
  NF.CastBar.Apply()
end

function Frames.UpdateAll()
  for _, b in pairs(Frames.byKey) do
    local ok, err = pcall(UB.UpdateAll, b)
    if not ok then NF.Error("update " .. b.key, err) end
  end
end

-- Target changes ripple up the chain: target -> ToT -> ToToT.
local CHAIN = { "target", "targettarget", "targettargettarget" }
local function updateChain(from)
  for i = from, #CHAIN do
    local b = Frames.byKey[CHAIN[i]]
    if b then
      local ok, err = pcall(UB.UpdateAll, b)
      if not ok then NF.Error("update " .. b.key, err) end
    end
  end
end

NF.On("PLAYER_TARGET_CHANGED", function() updateChain(1) end)
NF.On("UNIT_TARGET", function(_, unit)
  if NF.Compat.IsSecret(unit) then return end
  if unit == "target" then updateChain(2)
  elseif unit == "targettarget" then updateChain(3) end
end)

NF.On("PLAYER_ENTERING_WORLD", function() Frames.UpdateAll() end)
