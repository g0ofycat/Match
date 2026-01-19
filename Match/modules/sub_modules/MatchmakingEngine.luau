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
function MatchmakingEngine.CanStartMatchmaking(queueKey: Types.QueueKey): boolean
	if not MatchmakingEngine.Modules.SharedData.isProcessingMatch[queueKey.Mode] then
		MatchmakingEngine.Modules.SharedData.isProcessingMatch[queueKey.Mode] = {}
	end

	if MatchmakingEngine.Modules.SharedData.isProcessingMatch[queueKey.Mode][queueKey.SubMode] then
		return false
	end

	local matchSize = MatchmakingEngine.Modules.QueueManager.GetMatchSize(queueKey.SubMode)

	if matchSize % 2 ~= 0 then
		warn("CanStartMatchmaking(): Invalid match size for", queueKey.SubMode, "- must be even number")
		return false
	end

	return true
end

-- ProcessMatchmaking(): Wrapper for multiple functions, Processes matchmaking
-- @param queueKey: The key of the queue
function MatchmakingEngine.ProcessMatchmaking(queueKey: Types.QueueKey): ()
	local allPlayers = MatchmakingEngine.CollectPlayers(queueKey)

	if not allPlayers or #allPlayers == 0 or #allPlayers < MatchmakingEngine.Modules.QueueManager.GetMatchSize(queueKey.SubMode) then
		return
	end

	local bestGroup = MatchmakingEngine.FindOptimalPlayerGroup(allPlayers, queueKey.SubMode)

	if bestGroup then
		MatchmakingEngine.CreateCrossServerMatch(bestGroup, queueKey)
	else
		warn("ProcessMatchmaking(): No optimal group found for", queueKey.Mode, queueKey.SubMode)
	end
end

-- CollectPlayers(): Collects all of the players for matchmaking
-- @param queueKey: The key of the queue
-- @return { Types.ParsedPlayerData }
function MatchmakingEngine.CollectPlayers(queueKey: Types.QueueKey): { Types.ParsedPlayerData }
	if not MatchmakingEngine.Modules.SharedData.localQueueCounts[queueKey.Mode] or not MatchmakingEngine.Modules.SharedData.localQueueCounts[queueKey.Mode][queueKey.SubMode] or MatchmakingEngine.Modules.SharedData.localQueueCounts[queueKey.Mode][queueKey.SubMode] == 0 then
		return {}
	end

	local allPlayers: { Types.ParsedPlayerData } = {}
	local queue = MatchmakingEngine.Modules.QueueManager.GetQueue(queueKey.Mode, queueKey.SubMode)
	local batchSize = math.clamp(MatchmakingEngine.Modules.QueueManager.GetMatchSize(queueKey.SubMode) * MatchmakingEngine.Modules.Settings.Matches.BATCH_SIZE, 1, 200)

	print("CollectPlayers(): Processing matchmaking: Found", MatchmakingEngine.Modules.SharedData.localQueueCounts[queueKey.Mode][queueKey.SubMode], "total players for", queueKey.Mode, queueKey.SubMode)

	local success, result = pcall(function()
		return queue:GetRangeAsync(Enum.SortDirection.Ascending, batchSize)
	end)

	if success and type(result) == "table" then
		for _, entry in result do
			local playerData = MatchmakingEngine.ParseQueueEntry(entry, queueKey)

			if playerData then
				table.insert(allPlayers, playerData)
			end
		end
	else
		warn("CollectPlayers(): Failed to collect players from queue:", queueKey.Mode, queueKey.SubMode)
	end

	return allPlayers
end

