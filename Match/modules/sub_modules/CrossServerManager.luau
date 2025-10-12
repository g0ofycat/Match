--!strict

local CrossServerManager = {}

--=========================
-- // SERVICES
--=========================

local Players = game:GetService("Players")
local MessagingService = game:GetService("MessagingService")
local HttpService = game:GetService("HttpService")

--=========================
-- // TYPES
--=========================

local Types = require(script.Parent.Parent.helpers.Types)

export type CrossServerManagerT = typeof(CrossServerManager) & {
	_data: Types.MatchData,
	[any]: any
}

--=========================
-- // MODULES
--=========================

CrossServerManager.Modules = {
	Settings = require(script.Parent.Parent.helpers.Settings),
	TeleportHandler = require(script.Parent.TeleportHandler),
	QueueManager = require(script.Parent.QueueManager)
}

--=========================
-- // INIT
--=========================

-- Initialize(): Init function for this module
-- @param matchData: Types.MatchData
function CrossServerManager:Initialize(matchData: Types.MatchData): ()
	assert(matchData, "[CrossServerManager:Initialize]: 'matchData' is nil")

	self._data = matchData

	self:SetupMessagingService()
end

--=========================
-- // MESSAGING API
--=========================

-- SetupMessagingService(): Sets up the messaging service subscribers
function CrossServerManager:SetupMessagingService(): ()
	for _, c in self._data.messagingConnections do
		c:Disconnect()
	end

	self._data.messagingConnections = {}

	local function subscribe(channel: string, handlerKey: string, handler: ({ Data: Types.MessagedData }) -> ()): ()
		local ok, conn = pcall(function()
			return MessagingService:SubscribeAsync(channel, handler)
		end)

		if ok then
			self._data.messagingConnections[handlerKey] = conn
		end
	end

	local settings = CrossServerManager.Modules.Settings
	local serverId = settings.Information.SERVER_ID

	subscribe("MatchmakingRequest", "matchmakingRequest", function(msg)
		local data = msg.Data

		if data.Mode and data.SubMode and data.RequestingServer ~= serverId then
			task.spawn(function()
				self:SendQueueStatus(data.Mode, data.SubMode, data.RequestingServer)
			end)
		end
	end)

	subscribe("CrossServerTeleport", "crossServerTeleport", function(msg)
		local data = msg.Data

		if data.PlayersForServer and data.PlayersForServer[serverId] then
			task.spawn(function()
				CrossServerManager.Modules.TeleportHandler:HandleTeleportRequest(data)
			end)
		end
	end)

	subscribe("QueueStatusResponse", "queueStatusResponse", function(msg)
		local data = msg.Data

		if data.TargetServer == serverId then
			self:ReceiveQueueStatus(data)
		end
	end)
end

-- RequestCrossServerMatchmaking(): A wrapper for 'MatchmakingRequest' :PublishAsync()
-- @param mode: The mode to request
-- @param subMode: The subMode of the mode
function CrossServerManager:RequestCrossServerMatchmaking(mode: string, subMode: string): ()
	pcall(function()
		MessagingService:PublishAsync("MatchmakingRequest", {
			Mode = mode,
			SubMode = subMode,
			RequestingServer = CrossServerManager.Modules.Settings.Information.SERVER_ID,
			Timestamp = tick()
		})
	end)
end

-- NotifyServersOfMatch(): Notifies all servers about the new match
-- @param code: Reserved server code
-- @param playersByServer: Players organized by server ID
-- @param queueKey: The key of the queue
-- @return boolean: True on success, false on failure
function CrossServerManager:NotifyServersOfMatch(code: string, playersByServer: { [string]: { number } }, queueKey: Types.QueueKey): boolean
	local success, err = pcall(function()
		MessagingService:PublishAsync("CrossServerTeleport", {
			MatchId = CrossServerManager.Modules.Settings.Information.SERVER_ID,
			ServerCode = code,
			PlaceId = CrossServerManager.Modules.Settings.Information.PLACE_ID,
			PlayersForServer = playersByServer,
			Mode = queueKey.Mode,
			SubMode = queueKey.SubMode,
			Timestamp = tick()
		})
	end)

	if not success then
		warn("Failed to notify servers:", err)
		return false
	end

	return true
