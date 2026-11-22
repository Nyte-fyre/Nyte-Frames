-- Skin.lua: optional Masque support for the icons Nyte Frames draws itself
-- (the out-of-combat buff row on player/target and the cast bar icons).
-- Auras drawn by Blizzard's private-aura container are Blizzard frames and
-- are left alone. Without Masque everything here is a no-op; with it, the
-- groups show up under Masque's options as "Nyte Frames: Buffs" and
-- "Nyte Frames: Cast Bars", where they can be skinned or disabled.
local _, NF = ...
local SK = {}
NF.Skin = SK

SK.ADDON = "Nyte Frames"
SK.groups = {}

function SK.Masque()
  return LibStub and LibStub("Masque", true) or nil
end

function SK.Group(name)
  local g = SK.groups[name]
  if g then return g end
  local msq = SK.Masque()
  if not msq then return nil end
  local ok, grp = pcall(msq.Group, msq, SK.ADDON, name)
  if ok and grp then
    SK.groups[name] = grp
    return grp
  end
  return nil
end

-- Hand one icon frame to Masque. regions: { Icon=, Cooldown=, Count=, ... }
function SK.Add(groupName, frame, regions, kind)
  local g = SK.Group(groupName)
  if not (g and frame) or frame.nfSkinned then return false end
  local ok = pcall(g.AddButton, g, frame, regions, kind or "Aura")
  if ok then frame.nfSkinned = groupName end
  return ok
end

-- Re-apply the skin after an icon changes size (Masque sizes its layers then).
function SK.Resize(frame)
  local g = frame and frame.nfSkinned and SK.groups[frame.nfSkinned]
  if not g then return end
  if not pcall(g.ReSkin, g, frame) then pcall(g.ReSkin, g) end
end
