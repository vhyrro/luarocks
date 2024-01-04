local rockspecs = {}

local cfg = require("luarocks.core.cfg")
local dir = require("luarocks.dir")
local path = require("luarocks.path")
local queries = require("luarocks.queries")
local type_rockspec = require("luarocks.type.rockspec")
local util = require("luarocks.util")
local vers = require("luarocks.core.vers")

---@enum (key) VendoredBuildType
local vendored_build_type_set = {
   ["builtin"] = true,
   ["cmake"] = true,
   ["command"] = true,
   ["make"] = true,
   ["module"] = true, -- compatibility alias
   ["none"] = true,
}

---@class rockspec.build.install
---@field lua?  table<string, any> Lua modules written in Lua.
---@field lib?  table<string, any> Dynamic libraries implemented compiled Lua modules.
---@field conf? table<string, any> Configuration files.
---@field bin?  table<string, any> Lua command-line scripts.

---@class rockspec.build
---@field type              VendoredBuildType|string The LuaRocks build back-end to use.
---@field install?          rockspec.build.install Installation instructions for LuaRocks.
---@field copy_directories? string[] List of directories in the source directory to be copied to the rock installation prefix as-is. Useful for installing documentation and other files such as samples and tests. Default is {"doc"} for documentation to be locally installed in the rocktree.
---@field patches?          table<string, string>

---@class (exact) rockspec.source
---@field url      string The URL of the package source archive.
---@field md5?     string The MD5 sum for the source archive.
---@field file?    string The filename of the source archive. Can be omitted if it can be inferred from the `source.url` field.
---@field dir?     string The name of the directory created when the source archive is unpacked. Can be omitted if it can be inferred from the `source.file` field.
---@field tag?     string For SCM-based URL protocols such as "cvs://" and "git://", this field can be used to specify a tag for checking out sources.
---@field cvs_tag? string Deprecated, backwards-compatible alternative to `source.tag`.
---@field branch?  string For SCM-based URL protocols such as "git://", this field can be used to specify a branch for checking out sources.
---@field module?  string For SCM-based URL protocols such as "cvs://" and "git://", this field can be used to specify the module to be checked out. Can be omitted if it is the same as the basename of the `source.url` field.
---
---@field package protocol? string
---@field package pathname? string
---@field package cvs_module? string
---@field package dir_set? boolean

