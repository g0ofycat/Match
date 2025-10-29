--!strict

local PartyManager = {}

--=========================
-- // SERVICES
--=========================

local Players = game:GetService("Players")

local HttpService = game:GetService("HttpService")

--=========================
-- // MODULES
--=========================

PartyManager.Modules = {
    Settings = require(script.Parent.Parent.helpers.Settings),
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
    for _, player in Players:GetPlayers() do
        PartyManager.PlayerLookup[player.UserId] = player
    end

    Players.PlayerAdded:Connect(function(player)
        PartyManager.PlayerLookup[player.UserId] = player
    end)

    Players.PlayerRemoving:Connect(function(player)
        PartyManager.PlayerLookup[player.UserId] = nil
    end)
end

-- CleanupInit(): Handle players leaving if they're in a party
local function CleanupInit(): ()
    Players.PlayerRemoving:Connect(function(player)
        if PartyManager.Parties[player] then
            local party = PartyManager.Parties[player]

            local isInMatch = false

            for _, member in { player, table.unpack(party.Members) } do
                if PartyManager.Modules.QueueManager:IsPlayerQueued(member) then
                    isInMatch = true
                    break
                end
            end

            if not isInMatch then
                PartyManager.DeleteParty(player)
            end

            return
        end

        local leader = PartyManager.GetLeader(player)

        if leader then
            PartyManager.RemovePlayer(leader, player)
        end
    end)
end

--=========================
-- // PUBLIC API
--=========================

-- CreateParty(): Creates a party with a unique ID
-- @param LeaderPlayer: The player who created the party
-- @param Members: The members of the party
-- @return string: PartyID
function PartyManager.CreateParty(LeaderPlayer: Player, Members: { Player }): string
    if PartyManager.Parties[LeaderPlayer] then
        warn("CreateParty(): Leader already has a party")
        return ""
    end

    local partyId = HttpService:GenerateGUID(false)

    PartyManager.Parties[LeaderPlayer] = {
        PartyID = partyId,
        Members = Members
    }

    return partyId
end

-- QueueParty(): Queues all members of a party
-- @param LeaderPlayer: The player who created the party
-- @param mode: The mode the player should be queued to
-- @param subMode: The Sub-Mode the player should be queued to
-- @param ELO?: Optional ELO the party has
function PartyManager.QueueParty(LeaderPlayer: Player, mode: string, subMode: string, ELO: number?): ()
    local party = PartyManager.Parties[LeaderPlayer]

    if not party then
        warn("QueueParty(): LeaderPlayer not found")
        return
    end

    local matchSize = PartyManager.Modules.Settings.SubModes[subMode] and PartyManager.Modules.Settings.SubModes[subMode].MatchSize or 2
    local maxPartySize = math.floor(matchSize / 2)
    local totalPartySize = #party.Members + 1

    if totalPartySize > maxPartySize then
        warn(`QueueParty(): Party size {totalPartySize} exceeds max {maxPartySize} for {subMode}`)
        return
    end

    for _, member in { LeaderPlayer, table.unpack(party.Members) } do
        if PartyManager.Modules.QueueManager:IsPlayerQueued(member) then
            warn(`QueueParty(): {member.Name} is already queued, cannot queue party`)
            return
        end
    end

    PartyManager.Modules.QueueManager:QueueParty(LeaderPlayer, party.Members, mode, subMode, party.PartyID, ELO)
end

-- StopParty(): Stop queues all members of a party
-- @param LeaderPlayer: The player who created the party
function PartyManager.StopParty(LeaderPlayer: Player): ()
    local party = PartyManager.Parties[LeaderPlayer]

    if not party then
        warn("StopParty(): LeaderPlayer not found")
        return
    end

    PartyManager.Modules.QueueManager:StopQueue({ LeaderPlayer, table.unpack(party.Members) })
end

-- DeleteParty(): Deletes a party, also stopping everyone currently queueing (Including the leader)
-- @param LeaderPlayer: The player who created the party
function PartyManager.DeleteParty(LeaderPlayer: Player): ()
    local party = PartyManager.Parties[LeaderPlayer]

    if not party then
        warn("DeleteParty(): LeaderPlayer not found")
        return
    end

    PartyManager.Modules.QueueManager:StopQueue({ LeaderPlayer, table.unpack(party.Members) })

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

	if table.find(party.Members, NewMember) then
		warn("AddPlayer(): Player already in the party")
		return
	end

	if LeaderPlayer == NewMember then
		warn("AddPlayer(): Cannot add leader as member")
		return
	end

	table.insert(party.Members, NewMember)
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

	local index = table.find(party.Members, Member)

    if index then
        table.remove(party.Members, index)
    end

	if #party.Members == 0 then
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
	local party = PartyManager.Parties[LeaderPlayer]

	return party and party.Members or nil
end

-- IsInParty(): Checks if a player is in any party
-- @param PlayerToCheck: The player to check
-- @return boolean: If they're in the party
function PartyManager.IsInParty(PlayerToCheck: Player): boolean
	if PartyManager.Parties[PlayerToCheck] then
		return true
	end

	for _, partyData in PartyManager.Parties do
		if table.find(partyData.Members, PlayerToCheck) then
			return true
		end
	end

	return false
end

-- GetLeader(): Returns the leader of the party a player belongs to
-- @param PlayerToCheck: The player to check
-- @return Player?: The leader, if found
function PartyManager.GetLeader(PlayerToCheck: Player): Player?
	if PartyManager.Parties[PlayerToCheck] then
		return PlayerToCheck
	end

	for leader, partyData in PartyManager.Parties do
		if table.find(partyData.Members, PlayerToCheck) then
			return leader
		end
	end

	return nil
end

-- GetPartySize(): Returns total size of a leaders party (leader + members)
-- @param LeaderPlayer: The player who created the party
-- @return number: The party size
function PartyManager.GetPartySize(LeaderPlayer: Player): number
	local party = PartyManager.Parties[LeaderPlayer]

    return party and (#party.Members + 1) or 1
end

-- CreateTeamsFromPartyMap(): Automatically creates parties from a server's party data
-- @param serverParties: The party data for this server
function PartyManager.CreateTeamsFromPartyMap(serverParties: { [string]: { Members: { number }, Leader: number? } }): ()
	if not serverParties then
		warn("CreateTeamsFromPartyMap(): No party data provided")
		return
	end

	for partyId, partyData in serverParties do
		if not partyData.Leader then
			warn("CreateTeamsFromPartyMap(): Party missing leader", partyId)
			continue
		end

		local leaderPlayer = PartyManager.PlayerLookup[partyData.Leader]

		if not leaderPlayer then
			warn("CreateTeamsFromPartyMap(): Leader not found", partyData.Leader)
			continue
		end

		local members = {}

		for _, userId in partyData.Members do
			local player = PartyManager.PlayerLookup[userId]

			if player and player ~= leaderPlayer then
				table.insert(members, player)
			end
		end

		PartyManager.Parties[leaderPlayer] = {
			PartyID = partyId,
			Members = members
		}
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