--!strict

local QueueManager = {}

--=========================
-- // SERVICES
--=========================

local MemoryStoreService = game:GetService("MemoryStoreService")
local HttpService = game:GetService("HttpService")

--=========================
-- // TYPES
--=========================

local Types = require(script.Parent.Parent.helpers.Types)

--=========================
-- // DATA
--=========================

local Data
local Modules

--=========================
-- // INIT
--=========================

function QueueManager:Initialize(matchData: Types.MatchData, modules: any): ()
	Data = matchData
	Modules = modules
end

--=========================
-- // PRIVATE API
--=========================

-- getQueue(): Returns the MemoryStoreService SortedMap based on the mode and subMode
-- @param mode: The mode to get
-- @param subMode: The subMode of the mode
-- @return MemoryStoreSortedMap
local function getQueue(mode: string, subMode: string): MemoryStoreSortedMap
	local queueKey = mode .. "_" .. subMode

	if not Data.queueCache[queueKey] then
		Data.queueCache[queueKey] = {
			queue = MemoryStoreService:GetSortedMap("MatchQueue_" .. queueKey),
			lastUsed = tick()
		}
	else
		Data.queueCache[queueKey].lastUsed = tick()
	end

	return Data.queueCache[queueKey].queue
end

-- getLockMap(): Returns 'MatchLocks' (MemoryStoreService SortedMap)
local function getLockMap(): MemoryStoreSortedMap
	if not Data._lockMap then
		Data._lockMap = MemoryStoreService:GetSortedMap("MatchLocks")
	end

	return Data._lockMap :: MemoryStoreSortedMap
end

-- cleanupCaches(): Cleans up all caches
local function cleanupCaches(): ()
	local now = tick()

	for queueKey, cacheData in Data.queueCache do
		if now - cacheData.lastUsed > Modules.Settings.Matches.CACHE_CLEANUP_INTERVAL then
			Data.queueCache[queueKey] = nil
		end
	end

	if Data.crossServerData then
		for queueKey, queueData in Data.crossServerData do
			local expired = {}

			for serverId, serverData in queueData do
				if now - serverData.Timestamp > Modules.Settings.Matches.CROSS_SERVER_DATA_TTL then
					table.insert(expired, serverId)
				end
			end

			for _, serverId in ipairs(expired) do
				queueData[serverId] = nil
			end

			if not next(queueData) then
				Data.crossServerData[queueKey] = nil
			end
		end
	end

	Data.lastCacheCleanup = now
end

-- generatePlayerQueueData(): Returns data based on multiple parameters
-- @param player: The Player object to generate queue data for
-- @param ELO: The ELO of the player
-- @param continent: The Continent of the player (Use PlayerLocation)
-- @param subMode: The subMode
-- @return key, HttpService:JSONEncode(data)
local function generatePlayerQueueData(player: Player, ELO: number, continent: string, subMode: string): (string, string)
	local timestamp = math.floor(tick() * 1000)
	local key = string.format("%010d", timestamp) .. "_" .. tostring(player.UserId)

	local data: Types.PlayerQueueData = {
		UserId = player.UserId,
		ELO = ELO,
		JoinTime = timestamp,
		ServerId = Modules.Settings.Information.SERVER_ID,
		Continent = continent,
		SubMode = subMode
	}

	return key, HttpService:JSONEncode(data)
end

--=========================
-- // PUBLIC API
--=========================

-- QueuePlayer(): Queues the player(s) up into the matchmaking
-- @param playerOrList: The player(s) to queue. Put a list of players to bulk queue them or just add one player
-- @param mode: The mode the player should be queued to (Match.Modules.Settings.Modes)
-- @param subMode: The Sub-Mode the player should be queued to (Keys of Match.Modules.Settings.SubModes)
-- @param ELO?: Optional ELO the player has
function QueueManager:QueuePlayer(playerOrList: Player | { Player }, mode: string, subMode: string, ELO: number?): ()
	assert(table.find(Modules.Settings.Modes, mode), "'mode' doesn't exist in Settings.Modes")
	assert(Modules.Settings.SubModes[subMode], "'subMode' doesn't exist in Settings.SubModes")

	local players: { Player } = typeof(playerOrList) == "Instance" and { playerOrList } or playerOrList :: { Player }
	local queueKey = mode .. "_" .. subMode

	for _, player in players do
		if Data.playerQueueKeys[player.UserId] and Data.playerQueueKeys[player.UserId][queueKey] then
			warn(player.Name .. " is already in the queue for mode:", mode, subMode)
			continue
		end

		local playerContinent = Modules.PlayerLocation.GetPlayerContinent(player)

		local key, data = generatePlayerQueueData(player, ELO or 0, playerContinent, subMode)

		if not Data.playerQueueKeys[player.UserId] then
			Data.playerQueueKeys[player.UserId] = {}
		end

		Data.playerQueueKeys[player.UserId][queueKey] = key

		local success, err = pcall(function()
			getQueue(mode, subMode):SetAsync(key, data, Modules.Settings.Matches.MATCHMAKING_DURATION)
		end)

		if not success then
			warn("Failed to queue player:", err)
			Data.playerQueueKeys[player.UserId][queueKey] = nil
		else
			Data.localQueueCounts[queueKey] = math.max(0, (Data.localQueueCounts[queueKey] or 0) + 1)
			print("Queued player", player.Name, "for", mode, subMode, "mode. Region: " .. playerContinent)
		end
	end
