--!strict

local MatchmakingEngine = {}

--=========================
-- // SERVICES
--=========================

local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")

--=========================
-- // TYPES
--=========================

local Types = require(script.Parent.Parent.helpers.Types)

--=========================
-- // MODULES
--=========================

MatchmakingEngine.Modules = {
	Settings = require(script.Parent.Parent.helpers.Settings),
	SharedData = require(script.Parent.SharedData),
	QueueManager = require(script.Parent.QueueManager),
	CrossServerManager = require(script.Parent.CrossServerManager),
	TeleportHandler = require(script.Parent.TeleportHandler)
}

--=========================
-- // HELPER API
--=========================

-- CanStartMatchmaking(): Some basic checks before getting into real matchmaking
-- @param queueKey: The key of the queue
-- @return boolean: Whether you can start matchmaking or not
function MatchmakingEngine:CanStartMatchmaking(queueKey: Types.QueueKey): boolean
	if not MatchmakingEngine.Modules.SharedData.isProcessingMatch[queueKey.Mode] then
		MatchmakingEngine.Modules.SharedData.isProcessingMatch[queueKey.Mode] = {}
	end

	if MatchmakingEngine.Modules.SharedData.isProcessingMatch[queueKey.Mode][queueKey.SubMode] then
		return false
	end

	local matchSize = MatchmakingEngine.Modules.QueueManager:GetMatchSize(queueKey.SubMode)

	if matchSize % 2 ~= 0 then
		warn("Invalid match size for", queueKey.SubMode, "- must be even number")
		return false
	end

	return true
end

-- ProcessMatchmaking(): Wrapper for multiple functions, Processes matchmaking
-- @param queueKey: The key of the queue
function MatchmakingEngine:ProcessMatchmaking(queueKey: Types.QueueKey): ()
	local allPlayers = self:CollectPlayers(queueKey)

	if not allPlayers or #allPlayers == 0 or #allPlayers < MatchmakingEngine.Modules.QueueManager:GetMatchSize(queueKey.SubMode) then
		return
	end

	MatchmakingEngine.Modules.CrossServerManager:RequestCrossServerMatchmaking(queueKey.Mode, queueKey.SubMode)

	local bestGroup = self:FindOptimalPlayerGroup(allPlayers, queueKey.SubMode)

	if bestGroup then
		self:CreateCrossServerMatch(bestGroup, queueKey)
	else
		warn("No optimal group found for", queueKey.Mode, queueKey.SubMode)
	end
end

-- CollectPlayers(): Collects all of the players for matchmaking
-- @param queueKey: The key of the queue
-- @return { Types.ParsedPlayerData }
function MatchmakingEngine:CollectPlayers(queueKey: Types.QueueKey): { Types.ParsedPlayerData }
	if not MatchmakingEngine.Modules.SharedData.localQueueCounts[queueKey.Mode] or not MatchmakingEngine.Modules.SharedData.localQueueCounts[queueKey.Mode][queueKey.SubMode] or MatchmakingEngine.Modules.SharedData.localQueueCounts[queueKey.Mode][queueKey.SubMode] == 0 then
		return {}
	end

	local allPlayers: { Types.ParsedPlayerData } = {}
	local queue = MatchmakingEngine.Modules.QueueManager:GetQueue(queueKey.Mode, queueKey.SubMode)
	local batchSize = math.clamp(MatchmakingEngine.Modules.QueueManager:GetMatchSize(queueKey.SubMode) * MatchmakingEngine.Modules.Settings.Matches.BATCH_SIZE, 1, 200)

	print("Processing matchmaking: Found", MatchmakingEngine.Modules.SharedData.localQueueCounts[queueKey.Mode][queueKey.SubMode], "total players for", queueKey.Mode, queueKey.SubMode)

	local success, result = pcall(function()
		return queue:GetRangeAsync(Enum.SortDirection.Ascending, batchSize)
	end)

	if success and type(result) == "table" then
		for _, entry in result do
			local playerData = self:ParseQueueEntry(entry, queueKey)

			if playerData then
				table.insert(allPlayers, playerData)
			end
		end
	else
		warn("Failed to collect players from queue:", queueKey.Mode, queueKey.SubMode)
	end

	return allPlayers
