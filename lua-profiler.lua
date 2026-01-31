--
--[[
This file is a part of the "profile.lua" library.

MIT License

Copyright (c) 2015 2dengine LLC

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
]]

local baseline_memory = collectgarbage "count"

-- Controls when to start or stop collecting data and can be used to generate reports.
---@module "Profiler"
local Profiler = {}

local utils = require "lua_utils"

local space <const> = " "

-- todo: Get user input to specify precision or fallback to this. Probably don't want them to have to type a bunch of zeros so I'll need to convert e.g. 7 to 0.0000001
local default_time_report_precision <const> = 0.000001

-- Amount of decimal places in time report. Doesn't affect actual stats, only report presentation.
local time_report_precision = default_time_report_precision

---@alias FuncStats {label: string, defined: string, time_called: number, time_elapsed: number, num_calls: number, time_file: file, avg_time: number, total_mem: number, mem_file: file, avg_mem: number, start_mem: number, short_src: string, linedefined: number}

---@type table<function, boolean> List of internal profiler functions
local internal = {}
---@type table<function, FuncStats> Map of runtime stats for each function
local stats = {}

function Profiler._new_func_stat()
	return {
		num_calls = 0,
		time_elapsed = 0,
		avg_time = 0,
		total_mem = 0,
		avg_mem = 0,
		time_file = assert(io.tmpfile()),
		mem_file = assert(io.tmpfile()),
	}
end

-- Pre-allocate a bunch of FuncStats to avoid messing with results.
-- todo: Need to measure to see what's better: this or writing everything to a temp file.
local stats_pool = {}
for i = 1, 50 do
	stats_pool[i] = Profiler._new_func_stat()
end

-- Set clock to chronos if found.
local clock = os.clock
local chronos = require "chronos"
if chronos then
	clock = chronos.nanotime
else
	print "Warning: Profiler couldn't find chronos. Falling back to os.clock."
end

local memory_to_ignore = collectgarbage "count" - baseline_memory
print("memory_to_ignore: " .. memory_to_ignore)

--- This is an internal function.
---@param event string Event type
---@param line number  Line number
---@param info table? Debug info table
function Profiler.hooker(event, line, info)
	info = info or debug.getinfo(2, "fnS")
	-- ignore the profiler itself
	if internal[info.func] or info.what ~= "Lua" then return end

	local stat_record = stats[info.func]

	-- utils.print_dict(info)
	if not stat_record then
		for _, record in pairs(stats) do
			if
				info.short_src == record.short_src
				and info.linedefined == record.linedefined
			then
				stat_record = record
				goto closure_already_recorded
			end
		end

		-- stats[f] = table.remove(stats_pool) or Profiler._new_func_stat()
		local stat = table.remove(stats_pool)
		if not stat then
			-- utils.printf("Creating new stat, #stats: %d", utils.dict_len(stats))
			stat_record = Profiler._new_func_stat()
		else
			-- print "Removing stat from pool"
			stat_record = stat
		end
		stats[info.func] = stat_record

		::closure_already_recorded::
	end

	-- get the function name if available
	if info.name then stat_record.label = info.name end

	-- find the line definition
	if not stat_record.defined then
		stat_record.short_src = info.short_src
		stat_record.linedefined = info.linedefined
		stat_record.defined = info.short_src .. ":" .. info.linedefined
		stat_record.num_calls = 0
		stat_record.time_elapsed = 0
	end

	-- If time_called was set, that means we're exiting that function.
	-- note: I could refactor this out into a separate function but the overhead might mess with results.
	if stat_record.time_called then
		-- Add function duration to total time
		local dt = clock() - stat_record.time_called
		stat_record.time_elapsed = stat_record.time_elapsed + dt
		stat_record.time_called = nil

		-- Record function duration to calculate avg afterwards.
		-- Doin it this way to avoid allocating a bajillion strings.
		assert(stat_record.time_file:write(dt), "Failed to write to time file")
		assert(stat_record.time_file:write(space), "Failed to write to time file")

		-- Add function memory usage to total mem
		assert(
			stat_record.start_mem and stat_record.total_mem,
			"You forgot to initialize mem fields"
		)
		local mem = stat_record.start_mem + collectgarbage "count"
		stat_record.total_mem = stat_record.total_mem + mem
		stat_record.start_mem = nil

		-- Record function memory usage to calculate avg afterwards.
		assert(stat_record.mem_file:write(mem))
		assert(stat_record.mem_file:write(space))
	end

	if event == "tail call" then
		local prev = debug.getinfo(3, "fnS")
		Profiler.hooker("return", line, prev)
		Profiler.hooker("call", line, info)
	elseif event == "call" then
		stat_record.time_called = clock()
		stat_record.start_mem = collectgarbage "count"
	else
		stat_record.num_calls = stat_record.num_calls + 1
	end
end

-- Sets a clock function to be used by the profiler.
---@param f function Clock function that returns a number
function Profiler.set_clock(f)
	assert(type(f) == "function", "clock must be a function")
	clock = f
end

-- Starts collecting data.
function Profiler.start() debug.sethook(Profiler.hooker, "cr") end

