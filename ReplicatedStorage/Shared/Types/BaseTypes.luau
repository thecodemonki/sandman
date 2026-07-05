-- Matches Architecture Skeleton v1 §3.2. One shape shared by Personal and Team bases.

export type Placement = {
	Id: string, -- unique instance id
	ItemId: string, -- the form it was BUILT as; -> BuildableConfig entry
	Position: { X: number, Y: number, Z: number }, -- plot-local coords, derived from grid cell
	Rotation: number,
	-- Per-instance state. For towers (this prompt resolves the v1.1 §6 open question as
	-- PER-TOWER): State.Level (number) and State.CurrentFormId (string, changes on evolution).
	-- Non-levelable buildables (crop plots, silos) leave this nil.
	State: { [string]: any }?,
}

export type BaseData = {
	SchemaVersion: number,

	BaseLevel: number,

	Placements: { Placement },
	Upgrades: { [string]: number }, -- base-wide stat tracks (e.g. WallMaterial); out of scope here

	Storage: {
		Crops: { [string]: number },
		Capacity: number,
	},

	Decor: { Placement },
}

return {}