end

-- ParseQueueEntry(): Returns the JSON decoded entry safely
-- @param entry: The entry (MemoryStore Key & JSON Encoded PlayerQueueData)
-- @param queueKey: Types.QueueKey
-- @return Types.ParsedPlayerData
function MatchmakingEngine:ParseQueueEntry(entry: any, queueKey: Types.QueueKey): Types.ParsedPlayerData
	local success, data = pcall(HttpService.JSONDecode, HttpService, entry.value)

	if not success or not data or not data.UserId or not data.ELO then
		error("Failed to parse queue entry: " .. entry.key)
	end

	return {
        PartyID = data.PartyID,
		UserId = data.UserId,
		ELO = data.ELO,
		JoinTime = data.JoinTime,
		QueueKey = queueKey,
		MemoryStoreKey = entry.key,
		ServerId = data.ServerId,
		Continent = data.Continent
	}
end

-- FindOptimalPlayerGroup(): Finds the optimal group for the player
-- @param allPlayers: { Types.ParsedPlayerData }
-- @param subMode: The subMode
-- @return { Types.ParsedPlayerData }?
function MatchmakingEngine:FindOptimalPlayerGroup(allPlayers: { Types.ParsedPlayerData }, subMode: string): { Types.ParsedPlayerData }?
	local matchSize = MatchmakingEngine.Modules.QueueManager:GetMatchSize(subMode)

	if #allPlayers < matchSize then return nil end

	local matchmakingUnits = self:CreateMatchmakingUnits(allPlayers)

	local continentGroups = self:GroupUnitsByContinent(matchmakingUnits)

	for _, units in continentGroups do
		local match = self:FormMatchFromUnits(units, matchSize)

		if match then return match end
	end

	return self:FormMatchFromUnits(matchmakingUnits, matchSize)
end

-- IsGroupValid(): Validates whether a matchmaking group meets ELO spread requirements for all players each player has a dynamic allowed spread based on their queue wait time
-- @param group: { Types.ParsedPlayerData }
-- @param actualSpread: The ELO difference between highest and lowest ELO players in the group
-- @param currentTime: Current timestamp used to calculate wait times
-- @return boolean: True if all players in the group accept the current ELO spread, false otherwise
function MatchmakingEngine:IsGroupValid(group: { Types.ParsedPlayerData }, actualSpread: number, currentTime: number): boolean
	local baseSpread = MatchmakingEngine.Modules.Settings.Matches.ELO_CHANGE or 200
	local increaseRate = MatchmakingEngine.Modules.Settings.Matches.ELO_INCREASE_RATE or 5

	for _, player in group do
		if not player.JoinTime then
			return false
		end

		local waitTime = math.max(0, currentTime - player.JoinTime)
		local allowedSpread = baseSpread + (waitTime * increaseRate)

		if actualSpread > allowedSpread then
			return false
		end
	end

	return true
end

