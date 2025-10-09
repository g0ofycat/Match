--!strict

local QueueManager = {
	_data = {
		playerQueueKeys = {},
		queueCache = {},
		localQueueCounts = {},
		lastCacheCleanup = 0
	}
}

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
-- // MODULES
--=========================

QueueManager.Modules = {
	Settings = require(script.Parent.Parent.helpers.Settings),
	PlayerLocation = require(script.Parent.Parent.helpers.PlayerLocation)
}

--=========================
-- // INIT
--=========================

function QueueManager:Initialize(matchData: Types.MatchData): ()
	assert(matchData, "[QueueManager:Initialize]: 'matchData' is nil")
	
	;(self :: any)._data = matchData
end

--=========================
-- // PRIVATE API
--=========================

-- getQueue(): Returns the MemoryStoreService SortedMap based on the mode and subMode
-- @param mode: The mode to get
-- @param subMode: The subMode of the mode
-- @return MemoryStoreSortedMap
local function getQueue(self: any, mode: string, subMode: string): MemoryStoreSortedMap
	local queueKey = mode .. "_" .. subMode

	if not self._data.queueCache[queueKey] then
		self._data.queueCache[queueKey] = {
			queue = MemoryStoreService:GetSortedMap("MatchQueue_" .. queueKey),
			lastUsed = tick()
		}
	else
		self._data.queueCache[queueKey].lastUsed = tick()
	end

	return self._data.queueCache[queueKey].queue
end

-- getLockMap(): Returns 'MatchLocks' (MemoryStoreService SortedMap)
local function getLockMap(self: any): MemoryStoreSortedMap
	if not self._data._lockMap then
		self._data._lockMap = MemoryStoreService:GetSortedMap("MatchLocks")
	end

	return self._data._lockMap :: MemoryStoreSortedMap
end

-- cleanupCaches(): Cleans up all caches
local function cleanupCaches(self: any): ()
	local now = tick()

	for queueKey, cacheData in self._data.queueCache do
		if now - cacheData.lastUsed > QueueManager.Modules.Settings.Matches.CACHE_CLEANUP_INTERVAL then
			self._data.queueCache[queueKey] = nil
		end
	end

	if self._data.crossServerData then
		for queueKey, queueData in self._data.crossServerData do
			local expired = {}

			for serverId, serverData in queueData do
				if now - serverData.Timestamp > QueueManager.Modules.Settings.Matches.CROSS_SERVER_DATA_TTL then
					table.insert(expired, serverId)
				end
			end

			for _, serverId in ipairs(expired) do
				queueData[serverId] = nil
			end

			if not next(queueData) then
				self._data.crossServerData[queueKey] = nil
			end
		end
	end

	self._data.lastCacheCleanup = now
end

-- generatePlayerQueueData(): Returns data based on multiple parameters
-- @param player: The Player object to generate queue data for
-- @param ELO: The ELO of the player
-- @param continent: The Continent of the player (Use PlayerLocation)
-- @param subMode: The subMode
-- @return key, HttpService:JSONEncode(data)
local function generatePlayerQueueData(player: Player, ELO: number, continent: string, subMode: string): (string, string)
	local timestamp = math.floor(tick())
	local key = string.format("%010d", timestamp) .. "_" .. tostring(player.UserId)

	local data: Types.PlayerQueueData = {
		UserId = player.UserId,
		ELO = ELO,
		JoinTime = timestamp,
		ServerId = QueueManager.Modules.Settings.Information.SERVER_ID,
		Continent = continent,
		SubMode = subMode
	}

	local success, encoded = pcall(HttpService.JSONEncode, HttpService, data)

	if not success then
		warn("Failed to JSONEncode player queue data for " .. tostring(player.UserId) .. ": " .. encoded)
		return key, nil
	end

	return key, encoded
end

--=========================
-- // PUBLIC API
--=========================

