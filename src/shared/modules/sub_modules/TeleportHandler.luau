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
-- @param data: The teleport data (includes PlaceId, ServerCode, PlayersForServer, MatchId, Mode, SubMode)
function TeleportHandler:HandleTeleportRequest(data: Types.TeleportRequestData): ()
	local playersToTeleport = {}
	local playerIds = data.PlayersForServer[TeleportHandler.Modules.Settings.Information.SERVER_ID]
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
	local maxRetries = TeleportHandler.Modules.Settings.Matches.TELEPORT_RETRIES

	for attempt = 1, maxRetries do
		if #playersToRetry == 0 then break end

		local success = pcall(function()
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

		local originalPlayerIds = data.PlayersForServer[TeleportHandler.Modules.Settings.Information.SERVER_ID]

		if originalPlayerIds then
			self:UnlockPlayers(originalPlayerIds)
		end
	end
end

-- UnlockPlayers(): Unlocks players in the lockMap to allow re-queuing or other operations
-- @param playerIds: The user IDs of players to unlock
function TeleportHandler:UnlockPlayers(playerIds: { number }): ()
	local lockMap = TeleportHandler.Modules.QueueManager:GetLockMap()

	for _, userId in playerIds do
		pcall(function()
			lockMap:RemoveAsync(tostring(userId))
		end)
	end
end

return TeleportHandler