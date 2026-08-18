--[[--------------------------------------------------------------------------
	Sloot Tracker - Modules/Vendors.lua

	"Can I actually afford this?"

	There is no API that reports what an arbitrary vendor charges. Prices exist
	only while a merchant window is open, so this module learns them: every time
	you open a vendor it records what is on offer and what it costs, and keeps
	that in the saved variables. From then on, anything sold by a vendor you
	have visited can be checked against your gold and currencies.

	The consequence is worth stating plainly: a mount from a vendor you have
	never opened has no known price, and gets no opinion either way. It is not
	treated as unaffordable - it is treated as unknown, which is the truth.

	Costs come in three forms and all three are handled: copper, currencies
	(Trader's Tender, Timewarped Badges and the like), and items used as
	currency.
----------------------------------------------------------------------------]]

local ADDON, ns = ...

local Vendors = {}
ns.Vendors = Vendors

--------------------------------------------------------------------------
-- Storage
--------------------------------------------------------------------------

-- prices[itemID]      = record
-- byName[lowercase]   = itemID     (mounts know their name, not their item id)
local function PriceStore()
	ns.db.cache.prices = ns.db.cache.prices or { byID = {}, byName = {} }
	local store = ns.db.cache.prices
	store.byID   = store.byID or {}
	store.byName = store.byName or {}
	return store
end

--------------------------------------------------------------------------
-- Learning prices from an open merchant
--------------------------------------------------------------------------

local function IDFromLink(link)
	if not link then return nil end
	local currency = link:match("|Hcurrency:(%d+)")
	if currency then return "currency", tonumber(currency) end
	local item = link:match("|Hitem:(%d+)")
	if item then return "item", tonumber(item) end
	return nil
end

function Vendors:CaptureMerchant()
	local count = ns.Try(GetMerchantNumItems) or 0
	if count == 0 then return end

	local store = PriceStore()
	local learned = 0

	for index = 1, count do
		local name, _, price, _, _, isPurchasable = ns.Try(GetMerchantItemInfo, index)
		local link = ns.Try(GetMerchantItemLink, index)
		local kind, itemID = IDFromLink(link)

		if name and itemID and kind == "item" and isPurchasable ~= false then
			local record = { money = price or 0, costs = nil }

			-- Extended costs: currencies or items handed over alongside gold.
			local numCosts = ns.Try(GetMerchantItemCostInfo, index) or 0
			if numCosts > 0 then
				record.costs = {}
				for c = 1, numCosts do
					local _, value, costLink, costName = ns.Try(GetMerchantItemCostItem, index, c)
					local costKind, costID = IDFromLink(costLink)
					if value and value > 0 then
						table.insert(record.costs, {
							kind = costKind or "unknown",
							id = costID,
							amount = value,
							name = costName,
						})
					end
				end
				if #record.costs == 0 then record.costs = nil end
			end

			store.byID[itemID] = record
			store.byName[name:lower()] = itemID
			learned = learned + 1
		end
	end

	if learned > 0 then
		ns:Debug(("learned prices for %d vendor items"):format(learned))
	end
end

--------------------------------------------------------------------------
-- Lookup
--------------------------------------------------------------------------

-- Mounts are named for the creature ("Swift Zhevra") while the item that
-- teaches them is not ("Reins of the Swift Zhevra"), so an exact name match is
-- not enough. A containment match is, and it is only ever consulted when there
-- is no item id to match on directly.
local function FindByName(store, name)
	if not name or name == "" then return nil end
	local lower = name:lower()

	local exact = store.byName[lower]
	if exact then return exact end

	for merchantName, itemID in pairs(store.byName) do
		if merchantName:find(lower, 1, true) then return itemID end
	end
	return nil
end

function Vendors:PriceFor(itemID, name)
	local store = PriceStore()

	local record = itemID and store.byID[itemID]
	if not record then
		local found = FindByName(store, name)
		record = found and store.byID[found] or nil
	end
	return record
end

--------------------------------------------------------------------------
-- Affordability
--------------------------------------------------------------------------

local function HeldAmount(cost)
	if cost.kind == "currency" and cost.id then
		local info = ns.Try(C_CurrencyInfo.GetCurrencyInfo, cost.id)
		return info and info.quantity or 0
	elseif cost.kind == "item" and cost.id then
		return ns.Try(C_Item and C_Item.GetItemCount or GetItemCount, cost.id) or 0
	end
	return nil   -- cannot tell
end

-- Returns affordable (true/false/nil when undeterminable), and a cost string.
function Vendors:CanAfford(record)
	if not record then return nil, nil end

	local parts, affordable = {}, true
	local unknown = false

	if record.money and record.money > 0 then
		local text = ns.Try(GetCoinTextureString, record.money) or (record.money .. "c")
		table.insert(parts, text)
		if (ns.Try(GetMoney) or 0) < record.money then affordable = false end
	end

	for _, cost in ipairs(record.costs or {}) do
		local held = HeldAmount(cost)
		local label = cost.name or "?"
		table.insert(parts, ("%d %s"):format(cost.amount, label))
		if held == nil then
			unknown = true
		elseif held < cost.amount then
			affordable = false
		end
	end

	if #parts == 0 then return nil, nil end
	-- A cost we could not evaluate must not be reported as affordable.
	if unknown and affordable then return nil, table.concat(parts, " + ") end
	return affordable, table.concat(parts, " + ")
end

-- Convenience used by the content modules.
function Vendors:Evaluate(itemID, name)
	local record = self:PriceFor(itemID, name)
	if not record then return nil end

	local affordable, costText = self:CanAfford(record)
	if not costText then return nil end
	return { affordable = affordable, costText = costText }
end

function Vendors:Forget()
	ns.db.cache.prices = { byID = {}, byName = {} }
end

--------------------------------------------------------------------------
-- Wiring
--------------------------------------------------------------------------

ns:RegisterEvent("MERCHANT_SHOW", function()
	Vendors:CaptureMerchant()
end)

-- Stock and costs can change while the window is open (currency tabs, etc).
ns:RegisterEvent("MERCHANT_UPDATE", function()
	if MerchantFrame and MerchantFrame:IsShown() then
		Vendors:CaptureMerchant()
	end
end)

-- Affordability changes as you earn and spend, so refresh the ranking.
local pending = false
local function Bump()
	if pending or not (ns.db and ns.db.autoRescan) then return end
	pending = true
	C_Timer.After(5, function()
		pending = false
		ns:Fire("REQUEST_SCAN", true)
	end)
end

ns:RegisterEvent("PLAYER_MONEY", Bump)
ns:RegisterEvent("CURRENCY_DISPLAY_UPDATE", Bump)
