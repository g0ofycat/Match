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
	SharedData = require(script.Parent.SharedData),
	TeleportHandler = require(script.Parent.TeleportHandler),
	QueueManager = require(script.Parent.QueueManager)
}

--=========================
-- // PUBLIC API
--=========================

-- SetupMessagingService(): Sets up the messaging service subscribers
function CrossServerManager.SetupMessagingService(): ()
	for _, c in CrossServerManager.Modules.SharedData.messagingConnections do
		c:Disconnect()
	end

	CrossServerManager.Modules.SharedData.messagingConnections = {}

	local function subscribe(channel: string, handlerKey: string, handler: ({ Data: any }) -> ()): ()
		local ok, conn = pcall(function()
			return MessagingService:SubscribeAsync(channel, handler)
		end)

		if ok then
			CrossServerManager.Modules.SharedData.messagingConnections[handlerKey] = conn
		end
	end

	local Settings = CrossServerManager.Modules.Settings
	local serverId = Settings.Information.SERVER_ID

	subscribe("CrossServerTeleport", "crossServerTeleport", function(msg)
		local data = msg.Data

		if data.PlayersForServer and data.PlayersForServer[serverId] then
			task.spawn(function()
				CrossServerManager.Modules.TeleportHandler.HandleTeleportRequest(data)
			end)
		end
	end)
end

-- NotifyServersOfMatch(): Notifies all servers about the new match
-- @param code: Reserved server code
-- @param playersByServer: Players organized by server ID
-- @param partyMapping: Party information for each player
-- @param queueKey: The key of the queue
-- @return boolean: True on success, false on failure
function CrossServerManager.NotifyServersOfMatch(code: string, playersByServer: { [string]: { number } }, partyMapping: Types.PartyMap, queueKey: Types.QueueKey): boolean
	local success, err = pcall(function()
		MessagingService:PublishAsync("CrossServerTeleport", {
			MatchId = CrossServerManager.Modules.Settings.Information.SERVER_ID,
			ServerCode = code,
			PlaceId = CrossServerManager.Modules.Settings.Information.PLACE_ID,
			PlayersForServer = playersByServer,
            PartyMapping = partyMapping,
			Mode = queueKey.Mode,
			SubMode = queueKey.SubMode,
			Timestamp = tick()
		})
	end)

	if not success then
		warn("NotifyServersOfMatch(): Failed to notify servers:", err)
		return false
	end

	return true
end

--=========================
-- // CLEANUP
--=========================

-- Cleanup(): Cleans up cross-server specific data
function CrossServerManager.Cleanup(): ()
	for _, connection in CrossServerManager.Modules.SharedData.messagingConnections do
		pcall(function()
			connection:Disconnect()
		end)
	end

	CrossServerManager.Modules.SharedData.messagingConnections = {}
end

--=========================
-- // INIT
--=========================

CrossServerManager.SetupMessagingService()

return CrossServerManager