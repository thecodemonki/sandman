-- Matches Architecture Skeleton v1 §3.4.

export type ItemDef = {
	ItemId: string,
	ItemType: string, -- Enums.ItemType
	IsCosmetic: boolean,
	AffectsCombat: boolean,
	IsMaterialGated: boolean,
	GatingMaterialId: string?, -- required if IsMaterialGated
	CurrencyCost: number?, -- nil = not currency-purchasable
}

return {}
