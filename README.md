# Match (Roblox)

A customizable matchmaking system for Roblox games. Handles queueing, grouping, ELO balancing, continent grouping, and cross-server match creation; Handles edge cases well. **(NOTE: Must be used on the server)**

## Features & Design Choices

- **Queue Management (Player, Mode, Sub-Mode)**
- **Dynamic ELO Spread Balancing with Wait-Time Expansion**
- **Continent-Based Player Grouping**
- **Cross-Server Match Creation via MessagingService**
- **Teleport Handling with Retries & Backoff**
- **Safe Player Locking / Unlocking using MemoryStore**
- **Everything is customizable in Settings.luau**

**Example Usage:**

```lua
-- Start matchmaking loops
Match:StartMatchmaking()

-- Queue a player (Player, ELO, Mode, SubMode)
Match:QueuePlayer(player, 1200, "Ranked", "1v1")

-- Stop matchmaking loops
Match:StopMatchmaking()
```