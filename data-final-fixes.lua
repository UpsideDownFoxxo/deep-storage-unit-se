-- stop the SE-compat override
if mods["space-exploration"] then
	local recipe = data.raw.recipe["memory-unit"]
	recipe.ingredients = {
		{ type = "item", name = "aai-warehouse", amount = 1 },
		{ type = "item", name = "se-holmium-solenoid", amount = 30 },
		{ type = "item", name = "se-space-supercomputer-1", amount = 2 },
		{ type = "item", name = "se-heavy-girder", amount = 20 },
		{ type = "item", name = "se-magnetic-canister", amount = 10 },
		{ type = "item", name = "se-forcefield-data", amount = 5 },
		{ type = "fluid", name = "water", amount = 100000 },
	}
	recipe.category = "space-manufacturing"

	local tech = data.raw.technology["memory-unit"]
	tech.prerequisites = { "se-holmium-solenoid", "se-heavy-girder", "se-astronomic-science-pack-1" }
	tech.unit.ingredients = {
		{ "automation-science-pack", 1 },
		{ "logistic-science-pack", 1 },
		{ "chemical-science-pack", 1 },
		{ "se-rocket-science-pack", 1 },
		{ "space-science-pack", 1 },
		{ "utility-science-pack", 1 },
		{ "production-science-pack", 1 },
		{ "se-astronomic-science-pack-1", 1 },
		{ "se-energy-science-pack-2", 1 },
		{ "se-material-science-pack-1", 1 },
	}
end
