require("gui")

---@class UnitData
---@field entity LuaEntity
---@field item string?
---@field quality QualityID?
---@field stack_size number?
---@field comfortable number?
---@field inventory LuaInventory
---@field beacons table<string,LuaEntity[]>
---@field overloads table<string,boolean>
---@field conversion_tier number
---@field energy_tier number
---@field conversion_to_next_tier number
---@field energy_to_next_tier number
---@field max_conversion_speed number
---@field count number
---@field previous_inventory_count number
---@field lag_id number
---@field containment_field number
---@field last_action number
---@field overloaded_sprite LuaRenderObject?
---@field effects {speed:number,energy:number}?
---@field powersource LuaEntity
---@field combinator LuaEntity

local shared = require("shared")
local update_rate = shared.update_rate
local update_slots = shared.update_slots
local compactify = shared.compactify
local validity_check = shared.validity_check
local has_power = shared.has_power

local beacons_max_count = {
	["se-wide-beacon"] = 0,
	["se-wide-beacon-2"] = 0,
	["se-compact-beacon"] = 4,
	["se-compact-beacon-2"] = 4,
}

local function setup()
	---@type table<number,UnitData>
	storage.units = storage.units or {}

	if remote.interfaces["PickerDollies"] then
		remote.call("PickerDollies", "add_blacklist_name", "memory-unit", true)
		remote.call("PickerDollies", "add_blacklist_name", "memory-unit-combinator", true)

		if remote.interfaces["PickerDollies"]["dolly_moved_entity_id"] then
			---@diagnostic disable-next-line
			script.on_event(remote.call("PickerDollies", "dolly_moved_entity_id"), function(event)
				---@diagnostic disable-next-line: undefined-field
				local entity = event.moved_entity --[[@as LuaEntity]]
				if entity.type == "beacon" then
					local surface = entity.surface

					local affected_storages = surface.find_entities_filtered({
						area = shared.pad_area(
							entity.bounding_box,
							prototypes.entity[entity.name].get_supply_area_distance() + 1
						),
						name = "memory-unit",
					})

					for _, value in pairs(affected_storages) do
						update_storage_beacons(storage.units[value.unit_number], entity.name)
					end
				end
			end)
		end
	end
end

script.on_init(setup)
script.on_configuration_changed(function()
	storage.items_with_metadata = nil
	setup()

	for unit_number, unit_data in pairs(storage.units) do
		if unit_data.item and not validity_check(unit_number, unit_data) then
			local prototype = prototypes.item[unit_data.item]
			if prototype then
				unit_data.stack_size = prototype.stack_size
				unit_data.comfortable = unit_data.stack_size * #unit_data.inventory / 2
			else
				shared.memory_unit_corruption(unit_number, unit_data)
			end
		end
	end
end)

local function update_unit_exterior(unit_data, inventory_count)
	local entity = unit_data.entity
	unit_data.previous_inventory_count = inventory_count
	local total_count = unit_data.count + inventory_count

	local signal = { type = "item", name = unit_data.item, quality = unit_data.quality or "normal" }
	shared.update_combinator(unit_data.combinator, signal, total_count)
	shared.update_display_text(unit_data, entity, compactify(total_count))
	shared.update_power_usage(unit_data, total_count)
end

---@param unit_data UnitData
function set_filter(unit_data)
	local inventory = unit_data.inventory
	local item = unit_data.item
	local entity = unit_data.entity
	local quality = unit_data.quality or "normal"

	for i = 1, #inventory do
		local stack = inventory[i]
		local filter = {
			name = item,
			quality = quality,
		}

		if
			not inventory.set_filter(i, filter)
			or (stack.valid_for_read and (stack.name ~= item or stack.quality.name ~= quality))
		then
			entity.surface.spill_item_stack({
				position = entity.position,
				stack = stack,
				enable_looted = true,
				force = entity.force_index,
				allow_belts = false,
				use_start_position_on_failure = true,
			})
			stack.clear()
			inventory.set_filter(i, filter)
		end
	end
end

---@param unit_data UnitData
local function detect_item(unit_data)
	local inventory = unit_data.inventory
	for _, itemstack in pairs(inventory.get_contents()) do
		local name, quality = itemstack.name, itemstack.quality
		if not shared.is_spoilable(name) then
			unit_data.item = name
			unit_data.quality = quality or "normal"
			unit_data.stack_size = prototypes.item[name].stack_size
			unit_data.comfortable = unit_data.stack_size * #inventory / 2
			set_filter(unit_data)
			return true
		end
	end
	return false
