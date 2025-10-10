--!strict

--=========================
-- // MATCHMAKING TYPES
--=========================

export type QueueKey = {
    Mode: string,
    SubMode: string
}

export type PlayerQueueData = {
	UserId: number,
	ELO: number,
	JoinTime: number,
	ServerId: string,
	Continent: string,
	SubMode: string
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
	UserId: number,
	ELO: number,
	JoinTime: number,
	QueueKey: QueueKey,
	MemoryStoreKey: string,
	ServerId: string,
	Continent: string
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

export type CrossServerData = {
	Players: { CrossServerPlayer },
	Timestamp: number
}

export type TeleportRequestData = {
    MatchId: string,
    ServerCode: string,
    PlaceId: number,
    PlayersForServer: { [string]: { number } },
    Mode: string,
    SubMode: string,
    Timestamp: number
}

export type MessagedData = {
	Mode: string,
	SubMode: string,
	RequestingServer: string,
	Timestamp: number,
	PlayersForServer: { [string]: { number } },
	TargetServer: string
}

export type MatchData = {
	playerQueueKeys: { [number]: { [string]: { [string]: string } } }, -- // UserId -> Mode -> SubMode -> MemoryStoreKey (string)
	localQueueCounts: { [string]: { [string]: number } }, -- // Mode -> SubMode -> Count
	isProcessingMatch: { [string]: { [string]: boolean } }, -- // Mode -> SubMode -> Processing Status

	crossServerData: { [string]: { [string]: { [string]: CrossServerData } } }, -- // Mode -> SubMode -> ServerId -> Data

	matchmakingTasks: { [string]: { [string]: thread } }, -- // Mode -> SubMode -> Thread

	queueCache: { [string]: { [string]: QueueCacheEntry } }, -- // Mode -> SubMode -> Cache Entry
	messagingConnections: { [string]: RBXScriptConnection }, -- // Handler Key -> Connection

	lastCacheCleanup: number,
	heartbeatConnection: RBXScriptConnection?,
	_lockMap: MemoryStoreSortedMap?
}

return nil