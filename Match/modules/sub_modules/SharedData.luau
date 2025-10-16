--!strict

--=========================
-- // TYPES
--=========================

local Types = require(script.Parent.Parent.helpers.Types)

--=========================
-- // MAIN
--=========================

local SharedData = {
	playerQueueKeys = {},
	localQueueCounts = {},
	isProcessingMatch = {},
	crossServerData = {},
	matchmakingTasks = {},
	queueCache = {},
	messagingConnections = {},
	lastCacheCleanup = 0,
	heartbeatConnection = nil,
	_lockMap = nil :: MemoryStoreSortedMap?,
} :: Types.MatchData

return SharedData