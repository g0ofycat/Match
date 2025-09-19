--!strict

local MatchmakingEngine = {}

--=========================
-- // SERVICES
--=========================

local Players = game:GetService("Players")
local MessagingService = game:GetService("MessagingService")
local HttpService = game:GetService("HttpService")
local TeleportService = game:GetService("TeleportService")

--=========================
-- // TYPES
--=========================

local Types = require(script.Parent.Parent.helpers.Types)

--=========================
-- // MODULES
--=========================

MatchmakingEngine.Modules = {
	Settings = require(script.Parent.Parent.helpers.Settings),
	QueueManager = require(script.Parent.QueueManager),
	CrossServerManager = require(script.Parent.CrossServerManager)
}

--=========================
-- // INIT
--=========================

-- Initialize(): Init function for this module
-- @param matchData: Match.Data
function MatchmakingEngine:Initialize(matchData: Types.MatchData): ()
	assert(matchData, "[MatchmakingEngine:Initialize]: 'matchData' is nil")

	;(self :: any)._data = matchData
end

--=========================
-- // HELPER API
--=========================

-- CanStartMatchmaking(): Some basic checks before getting into real matchmaking
-- @param queueKey: The key of the queue
-- @param subMode: The subMode
-- @return boolean: Whether you can start matchmaking or not
function MatchmakingEngine:CanStartMatchmaking(queueKey: string, subMode: string): boolean
	if self._data.isProcessingMatch[queueKey] then
		return false
	end

	local matchSize = MatchmakingEngine.Modules.QueueManager:GetMatchSize(subMode)

	if matchSize % 2 ~= 0 then
		warn("Invalid match size for", subMode, "- must be even number")
		return false
	end

	return true
end

-- ProcessMatchmaking(): Wrapper for multiple functions, Processes matchmaking
-- @param mode: The mode to process
-- @param subMode: The subMode of the mode
-- @param queueKey: The key of the queue
function MatchmakingEngine:ProcessMatchmaking(mode: string, subMode: string, queueKey: string): ()
	local allPlayers = self:CollectPlayers(mode, subMode, queueKey)

	if not allPlayers or #allPlayers == 0 or #allPlayers < MatchmakingEngine.Modules.QueueManager:GetMatchSize(subMode) then
		return
	end

	MatchmakingEngine.Modules.CrossServerManager:RequestCrossServerMatchmaking(mode, subMode)

	local bestGroup = self:FindOptimalPlayerGroup(allPlayers, subMode)

	if bestGroup then
		self:CreateCrossServerMatch(bestGroup, mode, subMode)
	else
		warn("No optimal group found for", mode, subMode)
	end
end

-- CollectPlayers(): Collects all of the players for matchmaking
-- @param mode: The mode to process
-- @param subMode: The subMode of the mode
-- @param queueKey: The key of the queue
-- @return { ParsedPlayerData }
function MatchmakingEngine:CollectPlayers(mode: string, subMode: string, queueKey: string): { Types.ParsedPlayerData }
	if not self._data.localQueueCounts[queueKey] or self._data.localQueueCounts[queueKey] == 0 then
		return {}
	end

	local allPlayers: { Types.ParsedPlayerData } = {}
	local queue = MatchmakingEngine.Modules.QueueManager:GetQueue(mode, subMode)
	local batchSize = math.min(200, MatchmakingEngine.Modules.QueueManager:GetMatchSize(subMode) * MatchmakingEngine.Modules.Settings.Matches.BATCH_SIZE)

	print("Processing matchmaking: Found", self._data.localQueueCounts[queueKey], "total players for", mode, subMode)

	local success, result = pcall(function()
		return queue:GetRangeAsync(Enum.SortDirection.Ascending, batchSize)
	end)

	if success and type(result) == "table" then
		for _, entry in result do
			local playerData = self:ParseQueueEntry(entry)

			if playerData then
				table.insert(allPlayers, playerData)
			end
		end
	else
		warn("Failed to collect players from queue:", queueKey)
	end

	return allPlayers
end

-- ParseQueueEntry(): Returns the JSON decoded entry safely
-- @param entry: The entry
-- @return ParsedPlayerData?
function MatchmakingEngine:ParseQueueEntry(entry: any): Types.ParsedPlayerData
	local success, data = pcall(function()
		return HttpService:JSONDecode(entry.value)
	end)

	if not success or not data or not data.UserId or not data.ELO then
		error("Failed to parse queue entry: " .. tostring(entry.key))
	end

	return {
		UserId = data.UserId,
		ELO = data.ELO,
		JoinTime = data.JoinTime,
		QueueKey = entry.key,
		ServerId = data.ServerId,
		Continent = data.Continent or "Unknown"
	}
