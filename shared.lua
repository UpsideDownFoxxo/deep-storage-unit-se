-- shared code between memory units and fluid memory units

local min = math.min
local floor = math.floor

local tier_borders = {
	[0] = 400,
	[1] = 800,
	[2] = 1600,
	[3] = 3200,
	[4] = 6400,
	[5] = 12800,
	[6] = 25600,
	[7] = 51200,
	[8] = 102400,
}

local base_graphs = {
	[0] = function(x)
		return 100 * math.pow(x, 0.9)
	end,
	[1] = function(x)
		return 90 * math.pow(x, 0.875)
	end,
	[2] = function(x)
		return 80 * math.pow(x, 0.85)
	end,
	[3] = function(x)
		return 70 * math.pow(x, 0.825)
	end,
	[4] = function(x)
		return 60 * math.pow(x, 0.8)
	end,
	[5] = function(x)
		return 50 * math.pow(x, 0.775)
	end,
	[6] = function(x)
		return 40 * math.pow(x, 0.75)
	end,
	[7] = function(x)
		return 30 * math.pow(x, 0.725)
	end,
	[8] = function(x)
		return 20 * math.pow(x, 0.7)
	end,
}

local transition_heights = {}

--- created to reflect https://www.desmos.com/calculator/tqogtkoo5d
---@type table <number,function<number,number>>
local power_table = { tier_borders = tier_borders }

transition_heights[0] = 0
power_table[0] = base_graphs[0]

for i = 1, 8, 1 do
	transition_heights[i] = -base_graphs[i](tier_borders[i - 1]) + power_table[i - 1](tier_borders[i - 1])
	power_table[i] = function(x)
		return transition_heights[i] + base_graphs[i](x)
	end
end

local function compactify(n)
	n = floor(n)

	local suffix = 1
	local new
	while n >= 1000 do
		new = floor(n / 100) / 10
		if n == new then
			return { "big-numbers.infinity" }
		else
			n = new
		end
		suffix = suffix + 1
	end

	if suffix ~= 1 and floor(n) == n then
		n = tostring(n) .. ".0"
	end

	return { "big-numbers." .. suffix, n }
end

---pad an area by a given amount
---@param area BoundingBox
---@param padding number
---@return BoundingBox
local function pad_area(area, padding)
	for index1, value1 in pairs(area) do
		for index2, value2 in pairs(value1) do
			if index1 == 1 or index1 == "left_top" then
				area[index1][index2] = value2 - padding
			else
				area[index1][index2] = value2 + padding
			end
		end
	end

	return area
end

local function clamp(is, max, min)
	return math.max(min, math.min(is, max))
end

local function open_inventory(player)
	if not storage.blank_gui_item then
		local inventory = game.create_inventory(1)
		inventory[1].set_stack("blank-gui-item")
		inventory[1].allow_manual_label_change = false
		storage.empty_gui_item = inventory[1]
	end
	player.opened = nil
	player.opened = storage.empty_gui_item
	return player.opened
end

local function update_display_text(unit_data, entity, localised_string)
	if unit_data.text then
		local render_object = rendering.get_object_by_id(unit_data.text)
		if render_object then
			render_object.text = localised_string
			return
		end
	end

	unit_data.text = rendering.draw_text({
		surface = entity.surface,
		target = entity,
		text = localised_string,
		alignment = "center",
		scale = 1.5,
		only_in_alt_mode = true,
		color = { r = 1, g = 1, b = 1 },
	}).id
end

local function update_combinator(combinator, signal, count)
	local control = combinator.get_or_create_control_behavior()
	count = min(2147483647, count)

	control.get_section(1).set_slot(1, {
		value = signal,
		min = count,
		max = count,
		count = count,
	})
end

local power_usages = {
	["0W"] = 0,
	["60kW"] = 0.2,
	["180kW"] = 0.6,
	["300kW"] = 1,
	["480kW"] = 1.6,
	["600kW"] = 2,
	["1.2MW"] = 4,
	["2.4MW"] = 8,
}

local base_usage = 1000000 / 60
---updates the power usage for the given unit
---@param unit_data any
---@param count any
local function update_power_usage(unit_data, count)
	local powersource = unit_data.powersource
	local power_usage = power_table[unit_data.energy_tier or 0](math.ceil(count / (unit_data.stack_size or 1000)))
	power_usage = power_usage * 1000 / 60 + base_usage
	power_usage = power_usage * power_usages[(settings.global["memory-unit-power-usage"]).value]
	unit_data.operation_cost = power_usage

	if unit_data.containment_field < settings.global["memory-unit-se-fox-containment-field"].value then -- we need to charge the containment field, increase the power usage
		power_usage = power_usage * 1.2
	end

	powersource.power_usage = power_usage
	powersource.electric_buffer_size = power_usage
	return power_usage
end

local update_rate = 15
local update_slots = 4

local function has_power(powersource, entity)
	if powersource.energy < powersource.electric_buffer_size * 0.9 then
		if powersource.energy ~= 0 then
			rendering.draw_sprite({
				sprite = "utility.electricity_icon",
				x_scale = 0.5,
				y_scale = 0.5,
				target = entity,
				surface = entity.surface,
				time_to_live = 30,
			})
		end
		return false
	end

	return not entity.to_be_deconstructed()
end

local function is_spoilable(item)
	return prototypes.item[item].get_spoil_ticks() ~= 0
end

local function memory_unit_corruption(unit_number, unit_data)
	local entity = unit_data.entity
	local powersource = unit_data.powersource
	local combinator = unit_data.combinator

	if entity.valid then
		entity.destroy()
	end
	if powersource.valid then
		powersource.destroy()
	end
	if combinator.valid then
		combinator.destroy()
	end

	game.print({ "memory-unit-corruption", unit_data.count, unit_data.item or "nothing" })
	storage.units[unit_number] = nil
end

local function validity_check(unit_number, unit_data, force)
	if not unit_data.entity.valid or not unit_data.powersource.valid or not unit_data.combinator.valid then
		memory_unit_corruption(unit_number, unit_data)
		return true
	end

	if not force and not has_power(unit_data.powersource, unit_data.entity) then
		return true
	end
	return false
end

local function combine_tempatures(first_count, first_tempature, second_count, second_tempature)
	if first_tempature == second_tempature then
		return first_tempature
	end
	local total_count = first_count + second_count
	return (first_tempature * first_count / total_count) + (second_tempature * second_count / total_count)
end

return {
	update_display_text = update_display_text,
	update_combinator = update_combinator,
	has_power = has_power,
	update_power_usage = update_power_usage,
	update_rate = update_rate,
	update_slots = update_slots,
	compactify = compactify,
	open_inventory = open_inventory,
	is_spoilable = is_spoilable,
	memory_unit_corruption = memory_unit_corruption,
	validity_check = validity_check,
	combine_tempatures = combine_tempatures,
	pad_area = pad_area,
	clamp = clamp,
	power_table = power_table,
}
