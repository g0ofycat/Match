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
	matchmakingTasks = {},
	queueCache = {},
	messagingConnections = {},
	lastCacheCleanup = 0,
	heartbeatConnection = nil,
	signal = Signal.new()
} :: Types.MatchData

return SharedData