end

-- StopQueue(): Removes the player(s) from all queues across every mode and subMode
-- @param playerOrList: The player(s) to remove from queues. Pass a single player or a list of players for bulk removal
-- @return boolean: True if all players were successfully removed from their queues, false if any failures occurred
function QueueManager:StopQueue(playerOrList: Player | { Player }): boolean
	local players: { Player } = typeof(playerOrList) == "Instance" and { playerOrList } or playerOrList :: { Player }
	local allSuccess = true
	local lockMap = getLockMap()

	for _, player in players do
		if not player or not player.UserId then
			allSuccess = false
			continue
		end

		local playerQueues = Data.playerQueueKeys[player.UserId]

		if not playerQueues then
			pcall(function()
				lockMap:RemoveAsync(tostring(player.UserId))
			end)

			Data.playerQueueKeys[player.UserId] = nil

			continue
		end

		for queueKey, keyToRemove in playerQueues do
			local mode, subMode = queueKey:match("(.+)_(.+)")
			if not mode or not subMode then
				continue
			end

			local success = pcall(function()
				getQueue(mode, subMode):RemoveAsync(keyToRemove)
			end)

			if not success then
				warn("Failed to remove from queue:", queueKey)
				allSuccess = false
				continue
			end

			Data.localQueueCounts[queueKey] = math.max(0, (Data.localQueueCounts[queueKey] or 0) - 1)
		end

		pcall(function()
			lockMap:RemoveAsync(tostring(player.UserId))
		end)

		Data.playerQueueKeys[player.UserId] = nil
	end

	return allSuccess
end

--=========================
-- // QUEUE INFO
--=========================

-- IsPlayerQueued(): Checks if a player is queued in a certain subMode's mode
-- @param player: The player to check
-- @param mode: The mode the player should be queued to (Match.Modules.Settings.Modes)
-- @param subMode: The Sub-Mode the player should be queued to (Keys of Match.Modules.Settings.SubModes)
-- @return boolean: If the player is queued or not
function QueueManager:IsPlayerQueued(player: Player, mode: string?, subMode: string?): boolean
	local queues = Data.playerQueueKeys[player.UserId]

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
function QueueManager:GetQueuedPlayers(mode: string, subMode: string): { number }
	local players = {}
	local queue = getQueue(mode, subMode)
	local matchSize = self:GetMatchSize(subMode)
	local batchSize = math.min(200, matchSize :: number * Modules.Settings.Matches.BATCH_SIZE)

	local success, result = pcall(function()
		return queue:GetRangeAsync(Enum.SortDirection.Ascending, batchSize)
	end)

	if success and result then
		for _, entry in result do
			local data = HttpService:JSONDecode(entry.value)
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
function QueueManager:GetPlayerJoinTime(player: Player, mode: string, subMode: string): number?
	local queueKey = mode .. "_" .. subMode
	local key = Data.playerQueueKeys[player.UserId] and Data.playerQueueKeys[player.UserId][queueKey]
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
function QueueManager:GetQueueCount(mode: string, subMode: string): number
	local key = mode .. "_" .. subMode

	return Data.localQueueCounts[key] or 0
end

--=========================
-- // UTILITY FUNCTIONS
--=========================

-- GetMatchSize(): Returns the total number of players required for a match in the given subMode
-- @param subMode: The subMode
-- @return number: totalPlayers
function QueueManager:GetMatchSize(subMode: string): number
	if Modules.Settings.SubModes[subMode] then
		return Modules.Settings.SubModes[subMode].totalPlayers
	end

	warn("Unknown subMode:", subMode, "- using default size of 2")

	return 2
end

-- GetQueue(): Public accessor for queue
function QueueManager:GetQueue(mode: string, subMode: string): MemoryStoreSortedMap
	return getQueue(mode, subMode)
end

-- GetLockMap(): Public accessor for lock map
function QueueManager:GetLockMap(): MemoryStoreSortedMap
	return getLockMap()
end

--=========================
-- // HEARTBEAT
--=========================

-- RunHeartbeat(): Runs cache cleanup on heartbeat
function QueueManager:RunHeartbeat(): ()
	if tick() - Data.lastCacheCleanup > Modules.Settings.Matches.CACHE_CLEANUP_INTERVAL then
		cleanupCaches()
	end
end

--=========================
-- // CLEANUP
--=========================

-- Cleanup(): Cleans up queue-specific data
function QueueManager:Cleanup(): ()
	Data.queueCache = {}
	Data.playerQueueKeys = {}
end

return QueueManager