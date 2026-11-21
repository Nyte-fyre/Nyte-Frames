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
-- Bottom-right corner of the group: the player frame's top-right + spacing,
-- shifted by the group's own offset.
function Party.Anchor()
  local p = NF.profile.frames.player
  local pos = p.pos or { x = 0, y = 0 }
  local c = cfg()
  local sp = c.spacing or 2
  return (pos.x or 0) + p.width / 2 + (c.offset.x or 0),
         (pos.y or 0) + p.height / 2 + sp + (c.offset.y or 0)
end

-- Center of a cell, by column (0 = right-most) and row (0 = bottom).
function Party.CellCenter(colFromRight, rowFromBottom)
  local c = cfg()
  local sp = c.spacing or 2
  local ax, ay = Party.Anchor()
  return ax - colFromRight * (c.width + sp) - c.width / 2,
         ay + rowFromBottom * (c.height + sp) + c.height / 2
end

-- Rectangle covering a full column (used by unlock mode): cx, cy, w, h
function Party.GroupRect()
  local c = cfg()
  local sp = c.spacing or 2
  local ax, ay = Party.Anchor()
  local h = Party.SIZE * c.height + (Party.SIZE - 1) * sp
  return ax - c.width / 2, ay + h / 2, c.width, h
end

-- Unlock mode drop: new group rect -> offset and cell size.
function Party.SetGroupRect(cx, cy, w, h, resized)
  local c = cfg()
  local sp = c.spacing or 2
  if resized then
    c.width = math.max(30, math.floor(w + 0.5))
    c.height = math.max(12, math.floor((h - (Party.SIZE - 1) * sp) / Party.SIZE + 0.5))
  end
  local ox, oy = Party.Anchor()
  local curH = Party.SIZE * c.height + (Party.SIZE - 1) * sp
  -- where the group's bottom-right should be
  local wantX, wantY = cx + c.width / 2, cy - curH / 2
  c.offset.x = math.floor((c.offset.x or 0) + (wantX - ox) + 0.5)
  c.offset.y = math.floor((c.offset.y or 0) + (wantY - oy) + 0.5)
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
  NF.On(e, function() if #Party.buttons > 0 or cfg().enabled then Party.Apply() end end)
end
