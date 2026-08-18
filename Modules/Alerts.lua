--[[--------------------------------------------------------------------------
	SlootTracker - Modules/Alerts.lua

	Tells you when the zone you just walked into still has quests in it.

	The low-level switch decides what counts, mirroring quests.includeTrivial:
	  includeLowLevel = true  - every unaccepted or unfinished quest here,
	                            including the ones you have outlevelled (which
	                            quietly stop showing on your map and get
	                            forgotten); the alert says how many are low-level
	  includeLowLevel = false - level-appropriate quests only

	Alerts are throttled per zone so flying over a continent does not spam you,
	and they never fire in combat or during an instance load.
----------------------------------------------------------------------------]]

local ADDON, ns = ...

local Alerts = {}
ns.Alerts = Alerts

local lastAlertAt = {}   -- [mapID] = GetTime()
local banner

--------------------------------------------------------------------------
-- Decide whether this zone is worth interrupting the player for
--------------------------------------------------------------------------

-- Returns count, headline, survey  (count == 0 means stay quiet)
function Alerts:Evaluate(mapID)
	local cfg = ns.db.alerts
	if not (ns.Quests and ns.Quests.SurveyZone) then return 0 end

	local survey = ns.Quests:SurveyZone(mapID, UnitLevel("player"))

	-- The low-level switch: alert about everything, or drop the quests this
	-- character has outlevelled.
	local unaccepted, unfinished
	if cfg.includeLowLevel then
		unaccepted = survey.unaccepted
		unfinished = survey.unfinished
	else
		unaccepted = survey.unaccepted - survey.unacceptedTrivial
		unfinished = survey.unfinished - survey.unfinishedTrivial
	end

	if not cfg.unaccepted then unaccepted = 0 end
	if not cfg.unfinished then unfinished = 0 end

	local count = unaccepted + unfinished
	if count == 0 then return 0, nil, survey end

	local parts = {}
	if unaccepted > 0 then
		table.insert(parts, ("%d to pick up"):format(unaccepted))
	end
	if unfinished > 0 then
		table.insert(parts, ("%d unfinished"):format(unfinished))
	end
	if survey.readyForTurnIn > 0 then
		table.insert(parts, ("|cff40ff40%d ready to turn in|r"):format(survey.readyForTurnIn))
	end

	-- When we are counting everything, call out how much of it is low-level,
	-- since that is the part the player has usually stopped seeing.
	local qualifier = ""
	if cfg.includeLowLevel then
		local lowLevel = 0
		if cfg.unaccepted then lowLevel = lowLevel + survey.unacceptedTrivial end
		if cfg.unfinished then lowLevel = lowLevel + survey.unfinishedTrivial end
		if lowLevel > 0 then
			table.insert(parts, ("|cff888888%d low-level|r"):format(lowLevel))
		end
	else
		qualifier = " level-appropriate"
	end

	local headline = ("%s - %d%s quest%s: %s"):format(
		ns.Location:GetMapName(mapID),
		count, qualifier,
		count == 1 and "" or "s",
		table.concat(parts, ", "))

	return count, headline, survey
end

--------------------------------------------------------------------------
-- Banner
--------------------------------------------------------------------------

