--[[--------------------------------------------------------------------------
	SlootTracker - Modules/Achievements.lua

	There is no API that says "which achievements belong to this zone", so we
	build that index ourselves, once per client build, and cache it:

	  1. category title matches a map name  -> every achievement in it is zoned
	  2. achievement name matches a map name
	  3. achievement description matches a map name

	It is a heuristic, and it is a good one: exploration, zone meta, dungeon
	and raid achievements all land correctly, and the misses fall back to the
	unzoned bucket rather than lying about a location.
----------------------------------------------------------------------------]]

local ADDON, ns = ...

local Achievements = { key = "achievements", label = "Achievements", filters = { "achievements" } }
ns:RegisterProvider(Achievements)

local CATEGORY_FEATS_OF_STRENGTH = 81
local CATEGORY_LEGACY            = 15234
local ACHIEVEMENT_FLAG_STATISTIC = 0x1

-- Runtime views rebuilt from the cached index.
local byZone   = nil   -- [mapID] = { achID, ... }
local unzoned  = nil   -- { achID, ... }

--------------------------------------------------------------------------
-- Index build
--------------------------------------------------------------------------

local function CacheRoot()
	ns.db.cache.ach = ns.db.cache.ach or {}
	return ns.db.cache.ach
end

local function CategoryIsUnder(categoryID, ancestorID, categoryParent)
	local guard, cur = 0, categoryID
	while cur and cur > 0 and guard < 12 do
		if cur == ancestorID then return true end
		cur = categoryParent[cur]
		guard = guard + 1
	end
	return false
end

