------------------------------------------------------------------------
-- Copyright (c) 2009 Scott Vokes <scott@silentbicycle.com>
--
-- Permission to use, copy, modify, and/or distribute this software for any
-- purpose with or without fee is hereby granted, provided that the above
-- copyright notice and this permission notice appear in all copies.
--
-- THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
-- WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
-- MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
-- ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
-- WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
-- ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
-- OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
------------------------------------------------------------------------
-- This is a library for randomized testing with Lua.
-- For usage and examples, see README and the test suite.
------------------------------------------------------------------------

local use_lrandom = true        -- prefer lhf's "random" package

------------
-- Module --
------------

-- standard library dependencies
local io, math, os, string, table = io, math, os, string, table

-- required core global funs
local assert, error, ipairs, pcall, print, setmetatable, tonumber =
   assert, error, ipairs, pcall, print, setmetatable, tonumber
local tostring, type, unpack = tostring, type, unpack

module(...)


-------------------
-- RNG Interface --
-------------------

local RNG = {}          -- prototype for RNG interface
function RNG:tostring() return "(RNG interface)" end
-- get_bool()           -> get a random bool
-- get_float(bound)     -> get a random float 0 <= x < bound
-- get_float(low, high) -> get a random float low <= x < high
-- get_int(bound)       -> get a random int 0 <= x < bound
-- get_int(low, high)   -> get a random int low <= x < high
-- get_seed()           -> get current seed
-- get_string(spec)     -> get a random string, according to spec
-- set_seed(s)          -> set the new random seed to s


-- Lua_number's bits of precision. IEEE 754 doubles have 52.
local function determine_accuracy()
   for i=1,128 do
      if 2^i == (2^i + 1) then return i - 1 end
   end
   return 128   --long long ints?
end
local bits_of_accuracy = determine_accuracy()


-- Metatable for RNG objects
local RNGmt = { __index=RNG, __tostring=RNG.tostring }

local value         -- value() -> float 0 <= x < 1
local valuelh       -- valuelh(low, high) -> int low <= x < high