end

---@param unit_data UnitData
local function overload_storage(unit_data, name)
	-- map alert
	for _, player in pairs(unit_data.entity.force.players) do
		local conflict_string
		if beacons_max_count[name] == 0 then
			conflict_string = "entity-overloading.invalid-beacon-tooltip"
		else
			conflict_string = "entity-overloading.invalid-beacon-tooltip-too-many"
		end
		player.add_custom_alert(unit_data.entity, { type = "virtual", name = "se-beacon-overload" }, {
			conflict_string,
			"[img=entity/" .. name .. "]",
			beacons_max_count[name],
		}, true)
	end

	-- create sprite on machine
	if not unit_data.overloaded_sprite or not unit_data.overloaded_sprite.valid then
		unit_data.overloaded_sprite = rendering.draw_sprite({
			sprite = "virtual-signal/se-beacon-overload",
			surface = unit_data.entity.surface,
			target = unit_data.entity,
		})
	end

	unit_data.overloads = unit_data.overloads or {}
	unit_data.overloads[name] = true
end

local function overload_storage_clear(unit_data)
	if unit_data.overloaded_sprite then
		unit_data.overloaded_sprite.destroy()
	end

	unit_data.overloaded_sprite = nil
end

---@param unit_data UnitData
function update_storage_beacons(unit_data, name, exclude)
	---@type LuaEntity
	local unit = unit_data.entity

	unit_data.beacons = unit_data.beacons or {}

	unit_data.beacons[name] = unit.surface.find_entities_filtered({
		area = shared.pad_area(unit.bounding_box, prototypes.entity[name].get_supply_area_distance()),
		name = name,
	})
	local beacons = unit_data.beacons[name]

	if exclude then
		for i = #beacons, 1, -1 do
			local beacon = unit_data.beacons[name][i]
			if beacon.unit_number == exclude.unit_number then
				table.remove(beacons, i)
			end
		end
	end

	local max_count = beacons_max_count[name]

	unit_data.overloads = unit_data.overloads or {}

	if max_count and #beacons > max_count then
		unit_data.overloads[name] = true
	else
		unit_data.overloads[name] = nil
	end

	local beacon, _ = next(unit_data.overloads)
	if beacon then
		overload_storage(unit_data, beacon)
	else
		overload_storage_clear(unit_data)
	end
end

---Calculates the tiers for the two different cores of the storage
---@param unit_data UnitData
local function calculate_tiers(unit_data)
	if not unit_data.effects then
		return
	end

	unit_data.conversion_tier = shared.clamp(math.floor(unit_data.effects.speed), 17, 0)
	unit_data.energy_tier = shared.clamp(math.floor(-unit_data.effects.energy / 72 * 4), 8, 0)
end

local function calculate_needed(unit_data)
	local conversion_tier, energy_tier = unit_data.conversion_tier, unit_data.energy_tier

	-- percentage needed for the next tier

	conversion_tier = conversion_tier + 1
	energy_tier = (energy_tier + 1) * 72

	unit_data.conversion_to_next_tier = conversion_tier - unit_data.effects.speed
	unit_data.energy_to_next_tier = energy_tier + unit_data.effects.energy -- energy is negative
end

---@param unit_data UnitData
function update_inventory_limits(unit_data)
	if not unit_data.stack_size then
		return
	end

	local inventory_limit

	if unit_data.max_conversion_speed then
		inventory_limit = math.min(
			--- we want to be able to buffer 8 cycles in either direction
			math.ceil(unit_data.max_conversion_speed * 8 / unit_data.stack_size) * 2,
			--- use inventory size as maximum
			#unit_data.inventory
		)
	else
		inventory_limit = 2
	end

	unit_data.comfortable = unit_data.stack_size * inventory_limit / 2
	unit_data.inventory.set_bar(inventory_limit + 1)
end

---@param unit_data UnitData
local function update_storage_effects(unit_data)
	local effects = { speed = 0, energy = 0 }

	---@param beacons LuaEntity[]
	for name, beacons in pairs(unit_data.beacons or {}) do
		for _, beacon in pairs(beacons) do
			if beacon.energy == 0 then
				goto continue
			end

			if beacon.effects then
				local effectivity = prototypes.entity[name].distribution_effectivity
				effects.speed = effects.speed + (beacon.effects.speed or 0) * effectivity
				effects.energy = effects.energy + (beacon.effects.consumption or 0) * effectivity
			end

			::continue::
		end
	end

	unit_data.effects = effects

	calculate_tiers(unit_data)
	calculate_needed(unit_data)

	unit_data.max_conversion_speed = (unit_data.conversion_tier + 1) * (update_rate * update_slots)

	update_inventory_limits(unit_data)
