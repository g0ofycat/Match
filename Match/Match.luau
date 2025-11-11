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
-- // PATHS
--=========================

local HelpersPath = script.Parent.modules.helpers
local SubModulesPath = script.Parent.modules.sub_modules

--=========================
-- // TYPES
--=========================

local Types = require(HelpersPath.Types)

--=========================
-- // HELPERS
--=========================

Match.Helpers = {
    Settings = require(HelpersPath.Settings)
}

--=========================
-- // SUB-MODULES
--=========================

Match.SubModules = {
	SharedData = require(SubModulesPath.SharedData),
    QueueManager = require(SubModulesPath.QueueManager),
    CrossServerManager = require(SubModulesPath.CrossServerManager),
    MatchmakingEngine = require(SubModulesPath.MatchmakingEngine),
    PartyManager = require(SubModulesPath.PartyManager),
	Signal = require(HelpersPath.Signal)
}

--=========================
-- // PRIVATE API
--=========================

-- CleanupInit(): Initializes cleanup hooks
local function CleanupInit(): ()
	Players.PlayerRemoving:Connect(function(player)
		if player then
			Match:StopQueue(player)
		end
	end)

	game:BindToClose(function()
		Match:Cleanup()
	end)

	local interval = Match.SubModules.QueueManager.Modules.Settings.Matches.CACHE_CLEANUP_INTERVAL or 60
	local lastTick = tick()

	Match.SubModules.SharedData.heartbeatConnection = RunService.Heartbeat:Connect(function()
		if tick() - lastTick >= interval then
			Match.SubModules.QueueManager:RunHeartbeat()
			lastTick = tick()
		end
	end)
end

--=========================
-- // MAIN API
--=========================

-- QueuePlayer(): Queues the player(s) up into matchmaking
-- @param playerOrList: The player(s) to queue. Put a list of players to bulk queue them or just add one player
-- @param mode: The mode the player should be queued to (Match.QueueManager.Modules.Settings.Modes)
-- @param subMode: The Sub-Mode the player should be queued to (Keys of Match.QueueManager.Modules.Settings.SubModes)
-- @param ELO?: Optional ELO the player has
function Match:QueuePlayer(playerOrList: Player | { Player }, mode: string, subMode: string, ELO: number?): ()
	Match.SubModules.QueueManager:QueuePlayer(playerOrList, mode, subMode, ELO)
end

-- OnMatchmake(): Callback for when matchmaking starts
-- @param functionOrCallback: What to run when the players are matchmaked
function Match:OnMatchmake(functionOrCallback: (matched_players: { Types.ParsedPlayerData }) -> ()): ()
	Match.SubModules.SharedData.signal:Connect(functionOrCallback)
end

-- StopQueue(): Removes the player(s) from all queues across every mode and subMode
-- @param playerOrList: The player(s) to remove from queues. Pass a single player or a list of players for bulk removal
-- @return boolean: True if all players were successfully removed from their queues, false if any failures occurred
function Match:StopQueue(playerOrList: Player | { Player }): boolean
	return Match.SubModules.QueueManager:StopQueue(playerOrList)
end

-- MatchMake(): Globally handles and checks all players eligible for Matchmaking based on their Mode and subMode and teleports them
-- @param mode: The mode the player should be queued to (Match.Helpers.Settings.Modes)
-- @param subMode: The Sub-Mode the player should be queued to (Keys of Match.Helpers.Settings.SubModes)
function Match:MatchMake(mode: string, subMode: string): ()
	Match.SubModules.MatchmakingEngine:MatchMake(mode, subMode)
end

-- StartMatchmaking(): Starts continuous matchmaking loops for all modes and sub-modes; Each loop calls MatchMake at intervals defined by Settings.Matches.CHECK_MATCHMAKING_INTERVALS
function Match:StartMatchmaking(): ()
	Match.SubModules.MatchmakingEngine:StartMatchmaking()
end

-- StopMatchmaking(): Stops all currently running matchmaking loops that were started with StartMatchmaking; Cancels all tasks and clears the internal task table
function Match:StopMatchmaking(): ()
	Match.SubModules.MatchmakingEngine:StopMatchmaking()
end

--=========================
-- // MISC
--=========================

-- IsPlayerQueued(): Checks if a player is queued in a certain subMode's mode
-- @param player: The player to check
-- @param mode: The mode the player should be queued to (Match.Helpers.Settings.Modes)
-- @param subMode: The Sub-Mode the player should be queued to (Keys of Match.Helpers.Settings.SubModes)
-- @return boolean: If the player is queued or not
function Match:IsPlayerQueued(player: Player, mode: string?, subMode: string?): boolean
	return Match.SubModules.QueueManager:IsPlayerQueued(player, mode, subMode)
end

-- GetQueuedPlayers(): Get all of the queued players in a subMode's mode
-- @param mode: The mode the player should be queued to (Match.Helpers.Settings.Modes)
-- @param subMode: The Sub-Mode the player should be queued to (Keys of Match.Helpers.Settings.SubModes)
-- @return { number }: A list of UserIds of the queued players
function Match:GetQueuedPlayers(mode: string, subMode: string): { number }
	return Match.SubModules.QueueManager:GetQueuedPlayers(mode, subMode)
end

-- GetPlayerJoinTime(): Gets the players join time in a subMode's mode
-- @param player: The player to check
-- @param mode: The mode the player should be queued to (Match.Helpers.Settings.Modes)
-- @param subMode: The Sub-Mode the player should be queued to (Keys of Match.Helpers.Settings.SubModes)
-- @return number?: The join time of the player if found, otherwise nil
function Match:GetPlayerJoinTime(player: Player, mode: string, subMode: string): number?
	return Match.SubModules.QueueManager:GetPlayerJoinTime(player, mode, subMode)
end

-- GetQueueCount(): Gets the local queue count in a subMode's mode
-- @param mode: The mode the player should be queued to (Match.Helpers.Settings.Modes)
-- @param subMode: The Sub-Mode the player should be queued to (Keys of Match.Helpers.Settings.SubModes)
-- @return number: The total number of players in the queue
function Match:GetQueueCount(mode: string, subMode: string): number
	return Match.SubModules.QueueManager:GetQueueCount(mode, subMode)
end

--=========================
-- // CLEANUP
--=========================

-- Cleanup(): Cleans up all caches
function Match:Cleanup()
	Match.SubModules.CrossServerManager:Cleanup()
	Match.SubModules.QueueManager:Cleanup()
	Match.SubModules.MatchmakingEngine:Cleanup()
end

CleanupInit()

return Match