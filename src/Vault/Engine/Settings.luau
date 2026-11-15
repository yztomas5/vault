--!strict
return table.freeze({
	AutoSaveSeconds = 300,
	FirstLoadRepeatSeconds = 5,
	LoadRepeatSeconds = 10,
	StealSeconds = 40,
	DeadSeconds = 630,
	StartTimeoutSeconds = 120,
	MessageQueue = 1000,
	MessageCooldownSeconds = 6,
	NameLength = 50,
	KeyBytes = 4194304,
	SizeWarnings = { 0.5, 0.75, 0.9 },
	ServerThrottleSeconds = 5,
	ExperienceThrottleSeconds = 15,
	GlobalReserve = 10,
	LowPriorityWaitSeconds = 10,
})
