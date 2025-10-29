--!strict

local Settings = {}

Settings.Matches = {
	-- // MATCHMAKING

	MATCHMAKING_DURATION = 300, -- // How long the player is in matchmaking before removing them
	CHECK_MATCHMAKING_INTERVALS = 5, -- // How fast to check for matches
	CACHE_CLEANUP_INTERVAL = 300, -- // How fast cached data gets cleaned up
	CROSS_SERVER_DATA_TTL = 120, -- // The Lifetime for the cross server data
	TELEPORT_RETRIES = 3, -- // How many times the game tries to teleport you on fail

	-- // ELO SETTINGS

	ELO_CHANGE = 200, -- // How close ELO can be for matchmaking
	ELO_INCREASE_RATE = 50, -- // Higher ELO people may not be put in any matches. Finds more people in range every loop so they can be matchmaked

	-- // BATCHING

	BATCH_SIZE = 50, -- // The Batch of the amount of keys fetched from the MemoryStore
	MAX_QUEUE_STATUS_PLAYERS = 50, -- // The max amount of players are gotten and sent for each PublishAsync

	-- // LOCKING

	LOCK_TIMEOUT = 10 -- // How long 'Locking' lives before being removed. Locking is a state that tells servers that the player is in a match so the edge case where 2 servers try to match make someone at the same time doesn't happen
}

Settings.Information = {
	PLACE_ID = game.PlaceId, -- // The Place ID of where you want the player to go when they're matchmaked
	SERVER_ID = game.JobId
}

Settings.Modes = {"Casual", "Ranked"} -- // Modes act like parents to SubModes

Settings.SubModes = { -- // Names of mode, totalPlayers is how many players can be in that mode. All SubModes are in each Modes
	["1v1"] = { totalPlayers = 2 },
	["2v2"] = { totalPlayers = 4 },
	["3v3"] = { totalPlayers = 6 },
	["4v4"] = { totalPlayers = 8 }
}

table.freeze(Settings)

return Settings