end

---@param unit_data UnitData
local function apply_item_loss(unit_data)
	local powersource = unit_data.powersource
	local inventory = unit_data.inventory
	local item = unit_data.item

	if not item or not powersource or not unit_data.count then
		return false --storage is not initialized yet or has invalid properties that prevent calculations
	end

	if powersource.energy >= powersource.electric_buffer_size * 0.5 then -- storage has enough power, do not leak items
		if has_power(unit_data.powersource, unit_data.entity) then
			---@diagnostic disable-next-line: param-type-mismatch
			unit_data.containment_field = math.min(
				unit_data.containment_field + 4,
				---@diagnostic disable-next-line: param-type-mismatch
				settings.global["memory-unit-se-fox-containment-field"].value
			)
			return false
		end
	end

	if unit_data.containment_field > 0 then -- storage has remaining containment field, drain that and do not delete items
		unit_data.containment_field = unit_data.containment_field - 1

		rendering.draw_sprite({
			sprite = "utility/warning_icon",
			surface = unit_data.entity.surface,
			target = unit_data.entity,
			time_to_live = 30,
			x_scale = 0.5,
			y_scale = 0.5,
		})
		for _, player in pairs(unit_data.entity.force.players) do
			player.add_custom_alert(
				unit_data.entity,
				{ type = "item", name = "energy-shield-equipment" },
				{ "alert.power-outage-warning" },
				true
			)
		end
	else
		if unit_data.count > 0 then
			-- item is checked for existence above, unsure why the LSP cannot figure it out, so cast
			local inventory_count = inventory.get_item_count(item --[[@as string]]) -- no containment field left, slowly delete items
			unit_data.count = unit_data.count * (1 - settings.global["memory-unit-se-fox-item-loss"].value)
			update_unit_exterior(unit_data, inventory_count)

			local signal = "virtual-signal/se-anomaly" -- the anomaly is just a cooler item that fits
			rendering.draw_sprite({
				sprite = signal,
				surface = unit_data.entity.surface,
				target = unit_data.entity,
				time_to_live = 30,
				x_scale = 1.5,
				y_scale = 1.5,
				tint = {},
			})
			rendering.draw_sprite({
				sprite = signal,
				surface = unit_data.entity.surface,
				target = unit_data.entity,
				time_to_live = 30,
			})

			for _, player in pairs(unit_data.entity.force.players) do
				player.add_custom_alert(
					unit_data.entity,
					{ type = "virtual", name = "se-anomaly" },
					{ "alert.power-outage-critical" },
					true
				)
			end
		end
		return true
	end
end

---@param unit_data UnitData
function update_unit(unit_data, unit_number, force)
	local entity = unit_data.entity
	local inventory = unit_data.inventory

	if validity_check(unit_number, unit_data, true) then
		return
	end

	update_storage_effects(unit_data)

	local changed = false

	if unit_data.item == nil then
		changed = detect_item(unit_data)
	end
	local item = unit_data.item
	if item == nil then
		return
	end

	unit_data.last_action = 0

	local max_conversion_speed = unit_data.max_conversion_speed or 0
	local comfortable = unit_data.comfortable
	local quality = unit_data.quality

	local inventory_count = inventory.get_item_count({
		name = item,
		quality = quality,
	})

	local should_run = false
	if not force then
		should_run = not apply_item_loss(unit_data)
	end

	should_run = should_run and not unit_data.overloaded_sprite

	if not force and should_run then
		local delta = math.min(math.abs(inventory_count - comfortable), max_conversion_speed)

		if inventory_count > comfortable then
			local amount_removed = inventory.remove({ name = item, count = delta, quality = quality })
			unit_data.count = unit_data.count + amount_removed
			inventory_count = inventory_count - amount_removed
			unit_data.last_action = -amount_removed
			changed = true
		elseif inventory_count < comfortable then
			if unit_data.previous_inventory_count ~= inventory_count then
				changed = true
			end
			local to_add = math.floor(math.min(delta, unit_data.count))

			if to_add ~= 0 then
				local amount_added = entity.insert({ name = item, count = to_add, quality = quality })
				unit_data.count = unit_data.count - amount_added
				inventory_count = inventory_count + amount_added
				unit_data.last_action = amount_added
			end
		end
	end

	if force or changed then
		inventory.sort_and_merge()
	end
	update_unit_exterior(unit_data, inventory_count)
