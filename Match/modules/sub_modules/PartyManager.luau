--!strict

local PartyManager = {}

--=========================
-- // SERVICES
--=========================

local Players = game:GetService("Players")

--=========================
-- // TYPES
--=========================

local Types = require(script.Parent.Parent.helpers.Types)

--=========================
-- // MODULES
--=========================

PartyManager.Modules = {
	QueueManager = require(script.Parent.QueueManager)
}

--=========================
-- // DATA
--=========================

PartyManager.Parties = {}

PartyManager.PlayerLookup = {}

--=========================
-- // PRIVATE API
--=========================

-- SetupPlayerLookup(): Maintains a lookup table of UserId -> Player
local function SetupPlayerLookup(): ()
    Players.PlayerAdded:Connect(function(player)
        PartyManager.PlayerLookup[player.UserId] = player
    end)

    Players.PlayerRemoving:Connect(function(player)
        PartyManager.PlayerLookup[player.UserId] = nil
    end)
end

-- CleanupInit(): Handle players leaving if they're a party leader
local function CleanupInit(): ()
    Players.PlayerRemoving:Connect(function(player)
        if not PartyManager.Parties[player] then return end

        PartyManager.DeleteParty(player)
    end)
end

--=========================
-- // PUBLIC API
--=========================

-- CreateParty(): Creates a party
-- @param LeaderPlayer: The player who created the party
-- @param Members: The members of the party
function PartyManager.CreateParty(LeaderPlayer: Player, Members: { Player }): ()
    PartyManager.Parties[LeaderPlayer] = Members
end

-- QueueParty(): Queues all members of a party
-- @param LeaderPlayer: The player who created the party
-- @param mode: The mode the player should be queued to
-- @param subMode: The Sub-Mode the player should be queued to
-- @param ELO?: Optional ELO the party has
function PartyManager.QueueParty(LeaderPlayer: Player, mode: string, subMode: string, ELO: number?): ()
    if not PartyManager.Parties[LeaderPlayer] then
        warn("QueueParty(): LeaderPlayer not found")
        return
    end

    PartyManager.Modules.QueueManager:QueueParty(LeaderPlayer, PartyManager.Parties[LeaderPlayer], mode, subMode, ELO)
end

-- StopParty(): Stop queues all members of a party
-- @param LeaderPlayer: The player who created the party
function PartyManager.StopParty(LeaderPlayer: Player): ()
    if not PartyManager.Parties[LeaderPlayer] then
        warn("StopParty(): LeaderPlayer not found")
        return
    end

    PartyManager.Modules.QueueManager:StopQueue({ LeaderPlayer, table.unpack(PartyManager.Parties[LeaderPlayer]) })
end

-- DeleteParty(): Deletes a party, also stopping everyone currently queueing (Including the leader)
-- @param LeaderPlayer: The player who created the party
function PartyManager.DeleteParty(LeaderPlayer: Player): ()
    if not PartyManager.Parties[LeaderPlayer] then
        warn("DeleteParty(): LeaderPlayer not found")
        return
    end

    PartyManager.Modules.QueueManager:StopQueue({ LeaderPlayer, table.unpack(PartyManager.Parties[LeaderPlayer]) })

    PartyManager.Parties[LeaderPlayer] = nil
end

--=========================
-- // MEMBER API
--=========================

-- AddPlayer(): Adds a player to a leaders party
-- @param LeaderPlayer: The player who created the party
-- @param NewMember: The player to add to the party
function PartyManager.AddPlayer(LeaderPlayer: Player, NewMember: Player): ()
	local party = PartyManager.Parties[LeaderPlayer]

    if not party then
		warn("AddPlayer(): LeaderPlayer not found")
		return
	end

	if table.find(party, NewMember) then
		warn("AddPlayer(): Player already in the party")
		return
	end

	table.insert(party, NewMember)
end

-- RemovePlayer(): Removes a player from a leaders party. If the leader is the only one in the party, it deletes the party
-- @param LeaderPlayer: The player who created the party
-- @param Member: The player to remove from the party
function PartyManager.RemovePlayer(LeaderPlayer: Player, Member: Player): ()
	local party = PartyManager.Parties[LeaderPlayer]

	if not party then
		warn("RemovePlayer(): LeaderPlayer not found")
		return
	end

	local index = table.find(party, Member)

    if index then
        table.remove(party, index)
    end


	if #party == 0 then
		PartyManager.DeleteParty(LeaderPlayer)
	end
end

--=========================
-- // UTILITY API
--=========================

-- GetPartyMembers(): Returns the members of a leaders party
-- @param LeaderPlayer: The player who created the party
-- @return { Player }?: The members
function PartyManager.GetPartyMembers(LeaderPlayer: Player): { Player }?
	return PartyManager.Parties[LeaderPlayer]
end

-- IsInParty(): Checks if a player is in any party
-- @param PlayerToCheck: The player to check
-- @return boolean: If they're in the party
function PartyManager.IsInParty(PlayerToCheck: Player): boolean
	for _, members in PartyManager.Parties do
		if table.find(members, PlayerToCheck) then
			return true
		end
	end

	return false
end

-- GetLeader(): Returns the leader of the party a player belongs to
-- @param PlayerToCheck: The player to check
-- @return Player?: The leader, if found
function PartyManager.GetLeader(PlayerToCheck: Player): Player?
	for leader, members in PartyManager.Parties do
		if table.find(members, PlayerToCheck) then
			return leader
		end
	end

	return nil
end

-- GetPartySize(): Returns total size of a leaders party (leader + members)
-- @param LeaderPlayer: The player who created the party
-- @return number: The party size
function PartyManager.GetPartySize(LeaderPlayer: Player): number
	local members = PartyManager.Parties[LeaderPlayer]

    return members and (#members + 1) or 1
end

-- CreateTeamsFromPartyMap(): Automatically creates parties from a PartyMap
-- @param partyMap: Types.PartyMap
function PartyManager.CreateTeamsFromPartyMap(partyMap: Types.PartyMap): ()
		for _, partyData in partyMap do
            local leaderPlayer = PartyManager.PlayerLookup[partyData.Leader]
            if not leaderPlayer then continue end

            local members = {}

            for _, userId in partyData.Members do
                local player = PartyManager.PlayerLookup[userId]

                if player and player ~= leaderPlayer then
                    table.insert(members, player)
                end
            end

            PartyManager.CreateParty(leaderPlayer, members)
	end
end

--=========================
-- // CLEANUP
--=========================

-- Cleanup(): Cleans up all of the parties
function PartyManager.Cleanup(): ()
    PartyManager.Parties = {}
end

--=========================
-- // INIT
--=========================

SetupPlayerLookup()

CleanupInit()

return PartyManager