--[[--------------------------------------------------------------------------
	SlootTracker - Core/Priority.lua

	Orchestrates the scan, scores every entry, and plans a route.

	Scoring is deliberately explainable: each entry keeps the factors that
	produced its score so the tooltip can justify the ranking instead of
	handing the player an opaque number.

	    score = weight x proximity x precision x progress x urgency x points

	Proximity dominates, because the whole point is "what can I finish from
	where I am standing".
----------------------------------------------------------------------------]]

local ADDON, ns = ...

local Priority = {}
ns.Priority = Priority

Priority.entries = {}       -- scored + sorted
Priority.route   = {}       -- ordered subset with coordinates in the current zone
Priority.stats   = {}       -- per-category counts for the footer
Priority.lastScan = 0
Priority.scanning = false

--------------------------------------------------------------------------
-- Scoring
--------------------------------------------------------------------------

local TIER_MULT = {
	here      = 3.0,
	zone      = 2.2,
	continent = 0.8,
	world     = 0.25,
}

-- Distance falloff inside the current zone. 0 yards -> 1.6x, 600+ yards -> 1.0x.
local NEAR_YARDS = 800
-- Zone-to-zone distances are an order of magnitude larger than in-zone ones.
local FAR_YARDS  = 6000

-- How much we actually know about where to go.
--
-- This is the difference between "there is a chest at 42.1, 63.8" and "this is
-- somewhere in Duskwood". The second is not an opportunity you can act on; it
-- is a reminder. The whole point of the addon is spotting things that are
-- close and cheap, so a lead you cannot walk to has to rank far below one you
-- can, even when the vague one is nominally nearer.
local function PrecisionFactor(entry)
	if entry.x and entry.y then return 1.0 end

	-- No fixed spot means the best we can offer is the middle of a zone, which
	-- is not a lead - it is a note saying "something is somewhere around here".
	-- The addon exists to surface what you missed for the least effort, and
	-- effort starts with knowing where to walk. These sink hard.
	return 0.12
end

local function ProximityFactor(entry)
	local tier = entry.tier or "world"
	local mult = TIER_MULT[tier] or 0.25

	if entry.x and entry.distance and (tier == "here" or tier == "zone") then
		-- Steeper than it was, and over a longer range: something 50 yards away
		-- should clearly beat the same thing 700 yards away.
		local d = math.max(0, math.min(entry.distance, NEAR_YARDS))
		mult = mult * (2.2 - 1.5 * (d / NEAR_YARDS))
	elseif (tier == "here" or tier == "zone") and not entry.x then
		-- In the right zone but we cannot pin it down. PrecisionFactor already
		-- discounts this heavily; no need to punish it twice.
		mult = mult * 1.0
	elseif tier == "continent" and entry.distance then
		-- Everything on this continent used to score identically. A zone two
		-- flights away should beat one on the far side of the map, so the
		-- approximate zone distance is allowed to separate them.
		local d = math.max(0, math.min(entry.distance, FAR_YARDS))
		mult = mult * (1.5 - 0.8 * (d / FAR_YARDS))
	end
	return mult
end

local function ProgressFactor(entry)
	local p = entry.progress
	if not p or p <= 0 then return 1.0 end

	local factor = 1.0 + 1.2 * p
	-- "One criterion left" is worth far more than the raw ratio suggests.
	if entry.need and entry.have and (entry.need - entry.have) == 1 then
		factor = factor + 0.8
	end
	return factor
end

-- Achievement score is the stated goal, so points matter - but raw points are
-- the wrong metric. A 10-point achievement one criterion from done beats a
-- 25-point one needing forty more kills, so this ranks on points earned per
-- remaining step.
local function PointsFactor(entry)
	if not ns.db.achievements.prioritiseByPoints then return 1.0 end

	local points = entry.points
	if not points or points <= 0 then return 1.0 end

	local steps = 1
	if entry.need and entry.have then
		steps = math.max(1, entry.need - entry.have)
	end

	entry.pointsPerStep = points / steps

	-- 25 points per remaining step saturates the bonus at roughly 2.2x.
	local weight = ns.db.achievements.pointsWeight or 1.0
	return 1.0 + math.min(entry.pointsPerStep / 25, 1.2) * weight
end

local function UrgencyFactor(entry)
	-- Bonuses first, then gates. Applying a penalty before the additive terms
	-- let a bonus quietly undo it, which defeated the point of the penalty.
	local f = 1.0
	if entry.isRare then f = f + 0.5 end   -- up right now
	if entry.timeLeft and entry.timeLeft > 0 and entry.timeLeft < 3600 then
		f = f + 0.6                        -- about to despawn
	end

	-- Something you can buy right now is about as actionable as content gets,
	-- so it is promoted; something priced beyond your purse is not, so it
	-- drops. A price we never learned leaves affordable as nil and changes
	-- nothing - unknown is not the same as unaffordable.
	if entry.affordable == true then
		f = f * 1.6
	elseif entry.affordable == false then
		f = f * 0.35
	end

	-- Behind a key, lockbox or attunement: still worth listing, but it must not
	-- outrank something you can simply walk over to. Much lighter when we could
	-- confirm the key is actually in your bags.
	if entry.locked then
		f = f * (entry.haveKey and 0.75 or 0.3)
	end

	-- A meta-achievement gated behind other unfinished achievements cannot be
	-- acted on from here at all, however near it nominally is.
	--
	-- Count alone is not enough. "One achievement away" reads as nearly done,
	-- but if that one achievement is itself a meta with six of its own, the
	-- real distance is far greater and the shape of the work is different -
	-- you cannot finish any of it in one sitting. So stacked tiers are
	-- penalised on top of the raw count.
	if entry.metaRemaining and entry.metaRemaining > 0 then
		local tier = entry.metaTier or 1
		f = f / (1 + entry.metaRemaining * 0.9 + math.max(0, tier - 1) * 2.0)
	end

	return f
