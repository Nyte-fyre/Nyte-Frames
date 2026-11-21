-- Raid.lua: raid frames (handoff section 5).
--   Column 1 (right-most, directly above the player frame): the player's own
--   group, tank -> healer -> DPS, player excluded.
--   Everyone else: one list sorted tank -> healer -> DPS, chunked into
--   columns of 5 placed to the left. Columns past maxColumnsPerRow wrap onto
--   a band above the first instead of running off screen.
--
-- A pool of 40 secure buttons is made out of combat. The sort is plain Lua
-- (Layout/Sorting.lua) and is applied only out of combat; roster changes in
-- combat are queued for PLAYER_REGEN_ENABLED.
local _, NF = ...
local Raid = {}
NF.Raid = Raid
local UB = NF.UnitButton
local GL = NF.GroupLayout
local Plain, Try = NF.Compat.Plain, NF.Compat.Try

Raid.SIZE = 40
Raid.COLUMN = 5
Raid.PREVIEW_COLS = 5 -- unlock-mode block: a 25-player layout
Raid.buttons = {}
Raid.placed = {}

local function cfg() return NF.profile.frames.raid end

function Raid.CellCenter(colFromRight, rowFromBottom)
  return GL.CellCenter(cfg(), colFromRight, rowFromBottom)
end

function Raid.GroupRect() return GL.Rect(cfg(), Raid.PREVIEW_COLS, Raid.COLUMN) end

function Raid.SetGroupRect(cx, cy, w, h, resized)
  GL.SetRect(cfg(), Raid.PREVIEW_COLS, Raid.COLUMN, cx, cy, w, h, resized)
  Raid.Refresh()
end

local function placeButton(b)
  local e = Raid.placed[b]
  if not e then return end
  local x, y = Raid.CellCenter(e.colFromRight, e.rowFromBottom)
  b:ClearAllPoints()
  b:SetPoint("CENTER", UIParent, "CENTER", x, y)
end

function Raid.Active()
  return cfg().enabled and IsInRaid()
end

---------------------------------------------------------------------------
-- Roster
---------------------------------------------------------------------------
-- returns members (incl. the player, flagged) and the player's subgroup
function Raid.Members()
  local list, mySub = {}, nil
  local n = GetNumGroupMembers() or 0
  for i = 1, math.min(n, Raid.SIZE) do
    local u = "raid" .. i
    if Plain(Try(UnitExists, u)) then
      local ok, name, _, subgroup, _, _, fileName = pcall(GetRaidRosterInfo, i)
      subgroup = ok and Plain(subgroup) or nil
      local isPlayer = Plain(Try(UnitIsUnit, u, "player"))
      if isPlayer == nil then isPlayer = (NF.Roles.NameOf(u) == NF.Roles.NameOf("player")) end
      isPlayer = isPlayer == true
      if isPlayer then mySub = subgroup end
      local okC, _, class = pcall(UnitClass, u)
      list[#list + 1] = {
        key = u, unit = u, subgroup = subgroup, isPlayer = isPlayer,
        role = (not isPlayer) and NF.Roles.Get(u) or nil,
        class = (okC and Plain(class)) or (ok and Plain(fileName)) or "",
        name = NF.Roles.NameOf(u) or (ok and Plain(name)) or u,
      }
    end
  end
  return list, mySub
end

---------------------------------------------------------------------------
-- Pool + apply
---------------------------------------------------------------------------
function Raid.Create()
  if #Raid.buttons > 0 or not cfg().enabled then return end
  for i = 1, Raid.SIZE do
    local b = UB.Create("raid", "raid" .. i, "NyteFrames_Raid" .. i)
    b.placeFn = placeButton
    NF.RoleMenu.Attach(b)
    b:Hide()
    Raid.buttons[i] = b
  end
end

function Raid.Apply()
  NF.RunOOC("raid-layout", function()
    Raid.Create()
    if #Raid.buttons == 0 then return end
    local placed = {}
    if Raid.Active() then
      NF.Roles.ScanRoster()
      local members, mySub = Raid.Members()
      local columns = NF.Sorting.RaidColumns(members, mySub, Raid.COLUMN)
      placed = NF.Sorting.Place(columns, cfg().maxColumnsPerRow or 8, Raid.COLUMN)
    end
    for i, b in ipairs(Raid.buttons) do
      local e = placed[i]
      Raid.placed[b] = e
      if e then
        UB.SetUnit(b, e.member.unit)
        UB.SetRole(b, e.member.role)
        UB.Layout(b)
        RegisterUnitWatch(b)
      else
        UnregisterUnitWatch(b)
        b:Hide()
      end
    end
    Raid.columns = placed
    if NF.EditMode and NF.EditMode.active then NF.EditMode.RefreshPreview() end
    NF.AuraBridge.ScheduleGroup()
  end)
end

function Raid.Refresh()
  for _, b in ipairs(Raid.buttons) do
    if Raid.placed[b] then UB.Layout(b) end
  end
  if NF.EditMode and NF.EditMode.active then NF.EditMode.RefreshPreview() end
end

-- Roster events come in bursts while a raid forms: re-sort at most every 0.3s.
local pendingApply
local function scheduleApply()
  if not cfg().enabled or pendingApply then return end
  pendingApply = true
  C_Timer.After(0.3, function()
    pendingApply = false
    Raid.Apply()
  end)
end
Raid.Schedule = scheduleApply

for _, e in ipairs({ "GROUP_ROSTER_UPDATE", "PLAYER_ROLES_ASSIGNED", "PLAYER_ENTERING_WORLD" }) do
  NF.On(e, scheduleApply)
end