end

-- FindOptimalPlayerGroup(): Finds the optimal group for the player
-- @param allPlayers: The players to find the best group for
-- @param subMode: The subMode
-- @return { ParsedPlayerData }?
function MatchmakingEngine:FindOptimalPlayerGroup(allPlayers: { Types.ParsedPlayerData }, subMode: string): { Types.ParsedPlayerData }?
	local matchSize = MatchmakingEngine.Modules.QueueManager:GetMatchSize(subMode)
	local continentGroups = self:GroupPlayersByContinent(allPlayers)

	self:SortPlayers(allPlayers)

	for continent, playersInContinent in continentGroups do
		if #playersInContinent < matchSize then
			continue
		end

		local bestGroup = self:FindBestGroup(playersInContinent, matchSize)

		if bestGroup then
			return bestGroup
		end
	end

	return self:FindBestGroup(allPlayers, matchSize)
end

-- GroupPlayersByContinent(): Groups a list of players by their continent
-- @param players: The players to group
-- @return { [string]: {any} }: A dictionary where keys are continent names and values are lists of players
function MatchmakingEngine:GroupPlayersByContinent(players: { Types.ParsedPlayerData }): { [string]: {any} }
	local groups = {}

	for _, player in players do
		local cont = player.Continent or "Unknown"
		groups[cont] = groups[cont] or {}
		table.insert(groups[cont], player)
	end

	return groups
end

-- SortPlayers(): Sorts players in-place based on wait time or ELO
-- @param players: The players to sort
function MatchmakingEngine:SortPlayers(players: { Types.ParsedPlayerData }): ()
	table.sort(players, function(a, b)
		if MatchmakingEngine.Modules.Settings.Matches.PRIORITIZE_WAIT_TIME and a.JoinTime ~= b.JoinTime then
			return a.JoinTime < b.JoinTime
		end
		return a.ELO < b.ELO
	end)
end

