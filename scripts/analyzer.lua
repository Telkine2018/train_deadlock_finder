
local util = require("util")

local function print(msg)

	log(msg)
	for _, player in pairs(game.players) do
		if (not player.mod_settings["tdf-silent"].value) then
			player.print(msg)
		end
	end
end


local function pretty_object(o)
	return serpent.block(o):gsub("[\n\r ]", "")
end

local train_states = {
	[defines.train_state.on_the_path] = "on_the_path",		-- Normal state following the path.
	[defines.train_state.path_lost] = "path_lost", 			-- Had path and lost it  must stop.
	[defines.train_state.no_schedule] = "no_schedule",		-- Doesn't have anywhere to go.
	[defines.train_state.no_path] = "no_path", 				-- Has no path and is stopped.
	[defines.train_state.arrive_signal] = "arrive_signal",	-- Braking before a rail signal.
	[defines.train_state.wait_signal] = "",					-- Waiting at a signal.
	[defines.train_state.arrive_station] = "arrive_station", 	-- before a station.
	[defines.train_state.wait_station] = "wait_station", 						-- Waiting at a station.
	[defines.train_state.manual_control_stop] = "manual_control_stop",			-- Switched to manual control and has to stop.
	[defines.train_state.manual_control]=	"manual_control",					-- Can move if user explicitly sits in and rides the train.
	[defines.train_state.destination_full] = "destination_full"
}

local trains = {}
local surface_trains = {}
local current_surface = nil
local current_station = nil
local err_map = {}

local trace_events = false
local trace_register = false
local trace_deadlock = true

local function get_ts(train)
	local surface = train.carriages[1].surface
	return surface_trains[surface.name]
end

local function invert_rail_direction(dir)
	if dir == defines.rail_direction.front then	
		return defines.rail_direction.back
	else
		return defines.rail_direction.front
	end
end

local function register_train(ts, train)

	local schedule = train.schedule
	if #schedule.records > 1 then
		local current = schedule.current
		local previous
		if current == 1 then
			previous = #schedule.records
		else
			previous = current - 1
		end
		local dst = schedule.records[current].station
		local src = schedule.records[previous].station
		
		local front_rail = train.front_rail
		local from_station
		if front_rail then
			from_station = front_rail.get_rail_segment_entity(train.rail_direction_from_front_rail , false)
		end
		
		if not from_station or (from_station.type ~= "train-stop" or from_station.backer_name ~= src) then
			local back_rail = train.back_rail
			if back_rail then
				from_station = back_rail.get_rail_segment_entity(invert_rail_direction(train.rail_direction_from_front_rail), false)
			end
		end
		
		if from_station and from_station.type == "train-stop" and from_station.backer_name==src then
			
			local cb = from_station.get_control_behavior()
			if cb and cb.disabled then return end
			
			if trace_register then 
				print("[" .. train.id .. "] Register dst=" .. dst .. ",src=" .. src .. ",trains_count=" .. from_station.trains_count .. ",trains_limit=" .. from_station.trains_limit )
			end
			local id = train.id
			local info = {
				train = train,
				dst = dst,
				src = src,
				id = id,
				station = from_station
			}
			trains[id] = info
			
			local tab_dst = ts.map_dst[dst]
			if tab_dst == nil then
				tab_dst = {}
				ts.map_dst[dst] = tab_dst
			end
			table.insert(tab_dst, info)
			
			local tab_src = ts.map_src[src]
			if tab_src == nil then
				tab_src = {}
				ts.map_src[src] = tab_src
			end
			table.insert(tab_src, info)
			
			if trace_register then 
				print(pretty_object(surface_trains))
			end
			return info
		end
	end
end

local function unregister_train(id)

	local info = trains[id]
	if not info then return end
	
	local train = info.train
	local ts = get_ts(train)
	local id = train.id
	if trace_register then 
		print("[" .. id .. "] Unregister ")
	end

	trains[id] = nil
	for i, cur_info in ipairs(ts.map_dst[info.dst]) do
		if cur_info.id == id then	
			table.remove(ts.map_dst[info.dst], i)
			break
		end
	end 
	for i, cur_info in ipairs(ts.map_src[info.src]) do
		if cur_info.id == id then
			table.remove(ts.map_src[info.src], i)
			break
		end
	end 
	if trace_register then 
		print(pretty_object(surface_trains))
	end
end

local function load_trains()
	for name,surface in pairs(game.surfaces) do
		local ts = {
			map_dst = {},
			map_src = {}
		}
		surface_trains[name] = ts
		
		for _,train in pairs(surface.get_trains("player")) do
			if train.state == defines.train_state.destination_full then
				register_train(ts, train)
			end
		end
	end
end