---@class (exact) rockspec.description
---@field summary?    string A one-line description of the package.
---@field detailed?   string A longer description of the package.
---@field license?    string The license used by the package. A short name, such as "MIT" and "GPL-2" is preferred. Software using the same license as Lua 5.x should use "MIT".
---@field homepage?   string An URL for the project. This is not the URL for the tarball, but the address of a website.
---@field issues_url? string An URL for the project's issue tracker.
---@field maintainer? string Contact information for the rockspec maintainer (which may or may not be the package maintainer - contact for the package maintainer can usually be obtained through the address in the homepage field).
---@field labels?     string[] A list of short strings that specify labels for categorization of this rock. See the list of labels at [http://luarocks.org] for inspiration.

---@class (exact) rockspec.variables
---@field BINDIR string
---@field CONFDIR string
---@field DOCDIR string
---@field LIBDIR string
---@field LUADIR string
---@field PREFIX string

---@alias Dependencies string[]
---@alias ExternalDependencies table<string, { header?: string, library?: string }>

---@class (exact) rockspec
---@field build? rockspec.build
---@field build_dependencies? Dependencies
---@field dependencies? Dependencies
---@field description? rockspec.description
---@field external_dependencies? ExternalDependencies
---@field package string
---@field rockspec_format? string
---@field source rockspec.source
---@field test table
---@field test_dependencies Dependencies
---@field version string
---
---@field package format_is_at_least fun(self, version: string): boolean
---@field package hooks? unknown
---@field package local_abs_filename? any
---@field package name? string
---@field package rocks_provided? table<string, string>
---@field package variables rockspec.variables

---@type metatable
local rockspec_mt = {}

rockspec_mt.__index = rockspec_mt

function rockspec_mt.type()
   return "rockspec"
end

--- Perform platform-specific overrides on a table.
-- Overrides values of table with the contents of the appropriate
-- subset of its "platforms" field. The "platforms" field should
-- be a table containing subtables keyed with strings representing
-- platform names. Names that match the contents of the global
-- detected platforms setting are used. For example, if
-- platform "unix" is detected, then the fields of
-- tbl.platforms.unix will overwrite those of tbl with the same
-- names. For table values, the operation is performed recursively
-- (tbl.platforms.foo.x.y.z overrides tbl.x.y.z; other contents of
-- tbl.x are preserved).
-- @param tbl table or nil: Table which may contain a "platforms" field;
-- if it doesn't (or if nil is passed), this function does nothing.
---@param tbl { platforms: table<string, string> }
local function platform_overrides(tbl)
   assert(type(tbl) == "table" or not tbl)

   if not tbl then return end

   if tbl.platforms then
      for platform in cfg.each_platform() do
         local platform_tbl = tbl.platforms[platform]
         if platform_tbl then
            util.deep_merge(tbl, platform_tbl)
         end
      end
   end
   tbl.platforms = nil
end

---
---@param rockspec rockspec
---@param key string
---@return boolean? success
---@return string? error
local function convert_dependencies(rockspec, key)
   if rockspec[key] then
      for i = 1, #rockspec[key] do
         local parsed, err = queries.from_dep_string(rockspec[key][i])
         if not parsed then
            return nil, "Parse error processing dependency '"..rockspec[key][i].."': "..tostring(err)
         end
         rockspec[key][i] = parsed
      end
   else
      rockspec[key] = {}
   end
   return true
end

--- Set up path-related variables for a given rock.
-- Create a "variables" table in the rockspec table, containing
-- adjusted variables according to the configuration file.
---@param rockspec rockspec The rockspec table.
local function configure_paths(rockspec)
   local vars = {}
   for k,v in pairs(cfg.variables) do
      vars[k] = v
   end
   local name, version = rockspec.name, rockspec.version
   vars.PREFIX = path.install_dir(name, version)
   vars.LUADIR = path.lua_dir(name, version)
   vars.LIBDIR = path.lib_dir(name, version)
   vars.CONFDIR = path.conf_dir(name, version)
   vars.BINDIR = path.bin_dir(name, version)
   vars.DOCDIR = path.doc_dir(name, version)
   rockspec.variables = vars
end

---@param rockspec rockspec
function rockspecs.from_persisted_table(filename, rockspec, globals, quick)
   assert(type(rockspec) == "table")
   assert(type(globals) == "table" or globals == nil)
   assert(type(filename) == "string")
   assert(type(quick) == "boolean" or quick == nil)

   if rockspec.rockspec_format then
      if vers.compare_versions(rockspec.rockspec_format, type_rockspec.rockspec_format) then
         return nil, "Rockspec format "..rockspec.rockspec_format.." is not supported, please upgrade LuaRocks."
      end
   end

   if not quick then
      local ok, err = type_rockspec.check(rockspec, globals or {})
      if not ok then
         return nil, err
      end
   end

   --- Check if rockspec format version satisfies version requirement.
   -- @param rockspec table: The rockspec table.
   -- @param version string: required version.
   -- @return boolean: true if rockspec format matches version or is newer, false otherwise.
   do
      local parsed_format = vers.parse_version(rockspec.rockspec_format or "1.0")
      rockspec.format_is_at_least = function(_, version)
         return parsed_format >= vers.parse_version(version)
      end
   end

   platform_overrides(rockspec.build)
   platform_overrides(rockspec.dependencies)
   platform_overrides(rockspec.build_dependencies)
   platform_overrides(rockspec.test_dependencies)
   platform_overrides(rockspec.external_dependencies)
   platform_overrides(rockspec.source)
   platform_overrides(rockspec.hooks)
   platform_overrides(rockspec.test)

   rockspec.name = rockspec.package:lower()

   local protocol, pathname = dir.split_url(rockspec.source.url)
   if dir.is_basic_protocol(protocol) then
      rockspec.source.file = rockspec.source.file or dir.base_name(rockspec.source.url)
   end
   rockspec.source.protocol, rockspec.source.pathname = protocol, pathname

   -- Temporary compatibility
   if rockspec.source.cvs_module then rockspec.source.module = rockspec.source.cvs_module end
   if rockspec.source.cvs_tag then rockspec.source.tag = rockspec.source.cvs_tag end

   rockspec.local_abs_filename = filename
   rockspec.source.dir_set = rockspec.source.dir ~= nil
   rockspec.source.dir = rockspec.source.dir or rockspec.source.module

   rockspec.rocks_provided = util.get_rocks_provided(rockspec)

   for _, key in ipairs({"dependencies", "build_dependencies", "test_dependencies"}) do
      local ok, err = convert_dependencies(rockspec, key)
      if not ok then
         return nil, err
      end
   end

   if rockspec.build
      and rockspec.build.type
      and not vendored_build_type_set[rockspec.build.type] then
      local build_pkg_name = "luarocks-build-" .. rockspec.build.type
      if not rockspec.build_dependencies then
         rockspec.build_dependencies = {}
      end

      local found = false
      -- TODO(docs): We are casting to a table because `convert_dependencies` changed
      -- the structure of the dependency tables. We should create a type for that specific
      -- table type and then cast to that instead.
      for _, dep in ipairs(rockspec.build_dependencies --[[@as table]]) do
         if dep.name == build_pkg_name then
            found = true
            break
         end
      end

      if not found then
         table.insert(rockspec.build_dependencies, (queries.from_dep_string(build_pkg_name)))
      end
   end

   if not quick then
      configure_paths(rockspec)
   end

   return setmetatable(rockspec, rockspec_mt)
end

return rockspecs
