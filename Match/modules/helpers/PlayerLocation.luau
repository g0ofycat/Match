--!strict

local PlayerLocation = {}

--=========================
-- // SERVICES
--=========================

local LocalizationService = game:GetService("LocalizationService")

--=========================
-- // DATA
--=========================

PlayerLocation.continentMap = {
	-- // Africa (AF)
	["DZ"] = "AF", ["AO"] = "AF", ["BJ"] = "AF", ["BW"] = "AF", ["BF"] = "AF", ["BI"] = "AF",
	["CM"] = "AF", ["CV"] = "AF", ["CF"] = "AF", ["TD"] = "AF", ["KM"] = "AF", ["CD"] = "AF",
	["CG"] = "AF", ["CI"] = "AF", ["DJ"] = "AF", ["EG"] = "AF", ["GQ"] = "AF", ["ER"] = "AF",
	["SZ"] = "AF", ["ET"] = "AF", ["GA"] = "AF", ["GM"] = "AF", ["GH"] = "AF", ["GN"] = "AF",
	["GW"] = "AF", ["KE"] = "AF", ["LS"] = "AF", ["LR"] = "AF", ["LY"] = "AF", ["MG"] = "AF",
	["MW"] = "AF", ["ML"] = "AF", ["MR"] = "AF", ["MU"] = "AF", ["YT"] = "AF", ["MA"] = "AF",
	["MZ"] = "AF", ["NA"] = "AF", ["NE"] = "AF", ["NG"] = "AF", ["RE"] = "AF", ["RW"] = "AF",
	["SH"] = "AF", ["ST"] = "AF", ["SN"] = "AF", ["SC"] = "AF", ["SL"] = "AF", ["SO"] = "AF",
	["ZA"] = "AF", ["SS"] = "AF", ["SD"] = "AF", ["TG"] = "AF", ["TN"] = "AF", ["UG"] = "AF",
	["EH"] = "AF", ["ZM"] = "AF", ["ZW"] = "AF",
	-- // Asia (AS)
	["AF"] = "AS", ["AM"] = "AS", ["AZ"] = "AS", ["BH"] = "AS", ["BD"] = "AS", ["BT"] = "AS",
	["BN"] = "AS", ["KH"] = "AS", ["CN"] = "AS", ["CY"] = "AS", ["GE"] = "AS", ["IN"] = "AS",
	["ID"] = "AS", ["IR"] = "AS", ["IQ"] = "AS", ["IL"] = "AS", ["JP"] = "AS", ["JO"] = "AS",
	["KZ"] = "AS", ["KW"] = "AS", ["KG"] = "AS", ["LA"] = "AS", ["LB"] = "AS", ["MY"] = "AS",
	["MV"] = "AS", ["MN"] = "AS", ["MM"] = "AS", ["NP"] = "AS", ["KP"] = "AS", ["OM"] = "AS",
	["PK"] = "AS", ["PS"] = "AS", ["PH"] = "AS", ["QA"] = "AS", ["SA"] = "AS", ["SG"] = "AS",
	["KR"] = "AS", ["LK"] = "AS", ["SY"] = "AS", ["TW"] = "AS", ["TJ"] = "AS", ["TH"] = "AS",
	["TL"] = "AS", ["TR"] = "AS", ["TM"] = "AS", ["AE"] = "AS", ["UZ"] = "AS", ["VN"] = "AS",
	["YE"] = "AS",
	-- // Australia/Oceania (OC)
	["AU"] = "OC", ["FJ"] = "OC", ["KI"] = "OC", ["MH"] = "OC", ["FM"] = "OC", ["NR"] = "OC",
	["NZ"] = "OC", ["PW"] = "OC", ["PG"] = "OC", ["WS"] = "OC", ["SB"] = "OC", ["TO"] = "OC",
	["TV"] = "OC", ["VU"] = "OC",
	-- // Europe (EU)
	["AL"] = "EU", ["AD"] = "EU", ["AT"] = "EU", ["BY"] = "EU", ["BE"] = "EU", ["BA"] = "EU",
	["BG"] = "EU", ["HR"] = "EU", ["CZ"] = "EU", ["DK"] = "EU", ["EE"] = "EU", ["FO"] = "EU",
	["FI"] = "EU", ["FR"] = "EU", ["DE"] = "EU", ["GI"] = "EU", ["GR"] = "EU", ["GG"] = "EU",
	["HU"] = "EU", ["IS"] = "EU", ["IE"] = "EU", ["IM"] = "EU", ["IT"] = "EU", ["JE"] = "EU",
	["LV"] = "EU", ["LI"] = "EU", ["LT"] = "EU", ["LU"] = "EU", ["MT"] = "EU", ["MD"] = "EU",
	["MC"] = "EU", ["ME"] = "EU", ["NL"] = "EU", ["MK"] = "EU", ["NO"] = "EU", ["PL"] = "EU",
	["PT"] = "EU", ["RO"] = "EU", ["RU"] = "EU", ["SM"] = "EU", ["RS"] = "EU", ["SK"] = "EU",
	["SI"] = "EU", ["ES"] = "EU", ["SE"] = "EU", ["CH"] = "EU", ["UA"] = "EU", ["GB"] = "EU",
	["VA"] = "EU",
	-- // North America (NA)
	["AG"] = "NA", ["BS"] = "NA", ["BB"] = "NA", ["BZ"] = "NA", ["CA"] = "NA", ["CR"] = "NA",
	["CU"] = "NA", ["DM"] = "NA", ["DO"] = "NA", ["SV"] = "NA", ["GD"] = "NA", ["GT"] = "NA",
	["HT"] = "NA", ["HN"] = "NA", ["JM"] = "NA", ["MX"] = "NA", ["NI"] = "NA", ["PA"] = "NA",
	["KN"] = "NA", ["LC"] = "NA", ["VC"] = "NA", ["TT"] = "NA", ["US"] = "NA",
	-- // South America (SA)
	["AR"] = "SA", ["BO"] = "SA", ["BR"] = "SA", ["CL"] = "SA", ["CO"] = "SA", ["EC"] = "SA",
	["FK"] = "SA", ["GF"] = "SA", ["GY"] = "SA", ["PY"] = "SA", ["PE"] = "SA", ["SR"] = "SA",
	["UY"] = "SA", ["VE"] = "SA",
	-- // ANTARCTICA (AN)
	["AQ"] = "AN"
}

