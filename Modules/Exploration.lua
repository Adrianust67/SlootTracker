--[[--------------------------------------------------------------------------
	SlootTracker - Modules/Exploration.lua

	Unexplored subzones, pulled from the "Explore <Zone>" achievements, whose
	criteria are one-per-subzone (criteria type 43, asset = areaID).

	These criteria are account-wide in retail, but each one records WHICH
	character satisfied it - so character scope can still tell you which
	corners of the map this particular character has never walked into.

	Blizzard exposes no coordinates for an unexplored area, so positions are
	recovered by sampling a grid across the map - see "Finding somewhere to
	actually walk" below. That is what lets these entries join the route
	instead of only ranking by zone.
----------------------------------------------------------------------------]]

local ADDON, ns = ...

local Exploration = { key = "exploration", label = "Unexplored areas", filters = { "exploration" } }
ns:RegisterProvider(Exploration)

local CRITERIA_TYPE_EXPLORE_AREA = 43

--------------------------------------------------------------------------
-- Index: map -> exploration achievement
--------------------------------------------------------------------------

local function CacheRoot()
	ns.db.cache.explore = ns.db.cache.explore or {}
	return ns.db.cache.explore
end

local prepareAttempts = 0

function Exploration:Prepare()
	local cache = CacheRoot()
	if cache.byMap then return end
	if ns:IsTaskRunning("ST:ExploreIndex") then return end

	local achCache = ns.db.cache.ach
	if not (achCache and achCache.zoneOf) then
		-- This index is derived from the achievement index, which may still be
		-- building. Retry a bounded number of times rather than looping forever.
		prepareAttempts = prepareAttempts + 1
		if prepareAttempts > 12 then
			ns:Debug("exploration index gave up waiting for the achievement index")
			return
		end
		C_Timer.After(5, function() Exploration:Prepare() end)
		return
	end
	prepareAttempts = 0

	local candidates = {}
	for achID, mapID in pairs(achCache.zoneOf) do
		table.insert(candidates, { ach = achID, map = mapID })
	end

	local byMap = {}
	local i = 0
	ns:RunTask("ST:ExploreIndex", function()
		i = i + 1
		local c = candidates[i]
		if not c then return false end

		local num = ns.Try(GetAchievementNumCriteria, c.ach) or 0
		if num > 0 then
			local _, criteriaType = ns.Try(GetAchievementCriteriaInfo, c.ach, 1)
			if criteriaType == CRITERIA_TYPE_EXPLORE_AREA then
				-- Prefer the achievement with the most criteria for a map, which
				-- is the real "Explore X" rather than a subset achievement.
				local prev = byMap[c.map]
				if not prev or (ns.Try(GetAchievementNumCriteria, prev) or 0) < num then
					byMap[c.map] = c.ach
				end
			end
		end
		return i < #candidates
	end, function()
		cache.byMap = byMap
		ns:Debug("exploration index built")
	end)
end

--------------------------------------------------------------------------
-- Finding somewhere to actually walk
--
-- Blizzard exposes no coordinates for an unexplored area, which is why these
-- entries never used to appear in the route. We can recover positions by
-- sampling a grid across the map and asking what is at each point:
--
--   * GetExploredAreaIDsAtPosition returns area ids at a coordinate. When it
--     reports an area matching an incomplete criterion, we can average those
--     points into a real centroid for that named subzone - the ideal case.
--
-- Points the client reports nothing for are ignored: unmapped ground is just
-- as often ocean or cliff face as it is unexplored, and guessing there sent
-- people somewhere they could not reach. Results are cached per map because
-- the grid costs a few hundred API calls.
--------------------------------------------------------------------------

local GRID = 22

local targetCache = {}

local function ComputeTargets(mapID, todo)
	local cached = targetCache[mapID]
	if cached then return cached end

	local byArea = {}
	for _, area in ipairs(todo) do
		if area.areaID and area.areaID > 0 then byArea[area.areaID] = area.index end
	end

	local sums = {}

	for gx = 1, GRID do
		for gy = 1, GRID do
			local x = (gx - 0.5) / GRID
			local y = (gy - 0.5) / GRID

			local ids = ns.Try(C_MapExplorationInfo.GetExploredAreaIDsAtPosition,
				mapID, CreateVector2D(x, y))

			if type(ids) == "table" and #ids > 0 then
				-- Points covered by an area we have already explored are simply
				-- dropped; only ones matching an outstanding criterion count.
				for _, areaID in ipairs(ids) do
					local index = byArea[areaID]
					if index then
						local s = sums[index]
						if not s then s = { x = 0, y = 0, n = 0 }; sums[index] = s end
						s.x, s.y, s.n = s.x + x, s.y + y, s.n + 1
					end
				end
			end
		end
	end

	local result = { precise = {} }
	for index, s in pairs(sums) do
		if s.n > 0 then
			result.precise[index] = { x = s.x / s.n, y = s.y / s.n }
		end
	end

	-- The gap-clustering fallback is deliberately NOT used any more. A point
	-- with no map overlay is just as likely to be ocean, cliff face, or dead
	-- space outside the playable zone as it is to be unexplored ground, and it
	-- sent people toward places they could not reach. A missing pin is honest;
	-- a confident pin pointing into a mountain is not. Only area-matched
	-- centroids, which sit inside a real named subzone, are used.

	targetCache[mapID] = result
	return result
