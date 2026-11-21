-- Offline tests for Layout/Sorting.lua. Plain Lua 5.1+:
--   lua tests/sorting_spec.lua        (from the repo root)
--   python tests/run.py               (same thing through lupa)

local root = (arg and arg[0] and arg[0]:match("^(.*)[/\\]tests[/\\]")) or "."
local Sorting = dofile(root .. "/Layout/Sorting.lua")

local passed, failed = 0, 0
local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then
    passed = passed + 1
  else
    failed = failed + 1
    print("FAIL " .. name .. ": " .. tostring(err))
  end
end
local function eq(a, b, msg)
  if a ~= b then error((msg or "") .. " expected " .. tostring(b) .. ", got " .. tostring(a), 2) end
end

local n = 0
local function M(role, class, name, subgroup, isPlayer)
  n = n + 1
  return { key = "k" .. n, role = role, class = class, name = name, subgroup = subgroup, isPlayer = isPlayer }
end
local function roles(col)
  local t = {}
  for i, m in ipairs(col) do t[i] = (m.role or "?"):sub(1, 1) end
  return table.concat(t)
end

-- Section 5 worked example: the rest of the raid is 3 tanks + 4 healers + 7 DPS.
local function workedRaid()
  local r = {
    -- player's group (subgroup 1): player + 4 others
    M("HEALER", "PALADIN", "Nyte", 1, true),
    M("DAMAGER", "MAGE", "Mage1", 1),
    M("TANK", "WARRIOR", "Tank1", 1),
    M("DAMAGER", "ROGUE", "Rogue1", 1),
    M("HEALER", "PRIEST", "Priest1", 1),
  }
  local rest = {
    M("TANK", "WARRIOR", "Wt", 2), M("TANK", "DRUID", "Dt", 3), M("TANK", "PALADIN", "Pt", 4),
    M("HEALER", "PRIEST", "Ph", 2), M("HEALER", "SHAMAN", "Sh", 3), M("HEALER", "DRUID", "Dh", 4),
    M("HEALER", "PALADIN", "Pah", 2),
    M("DAMAGER", "MAGE", "Md", 2), M("DAMAGER", "WARLOCK", "Wd", 3), M("DAMAGER", "HUNTER", "Hd", 3),
    M("DAMAGER", "ROGUE", "Rd", 4), M("DAMAGER", "MAGE", "Md2", 4), M("DAMAGER", "PRIEST", "Spd", 2),
    M("DAMAGER", "SHAMAN", "Ed", 3),
  }
  for _, m in ipairs(rest) do r[#r + 1] = m end
  return r
end

test("worked example: 3T + 4H + 7D outside the player's group", function()
  local cols = Sorting.RaidColumns(workedRaid())
  eq(#cols, 4, "column count")
  eq(roles(cols[1]), "THDD", "column 1 (own group, player excluded)")
  eq(roles(cols[2]), "TTTHH", "column 2")
  eq(roles(cols[3]), "HHDDD", "column 3")
  eq(roles(cols[4]), "DDDD", "column 4 (far left)")
end)

test("player is never in any column", function()
  for _, col in ipairs(Sorting.RaidColumns(workedRaid())) do
    for _, m in ipairs(col) do assert(not m.isPlayer, "player found") end
  end
  for _, m in ipairs(Sorting.PartyColumns(workedRaid())[1]) do assert(not m.isPlayer) end
end)

test("player subgroup is found from the roster when not given", function()
  local r = workedRaid()
  r[1].subgroup = 3
  local cols = Sorting.RaidColumns(r)
  for _, m in ipairs(cols[1]) do eq(m.subgroup, 3, "own column subgroup") end
  eq(#cols[1], 5, "group 3 has 5 others")
end)

test("within a role: class, then name", function()
  local cols = Sorting.PartyColumns({
    M("DAMAGER", "ROGUE", "Zed", 1), M("DAMAGER", "MAGE", "Bob", 1),
    M("DAMAGER", "MAGE", "Amy", 1), M("TANK", "WARRIOR", "Tim", 1),
  })
  local names = {}
  for i, m in ipairs(cols[1]) do names[i] = m.name end
  eq(table.concat(names, ","), "Tim,Amy,Bob,Zed")
end)

test("unknown role sorts with DPS", function()
  local cols = Sorting.PartyColumns({ M(nil, "MAGE", "A", 1), M("HEALER", "PRIEST", "B", 1) })
  eq(cols[1][1].name, "B")
  eq(cols[1][2].name, "A")
end)

test("sorting is stable for identical class/name (key breaks ties)", function()
  local a, b = M("DAMAGER", "MAGE", "Same", 1), M("DAMAGER", "MAGE", "Same", 1)
  local c1 = Sorting.PartyColumns({ a, b })[1]
  local c2 = Sorting.PartyColumns({ b, a })[1]
  eq(c1[1], c2[1])
end)

test("party: one column, player excluded", function()
  local cols = Sorting.Columns({ M("HEALER", "PALADIN", "Me", 1, true), M("DAMAGER", "MAGE", "X", 1) }, false)
  eq(#cols, 1)
  eq(#cols[1], 1)
end)

test("solo raid with only the player: one empty own column", function()
  local cols = Sorting.RaidColumns({ M("HEALER", "PALADIN", "Me", 1, true) })
  eq(#cols, 1)
  eq(#cols[1], 0)
end)

test("40-man: 39 others -> own group + 7 columns", function()
  local r = { M("HEALER", "PALADIN", "Me", 1, true) }
  for g = 1, 8 do
    for i = 1, (g == 1 and 4 or 5) do r[#r + 1] = M("DAMAGER", "MAGE", "p" .. g .. i, g) end
  end
  local cols = Sorting.RaidColumns(r)
  eq(#cols, 8)
  eq(#cols[1], 4)
  eq(#cols[8], 5)
end)

test("place: column 1 right-most, bottom aligned, wraps to a second band", function()
  local cols = Sorting.RaidColumns(workedRaid())
  local placed = Sorting.Place(cols, 3)
  local byKey = {}
  for _, p in ipairs(placed) do byKey[p.member] = p end
  -- column 1 has 4 members: top member sits at rowFromBottom 3
  local top = byKey[cols[1][1]]
  eq(top.colFromRight, 0) ; eq(top.rowFromBottom, 3) ; eq(top.band, 1)
  eq(byKey[cols[1][4]].rowFromBottom, 0)
  -- column 4 wraps (maxPerRow 3) to band 2, back at the right edge
  local w = byKey[cols[4][1]]
  eq(w.band, 2) ; eq(w.colFromRight, 0) ; eq(w.rowFromBottom, 3 + 5)
end)

print(string.format("sorting_spec: %d passed, %d failed", passed, failed))
if failed > 0 then
  if os and os.exit then os.exit(1) end
  error("sorting_spec failed")
end
return failed