end

function Priority:Score(entry)
	local weightKey = entry.category or entry.module
	local weight = (ns.db.weights[weightKey] or ns.db.weights[entry.module] or 1.0)

	local prox   = ProximityFactor(entry)
	local prec   = PrecisionFactor(entry)
	local prog   = ProgressFactor(entry)
	local urg    = UrgencyFactor(entry)
	local points = PointsFactor(entry)

	entry.scoreParts = {
		weight = weight, proximity = prox, precision = prec, progress = prog,
		urgency = urg, points = points,
	}
	entry.score = weight * prox * prec * prog * urg * points * 100
	return entry.score
end

--------------------------------------------------------------------------
-- Context handed to every provider
--------------------------------------------------------------------------

function Priority:BuildContext()
	local loc = ns.Location:Get()
	return {
		mapID       = loc.mapID,
		x           = loc.x,
		y           = loc.y,
		continentID = loc.continentID,
		zoneName    = loc.zoneName,
		subZone     = loc.subZone,
		-- Scope is deliberately not in here: it varies per category, so
		-- modules call ns:ScopeFor(category) rather than trusting one value.
		reach       = ns.db.reach,
		playerLevel = UnitLevel("player"),
		faction     = ns.playerFaction,
	}
end

--------------------------------------------------------------------------
-- Post-processing shared by every provider's output
--------------------------------------------------------------------------

local function Finalise(entry)
	-- One place decides, so every content type obeys the same switch.
	if entry.isPvP and not ns.db.includePvP then return false end

	-- Nothing to walk to, and the player asked not to be shown those at all.
	if ns.db.requireExactLocation and not (entry.x and entry.y) then return false end

	-- Reach / tier
	local inReach, tier = ns.Location:InReach(entry.mapID)
	entry.tier = tier

	if entry.mapID and not inReach then return false end

	-- Entries with no location at all only show at world reach.
	if not entry.mapID then
		if ns.db.reach ~= "world" then return false end
		entry.tier = "world"
	end

	if entry.x and entry.y and entry.mapID then
		entry.distance = ns.Location:DistanceToPlayer(entry.mapID, entry.x, entry.y)
	elseif entry.mapID then
		-- No exact spot, but we know the zone. A rough distance is far more
		-- use than a blank column when deciding where to go next.
		entry.distance = ns.Location:DistanceToZone(entry.mapID)
		entry.approximateDistance = entry.distance ~= nil or nil
	end

	if entry.have and entry.need and entry.need > 0 then
		entry.progress = entry.have / entry.need
	end

	entry.zoneName = entry.zoneName or (entry.mapID and ns.Location:GetMapName(entry.mapID)) or nil
	return true
end

--------------------------------------------------------------------------
-- Scan
--------------------------------------------------------------------------

local function SortEntries(a, b)
	if a.score ~= b.score then return a.score > b.score end
	return (a.name or "") < (b.name or "")
end

