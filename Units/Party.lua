-- Party.lua: one column of up to 4 party members directly above the player
-- frame, sorted tank -> healer -> DPS (Layout/Sorting.lua). The player is
-- never in it.
--
-- A pool of 4 secure buttons is created out of combat. Sorting is plain Lua;
-- it's applied (unit attributes + positions) only out of combat. A roster
-- change in combat is queued for PLAYER_REGEN_ENABLED; until then the
-- buttons keep valid unit tokens and RegisterUnitWatch handles visibility.
local _, NF = ...
local Party = {}
NF.Party = Party
local UB = NF.UnitButton
local Plain, Try = NF.Compat.Plain, NF.Compat.Try

Party.SIZE = 4
Party.buttons = {}
Party.placed = {}   -- [button] = Sorting.Place entry

local function cfg() return NF.profile.frames.party end

---------------------------------------------------------------------------
-- Geometry: offsets from the screen center (same space as saved positions)
---------------------------------------------------------------------------
function Party.Anchor() return NF.GroupLayout.Anchor(cfg()) end

function Party.CellCenter(colFromRight, rowFromBottom)
  return NF.GroupLayout.CellCenter(cfg(), colFromRight, rowFromBottom)
end

-- Rectangle covering a full column (used by unlock mode): cx, cy, w, h
function Party.GroupRect() return NF.GroupLayout.Rect(cfg(), 1, Party.SIZE) end

-- Unlock mode drop: new group rect -> offset and cell size.
function Party.SetGroupRect(cx, cy, w, h, resized)
  NF.GroupLayout.SetRect(cfg(), 1, Party.SIZE, cx, cy, w, h, resized)
  Party.Refresh()
end

local function placeButton(b)
  local e = Party.placed[b]
  if not e then return end
  local x, y = Party.CellCenter(e.colFromRight, e.rowFromBottom)
  b:ClearAllPoints()
  b:SetPoint("CENTER", UIParent, "CENTER", x, y)
end

---------------------------------------------------------------------------
-- Roster -> sorted members
---------------------------------------------------------------------------
local function member(unit)
  local okC, _, class = pcall(UnitClass, unit)
  local role = NF.Roles.Get(unit)
  return {
    key = unit, unit = unit, role = role,
    class = okC and Plain(class) or "",
    name = NF.Roles.NameOf(unit) or unit,
  }
end

function Party.Members()
  local list = {}
  for i = 1, Party.SIZE do
    local u = "party" .. i
    if Plain(Try(UnitExists, u)) then list[#list + 1] = member(u) end
  end
  return list
end

function Party.Active()
  return cfg().enabled and IsInGroup() and not IsInRaid()
end

---------------------------------------------------------------------------
-- Pool + apply
---------------------------------------------------------------------------
function Party.Create()
  if #Party.buttons > 0 or not cfg().enabled then return end
  for i = 1, Party.SIZE do
    local b = UB.Create("party", "party" .. i, "NyteFrames_Party" .. i)
    b.placeFn = placeButton
    NF.RoleMenu.Attach(b)
    b:Hide()
    Party.buttons[i] = b
  end
end

-- Recompute the sort and apply it (queued until combat ends if needed).
function Party.Apply()
  NF.RunOOC("party-layout", function()
    Party.Create()
    if #Party.buttons == 0 then return end
    local members = Party.Active() and Party.Members() or {}
    local placed = NF.Sorting.Place(NF.Sorting.PartyColumns(members), 1)
    for i, b in ipairs(Party.buttons) do
      local e = placed[i]
      Party.placed[b] = e
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
    if NF.EditMode and NF.EditMode.active then NF.EditMode.RefreshPreview() end
  end)
end

-- Size/text settings changed, or the player frame moved.
function Party.Refresh()
  for _, b in ipairs(Party.buttons) do UB.Layout(b) end
  if NF.EditMode and NF.EditMode.active then NF.EditMode.RefreshPreview() end
end

for _, e in ipairs({ "GROUP_ROSTER_UPDATE", "PLAYER_ROLES_ASSIGNED", "PLAYER_ENTERING_WORLD" }) do
  NF.On(e, function() if cfg().enabled then Party.Apply() end end)
end