end

script.on_nth_tick(update_rate, function(event)
	local smooth_ups = event.tick % update_slots

	for unit_number, unit_data in pairs(storage.units) do
		if unit_data.lag_id == smooth_ups then
			update_unit(unit_data, unit_number)
		end
	end
end)

local combinator_shift_x = 2.25
local combinator_shift_y = 1.75

local function on_created_storage(event)
	local entity = event.entity

	local position = entity.position
	local surface = entity.surface
	local force = entity.force

	local combinator = surface.create_entity({
		name = "memory-unit-combinator",
		position = { position.x + combinator_shift_x, position.y + combinator_shift_y },
		force = force,
		quality = entity.quality,
	})
	combinator.operable = false
	combinator.destructible = false

	local powersource = surface.create_entity({
		name = "memory-unit-powersource",
		position = position,
		force = force,
		quality = entity.quality,
	})
	powersource.destructible = false

	---@type UnitData
	local unit_data = {
		entity = entity,
		count = 0,
		powersource = powersource,
		combinator = combinator,
		containment_field = 0,
		quality = "normal",
		inventory = entity.get_inventory(defines.inventory.chest),
		lag_id = math.random(0, update_slots - 1),
		beacons = {},
		overloads = {},
		conversion_tier = 0,
		conversion_to_next_tier = 0,
		energy_tier = 0,
		energy_to_next_tier = 0,
		max_conversion_speed = 0,
		previous_inventory_count = 0,
		last_action = 0,
	}
	storage.units[entity.unit_number] = unit_data

	local inventory = event.consumed_items
	local tags = event.tags
		or (inventory and not inventory.is_empty() and inventory[1].valid_for_read and inventory[1].is_item_with_tags and inventory[1].tags)
		or nil
	if tags and tags.name and prototypes.item[tags.name] then
		unit_data.count = tags.count
		unit_data.item = tags.name
		unit_data.quality = tags.quality or "normal"
		unit_data.stack_size = prototypes.item[tags.name].stack_size
		unit_data.comfortable = unit_data.stack_size * #unit_data.inventory / 2
		set_filter(unit_data)
		update_unit(unit_data, entity.unit_number, true)
	elseif tags and tags.name and not prototypes.item[tags.name] then
		shared.update_power_usage(unit_data, 0)
		game.print({ "mod-gui.migrated-item", tags.count, tags.name, tags.quality or "normal" })
	else
		shared.update_power_usage(unit_data, 0)
	end
end

local function on_created_beacon(event)
	local entity = event.entity --[[@as LuaEntity]]
	local surface = entity.surface

	local affected_storages = surface.find_entities_filtered({
		area = shared.pad_area(entity.bounding_box, prototypes.entity[entity.name].get_supply_area_distance()),
		name = "memory-unit",
	})

	for _, unit in ipairs(affected_storages) do
		update_storage_beacons(storage.units[unit.unit_number], entity.name)
	end
end

local function on_created(event)
	local entity = event.entity
	if entity.name == "memory-unit" then
		on_created_storage(event)
	end
	if entity.type == "beacon" then
		on_created_beacon(event)
	end
	if entity.name == "entity-ghost" and entity.ghost_name == "memory-unit" then
		entity.tags = nil
	end
end

script.on_event(defines.events.on_built_entity, on_created)
script.on_event(defines.events.on_robot_built_entity, on_created)
script.on_event(defines.events.script_raised_built, on_created)
script.on_event(defines.events.script_raised_revive, on_created)
script.on_event(defines.events.on_space_platform_built_entity, on_created)

