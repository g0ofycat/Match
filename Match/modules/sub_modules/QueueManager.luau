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
-- // MODULES
--=========================

QueueManager.Modules = {
	Settings = require(script.Parent.Parent.helpers.Settings),
	SharedData = require(script.Parent.SharedData),
	PlayerLocation = require(script.Parent.Parent.helpers.PlayerLocation)
}

--=========================
-- // PRIVATE API
--=========================

-- generatePlayerQueueData(): Returns data based on multiple parameters
-- @param player: The Player object to generate queue data for
-- @param partyID?: The ID of the party, if any
-- @param isLeader: If the player is the leader of their party
-- @param continent: The Continent of the player (Use PlayerLocation)
-- @param ELO: The ELO of the player
-- @return key, encoded? (JSON Encoded PlayerQueueData)
local function generatePlayerQueueData(player: Player, partyID: string?, isLeader: boolean, continent: string, ELO: number): (string, string?)
	local timestamp = tick()
	local key = HttpService:GenerateGUID(false)

	local data: Types.PlayerQueueData = {
        PartyID = partyID,
        IsPartyLeader = isLeader,
		UserId = player.UserId,
		ELO = ELO,
		JoinTime = timestamp,
		ServerId = QueueManager.Modules.Settings.Information.SERVER_ID,
		Continent = continent
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

-- QueuePlayer(): Queues the player(s) up into matchmaking
-- @param playerOrList: The player(s) to queue. Put a list of players to bulk queue them or just add one player
-- @param mode: The mode the player should be queued to (Match.QueueManager.Modules.Settings.Modes)
-- @param subMode: The Sub-Mode the player should be queued to (Keys of Match.QueueManager.Modules.Settings.SubModes)
-- @param ELO?: Optional ELO the player has
function QueueManager:QueuePlayer(playerOrList: Player | { Player }, mode: string, subMode: string, ELO: number?): ()
	assert(table.find(QueueManager.Modules.Settings.Modes, mode), "'mode' doesn't exist in Settings.Modes")
	assert(QueueManager.Modules.Settings.SubModes[subMode], "'subMode' doesn't exist in Settings.SubModes")

	local players: { Player } = typeof(playerOrList) == "Instance" and { playerOrList } or playerOrList :: { Player }

	for _, player in players do
		if QueueManager.Modules.SharedData.playerQueueKeys[player.UserId] then
			warn(player.Name .. " is already in a queue")
			return
		end

		local playerContinent = QueueManager.Modules.PlayerLocation.GetPlayerContinent(player)

        if not playerContinent then
            warn(`QueuePlayer(): Couldn't find {player}'s continent, skipping`)
            continue
        end

		local key, data = generatePlayerQueueData(player, nil, false, playerContinent, ELO or 0)

		local success, err = pcall(function()
			self:GetQueue(mode, subMode):SetAsync(key, data, QueueManager.Modules.Settings.Matches.MATCHMAKING_DURATION)
		end)

		if success then
			QueueManager.Modules.SharedData.playerQueueKeys[player.UserId] = QueueManager.Modules.SharedData.playerQueueKeys[player.UserId] or {}
			QueueManager.Modules.SharedData.playerQueueKeys[player.UserId][mode] = QueueManager.Modules.SharedData.playerQueueKeys[player.UserId][mode] or {}
			QueueManager.Modules.SharedData.playerQueueKeys[player.UserId][mode][subMode] = key

			if not QueueManager.Modules.SharedData.localQueueCounts[mode] then
				QueueManager.Modules.SharedData.localQueueCounts[mode] = {}
			end
			QueueManager.Modules.SharedData.localQueueCounts[mode][subMode] = (QueueManager.Modules.SharedData.localQueueCounts[mode][subMode] or 0) + 1

			print("Queued player", player.Name, "for", mode, subMode, "mode. Region:", playerContinent)
		else
			warn("Failed to queue player:", err)
            continue
		end
	end
end

-- QueueParty(): Queues a party into matchmaking
-- @param leaderPlayer: The player who created the party
-- @param partyMembers: The party members
-- @param mode: The mode the player should be queued to (Match.QueueManager.Modules.Settings.Modes)
-- @param subMode: The Sub-Mode the player should be queued to (Keys of Match.QueueManager.Modules.Settings.SubModes)
-- @param partyID: The party ID from PartyManager
-- @param ELO?: Optional ELO the player has
function QueueManager:QueueParty(leaderPlayer: Player, partyMembers: { Player }, mode: string, subMode: string, partyID: string, ELO: number?): ()
	assert(#partyMembers > 0, "QueueParty(): Party must have at least one member")
	assert(partyID, "QueueParty(): partyID is required")

	local leaderContinent = QueueManager.Modules.PlayerLocation.GetPlayerContinent(leaderPlayer)

	if not leaderContinent then
		warn(`QueueParty(): Couldn't find {leaderPlayer.Name}'s continent, aborting`)
		return
	end

	local queuedPlayers = {}
	local failedPlayers = {}

	for _, player in { leaderPlayer, table.unpack(partyMembers) } do
		local isLeader = player == leaderPlayer

		local key, data = generatePlayerQueueData(player, partyID, isLeader, leaderContinent, ELO or 0)

		if not data then
			warn(`QueueParty(): Failed to generate data for {player.Name}`)
			table.insert(failedPlayers, player)
			continue
		end

		local success, err = pcall(function()
			self:GetQueue(mode, subMode):SetAsync(key, data, QueueManager.Modules.Settings.Matches.MATCHMAKING_DURATION)
		end)

		if success then
			QueueManager.Modules.SharedData.playerQueueKeys[player.UserId] = QueueManager.Modules.SharedData.playerQueueKeys[player.UserId] or {}
			QueueManager.Modules.SharedData.playerQueueKeys[player.UserId][mode] = QueueManager.Modules.SharedData.playerQueueKeys[player.UserId][mode] or {}
			QueueManager.Modules.SharedData.playerQueueKeys[player.UserId][mode][subMode] = key

			QueueManager.Modules.SharedData.localQueueCounts[mode] = QueueManager.Modules.SharedData.localQueueCounts[mode] or {}
			QueueManager.Modules.SharedData.localQueueCounts[mode][subMode] = (QueueManager.Modules.SharedData.localQueueCounts[mode][subMode] or 0) + 1

			table.insert(queuedPlayers, player)
		else
			warn(`QueueParty(): Failed to queue {player.Name}: {err}`)
			table.insert(failedPlayers, player)
		end
	end

	if #failedPlayers > 0 then
		warn(`QueueParty(): {#failedPlayers} players failed to queue, rolling back party`)

		for _, player in queuedPlayers do
			self:StopQueue(player)
		end

		return
	end

	print((`Queued party led by %s with %d members for %s / %s`):format(
		leaderPlayer.Name,
		#partyMembers,
		mode,
		subMode
	))
end

-- StopQueue(): Removes the player(s) from all queues across every mode and subMode
-- @param playerOrList: The player(s) to remove from queues. Pass a single player or a list of players for bulk removal
-- @return boolean: True if all players were successfully removed from their queues, false if any failures occurred
function QueueManager:StopQueue(playerOrList: Player | { Player }): boolean
	local players: { Player } = typeof(playerOrList) == "Instance" and { playerOrList } or playerOrList :: { Player }
	local allSuccess = true
	local lockMap = self:GetLockMap()

	for _, player in players do
		if not player or not player.UserId then
			allSuccess = false
			continue
		end

		local playerQueues = QueueManager.Modules.SharedData.playerQueueKeys[player.UserId]

		if not playerQueues then
			pcall(function()
				lockMap:RemoveAsync(tostring(player.UserId))
			end)

			QueueManager.Modules.SharedData.playerQueueKeys[player.UserId] = nil

			continue
		end

		for mode, subModes in playerQueues do
			for subMode, keyToRemove in subModes do
				local success = pcall(function()
					self:GetQueue(mode, subMode):RemoveAsync(keyToRemove)
				end)

				if not success then
					warn("Failed to remove from queue:", mode, subMode)
					allSuccess = false
					continue
				end

				if not QueueManager.Modules.SharedData.localQueueCounts[mode] then
					QueueManager.Modules.SharedData.localQueueCounts[mode] = {}
				end
				QueueManager.Modules.SharedData.localQueueCounts[mode][subMode] = math.max(0, (QueueManager.Modules.SharedData.localQueueCounts[mode][subMode] or 0) - 1)
			end
		end

		pcall(function()
			lockMap:RemoveAsync(tostring(player.UserId))
		end)

		QueueManager.Modules.SharedData.playerQueueKeys[player.UserId] = nil
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
	local queues = QueueManager.Modules.SharedData.playerQueueKeys[player.UserId]

	if not queues then
		return false
	end

	if mode and subMode then
		return queues[mode] and queues[mode][subMode] ~= nil
	end

	return next(queues) ~= nil
end

-- GetQueuedPlayers(): Get all of the queued players in a subMode's mode
-- @param mode: The mode the player should be queued to (Match.QueueManager.Modules.Settings.Modes)
-- @param subMode: The Sub-Mode the player should be queued to (Keys of Match.QueueManager.Modules.Settings.SubModes)
-- @return { number }: A list of UserIds of the queued players
function QueueManager:GetQueuedPlayers(mode: string, subMode: string): { number }
	local players = {}
	local queue = self:GetQueue(mode, subMode)
	local matchSize = self:GetMatchSize(subMode)
	local batchSize = math.clamp(matchSize :: number * QueueManager.Modules.Settings.Matches.BATCH_SIZE, 1, 200)

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
		warn("Failed to get queue range for " .. mode .. "-" .. subMode)
	end

	return players
end

-- GetPlayerJoinTime(): Gets the players join time in a subMode's mode
-- @param player: The player to check
-- @param mode: The mode the player should be queued to (Match.QueueManager.Modules.Settings.Modes)
-- @param subMode: The Sub-Mode the player should be queued to (Keys of Match.QueueManager.Modules.Settings.SubModes)
-- @return number?: The join time of the player if found, otherwise nil
function QueueManager:GetPlayerJoinTime(player: Player, mode: string, subMode: string): number?
	local key = QueueManager.Modules.SharedData.playerQueueKeys[player.UserId]
		and QueueManager.Modules.SharedData.playerQueueKeys[player.UserId][mode]
		and QueueManager.Modules.SharedData.playerQueueKeys[player.UserId][mode][subMode]

	if not key then return nil end

	local queue = self:GetQueue(mode, subMode)

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
	if not QueueManager.Modules.SharedData.localQueueCounts[mode] then
		return 0
	end

	return QueueManager.Modules.SharedData.localQueueCounts[mode][subMode] or 0
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

-- GetQueue(): Returns the MemoryStoreService SortedMap based on the mode and subMode
-- @param mode: The mode to get
-- @param subMode: The subMode of the mode
-- @return MemoryStoreSortedMap
function QueueManager:GetQueue(mode: string, subMode: string): MemoryStoreSortedMap
	if not QueueManager.Modules.SharedData.queueCache[mode] then
    	QueueManager.Modules.SharedData.queueCache[mode] = {}
	end

	if not QueueManager.Modules.SharedData.queueCache[mode][subMode] then
		QueueManager.Modules.SharedData.queueCache[mode][subMode] = {
			queue = MemoryStoreService:GetSortedMap("MatchQueue_" .. mode .. "_" .. subMode),
			lastUsed = tick()
		}
	else
		QueueManager.Modules.SharedData.queueCache[mode][subMode].lastUsed = tick()
	end

	return QueueManager.Modules.SharedData.queueCache[mode][subMode].queue
end

-- GetLockMap(): Returns MatchLocks
-- @return MemoryStoreSortedMap
function QueueManager:GetLockMap(): MemoryStoreSortedMap
	if not QueueManager.Modules.SharedData._lockMap then
		QueueManager.Modules.SharedData._lockMap = MemoryStoreService:GetSortedMap("MatchLocks")
	end

	return QueueManager.Modules.SharedData._lockMap :: MemoryStoreSortedMap
end

-- RunHeartbeat(): Runs cache cleanup on heartbeat
function QueueManager:RunHeartbeat(): ()
	local now = tick()

	for mode, subModes in QueueManager.Modules.SharedData.queueCache do
		for subMode, cacheData in subModes do
			if now - cacheData.lastUsed > QueueManager.Modules.Settings.Matches.CACHE_CLEANUP_INTERVAL then
				QueueManager.Modules.SharedData.queueCache[mode][subMode] = nil
			end
		end

		if next(QueueManager.Modules.SharedData.queueCache[mode]) == nil then
			QueueManager.Modules.SharedData.queueCache[mode] = nil
		end
	end

	if QueueManager.Modules.SharedData.crossServerData then
		for mode, subModes in QueueManager.Modules.SharedData.crossServerData do
			for subMode, queueData in subModes do
				local expired = {}

				for serverId, serverData in queueData do
					if now - serverData.Timestamp > QueueManager.Modules.Settings.Matches.CROSS_SERVER_DATA_TTL then
						table.insert(expired, serverId)
					end
				end

				for _, serverId in expired do
					queueData[serverId] = nil
				end

				if not next(queueData) then
					QueueManager.Modules.SharedData.crossServerData[mode][subMode] = nil
				end
			end

			if next(QueueManager.Modules.SharedData.crossServerData[mode]) == nil then
				QueueManager.Modules.SharedData.crossServerData[mode] = nil
			end
		end
	end

	QueueManager.Modules.SharedData.lastCacheCleanup = now
end

--=========================
-- // CLEANUP
--=========================

-- Cleanup(): Cleans up queue-specific data
function QueueManager:Cleanup(): ()
	QueueManager.Modules.SharedData.queueCache = {}
	QueueManager.Modules.SharedData.localQueueCounts = {}
	QueueManager.Modules.SharedData.playerQueueKeys = {}
end

return QueueManager