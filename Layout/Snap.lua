-- Snap.lua: where a dragged frame should land. PURE LUA (tests/snap_spec.lua).
-- Coordinates are offsets from the screen center (x right, y up), the same
-- space saved positions use.
local _, NF = ...
NF = NF or {}

local Snap = {}
NF.Snap = Snap

function Snap.Rect(cx, cy, w, h)
  return { l = cx - w / 2, r = cx + w / 2, b = cy - h / 2, t = cy + h / 2, cx = cx, cy = cy, w = w, h = h }
end

local function round(v) return math.floor(v + 0.5) end

-- Best shift (<= threshold) that lines one of our edges up with another
-- frame's edges or center. Returns the shift or nil.
local function bestShift(mine, theirs, threshold)
  local best
  for _, m in ipairs(mine) do
    for _, t in ipairs(theirs) do
      local d = t - m
      if math.abs(d) <= threshold and (not best or math.abs(d) < math.abs(best)) then best = d end
    end
  end
  return best
end

-- rect: Snap.Rect of the dropped frame. others: list of rects.
-- opts: { threshold = 6, grid = 16, snapGrid = bool, snapElements = bool }
-- Returns the new center x, y (rounded to whole pixels) and which kind of
-- snap won on each axis ("element", "grid" or nil).
function Snap.Compute(rect, others, opts)
  opts = opts or {}
  local threshold = opts.threshold or 6
  local dx, dy, kx, ky
  if opts.snapElements then
    local xs, ys = {}, {}
    for _, o in ipairs(others or {}) do
      xs[#xs + 1] = o.l ; xs[#xs + 1] = o.r ; xs[#xs + 1] = o.cx
      ys[#ys + 1] = o.b ; ys[#ys + 1] = o.t ; ys[#ys + 1] = o.cy
    end
    dx = bestShift({ rect.l, rect.r, rect.cx }, xs, threshold)
    dy = bestShift({ rect.b, rect.t, rect.cy }, ys, threshold)
    if dx then kx = "element" end
    if dy then ky = "element" end
  end
  local g = opts.grid or 0
  if opts.snapGrid and g > 0 then
    if not dx then dx = round(rect.l / g) * g - rect.l kx = "grid" end
    if not dy then dy = round(rect.b / g) * g - rect.b ky = "grid" end
  end
  return round(rect.cx + (dx or 0)), round(rect.cy + (dy or 0)), kx, ky
end

return Snap
