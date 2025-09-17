--!strict

--=========================
-- // TYPES
--=========================

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
	QueueKey: string,
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
	QueueKey: string
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

export type MatchData = {
	playerQueueKeys: { [number]: { [string]: string } }, -- // UserId -> QueueKey -> MemoryStore Key
	localQueueCounts: { [string]: number }, -- // QueueKey -> Count
	isProcessingMatch: { [string]: boolean }, -- // QueueKey -> Processing Status

	crossServerData: { [string]: { [string]: CrossServerData } }, -- // QueueKey -> ServerId -> Data

	matchmakingTasks: { [string]: thread }, -- // QueueKey -> Thread

	queueCache: { [string]: QueueCacheEntry }, -- // QueueKey -> Cache Entry
	messagingConnections: { [string]: RBXScriptConnection }, -- // Handler Key -> Connection

	lastCacheCleanup: number,
	heartbeatConnection: RBXScriptConnection?,
	_lockMap: MemoryStoreSortedMap? -- // Cached lock map
}

return nil