--[[
	MIT License

	Copyright © 2025 g0ofycat

	Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

	The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

	THE SOFTWARE IS PROVIDED "AS IS," WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
]]

--!strict

local Match = {}

--=========================
-- // SERVICES
--=========================

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

--=========================
-- // SUB-MODULES
--=========================

local Types = require(script.Parent.modules.sub_modules.Types)
local QueueManager = require(script.Parent.modules.sub_modules.QueueManager)
local CrossServerManager = require(script.Parent.modules.sub_modules.CrossServerManager)
local MatchmakingEngine = require(script.Parent.modules.sub_modules.MatchmakingEngine)
local TeleportHandler = require(script.Parent.modules.sub_modules.TeleportHandler)

--=========================
-- // DATA
--=========================

Match.Data = {
	playerQueueKeys = {}, -- // Stores the timestamp for each player based on their UserId and their modes
	localQueueCounts = {}, -- // Tracks the amount of players in each queue. Stops all MemoryStoreService calls if there's noone in a certain subMode's mode
	isProcessingMatch = {}, -- // Stores booleans for each player
	crossServerData = {}, -- // Stored data from other servers
	matchmakingTasks = {}, -- // Stores all current loops for matchmaking

	queueCache = {}, -- // Stores Match Queue Maps
	messagingConnections = {}, -- // All of the connections used from MessagingService

	lastCacheCleanup = 0,
	heartbeatConnection = nil,
	_lockMap = nil :: MemoryStoreSortedMap? -- // Stores the 'MatchLocks' MemoryStoreSortedMap
} :: Types.MatchData

--=========================
-- // HELPERS
--=========================

Match.Helpers = {
	Settings = require(script.Parent.modules.helpers.Settings), -- // Handles all of the core information like modes, subModes, etc
	PlayerLocation = require(script.Parent.modules.helpers.PlayerLocation) -- // Uses LocalizationService to get a player by their Continent
}

--=========================
-- // INIT
--=========================

QueueManager:Initialize(Match.Data, Match.Helpers :: any)
CrossServerManager:Initialize(Match.Data, Match.Helpers :: any)
MatchmakingEngine:Initialize(Match.Data, Match.Helpers :: any)
TeleportHandler:Initialize(Match.Helpers :: any)

--=========================
-- // MAIN API
--=========================

-- QueuePlayer(): Queues the player(s) up into the matchmaking
-- @param playerOrList: The player(s) to queue. Put a list of players to bulk queue them or just add one player
-- @param mode: The mode the player should be queued to (Match.Helpers.Settings.Modes)
-- @param subMode: The Sub-Mode the player should be queued to (Keys of Match.Helpers.Settings.SubModes)
-- @param ELO?: Optional ELO the player has
function Match:QueuePlayer(playerOrList: Player | { Player }, mode: string, subMode: string, ELO: number?): ()
	QueueManager:QueuePlayer(playerOrList, mode, subMode, ELO)
end

-- StopQueue(): Removes the player(s) from all queues across every mode and subMode
-- @param playerOrList: The player(s) to remove from queues. Pass a single player or a list of players for bulk removal
-- @return boolean: True if all players were successfully removed from their queues, false if any failures occurred
function Match:StopQueue(playerOrList: Player | { Player }): boolean
	return QueueManager:StopQueue(playerOrList)
end

-- MatchMake(): Globally handles and checks all players elligble for Matchmaking based on their Mode and subMode and teleports them
-- @param mode: The mode the player should be queued to (Match.Helpers.Settings.Modes)
-- @param subMode: The Sub-Mode the player should be queued to (Keys of Match.Helpers.Settings.SubModes)
function Match:MatchMake(mode: string, subMode: string): ()
	MatchmakingEngine:MatchMake(mode, subMode)
end

-- StartMatchmaking(): Starts continuous matchmaking loops for all modes and sub-modes; Each loop calls MatchMake at intervals defined by Settings.Matches.CHECK_MATCHMAKING_INTERVALS
function Match:StartMatchmaking(): ()
	MatchmakingEngine:StartMatchmaking()
end

-- StopMatchmaking(): Stops all currently running matchmaking loops that were started with StartMatchmaking; Cancels all tasks and clears the internal task table
function Match:StopMatchmaking(): ()
	MatchmakingEngine:StopMatchmaking()
