-- RoleMenu.lua: manual role override.
--   Shift + right-click a party/raid frame -> Tank / Healer / DPS / Auto
--   (plain right-click keeps Blizzard's unit menu untouched)
--   /nf role [name] tank|healer|dps|auto   (no name = your target)
-- Overrides are saved by character name in the profile.
local _, NF = ...
local RoleMenu = {}
NF.RoleMenu = RoleMenu

local CHOICES = {
  { "TANK", "Tank" }, { "HEALER", "Healer" }, { "DAMAGER", "DPS" }, { nil, "Auto" },
}
local WORDS = { tank = "TANK", healer = "HEALER", heal = "HEALER", dps = "DAMAGER", damager = "DAMAGER", auto = false }

local function label(role)
  for _, c in ipairs(CHOICES) do if c[1] == role then return c[2] end end
  return "Auto"
end

function RoleMenu.Open(unit, owner)
  local name = NF.Roles.NameOf(unit)
  if not name then
    NF.Print("can't read that player's name here; use /nf role <name> tank|healer|dps|auto.")
    return
  end
  local current = NF.profile.roleOverrides[name]
  if MenuUtil and MenuUtil.CreateContextMenu then
    local ok = pcall(MenuUtil.CreateContextMenu, owner, function(_, root)
      root:CreateTitle(name .. " role")
      for _, c in ipairs(CHOICES) do
        root:CreateRadio(c[2],
          function() return current == c[1] end,
          function() NF.Roles.SetOverride(name, c[1]) end)
      end
    end)
    if ok then return end
  end
  NF.Print(name .. ": role " .. label(current) .. ". Change with /nf role " .. name .. " tank|healer|dps|auto")
end

-- secure button custom action (shift-type2 = "nfRoleMenu")
function RoleMenu.Attach(b)
  b:SetAttribute("shift-type2", "nfRoleMenu")
  b.nfRoleMenu = function(self) RoleMenu.Open(self.unit, self) end
end

function RoleMenu.Command(rest)
  rest = rest or ""
  if rest:lower():match("^%s*refresh%s*$") then
    local n = NF.Roles.RefreshAll()
    NF.Print(string.format("re-checking talents for %d group member(s) (out of combat, about 2s each).", n))
    return
  end
  local word = rest:match("(%S+)%s*$")
  local role = word and WORDS[word:lower()]
  local name = rest:gsub("%s*%S+%s*$", "")
  if role == nil then
    NF.Print("usage: /nf role [name] tank|healer|dps|auto  (no name = your target), or /nf role refresh")
    return
  end
  if name == "" then name = NF.Roles.NameOf("target") end
  if not name then NF.Print("target a player or give a name.") return end
  NF.Roles.SetOverride(name, role or nil)
  NF.Print(name .. " -> " .. label(role or nil))
end
