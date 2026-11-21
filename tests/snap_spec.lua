-- Offline tests for Layout/Snap.lua.  lua tests/snap_spec.lua  (or python tests/run.py)
local root = (arg and arg[0] and arg[0]:match("^(.*)[/\\]tests[/\\]")) or "."
local Snap = dofile(root .. "/Layout/Snap.lua")

local passed, failed = 0, 0
local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then passed = passed + 1 else failed = failed + 1 print("FAIL " .. name .. ": " .. tostring(err)) end
end
local function eq(a, b, msg)
  if a ~= b then error((msg or "") .. " expected " .. tostring(b) .. ", got " .. tostring(a), 2) end
end

local R = Snap.Rect

test("no snapping: position only rounded", function()
  local x, y = Snap.Compute(R(10.4, -20.6, 100, 40), {}, {})
  eq(x, 10) ; eq(y, -21)
end)

test("left edge snaps to another frame's left edge within threshold", function()
  local other = R(0, 100, 100, 40)        -- l = -50
  local x, _, kx = Snap.Compute(R(4, 0, 100, 40), { other }, { snapElements = true })  -- l = -46
  eq(x, 0, "x") ; eq(kx, "element")
end)

test("bottom of dragged frame snaps onto the top of another (stacking)", function()
  local target = R(280, -196, 190, 58)    -- t = -167
  local _, y, _, ky = Snap.Compute(R(280, -134, 117, 31), { target }, { snapElements = true }) -- b = -149.5
  eq(ky, nil, "too far (17px) to snap")
  local _, y2, _, ky2 = Snap.Compute(R(280, -148, 117, 31), { target }, { snapElements = true }) -- b = -163.5
  eq(ky2, "element") ; eq(y2, -151, "b lands on -167 => cy = -151.5 rounded")
end)

test("element snap beats grid snap", function()
  local other = R(0, 0, 100, 40)
  local x, _, kx = Snap.Compute(R(3, 200, 100, 40), { other }, { snapElements = true, snapGrid = true, grid = 16 })
  eq(kx, "element") ; eq(x, 0)
end)

test("grid snap lines the left/bottom edge up with the grid", function()
  local x, y, kx, ky = Snap.Compute(R(37, 9, 100, 40), {}, { snapGrid = true, grid = 16 }) -- l=-13 -> -16, b=-11 -> -16
  eq(kx, "grid") ; eq(ky, "grid")
  eq(x, 34) ; eq(y, 4)
end)

test("closest candidate wins", function()
  local a, b = R(0, 0, 100, 40), R(0, 0, 104, 40)  -- l = -50 and -52
  local x = Snap.Compute(R(-1, 300, 100, 40), { a, b }, { snapElements = true }) -- l = -51
  eq(x == 0 or x == -2, true)
end)

print(string.format("snap_spec: %d passed, %d failed", passed, failed))
if failed > 0 then error("snap_spec failed") end
return failed
