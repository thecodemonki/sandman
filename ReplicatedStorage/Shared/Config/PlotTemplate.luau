-- Grid definition for a base plot: cell size, dimensions, and zone map.
-- Pure data + lookup helpers; no Roblox instances (no models/parts) yet.

export type ZoneType = "Protected" | "Farm" | "Open"

export type ZoneDef = {
	ZoneType: ZoneType,
	ColMin: number,
	ColMax: number,
	RowMin: number,
	RowMax: number,
}

local PlotTemplate = {}

PlotTemplate.CellSize = 6 -- studs per cell, PLACEHOLDER (brief §8)
PlotTemplate.GridWidth = 20 -- cells
PlotTemplate.GridHeight = 20 -- cells

-- Rectangular cell ranges (inclusive), kept non-overlapping in this template.
PlotTemplate.Zones = {
	{ ZoneType = "Protected", ColMin = 8, ColMax = 11, RowMin = 8, RowMax = 11 }, -- core, near spawn
	{ ZoneType = "Farm", ColMin = 0, ColMax = 7, RowMin = 0, RowMax = 19 },
	{ ZoneType = "Open", ColMin = 12, ColMax = 19, RowMin = 0, RowMax = 19 },
} :: { ZoneDef }

function PlotTemplate.GetZoneAt(col: number, row: number): ZoneType?
	for _, zone in PlotTemplate.Zones do
		if col >= zone.ColMin and col <= zone.ColMax and row >= zone.RowMin and row <= zone.RowMax then
			return zone.ZoneType
		end
	end
	return nil
end

function PlotTemplate.IsInBounds(col: number, row: number): boolean
	return col >= 0 and col < PlotTemplate.GridWidth and row >= 0 and row < PlotTemplate.GridHeight
end

return PlotTemplate
