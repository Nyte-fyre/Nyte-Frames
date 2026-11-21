-- Offline tests for Layout/RoleRules.lua.  lua tests/roles_spec.lua  (or python tests/run.py)
local root = (arg and arg[0] and arg[0]:match("^(.*)[/\\]tests[/\\]")) or "."
local R = dofile(root .. "/Layout/RoleRules.lua")

local passed, failed = 0, 0
local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then passed = passed + 1 else failed = failed + 1 print("FAIL " .. name .. ": " .. tostring(err)) end
end
local function eq(a, b, msg)
  if a ~= b then error((msg or "") .. " expected " .. tostring(b) .. ", got " .. tostring(a), 2) end
end

test("probe: the author's Paladin (31 Holy / 4 Prot) is a healer", function()
  eq(R.FromTalents("PALADIN", { [1] = 23, [2] = 8, [5] = 4 }), "HEALER")
end)

test("probe: inspected Shaman (31 tree 1 / 8 tree 3) is DPS (Elemental)", function()
  eq(R.FromTalents("SHAMAN", { [1] = 11, [2] = 20, [9] = 1, [10] = 7 }), "DAMAGER")
end)

test("protection warrior is a tank", function()
  eq(R.FromTalents("WARRIOR", { [9] = 20, [10] = 11, [1] = 5 }), "TANK")
end)

test("restoration druid heals, feral druid tanks", function()
  eq(R.FromTalents("DRUID", { [9] = 31 }), "HEALER")
  eq(R.FromTalents("DRUID", { [5] = 31 }), "TANK")
end)

test("shadow priest is DPS, discipline priest heals", function()
  eq(R.FromTalents("PRIEST", { [10] = 31 }), "DAMAGER")
  eq(R.FromTalents("PRIEST", { [2] = 31 }), "HEALER")
end)

test("too few points: unknown", function()
  eq(R.FromTalents("WARRIOR", { [9] = 5 }), nil)
  eq(R.FromTalents("PALADIN", {}), nil)
end)

test("pure DPS classes are always DPS", function()
  eq(R.FromTalents("MAGE", {}), "DAMAGER")
  eq(R.FromTalents("ROGUE", { [1] = 31 }), "DAMAGER")
end)

test("string keys (from SavedVariables) still work", function()
  eq(R.FromTalents("PALADIN", { ["5"] = 31 }), "TANK")
end)

print(string.format("roles_spec: %d passed, %d failed", passed, failed))
if failed > 0 then error("roles_spec failed") end
return failed