-- QueuePlayer(): Queues the player(s) up into the matchmaking
-- @param playerOrList: The player(s) to queue. Put a list of players to bulk queue them or just add one player
-- @param mode: The mode the player should be queued to (Match.QueueManager.Modules.Settings.Modes)
-- @param subMode: The Sub-Mode the player should be queued to (Keys of Match.QueueManager.Modules.Settings.SubModes)
-- @param ELO?: Optional ELO the player has
function QueueManager:QueuePlayer(playerOrList: Player | { Player }, mode: string, subMode: string, ELO: number?): ()
	assert(table.find(QueueManager.Modules.Settings.Modes, mode), "'mode' doesn't exist in Settings.Modes")
	assert(QueueManager.Modules.Settings.SubModes[subMode], "'subMode' doesn't exist in Settings.SubModes")

	local players: { Player } = typeof(playerOrList) == "Instance" and { playerOrList } or playerOrList :: { Player }
	local queueKey = mode .. "_" .. subMode

	for _, player in players do
		if self._data.playerQueueKeys[player.UserId] and self._data.playerQueueKeys[player.UserId][queueKey] then
			warn(player.Name .. " is already in the queue for mode:", mode, subMode)
			continue
		end

		local playerContinent = QueueManager.Modules.PlayerLocation.GetPlayerContinent(player) :: string
		local key, data = generatePlayerQueueData(player, ELO or 0, playerContinent, subMode)

		local success, err = pcall(function()
			getQueue(self, mode, subMode):SetAsync(key, data, QueueManager.Modules.Settings.Matches.MATCHMAKING_DURATION)
		end)

		if success then
			self._data.playerQueueKeys[player.UserId] = self._data.playerQueueKeys[player.UserId] or {}
			self._data.playerQueueKeys[player.UserId][queueKey] = key
			self._data.localQueueCounts[queueKey] = (self._data.localQueueCounts[queueKey] or 0) + 1
			print("Queued player", player.Name, "for", mode, subMode, "mode. Region:", playerContinent)
		else
			warn("Failed to queue player:", err)
		end
	end
end

-- StopQueue(): Removes the player(s) from all queues across every mode and subMode
-- @param playerOrList: The player(s) to remove from queues. Pass a single player or a list of players for bulk removal
-- @return boolean: True if all players were successfully removed from their queues, false if any failures occurred
function QueueManager:StopQueue(playerOrList: Player | { Player }): boolean
	local players: { Player } = typeof(playerOrList) == "Instance" and { playerOrList } or playerOrList :: { Player }
	local allSuccess = true
	local lockMap = getLockMap(self)

	for _, player in players do
		if not player or not player.UserId then
			allSuccess = false
			continue
		end

		local playerQueues = self._data.playerQueueKeys[player.UserId]

		if not playerQueues then
			pcall(function()
				lockMap:RemoveAsync(tostring(player.UserId))
			end)

			self._data.playerQueueKeys[player.UserId] = nil

			continue
		end

		for queueKey, keyToRemove in playerQueues do
			local mode, subMode = queueKey:match("(.+)_(.+)")
			if not mode or not subMode then
				continue
			end

			local success = pcall(function()
				getQueue(self, mode, subMode):RemoveAsync(keyToRemove)
			end)

			if not success then
				warn("Failed to remove from queue:", queueKey)
				allSuccess = false
				continue
			end

			self._data.localQueueCounts[queueKey] = math.max(0, (self._data.localQueueCounts[queueKey] or 0) - 1)
		end

		pcall(function()
			lockMap:RemoveAsync(tostring(player.UserId))
		end)

		self._data.playerQueueKeys[player.UserId] = nil
	end

	return allSuccess
end

--=========================
-- // QUEUE DATA API
--=========================

