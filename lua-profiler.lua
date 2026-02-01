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

local baseline_memory <const> = collectgarbage "count"

-- Controls when to start or stop collecting data and can be used to generate reports.
---@module "Profiler"
local Profiler = {}

local utils = require "lua_utils"

local space <const> = " "

-- todo: Get user input to specify precision or fallback to this. Probably don't want them to have to type a bunch of zeros so I'll need to convert e.g. 7 to 0.0000001
local default_time_report_precision <const> = 0.000001

-- Amount of decimal places in time report. Doesn't affect actual stats, only report presentation.
local time_report_precision = default_time_report_precision

---@alias FuncStats {label: string, time_called: number, time_elapsed: number, num_calls: number, time_file: file, avg_time: number, total_mem: number, mem_file: file, avg_mem: number, start_mem: number, short_src: string, linedefined: number}

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
		time_file = assert(io.tmpfile()),
		mem_file = assert(io.tmpfile()),
	}
end

-- Pre-allocate a bunch of FuncStats to avoid messing with results.
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

local gc_cycles = 0
local gc_file = assert(io.tmpfile())
local last_cycle = 0
do
	local mt = {
		__gc = function(o)
			gc_cycles = gc_cycles + 1
			local now = clock()
			assert(gc_file:write(now - last_cycle))
			assert(gc_file:write(space))
			last_cycle = now
			setmetatable({}, getmetatable(o))
		end,
	}
	setmetatable({}, mt)
end

---@type number
local memory_to_ignore

---@param event string Event type
---@param line number  Line number
---@param info table? Debug info table
function Profiler._check_stats(event, line, info)
	-- note: I could refactor this out into separate functions but the overhead might mess with results. I should do it anyway this is nasty.
	info = info or debug.getinfo(2, "fnS")
	-- ignore the profiler itself
	if internal[info.func] or info.what ~= "Lua" then return end

	local stat_record = stats[info.func]

	if not stat_record then
		-- Check if this closure has already been recorded.
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
			local before = collectgarbage "count"
			stat_record = Profiler._new_func_stat()
			memory_to_ignore = memory_to_ignore + (collectgarbage "count" - before)
		else
			stat_record = stat
		end
		stats[info.func] = stat_record

		::closure_already_recorded::
	end

	-- get the function name if available
	if info.name then stat_record.label = info.name end

	-- find the line definition
	-- if not stat_record.defined then
	if not stat_record.short_src then
		stat_record.short_src = info.short_src
		stat_record.linedefined = info.linedefined
		stat_record.num_calls = 0
		stat_record.time_elapsed = 0
	end

	-- If time_called was set, that means we're exiting that function.
	if stat_record.time_called then
		-- Add function duration to total time
		local dt = clock() - stat_record.time_called
		stat_record.time_elapsed = stat_record.time_elapsed + dt
		stat_record.time_called = nil

		-- Record function duration to calculate avg afterwards.
		-- Doin it this way to avoid allocating a bajillion strings.
		assert(stat_record.time_file:write(dt))
		assert(stat_record.time_file:write(space))

		-- Add function memory usage to total mem
		assert(
			stat_record.start_mem and stat_record.total_mem,
			"You forgot to initialize mem fields"
		)

		local mem = collectgarbage "count" - stat_record.start_mem
		stat_record.total_mem = stat_record.total_mem + mem
		stat_record.start_mem = nil

		-- Record function memory usage to calculate avg afterwards.
		assert(stat_record.mem_file:write(mem))
		assert(stat_record.mem_file:write(space))
	end

	if event == "tail call" then
		local prev = debug.getinfo(3, "fnS")
		Profiler._check_stats("return", line, prev)
		Profiler._check_stats("call", line, info)
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
function Profiler.start() debug.sethook(Profiler._check_stats, "cr") end

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

		local converted_mem, size_unit =
			utils.convert_units(record.total_mem, "kb")
		-- utils.printf("%f to %f %s", record.total_mem, converted_mem, size_unit)

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
		record.label = nil
		record.time_called = nil
		record.time_elapsed = 0
		record.num_calls = 0
		record.avg_time = 0
		record.total_mem = 0
		record.avg_mem = nil
		record.start_mem = nil
		record.short_src = nil
		record.linedefined = nil

		record.time_file = Profiler._reset_file(record.time_file)
		record.mem_file = Profiler._reset_file(record.mem_file)

		table.insert(stats_pool, record)
	end

	gc_cycles = 0
	gc_file = Profiler._reset_file(gc_file)
	stats = {}
	collectgarbage "collect"
end

Profiler.SortingMethod = {
	NUM_CALLS = 1,
	TOTAL_TIME = 2,
	AVG_TIME = 3,
	TOTAL_MEM = 4,
	AVG_MEM = 5,
}

---@param a FuncStats First function
---@param b FuncStats Second function
---@return boolean True if "a" should rank higher than "b"
function Profiler._comp(a, b)
	local dt = b.time_elapsed - a.time_elapsed
	if dt == 0 then return b.num_calls < a.num_calls end
	return dt < 0
end

