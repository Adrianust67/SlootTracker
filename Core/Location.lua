--[[--------------------------------------------------------------------------
	ZoneComplete - Core/Location.lua

	Where the player is, what maps exist, and how far apart two things are.

	The map index (name -> uiMapID, uiMapID -> continent/zone chain) is built
	once per client build and cached, because half the addon works by matching
	free-text source strings like "Zone: Duskwood" against real zone names.
----------------------------------------------------------------------------]]

local ADDON, ns = ...

local Location = {}
ns.Location = Location

local COSMIC_MAP = 946

local Enum_UIMapType = Enum and Enum.UIMapType or {
	Cosmic = 0, World = 1, Continent = 2, Zone = 3, Dungeon = 4, Micro = 5, Orphan = 7,
}

--------------------------------------------------------------------------
-- Map index
--------------------------------------------------------------------------

Location.maps       = {}  -- [uiMapID] = { id, name, mapType, parentID, continentID, depth }
Location.byName     = {}  -- [lowercased name] = uiMapID   (first/most specific wins)
Location.nameList   = {}  -- sorted longest-first, for greedy text matching
Location.zoneList   = {}  -- array of uiMapIDs with mapType == Zone

local function AddMap(info, depth)
	if not info or not info.mapID then return end
	if Location.maps[info.mapID] then return end

	Location.maps[info.mapID] = {
		id       = info.mapID,
		name     = info.name,
		mapType  = info.mapType,
		parentID = info.parentMapID,
		depth    = depth or 0,
	}
end

local function ResolveContinent(mapID)
	local seen, cur = 0, mapID
	while cur and cur ~= 0 and seen < 12 do
		local m = Location.maps[cur]
		if not m then return nil end
		if m.mapType == Enum_UIMapType.Continent then return cur end
		cur = m.parentID
		seen = seen + 1
	end
	return nil
end

