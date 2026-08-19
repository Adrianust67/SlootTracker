--[[--------------------------------------------------------------------------
	Sloot Tracker - Modules/Decor.lua

	Housing decor you do not own yet.

	The catalog is not a simple list you can walk. You create a searcher, hand
	it a callback, run the search, and collect results when it calls back - so
	the first scan after login has nothing and fills in a moment later.

	Ownership is the sum of what is placed, what is in the chest, and what is
	redeemable. The client sometimes reports an unsigned sentinel instead of a
	real count, so absurd values are read as "owned" rather than risking
	listing something you already have.

	Decor entries carry an itemID, which is what makes them useful here: the
	same tooltip parsing that locates toys can locate decor, and the same
	learned vendor prices can tell you whether you can afford it.
----------------------------------------------------------------------------]]

local ADDON, ns = ...

local Decor = { key = "decor", label = "Decor", filters = { "decor" } }
ns:RegisterProvider(Decor)
ns.Decor = Decor

-- Guard: this whole API arrived with housing and does not exist on older
-- clients, so every entry point checks before touching it.
local function CatalogAvailable()
	return C_HousingCatalog ~= nil
		and C_HousingCatalog.CreateCatalogSearcher ~= nil
		and C_HousingCatalog.GetCatalogEntryInfo ~= nil
		and Enum ~= nil and Enum.HousingCatalogEntryType ~= nil
end

local searcher, results

--------------------------------------------------------------------------
-- Catalog search
--------------------------------------------------------------------------

local function EnsureSearcher()
	if searcher then return searcher end
	if not CatalogAvailable() then return nil end

	searcher = ns.Try(C_HousingCatalog.CreateCatalogSearcher)
	if not searcher then return nil end

	-- Results arrive asynchronously; stash them and ask for a rescan so the
	-- list picks them up rather than waiting for the next zone change.
	ns.Try(searcher.SetAutoUpdateOnParamChanges, searcher, false)
	ns.Try(searcher.SetResultsUpdatedCallback, searcher, function()
		results = ns.Try(searcher.GetCatalogSearchResults, searcher)
		ns:Debug(("decor catalog returned %d entries"):format(results and #results or 0))
		ns:Fire("REQUEST_SCAN", true)
	end)

	return searcher
end

function Decor:Refresh()
	local s = EnsureSearcher()
	if s then ns.Try(s.RunSearch, s) end
end

function Decor:Prepare()
	if not CatalogAvailable() then
		ns:Debug("housing catalog API not present on this client")
		return
	end
	-- Slightly delayed: the catalog is not ready the instant we log in.
	C_Timer.After(4, function() Decor:Refresh() end)
end

--------------------------------------------------------------------------
-- Ownership
--------------------------------------------------------------------------

local SENTINEL = 1000000

local function OwnedCount(info)
	local sum = (info.numPlaced or 0) + (info.quantity or 0) + (info.remainingRedeemable or 0)

	-- The client can report an unsigned sentinel (4294967295) rather than a
	-- count. Reading that as zero would list decor you already own, so an
	-- implausible number is treated as owned.
	if sum >= SENTINEL then return 1 end
	return sum
end

--------------------------------------------------------------------------
-- Scan
--------------------------------------------------------------------------

function Decor:Scan(ctx)
	if not CatalogAvailable() then return {} end
	if not results then
		self:Refresh()
		return {}
	end

	local decorType = Enum.HousingCatalogEntryType.Decor
	local out = {}

	for i = 1, #results do
		local entryID = results[i]
		local info = ns.Try(C_HousingCatalog.GetCatalogEntryInfo, entryID)

		if info and info.entryID and info.entryID.entryType == decorType
		   and OwnedCount(info) == 0 then

			local recordID = info.entryID.recordID
			local name = info.name
			local itemID = info.itemID

			if name and name ~= "" and recordID then
				-- Decor has no source field of its own, so the origin has to
				-- come from the underlying item's tooltip - the same route
				-- used for toys.
				local parsed = ns.Sources:Resolve("decor", recordID, function()
					return itemID and ns.Sources:ItemTooltipText(itemID) or nil
				end)

				if not (ns.db.collections.hideUnobtainable
				        and not ns.Sources:IsRoutable(parsed.sourceKey)) then

					local entry = {
						key       = "decor:" .. recordID,
						module    = "decor",
						category  = "decor",
						id        = recordID,
						itemID    = itemID,
						name      = name,
						icon      = info.iconTexture or "Interface\\Icons\\INV_Misc_Bag_10",
						typeLabel = "Decor",
						mapID     = parsed.mapID,
						zoneName  = parsed.zoneName,
						sourceKey = parsed.sourceKey,
						isPvP     = parsed.isPvP or nil,
						detail    = parsed.headline or parsed.sourceLabel,
					}

					if parsed.locked then
						entry.locked   = true
						entry.lockNote = parsed.lockNote
					end

					-- Priced from a vendor you have actually opened.
					if ns.Vendors then
						local price = ns.Vendors:Evaluate(itemID,
							parsed.sourceKey == "vendor" and name or nil)
						if price then
							entry.costText   = price.costText
							entry.affordable = price.affordable
							local colour = (price.affordable == true and "|cff40ff40")
								or (price.affordable == false and "|cffff8040") or "|cffaaaaaa"
							entry.detail = ("%s%s|r  %s"):format(colour, price.costText, entry.detail or "")
						end
					end

					-- Same rule as every other collectible: without a zone it
					-- cannot be routed to, so it only shows at world reach.
					if parsed.mapID
					   or (not ns.db.collections.requireZoneMatch and ns.db.reach == "world") then
						table.insert(out, entry)
					end
				end
			end
		end
	end

	return out
end

--------------------------------------------------------------------------
-- Live updates
--------------------------------------------------------------------------

ns:RegisterEvent("HOUSE_DECOR_ADDED_TO_CHEST", function()
	if not (ns.db and ns.db.autoRescan) then return end
	C_Timer.After(2, function() Decor:Refresh() end)
end)