script.on_event(defines.events.on_entity_cloned, function(event)
	local entity = event.source
	if entity.name ~= "memory-unit" then
		return
	end
	local destination = event.destination

	---@type UnitData
	local unit_data = storage.units[entity.unit_number]
	local position = destination.position
	local surface = destination.surface
	local force = destination.force

	-- try to find parts that result from area clones and re-integrate them

	local combinator
	local powersource

	local old_powersource = surface.find_entities_filtered({ position = position, name = "memory-unit-powersource" })[1]
	local old_combinator = surface.find_entities_filtered({
		position = { position.x + combinator_shift_x, position.y + combinator_shift_y },
		name = "memory-unit-combinator",
	})[1]

	if old_powersource then
		powersource = old_powersource
	else
		powersource = unit_data.powersource
		if powersource.valid then
			powersource = powersource.clone({ position = position, surface = surface })
		else
			powersource = surface.create_entity({
				name = "memory-unit-powersource",
				position = position,
				force = force,
			})
			powersource.destructible = false
		end
	end

	if old_combinator then
		combinator = old_combinator
	else
		powersource = unit_data.combinator
		if combinator.valid then
			combinator = combinator.clone({
				position = { position.x + combinator_shift_x, position.y + combinator_shift_y },
				surface = surface,
			})
		else
			combinator = surface.create_entity({
				name = "memory-unit-combinator",
				position = { position.x + combinator_shift_x, position.y + combinator_shift_y },
				force = force,
			})
			combinator.destructible = false
			combinator.operable = false
		end
	end

	local item = unit_data.item
	unit_data = {
		powersource = assert(powersource),
		combinator = assert(combinator),
		item = item,
		count = unit_data.count,
		entity = destination,
		comfortable = unit_data.comfortable,
		stack_size = unit_data.stack_size,
		inventory = assert(destination.get_inventory(defines.inventory.chest)),
		lag_id = math.random(0, update_slots - 1),
		overloads = unit_data.overloads,
		containment_field = unit_data.containment_field,
		conversion_tier = unit_data.conversion_tier,
		conversion_to_next_tier = unit_data.conversion_to_next_tier,
		energy_tier = unit_data.energy_tier,
		energy_to_next_tier = unit_data.energy_to_next_tier,
		max_conversion_speed = unit_data.max_conversion_speed,
		last_action = unit_data.last_action,
		previous_inventory_count = unit_data.previous_inventory_count,
		beacons = {},
	} --[[@as UnitData]]

	for name, _ in pairs(prototypes.get_entity_filtered({ { filter = "type", type = "beacon" } })) do
		update_storage_beacons(unit_data, name)
	end

	storage.units[destination.unit_number] = unit_data

	if item then
		set_filter(unit_data)
		update_unit(storage.units[destination.unit_number], destination.unit_number, true)
	end
end)

local function on_destroyed_storage(event)
	local entity = event.entity
	if entity.name ~= "memory-unit" then
		return
	end

	local unit_data = storage.units[entity.unit_number]
	storage.units[entity.unit_number] = nil
	unit_data.powersource.destroy()
	unit_data.combinator.destroy()

	local item = unit_data.item
	local count = unit_data.count
	local quality = unit_data.quality
	local buffer = event.buffer

	if buffer and item and count ~= 0 then
		buffer.clear()
		buffer.insert({
			name = "memory-unit-with-tags",
			count = 1,
			quality = entity.quality.name,
			tags = { name = item, count = count, quality = quality },
			custom_description = {
				"item-description.memory-unit-with-tags",
				compactify(count),
				item,
				quality,
			},
		})
	end
end

local function on_destroyed_beacon(event)
	local entity = event.entity --[[@as LuaEntity]]
	local surface = entity.surface

	local affected_storages = surface.find_entities_filtered({
		area = shared.pad_area(entity.bounding_box, prototypes.entity[entity.name].get_supply_area_distance()),
		name = "memory-unit",
	})

	for _, value in pairs(affected_storages) do
		update_storage_beacons(storage.units[value.unit_number], entity.name, entity)
	end
end

local function on_destroyed(event)
	local entity = event.entity
	if entity.name == "memory-unit" then
		on_destroyed_storage(event)
	elseif entity.type == "beacon" then
		on_destroyed_beacon(event)
	end
end

script.on_event(defines.events.on_player_mined_entity, on_destroyed)
script.on_event(defines.events.on_robot_mined_entity, on_destroyed)
script.on_event(defines.events.on_entity_died, on_destroyed)
script.on_event(defines.events.script_raised_destroy, on_destroyed)
script.on_event(defines.events.on_space_platform_mined_entity, on_destroyed)

local function pre_mined(event)
	local entity = event.entity
	if entity.name ~= "memory-unit" then
		return
	end

	local unit_data = storage.units[entity.unit_number]
	local item = unit_data.item

	if item then
		local inventory = unit_data.inventory
		local in_inventory = inventory.get_item_count({
			name = item,
			quality = unit_data.quality,
		})

		if in_inventory > 0 then
			unit_data.count = unit_data.count
				+ inventory.remove({ name = item, count = in_inventory, quality = unit_data.quality })
		end
	end
end

script.on_event(defines.events.on_pre_player_mined_item, pre_mined)
script.on_event(defines.events.on_robot_pre_mined, pre_mined)
script.on_event(defines.events.on_marked_for_deconstruction, pre_mined)
script.on_event(defines.events.on_space_platform_pre_mined, pre_mined)