-- ParseQueueEntry(): Returns the JSON decoded entry safely
-- @param entry: The entry
-- @param queueKey: Types.QueueKey
-- @return Types.ParsedPlayerData
function MatchmakingEngine.ParseQueueEntry(entry: { key: string, value: Types.PlayerQueueData }, queueKey: Types.QueueKey): Types.ParsedPlayerData
	local success, data = pcall(HttpService.JSONDecode, HttpService, entry.value)

	if not success or not data or not data.UserId or not data.ELO then
		error("ParseQueueEntry(): Failed to parse queue entry: " .. entry.key)
	end

	return {
        PartyID = data.PartyID,
        IsPartyLeader = data.IsPartyLeader,
		UserId = data.UserId,
		ELO = data.ELO,
		JoinTime = data.JoinTime,
		QueueKey = queueKey,
		MemoryStoreKey = entry.key,
		ServerId = data.ServerId,
		Continent = data.Continent
	}
end

-- FindOptimalPlayerGroup(): Main entry point for match formation
-- @param allPlayers: { Types.ParsedPlayerData }
-- @param subMode: string
-- @return { Types.ParsedPlayerData }?
function MatchmakingEngine.FindOptimalPlayerGroup(allPlayers: { Types.ParsedPlayerData }, subMode: string): { Types.ParsedPlayerData }?
	local matchSize = MatchmakingEngine.Modules.QueueManager.GetMatchSize(subMode)

	if #allPlayers < matchSize then
		return nil
	end

	local units = MatchmakingEngine.CreateMatchmakingUnits(allPlayers)

	local continentGroups = MatchmakingEngine.GroupUnitsByContinent(units)

	local sortedContinents = {}

	for continent, continentUnits in continentGroups do
		local totalPlayers = 0
		for _, unit in continentUnits do
			totalPlayers += #unit
		end

		if totalPlayers >= matchSize then
			table.insert(sortedContinents, {
				continent = continent,
				units = continentUnits,
				playerCount = totalPlayers
			})
		end
	end

	table.sort(sortedContinents, function(a, b)
		return a.playerCount > b.playerCount
	end)

	for _, group in sortedContinents do
		local match = MatchmakingEngine.FormMatchFromUnits(group.units, matchSize)

		if match then
			return match
		end
	end

	return MatchmakingEngine.FormMatchFromUnits(units, matchSize)
end

