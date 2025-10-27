local function ensure_exists(t, v, default)
	t[v] = t[v] or default
end
for _, unit_data in pairs(storage.units) do
	ensure_exists(unit_data, "conversion_tier", 0)
	ensure_exists(unit_data, "energy_tier", 0)
	ensure_exists(unit_data, "conversion_to_nexttier", 0)
	ensure_exists(unit_data, "energy_to_next_tier", 0)
	ensure_exists(unit_data, "max_conversion_speed", 0)
	ensure_exists(unit_data, "last_action", 0)
	ensure_exists(unit_data, "previous_inventory_count", 0)

	ensure_exists(unit_data, "effects", {})
	ensure_exists(unit_data, "overloads", {})
	ensure_exists(unit_data, "beacons", {})
end
