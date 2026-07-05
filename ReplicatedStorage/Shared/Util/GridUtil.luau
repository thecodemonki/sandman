-- Single shared grid<->world conversion so client rendering and server placement/range math
-- can never drift out of sync. Previously two independently-maintained formulas existed:
-- center-anchored on the client (BuildController), corner-anchored on the server
-- (BuildService) -- harmless for rendering, but caused a real half-cell offset for anything
-- doing spatial math (tower range checks). Standardized on CENTER-anchored: a cell's world
-- position is the middle of its footprint, not a corner.

local GridUtil = {}

function GridUtil.CellToWorldCenter(col: number, row: number, cellSize: number, origin: Vector3?): Vector3
	local o = origin or Vector3.new(0, 0, 0)
	return Vector3.new(
		o.X + col * cellSize + cellSize / 2,
		o.Y,
		o.Z + row * cellSize + cellSize / 2
	)
end

-- Inverse of CellToWorldCenter. Only meaningful for positions that actually came from it
-- (e.g. recovering a placement's cell from its stored center position) -- the small epsilon
-- guards against floating-point drift landing just under the exact integer.
function GridUtil.WorldToCell(x: number, z: number, cellSize: number, origin: Vector3?): (number, number)
	local o = origin or Vector3.new(0, 0, 0)
	local col = math.floor((x - o.X) / cellSize - 0.5 + 1e-6)
	local row = math.floor((z - o.Z) / cellSize - 0.5 + 1e-6)
	return col, row
end

return GridUtil