-- FindBestGroup(): Finds the best possible group of players that fit within ELO spread rules
-- @param players: The players to search through
-- @param matchSize: The number of players required for the match
-- @return { ParsedPlayerData }?
function MatchmakingEngine:FindBestGroup(players: { Types.ParsedPlayerData }, matchSize: number): { Types.ParsedPlayerData }?
	if not players or #players < matchSize then
		return nil
	end

	local bestGroup = nil
	local bestSpread = math.huge
	local maxIterations = math.min(#players - matchSize + 1, 50)
	local currentTime = tick()

	for i = 1, maxIterations do
		local group = {}
		for j = i, i + matchSize - 1 do
			table.insert(group, players[j])
		end

		local minELO = group[1].ELO
		local maxELO = group[#group].ELO
		local actualSpread = maxELO - minELO

		local groupValid = self:IsGroupValid(group, actualSpread, currentTime)

		if not groupValid then
			continue
		end

		if actualSpread >= bestSpread then
			continue
		end

		bestSpread = actualSpread
		bestGroup = group

		if actualSpread == 0 then
			break
		end
	end

	return bestGroup
end

-- IsGroupValid(): Validates whether a matchmaking group meets ELO spread requirements for all players each player has a dynamic allowed spread based on their queue wait time
-- @param group: { ParsedPlayerData }
-- @param actualSpread: The ELO difference between highest and lowest ELO players in the group
-- @param currentTime: Current timestamp used to calculate wait times
-- @return boolean: True if all players in the group accept the current ELO spread, false otherwise
function MatchmakingEngine:IsGroupValid(group: { Types.ParsedPlayerData }, actualSpread: number, currentTime: number): boolean
	for _, player in group do
		local waitTime = math.max(0, currentTime - (player.JoinTime or currentTime))
		local baseSpread = MatchmakingEngine.Modules.Settings.Matches.ELO_CHANGE or 200
		local increaseRate = MatchmakingEngine.Modules.Settings.Matches.ELO_INCREASE_RATE or 5
		local playerAllowedSpread = baseSpread + (waitTime * increaseRate)

		if actualSpread > playerAllowedSpread then
			return false
		end
	end

	return true
end

-- CreateCrossServerMatch(): Creates a cross-server match, locks players, removes them from the queue, reserves a server, and notifies other servers
-- @param players: { ParsedPlayerData }
-- @param mode: The mode of the match
-- @param subMode: The sub-mode of the match
-- @return boolean: True if the match was successfully created, false otherwise
function MatchmakingEngine:CreateCrossServerMatch(players: { Types.ParsedPlayerData }, mode: string, subMode: string): boolean
	if not players or #players == 0 then
		warn("No players provided for match creation")
		return false
	end

	print("Creating cross-server match with", #players, "players for", mode, subMode)

	local lockedPlayerIds = self:LockAllPlayers(players)

	if not lockedPlayerIds then
		return false
	end

	local code = self:ReserveMatchServer()

	if not code then
		self:UnlockPlayers(lockedPlayerIds)
		return false
	end

	local playersByServer, removalFailures = self:ProcessPlayerRemoval(players, mode, subMode)

	self:UpdateLocalQueueCount(players, mode, subMode)

	if removalFailures > 0 then
		warn(removalFailures, "queue removal failures occurred")
	end

	local notifySuccess = self:NotifyServersOfMatch(code, playersByServer, mode, subMode)

	if not notifySuccess then
		self:UnlockPlayers(lockedPlayerIds)
		return false
	end

	print("Successfully created cross-server match", MatchmakingEngine.Modules.Settings.Information.SERVER_ID)

	return true
end

-- LockAllPlayers(): Attempts to lock all players for the match
-- @param { ParsedPlayerData }: Array of player data objects
-- @return { number }?: Array of locked player IDs on success, nil on failure
function MatchmakingEngine:LockAllPlayers(players: { Types.ParsedPlayerData }): { number }?
	local lockMap = MatchmakingEngine.Modules.QueueManager:GetLockMap()
	local lockedPlayerIds = {}

	for _, playerData in players do
		if not playerData.UserId then
			warn("Invalid player data missing UserId")
			self:UnlockPlayers(lockedPlayerIds)
			return nil
		end

		local success, err = pcall(function()
			return lockMap:UpdateAsync(
				tostring(playerData.UserId),
				function(oldData)
					return {
						Status = "InMatch",
						MatchId = MatchmakingEngine.Modules.Settings.Information.SERVER_ID,
						Timestamp = tick()
					}
				end,
				MatchmakingEngine.Modules.Settings.Matches.LOCK_TIMEOUT
			)
		end)

		if not success then
			warn("Failed to lock player", playerData.UserId, ":", err)
			self:UnlockPlayers(lockedPlayerIds)
			return nil
		end

		table.insert(lockedPlayerIds, playerData.UserId)
	end

	return lockedPlayerIds
end

-- ReserveMatchServer(): Reserves a server for the match
-- @return string?: Server code on success, nil on failure
function MatchmakingEngine:ReserveMatchServer(): string?
	local success, result = pcall(function()
		return TeleportService:ReserveServer(MatchmakingEngine.Modules.Settings.Information.PLACE_ID)
	end)

	if not success or not result then
		warn("Failed to reserve server:", result)
		return nil
	end

	return result
end

-- ProcessPlayerRemoval(): Removes players from queue and organizes them by server
-- @param players: { ParsedPlayerData }
-- @param mode: Game mode string
-- @param subMode: Game sub-mode string
-- @return ({ [string]: { number } }, number): Table of players organized by server ID, number of removal failures
function MatchmakingEngine:ProcessPlayerRemoval(players: { Types.ParsedPlayerData }, mode: string, subMode: string): ({ [string]: { number } }, number)
	local playersByServer = {}
	local removalFailures = 0
	local queue = MatchmakingEngine.Modules.QueueManager:GetQueue(mode, subMode)

	for _, playerData in players do
		local removeSuccess = pcall(function()
			queue:RemoveAsync(playerData.QueueKey)
		end)

		if not removeSuccess then
			removalFailures += 1
			warn("Failed to remove player from queue:", playerData.UserId)
		end

		if playerData.ServerId == MatchmakingEngine.Modules.Settings.Information.SERVER_ID then
			local player = Players:GetPlayerByUserId(playerData.UserId)
			if player and self._data.playerQueueKeys[playerData.UserId] then
				self._data.playerQueueKeys[playerData.UserId][mode.."_"..subMode] = nil
				if next(self._data.playerQueueKeys[playerData.UserId]) == nil then
					self._data.playerQueueKeys[playerData.UserId] = nil
				end
			end
		end

		local serverId = playerData.ServerId
		playersByServer[serverId] = playersByServer[serverId] or {}
		table.insert(playersByServer[serverId], playerData.UserId)
	end

	return playersByServer, removalFailures
end

-- UpdateLocalQueueCount(): Updates the local queue count after match creation
-- @param players: { ParsedPlayerData }
-- @param mode: Game mode string
-- @param subMode: Game sub-mode string
function MatchmakingEngine:UpdateLocalQueueCount(players: { Types.ParsedPlayerData }, mode: string, subMode: string): ()
	local queueKey = mode .. "_" .. subMode
	local localPlayersRemoved = 0

	for _, playerData in players do
		if playerData.ServerId == MatchmakingEngine.Modules.Settings.Information.SERVER_ID then
			localPlayersRemoved += 1
		end
	end

	self._data.localQueueCounts[queueKey] = math.max(0, (self._data.localQueueCounts[queueKey] or 0) - localPlayersRemoved)
end

-- NotifyServersOfMatch(): Notifies all servers about the new match
-- @param code: Reserved server code
-- @param playersByServer: Players organized by server ID
-- @param mode: Game mode string
-- @param subMode: Game sub-mode string
-- @return boolean: True on success, false on failure
function MatchmakingEngine:NotifyServersOfMatch(code: string, playersByServer: { [string]: { number } }, mode: string, subMode: string): boolean
	local success, err = pcall(function()
		MessagingService:PublishAsync("CrossServerTeleport", {
			MatchId = MatchmakingEngine.Modules.Settings.Information.SERVER_ID,
			ServerCode = code,
			PlaceId = MatchmakingEngine.Modules.Settings.Information.PLACE_ID,
			PlayersForServer = playersByServer,
			Mode = mode,
			SubMode = subMode,
			Timestamp = tick()
		})
	end)

	if not success then
		warn("Failed to notify servers:", err)
		return false
	end

	return true
end

-- UnlockPlayers(): Unlocks players in the lockMap to allow re-queuing or other operations
-- @param playerIds: The user IDs of players to unlock
function MatchmakingEngine:UnlockPlayers(playerIds: { number }): ()
	local lockMap = MatchmakingEngine.Modules.QueueManager:GetLockMap()

	for _, userId in playerIds do
		pcall(function()
			lockMap:RemoveAsync(tostring(userId))
		end)
	end
end

--=========================
-- // PUBLIC API
--=========================

-- MatchMake(): Globally handles and checks all players elligble for Matchmaking based on their Mode and subMode and teleports them
-- @param mode: The mode the player should be queued to (Match.Modules.MatchmakingEngine.Modules.Settings.Modes)
-- @param subMode: The Sub-Mode the player should be queued to (Keys of Match.Modules.MatchmakingEngine.Modules.Settings.SubModes)
function MatchmakingEngine:MatchMake(mode: string, subMode: string): ()
	local queueKey = mode .. "_" .. subMode

	if not self:CanStartMatchmaking(queueKey, subMode) then
		return
	end

	self._data.isProcessingMatch[queueKey] = true

	local success, err = pcall(function()
		self:ProcessMatchmaking(mode, subMode, queueKey)
	end)

	self._data.isProcessingMatch[queueKey] = false

	if not success then
		warn("Error in CrossServerMatchMake:", err, debug.traceback())
	end
end

-- StartMatchmaking(): Starts continuous matchmaking loops for all modes and sub-modes; Each loop calls MatchMake at intervals defined by MatchmakingEngine.Modules.Settings.Matches.CHECK_MATCHMAKING_INTERVALS
function MatchmakingEngine:StartMatchmaking(): ()
	for _, mode in MatchmakingEngine.Modules.Settings.Modes do
		for subMode, _ in MatchmakingEngine.Modules.Settings.SubModes do
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

	self._data.matchmakingTasks[mode.."_"..subMode] = thread
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
	for key, thread in self._data.matchmakingTasks do
		task.cancel(thread)
		self._data.matchmakingTasks[key] = nil
	end
end

--=========================
-- // CLEANUP
--=========================

-- Cleanup(): Cleans up matchmaking-specific data
function MatchmakingEngine:Cleanup(): ()
	self._data.isProcessingMatch = {}
end

return MatchmakingEngine