-- IsGroupValid(): Validates whether a matchmaking group meets ELO spread requirements for all players each player has a dynamic allowed spread based on their queue wait time
-- @param group: { Types.ParsedPlayerData }
-- @param actualSpread: The ELO difference between highest and lowest ELO players in the group
-- @param currentTime: Current timestamp used to calculate wait times
-- @return boolean: True if all players in the group accept the current ELO spread, false otherwise
function MatchmakingEngine.IsGroupValid(group: { Types.ParsedPlayerData }, actualSpread: number, currentTime: number): boolean
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
function MatchmakingEngine.CreateCrossServerMatch(players: { Types.ParsedPlayerData }, queueKey: Types.QueueKey): boolean
	if not players or #players == 0 then
		warn("CreateCrossServerMatch(): No players provided for match creation")
		return false
	end

	print("CreateCrossServerMatch(): Creating cross-server match with", #players, "players for", queueKey.Mode, queueKey.SubMode)

	local lockedPlayerIds = MatchmakingEngine.LockAllPlayers(players)

	if not lockedPlayerIds then
		return false
	end

	local code = MatchmakingEngine.Modules.TeleportHandler.ReserveMatchServer()

	if not code then
		MatchmakingEngine.Modules.TeleportHandler.UnlockPlayers(lockedPlayerIds)
		return false
	end

	local playersByServer, partyMapping, removalFailures, localPlayersRemoved = MatchmakingEngine.ProcessPlayerRemoval(players, queueKey)

	MatchmakingEngine.UpdateLocalQueueCount(localPlayersRemoved, queueKey)

	if removalFailures > 0 then
		warn("CreateCrossServerMatch():", removalFailures, "queue removal failures occurred")
	end

	local notifySuccess = MatchmakingEngine.Modules.CrossServerManager.NotifyServersOfMatch(code, playersByServer, partyMapping, queueKey)

	if not notifySuccess then
		MatchmakingEngine.Modules.TeleportHandler.UnlockPlayers(lockedPlayerIds)
		return false
	end

	print("CreateCrossServerMatch(): Successfully created cross-server match", MatchmakingEngine.Modules.Settings.Information.SERVER_ID)

	MatchmakingEngine.Modules.SharedData.signal:Fire(players)

	return true
end

-- LockAllPlayers(): Attempts to lock all players for the match
-- @param players: { Types.ParsedPlayerData }
-- @return { number }?: Array of locked player IDs on success, nil on failure
function MatchmakingEngine.LockAllPlayers(players: { Types.ParsedPlayerData }): { number }?
	local lockMap = MatchmakingEngine.Modules.QueueManager.GetLockMap()
	local lockedPlayerIds = {}

	for _, playerData in players do
		if not playerData.UserId then
			warn("LockAllPlayers(): Invalid player data missing UserId")
			MatchmakingEngine.Modules.TeleportHandler.UnlockPlayers(lockedPlayerIds)
			return nil
		end

		local success, result = pcall(function()
			return lockMap:UpdateAsync(
				tostring(playerData.UserId),
				function(oldData): any
					if oldData and oldData.Status == "InMatch" then
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

		if not success or not result then
			warn("LockAllPlayers(): Failed to lock player", playerData.UserId, ":", result)

			MatchmakingEngine.Modules.TeleportHandler.UnlockPlayers(lockedPlayerIds)

			return nil
		end

		table.insert(lockedPlayerIds, playerData.UserId)
	end

	return lockedPlayerIds
end

-- ProcessPlayerRemoval(): Removes players from queue and organizes them by server WITH party info
-- @param players: { Types.ParsedPlayerData }
-- @param queueKey: Types.QueueKey
-- @return ({ [string]: { number } }, Types.PartyMap, number): Players by server, party mapping, removal failures, local players removed
function MatchmakingEngine.ProcessPlayerRemoval(players: { Types.ParsedPlayerData }, queueKey: Types.QueueKey): ({ [string]: { number } }, Types.PartyMap, number, number)
	local playersByServer = {}
    local partyMapping: Types.PartyMap = {}
	local removalFailures = 0
	local localPlayersRemoved = 0
	local queue = MatchmakingEngine.Modules.QueueManager.GetQueue(queueKey.Mode, queueKey.SubMode)

	for _, playerData in players do
		local success, err = pcall(function()
			queue:RemoveAsync(playerData.MemoryStoreKey)
		end)

		if not success then
			removalFailures += 1
			warn("ProcessPlayerRemoval(): Failed to remove player from queue:", playerData.UserId, err)
			continue
		end

		local originServerId = playerData.ServerId
		local serverId = playerData.ServerId
        local partyId = playerData.PartyID

		playersByServer[originServerId] = playersByServer[originServerId] or {}
		table.insert(playersByServer[originServerId], playerData.UserId)

		if partyId then
			partyMapping[serverId] = partyMapping[serverId] or {}
			partyMapping[serverId][partyId] = partyMapping[serverId][partyId] or { Members = {}, Leader = nil }

			table.insert(partyMapping[serverId][partyId].Members, playerData.UserId)

			if playerData.IsPartyLeader then
				partyMapping[serverId][partyId].Leader = playerData.UserId
			end
		end

		if originServerId ~= MatchmakingEngine.Modules.Settings.Information.SERVER_ID then
			continue
		end

		local player = Players:GetPlayerByUserId(playerData.UserId)

		if not player or not MatchmakingEngine.Modules.SharedData.playerQueueKeys[playerData.UserId] then
			continue
		end

		if not MatchmakingEngine.Modules.SharedData.playerQueueKeys[playerData.UserId][queueKey.Mode] then
			continue
		end

		localPlayersRemoved += 1

		MatchmakingEngine.Modules.SharedData.playerQueueKeys[playerData.UserId][queueKey.Mode][queueKey.SubMode] = nil

		if next(MatchmakingEngine.Modules.SharedData.playerQueueKeys[playerData.UserId][queueKey.Mode]) == nil then
			MatchmakingEngine.Modules.SharedData.playerQueueKeys[playerData.UserId][queueKey.Mode] = nil
		end

		if next(MatchmakingEngine.Modules.SharedData.playerQueueKeys[playerData.UserId]) == nil then
			MatchmakingEngine.Modules.SharedData.playerQueueKeys[playerData.UserId] = nil
		end
	end

	return playersByServer, partyMapping, removalFailures, localPlayersRemoved
end

-- UpdateLocalQueueCount(): Updates the local queue count after match creation
-- @param localPlayersRemoved: number
-- @param queueKey: Types.QueueKey
function MatchmakingEngine.UpdateLocalQueueCount(localPlayersRemoved: number, queueKey: Types.QueueKey): ()
	MatchmakingEngine.Modules.SharedData.localQueueCounts[queueKey.Mode][queueKey.SubMode] = math.max(0, (MatchmakingEngine.Modules.SharedData.localQueueCounts[queueKey.Mode][queueKey.SubMode] or 0) - localPlayersRemoved)
end

--=========================
-- // UNIT API
--=========================

-- CreateMatchmakingUnits(): Groups players into units with validation
-- @param players: { Types.ParsedPlayerData }
-- @return { { Types.ParsedPlayerData } }
function MatchmakingEngine.CreateMatchmakingUnits(players: { Types.ParsedPlayerData }): { { Types.ParsedPlayerData } }
	local parties: { [string]: { Types.ParsedPlayerData } } = {}
	local partyLeaders: { [string]: boolean } = {}
	local solos = {}

	for _, player in players do
		if player.PartyID then
			parties[player.PartyID] = parties[player.PartyID] or {}
			table.insert(parties[player.PartyID], player)

			if player.IsPartyLeader then
				partyLeaders[player.PartyID] = true
			end
		else
			table.insert(solos, { player })
		end
	end

	local units = {}

	for partyId, party in parties do
		if not partyLeaders[partyId] then
			warn(`CreateMatchmakingUnits(): Party {partyId} missing leader, splitting into solos`)
			for _, player in party do
				table.insert(units, { player })
			end
		else
			table.insert(units, party)
		end
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
function MatchmakingEngine.FormMatchFromUnits(units: { { Types.ParsedPlayerData } }, matchSize: number): { Types.ParsedPlayerData }?
	if #units == 0 then return nil end

	local maxPartySize = math.floor(matchSize / 2)
	local validUnits = {}

	for _, unit in units do
		if #unit <= maxPartySize then
			table.insert(validUnits, unit)
		end
	end

	if #validUnits == 0 then return nil end

	table.sort(validUnits, function(a, b)
		return MatchmakingEngine.GetAverageJoinTime(a) < MatchmakingEngine.GetAverageJoinTime(b) :: number
	end)

	for startIdx = 1, #validUnits do
		local match = MatchmakingEngine.BuildMatchFromSeed(validUnits, startIdx, matchSize)

		if match then
			return match
		end
	end

    warn(`FormMatchFromUnits(): No valid match formed from {#validUnits} units for {matchSize}-player match`)

	return nil
end

-- BuildMatchFromSeed(): Build a match starting from a seed unit
-- @param units: { { Types.ParsedPlayerData } }
-- @param seedIdx: Index of the seed unit
-- @param matchSize: number
-- @return { Types.ParsedPlayerData }?
function MatchmakingEngine.BuildMatchFromSeed(units: { { Types.ParsedPlayerData } }, seedIdx: number, matchSize: number): { Types.ParsedPlayerData }?
	local seedUnit = units[seedIdx]
	local currentMatch = {}
	local currentTime = tick()

	for _, player in seedUnit do
		table.insert(currentMatch, player)
	end

	local oldestJoinTime = math.huge

	for _, player in seedUnit do
		oldestJoinTime = math.min(oldestJoinTime, player.JoinTime or currentTime)
	end

	local seedWaitTime = currentTime - oldestJoinTime
    local allowedSpread = MatchmakingEngine.GetMaxSpreadForWaitTime(seedWaitTime) :: number

	local seedELO = MatchmakingEngine.GetAverageELO(seedUnit)

	local candidates = {}

	for i, unit in units do
		if i == seedIdx then continue end

		local avgELO = MatchmakingEngine.GetAverageELO(unit) :: number
		local eloDiff = math.abs(avgELO - seedELO)

		if eloDiff <= allowedSpread * 2 then
			table.insert(candidates, {
				unit = unit,
				index = i,
				eloDiff = eloDiff,
				size = #unit
			})
		end
	end

	table.sort(candidates, function(a, b)
		return a.eloDiff < b.eloDiff
	end)

	for _, candidate in candidates do
		if #currentMatch + candidate.size > matchSize then
			continue
		end

		for _, player in candidate.unit do
			table.insert(currentMatch, player)
		end

		if #currentMatch == matchSize then
			if MatchmakingEngine.IsMatchValid(currentMatch) then
				return currentMatch
			else
				for _ = 1, candidate.size do
					table.remove(currentMatch)
				end
			end
		end
	end

	return nil
end

-- GroupUnitsByContinent(): Group units by continent
-- @param units: { { Types.ParsedPlayerData } }
-- @return { [string]: { { Types.ParsedPlayerData } } }
function MatchmakingEngine.GroupUnitsByContinent(units: { { Types.ParsedPlayerData } }): { [string]: { { Types.ParsedPlayerData } } }
	local groups = {}

	for _, unit in units do
		local continent = nil

		for _, player in unit do
			if player.IsPartyLeader then
				continent = player.Continent
				break
			end
		end

		continent = continent or unit[1].Continent or "Unknown"

		groups[continent] = groups[continent] or {}
		table.insert(groups[continent], unit)
	end

	return groups
end

-- GetAverageJoinTime(): Gets average join time for a unit
-- @param unit: { Types.ParsedPlayerData }
-- @return number
function MatchmakingEngine.GetAverageJoinTime(unit: { Types.ParsedPlayerData }): number
	local sum = 0

	for _, player in unit do
		sum += player.JoinTime or 0
	end

	return sum / #unit
end

-- GetAverageELO(): Get the average ELO on a unit
-- @param unit: { Types.ParsedPlayerData }
-- @return number
function MatchmakingEngine.GetAverageELO(unit: { Types.ParsedPlayerData }): number
	local sum = 0

	for _, player in unit do
		sum += player.ELO or 1000
	end

	return sum / #unit
end

-- GetMaxSpreadForWaitTime(): Calculate max allowed ELO spread based on wait time
-- @param waitTime: Seconds waited
-- @return number
function MatchmakingEngine.GetMaxSpreadForWaitTime(waitTime: number): number
	local baseSpread = MatchmakingEngine.Modules.Settings.Matches.ELO_CHANGE or 200
	local increaseRate = MatchmakingEngine.Modules.Settings.Matches.ELO_INCREASE_RATE or 5

	return baseSpread + (waitTime * increaseRate)
end

-- IsMatchValid(): Validate complete match
-- @param players: { Types.ParsedPlayerData }
-- @return boolean
function MatchmakingEngine.IsMatchValid(players: { Types.ParsedPlayerData }): boolean
	table.sort(players, function(a, b) return a.ELO < b.ELO end)

	local minELO = players[1].ELO
	local maxELO = players[#players].ELO
	local actualSpread = maxELO - minELO
	local currentTime = tick()

	return MatchmakingEngine.IsGroupValid(players, actualSpread, currentTime)
end

--=========================
-- // PUBLIC API
--=========================

-- MatchMake(): Globally handles and checks all players eligible for Matchmaking based on their Mode and subMode and teleports them
-- @param mode: The mode the player should be queued to (Match.Modules.MatchmakingEngine.Modules.Settings.Modes)
-- @param subMode: The Sub-Mode the player should be queued to (Keys of Match.Modules.MatchmakingEngine.Modules.Settings.SubModes)
function MatchmakingEngine.MatchMake(mode: string, subMode: string): ()
	local queueKey = {
		Mode = mode,
		SubMode = subMode
	}

	if not MatchmakingEngine.CanStartMatchmaking(queueKey) then
		return
	end

	if not MatchmakingEngine.Modules.SharedData.isProcessingMatch[queueKey.Mode] then
		MatchmakingEngine.Modules.SharedData.isProcessingMatch[queueKey.Mode] = {}
	end

	MatchmakingEngine.Modules.SharedData.isProcessingMatch[queueKey.Mode][queueKey.SubMode] = true

	local function errHandler(err)
		warn("MatchMake(): Matchmaking error:", err, debug.traceback())
	end

	xpcall(function()
		MatchmakingEngine.ProcessMatchmaking(queueKey)
	end, errHandler)

	MatchmakingEngine.Modules.SharedData.isProcessingMatch[queueKey.Mode][queueKey.SubMode] = false
end

-- StartMatchmaking(): Starts continuous matchmaking loops for all modes and sub-modes; Each loop calls MatchMake at intervals defined by MatchmakingEngine.Modules.Settings.Matches.CHECK_MATCHMAKING_INTERVALS
function MatchmakingEngine.StartMatchmaking(): ()
	for _, mode in MatchmakingEngine.Modules.Settings.Modes do
		for subModeKey, _ in MatchmakingEngine.Modules.Settings.SubModes do
            local subMode = subModeKey :: string
            MatchmakingEngine.CreateMatchmakingThread(mode, subMode)
        end
	end
end

-- CreateMatchmakingThread(): Creates and starts a matchmaking thread for a specific game mode combination
-- @param mode: The main game mode (e.g., "Ranked", "Casual")
-- @param subMode: The sub-mode variant (e.g., "1v1", "2v2", "4v4")
function MatchmakingEngine.CreateMatchmakingThread(mode: string, subMode: string): ()
	local thread = task.spawn(function()
		MatchmakingEngine.RunMatchmakingLoop(mode, subMode)
	end)

	if not MatchmakingEngine.Modules.SharedData.matchmakingTasks[mode] then
		MatchmakingEngine.Modules.SharedData.matchmakingTasks[mode] = {}
	end

	MatchmakingEngine.Modules.SharedData.matchmakingTasks[mode][subMode] = thread
end

-- RunMatchmakingLoop(): Runs the continuous matchmaking loop for a specific mode/subMode combination
-- @param mode: The main game mode to process
-- @param subMode: The sub-mode variant to process
function MatchmakingEngine.RunMatchmakingLoop(mode: string, subMode: string): ()
	while true do
		task.wait(MatchmakingEngine.Modules.Settings.Matches.CHECK_MATCHMAKING_INTERVALS)

		local success, err = pcall(function()
			MatchmakingEngine.MatchMake(mode, subMode)
		end)

		if not success then
			warn(`RunMatchmakingLoop(): Matchmaking error for {mode} {subMode}:`, err)
		end
	end
end

-- StopMatchmaking(): Stops all currently running matchmaking loops that were started with StartMatchmaking; Cancels all tasks and clears the internal task table
function MatchmakingEngine.StopMatchmaking(): ()
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
function MatchmakingEngine.Cleanup(): ()
	MatchmakingEngine.Modules.SharedData.isProcessingMatch = {}
end

return MatchmakingEngine