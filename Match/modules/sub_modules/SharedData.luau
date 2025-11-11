--!strict

--=========================
-- // MODULES
--=========================

local Signal = require(script.Parent.Parent.helpers.Signal)

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
	signal = Signal.new()
} :: Types.MatchData

return SharedData