function Location:BuildIndex()
	wipe(self.maps)
	wipe(self.byName)
	wipe(self.zoneList)

	-- Walk the whole tree from the cosmic map. GetMapChildrenInfo with
	-- allDescendants returns everything below a node in one call.
	local root = ns.Try(C_Map.GetMapInfo, COSMIC_MAP)
	if root then AddMap(root, 0) end

	local all = ns.Try(C_Map.GetMapChildrenInfo, COSMIC_MAP, nil, true)
	if all then
		for _, info in ipairs(all) do AddMap(info, 1) end
	end

	-- Some maps (instances, scenario stages, a few orphans) are not reachable
	-- from the cosmic tree. Sweep the numeric range to pick up the rest.
	for id = 1, 3000 do
		if not self.maps[id] then
			local info = ns.Try(C_Map.GetMapInfo, id)
			if info and info.name and info.name ~= "" then AddMap(info, 2) end
		end
	end

	for id, m in pairs(self.maps) do
		m.continentID = ResolveContinent(id)

		if m.name and m.name ~= "" then
			local key = m.name:lower()
			local prev = self.byName[key]
			-- Prefer real zones over dungeons/micro maps with the same name.
			if not prev or (m.mapType == Enum_UIMapType.Zone and self.maps[prev].mapType ~= Enum_UIMapType.Zone) then
				self.byName[key] = id
			end
		end

		if m.mapType == Enum_UIMapType.Zone then
			table.insert(self.zoneList, id)
		end
	end

	wipe(self.nameList)
	for name in pairs(self.byName) do table.insert(self.nameList, name) end
	table.sort(self.nameList, function(a, b) return #a > #b end)

	-- First-word bucket index. Matching source blobs against ~2500 zone names
	-- linearly is millions of string searches; bucketing by first word means a
	-- given blob only tests the handful of names whose first word it contains.
	self.wordIndex = {}
	for _, name in ipairs(self.nameList) do
		local first = name:match("^([%w']+)")
		if first and #first >= 3 then
			local bucket = self.wordIndex[first]
			if not bucket then bucket = {}; self.wordIndex[first] = bucket end
			table.insert(bucket, name)
		end
	end

	self.indexed = true
	ns:Debug(("map index built: %d maps, %d zones"):format(self:CountMaps(), #self.zoneList))
end

function Location:CountMaps()
	local n = 0
	for _ in pairs(self.maps) do n = n + 1 end
	return n
end

function Location:GetMapName(mapID)
	local m = mapID and self.maps[mapID]
	if m then return m.name end
	local info = mapID and ns.Try(C_Map.GetMapInfo, mapID)
	return info and info.name or ("Map " .. tostring(mapID))
end

function Location:GetContinent(mapID)
	local m = mapID and self.maps[mapID]
	return m and m.continentID or nil
end

-- Chain of ancestors, closest first: { zone, continent, world, cosmic }
function Location:GetAncestry(mapID)
	local chain, cur, guard = {}, mapID, 0
	while cur and cur ~= 0 and guard < 12 do
		table.insert(chain, cur)
		local m = self.maps[cur]
		if not m then break end
		cur = m.parentID
		guard = guard + 1
	end
	return chain
end

function Location:IsDescendantOf(mapID, ancestorID)
	if not mapID or not ancestorID then return false end
	if mapID == ancestorID then return true end
	for _, id in ipairs(self:GetAncestry(mapID)) do
		if id == ancestorID then return true end
	end
	return false
end

--------------------------------------------------------------------------
-- Text -> map matching
--
-- Mount/pet/toy source strings look like:
--   "Drop: Attumen the Huntsman\nZone: Karazhan"
--   "Vendor: Grand Expedition Yak\nZone: Kun-Lai Summit"
-- so an explicit "Zone:" line is checked first, then a greedy longest-name
-- scan over the whole string.
--------------------------------------------------------------------------

local ZONE_LINE = "[Zz]one:%s*([^\n\r]+)"

function Location:MatchZoneInText(text)
	if not text or text == "" or not self.indexed then return nil end

	local zoneLine = text:match(ZONE_LINE)
	if zoneLine then
		zoneLine = zoneLine:gsub("%s+$", "")
		local id = self.byName[zoneLine:lower()]
		if id then return id, zoneLine end
		-- "Zone: Karazhan, Deadwind Pass" style
		for part in zoneLine:gmatch("[^,;]+") do
			part = part:gsub("^%s+", ""):gsub("%s+$", "")
			local pid = self.byName[part:lower()]
			if pid then return pid, part end
		end
	end

	-- Greedy fallback: longest zone name mentioned anywhere in the blob.
	local haystack = " " .. text:lower():gsub("[\n\r]", " ") .. " "
	local bestID, bestName
	for word in haystack:gmatch("[%w']+") do
		local bucket = self.wordIndex and self.wordIndex[word]
		if bucket then
			for _, name in ipairs(bucket) do
				if #name >= 5 and (not bestName or #name > #bestName)
				   and haystack:find(name, 1, true) then
					bestID, bestName = self.byName[name], name
				end
			end
		end
	end
	return bestID, bestName
end

--------------------------------------------------------------------------
-- Player position
--------------------------------------------------------------------------

Location.current = { mapID = nil, x = nil, y = nil, continentID = nil, zoneName = "", subZone = "" }

function Location:Refresh()
	local mapID = ns.Try(C_Map.GetBestMapForUnit, "player")
	local x, y
	if mapID then
		local pos = ns.Try(C_Map.GetPlayerMapPosition, mapID, "player")
		if pos and pos.GetXY then x, y = pos:GetXY() end
	end

	local prevMap = self.current.mapID
	self.current.mapID       = mapID
	self.current.x           = x
	self.current.y           = y
	self.current.continentID = mapID and self:GetContinent(mapID) or nil
	self.current.zoneName    = GetRealZoneText() or (mapID and self:GetMapName(mapID)) or ""
	self.current.subZone     = GetSubZoneText() or ""

	if mapID and mapID ~= prevMap then
		ns:Fire("ZONE_CHANGED", mapID, prevMap)
	end
	return self.current
end

function Location:Get()
	if not self.current.mapID then self:Refresh() end
	return self.current
end

--------------------------------------------------------------------------
-- Distance
--
-- GetWorldPosFromMapPos converts normalised map coords into continent-space
-- yards, so we can compare points that live on different (but neighbouring)
-- maps. Falls back to normalised distance within a single map.
--------------------------------------------------------------------------

local function WorldPos(mapID, x, y)
	if not mapID or not x or not y then return nil end
	local continentID, pos = ns.Try(C_Map.GetWorldPosFromMapPos, mapID, CreateVector2D(x, y))
	if continentID and pos then
		local wx, wy = pos:GetXY()
		return continentID, wx, wy
	end
	return nil
end

-- Returns distance in yards, or nil when the two points are not comparable.
function Location:Distance(mapA, xA, yA, mapB, xB, yB)
	if not (mapA and mapB and xA and yA and xB and yB) then return nil end

	local cA, wxA, wyA = WorldPos(mapA, xA, yA)
	local cB, wxB, wyB = WorldPos(mapB, xB, yB)
	if cA and cB and cA == cB then
		local dx, dy = wxA - wxB, wyA - wyB
		return math.sqrt(dx * dx + dy * dy)
	end

	if mapA == mapB then
		-- No world transform available (instance maps): approximate using the
		-- normalised coordinate delta scaled to a typical zone width.
		local dx, dy = (xA - xB) * 1000, (yA - yB) * 1000
		return math.sqrt(dx * dx + dy * dy)
	end
	return nil
end

-- Distance from the player to an entry-ish { mapID, x, y }.
function Location:DistanceToPlayer(mapID, x, y)
	local c = self:Get()
	return self:Distance(c.mapID, c.x, c.y, mapID, x, y)
end

--------------------------------------------------------------------------
-- Reach: is a given map within the player's configured search radius?
--
-- Returns a tier string or nil when out of reach:
--   "here"      same map as the player
--   "zone"      inside the player's zone (sub-map, dungeon in the zone)
--   "continent" same continent
--   "world"     anywhere else
--------------------------------------------------------------------------

function Location:ReachTier(mapID)
	local c = self:Get()
	if not mapID or not c.mapID then return nil end

	if mapID == c.mapID then return "here" end
	if self:IsDescendantOf(mapID, c.mapID) or self:IsDescendantOf(c.mapID, mapID) then return "zone" end

	local mine, theirs = c.continentID, self:GetContinent(mapID)
	if mine and theirs and mine == theirs then return "continent" end

	return "world"
end

local REACH_RANK = { here = 1, zone = 2, continent = 3, world = 4 }

function Location:InReach(mapID)
	local tier = self:ReachTier(mapID)
	if not tier then return false, nil end

	local allowed = ns.db and ns.db.reach or "continent"
	local limit = (allowed == "zone" and 2) or (allowed == "continent" and 3) or 4
	return REACH_RANK[tier] <= limit, tier
end

--------------------------------------------------------------------------
-- Waypoints
--------------------------------------------------------------------------

function Location:SetWaypoint(mapID, x, y, title)
	if not (mapID and x and y) then
		ns:Print("no coordinates for that entry.")
		return false
	end

	if _G.TomTom and _G.TomTom.AddWaypoint then
		ns.Try(_G.TomTom.AddWaypoint, _G.TomTom, mapID, x, y, {
			title = title or "ZoneComplete",
			persistent = false,
			minimap = true,
			world = true,
			crazy = true,
		})
		ns:Print(("waypoint set: %s (%.1f, %.1f) in %s"):format(title or "?", x * 100, y * 100, self:GetMapName(mapID)))
		return true
	end

	if C_Map.SetUserWaypoint and UiMapPoint then
		local point = ns.Try(UiMapPoint.CreateFromCoordinates, mapID, x, y, 0)
		if point then
			ns.Try(C_Map.SetUserWaypoint, point)
			if C_SuperTrack and C_SuperTrack.SetSuperTrackedUserWaypoint then
				ns.Try(C_SuperTrack.SetSuperTrackedUserWaypoint, true)
			end
			ns:Print(("waypoint set: %s (%.1f, %.1f)"):format(title or "?", x * 100, y * 100))
			return true
		end
	end

	ns:Print("could not set a waypoint (install TomTom for cross-zone arrows).")
	return false
end

--------------------------------------------------------------------------
-- Wiring
--------------------------------------------------------------------------

ns:On("PLAYER_READY", function()
	Location:BuildIndex()
	Location:Refresh()
end)

local pending
local function DeferredRefresh()
	if pending then return end
	pending = true
	C_Timer.After(0.6, function()
		pending = false
		Location:Refresh()
	end)
end

ns:RegisterEvent("ZONE_CHANGED_NEW_AREA", DeferredRefresh)
ns:RegisterEvent("ZONE_CHANGED", DeferredRefresh)
ns:RegisterEvent("ZONE_CHANGED_INDOORS", DeferredRefresh)
ns:RegisterEvent("PLAYER_ENTERING_WORLD", DeferredRefresh)

-- Cheap position poll so distances and the route stay live while moving.
local elapsed = 0
local poller = CreateFrame("Frame")
poller:SetScript("OnUpdate", function(_, dt)
	elapsed = elapsed + dt
	if elapsed < 1.0 then return end
	elapsed = 0
	if not Location.indexed then return end
	local mapID = ns.Try(C_Map.GetBestMapForUnit, "player")
	if not mapID then return end
	local pos = ns.Try(C_Map.GetPlayerMapPosition, mapID, "player")
	if pos and pos.GetXY then
		Location.current.mapID = mapID
		Location.current.x, Location.current.y = pos:GetXY()
		ns:Fire("POSITION_TICK")
	end
end)