local function train_info(train)

	local schedule = train.schedule
	return 	"state=" .. train_states[train.state] 
			.. (train.station and (", station=" .. train.station.backer_name) or "")
			.. ((schedule and #schedule.records > 0) and (", schedule=" .. tostring(schedule.records[schedule.current].station )) or "")
end

local function check_deadlock(ts, station_name)
	
	local cycle = {}
	local cycle_map = {}
	local failed = {}
	local function search_cycle(station_name) 

		if failed[station_name] then return end

		table.insert(cycle, station_name)
		if cycle_map[station_name] then 
			return true 
		end
		
		cycle_map[station_name] = true
		local infos = ts.map_src[station_name]
		if infos then
			for _, info in pairs(infos) do
				if info.station.valid and info.station.trains_limit > 0 then
					local cb = info.station.get_control_behavior()
					if not cb or not cb.disabled then
						if search_cycle(info.dst) then
							return true
						end	
						failed[info.dst] = true
					end
				end
			end
		end
		table.remove(cycle)
		cycle_map[station_name] = nil
		return false
	end
	
	if not search_cycle(station_name) then
		return false
	end
	
	local last = cycle[#cycle]
	while cycle[1] ~= last do
		table.remove(cycle, 1)
	end
	
	-- check
	local invalid = false
	for _, station_name in pairs(cycle) do
		
		local infos = ts.map_src[station_name]
		local first_station = infos[1].dst
		for _, info in pairs(infos) do
			if info.dst ~= first_station then
				invalid = true
			end
			if invalid then break end
		end
		if invalid then break end
	end
	
	if invalid then 
		local str_cycle =  pretty_object(cycle)
		if not err_map[str_cycle] then
			print("Cannot remove deadlock: " .. str_cycle)
			err_map[str_cycle] = true
		end
		return false 
	end
	
	if trace_deadlock then
		print("Deadlock: " .. pretty_object(cycle))
	end
	
	local locked_info
	
	for i=1, #cycle do
		local station_name = cycle[i]
		
		if #(ts.map_src[station_name]) ==1 then
			for _,info in pairs(ts.map_src[station_name]) do
				
				if info.station and info.station.trains_limit > 0 then
					locked_info = info
					break
				end
			end
		end
		if locked_info then
			break
		end
	end
	
	if not locked_info then
		
		if settings.global["tdf-allow-unsafe-break"].value  then
			for i=1, #cycle do
				local station_name = cycle[i]
				for _,info in pairs(ts.map_src[station_name]) do
					
					if info.station and info.station.trains_limit > 0 then
						local cb = info.station.get_control_behavior()
						if not cb or not cb.disabled then
							locked_info = info
							break
						end
					end
				end
				if locked_info then
					break
				end
			end
		end

		if not locked_info then 
			table.remove(cycle)
			local str_cycle =  pretty_object(cycle)
			if not err_map[str_cycle] then
				print("Cannot remove deadlock (change settings ?); " .. str_cycle)
				err_map[str_cycle] = true
			end
			return false
		end
	end
	
	
	global.locked_train = locked_info
	local station = locked_info.station
	
	if station.valid then
		
		local trains_limit = station.trains_limit
		local cb = station.get_control_behavior()
		
		locked_info.trains_limit = trains_limit
		locked_info.cb = cb
		if cb then
			locked_info.set_trains_limit = cb.set_trains_limit 
			cb.set_trains_limit = false
		end
		station.trains_limit = trains_limit + 1
	else
		global.locked_train = nil
	end
	
	return true
end

local function on_train_changed_state(e) 
	-- train, old_state
	local train = e.train
	
	if trace_events then
		print("[" .. train.id .. "] on_train_changed_state, old_state=[" .. 
			(e.old_state and train_states[e.old_state] or "") .. "]," .. train_info(train))
	end
		
	local ts = get_ts(train)
	if train.state == defines.train_state.destination_full then
		register_train(ts, train)
	else
		unregister_train(train.id)
	end
		
end

local function on_train_created(e)
	-- train, old_train_id_1, old_train_id_2 
	local train = e.train
	if trace_events then
		print("[" .. train.id .. "] on_train_created, old_train_id_1="  .. tostring(e.old_train_id_1) .. ",old_train_id_2=" .. tostring(e.old_train_id_2))
	end
end

local function on_train_schedule_changed(e)
	-- train, player_index 
	local train = e.train
	if trace_events then
		print("[" .. train.id .. "] on_train_schedule_changed," .. train_info(train))
	end
end

local function on_tick(e)
	local locked_train = global.locked_train
	if locked_train then	
		local station = locked_train.station
		if station.valid then
			station.trains_limit = locked_train.trains_limit
			if locked_train.cb then
				locked_train.cb.set_trains_limit = locked_train.set_trains_limit
			end
		end
		global.locked_train = nil
	end
end

local function on_nth_tick(e)

	if global.locked_train then	
		return
	else	

		if current_surface and not surface_trains[current_surface] then
			current_surface = nil
			current_station = nil
		end
		
		local n_surface, ts = next(surface_trains, current_surface) 
		current_surface = n_surface
		
		if not ts then return end
		
		for station_name, station in pairs(ts.map_src) do
			if check_deadlock(ts, station_name) then
				return 
			end
		end
	end
end

local function on_nth_tick_with_init(e) 

	script.on_nth_tick(5, on_nth_tick)
	
	load_trains()
end

script.on_event(defines.events.on_train_changed_state, on_train_changed_state)
script.on_event(defines.events.on_train_created, on_train_created)
script.on_event(defines.events.on_train_schedule_changed, on_train_schedule_changed)
script.on_event(defines.events.on_tick, on_tick)
script.on_nth_tick(5, on_nth_tick_with_init)
