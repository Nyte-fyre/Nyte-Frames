-- Sorting.lua: roster -> ordered columns for party and raid frames.
-- PURE LUA. No WoW API calls, so tests/sorting_spec.lua can run it offline.
--
-- A member is a table: { key = <unique id>, name = "Name", class = "PRIEST",
--   role = "TANK" | "HEALER" | "DAMAGER" | nil, subgroup = 1..8, isPlayer = bool }
-- Unknown roles sort as DPS.

local _, NF = ...
NF = NF or {}

local Sorting = {}
NF.Sorting = Sorting

Sorting.COLUMN_SIZE = 5
Sorting.ROLE_ORDER = { TANK = 1, HEALER = 2, DAMAGER = 3 }

local function roleRank(role)
  return Sorting.ROLE_ORDER[role] or 3
end

-- Tank, healer, DPS; then class; then name; then key (always a strict order).
function Sorting.Compare(a, b)
  local ra, rb = roleRank(a.role), roleRank(b.role)
  if ra ~= rb then return ra < rb end
  local ca, cb = a.class or "", b.class or ""
  if ca ~= cb then return ca < cb end
  local na, nb = a.name or "", b.name or ""
  if na ~= nb then return na < nb end
  return tostring(a.key or "") < tostring(b.key or "")
end

local function sorted(list)
  local out = {}
  for i = 1, #list do out[i] = list[i] end
  table.sort(out, Sorting.Compare)
  return out
end

-- Party (not in a raid): one column, player excluded.
function Sorting.PartyColumns(members)
  local others = {}
  for _, m in ipairs(members) do
    if not m.isPlayer then others[#others + 1] = m end
  end
  return { sorted(others) }
end

-- Raid: column 1 = the player's own group (player excluded); everyone else is
-- one list sorted tank/healer/DPS and chunked into columns of COLUMN_SIZE.
-- Returned in order right-most first: columns[1] sits above the player frame,
-- columns[2] to its left, and so on.
function Sorting.RaidColumns(members, playerSubgroup, columnSize)
  columnSize = columnSize or Sorting.COLUMN_SIZE
  if not playerSubgroup then
    for _, m in ipairs(members) do
      if m.isPlayer then playerSubgroup = m.subgroup break end
    end
  end
  local own, rest = {}, {}
  for _, m in ipairs(members) do
    if not m.isPlayer then
      if playerSubgroup and m.subgroup == playerSubgroup then
        own[#own + 1] = m
      else
        rest[#rest + 1] = m
      end
    end
  end
  local columns = { sorted(own) }
  rest = sorted(rest)
  local col
  for i, m in ipairs(rest) do
    if (i - 1) % columnSize == 0 then
      col = {}
      columns[#columns + 1] = col
    end
    col[#col + 1] = m
  end
  return columns
end

function Sorting.Columns(members, inRaid, playerSubgroup, columnSize)
  if inRaid then
    return Sorting.RaidColumns(members, playerSubgroup, columnSize)
  end
  return Sorting.PartyColumns(members)
end

-- Grid placement for columns. Column 1 is right-most. When more than
-- maxPerRow columns exist, the overflow wraps onto a band above the first
-- (band 2 starts again at the right). Within a column, row 1 is the TOP slot
-- and rows grow downward toward the player frame; the column's bottom edge
-- sits on the anchor, so a short column still touches the player frame.
-- Returns a list of { member = m, column = c, band = b, slot = s,
--   colFromRight = 0-based, rowFromBottom = 0-based } in display order.
function Sorting.Place(columns, maxPerRow, columnSize)
  columnSize = columnSize or Sorting.COLUMN_SIZE
  maxPerRow = (maxPerRow and maxPerRow > 0) and maxPerRow or #columns
  local placed = {}
  for c, col in ipairs(columns) do
    local band = math.floor((c - 1) / maxPerRow) + 1
    local colFromRight = (c - 1) % maxPerRow
    local n = #col
    for s, m in ipairs(col) do
      placed[#placed + 1] = {
        member = m, column = c, band = band, slot = s,
        colFromRight = colFromRight,
        -- bottom row = 0; a column of n shows member 1 on top
        rowFromBottom = (n - s) + (band - 1) * columnSize,
      }
    end
  end
  return placed
end

return Sorting
