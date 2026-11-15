--!strict
export type Key = string | number
export type Path = { Key }
export type PathLike = Path | string
export type Op = "set" | "insert" | "remove"
export type Change = { any }
export type Listener = (value: any) -> ()
export type Disconnect = () -> ()
export type Migration = (data: { [any]: any }) -> ()
export type StudioData = "Mock" | "Studio" | "ProductionReadOnly" | "Production"
export type Kind = "Session" | "Mock" | "ReadOnly"
export type Message = (player: any, data: any) -> boolean?

export type Packets = {
	snapshot: any,
	changes: any,
	setting: any?,
}

export type Stores = {
	production: string,
	studio: string,
}

export type Messages = {
	failed: string,
	stolen: string,
	wiped: string,
}

export type ServerConfig = {
	template: { [string]: any },
	migrations: { Migration },
	versionPath: Path,
	baseVersion: number?,
	private: { Path }?,
	studioData: StudioData?,
	studioProduction: boolean?,
	keyPrefix: string,
	stores: Stores,
	loadSeconds: number,
	snapshotSeconds: number,
	messages: Messages,
	packets: Packets,
	serve: ((
		packet: any,
		label: string,
		handler: (any, ...any) -> ...any,
		fallback: (any, ...any) -> ...any
	) -> ())?,
	saveAttempts: number?,
	saveRetrySeconds: number?,
	players: boolean?,
	studio: boolean?,
}

export type ClientConfig = {
	packets: Packets,
	settingsPath: Path?,
	retrySeconds: number?,
	settingDelay: number?,
}

export type Choice = {
	kind: Kind,
	name: string,
	reason: string?,
}

return {}
