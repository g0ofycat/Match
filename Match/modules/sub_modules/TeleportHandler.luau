--!strict

local TeleportHandler = {}

--=========================
-- // SERVICES
--=========================

local Players = game:GetService("Players")
local TeleportService = game:GetService("TeleportService")

--=========================
-- // TYPES
--=========================

local Types = require(script.Parent.Parent.helpers.Types)

export type TeleportHandlerT = typeof(TeleportHandler) & {
	[any]: any
}

--=========================
-- // MODULES
--=========================

TeleportHandler.Modules = {
	Settings = require(script.Parent.Parent.helpers.Settings),
	QueueManager = require(script.Parent.QueueManager)
}

--=========================
-- // PUBLIC API
--=========================

-- HandleTeleportRequest(): Handles a teleport request by teleporting players to a reserved private server for a cross-server match, with retries and backoff
-- @param data: Types.TeleportRequestData
function TeleportHandler:HandleTeleportRequest(data: Types.TeleportRequestData): ()
	local serverId = TeleportHandler.Modules.Settings.Information.SERVER_ID
	local playerIds = data.PlayersForServer[serverId]

	if not playerIds then return end

	local playersToTeleport = {}

	for _, userId in playerIds do
		local player = Players:GetPlayerByUserId(userId)

		if player then
			table.insert(playersToTeleport, player)
		end
	end

	if #playersToTeleport == 0 then return end

	print("Teleporting", #playersToTeleport, "players to cross-server match")

	local maxRetries = TeleportHandler.Modules.Settings.Matches.TELEPORT_RETRIES

	for attempt = 1, maxRetries do
		if #playersToTeleport == 0 then return end

		local success, err = pcall(function()
			TeleportService:TeleportToPrivateServer(
				data.PlaceId,
				data.ServerCode,
				playersToTeleport,
				nil,
				{ MatchId = data.MatchId, Mode = data.Mode, SubMode = data.SubMode }
			)
		end)

		if success then
			print(`Successfully teleported {#playersToTeleport} players on attempt {attempt}`)
			return
		else
			print(`Attempt {attempt} failed: {err}, retrying {#playersToTeleport} players`)
		end

		local stillValid = {}

		for _, player in playersToTeleport do
			if player.Parent == Players then
				table.insert(stillValid, player)
			end
		end

		playersToTeleport = stillValid

		if attempt < maxRetries and #playersToTeleport > 0 then
			task.wait(0.5 * (1 + attempt * 0.5))
		end
	end

	if #playersToTeleport > 0 then
		warn(`Failed to teleport {#playersToTeleport} players after {maxRetries} attempts`)

		local failedIds = {}

		for _, p in playersToTeleport do
			table.insert(failedIds, p.UserId)
		end

		self:UnlockPlayers(failedIds)
	end
end

-- ReserveMatchServer(): Reserves a server for the match
-- @return string?: Server code on success, nil on failure
function TeleportHandler:ReserveMatchServer(): string?
	local success, result = pcall(function()
		return TeleportService:ReserveServer(TeleportHandler.Modules.Settings.Information.PLACE_ID)
	end)

	if not success or not result then
		warn("Failed to reserve server:", result)
		return nil
	end

	return result
end

-- UnlockPlayers(): Unlocks players in the lockMap to allow re-queuing or other operations
-- @param playerIds: The UserIDs of players to unlock
function TeleportHandler:UnlockPlayers(playerIds: { number }): ()
	local lockMap = TeleportHandler.Modules.QueueManager:GetLockMap()

	for _, userId in playerIds do
		pcall(function()
			lockMap:RemoveAsync(tostring(userId))
		end)
	end
end

return TeleportHandler :: TeleportHandlerT