function Achievements:BuildIndex(onDone)
	local cache = CacheRoot()
	if cache.zoneOf and cache.unzoned then
		self:RebuildViews()
		if onDone then onDone() end
		return
	end
	if ns:IsTaskRunning("ST:AchIndex") then return end

	local categories = ns.Try(GetCategoryList)
	if not categories then
		if onDone then onDone() end
		return
	end

	local categoryParent, categoryZone = {}, {}
	for _, catID in ipairs(categories) do
		local title, parentID = ns.Try(GetCategoryInfo, catID)
		categoryParent[catID] = parentID
		if title and title ~= "" then
			local mapID = ns.Location.byName[title:lower()]
			if mapID then categoryZone[catID] = mapID end
		end
	end

	-- Inherit a zone from the nearest ancestor category that has one.
	local function ResolveCategoryZone(catID)
		local guard, cur = 0, catID
		while cur and cur > 0 and guard < 12 do
			if categoryZone[cur] then return categoryZone[cur] end
			cur = categoryParent[cur]
			guard = guard + 1
		end
		return nil
	end

	local zoneOf, special, unzonedList = {}, {}, {}
	local ci = 0

	ns:RunTask("ST:AchIndex", function()
		ci = ci + 1
		local catID = categories[ci]
		if not catID then return false end

		local isFoS    = CategoryIsUnder(catID, CATEGORY_FEATS_OF_STRENGTH, categoryParent)
		local isLegacy = CategoryIsUnder(catID, CATEGORY_LEGACY, categoryParent)
		local catMap   = ResolveCategoryZone(catID)

		local count = ns.Try(GetCategoryNumAchievements, catID, true) or 0
		for i = 1, count do
			local achID, name, _, _, _, _, _, description, flags, _, _, isGuild, _, _, isStatistic =
				ns.Try(GetAchievementInfo, catID, i)

			if achID and not isGuild and not isStatistic
			   and (not flags or bit.band(flags, ACHIEVEMENT_FLAG_STATISTIC) == 0) then

				local mapID = catMap
				if not mapID and name then mapID = ns.Location:MatchZoneInText(name) end
				if not mapID and description then mapID = ns.Location:MatchZoneInText(description) end

				if mapID then zoneOf[achID] = mapID else table.insert(unzonedList, achID) end
				if isFoS then special[achID] = "fos"
				elseif isLegacy then special[achID] = "legacy" end
			end
		end

		return ci < #categories
	end, function()
		cache.zoneOf  = zoneOf
		cache.special = special
		cache.unzoned = unzonedList
		Achievements:RebuildViews()
		ns:Debug(("achievement index: %d zoned, %d unzoned"):format(
			(function() local n = 0 for _ in pairs(zoneOf) do n = n + 1 end return n end)(), #unzonedList))
		if onDone then onDone() end
	end)
end

function Achievements:RebuildViews()
	local cache = CacheRoot()
	byZone, unzoned = {}, cache.unzoned or {}
	for achID, mapID in pairs(cache.zoneOf or {}) do
		byZone[mapID] = byZone[mapID] or {}
		table.insert(byZone[mapID], achID)
	end
end

function Achievements:Prepare()
	self:BuildIndex()
end

--------------------------------------------------------------------------
-- Criteria
--------------------------------------------------------------------------

--------------------------------------------------------------------------
-- Meta-achievements
--
-- Some achievements are satisfied by other achievements (criteria type 8,
-- asset = the required achievement id). A meta sitting behind five unfinished
-- sub-achievements is not something you can act on from where you stand, so
-- it needs to say how far away it is and rank accordingly.
--
-- Prerequisites that are themselves metas contribute their own depth, so the
-- number reported is the real count of achievements still in the way, not
-- just the direct ones. Depth is capped rather than cycle-checked; the tree is
-- shallow in practice and the cap makes runaway recursion impossible.
--------------------------------------------------------------------------

local CRITERIA_TYPE_ACHIEVEMENT = 8
local META_MAX_DEPTH = 4

local metaCache = {}

-- Not every meta criterion reports type 8, which is why a second tier could go
-- unrecognised and contribute nothing to the count. Where the type does not say
-- so, confirm by resolving the asset as an achievement and matching its name
-- against the criterion text - that is exactly how the game renders these rows,
-- and it avoids false positives from the many other criteria types that also
-- carry an assetID (explore areas, items, and so on).
local function IsAchievementCriterion(criteriaType, assetID, criteriaString)
	if not assetID or assetID <= 0 then return false end
	if criteriaType == CRITERIA_TYPE_ACHIEVEMENT then return true end
	if not criteriaString or criteriaString == "" then return false end

	local name = select(2, ns.Try(GetAchievementInfo, assetID))
	return name ~= nil and name == criteriaString
end

-- Unfinished criteria on an achievement, whatever their type.
--
-- A prerequisite does not have to be a meta to hide a pile of work behind it.
-- Battle for Azeroth Pathfinder, Part One is one achievement short - but that
-- one is Azerothian Diplomat, whose criteria are reputations rather than
-- achievements. Counting only meta-in-meta would report that chain as "1 away"
-- when it is really seven pieces of work.
local function RemainingCriteria(achID)
	local num = ns.Try(GetAchievementNumCriteria, achID) or 0
	if num == 0 then return 0 end

	local remaining = 0
	for i = 1, num do
		local _, _, completed = ns.Try(GetAchievementCriteriaInfo, achID, i)
		if not completed then remaining = remaining + 1 end
	end
	return remaining
end

-- Returns isMeta, stepsAway, { descriptions of missing prerequisites }, tier
--   stepsAway = every unfinished achievement in the whole tree below this one
--   tier      = how many levels of meta are stacked up (1 = plain prerequisites,
--               2 = a prerequisite is itself a meta, and so on)
local function MetaInfo(achID, depth)
	local cached = metaCache[achID]
	if cached then return cached.isMeta, cached.steps, cached.names, cached.tier end

	depth = depth or 0
	if depth > META_MAX_DEPTH then return false, 0, nil, 0 end

	local num = ns.Try(GetAchievementNumCriteria, achID) or 0
	local isMeta, steps, names, tier = false, 0, {}, 0

	for i = 1, num do
		local criteriaString, criteriaType, completed, _, _, _, _, assetID =
			ns.Try(GetAchievementCriteriaInfo, achID, i)

		if IsAchievementCriterion(criteriaType, assetID, criteriaString) then
			isMeta = true
			if not completed then
				steps = steps + 1

				-- One call: results below depth 0 are not memoised, so asking
				-- twice would recompute the entire subtree.
				local subIsMeta, subSteps, _, subTier = MetaInfo(assetID, depth + 1)
				subTier = subTier or 0

				-- Work hidden below this prerequisite, whichever form it takes.
				local hidden, thisTier = 0, 1
				if subIsMeta and subSteps > 0 then
					hidden = subSteps
					thisTier = 1 + math.max(1, subTier)
				else
					-- Not a meta, but its own unfinished criteria are still
					-- things you have to go and do first.
					hidden = RemainingCriteria(assetID)
					if hidden > 0 then thisTier = 2 end
				end

				steps = steps + hidden
				if thisTier > tier then tier = thisTier end

				if #names < 3 then
					local subName = select(2, ns.Try(GetAchievementInfo, assetID))
						or criteriaString or ("#" .. assetID)
					if hidden > 0 then
						subName = ("%s |cff888888(+%d behind it)|r"):format(subName, hidden)
					end
					table.insert(names, subName)
				end
			end
		end
	end

	if depth == 0 then
		metaCache[achID] = { isMeta = isMeta, steps = steps, names = names, tier = tier }
	end
	return isMeta, steps, names, tier
end

function Achievements:ClearMetaCache()
	wipe(metaCache)
end

-- Returns have, need, { missing criteria strings }
local function CriteriaProgress(achID, wantStrings)
	local num = ns.Try(GetAchievementNumCriteria, achID) or 0
	if num == 0 then return nil, nil, nil end

	local done, missing = 0, wantStrings and {} or nil
	for i = 1, num do
		local criteriaString, _, completed, quantity, reqQuantity = ns.Try(GetAchievementCriteriaInfo, achID, i)
		if completed then
			done = done + 1
		elseif missing and #missing < 4 then
			local text = criteriaString
			if (not text or text == "") and reqQuantity and reqQuantity > 0 then
				text = ("%d / %d"):format(quantity or 0, reqQuantity)
			elseif text and reqQuantity and reqQuantity > 1 and quantity then
				text = ("%s (%d/%d)"):format(text, quantity, reqQuantity)
			end
			if text and text ~= "" then table.insert(missing, text) end
		end
	end
	return done, num, missing
end

--------------------------------------------------------------------------
-- Scan
--------------------------------------------------------------------------

local function ShouldSkip(achID, completed, wasEarnedByMe)
	local cfg = ns.db.achievements
	local special = CacheRoot().special and CacheRoot().special[achID]

	if cfg.hideFeatsOfStrength and special == "fos" then return true end
	if cfg.hideLegacy and special == "legacy" then return true end

	if ns:IsAccountScope("achievements") then
		-- Achievement credit is account-wide; if the account has it, it is done.
		return completed
	end

	-- Character scope.
	if completed then
		-- Earned by an alt but not by this character. Only interesting if the
		-- player explicitly asked to chase personal credit.
		if wasEarnedByMe then return true end
		return not cfg.includeEarnedByAlts
	end
	return false
end

local function BuildEntry(achID)
	local id, name, points, completed, _, _, _, description, _, icon, _, _, wasEarnedByMe =
		ns.Try(GetAchievementInfo, achID)
	if not id or not name then return nil end
	if ShouldSkip(achID, completed, wasEarnedByMe) then return nil end

	local cfg = ns.db.achievements
	local have, need, missing = CriteriaProgress(achID, cfg.showCriteria)
	local progress = (have and need and need > 0) and (have / need) or 0

	if cfg.onlyNearlyDone and progress < (cfg.nearlyDoneThreshold or 0) then
		return nil
	end

	-- How far away is this, really?
	local isMeta, steps, blockers, metaTier = MetaInfo(achID)
	local stepsAway = isMeta and steps
		or (have and need and (need - have)) or nil

	local maxSteps = cfg.maxSteps or 0
	if maxSteps > 0 and stepsAway and stepsAway > maxSteps then
		return nil
	end

	local detail
	if isMeta and steps > 0 then
		-- A meta behind other achievements is the case where "Missing: ..."
		-- criteria text is useless; what matters is how many are in the way.
		local tierNote = (metaTier and metaTier > 1)
			and (" |cffff8040(%d tiers deep)|r"):format(metaTier) or ""
		detail = ("|cffff8040%d achievement%s away|r%s - %s"):format(
			steps, steps == 1 and "" or "s", tierNote,
			blockers and #blockers > 0 and table.concat(blockers, ", ") or "prerequisites unfinished")
	elseif missing and #missing > 0 then
		detail = "Missing: " .. table.concat(missing, ", ")
	elseif description and description ~= "" then
		detail = description
	end
	if points and points > 0 then
		detail = ("|cffffd100%d pts|r  %s"):format(points, detail or "")
	end

	local mapID = CacheRoot().zoneOf and CacheRoot().zoneOf[achID] or nil

	return {
		key       = "ach:" .. achID,
		module    = "achievements",
		category  = "achievements",
		id        = achID,
		name      = name,
		icon      = icon,
		points    = points,
		mapID     = mapID,
		have      = have,
		need      = need,
		progress  = progress,
		detail    = detail,
		missing   = missing,
		isMeta        = isMeta or nil,
		metaRemaining = (isMeta and steps > 0) and steps or nil,
		metaTier      = (isMeta and steps > 0) and metaTier or nil,
		stepsAway     = stepsAway,
		earnedByAlt = completed and not wasEarnedByMe or nil,
		link      = ns.Try(GetAchievementLink, achID),
		trackType = Enum and Enum.ContentTrackingType and Enum.ContentTrackingType.Achievement or nil,
		typeLabel = "Achievement",
	}
end

function Achievements:Scan(ctx)
	if not byZone then
		self:BuildIndex()
		return {}
	end

	local out = {}
	local seen = {}

	for mapID, list in pairs(byZone) do
		if ns.Location:InReach(mapID) then
			for _, achID in ipairs(list) do
				if not seen[achID] then
					seen[achID] = true
					local entry = BuildEntry(achID)
					if entry then table.insert(out, entry) end
				end
			end
		end
	end

	-- Unzoned achievements are only worth surfacing when the player has
	-- explicitly widened the search to the whole world.
	if ns.db.reach == "world" and unzoned then
		for _, achID in ipairs(unzoned) do
			if not seen[achID] then
				seen[achID] = true
				local entry = BuildEntry(achID)
				if entry then table.insert(out, entry) end
			end
		end
	end

	return out
end

--------------------------------------------------------------------------
-- Live updates
--------------------------------------------------------------------------

ns:RegisterEvent("ACHIEVEMENT_EARNED", function()
	Achievements:ClearMetaCache()
	C_Timer.After(2, function() ns:Fire("REQUEST_SCAN", true) end)
end)

ns:RegisterEvent("CRITERIA_UPDATE", function()
	Achievements:ClearMetaCache()
	if ns.db and ns.db.autoRescan then
		C_Timer.After(5, function() ns:Fire("REQUEST_SCAN") end)
	end
end)
