--[[--------------------------------------------------------------------------
	ZoneComplete - Modules/Exploration.lua

	Unexplored subzones, pulled from the "Explore <Zone>" achievements, whose
	criteria are one-per-subzone (criteria type 43, asset = areaID).

	These criteria are account-wide in retail, but each one records WHICH
	character satisfied it - so character scope can still tell you which
	corners of the map this particular character has never walked into.

	Blizzard exposes no coordinates for an unexplored area, so these entries
	carry a zone but no pin. They rank by zone, not by yards.
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
	if ns:IsTaskRunning("ZC:ExploreIndex") then return end

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
	ns:RunTask("ZC:ExploreIndex", function()
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
				for _, area in ipairs(todo) do
					local detail = ("%s - %d of %d areas found"):format(achName or "Exploration", doneCount, num)
					if achPoints and achPoints > 0 then
						detail = ("|cffffd100%d pts|r  %s"):format(achPoints, detail)
					end
					if area.doneByAlt then
						detail = detail .. (" |cff888888(found by %s)|r"):format(area.altName or "an alt")
					end

					table.insert(out, {
						key       = ("explore:%d:%d"):format(achID, area.index),
						module    = "exploration",
						category  = "exploration",
						id        = achID,
						criteriaIndex = area.index,
						name      = area.name,
						icon      = "Interface\\Icons\\INV_Misc_Map_01",
						mapID     = mapID,
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
