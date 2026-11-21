-- Roles.lua: resolve TANK / HEALER / DAMAGER for a group member.
--
-- Chain (handoff section 5):
--   1. manual override (profile.roleOverrides, by character name)
--   2. UnitGroupRolesAssigned, but only TANK/HEALER are trusted: on this client
--      it reports DAMAGER for anyone without a role set (probe #1)
--   3. raid roster main tank / main assist          (milestone 6)
--   4. talents via inspect                            (milestone 6)
--   5. class heuristic: Priest = healer, everyone else = DPS until known
local _, NF = ...
local Roles = {}
NF.Roles = Roles

local Plain, Try = NF.Compat.Plain, NF.Compat.Try

Roles.CLASS_DEFAULT = { PRIEST = "HEALER" }

function Roles.NameOf(unit)
  local n = Plain(Try(GetUnitName, unit, true))
  if type(n) == "string" then return (n:gsub("%-.*$", "")) end
  return nil
end

-- returns role, source ("override" | "assigned" | "class" | "default")
function Roles.Get(unit)
  local name = Roles.NameOf(unit)
  local overrides = NF.profile and NF.profile.roleOverrides
  if name and overrides and overrides[name] then return overrides[name], "override" end
  local assigned = NF.Compat.Role(unit)
  if assigned == "TANK" or assigned == "HEALER" then return assigned, "assigned" end
  local ok, _, class = pcall(UnitClass, unit)
  class = ok and Plain(class) or nil
  if class and Roles.CLASS_DEFAULT[class] then return Roles.CLASS_DEFAULT[class], "class" end
  return "DAMAGER", "default"
end