function Profiler.stop()
	debug.sethook()

	for _, record in pairs(stats) do
		-- If profiler was stopped before a function returned, close out that function.
		if record.time_called then
			local dt = clock() - record.time_called
			record.time_elapsed = record.time_elapsed + dt
			record.time_called = nil

			record.total_mem = record.total_mem + collectgarbage "count"
			record.start_mem = nil
		end

		record.total_mem = record.total_mem - memory_to_ignore

		local all_times = Profiler._read_file(record.time_file)
		record.avg_time = Profiler._average(all_times)

		local all_mem_usage = Profiler._read_file(record.mem_file)
		record.avg_mem = Profiler._average(all_mem_usage)
	end

	collectgarbage "collect"
end

--- Resets all collected data.
function Profiler.reset()
	for _, record in pairs(stats) do
		record.num_calls = 0
		record.time_elapsed = 0
		record.time_called = nil
		record.defined = nil
		record.label = nil

		record.time_file = Profiler._reset_file(record.time_file)
		record.mem_file = Profiler._reset_file(record.mem_file)

		table.insert(stats_pool, record)
	end

	stats = {}
	collectgarbage "collect"
end

-- todo: add different user options for sorting
-- This is an internal function.
---@param a FuncStats First function
---@param b FuncStats Second function
---@return boolean True if "a" should rank higher than "b"
function Profiler.comp(a, b)
	local dt = b.time_elapsed - a.time_elapsed
	if dt == 0 then return b.num_calls < a.num_calls end
	return dt < 0
end

-- Generates a report of functions that have been called since the profile was started.
-- Returns the report as a numeric table of rows containing the rank, function label, number of calls, total execution time and source code line number.
---@param limit number? Maximum number of rows
---@return table[] Table of rows
function Profiler.get_results(limit)
	limit = limit or 500

	local sorted_stats = {}
	for _, record in pairs(stats) do
		for k, v in pairs(record) do
			print(k, v)
		end
		if record.num_calls and record.num_calls > 0 then
			sorted_stats[#sorted_stats + 1] = record
		end
	end

	table.sort(sorted_stats, Profiler.comp)

	while #sorted_stats > limit do
		table.remove(sorted_stats)
	end

	local reports = {}

	for i, stat in ipairs(sorted_stats) do
		local dt = 0
		if stat.time_called then dt = clock() - stat.time_called end

		local time = stat.time_elapsed + dt
		reports[i] = {
			i,
			stat.label or "?",
			stat.num_calls,
			time - time % time_report_precision,
			stat.defined,
			stat.avg_time - stat.avg_time % time_report_precision,
			math.ceil(stat.total_mem),
			math.ceil(stat.avg_mem),
		}
	end

	return reports
end

-- todo: make these dynamic instead of hard-coded. Could use tuples of default sizes and cutoffs then clamp the stat value between them.
local col_positions = { 3, 23, 6, 15, 29, 10, 8, 6 }

-- Generates a text report of functions that have been called since the profile was started.
-- Returns the report as a string that can be printed to the console.
---@param limit number? Maximum number of rows
---@return string Text-based profiling report
function Profiler.report(limit)
	local result_strings = {}
	local results = Profiler.get_results(limit)

	for i, row in ipairs(results) do
		for j = 1, #row do
			local s = tostring(row[j])
			local l2 = col_positions[j]
			local l1 = s:len()

			assert(l2)
			if l1 < l2 then
				s = s .. space:rep(l2 - l1)
			elseif l1 > l2 then
				s = s:sub(l1 - l2 + 1, l1)
			end

			row[j] = s
		end

		result_strings[i] = table.concat(row, " | ")
	end

	-- todo: refactor all of this for dynamic sizing. I'd like to be able to fit it on half a screen but that's not likely now with memory stats.
	local row =
		" +-----+-------------------------+--------+-----------------+-------------------------------+------------+----------+--------+\n"
	local col =
		" | #   | Function                | Calls  | Time            | Code                          | Avg time   | Total kb | Avg kb |\n"
	local report_chart = row .. col .. row
	if #result_strings > 0 then
		report_chart = report_chart
			.. " | "
			.. table.concat(result_strings, " | \n | ")
			.. " | \n"
	end
	return "\n" .. report_chart .. row
end

function Profiler._sum(t)
	local x = 0
	for i = 1, #t do
		x = x + t[i]
	end
	return x
end

function Profiler._average(t) return Profiler._sum(t) / #t end

---@param file file?
---@return file
function Profiler._reset_file(file)
	if file and io.type(file) ~= "closed file" then assert(file:close()) end
	file = assert(io.tmpfile())
	return file
end

---@param file file A file full of numbers
---@return number[] All those numbers read into a table
function Profiler._read_file(file)
	assert(file:flush())
	assert(file:seek "set")

	local result = {}
	for n in file:lines "n" do
		result[#result + 1] = n
	end
	return result
end

-- store all internal profiler functions
for _, v in pairs(Profiler) do
	if type(v) == "function" then internal[v] = true end
end

return Profiler
