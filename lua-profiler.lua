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

local clock = os.clock
local chronos = require("chronos")
if chronos then
	clock = chronos.nanotime
	print("Profiler found chronos. Upgrading clock function to chronos.nanotime")
end

-- The "profile" module controls when to start or stop collecting data and can be used to generate reports.
---@module "Profiler"
local Profiler = {}

---@type table<function, string> Function labels
local labeled = {}
---@type table<function, string> Function definitions
local defined = {}
---@type table<function, number?> Time of last call
local time_called = {}
-- total execution time
local time_elapsed = {}
-- number of calls
local num_calls = {}
-- list of internal profiler functions
local _internal = {}

--- This is an internal function.
---@param event string Event type
---@param line number  Line number
---@param info table? Debug info table
function Profiler.hooker(event, line, info)
	info = info or debug.getinfo(2, "fnS")
	local f = info.func
	-- ignore the profiler itself
	if _internal[f] or info.what ~= "Lua" then
		return
	end

	-- get the function name if available
	if info.name ~= nil then
		labeled[f] = info.name
	end

	-- find the line definition
	if not defined[f] then
		defined[f] = info.short_src .. ":" .. info.linedefined
		num_calls[f] = 0
		time_elapsed[f] = 0
	end

	--todo: record memory at function call and return/tail call
	if time_called[f] then
		local dt = clock() - time_called[f]
		time_elapsed[f] = time_elapsed[f] + dt
		time_called[f] = nil
	end

	if event == "tail call" then
		local prev = debug.getinfo(3, "fnS")
		Profiler.hooker("return", line, prev)
		Profiler.hooker("call", line, info)
	elseif event == "call" then
		time_called[f] = clock()
	else
		num_calls[f] = num_calls[f] + 1
	end
end

-- Sets a clock function to be used by the profiler.
---@param f function Clock function that returns a number
function Profiler.setclock(f)
	assert(type(f) == "function", "clock must be a function")
	clock = f
end

-- Starts collecting data.
function Profiler.start()
	debug.sethook(Profiler.hooker, "cr")
end

--- Stops collecting data.
function Profiler.stop()
	debug.sethook()

	for f in pairs(time_called) do
		local dt = clock() - time_called[f]
		time_elapsed[f] = time_elapsed[f] + dt
		time_called[f] = nil
	end

	-- merge closures
	local lookup = {}
	for f, d in pairs(defined) do
		local id = (labeled[f] or "?") .. d
		local f2 = lookup[id]
		if f2 then
			num_calls[f2] = num_calls[f2] + (num_calls[f] or 0)
			time_elapsed[f2] = time_elapsed[f2] + (time_elapsed[f] or 0)
			defined[f], labeled[f] = nil, nil
			num_calls[f], time_elapsed[f] = nil, nil
		else
			lookup[id] = f
		end
	end
	collectgarbage("collect")
end

--- Resets all collected data.
function Profiler.reset()
	for f in pairs(num_calls) do
		num_calls[f] = 0
	end

	for f in pairs(time_elapsed) do
		time_elapsed[f] = 0
	end

	for f in pairs(time_called) do
		time_called[f] = nil
	end

	collectgarbage("collect")
end

--- This is an internal function.
---@param a function First function
---@param b function Second function
---@return boolean True if "a" should rank higher than "b"
function Profiler.comp(a, b)
	local dt = time_elapsed[b] - time_elapsed[a]
	if dt == 0 then
		return num_calls[b] < num_calls[a]
	end
	return dt < 0
end

--- Generates a report of functions that have been called since the profile was started.
-- Returns the report as a numeric table of rows containing the rank, function label, number of calls, total execution time and source code line number.
---@param limit number? Maximum number of rows
---@return table Table of rows
function Profiler.query(limit)
	local t = {}
	for f, n in pairs(num_calls) do
		if n > 0 then
			t[#t + 1] = f
		end
	end

	table.sort(t, Profiler.comp)

	if limit then
		while #t > limit do
			table.remove(t)
		end
	end

	for i, f in ipairs(t) do
		local dt = 0
		if time_called[f] then
			dt = clock() - time_called[f]
		end
		t[i] = { i, labeled[f] or "?", num_calls[f], time_elapsed[f] + dt, defined[f] }
	end

	return t
end

local cols = { 3, 29, 11, 24, 32 }

--- Generates a text report of functions that have been called since the profile was started.
-- Returns the report as a string that can be printed to the console.
---@param n number? Maximum number of rows
---@return string Text-based profiling report
function Profiler.report(n)
	local out = {}
	local report = Profiler.query(n)

	for i, row in ipairs(report) do
		for j = 1, 5 do
			local s = row[j]
			local l2 = cols[j]
			s = tostring(s)
			local l1 = s:len()

			assert(l2)
			if l1 < l2 then
				s = s .. (" "):rep(l2 - l1)
			elseif l1 > l2 then
				s = s:sub(l1 - l2 + 1, l1)
			end

			row[j] = s
		end

		out[i] = table.concat(row, " | ")
	end

	local row =
		" +-----+-------------------------------+-------------+--------------------------+----------------------------------+ \n"
	local col =
		" | #   | Function                      | Calls       | Time                     | Code                             | \n"
	local sz = row .. col .. row
	if #out > 0 then
		sz = sz .. " | " .. table.concat(out, " | \n | ") .. " | \n"
	end
	return "\n" .. sz .. row
end

-- store all internal profiler functions
for _, v in pairs(Profiler) do
	if type(v) == "function" then
		_internal[v] = true
	end
end

return Profiler
