--- lulip: LuaJIT line level profiler
--- Copyright (c) 2013 John Graham-Cumming
--- License: http://opensource.org/licenses/MIT

--- Update 2016 - Adrien Bertrand:
--- * Fix missing '>' in HTML
--- * Fix code highlighter script source
--- * Add average time per call column
--- * Add script to use DataTable on the table (jQuery plugin)
--- * LuaCov integration (the caller calls init) with debug hook chaining
--- * ignore func ('dont' alias), ignoreFiles func
--- * ignoreLine func / codeIgnore table
--- * Methods can be chained

local io_lines      = io.lines
local io_open       = io.open
local io_close      = io.close
local pairs         = pairs
local ipairs        = ipairs
local print         = print
local debug         = debug
local tonumber      = tonumber
local setmetatable  = setmetatable
local table_sort    = table.sort
local table_insert  = table.insert
local string_find   = string.find
local string_sub    = string.sub
local string_gsub   = string.gsub
local string_match  = string.match
local string_format = string.format

local constRemoveMeCodeLine = '~~~!REMOVE_ME!~~~'

local __luacov_enabled__ = os.getenv("LUATESTS_DO_COVERAGE") == "1"
local __local_luacov_runner__
if __luacov_enabled__ then
   __local_luacov_runner__ = require("luacov.runner")
   local params = { exclude = { "/share/lua/", "_spec" }, codefromstrings = true, deletestats = true, runreport = true }
   __local_luacov_runner__.init(params)
end

local ffi = require("ffi")

ffi.cdef[[
  typedef long time_t;

  typedef struct timeval {
    time_t tv_sec;
    time_t tv_usec;
  } timeval;

  int gettimeofday(struct timeval* t, void* tzp);
]]

module(...)

local gettimeofday_struct = ffi.new("timeval")
local function gettimeofday()
   ffi.C.gettimeofday(gettimeofday_struct, nil)
   return tonumber(gettimeofday_struct.tv_sec) * 1000000 + tonumber(gettimeofday_struct.tv_usec)
end

local mt = { __index = _M }

-- new: create new profiler object
function new(self)
   return setmetatable({
      -- Time when start() and stop() were called in microseconds
      start_time = 0,
      stop_time = 0,

      -- Per line timing information
      lines = {},

      -- The current line being processed and when it was startd
      current_line = nil,
      current_start = 0,

      -- List of files to ignore. Set patterns using dont()
      ignore = { '/.luarocks/', '/busted/', '_spec' },

      -- List of patters for lines to ignore.
      codeIgnore = { '%f[%a_]assert%.' }, -- default: busted assert.*

      -- List of short file names used as a cache
      short = {},

      -- Maximum number of rows of output data, set using maxrows()
      rows = 30,
   }, mt)
end

-- event: called when a line is executed
function event(self, event, line)
   local now = gettimeofday()

   local f = string_sub(debug.getinfo(3).source,2)
   for i=1,#self.ignore do
      if string_find(f, self.ignore[i], 1, true) then
         return
      end
   end

   local short = self.short[f]
   if not short then
      self.short[f] = string_match(f, '([^/]+)$') or "?"
      short = self.short[f]
   end

   if self.current_line ~= nil then
      self.lines[self.current_line][1] = self.lines[self.current_line][1] + 1
      self.lines[self.current_line][2] = self.lines[self.current_line][2] + (now - self.current_start)
   end

   self.current_line = short .. ':' .. line

   if self.lines[self.current_line] == nil then
      self.lines[self.current_line] = {0, 0.0, f}
   end

   self.current_start = gettimeofday()
end

-- dont: tell the profiler to ignore files that match these patterns
function dont(self, file)
   table_insert(self.ignore, file)
   return self
end
ignoreFile = dont
function ignoreFiles(self, files)
   for _,file in pairs(files) do
      ignoreFile(self, file)
   end
   return self
end

function ignoreline(self, line)
   table_insert(self.codeIgnore, line)
   return self
end

-- maxrows: set the maximum number of rows of output
function maxrows(self, max)
   self.rows = max
   return self
end

-- start: begin profiling
function start(self)
   self:dont('lulip.lua')
   self.start_time = gettimeofday()
   self.current_line = nil
   self.current_start = 0
   if __luacov_enabled__ then
      debug.sethook(function(e,l) __local_luacov_runner__.debug_hook(e,l, 3) self:event(e, l) end, "l")
   else
      debug.sethook(function(e,l) self:event(e, l) end, "l")
   end
   return self
end

-- stop: end profiling
function stop(self)
   self.stop_time = gettimeofday()
   debug.sethook()
   return self
end

local function file_exists(name)
   local f=io_open(name,"r")
   if f~=nil then io_close(f) return true else return false end
end

-- readfile: turn a file into an array for line-level access
local function readfile(self, file)
   if not file_exists(file) then return {} end
   local lines = {}
   local ln = 1
   for line in io_lines(file) do
      local isIgnoredLine = false
      for _,v in ipairs(self.codeIgnore) do
         if string_match(line, v) then
            isIgnoredLine = true
            break
         end
      end
      lines[ln] = isIgnoredLine and constRemoveMeCodeLine or string_gsub(line, "^%s*(.-)%s*$", "%1")
      ln = ln + 1
   end
   return lines
end

-- dump: dump profile information to the named file
function dump(self, file)
   local t = {}
   for l,d in pairs(self.lines) do
      table_insert(t, {line=l, data=d})
   end
   table_sort(t, function(a,b) return a["data"][2] > b["data"][2] end)

   local files = {}

   local f = io_open(file, "w")
   if not f then
      print("Failed to open output file " .. file)
      return
   end
   f:write([[
      <html>
      <head>
      <link rel="stylesheet" type="text/css" href="https://cdn.datatables.net/1.10.12/css/jquery.dataTables.min.css">

      <script src="https://code.jquery.com/jquery-3.1.1.min.js"></script>
      <script src="https://cdn.rawgit.com/google/code-prettify/master/loader/run_prettify.js"></script>
      <script src="https://cdn.datatables.net/1.10.12/js/jquery.dataTables.min.js"></script>
      <style>
      #profileTable tbody td { padding: 4px 12px; }
      </style>
      </head>

      <body>

      <table id="profileTable" width="100%">
      <thead>
      <tr>
        <th align="left">file:line</th>
        <th align="right">count</th>
        <th align="right">total elapsed (ms)</th>
        <th align="right">call avg elapsed (ms)</th>
        <th align="left" class="code">line</th>
      </tr>
      </thead>
      <tbody>
]])

   for j=1,self.rows do
      if not t[j] then break end
      local l = t[j]["line"]
      local d = t[j]["data"]
      if not files[d[3]] then
         files[d[3]] = readfile(self, d[3])
      end
      local ln = tonumber(string_sub(l, string_find(l, ":", 1, true)+1))
      local code = files[d[3]][ln]
      if code ~= constRemoveMeCodeLine then
         f:write(string_format([[
            <tr>
              <td>%s</td>
              <td align="right">%i</td>
              <td align="right">%.3f</td>
              <td align="right">%.3f</td>
              <td class="code"><code class="prettyprint">%s</code></td>
            </tr>]], l, d[1], d[2]/1000, (d[2]/1000)/d[1], files[d[3]][ln]))
      end
   end
   f:write([[</tbody>
            </table>

            <script>
            $(document).ready(function(){
              $('#profileTable').DataTable({
                paging: false,
                order: [ [ 2, 'desc' ], [ 1, 'desc' ] ]
              });
            });
            </script>

            </body>
            </html>]])
   f:close()
   return self
end