-- IsPlayerQueued(): Checks if a player is queued in a certain subMode's mode
-- @param player: The player to check
-- @param mode: The mode the player should be queued to (Match.QueueManager.Modules.Settings.Modes)
-- @param subMode: The Sub-Mode the player should be queued to (Keys of Match.QueueManager.Modules.Settings.SubModes)
-- @return boolean: If the player is queued or not
function QueueManager:IsPlayerQueued(player: Player, mode: string?, subMode: string?): boolean
	local queues = self._data.playerQueueKeys[player.UserId]

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
-- @param mode: The mode the player should be queued to (Match.QueueManager.Modules.Settings.Modes)
-- @param subMode: The Sub-Mode the player should be queued to (Keys of Match.QueueManager.Modules.Settings.SubModes)
-- @return { number }: A list of UserIds of the queued players
function QueueManager:GetQueuedPlayers(mode: string, subMode: string): { number }
	local players = {}
	local queue = getQueue(self, mode, subMode)
	local matchSize = self:GetMatchSize(subMode)
	local batchSize = matchSize :: number * QueueManager.Modules.Settings.Matches.BATCH_SIZE

	local success, result = pcall(function()
		return queue:GetRangeAsync(Enum.SortDirection.Ascending, batchSize)
	end)

	if success and result then
		for _, entry in result do
			local ok, data = pcall(HttpService.JSONDecode, HttpService, entry.value)
			if ok and data and data.UserId then
				table.insert(players, data.UserId)
			else
				warn("Skipped bad queue entry: " .. entry.key)
			end
		end
	else
		warn("Failed to get queue range for " .. mode .. "_" .. subMode)
	end

	return players
end

-- GetPlayerJoinTime(): Gets the players join time in a subMode's mode
-- @param player: The player to check
-- @param mode: The mode the player should be queued to (Match.QueueManager.Modules.Settings.Modes)
-- @param subMode: The Sub-Mode the player should be queued to (Keys of Match.QueueManager.Modules.Settings.SubModes)
-- @return number?: The join time of the player if found, otherwise nil
function QueueManager:GetPlayerJoinTime(player: Player, mode: string, subMode: string): number?
	local queueKey = mode .. "_" .. subMode

	local key = self._data.playerQueueKeys[player.UserId] and self._data.playerQueueKeys[player.UserId][queueKey]

	if not key then return nil end

	local queue = getQueue(self, mode, subMode)

	local success, value = pcall(function()
		return queue:GetAsync(key)
	end)

	if success and value then
		local ok, data = pcall(HttpService.JSONDecode, HttpService, value)
		if ok and data and data.JoinTime then
			return data.JoinTime
		else
			warn("Failed to decode join time for " .. tostring(player.UserId))
		end
	else
		warn("Failed to get async for key: " .. key)
	end

	return nil
end

-- GetQueueCount(): Gets the local queue count in a subMode's mode
-- @param mode: The mode the player should be queued to (Match.QueueManager.Modules.Settings.Modes)
-- @param subMode: The Sub-Mode the player should be queued to (Keys of Match.QueueManager.Modules.Settings.SubModes)
-- @return number: The total number of players in the queue
function QueueManager:GetQueueCount(mode: string, subMode: string): number
	local key = mode .. "_" .. subMode

	return self._data.localQueueCounts[key] or 0
end

--=========================
-- // UTILITY API
--=========================

-- GetMatchSize(): Returns the total number of players required for a match in the given subMode
-- @param subMode: The subMode
-- @return number: totalPlayers
function QueueManager:GetMatchSize(subMode: string): number
	if QueueManager.Modules.Settings.SubModes[subMode] then
		return QueueManager.Modules.Settings.SubModes[subMode].totalPlayers
	end

	warn("Unknown subMode:", subMode, "- using default size of 2")

	return 2
end

-- GetQueue(): Public accessor for queue
function QueueManager:GetQueue(mode: string, subMode: string): MemoryStoreSortedMap
	return getQueue(self, mode, subMode)
end

-- GetLockMap(): Public accessor for lock map
function QueueManager:GetLockMap(): MemoryStoreSortedMap
	return getLockMap(self)
end

-- RunHeartbeat(): Runs cache cleanup on heartbeat
function QueueManager:RunHeartbeat(): ()
	cleanupCaches(self)
end

--=========================
-- // CLEANUP
--=========================

-- Cleanup(): Cleans up queue-specific data
function QueueManager:Cleanup(): ()
	self._data.queueCache = {}
	self._data.localQueueCounts = {}
	self._data.playerQueueKeys = {}
end

return QueueManager