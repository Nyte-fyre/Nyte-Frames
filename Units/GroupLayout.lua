-- GroupLayout.lua: where party/raid cells go. Offsets from the screen center,
-- the same space saved positions use. The group's bottom-right corner sits on
-- the player frame's top-right (plus spacing), shifted by the group's offset;
-- column 0 is right-most and row 0 is the bottom row.
local _, NF = ...
local GL = {}
NF.GroupLayout = GL

function GL.Anchor(c)
  local p = NF.profile.frames.player
  local pos = p.pos or { x = 0, y = 0 }
  local sp = c.spacing or 2
  return (pos.x or 0) + p.width / 2 + (c.offset.x or 0),
         (pos.y or 0) + p.height / 2 + sp + (c.offset.y or 0)
end

function GL.CellCenter(c, colFromRight, rowFromBottom)
  local sp = c.spacing or 2
  local ax, ay = GL.Anchor(c)
  return ax - colFromRight * (c.width + sp) - c.width / 2,
         ay + rowFromBottom * (c.height + sp) + c.height / 2
end

-- Rectangle of a cols x rows block: cx, cy, w, h
function GL.Rect(c, cols, rows)
  local sp = c.spacing or 2
  local ax, ay = GL.Anchor(c)
  local w = cols * c.width + (cols - 1) * sp
  local h = rows * c.height + (rows - 1) * sp
  return ax - w / 2, ay + h / 2, w, h
end

-- Unlock-mode drop of a cols x rows block: new offset (and cell size if resized)
function GL.SetRect(c, cols, rows, cx, cy, w, h, resized)
  local sp = c.spacing or 2
  if resized then
    c.width = math.max(30, math.floor((w - (cols - 1) * sp) / cols + 0.5))
    c.height = math.max(12, math.floor((h - (rows - 1) * sp) / rows + 0.5))
  end
  local ax, ay = GL.Anchor(c)
  local bw = cols * c.width + (cols - 1) * sp
  local bh = rows * c.height + (rows - 1) * sp
  local wantX, wantY = cx + bw / 2, cy - bh / 2
  c.offset.x = math.floor((c.offset.x or 0) + (wantX - ax) + 0.5)
  c.offset.y = math.floor((c.offset.y or 0) + (wantY - ay) + 0.5)
end
