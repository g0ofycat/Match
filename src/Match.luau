--!strict

local Match = {}

--=========================
-- // SERVICES
--=========================

local MemoryStoreService = game:GetService("MemoryStoreService")
local MessagingService = game:GetService("MessagingService")
local HttpService = game:GetService("HttpService")
local TeleportService = game:GetService("TeleportService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

--=========================
-- // DATA
--=========================

Match.Data = {
	playerQueueKeys = {}, -- // Stores the timestamp for each player based on their UserId and their modes
	localQueueCounts = {}, -- // Tracks the amount of players in each queue. Stops all MemoryStoreService calls if there's noone in a certain subMode's mode
	isProcessingMatch = {}, -- // Stores booleans for each player
	crossServerData = {}, -- // Stored data from other servers
	matchmakingTasks = {}, -- // Stores all current loops for matchmaking

	queueCache = {}, -- // Stores Match Queue Maps
	messagingConnections = {}, -- // All of the connections used from MessagingService

	lastCacheCleanup = 0,
	heartbeatConnection = nil,
	_lockMap = nil :: MemoryStoreSortedMap? -- // Stores the 'MatchLocks' MemoryStoreSortedMap
}

--=========================
-- // MODULES
--=========================

Match.Modules = {
	Settings = require(script.Parent.Misc.Settings), -- // Handles all of the core information like modes, subModes, etc
	PlayerLocation = require(script.Parent.Misc.PlayerLocation) -- // Uses LocalizationService to get a player by their Continent
}

--=========================
-- // UTILITY
--=========================

-- getQueue(): Returns the MemoryStoreService SortedMap based on the mode and subMode
-- @param mode: The mode to get
-- @param subMode: The subMode of the mode
-- @return MemoryStoreSortedMap
local function getQueue(mode: string, subMode: string): MemoryStoreSortedMap
	local queueKey = mode .. "_" .. subMode

	if not Match.Data.queueCache[queueKey] then
		Match.Data.queueCache[queueKey] = {
			queue = MemoryStoreService:GetSortedMap("MatchQueue_" .. queueKey),
			lastUsed = tick()
		}
	else
		Match.Data.queueCache[queueKey].lastUsed = tick()
	end

	return Match.Data.queueCache[queueKey].queue
end

-- getLockMap(): Returns 'MatchLocks' (MemoryStoreService SortedMap)
local function getLockMap(): MemoryStoreSortedMap
	if not Match.Data._lockMap then
		Match.Data._lockMap = MemoryStoreService:GetSortedMap("MatchLocks")
	end

	return Match.Data._lockMap :: MemoryStoreSortedMap
end

-- getMatchSize(): Returns the totalPlayers given the subMode
-- @param subMode: The subMode
-- @return number: totalPlayers
local function getMatchSize(subMode: string): number
	if Match.Modules.Settings.SubModes[subMode] then
		return Match.Modules.Settings.SubModes[subMode].totalPlayers
	end

	warn("Unknown subMode:", subMode, "- using default size of 2")

	return 2
end

-- cleanupCaches(): Cleans up all caches
local function cleanupCaches()
	local now = tick()

	for queueKey, cacheData in Match.Data.queueCache do
		if now - cacheData.lastUsed > Match.Modules.Settings.Matches.CACHE_CLEANUP_INTERVAL then
			Match.Data.queueCache[queueKey] = nil
		end	
	end

	if Match.Data.crossServerData then
		for queueKey, queueData in Match.Data.crossServerData :: { [string]: { [string]: any } } do
			for serverId, serverData in queueData :: { [string]: any } do
				if now - serverData.Timestamp > Match.Modules.Settings.Matches.CROSS_SERVER_DATA_TTL then
					queueData[serverId] = nil
				end
			end

			if next(queueData) == nil then
				Match.Data.crossServerData[queueKey] = nil
			end
		end
	end

	Match.Data.lastCacheCleanup = now
end

-- generatePlayerQueueData(): Returns data based on multiple parameters
-- @param player: Used for part of the 'key'
-- @param ELO: The ELO of the player
-- @param continent: The Continent of the player (Use PlayerLocation)
-- @param subMode: The subMode
-- @return key, HttpService:JSONEncode(data)
function generatePlayerQueueData(player: Player, ELO: number, continent: string, subMode: string): (string, string)
	local timestamp = math.floor(tick() * 1000)
	local key = string.format("%010d", timestamp) .. "_" .. tostring(player.UserId)

	local data = {
		UserId = player.UserId,
		ELO = ELO,
		JoinTime = timestamp,
		ServerId = Match.Modules.Settings.Information.SERVER_ID,
		Continent = continent,
		SubMode = subMode
	}
	
	return key, HttpService:JSONEncode(data)
end

--=========================
-- // MESSAGING SERVICE
--=========================

-- setupMessagingService(): Sets up the messaging service subscribers
local function setupMessagingService(): ()
	for _, connection in Match.Data.messagingConnections :: { RBXScriptConnection } do
		connection:Disconnect()
	end

	Match.Data.messagingConnections = {}

	local success, connection = pcall(function()
		return MessagingService:SubscribeAsync("MatchmakingRequest", function(message) -- // Recieves the status of the current Matchmaking to all servers from the data of RequestCrossServerMatchmaking
			local data = message.Data
			if data.Mode and data.SubMode and data.RequestingServer ~= Match.Modules.Settings.Information.SERVER_ID then
				task.spawn(function()
					Match:SendQueueStatus(data.Mode, data.SubMode, data.RequestingServer)
				end)
			end
		end)
	end)

	if success then
		Match.Data.messagingConnections.matchmakingRequest = connection
	end

	success, connection = pcall(function() -- // Teleports all affected players to 1 Private Servers
		return MessagingService:SubscribeAsync("CrossServerTeleport", function(message)
			local data = message.Data
			if data.PlayersForServer and data.PlayersForServer[Match.Modules.Settings.Information.SERVER_ID] then
				task.spawn(function()
					Match:HandleTeleportRequest(data)
				end)
			end
		end)
	end)

	if success then
		Match.Data.messagingConnections.crossServerTeleport = connection
	end

	success, connection = pcall(function()
		return MessagingService:SubscribeAsync("QueueStatusResponse", function(message)
			local data = message.Data
			if data.TargetServer == Match.Modules.Settings.Information.SERVER_ID then
				Match:ReceiveQueueStatus(data)
			end
		end)
	end)

	if success then
		Match.Data.messagingConnections.queueStatusResponse = connection
	end
end

-- RequestCrossServerMatchmaking(): A wrapper for 'MatchmakingRequest' :PublishAsync()
-- @param mode: The mode to request
-- @param subMode: The subMode of the mode
function Match:RequestCrossServerMatchmaking(mode: string, subMode: string): ()
	pcall(function()
		MessagingService:PublishAsync("MatchmakingRequest", {
			Mode = mode,
			SubMode = subMode,
			RequestingServer = Match.Modules.Settings.Information.SERVER_ID,
			Timestamp = tick()
		})
	end)
end

-- SendQueueStatus(): Sends all of the information in the MemoryStore sorted map and broadcasts it to QueueStatusResponse
-- @param mode: The mode to send
-- @param subMode: The subMode of the mode
-- @param targetServer: The server to send the status to
function Match:SendQueueStatus(mode: string, subMode: string, targetServer: string): ()
	local queue = getQueue(mode, subMode)
	local players = {}
	local matchSize = getMatchSize(subMode)
	local maxPlayers = math.min(50, matchSize * 3)

	local success, result = pcall(function()
		return queue:GetRangeAsync(Enum.SortDirection.Ascending, maxPlayers)
	end)

	if success and result then
		for _, entry in result do
			local success, data = pcall(function()
				return HttpService:JSONDecode(entry.value)
			end)
			if success and data and data.ServerId == Match.Modules.Settings.Information.SERVER_ID then
				local player = Players:GetPlayerByUserId(data.UserId)
				if player then
					table.insert(players, {
						UserId = data.UserId,
						ELO = data.ELO,
						JoinTime = data.JoinTime,
						QueueKey = entry.key
					})
				end
			end
		end
	end

	pcall(function()
		MessagingService:PublishAsync("QueueStatusResponse", {
			Mode = mode,
			SubMode = subMode,
			TargetServer = targetServer,
			SendingServer = Match.Modules.Settings.Information.SERVER_ID,
			Players = players,
			PlayerCount = #players,
			Timestamp = tick()
		})
	end)
end

-- ReceiveQueueStatus(): Stores the Cross Server data for MessagingService to use and broadcast to servers
-- @param data
function Match:ReceiveQueueStatus(data: any): ()
	local queueKey = data.Mode .. "_" .. data.SubMode

	if not Match.Data.crossServerData[queueKey] then
		Match.Data.crossServerData[queueKey] = {}
	end

	Match.Data.crossServerData[queueKey][data.SendingServer] = {
		Players = data.Players,
		Timestamp = data.Timestamp
	}

	local now = tick()
	for serverId, serverData in Match.Data.crossServerData[queueKey] do
		if now - serverData.Timestamp > Match.Modules.Settings.Matches.CROSS_SERVER_DATA_TTL then
			Match.Data.crossServerData[queueKey][serverId] = nil
		end
	end
end

--=========================
-- // MATCHMAKING SERVICE
--=========================

-- CanStartMatchmaking(): Some basic checks before getting into real matchmaking
-- @param queueKey: The key of the queue
-- @param subMode: The subMode
-- @return boolean: Whether you can start matchmaking or not
function Match:CanStartMatchmaking(queueKey: string, subMode: string): boolean
	if Match.Data.isProcessingMatch[queueKey] then
		return false
	end

	local matchSize = getMatchSize(subMode)

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
function Match:ProcessMatchmaking(mode: string, subMode: string, queueKey: string): ()
	local allPlayers = self:CollectPlayers(mode, subMode, queueKey)

	if not allPlayers or #allPlayers == 0 or #allPlayers < getMatchSize(subMode) then
		return
	end

	self:RequestCrossServerMatchmaking(mode, subMode)

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
-- @return { any }: A table storing all of the player's data
function Match:CollectPlayers(mode: string, subMode: string, queueKey: string): { any }
	if not Match.Data.localQueueCounts[queueKey] or Match.Data.localQueueCounts[queueKey] == 0 then
		return {}
	end

	local allPlayers = {}
	local queue = getQueue(mode, subMode)
	local batchSize = math.min(200, getMatchSize(subMode) * Match.Modules.Settings.Matches.BATCH_SIZE)

	print("Processing matchmaking: Found", Match.Data.localQueueCounts[queueKey], "total players for", mode, subMode)

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
-- @return { UserId: number, ELO: number, JoinTime: number, QueueKey: string, ServerId: string, Continent: string } or nil if it couldn't safely get the data
function Match:ParseQueueEntry(entry: any): { UserId: number, ELO: number, JoinTime: number, QueueKey: string, ServerId: string, Continent: string }?
	local success, data = pcall(function()
		return HttpService:JSONDecode(entry.value)
	end)

	if not success or not data or not data.UserId or not data.ELO then
		return nil
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
-- @return { any }?: A table of the best players to find
function Match:FindOptimalPlayerGroup(allPlayers: { any }, subMode: string): { any }?
	local matchSize = getMatchSize(subMode)
	local continentGroups = self:GroupPlayersByContinent(allPlayers)

	self:SortPlayers(allPlayers)

	for continent, playersInContinent in continentGroups do
		if #playersInContinent >= matchSize then
			local bestGroup = self:FindBestGroup(playersInContinent, matchSize)
			if bestGroup then
				return bestGroup
			end
		end
	end

	return self:FindBestGroup(allPlayers, matchSize)
end

-- GroupPlayersByContinent(): Groups a list of players by their continent
-- @param players: The players to group
-- @return { [string]: {any} }: A dictionary where keys are continent names and values are lists of players
function Match:GroupPlayersByContinent(players: { any }): { [string]: {any} }
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
function Match:SortPlayers(players: { any }): ()
	table.sort(players, function(a, b)
		if Match.Modules.Settings.Matches.PRIORITIZE_WAIT_TIME and a.JoinTime ~= b.JoinTime then
			return a.JoinTime < b.JoinTime
		end
		return a.ELO < b.ELO
	end)
end

-- FindBestGroup(): Finds the best possible group of players that fit within ELO spread rules
-- @param players: The players to search through
-- @param matchSize: The number of players required for the match
-- @return { any }? : A list of players forming the best valid group, or nil if none found
function Match:FindBestGroup(players: { any }, matchSize: number): { any }?
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

		local groupValid = true
		for _, player in group do
			local waitTime = math.max(0, currentTime - (player.JoinTime or currentTime))
			local baseSpread = Match.Modules.Settings.Matches.ELO_CHANGE or 200
			local increaseRate = Match.Modules.Settings.Matches.ELO_INCREASE_RATE or 5
			local playerAllowedSpread = baseSpread + (waitTime * increaseRate)

			if actualSpread > playerAllowedSpread then
				groupValid = false
				break
			end
		end

		if groupValid and actualSpread < bestSpread then
			bestSpread = actualSpread
			bestGroup = group
			if actualSpread == 0 then
				break
			end
		end
	end

	return bestGroup
end

-- CreateCrossServerMatch(): Creates a cross-server match, locks players, removes them from the queue, reserves a server, and notifies other servers
-- @param players: The players to put into the match
-- @param mode: The mode of the match
-- @param subMode: The sub-mode of the match
-- @return boolean: True if the match was successfully created, false otherwise
function Match:CreateCrossServerMatch(players: { any }, mode: string, subMode: string): boolean
	if not players or #players == 0 then
		warn("No players provided for match creation")
		return false
	end

	print("Creating cross-server match with", #players, "players for", mode, subMode)

	local lockMap = getLockMap()
	local lockedPlayerIds = {}
	local allPlayersValid = true

	for _, playerData in players do
		if not playerData.UserId then
			warn("Invalid player data missing UserId")
			allPlayersValid = false
			break
		end

		local success, err = pcall(function()
			return lockMap:UpdateAsync(
				tostring(playerData.UserId), 
				function(oldData)
					return {
						Status = "InMatch", 
						MatchId = Match.Modules.Settings.Information.SERVER_ID, 
						Timestamp = tick() 
					}
				end,
				Match.Modules.Settings.Matches.LOCK_TIMEOUT
			)
		end)

		if not success then
			warn("Failed to lock player", playerData.UserId, ":", err)
			allPlayersValid = false
			break
		end

		table.insert(lockedPlayerIds, playerData.UserId)
	end

	if not allPlayersValid then
		self:UnlockPlayers(lockedPlayerIds)
		return false
	end

	local code, reserveErr

	local success, err = pcall(function()
		code, reserveErr = TeleportService:ReserveServer(Match.Modules.Settings.Information.PLACE_ID)
	end)

	if not success or not code then
		warn("Failed to reserve server:", err or reserveErr)
		self:UnlockPlayers(lockedPlayerIds)
		return false
	end

	local playersByServer = {}
	local removalFailures = 0
	local queue = getQueue(mode, subMode)

	for _, playerData in players do
		local removeSuccess = pcall(function()
			queue:RemoveAsync(playerData.QueueKey)
		end)

		if not removeSuccess then
			removalFailures += 1
			warn("Failed to remove player from queue:", playerData.UserId)
		end

		if playerData.ServerId == Match.Modules.Settings.Information.SERVER_ID then
			local player = Players:GetPlayerByUserId(playerData.UserId)
			if player and Match.Data.playerQueueKeys[playerData.UserId] then
				Match.Data.playerQueueKeys[playerData.UserId][mode.."_"..subMode] = nil
				if next(Match.Data.playerQueueKeys[playerData.UserId]) == nil then
					Match.Data.playerQueueKeys[playerData.UserId] = nil
				end
			end
		end

		local serverId = playerData.ServerId
		playersByServer[serverId] = playersByServer[serverId] or {}
		table.insert(playersByServer[serverId], playerData.UserId)
	end

	local queueKey = mode .. "_" .. subMode
	local localPlayersRemoved = 0

	for _, playerData in players do
		if playerData.ServerId == Match.Modules.Settings.Information.SERVER_ID then
			localPlayersRemoved += 1
		end
	end

	Match.Data.localQueueCounts[queueKey] = math.max(0, (Match.Data.localQueueCounts[queueKey] or 0) - localPlayersRemoved)

	if removalFailures > 0 then
		warn(removalFailures, "queue removal failures occurred")
	end

	local notifySuccess, notifyErr = pcall(function()
		MessagingService:PublishAsync("CrossServerTeleport", {
			MatchId = Match.Modules.Settings.Information.SERVER_ID,
			ServerCode = code,
			PlaceId = Match.Modules.Settings.Information.PLACE_ID,
			PlayersForServer = playersByServer,
			Mode = mode,
			SubMode = subMode,
			Timestamp = tick()
		})
	end)

	if not notifySuccess then
		warn("Failed to notify servers:", notifyErr)
		self:UnlockPlayers(lockedPlayerIds)
		return false
	end

	print("Successfully created cross-server match", Match.Modules.Settings.Information.SERVER_ID)
	return true
end

-- UnlockPlayers(): Unlocks players in the lockMap to allow re-queuing or other operations
-- @param playerIds: The user IDs of players to unlock
function Match:UnlockPlayers(playerIds: { number }): ()
	local lockMap = getLockMap()
	for _, userId in playerIds do
		pcall(function()
			lockMap:RemoveAsync(tostring(userId))
		end)
	end
end

-- HandleTeleportRequest(): Handles a teleport request by teleporting players to a reserved private server for a cross-server match, with retries and backoff
-- @param data: The teleport data (includes PlaceId, ServerCode, PlayersForServer, MatchId, Mode, SubMode)
function Match:HandleTeleportRequest(data: any): ()
	local playersToTeleport = {}
	local playerIds = data.PlayersForServer[Match.Modules.Settings.Information.SERVER_ID]
	if not playerIds then return end

	for _, userId in playerIds do
		local player = Players:GetPlayerByUserId(userId)
		if player then
			table.insert(playersToTeleport, player)
		end
	end

	if #playersToTeleport == 0 then return end

	print("Teleporting", #playersToTeleport, "players to cross-server match")

	local playersToRetry = playersToTeleport
	local maxRetries = Match.Modules.Settings.Matches.TELEPORT_RETRIES

	for attempt = 1, maxRetries do
		if #playersToRetry == 0 then break end

		local success, err = pcall(function()
			TeleportService:TeleportToPrivateServer(
				data.PlaceId,
				data.ServerCode,
				playersToRetry,
				nil,
				{
					MatchId = data.MatchId,
					Mode = data.Mode,
					SubMode = data.SubMode
				}
			)
		end)

		if success then
			print(`Successfully teleported {#playersToRetry} players on attempt {attempt}`)
			playersToRetry = {}
			break
		else
			local stillValidPlayers = {}
			for _, player in playersToRetry do
				if player.Parent and Players:GetPlayerByUserId(player.UserId) then
					table.insert(stillValidPlayers, player)
				end
			end
			playersToRetry = stillValidPlayers

			if attempt < maxRetries and #playersToRetry > 0 then
				task.wait(0.5 + (attempt * 0.2))
			end
		end
	end

	if #playersToRetry > 0 then
		warn(`Failed to teleport {#playersToRetry} players after {maxRetries} attempts`)
		
		local playerIds = {}
		
		for _, player in playersToRetry do
			table.insert(playerIds, player.UserId)
		end
		
		self:UnlockPlayers(playerIds)
	end
end

--=========================
-- // MAIN API
--=========================

-- QueuePlayer(): Queues the player(s) up into the matchmaking
-- @param playerOrList: The player(s) to queue. Put a list of players to bulk queue them or just add one player
-- @param mode: The mode the player should be queued to (Match.Modules.Settings.Modes)
-- @param subMode: The Sub-Mode the player should be queued to (Keys of Match.Modules.Settings.SubModes)
-- @param ELO?: Optional ELO the player has
function Match:QueuePlayer(playerOrList: Player | { Player }, mode: string, subMode: string, ELO: number?): ()
	assert(table.find(Match.Modules.Settings.Modes, mode), "'mode' doesn't exist in Settings.Modes")
	assert(Match.Modules.Settings.SubModes[subMode], "'subMode' doesn't exist in Settings.SubModes")

	local players: { Player } = typeof(playerOrList) == "Instance" and { playerOrList } or playerOrList :: { Player }
	local queueKey = mode .. "_" .. subMode

	for _, player in players do
		if Match.Data.playerQueueKeys[player.UserId] and Match.Data.playerQueueKeys[player.UserId][queueKey] then
			warn(player.Name .. " is already in the queue for mode:", mode, subMode)
			continue
		end
		
		local playerContinent = Match.Modules.PlayerLocation.GetPlayerContinent(player)
		
		local key, data = generatePlayerQueueData(player, ELO or 1000, playerContinent, subMode)

		if not Match.Data.playerQueueKeys[player.UserId] then
			Match.Data.playerQueueKeys[player.UserId] = {}
		end
		
		Match.Data.playerQueueKeys[player.UserId][queueKey] = key

		local success, err = pcall(function()
			getQueue(mode, subMode):SetAsync(key, data, Match.Modules.Settings.Matches.MATCHMAKING_DURATION)
		end)

		if not success then
			warn("Failed to queue player:", err)
			Match.Data.playerQueueKeys[player.UserId][queueKey] = nil
		else
			Match.Data.localQueueCounts[queueKey] = math.max(0, (Match.Data.localQueueCounts[queueKey] or 0) + 1)
			print("Queued player", player.Name, "for", mode, subMode, "mode. Region: " .. playerContinent)
		end
	end
end

-- StopQueue(): Stops the player(s) queue for every Mode and subMode
-- @param playerOrList: The player(s) to stop queuing. Pass a list to bulk remove
-- @return boolean: Whether it has worked or not
function Match:StopQueue(playerOrList: Player | { Player }): boolean
	local players: { Player } = typeof(playerOrList) == "Instance" and { playerOrList } or playerOrList :: { Player }
	local allSuccess = true
	local lockMap = getLockMap()

	for _, player in players do
		if not player or not player.UserId then
			allSuccess = false
			continue
		end

		local playerQueues = Match.Data.playerQueueKeys[player.UserId]
		if playerQueues then
			for queueKey, keyToRemove in playerQueues do
				local mode, subMode = queueKey:match("(.+)_(.+)")
				if mode and subMode then
					local success = pcall(function()
						getQueue(mode, subMode):RemoveAsync(keyToRemove)
					end)
					if success then
						Match.Data.localQueueCounts[queueKey] = math.max(0, (Match.Data.localQueueCounts[queueKey] or 0) - 1)
					else
						warn("Failed to remove from queue:", queueKey)
						allSuccess = false
					end
				end
			end
		end

		pcall(function()
			lockMap:RemoveAsync(tostring(player.UserId))
		end)

		Match.Data.playerQueueKeys[player.UserId] = nil
	end

	return allSuccess
end

-- MatchMake(): Globally handles and checks all players elligble for Matchmaking based on their Mode and subMode and teleports them
-- @param mode: The mode the player should be queued to (Match.Modules.Settings.Modes)
-- @param subMode: The Sub-Mode the player should be queued to (Keys of Match.Modules.Settings.SubModes)
function Match:MatchMake(mode: string, subMode: string): ()
	local queueKey = mode .. "_" .. subMode

	if not self:CanStartMatchmaking(queueKey, subMode) then
		return
	end

	Match.Data.isProcessingMatch[queueKey] = true

	local success, err = pcall(function()
		self:ProcessMatchmaking(mode, subMode, queueKey)
	end)

	Match.Data.isProcessingMatch[queueKey] = false

	if not success then
		warn("Error in CrossServerMatchMake:", err, debug.traceback())
	end
end

-- StartMatchmaking(): Starts continuous matchmaking loops for all modes and sub-modes; Each loop calls MatchMake at intervals defined by Settings.Matches.CHECK_MATCHMAKING_INTERVALS
-- @param modes: A list of mode names to run matchmaking for
function Match:StartMatchmaking(): ()
	for _, mode in Match.Modules.Settings.Modes do
		for subMode, _ in Match.Modules.Settings.SubModes do
			local thread = task.spawn(function()
				while true do
					task.wait(Match.Modules.Settings.Matches.CHECK_MATCHMAKING_INTERVALS)
					local success, err = pcall(function()
						self:MatchMake(mode, subMode)
					end)
					if not success then
						warn(`Matchmaking error for {mode} {subMode}:`, err)
					end
				end
			end)
			
			Match.Data.matchmakingTasks[mode.."_"..subMode] = thread
		end
	end
end

-- StopMatchmaking(): Stops all currently running matchmaking loops that were started with StartMatchmaking; Cancels all tasks and clears the internal task table
function Match:StopMatchmaking(): ()
	for key, thread in self._matchmakingTasks do
		task.cancel(thread)
		self._matchmakingTasks[key] = nil
	end
end

--=========================
-- // MISC
--=========================

-- Cleanup(): Cleans up all caches
function Match:Cleanup()
	for _, connection in Match.Data.messagingConnections :: { RBXScriptConnection } do
		pcall(function()
			connection:Disconnect()
		end)
	end

	Match.Data.messagingConnections = {}

	Match.Data.queueCache = {}

	if Match.Data.crossServerData then
		Match.Data.crossServerData = {}
	end

	Match.Data.playerQueueKeys = {}

	if Match.Data.heartbeatConnection then
		Match.Data.heartbeatConnection:Disconnect()
	end

	Match.Data.isProcessingMatch = {}
end

-- IsPlayerQueued(): Checks if a player is queued in a certain subMode's mode
-- @param player: The player to check
-- @param mode: The mode the player should be queued to (Match.Modules.Settings.Modes)
-- @param subMode: The Sub-Mode the player should be queued to (Keys of Match.Modules.Settings.SubModes)
-- @return boolean: If the player is queued or not
function Match:IsPlayerQueued(player: Player, mode: string?, subMode: string?): boolean
	local queues = Match.Data.playerQueueKeys[player.UserId]
	
	if not queues then
		return false
	end

	if mode and subMode then
		local key = mode .. "_" .. subMode

		return queues[key] ~= nil
	end

	return next(queues) ~= nil
end

-- GetQueuedPlayers(): Get all of the queued players in a subMode's mode
-- @param mode: The mode the player should be queued to (Match.Modules.Settings.Modes)
-- @param subMode: The Sub-Mode the player should be queued to (Keys of Match.Modules.Settings.SubModes)
-- @return { number }: A list of UserIds of the queued players
function Match:GetQueuedPlayers(mode: string, subMode: string): { number }
	local players = {}
	local queue = getQueue(mode, subMode)
	local batchSize = math.min(200, getMatchSize(subMode) * Match.Modules.Settings.Matches.BATCH_SIZE)
	
	local success, result = pcall(function()
		return queue:GetRangeAsync(Enum.SortDirection.Ascending, batchSize)
	end)

	if success and result then
		for _, entry in result do
			local data = HttpService:JSONDecode(entry.Value)
			table.insert(players, data.UserId)
		end
	end

	return players
end

-- GetPlayerJoinTime(): Gets the players join time in a subMode's mode
-- @param player: The player to check
-- @param mode: The mode the player should be queued to (Match.Modules.Settings.Modes)
-- @param subMode: The Sub-Mode the player should be queued to (Keys of Match.Modules.Settings.SubModes)
-- @return number?: The join time of the player if found, otherwise nil
function Match:GetPlayerJoinTime(player: Player, mode: string, subMode: string): number?
	local queueKey = mode .. "_" .. subMode
	local key = Match.Data.playerQueueKeys[player.UserId] and Match.Data.playerQueueKeys[player.UserId][queueKey]
	if not key then return nil end

	local queue = getQueue(mode, subMode)
	
	local success, value = pcall(function()
		return queue:GetAsync(key)
	end)

	if success and value then
		local data = HttpService:JSONDecode(value)
		return data.JoinTime
	end

	return nil
end

-- GetQueueCount(): Gets the local queue count in a subMode's mode
-- @param mode: The mode the player should be queued to (Match.Modules.Settings.Modes)
-- @param subMode: The Sub-Mode the player should be queued to (Keys of Match.Modules.Settings.SubModes)
-- @return number: The total number of players in the queue
function Match:GetQueueCount(mode: string, subMode: string): number
	local key = mode .. "_" .. subMode

	return Match.Data.localQueueCounts[key] or 0
end

--=========================
-- // INIT
--=========================

setupMessagingService()

Players.PlayerRemoving:Connect(function(player)
	if player then
		Match:StopQueue(player)
	end
end)

game:BindToClose(function()
	Match:Cleanup()
end)

--=========================
-- // CONNECTIONS
--=========================

Match.Data.heartbeatConnection = RunService.Heartbeat:Connect(function()
	if tick() - Match.Data.lastCacheCleanup > Match.Modules.Settings.Matches.CACHE_CLEANUP_INTERVAL then
		cleanupCaches()
	end
end)

return Match