end

--------------------------------------------------------------------------
-- Scan
--------------------------------------------------------------------------

function Exploration:Scan(ctx)
	local cache = CacheRoot()
	if not cache.byMap then
		self:Prepare()
		return {}
	end

	local accountScope = ns:IsAccountScope("exploration")
	local out = {}

	for mapID, achID in pairs(cache.byMap) do
		if ns.Location:InReach(mapID) then
			local achName, achPoints, achCompleted = select(2, ns.Try(GetAchievementInfo, achID))
			local num = ns.Try(GetAchievementNumCriteria, achID) or 0

			if num > 0 and not (accountScope and achCompleted) then
				-- First pass: how much of this zone is already done, so each
				-- remaining area can show meaningful zone-level progress.
				local doneCount, todo = 0, {}
				local charDone = {}

				for i = 1, num do
					local areaName, _, completed, _, _, charName, _, assetID, _, criteriaID =
						ns.Try(GetAchievementCriteriaInfo, achID, i)

					local completedByMe = completed and (not charName or charName == "" or charName == ns.playerName)
					if completed then doneCount = doneCount + 1 end
					if completedByMe then charDone[i] = true end

					local isTodo
					if accountScope then
						isTodo = not completed
					else
						isTodo = not completedByMe
					end

					if isTodo and areaName and areaName ~= "" then
						table.insert(todo, {
							index = i, name = areaName, areaID = assetID,
							criteriaID = criteriaID,
							doneByAlt = completed and not completedByMe or false,
							altName = (completed and not completedByMe) and charName or nil,
						})
					end
				end

				ns.Roster:RecordExplored(mapID, charDone)

				local zoneName = ns.Location:GetMapName(mapID)

				-- Only worth the sampling cost for maps the route can reach.
				local targets
				local _, tier = ns.Location:InReach(mapID)
				if #todo > 0 and (tier == "here" or tier == "zone") then
					targets = ns.Try(ComputeTargets, mapID, todo)
				end
				for _, area in ipairs(todo) do
					local detail = ("%s - %d of %d areas found"):format(achName or "Exploration", doneCount, num)
					if achPoints and achPoints > 0 then
						detail = ("|cffffd100%d pts|r  %s"):format(achPoints, detail)
					end
					if area.doneByAlt then
						detail = detail .. (" |cff888888(found by %s)|r"):format(area.altName or "an alt")
					end

					-- A real centroid for this named subzone, when we found one.
					local pin = targets and targets.precise and targets.precise[area.index]

					table.insert(out, {
						key       = ("explore:%d:%d"):format(achID, area.index),
						module    = "exploration",
						category  = "exploration",
						id        = achID,
						criteriaIndex = area.index,
						name      = area.name,
						icon      = "Interface\\Icons\\INV_Misc_Map_01",
						mapID     = mapID,
						x         = pin and pin.x or nil,
						y         = pin and pin.y or nil,
						zoneName  = zoneName,
						have      = doneCount,
						need      = num,
						points    = achPoints,
						detail    = detail,
						link      = ns.Try(GetAchievementLink, achID),
						typeLabel = "Unexplored",
						-- The criterion itself is stored account-wide by the
						-- game; we are filtering it to this character.
						sharedCriteria = true,
						doneByAlt = area.doneByAlt or nil,
					})
				end

			end
		end
	end

	return out
end

--------------------------------------------------------------------------
-- Cache invalidation
--
-- Sampled targets go stale the moment you walk into one of the areas, and
-- the grid is too expensive to recompute on every scan.
--------------------------------------------------------------------------

ns:RegisterEvent("CRITERIA_UPDATE", function()
	wipe(targetCache)
end)

ns:On("ZONE_CHANGED", function()
	wipe(targetCache)
end)