end

-- RequestCrossServerMatchmaking(): A wrapper for 'MatchmakingRequest' :PublishAsync()
-- @param mode: The mode to request
-- @param subMode: The subMode of the mode
function Match:RequestCrossServerMatchmaking(mode: string, subMode: string): ()
	CrossServerManager:RequestCrossServerMatchmaking(mode, subMode)
end

-- SendQueueStatus(): Sends all of the information in the MemoryStore sorted map and broadcasts it to QueueStatusResponse
-- @param mode: The mode to send
-- @param subMode: The subMode of the mode
-- @param targetServer: The server to send the status to
function Match:SendQueueStatus(mode: string, subMode: string, targetServer: string): ()
	CrossServerManager:SendQueueStatus(mode, subMode, targetServer)
end

-- ReceiveQueueStatus(): Stores the Cross Server data for MessagingService to use and broadcast to servers
-- @param data: QueueStatusResponseData
function Match:ReceiveQueueStatus(data: Types.QueueStatusResponseData): ()
	CrossServerManager:ReceiveQueueStatus(data)
end

-- HandleTeleportRequest(): Handles a teleport request by teleporting players to a reserved private server for a cross-server match, with retries and backoff
-- @param data: The teleport data (includes PlaceId, ServerCode, PlayersForServer, MatchId, Mode, SubMode)
function Match:HandleTeleportRequest(data: Types.TeleportRequestData): ()
	TeleportHandler:HandleTeleportRequest(data)
end

--=========================
-- // MISC
--=========================

-- Cleanup(): Cleans up all caches
function Match:Cleanup()
	CrossServerManager:Cleanup()
	QueueManager:Cleanup()
	MatchmakingEngine:Cleanup()
end

-- IsPlayerQueued(): Checks if a player is queued in a certain subMode's mode
-- @param player: The player to check
-- @param mode: The mode the player should be queued to (Match.Helpers.Settings.Modes)
-- @param subMode: The Sub-Mode the player should be queued to (Keys of Match.Helpers.Settings.SubModes)
-- @return boolean: If the player is queued or not
function Match:IsPlayerQueued(player: Player, mode: string?, subMode: string?): boolean
	return QueueManager:IsPlayerQueued(player, mode, subMode)
end

-- GetQueuedPlayers(): Get all of the queued players in a subMode's mode
-- @param mode: The mode the player should be queued to (Match.Helpers.Settings.Modes)
-- @param subMode: The Sub-Mode the player should be queued to (Keys of Match.Helpers.Settings.SubModes)
-- @return { number }: A list of UserIds of the queued players
function Match:GetQueuedPlayers(mode: string, subMode: string): { number }
	return QueueManager:GetQueuedPlayers(mode, subMode)
end

-- GetPlayerJoinTime(): Gets the players join time in a subMode's mode
-- @param player: The player to check
-- @param mode: The mode the player should be queued to (Match.Helpers.Settings.Modes)
-- @param subMode: The Sub-Mode the player should be queued to (Keys of Match.Helpers.Settings.SubModes)
-- @return number?: The join time of the player if found, otherwise nil
function Match:GetPlayerJoinTime(player: Player, mode: string, subMode: string): number?
	return QueueManager:GetPlayerJoinTime(player, mode, subMode)
end

-- GetQueueCount(): Gets the local queue count in a subMode's mode
-- @param mode: The mode the player should be queued to (Match.Helpers.Settings.Modes)
-- @param subMode: The Sub-Mode the player should be queued to (Keys of Match.Helpers.Settings.SubModes)
-- @return number: The total number of players in the queue
function Match:GetQueueCount(mode: string, subMode: string): number
	return QueueManager:GetQueueCount(mode, subMode)
end

--=========================
-- // CONNECTIONS
--=========================

Players.PlayerRemoving:Connect(function(player)
	if player then
		Match:StopQueue(player)
	end
end)

game:BindToClose(function()
	Match:Cleanup()
end)

Match.Data.heartbeatConnection = RunService.Heartbeat:Connect(function()
	QueueManager:RunHeartbeat()
end)

return Match