PlayerLocation.continentCache = {}

--=========================
-- // PUBLIC API
--=========================

-- GetPlayerContinent(): Returns the players continent
-- @param player: The player to get the continent of
-- @return string?: The continent (e.x. NA, SA, EU, etc.) on success, nil on failure
function PlayerLocation.GetPlayerContinent(player: Player): string?
	if not player then
		return nil
	end

	if PlayerLocation.continentCache[player.UserId] then
		print("GetPlayerContinent(): Using cached continent for " .. player.Name .. ": " .. PlayerLocation.continentCache[player.UserId])
		return PlayerLocation.continentCache[player.UserId]
	end

	local success, countryCode = pcall(function()
		return LocalizationService:GetCountryRegionForPlayerAsync(player)
	end)

	if success and countryCode then
		local continent = PlayerLocation.continentMap[string.upper(countryCode)] or "Unknown"

		PlayerLocation.continentCache[player.UserId] = continent

		return continent
	else
		print("GetPlayerContinent(): Failed to get country code for player.")
		return nil
	end
end

--=========================
-- // CLEANUP
--=========================

-- CleanupInit(): Connect all events related to cleanup
function PlayerLocation.CleanupInit(): ()
	game.Players.PlayerRemoving:Connect(function(player)
		PlayerLocation.continentCache[player.UserId] = nil
	end)
end

PlayerLocation.CleanupInit()

return PlayerLocation