-- Try to load lhf's random module[1], and fall back on math.random
-- if it isn't available. (This code gives them a common interface.)
-- [1]: (http://www.tecgraf.puc-rio.br/~lhf/ftp/lua/#lrandom)
if use_lrandom and pcall(function() 
                            require "random" 
                         end) then
--    print("USING RANDOM")
   RNG.limit = 2^bits_of_accuracy
   RNG.set_seed = function(self, s) 
                     self._r:seed(s) 
                  end

   value = function(self) return self._r:value() end
   valuelh = function(self, low, hi) return self._r:value(low, hi - 1) end
   RNG.new = function()
                return setmetatable({ _r = random.new() }, RNGmt)
             end
else
   RNG.limit = math.min(2^30, 2^bits_of_accuracy)
--    print("USING MATH")
   RNG.set_seed = function(self, s) 
                     math.randomseed(s) 
                  end

   value = function(self) return math.random() end
   valuelh = function(self, low, hi) return math.random(low, hi - 1) end
   RNG.new = function()
                return setmetatable({}, RNGmt)
             end
end


-- Get seed.
RNG.get_seed = function(self) return self._seed end


-- Get a random int.
-- r:get_int(3)       ->   0 <= x < 3
-- r:get_int(-2, 10)  ->  -2 <= x < 10
RNG.get_int = function(self, low, hi)
                 if hi then 
                    assert(hi > low, "Bad range")
                    return valuelh(self, low, hi)
                 else 
                    if low <= 1 then 
                    error("For get_int(n), n must be > 1.") 
                    end
                    return valuelh(self, 0, low - 1)
                 end
              end


-- Get a random float.
-- r:get_float(3, 5)  ->  3.0 <= x < 5.0
RNG.get_float = function(self, low, hi)
                   return RNG.get_int(self, low, hi) + value(self)
                end


--------------------
-- Random strings --
--------------------

-- For valid char classes, see Lua Reference Manual 5.1, p. 77
-- or http://www.lua.org/manual/5.1/manual.html#5.4.1 .
local function charclass(pat)
   local m = {}

   local match, char = string.match, string.char
   for i=0,255 do
      local c = char(i)
      if match(c, pat) then m[#m+1] = c end
   end

   return table.concat(m)
end


-- Return a (RNG -> random char) iterator from a pattern.
local function parse_pattern(pattern)
   local cs = {}                --charset
   local idx = 1
   local len = string.len(pattern)
   assert(len > 0, "Cannot generate pattern from empty string.")

   local function at_either_end() return #cs == 0 or #cs == len end
   local function slice(i) return string.sub(pattern, i, i) end

   while idx <= len do
      local c = slice(idx)

      if c == "-" then
         if at_either_end() then
            cs[#cs+1] = c    --literal - at start or end
         else                --range
            local low = string.byte(slice(idx-1)) + 1
            local high = string.byte(slice(idx+1))
            assert(low < high, "Invalid character range: " .. pattern)
            for asc=low,high do
               cs[#cs+1] = string.char(asc)
            end
            idx = idx + 1
         end

      elseif c == "%" then
         local nextc = slice(idx + 1)
         cs[#cs+1] = charclass("%" .. nextc)
         idx = idx + 1

      else
         cs[#cs+1] = c
      end
      idx = idx + 1
   end

   cs = table.concat(cs)
   local len = string.len(cs)
   assert(len > 0, "Empty charset")

   return function(r)
             local idx = r:get_int(len) + 1
             return string.sub(cs, idx, idx)
          end
end


-- Read a random string spec, return a config table.
local function parse_randstring(s)
   local low, high, rest = string.match(s, "([0-9]+),?([0-9]*) (.*)")
   if low then                  --any match
      if high == "" then high = low end
      return { low = tonumber(low),
               high = tonumber(high),
               gen = parse_pattern(rest) }
   else
      local err = "Invalid random string spec: " .. s
      error(err, 2)
   end
end


-- Use with arg e.g. "20 listoftwentycharstogenerate" or "10,20 %l".
function RNG:get_string(arg)
   local spec = assert(parse_randstring(arg), "bad pattern")
   local ct, diff
   diff = spec.high - spec.low
   if diff == 0 then ct = spec.low  else
      ct = self:get_int(diff) + spec.low
   end

   local acc = {}
   for i=1,ct do
      acc[i] = spec.gen(self)
   end
   return table.concat(acc)
end


-----------------
-- Other types --
-----------------

-- Random bool. Simple.
function RNG:get_bool()
   return self:get_int(2) == 1
end


-- Generate a random number, according to arg.
local function gen_number(r, arg)
   local signed = (arg < 0)
   local float
   if signed then float = (math.ceil(arg) ~= arg) else
      float = (math.floor(arg) ~= arg)
   end

   local f = float and r.get_float or r.get_int
   if signed then
      return f(r, arg, -arg)
   else
      return f(r, arg)
   end
end


-- Create an arbitrary instance of a value.
local function generate_arbitrary(r, arg)
   local t = type(arg)
   if t == "number" then
      return gen_number(r, arg)
   elseif t == "function" then
      return arg(r)                   -- assume f(r) -> val
   elseif t == "string" then
      return r:get_string(arg)
   elseif t == "table"  or t == "userdata" then
      assert(arg.__random, t .. " has no __random method")
      return arg.__random(r)          -- assume arg.__random(r) -> val
   elseif t == "boolean" then
      return r:get_bool()
   else
      error("Cannot randomly generate values of type " .. t .. ".")
   end
end


-- Process test case args.
local function proc_args(arglist)
   local name, pred, args
   if type(arglist[1]) == "string" then
      name = arglist[1]
      table.remove(arglist, 1)
   else name = "" end

   local pred = arglist[1]
   assert(type(pred) == "function",
          "First argument (after optional name) must be trial function.")
   table.remove(arglist, 1)

   return name, pred, arglist
end


-----------------
-- Test runner --
-----------------

local Tester = {}               -- tester prototype

-- Log progress.
function Tester:log(...) 
   self._out:write(string.format(...)) 
   io.flush(self._out)
end


-- Show progress, according to verbosity.
function Tester:show_progress(log, res, seed, trials, 
                              pass, fail, skip, err)
   if self.verbose == true then
      self:log("%-4s %-20s (+%d, -%d, s%d, e%d)\n",
               res, seed, pass, fail, skip, err)
   elseif (trials % self._progress == 0 and self._count > 0) then
      self:log "."       -- "Brevity is the soul of wit." - W. S.
   end
end


function Tester:tostring() 
   return string.format([[
(random_tester {seed=%d, verbose=%s, progress=%d, skips_allowed=%d} )]],
    self._seed, tostring(self._verbose or false), 
    self._progress, self._skips_allowed)
end

function Tester:set_seed(s) 
   self._seed = s
   self.rng:set_seed(s) 
end


-- Construct a random testing function.
function new(opt)
   opt = opt or {}
   local t = {}                 --new tester
   t._count = opt.count or 100
   t._seed = opt.seed or os.time()
   t._skips_allowed = opt.skips or 50
   t._verbose = opt.verbose or false
   t._progress = opt.progress or 10
   t.rng = RNG.new()
   t._randbound = 2^bits_of_accuracy
   t._out = opt.log or io.stdout
   t.show_progress = opt.show_progress   -- optionally replace progress hook

   return setmetatable(t, { __index=Tester, __tostring=Tester.tostring })
end

-- Run an actual test.
function Tester:test(...)
   local name, check, args = proc_args{ ... }
   
   local padded_name = (name ~= "" and name .. ":\t") or ""

   self:log("%s%d trials, seed %10s: ", padded_name, self._count, self._seed)
   if self._verbose == true then self:log("\n") end
   local rng = self.rng
   
   local passed = 0
   local failed = 0
   local skipped = 0
   local errors = 0
   
   for trial=1,self._count do
      -- Get & save the current seed, so we can report it.
      local thisseed = rng:get_int(rng.limit)
      self:set_seed(thisseed)
      
      local callargs = {}
      for i=1, #args do
         callargs[i] = generate_arbitrary(rng, args[i])
      end
      local status, res = pcall(check, unpack(callargs))
      
      if status then         -- completed without error(...)
         -- results of "pass", "skip" caught implicitly
         if res then res = "pass" else res = "fail" end
      else   -- actual error or error("skip"), error("fail"), etc.
         local ok = { pass=true, skip=true, fail=true }
         local errval = res
         res = string.sub(res, -4) -- error is preceded by file:line
         if not ok[res] then
            res = "error"
            self:log("\nERROR: seed %d, %s", thisseed,
                     res or "(error() returned nil)")
            errors = errors + 1
         end
      end
      
      if res == "pass" then passed = passed + 1
      elseif res == "fail" then
         if self._verbose ~= "error_only" then
            self:log("\n%sFailed -- %s (+%d, -%d)",
               padded_name, thisseed, passed, failed)
         end
         failed = failed + 1
         
      elseif res == "skip" then
         skipped = skipped + 1
         if skipped > skips_allowed then
            self:log("\n%sWarning -- %d skips at %d of %d trials (+%d, -%d).\n",
               padded_name, skips_allowed, trial, count, passed, failed)
            return
         end
         
      else
         assert(res == "error")
         errors = errors + 1
      end
      
      if (res == "fail" and self._verbose ~= "error_only")
         or res == "error" then
         self:log("\n")
         for idx,arg in ipairs(callargs) do
            self:log("    %d -- %s\n", idx, tostring(arg))
         end
      end
      
      self:show_progress(log, res, thisseed, trial, passed,
                         failed, skipped, errors)
   end
   
   if self._verbose == true then self:log("total %s", name) end
   local overall_status = (passed == self._count and "PASS" or "FAIL")
   self:log(" %s (+%d, -%d, s%d, e%d)\n",
            overall_status, passed, failed, skipped, errors)
   if self._verbose == true then self:log("\n") end
   
   if overall_status == "PASS" then return true end
end