-- CreateCrossServerMatch(): Creates a cross-server match, locks players, removes them from the queue, reserves a server, and notifies other servers
-- @param players: { Types.ParsedPlayerData }
-- @param queueKey: Types.QueueKey
-- @return boolean: True if the match was successfully created, false otherwise
function MatchmakingEngine:CreateCrossServerMatch(players: { Types.ParsedPlayerData }, queueKey: Types.QueueKey): boolean
	if not players or #players == 0 then
		warn("No players provided for match creation")
		return false
	end

	print("Creating cross-server match with", #players, "players for", queueKey.Mode, queueKey.SubMode)

	local lockedPlayerIds = self:LockAllPlayers(players)

	if not lockedPlayerIds then
		return false
	end

	local code = MatchmakingEngine.Modules.TeleportHandler:ReserveMatchServer()

	if not code then
		MatchmakingEngine.Modules.TeleportHandler:UnlockPlayers(lockedPlayerIds)
		return false
	end

	local playersByServer, partyMapping, removalFailures = self:ProcessPlayerRemoval(players, queueKey)

	self:UpdateLocalQueueCount(players, queueKey)

	if removalFailures > 0 then
		warn(removalFailures, "queue removal failures occurred")
	end

	local notifySuccess = MatchmakingEngine.Modules.CrossServerManager:NotifyServersOfMatch(code, playersByServer, partyMapping, queueKey)

	if not notifySuccess then
		MatchmakingEngine.Modules.TeleportHandler:UnlockPlayers(lockedPlayerIds)
		return false
	end

	print("Successfully created cross-server match", MatchmakingEngine.Modules.Settings.Information.SERVER_ID)

	return true
end

-- LockAllPlayers(): Attempts to lock all players for the match
-- @param players: { Types.ParsedPlayerData }
-- @return { number }?: Array of locked player IDs on success, nil on failure
function MatchmakingEngine:LockAllPlayers(players: { Types.ParsedPlayerData }): { number }?
	local lockMap = MatchmakingEngine.Modules.QueueManager:GetLockMap()
	local lockedPlayerIds = {}

	for _, playerData in players do
		if not playerData.UserId then
			warn("Invalid player data missing UserId")
			MatchmakingEngine.Modules.TeleportHandler:UnlockPlayers(lockedPlayerIds)
			return nil
		end

		local success, err = pcall(function()
			return lockMap:UpdateAsync(
				tostring(playerData.UserId),
				function(oldData): any
					if oldData and oldData.Status == "InMatch" and oldData.MatchId ~= MatchmakingEngine.Modules.Settings.Information.SERVER_ID then
						return nil
					end

					return {
						Status = "InMatch",
						MatchId = MatchmakingEngine.Modules.Settings.Information.SERVER_ID,
						Timestamp = tick()
					}
				end,

				MatchmakingEngine.Modules.Settings.Matches.LOCK_TIMEOUT
			)
		end)

		if not success or not err then
			warn("Failed to lock player", playerData.UserId, ":", err)
			MatchmakingEngine.Modules.TeleportHandler:UnlockPlayers(lockedPlayerIds)
			return nil
		end

		table.insert(lockedPlayerIds, playerData.UserId)
	end

	return lockedPlayerIds
end

-- ProcessPlayerRemoval(): Removes players from queue and organizes them by server WITH party info
-- @param players: { Types.ParsedPlayerData }
-- @param queueKey: Types.QueueKey
-- @return ({ [string]: { number } }, { [string]: { [number]: string? } }, number): Players by server, party mapping, removal failures
function MatchmakingEngine:ProcessPlayerRemoval(players: { Types.ParsedPlayerData }, queueKey: Types.QueueKey): ({ [string]: { number } }, { [string]: { [number]: string? } }, number)
	local playersByServer = {}
    local partyMapping = {}
	local removalFailures = 0
	local queue = MatchmakingEngine.Modules.QueueManager:GetQueue(queueKey.Mode, queueKey.SubMode)

	for _, playerData in players do
		local success, err = pcall(function()
			queue:RemoveAsync(playerData.MemoryStoreKey)
		end)

		if not success then
			removalFailures += 1
			warn("Failed to remove player from queue:", playerData.UserId, err)
			continue
		end

		local serverId = playerData.ServerId

		playersByServer[serverId] = playersByServer[serverId] or {}

		table.insert(playersByServer[serverId], playerData.UserId)

        if playerData.PartyID then
            partyMapping[serverId] = partyMapping[serverId] or {}
			partyMapping[serverId][playerData.UserId] = playerData.PartyID
		end

		if serverId ~= MatchmakingEngine.Modules.Settings.Information.SERVER_ID then
			continue
		end

		local player = Players:GetPlayerByUserId(playerData.UserId)

		if not player or not MatchmakingEngine.Modules.SharedData.playerQueueKeys[playerData.UserId] then
			continue
		end

		if not MatchmakingEngine.Modules.SharedData.playerQueueKeys[playerData.UserId][queueKey.Mode] then
			continue
		end

		MatchmakingEngine.Modules.SharedData.playerQueueKeys[playerData.UserId][queueKey.Mode][queueKey.SubMode] = nil

		if next(MatchmakingEngine.Modules.SharedData.playerQueueKeys[playerData.UserId][queueKey.Mode]) == nil then
			MatchmakingEngine.Modules.SharedData.playerQueueKeys[playerData.UserId][queueKey.Mode] = nil
		end

		if next(MatchmakingEngine.Modules.SharedData.playerQueueKeys[playerData.UserId]) == nil then
			MatchmakingEngine.Modules.SharedData.playerQueueKeys[playerData.UserId] = nil
		end
	end

	return playersByServer, partyMapping, removalFailures
end

-- UpdateLocalQueueCount(): Updates the local queue count after match creation
-- @param players: { ParsedPlayerData }
-- @param queueKey: Types.QueueKey
function MatchmakingEngine:UpdateLocalQueueCount(players: { Types.ParsedPlayerData }, queueKey: Types.QueueKey): ()
	local localPlayersRemoved = 0

	for _, playerData in players do
		if playerData.ServerId == MatchmakingEngine.Modules.Settings.Information.SERVER_ID then
			localPlayersRemoved += 1
		end
	end

	if not MatchmakingEngine.Modules.SharedData.localQueueCounts[queueKey.Mode] then
		MatchmakingEngine.Modules.SharedData.localQueueCounts[queueKey.Mode] = {}
	end

	MatchmakingEngine.Modules.SharedData.localQueueCounts[queueKey.Mode][queueKey.SubMode] = math.max(0, (MatchmakingEngine.Modules.SharedData.localQueueCounts[queueKey.Mode][queueKey.SubMode] or 0) - localPlayersRemoved)
end

--=========================
-- // PARTY API
--=========================

-- CreateMatchmakingUnits(): Groups players into units (parties stay together)
-- @param players: { Types.ParsedPlayerData }
-- @return { { Types.ParsedPlayerData } }
function MatchmakingEngine:CreateMatchmakingUnits(players: { Types.ParsedPlayerData }): { { Types.ParsedPlayerData } }
	local parties: { [string]: { Types.ParsedPlayerData } } = {}
	local solos = {}

	for _, player in players do
		if player.PartyID then
			parties[player.PartyID] = parties[player.PartyID] or {}
			table.insert(parties[player.PartyID], player)
		else
			table.insert(solos, { player })
		end
	end

	local units = {}

	for _, party in parties do
		table.insert(units, party)
	end

	for _, solo in solos do
		table.insert(units, solo)
	end

	return units
end

-- FormMatchFromUnits(): Forms a match from matchmaking units
-- @param units: { { Types.ParsedPlayerData } }
-- @param matchSize: number
-- @return { Types.ParsedPlayerData }?
function MatchmakingEngine:FormMatchFromUnits(units: { { Types.ParsedPlayerData } }, matchSize: number): { Types.ParsedPlayerData }?
	table.sort(units, function(a, b)
		return self:GetAverageJoinTime(a) < self:GetAverageJoinTime(b) :: number
	end)

	local currentMatch = {}

	for _, unit in units do
		if #currentMatch + #unit <= matchSize then
			for _, player in unit do
				table.insert(currentMatch, player)
			end

			if #currentMatch == matchSize then
				if self:IsMatchValid(currentMatch) then
					return currentMatch
				else
					for _ = 1, #unit do
						table.remove(currentMatch)
					end
				end
			end
		end
	end

	return nil
end

-- GroupUnitsByContinent(): Group all units by their continent
-- @param units: The units to group
-- @return { [string]: { { Types.ParsedPlayerData } } }
function MatchmakingEngine:GroupUnitsByContinent(units: { { Types.ParsedPlayerData } }): { [string]: { { Types.ParsedPlayerData } } }
	local groups = {}

	for _, unit in units do
		local continent = unit[1].Continent
		groups[continent] = groups[continent] or {}
		table.insert(groups[continent], unit)
	end

	return groups
end

-- GetAverageJoinTime(): Gets average join time for a unit
-- @param unit: { Types.ParsedPlayerData }
-- @return number: The average join time
function MatchmakingEngine:GetAverageJoinTime(unit: { Types.ParsedPlayerData }): number
	local sum = 0

	for _, player in unit do
		sum += player.JoinTime or 0
	end

	return sum / #unit
end

-- IsMatchValid(): Validates the entire match (ELO spread, etc.)
-- @param players: { Types.ParsedPlayerData }
-- @return boolean: True if valid, false otherwise
function MatchmakingEngine:IsMatchValid(players: { Types.ParsedPlayerData }): boolean
	table.sort(players, function(a, b) return a.ELO < b.ELO end)

	local minELO = players[1].ELO
	local maxELO = players[#players].ELO
	local actualSpread = maxELO - minELO

	return self:IsGroupValid(players, actualSpread, tick())
end

--=========================
-- // PUBLIC API
--=========================

-- MatchMake(): Globally handles and checks all players eligible for Matchmaking based on their Mode and subMode and teleports them
-- @param mode: The mode the player should be queued to (Match.Modules.MatchmakingEngine.Modules.Settings.Modes)
-- @param subMode: The Sub-Mode the player should be queued to (Keys of Match.Modules.MatchmakingEngine.Modules.Settings.SubModes)
function MatchmakingEngine:MatchMake(mode: string, subMode: string): ()
	local queueKey = {
		Mode = mode,
		SubMode = subMode
	}

	if not self:CanStartMatchmaking(queueKey) then
		return
	end

	if not MatchmakingEngine.Modules.SharedData.isProcessingMatch[queueKey.Mode] then
		MatchmakingEngine.Modules.SharedData.isProcessingMatch[queueKey.Mode] = {}
	end

	MatchmakingEngine.Modules.SharedData.isProcessingMatch[queueKey.Mode][queueKey.SubMode] = true

	local function errHandler(err)
		warn("Matchmaking error:", err, debug.traceback())
	end

	xpcall(function()
		self:ProcessMatchmaking(queueKey)
	end, errHandler)

	MatchmakingEngine.Modules.SharedData.isProcessingMatch[queueKey.Mode][queueKey.SubMode] = false
end

-- StartMatchmaking(): Starts continuous matchmaking loops for all modes and sub-modes; Each loop calls MatchMake at intervals defined by MatchmakingEngine.Modules.Settings.Matches.CHECK_MATCHMAKING_INTERVALS
function MatchmakingEngine:StartMatchmaking(): ()
	for _, mode in MatchmakingEngine.Modules.Settings.Modes do
		for subModeKey, _ in MatchmakingEngine.Modules.Settings.SubModes do
            local subMode = subModeKey :: string
            self:CreateMatchmakingThread(mode, subMode)
        end
	end
end

-- CreateMatchmakingThread(): Creates and starts a matchmaking thread for a specific game mode combination
-- @param mode: The main game mode (e.g., "Ranked", "Casual")
-- @param subMode: The sub-mode variant (e.g., "1v1", "2v2", "4v4")
function MatchmakingEngine:CreateMatchmakingThread(mode: string, subMode: string): ()
	local thread = task.spawn(function()
		self:RunMatchmakingLoop(mode, subMode)
	end)

	if not MatchmakingEngine.Modules.SharedData.matchmakingTasks[mode] then
		MatchmakingEngine.Modules.SharedData.matchmakingTasks[mode] = {}
	end

	MatchmakingEngine.Modules.SharedData.matchmakingTasks[mode][subMode] = thread
end

-- RunMatchmakingLoop(): Runs the continuous matchmaking loop for a specific mode/subMode combination
-- @param mode: The main game mode to process
-- @param subMode: The sub-mode variant to process
function MatchmakingEngine:RunMatchmakingLoop(mode: string, subMode: string): ()
	while true do
		task.wait(MatchmakingEngine.Modules.Settings.Matches.CHECK_MATCHMAKING_INTERVALS)

		local success, err = pcall(function()
			self:MatchMake(mode, subMode)
		end)

		if not success then
			warn(`Matchmaking error for {mode} {subMode}:`, err)
		end
	end
end

-- StopMatchmaking(): Stops all currently running matchmaking loops that were started with StartMatchmaking; Cancels all tasks and clears the internal task table
function MatchmakingEngine:StopMatchmaking(): ()
	for mode, subModes in MatchmakingEngine.Modules.SharedData.matchmakingTasks do
		for subMode, thread in subModes do
			task.cancel(thread)
			MatchmakingEngine.Modules.SharedData.matchmakingTasks[mode][subMode] = nil
		end
	end
end

--=========================
-- // CLEANUP
--=========================

-- Cleanup(): Cleans up matchmaking-specific data
function MatchmakingEngine:Cleanup(): ()
	MatchmakingEngine.Modules.SharedData.isProcessingMatch = {}
end

return MatchmakingEngine