--[[--------------------------------------------------------------------------
	Sloot Tracker - Integrations/EllesmereUI.lua

	Registers the tracker window with EllesmereUI's Unlock Mode, so it can be
	dragged, snapped and resized alongside every other EllesmereUI element
	instead of being the one panel you have to position by hand.

	EllesmereUI exposes this deliberately - EUI_UnlockMode.lua states that
	"elements from any addon register via EllesmereUI:RegisterUnlockElements()"
	- so this is a supported API, not a hook into internals. It is still
	entirely optional: every call is guarded, and if EllesmereUI is absent or
	its API changes shape, the addon carries on with its own drag and resize.

	Position and size are read from and written to ns.db.window, the same table
	the window's own drag handler uses. One source of truth, so the two systems
	cannot disagree about where the window is.
----------------------------------------------------------------------------]]

local ADDON, ns = ...

local KEY      = "SlootTracker_Main"
local MIN_W    = 420    -- must match the frame's SetResizeBounds
local MIN_H    = 240

local Integration = {}
ns.EllesmereIntegration = Integration

local registered = false
local restoreAfterUnlock = nil

--------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------

local function EUI()
	local eui = _G.EllesmereUI
	if type(eui) ~= "table" then return nil end
	if not eui.RegisterUnlockElements or not eui.MakeUnlockElement then return nil end
	return eui
end

local function Frame()
	return ns.UI and ns.UI:GetFrame() or nil
end

-- EllesmereUI snaps to physical pixels; borrow its helper when present.
local function Snap(value)
	local eui = _G.EllesmereUI
	local pp = eui and eui.PP
	if pp and pp.Snap then
		local ok, snapped = pcall(pp.Snap, value)
		if ok and snapped then return snapped end
	end
	return math.floor(value + 0.5)
end

--------------------------------------------------------------------------
-- Registration
--------------------------------------------------------------------------

function Integration:Register()
	if registered then return true end

	local eui = EUI()
	if not eui then return false end
	if not Frame() then return false end

	local MK = eui.MakeUnlockElement

	local element = MK({
		key   = KEY,
		label = "Sloot Tracker",
		group = "Sloot Tracker",
		order = 900,

		getFrame = function() return Frame() end,

		getSize = function()
			local f = Frame()
			if f then return f:GetWidth(), f:GetHeight() end
			return ns.db.window.width or 820, ns.db.window.height or 560
		end,

		setWidth = function(_, newW)
			local f = Frame()
			if not f then return end
			local v = Snap(math.max(MIN_W, newW or MIN_W))
			f:SetWidth(v)
			-- OnSizeChanged persists it and relays out the rows.
		end,

		setHeight = function(_, newH)
			local f = Frame()
			if not f then return end
			local v = Snap(math.max(MIN_H, newH or MIN_H))
			f:SetHeight(v)
		end,

		savePos = function(_, point, relPoint, x, y)
			local w = ns.db.window
			w.point    = point
			w.relPoint = relPoint or point
			w.x, w.y   = x, y
		end,

		loadPos = function()
			local w = ns.db.window
			if not w.point then return nil end
			-- Return a copy; the caller may hold or rebase this table and must
			-- never mutate our stored position through it.
			return { point = w.point, relPoint = w.relPoint or w.point, x = w.x or 0, y = w.y or 0 }
		end,

		clearPos = function()
			local w = ns.db.window
			w.point, w.relPoint, w.x, w.y = "CENTER", "CENTER", 0, 0
			if ns.UI then ns.UI:ApplyStoredPosition() end
		end,

		applyPos = function()
			if ns.UI then ns.UI:ApplyStoredPosition() end
		end,

		isHidden = function()
			local f = Frame()
			return not (f and f:IsShown())
		end,
	})

	local ok = pcall(eui.RegisterUnlockElements, eui, { element }, ADDON)
	if not ok then return false end

	registered = true
	ns:Debug("registered with EllesmereUI unlock mode")

	--------------------------------------------------------------------
	-- Unlock-mode listener
	--
	-- You cannot drag or size a window you cannot see, so the tracker is
	-- shown for the duration of an unlock session and put back afterwards
	-- if it was closed to begin with.
	--------------------------------------------------------------------
	if eui.RegisterUnlockModeListener then
		pcall(eui.RegisterUnlockModeListener, eui, ADDON, function(active)
			local f = Frame()
			if not f then return end

			if active then
				if not f:IsShown() then
					restoreAfterUnlock = true
					f:Show()
				end
			elseif restoreAfterUnlock then
				restoreAfterUnlock = nil
				f:Hide()
			end
		end)
	end

	return true
end

--------------------------------------------------------------------------
-- Wiring
--
-- EllesmereUI is listed in OptionalDeps so it loads first when installed,
-- but its unlock module builds itself across several files and a couple of
-- events. Retry a bounded number of times rather than assuming readiness.
--------------------------------------------------------------------------

ns:On("PLAYER_READY", function()
	if not _G.EllesmereUI then return end

	local attempts = 0
	local function Attempt()
		attempts = attempts + 1
		if Integration:Register() then return end
		if attempts < 10 then
			C_Timer.After(2, Attempt)
		else
			ns:Debug("EllesmereUI present but unlock API never became available")
		end
	end
	C_Timer.After(2, Attempt)
end)
