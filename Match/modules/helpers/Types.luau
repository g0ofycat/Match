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