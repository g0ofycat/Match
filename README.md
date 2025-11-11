# Match (Roblox)

A customizable matchmaking system for Roblox games with **extremely** easy-to-use API. Handles queueing, grouping, ELO balancing, continent grouping, and cross-server match creation; Handles edge cases well. **(NOTE: Must be used on the server since this uses MemoryStoreService and MessagingService; The print statements from matchmaking use the local queue count since you don't want to use MemoryStore calls on prints)**

## Features & Design Choices

- **Queue Management (Player, Mode, Sub-Mode)**
- **Party System (EXPERIMENTAL)**
- **Dynamic ELO Spread Balancing with Wait-Time Expansion**
- **Continent-Based Player Grouping**
- **Cross-Server Match Creation via MessagingService**
- **Teleport Handling with Retries & Backoff**
- **Safe Player Locking / Unlocking using MemoryStore**
- **Everything is customizable (Check Settings.luau)**

**Basic Example Usage:**

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

-- // Function to run when matchmaking finds all players
Match:OnMatchmake(function(matched_players)
	print("Matchmaking complete!")

	print(matched_players) -- // { Types.ParsedPlayerData }
end)
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
```

Most of the *Settings* are self explanitory, this section will mostly be about **Modes** and **SubModes**. You can create new modes by adding their name to **Settings.SubModes**, each mode will have all SubModes inside of them. SubModes are self explanitory, the key is the name of the SubMode and they hold a table which holds a **totalPlayers** variable which will see how many players can be in 1 match. *(e.x. 1v1 has 2 'totalPlayers' since it's a player versus a player)*.

**(NOTE: Each Mode and SubMode has a seperate MemoryStoreSortedMap which would look something like: MatchQueue_Casual_1v1)**

# Party System

You can access the **Party API** with **Match.Modules.PartyManager**. It includes all of the basic operations for party handling.

**Basic Example Usage:**

```lua

local Members = { game.Players.Player1, game.Players.Player2 }

-- // Create a party
Match.Modules.PartyManager.CreateParty(game.Players.LeaderPlayer, Members)

-- // Add a new member
Match.Modules.PartyManager.AddPlayer(game.Players.LeaderPlayer, game.Players.Player3)

-- // Remove a member
Match.Modules.PartyManager.RemovePlayer(game.Players.LeaderPlayer, game.Players.Player2)

-- // Queue the party for a game mode (ELO should usually be the leaders ELO)
Match.Modules.PartyManager.QueueParty(game.Players.LeaderPlayer, "Casual", "2v2", 1000)

-- // Stop queueing the party
Match.Modules.PartyManager.StopParty(game.Players.LeaderPlayer)

-- // Delete the party
Match.Modules.PartyManager.DeleteParty(game.Players.LeaderPlayer)
```

# **Receiving data**

The following data is sent when players are teleported:

```lua
{ MatchId = data.MatchId, Mode = data.Mode, SubMode = data.SubMode, Parties = data.PartyMapping[serverId] }
```

The others are self explanitory. Although to set up teams for partied players, you can just check the **Parties** table.

**Table Format:**

```lua
export type Parties = {
    [string]: {
        Members: { number },
        Leader: number?
    }
}
```

You can easily convert the **Parties** table into actual teams by using **Match.Modules.PartyManager.CreateTeamsFromPartyMap(Parties)**

*PR's are welcome, let me know if you find any bugs or changes that this project can use!*