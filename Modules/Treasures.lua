--[[--------------------------------------------------------------------------
	SlootTracker - Modules/Treasures.lua

	Things that are physically on the map right now: area points of interest
	(dig sites, treasure chests, event objectives) and live vignettes (rare
	spawns, chests the client has flagged nearby).

	These always carry coordinates, which makes them the backbone of the route
	planner - everything else in the addon knows a zone, but these know a spot.
----------------------------------------------------------------------------]]

local ADDON, ns = ...

local Treasures = { key = "treasures", label = "Treasures & Rares", filters = { "treasures" } }
ns:RegisterProvider(Treasures)

--------------------------------------------------------------------------
-- Area POIs
--------------------------------------------------------------------------

local function ScanAreaPOIs(out, ctx)
	if not (ns.db.treasures.areaPOIs and C_AreaPoiInfo) then return end

	local maps = { ctx.mapID }
	if ns.db.reach ~= "zone" and ctx.continentID then
		for _, mapID in ipairs(ns.Location.zoneList) do
			local m = ns.Location.maps[mapID]
			if m and (ns.db.reach == "world" or m.continentID == ctx.continentID) then
				if mapID ~= ctx.mapID then table.insert(maps, mapID) end
			end
		end
	end

	for _, mapID in ipairs(maps) do
		local poiIDs = ns.Try(C_AreaPoiInfo.GetAreaPOIForMap, mapID)
		if type(poiIDs) == "table" then
			for _, poiID in ipairs(poiIDs) do
				local info = ns.Try(C_AreaPoiInfo.GetAreaPOIInfo, mapID, poiID)
				if info and info.name and info.name ~= "" then
					local x, y
					if info.position and info.position.GetXY then x, y = info.position:GetXY() end

					local timeLeft = ns.Try(C_AreaPoiInfo.GetAreaPOISecondsLeft, poiID)

					table.insert(out, {
						key       = ("poi:%d:%d"):format(mapID, poiID),
						module    = "treasures",
						category  = "treasures",
						id        = poiID,
						name      = info.name,
						icon      = "Interface\\Icons\\INV_Misc_Bag_10",
						atlas     = info.atlasName,
						mapID     = mapID,
						x = x, y = y,
						detail    = info.description ~= "" and info.description or "Point of interest",
						timeLeft  = timeLeft,
						typeLabel = "Point of Interest",
					})
				end
			end
		end
	end
end

--------------------------------------------------------------------------
-- Vignettes (live rares and treasure chests in range)
--------------------------------------------------------------------------

local function ScanVignettes(out, ctx)
	if not (ns.db.treasures.vignettes and C_VignetteInfo) then return end

	local guids = ns.Try(C_VignetteInfo.GetVignettes)
	if type(guids) ~= "table" then return end

	for _, guid in ipairs(guids) do
		local info = ns.Try(C_VignetteInfo.GetVignetteInfo, guid)
		if info and info.name and not info.isDead then
			local x, y
			local pos = ns.Try(C_VignetteInfo.GetVignettePosition, guid, ctx.mapID)
			if pos and pos.GetXY then x, y = pos:GetXY() end

			local isRare = info.atlasName and info.atlasName:lower():find("rare") and true or false

			table.insert(out, {
				key       = "vignette:" .. tostring(guid),
				module    = "treasures",
				category  = "treasures",
				id        = info.vignetteID,
				name      = info.name,
				icon      = isRare and "Interface\\Icons\\Ability_Hunter_MarkedForDeath"
				                    or "Interface\\Icons\\INV_Box_01",
				atlas     = info.atlasName,
				mapID     = ctx.mapID,
				x = x, y = y,
				detail    = isRare and "|cffff8040Rare - up now|r" or "Nearby - up now",
				isRare    = isRare,
				typeLabel = isRare and "Rare" or "Treasure",
			})
		end
	end
end

--------------------------------------------------------------------------
-- Provider
--------------------------------------------------------------------------

function Treasures:Scan(ctx)
	local out = {}
	ns.Try(ScanAreaPOIs, out, ctx)
	ns.Try(ScanVignettes, out, ctx)
	return out
end

--------------------------------------------------------------------------
-- Live updates
--------------------------------------------------------------------------

local pending = false
local function Bump()
	if pending or not (ns.db and ns.db.autoRescan) then return end
	pending = true
	C_Timer.After(4, function()
		pending = false
		ns:Fire("REQUEST_SCAN", true)
	end)
end

ns:RegisterEvent("VIGNETTES_UPDATED", Bump)
ns:RegisterEvent("AREA_POIS_UPDATED", Bump)
