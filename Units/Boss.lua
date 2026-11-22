-- Boss.lua: boss frames (handoff section 6).
--
-- The main boss slot is the target frame. Above the target column (target,
-- ToT, ToToT) sits a stack of the encounter's other bosses: boss1..boss5.
-- Clicking one targets it.
--
-- Auto-swap: the boss you target "moves" to the main slot. Secure frames
-- can't be re-ordered in combat and macro conditions can't tell which boss
-- is targeted, so:
--   in combat:     the targeted boss's stack slot fades out (alpha is allowed)
--   out of combat: the stack is re-packed without the targeted boss
-- Units come from boss1-5 only. A dungeon boss had no boss tokens on this
-- client (Healer Threat probe); raid behaviour is still being probed. With no
-- tokens the stack simply stays empty.
local _, NF = ...
local Boss = {}
NF.Boss = Boss
local UB = NF.UnitButton
local Plain, Try = NF.Compat.Plain, NF.Compat.Try

Boss.SIZE = 5
Boss.CAST_SPACE = 18
Boss.FADED = 0.2
Boss.buttons = {}
Boss.slot = {}      -- [button] = stack slot (0 = bottom)

local function cfg() return NF.profile.frames.boss end

local function slotHeight()
  local c = cfg()
  return c.height + (c.castBar and Boss.CAST_SPACE or 0) + (c.spacing or 4)
end

-- Bottom-left corner of the stack: above whichever of target / ToT / ToToT
-- reaches highest, lined up with the target frame's left edge.
function Boss.Anchor()
  local f = NF.profile.frames
  local t = f.target
  local tp = t.pos or { x = 0, y = 0 }
  local top = (tp.y or 0) + t.height / 2
  for _, key in ipairs({ "targettarget", "targettargettarget" }) do
    local c = f[key]
    if c.enabled and c.pos then top = math.max(top, c.pos.y + c.height / 2) end
  end
  local c = cfg()
  return (tp.x or 0) - t.width / 2 + (c.offset.x or 0), top + (c.spacing or 4) + (c.offset.y or 0)
end

function Boss.SlotCenter(slot)
  local c = cfg()
  local ax, ay = Boss.Anchor()
  -- the cast bar hangs under each frame, so it's part of the slot below the frame
  local castH = c.castBar and Boss.CAST_SPACE or 0
  return ax + c.width / 2, ay + slot * slotHeight() + castH + c.height / 2
end

-- unlock mode: the whole stack (5 slots)
function Boss.GroupRect()
  local c = cfg()
  local ax, ay = Boss.Anchor()
  local h = Boss.SIZE * slotHeight() - (c.spacing or 4)
  return ax + c.width / 2, ay + h / 2, c.width, h
end

function Boss.SetGroupRect(cx, cy, w, h, resized)
  local c = cfg()
  if resized then
    c.width = math.max(40, math.floor(w + 0.5))
    local per = (h + (c.spacing or 4)) / Boss.SIZE
    c.height = math.max(12, math.floor(per - (c.spacing or 4) - (c.castBar and Boss.CAST_SPACE or 0) + 0.5))
  end
  local ax, ay = Boss.Anchor()
  local bh = Boss.SIZE * slotHeight() - (c.spacing or 4)
  c.offset.x = math.floor((c.offset.x or 0) + (cx - c.width / 2 - ax) + 0.5)
  c.offset.y = math.floor((c.offset.y or 0) + (cy - bh / 2 - ay) + 0.5)
  Boss.Refresh()
end

local function placeButton(b)
  local x, y = Boss.SlotCenter(Boss.slot[b] or 0)
  b:ClearAllPoints()
  b:SetPoint("CENTER", UIParent, "CENTER", x, y)
end

---------------------------------------------------------------------------
-- Which bosses exist / which one is targeted
---------------------------------------------------------------------------
local function isTargeted(unit)
  return Plain(Try(UnitIsUnit, unit, "target")) == true
end

function Boss.Create()
  if #Boss.buttons > 0 or not cfg().enabled then return end
  for i = 1, Boss.SIZE do
    local b = UB.Create("boss", "boss" .. i, "NyteFrames_Boss" .. i)
    b.placeFn = placeButton
    Boss.slot[b] = i - 1
    RegisterUnitWatch(b) -- shows only while boss<i> exists; combat-safe
    Boss.buttons[i] = b
  end
end

-- Out of combat: pack the stack, skipping the boss that's in the main slot.
function Boss.Apply()
  NF.RunOOC("boss-layout", function()
    Boss.Create()
    local slot = 0
    for _, b in ipairs(Boss.buttons) do
      local exists = Plain(Try(UnitExists, b.unit)) == true
      if exists and not isTargeted(b.unit) then
        Boss.slot[b] = slot
        slot = slot + 1
        UB.Layout(b)
      end
    end
    -- absent / targeted ones go after the shown ones, in order
    local next = slot
    for _, b in ipairs(Boss.buttons) do
      local exists = Plain(Try(UnitExists, b.unit)) == true
      if not exists or isTargeted(b.unit) then
        Boss.slot[b] = next
        next = next + 1
        UB.Layout(b)
      end
    end
    Boss.UpdateFade()
    if NF.EditMode and NF.EditMode.active then NF.EditMode.RefreshPreview() end
  end)
end

-- Any time (also in combat): fade the targeted boss out of the stack.
function Boss.UpdateFade()
  for _, b in ipairs(Boss.buttons) do
    b:SetAlpha(isTargeted(b.unit) and Boss.FADED or 1)
  end
end

function Boss.Refresh()
  for _, b in ipairs(Boss.buttons) do UB.Layout(b) end
  if NF.EditMode and NF.EditMode.active then NF.EditMode.RefreshPreview() end
end

local function onTargetChanged()
  Boss.UpdateFade()
  if not InCombatLockdown() then Boss.Apply() end
end

NF.On("PLAYER_TARGET_CHANGED", onTargetChanged)
for _, e in ipairs({ "INSTANCE_ENCOUNTER_ENGAGE_UNIT", "UNIT_TARGETABLE_CHANGED",
    "ENCOUNTER_START", "ENCOUNTER_END", "PLAYER_REGEN_ENABLED", "PLAYER_ENTERING_WORLD" }) do
  NF.On(e, function() if cfg().enabled then Boss.Apply() end end)
end
