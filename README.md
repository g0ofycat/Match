# Match (Roblox)

A customizable matchmaking system for Roblox games with **extremely** easy-to-use API. Handles queueing, grouping, ELO balancing, continent grouping, and cross-server match creation; Handles edge cases well. **(NOTE: Must be used on the server since this uses MemoryStoreService and MessagingService)**

## Features & Design Choices

- **Queue Management (Player, Mode, Sub-Mode)**
- **Dynamic ELO Spread Balancing with Wait-Time Expansion**
- **Continent-Based Player Grouping**
- **Cross-Server Match Creation via MessagingService**
- **Teleport Handling with Retries & Backoff**
- **Safe Player Locking / Unlocking using MemoryStore**
- **Everything is customizable (Check Settings.luau)**

**Example Usage:**

```lua
-- // Start matchmaking loops
Match:StartMatchmaking()

-- // Queue a player with an optional ELO parameter (Player, Mode, SubMode, ELO?)
Match:QueuePlayer(player, "Ranked", "1v1", 1200)

-- // Bulk queue multiple players (all in the same mode/submode, optional shared ELO)
Match:QueuePlayer({player1, player2, player3}, "Ranked", "2v2", 1300)

-- // Stop the queue of a player
Match:StopQueue(player)

-- // Bulk stop the queue of multiple players
Match:StopQueue({player1, player2, player3})

-- // Stop matchmaking loops
Match:StopMatchmaking()
```

# Settings (How to use)

```lua
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
	PRIORITIZE_WAIT_TIME = true, -- // When Continent Matchmaking fails, Matchmaking will be faster for people who have waited longer instead of people with closer ELO

	-- // BATCHING

	BATCH_SIZE = 50, -- // The Batch of the amount of keys fetched from the MemoryStore
	MAX_FINDGROUP_ITERATIONS = 50, -- // Max amount of iterations to find the best group for the player
	MAX_QUEUE_STATUS_PLAYERS = 50, -- // The max amount of players are gotten and sent for each PublishAsync

	-- // LOCKING

	LOCK_TIMEOUT = 10, -- // How long 'Locking' lives before being removed. Locking is a state that tells servers that the player is in a match so the edge case where 2 servers try to match make someone at the same time doesn't happen
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
	["4v4"] = { totalPlayers = 8 },
}

return Settings
```

Most of the *Settings* are self explanitory, this section will mostly be about **Modes** and **SubModes**. You can create new modes by adding their name to **Settings.SubModes**, each mode will have all SubModes inside of them. SubModes are self explanitory, the key is the name of the SubMode and they hold a table which holds a **totalPlayers** variable which will see how many players can be in 1 match. *(e.x. 1v1 has 2 'totalPlayers' since it's a player versus a player)*. **(NOTE: Each Mode and SubMode has a seperate MemoryStoreSortedMap which would look something like: MatchQueue_Casual_1v1)**

*PR's are welcome, let me know if you find any bugs or changes that this project can use!*