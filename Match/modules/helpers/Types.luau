--[[
	MIT License

	Copyright © 2025 g0ofycat

	Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

	The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

	THE SOFTWARE IS PROVIDED "AS IS," WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
]]

--!strict

--=========================
-- // MATCHMAKING TYPES
--=========================

export type QueueKey = {
    Mode: string,
    SubMode: string
}

export type PlayerQueueData = {
    PartyID: string?,
    IsPartyLeader: boolean,
	UserId: number,
	ELO: number,
	JoinTime: number,
	ServerId: string,
	Continent: string,
}

export type QueueStatusResponseData = {
    Mode: string,
    SubMode: string,
    TargetServer: string,
    SendingServer: string,
    Players: { CrossServerPlayer },
    PlayerCount: number,
    Timestamp: number
}

export type ParsedPlayerData = {
    PartyID: string?,
    IsPartyLeader: boolean,
	UserId: number,
	ELO: number,
	JoinTime: number,
	QueueKey: QueueKey,
	MemoryStoreKey: string,
	ServerId: string,
	Continent: string,
}

export type QueueCacheEntry = {
	queue: MemoryStoreSortedMap,
	lastUsed: number
}

export type CrossServerPlayer = {
	UserId: number,
	ELO: number,
	JoinTime: number,
	QueueKey: QueueKey
}

export type PartyMap = {
    [string]: {
        [string]:
        {
            Members: { number },
            Leader: number?
        }
    }
}

export type TeleportRequestData = {
    MatchId: string,
    ServerCode: string,
    PlaceId: number,
    PlayersForServer: { [string]: { number } },
    PartyMapping: PartyMap,
    Mode: string,
    SubMode: string,
    Timestamp: number
}

export type PreviousMatchData = {
	MatchId: string,
	Mode: string,
	SubMode: string,
	Timestamp: number
}

export type MatchData = {
	playerQueueKeys: { [number]: { [string]: { [string]: string } } }, -- // UserId -> Mode -> SubMode -> MemoryStoreKey
	localQueueCounts: { [string]: { [string]: number } }, -- // Mode -> SubMode -> Count
	isProcessingMatch: { [string]: { [string]: boolean } }, -- // Mode -> SubMode -> Processing Status

	matchmakingTasks: { [string]: { [string]: thread } }, -- // Mode -> SubMode -> Thread

	queueCache: { [string]: { [string]: QueueCacheEntry } }, -- // Mode -> SubMode -> Cache Entry
	messagingConnections: { [string]: RBXScriptConnection }, -- // Handler Key -> Connection

	lastCacheCleanup: number,
	heartbeatConnection: RBXScriptConnection?,
	signal: any
}

return nil