function Priority:Scan(force)
	if self.scanning then return end
	if not force and (GetTime() - self.lastScan) < 1.0 then return end

	self.scanning = true
	local ctx = self:BuildContext()

	if not ctx.mapID then
		self.scanning = false
		ns:Debug("scan aborted: no map for player")
		return
	end

	local collected = {}
	local stats = {}
	local pointsAvailable = 0
	local countedAchievements = {}

	-- Providers are run one per frame chunk; some of them are heavy.
	local order = {}
	for _, key in ipairs(ns.providerOrder) do
		local p = ns.providers[key]
		if p and ns:ProviderEnabled(p) then table.insert(order, p) end
	end

	local index = 0
	ns:RunTask("Priority:Scan", function()
		index = index + 1
		local provider = order[index]
		if not provider then return false end

		local results = ns.Try(provider.Scan, provider, ctx)
		if type(results) == "table" then
			local kept = 0
			for _, entry in ipairs(results) do
				entry.module = entry.module or provider.key
				if Finalise(entry) then
					Priority:Score(entry)
					table.insert(collected, entry)
					kept = kept + 1
					local k = entry.category or entry.module
					stats[k] = (stats[k] or 0) + 1

					-- Sum points on offer, counting each achievement once even
					-- though exploration emits one row per missing subzone.
					if entry.points and entry.points > 0 and entry.id
					   and not countedAchievements[entry.id] then
						countedAchievements[entry.id] = true
						pointsAvailable = pointsAvailable + entry.points
					end
				end
			end
			ns:Debug(("provider %s -> %d/%d entries"):format(provider.key, kept, #results))
		end
		return index < #order
	end, function()
		table.sort(collected, SortEntries)

		local maxRows = ns.db.maxRows or 300
		if #collected > maxRows then
			for i = #collected, maxRows + 1, -1 do collected[i] = nil end
		end

		Priority.entries  = collected
		Priority.stats    = stats
		Priority.pointsAvailable = pointsAvailable
		Priority.lastScan = GetTime()
		Priority.scanning = false
		Priority:BuildRoute()
		ns:Fire("SCAN_COMPLETE", collected)
	end)
end

--------------------------------------------------------------------------
-- Route planning
--
-- Nearest-neighbour over everything in the current zone that has coordinates.
-- Not optimal, but for 8 stops in one zone the difference against an exact
-- solve is noise, and it recomputes instantly as the player moves.
--------------------------------------------------------------------------

function Priority:BuildRoute()
	wipe(self.route)

	-- Entry tables persist across rebuilds, so last pass's step numbers have
	-- to be cleared or dropped stops keep rendering a stale "#3".
	for _, entry in ipairs(self.entries) do
		entry.routeStep = nil
		entry.routeDistance = nil
	end

	if not ns.db.route.enabled then return end

	local loc = ns.Location:Get()
	if not (loc.mapID and loc.x and loc.y) then return end

	local pool = {}
	for _, entry in ipairs(self.entries) do
		if entry.x and entry.y and entry.mapID
		   and (entry.tier == "here" or entry.tier == "zone") then
			table.insert(pool, entry)
		end
	end
	if #pool == 0 then return end

	-- Weight the greedy choice by score as well as distance, so a high-value
	-- stop 200 yards away beats a throwaway one 60 yards away.
	local curMap, curX, curY = loc.mapID, loc.x, loc.y
	local limit = math.min(ns.db.route.size or 8, #pool)

	for _ = 1, limit do
		local best, bestCost, bestIdx
		for i, entry in ipairs(pool) do
			if not entry.__routed then
				local d = ns.Location:Distance(curMap, curX, curY, entry.mapID, entry.x, entry.y) or 99999
				local cost = d / math.max(entry.score / 100, 0.1)
				if not bestCost or cost < bestCost then
					best, bestCost, bestIdx = entry, cost, i
				end
			end
		end
		if not best then break end
		best.__routed = true
		best.routeStep = #self.route + 1
		best.routeDistance = ns.Location:Distance(curMap, curX, curY, best.mapID, best.x, best.y)
		table.insert(self.route, best)
		curMap, curX, curY = best.mapID, best.x, best.y
	end

	for _, entry in ipairs(pool) do entry.__routed = nil end

	if ns.db.route.autoPoint and self.route[1] then
		local first = self.route[1]
		ns.Location:SetWaypoint(first.mapID, first.x, first.y, first.name)
	end
end

function Priority:PrintRoute()
	if #self.route == 0 then
		ns:Print("no routable objectives with coordinates in this zone.")
		return
	end
	ns:Print(("route for %s:"):format(ns.Location:Get().zoneName or "?"))
	local total = 0
	for i, entry in ipairs(self.route) do
		total = total + (entry.routeDistance or 0)
		print(("  |cffffd100%d.|r %s  |cff888888(%.1f, %.1f - %d yd)|r"):format(
			i, entry.name or "?", (entry.x or 0) * 100, (entry.y or 0) * 100, entry.routeDistance or 0))
	end
	print(("  |cff888888total travel: %d yards|r"):format(total))
end

--------------------------------------------------------------------------
-- Wiring
--------------------------------------------------------------------------

ns:On("PROVIDERS_PREPARED", function() Priority:Scan(true) end)
ns:On("REQUEST_SCAN", function(force) Priority:Scan(force) end)
ns:On("PRINT_ROUTE", function() Priority:PrintRoute() end)

ns:On("ZONE_CHANGED", function()
	if ns.db and ns.db.autoRescan then
		C_Timer.After(1.5, function() Priority:Scan(true) end)
	end
end)

-- Distances and the route go stale as the player moves; refresh them cheaply
-- without re-running every provider.
local tick = 0
ns:On("POSITION_TICK", function()
	tick = tick + 1
	if tick % 3 ~= 0 then return end
	if Priority.scanning or #Priority.entries == 0 then return end

	local dirty = false
	for _, entry in ipairs(Priority.entries) do
		if entry.x and entry.y and entry.mapID then
			local d = ns.Location:DistanceToPlayer(entry.mapID, entry.x, entry.y)
			if d ~= entry.distance then
				entry.distance = d
				dirty = true
			end
		end
	end
	if dirty then
		for _, entry in ipairs(Priority.entries) do Priority:Score(entry) end
		table.sort(Priority.entries, SortEntries)
		Priority:BuildRoute()
		ns:Fire("ENTRIES_REFRESHED")
	end
end)
