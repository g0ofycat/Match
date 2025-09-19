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
-- @param matchData: Match.Data
function CrossServerManager:Initialize(matchData: Types.MatchData): ()
	assert(matchData, "[CrossServerManager:Initialize]: 'matchData' is nil")

	;(self :: any)._data = matchData

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

	local function subscribe(channel: string, handlerKey: string, handler: ({ Data: any }) -> ()): ()
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
		local d = msg.Data
		if d.Mode and d.SubMode and d.RequestingServer ~= serverId then
			task.spawn(function()
				self:SendQueueStatus(d.Mode, d.SubMode, d.RequestingServer)
			end)
		end
	end)

	subscribe("CrossServerTeleport", "crossServerTeleport", function(msg)
		local d = msg.Data
		if d.PlayersForServer and d.PlayersForServer[serverId] then
			task.spawn(function()
				CrossServerManager.Modules.TeleportHandler:HandleTeleportRequest(d)
			end)
		end
	end)

	subscribe("QueueStatusResponse", "queueStatusResponse", function(msg)
		local d = msg.Data
		if d.TargetServer == serverId then
			self:ReceiveQueueStatus(d)
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

-- SendQueueStatus(): Sends all of the information in the MemoryStore sorted map and broadcasts it to QueueStatusResponse
-- @param mode: The mode to send
-- @param subMode: The subMode of the mode
-- @param targetServer: The server to send the status to
function CrossServerManager:SendQueueStatus(mode: string, subMode: string, targetServer: string): ()
	local queue = CrossServerManager.Modules.QueueManager:GetQueue(mode, subMode)
	local players = {}
	local matchSize = CrossServerManager.Modules.QueueManager:GetMatchSize(subMode)
	local maxPlayers = math.min(50, matchSize * 3)

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
		local dataSuccess, data = pcall(function()
			return HttpService:JSONDecode(entry.value)
		end)

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
			QueueKey = entry.key
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
-- @param data: QueueStatusResponseData
function CrossServerManager:ReceiveQueueStatus(data: Types.QueueStatusResponseData): ()
	local queueKey = data.Mode .. "_" .. data.SubMode

	if not self._data.crossServerData[queueKey] then
		self._data.crossServerData[queueKey] = {}
	end

	self._data.crossServerData[queueKey][data.SendingServer] = {
		Players = data.Players,
		Timestamp = data.Timestamp
	}

	local now = tick()

	for serverId, serverData in self._data.crossServerData[queueKey] do
		if now - serverData.Timestamp > CrossServerManager.Modules.Settings.Matches.CROSS_SERVER_DATA_TTL then
			self._data.crossServerData[queueKey][serverId] = nil
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

return CrossServerManager