-- RoleRules.lua: talent points -> role. PURE LUA (tests/roles_spec.lua).
--
-- On this client all three classic talent trees live in one C_Traits tree,
-- side by side by node posX (probe: Paladin Holy at x 1000-2800, Protection
-- 5000-6800, Retribution 9000-10800; an inspected Shaman matched the same
-- bands). buckets = { [floor(posX / 1000)] = points }.
local _, NF = ...
NF = NF or {}

local RoleRules = {}
NF.RoleRules = RoleRules

RoleRules.MIN_POINTS = 11 -- below this the tree choice isn't meaningful yet

-- Classic tree order per class -> role of each tree.
-- Feral Druids are treated as tanks (the usual raid job); override if not.
RoleRules.TREES = {
  WARRIOR = { "DAMAGER", "DAMAGER", "TANK" },   -- Arms, Fury, Protection
  PALADIN = { "HEALER", "TANK", "DAMAGER" },    -- Holy, Protection, Retribution
  DRUID   = { "DAMAGER", "TANK", "HEALER" },    -- Balance, Feral, Restoration
  SHAMAN  = { "DAMAGER", "DAMAGER", "HEALER" }, -- Elemental, Enhancement, Restoration
  PRIEST  = { "HEALER", "HEALER", "DAMAGER" },  -- Discipline, Holy, Shadow
}

-- posX bucket (thousands) -> tree 1..3
function RoleRules.TreeOfBucket(b)
  if b <= 3 then return 1 elseif b <= 7 then return 2 end
  return 3
end

-- returns tree index (1..3) with the most points, and its point count
function RoleRules.MainTree(buckets)
  local points = { 0, 0, 0 }
  for b, n in pairs(buckets or {}) do
    local t = RoleRules.TreeOfBucket(tonumber(b) or 0)
    points[t] = points[t] + (tonumber(n) or 0)
  end
  local best, bestN = nil, 0
  for t = 1, 3 do
    if points[t] > bestN then best, bestN = t, points[t] end
  end
  return best, bestN
end

-- role or nil (too few points / class without a role choice)
function RoleRules.FromTalents(class, buckets)
  local trees = RoleRules.TREES[class]
  if not trees then return "DAMAGER" end -- Mage, Warlock, Hunter, Rogue
  local tree, n = RoleRules.MainTree(buckets)
  if not tree or n < RoleRules.MIN_POINTS then return nil end
  return trees[tree]
end

return RoleRules