end

-- SendQueueStatus(): Sends all of the information in the MemoryStore sorted map and broadcasts it to QueueStatusResponse
-- @param mode: The mode to send
-- @param subMode: The subMode of the mode
-- @param targetServer: The server to send the status to
function CrossServerManager:SendQueueStatus(mode: string, subMode: string, targetServer: string): ()
	local queue = CrossServerManager.Modules.QueueManager:GetQueue(mode, subMode)
	local players = {}
	local matchSize = CrossServerManager.Modules.QueueManager:GetMatchSize(subMode)
	local maxPlayersPerQueueStatus = CrossServerManager.Modules.Settings.Matches.MAX_QUEUE_STATUS_PLAYERS or 50
	local maxPlayers = math.clamp(math.min(maxPlayersPerQueueStatus, matchSize * 3), 1, 200)

	local success, result = pcall(function()
		return queue:GetRangeAsync(Enum.SortDirection.Ascending, maxPlayers)
	end)

	if not success or not result then
		pcall(function()
			MessagingService:PublishAsync("QueueStatusResponse", {
				Mode = mode,
				SubMode = subMode,
				TargetServer = targetServer,
				SendingServer = CrossServerManager.Modules.Settings.Information.SERVER_ID,
				Players = {},
				PlayerCount = 0,
				Timestamp = tick()
			})
		end)

		return
	end

	for _, entry in result do
		local dataSuccess, data = pcall(HttpService.JSONDecode, HttpService, entry.value)

		if not dataSuccess or not data then
			continue
		end

		if data.ServerId ~= CrossServerManager.Modules.Settings.Information.SERVER_ID then
			continue
		end

		local player = Players:GetPlayerByUserId(data.UserId)

		if not player then
			continue
		end

		table.insert(players, {
			UserId = data.UserId,
			ELO = data.ELO,
			JoinTime = data.JoinTime,
			QueueKey = {
				Mode = mode,
				SubMode = subMode
			}
		})
	end

	pcall(function()
		MessagingService:PublishAsync("QueueStatusResponse", {
			Mode = mode,
			SubMode = subMode,
			TargetServer = targetServer,
			SendingServer = CrossServerManager.Modules.Settings.Information.SERVER_ID,
			Players = players,
			PlayerCount = #players,
			Timestamp = tick()
		})
	end)
end

-- ReceiveQueueStatus(): Stores the Cross Server data for MessagingService to use and broadcast to servers
-- @param data: Types.QueueStatusResponseData
function CrossServerManager:ReceiveQueueStatus(data: Types.QueueStatusResponseData): ()
	if not self._data.crossServerData[data.Mode] then
		self._data.crossServerData[data.Mode] = {}
	end

	if not self._data.crossServerData[data.Mode][data.SubMode] then
		self._data.crossServerData[data.Mode][data.SubMode] = {}
	end

	self._data.crossServerData[data.Mode][data.SubMode][data.SendingServer] = {
		Players = data.Players,
		Timestamp = data.Timestamp
	}

	local now = tick()

	for serverId, serverData in self._data.crossServerData[data.Mode][data.SubMode] do
		if now - serverData.Timestamp > CrossServerManager.Modules.Settings.Matches.CROSS_SERVER_DATA_TTL then
			self._data.crossServerData[data.Mode][data.SubMode][serverId] = nil
		end
	end
end

--=========================
-- // CLEANUP
--=========================

-- Cleanup(): Cleans up cross-server specific data
function CrossServerManager:Cleanup(): ()
	for _, connection in self._data.messagingConnections do
		pcall(function()
			connection:Disconnect()
		end)
	end

	self._data.messagingConnections = {}

	if self._data.crossServerData then
		self._data.crossServerData = {}
	end
end

return CrossServerManager :: CrossServerManagerT