--[[
	MIT License

	Copyright © 2025 g0ofycat

	Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

	The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

	THE SOFTWARE IS PROVIDED "AS IS," WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
]]

--!strict

local TeleportHandler = {}

--=========================
-- // SERVICES
--=========================

local Players = game:GetService("Players")
local TeleportService = game:GetService("TeleportService")
local MemoryStoreService = game:GetService("MemoryStoreService")

--=========================
-- // TYPES
--=========================

local Types = require("../helpers/Types")

--=========================
-- // MODULES
--=========================

TeleportHandler.Modules = {
	Settings = require("../helpers/Settings"),
	QueueManager = require("./QueueManager")
}

local PreviousMatches = MemoryStoreService:GetSortedMap("PreviousMatches")

--=========================
-- // PUBLIC API
--=========================

-- HandleTeleportRequest(): Handles a teleport request by teleporting players to a reserved private server for a cross-server match, with retries and backoff
-- @param data: Types.TeleportRequestData
function TeleportHandler.HandleTeleportRequest(data: Types.TeleportRequestData): ()
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

	print("HandleTeleportRequest(): Teleporting", #playersToTeleport, "players to cross-server match")

	local maxRetries = TeleportHandler.Modules.Settings.Matches.TELEPORT_RETRIES

	for attempt = 1, maxRetries do
		if #playersToTeleport == 0 then return end

		local success, err = pcall(function()
			TeleportService:TeleportToPrivateServer(
				data.PlaceId,
				data.ServerCode,
				playersToTeleport,
				nil,
				{ MatchId = data.MatchId, Mode = data.Mode, SubMode = data.SubMode, Parties = data.PartyMapping[serverId] }
			)
		end)

		if success then
			print(`HandleTeleportRequest(): Successfully teleported {#playersToTeleport} players on attempt {attempt}`)
			for _, userId in data.PlayersForServer[serverId] do
				PreviousMatches:SetAsync(tostring(userId), {
					MatchId = data.MatchId,
					Mode = data.Mode,
					SubMode = data.SubMode,
					Timestamp = os.time()
				}, TeleportHandler.Modules.Settings.Matches.PREV_MATCHES_TTL)
			end
			return
		else
			print(`HandleTeleportRequest(): Attempt {attempt} failed: {err}, retrying {#playersToTeleport} players`)
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
		warn(`HandleTeleportRequest(): Failed to teleport {#playersToTeleport} players after {maxRetries} attempts`)

		local failedIds = {}

		for _, p in playersToTeleport do
			table.insert(failedIds, p.UserId)
		end

		TeleportHandler.UnlockPlayers(failedIds)
	end
end

-- ReserveMatchServer(): Reserves a server for the match
-- @return string?: Server code on success, nil on failure
function TeleportHandler.ReserveMatchServer(): string?
	local success, result = pcall(function()
		return TeleportService:ReserveServer(TeleportHandler.Modules.Settings.Information.PLACE_ID)
	end)

	if not success or not result then
		warn("ReserveMatchServer(): Failed to reserve server:", result)
		return nil
	end

	return result
end

-- UnlockPlayers(): Unlocks players in the lockMap to allow re-queuing or other operations
-- @param playerIds: The UserIDs of players to unlock
function TeleportHandler.UnlockPlayers(playerIds: { number }): ()
	local lockMap = TeleportHandler.Modules.QueueManager.GetLockMap()

	for _, userId in playerIds do
		pcall(function()
			lockMap:RemoveAsync(tostring(userId))
		end)
	end
end

-- GetPlayerPreviousMatches(): Gets a players previous matches within the PREV_MATCHES_TTL
-- @param player: The player to get previous matches for
-- @return Types.PreviousMatchData?: The previous match data if found, otherwise nil
function TeleportHandler.GetPlayerPreviousMatches(player: Player): Types.PreviousMatchData?
    local success, result = pcall(function()
        return PreviousMatches:GetAsync(tostring(player.UserId))
    end)

    if success and result then
        return result
    end

    return nil
end

return TeleportHandler