local function BuildBanner()
	if banner then return banner end

	banner = CreateFrame("Button", "SlootTrackerAlertBanner", UIParent, "BackdropTemplate")
	banner:SetSize(420, 54)
	banner:SetPoint("TOP", UIParent, "TOP", 0, -180)
	banner:SetFrameStrata("HIGH")
	banner:EnableMouse(true)
	banner:SetMovable(true)
	banner:RegisterForDrag("RightButton")
	banner:Hide()

	if banner.SetBackdrop then
		banner:SetBackdrop({
			bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
			edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
			tile = true, tileSize = 32, edgeSize = 22,
			insets = { left = 6, right = 6, top = 6, bottom = 6 },
		})
	end

	banner.icon = banner:CreateTexture(nil, "ARTWORK")
	banner.icon:SetSize(28, 28)
	banner.icon:SetPoint("LEFT", 14, 0)
	banner.icon:SetTexture("Interface\\GossipFrame\\AvailableQuestIcon")

	banner.title = banner:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	banner.title:SetPoint("TOPLEFT", banner.icon, "TOPRIGHT", 8, -2)
	banner.title:SetPoint("RIGHT", -30, 0)
	banner.title:SetJustifyH("LEFT")

	banner.subtitle = banner:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	banner.subtitle:SetPoint("TOPLEFT", banner.title, "BOTTOMLEFT", 0, -3)
	banner.subtitle:SetPoint("RIGHT", -30, 0)
	banner.subtitle:SetJustifyH("LEFT")

	local close = CreateFrame("Button", nil, banner, "UIPanelCloseButton")
	close:SetSize(24, 24)
	close:SetPoint("TOPRIGHT", -2, -2)
	close:SetScript("OnClick", function() banner:Hide() end)

	banner:SetScript("OnDragStart", function(self) self:StartMoving() end)
	banner:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		local point, _, relPoint, x, y = self:GetPoint()
		ns.db.alerts.bannerPos = { point = point, relPoint = relPoint, x = x, y = y }
	end)

	banner:SetScript("OnClick", function()
		banner:Hide()
		ns:Fire("TOGGLE_WINDOW")
	end)

	banner:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
		GameTooltip:AddLine("Sloot Tracker quest alert")
		if self.sample then
			for _, name in ipairs(self.sample) do
				GameTooltip:AddLine("- " .. name, 0.85, 0.85, 0.85)
			end
		end
		GameTooltip:AddLine(" ")
		GameTooltip:AddLine("Click: open the list", 0.4, 0.8, 0.4)
		GameTooltip:AddLine("Right-drag: move this banner", 0.6, 0.6, 0.6)
		GameTooltip:Show()
	end)
	banner:SetScript("OnLeave", function() GameTooltip:Hide() end)

	local saved = ns.db.alerts.bannerPos
	if saved then
		banner:ClearAllPoints()
		banner:SetPoint(saved.point, UIParent, saved.relPoint, saved.x, saved.y)
	end

	return banner
end

local hideTimer
local function ShowBanner(headline, survey)
	local f = BuildBanner()

	f.title:SetText("|cff5bc0f5" .. headline .. "|r")
	if survey and #survey.names > 0 then
		f.subtitle:SetText("e.g. " .. table.concat(survey.names, ", "))
	else
		f.subtitle:SetText("")
	end
	f.sample = survey and survey.names or nil

	f:SetAlpha(1)
	f:Show()

	if hideTimer then hideTimer:Cancel() end
	hideTimer = C_Timer.NewTimer(9, function()
		if f:IsShown() and UIFrameFadeOut then
			UIFrameFadeOut(f, 1.2, 1, 0)
			C_Timer.After(1.3, function() f:Hide() end)
		else
			f:Hide()
		end
	end)
end

--------------------------------------------------------------------------
-- Firing
--------------------------------------------------------------------------

function Alerts:Check(force)
	local cfg = ns.db.alerts
	if not cfg.enabled and not force then return end

	local loc = ns.Location:Get()
	local mapID = loc.mapID
	if not mapID then return end

	-- Do not interrupt a fight, and do not fire mid-loading-screen where the
	-- quest log is not populated yet.
	if not force then
		if InCombatLockdown() then return end
		local last = lastAlertAt[mapID]
		if last and (GetTime() - last) < (cfg.throttle or 300) then return end
	end

	local count, headline, survey = self:Evaluate(mapID)
	if count == 0 then
		if force then ns:Print("nothing to alert about in " .. (loc.zoneName or "this zone") .. ".") end
		return
	end

	lastAlertAt[mapID] = GetTime()

	if cfg.chat or force then
		ns:Print(headline)
	end
	if cfg.banner then
		ShowBanner(headline, survey)
	end
	if cfg.sound then
		ns.Try(PlaySound, SOUNDKIT and SOUNDKIT.IG_QUEST_LOG_OPEN or 875, "Master")
	end
end

--------------------------------------------------------------------------
-- Wiring
--------------------------------------------------------------------------

ns:On("ALERT_CHECK", function(force) Alerts:Check(force) end)

ns:On("ZONE_CHANGED", function()
	if not (ns.db and ns.db.alerts.enabled and ns.db.alerts.onZoneChange) then return end
	-- Let the quest log settle after the zone transition before counting.
	C_Timer.After(4, function() Alerts:Check(false) end)
end)

-- Changing the mode should not be blocked by a throttle from the old mode.
ns:On("ALERT_MODE_CHANGED", function() wipe(lastAlertAt) end)