function Profiler._get_sorting_function(sort_by)
	if sort_by == Profiler.SortingMethod.NUM_CALLS then
		return function(a, b) return a.num_calls > b.num_calls end
	elseif sort_by == Profiler.SortingMethod.TOTAL_TIME then
		return function(a, b) return a.time_elapsed > b.time_elapsed end
	elseif sort_by == Profiler.SortingMethod.AVG_TIME then
		return function(a, b) return a.avg_time > b.avg_time end
	elseif sort_by == Profiler.SortingMethod.TOTAL_MEM then
		return function(a, b) return a.total_mem > b.total_mem end
	elseif sort_by == Profiler.SortingMethod.AVG_MEM then
		return function(a, b) return a.avg_mem > b.avg_mem end
	else
		-- default to num_calls
		return function(a, b) return a.num_calls > b.num_calls end
	end
end

local categories = {
	"rank",
	"definition",
	"num_calls",
	"time",
	"avg_time",
	"total_mem",
	"avg_mem",
}
local reverse_categories = {}
for i, v in ipairs(categories) do
	reverse_categories[v] = i
end

---@alias ColumnInfo {title: string, cutoff: integer}

---@type table<string, ColumnInfo>
local columns = {
	rank = { title = "#", cutoff = 3 },
	definition = { title = "Function", cutoff = 40 },
	num_calls = { title = "Calls", cutoff = 8 },
	time = { title = "Time", cutoff = 15 },
	avg_time = { title = "Avg time", cutoff = 10 },
	total_mem = { title = "Total kb", cutoff = 12 },
	avg_mem = { title = "Avg kb", cutoff = 6 },
}

---@alias Result {rank: integer, definition: string, num_calls: integer, time: number, avg_time: number, total_mem: number, avg_mem: number}

-- Generates a report of functions that have been called since the profile was started.
---@param limit number? Maximum number of results
---@return Result[] Table of results
function Profiler._get_results(sort_by, limit)
	limit = limit or 500

	---@type FuncStats[]
	local sorted_stats = {}
	for _, record in pairs(stats) do
		if record.num_calls and record.num_calls > 0 then
			sorted_stats[#sorted_stats + 1] = record
		end
	end

	table.sort(sorted_stats, Profiler._get_sorting_function(sort_by))

	while #sorted_stats > limit do
		table.remove(sorted_stats)
	end

	local reports = {}

	for i, stat in ipairs(sorted_stats) do
		local dt = 0
		if stat.time_called then dt = clock() - stat.time_called end

		local time = stat.time_elapsed + dt
		reports[i] = {
			rank = i,
			definition = string.format(
				"%s %s:%s",
				stat.label or "?",
				stat.short_src,
				stat.linedefined
			),
			num_calls = stat.num_calls,
			time = time - time % time_report_precision,
			avg_time = stat.avg_time - stat.avg_time % time_report_precision,
			-- todo: convert between kb and mb depending on size
			total_mem = utils.round(stat.total_mem),
			avg_mem = utils.round(stat.avg_mem),
		}
	end

	return reports
end

-- Generates a text report of functions that have been called since the profile was started. Returns the report as a string that can be printed to the console.
---@param sort_by Profiler.SortingMethod?
---@param limit number? Maximum number of rows
---@return string Text-based profiling report
function Profiler.report(sort_by, limit)
	local result_strings = {}
	local results = Profiler._get_results(sort_by, limit)

	for i, result in ipairs(results) do
		local row = {}
		for k, v in pairs(result) do
			local s = tostring(v)
			local cutoff = columns[k].cutoff
			local s_len = s:len()

			if s_len < cutoff then
				s = s .. space:rep(cutoff - s_len)
			elseif s_len > cutoff then
				s = s:sub(s_len - cutoff + 1, s_len)
			end

			local index = reverse_categories[k]
			row[index] = s
		end

		result_strings[i] = table.concat(row, " | ")
	end

	-- Dynamically build row and column borders and titles for each column.
	local row_separator, category_headers = " +", " | "
	for _, v in ipairs(categories) do
		local col_info = columns[v]
		row_separator = string.format(
			"%s%s+",
			row_separator,
			string.rep("-", col_info.cutoff + 2)
		)
		category_headers = string.format(
			"%s%s%s | ",
			category_headers,
			col_info.title,
			string.rep(space, col_info.cutoff - #col_info.title)
		)
	end
	row_separator = row_separator .. "\n"
	category_headers = category_headers .. "\n"

	local report_chart = row_separator .. category_headers .. row_separator
	if #result_strings > 0 then
		report_chart = report_chart
			.. " | "
			.. table.concat(result_strings, " | \n | ")
			.. " | \n"
	end

	local gc_report = gc_cycles > 1
			and string.format(
				"\ngc cycles: %d, gc run every %f on average",
				gc_cycles,
				Profiler._average(Profiler._read_file(gc_file))
			)
		or ""

	return "\n" .. report_chart .. row_separator .. gc_report
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

-- Collect this at the bottom so everything outside of functions won't count
-- towards profiling results when this module is "required".
---@diagnostic disable-next-line: unused
memory_to_ignore = collectgarbage "count" - baseline_memory

return Profiler
