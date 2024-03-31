local function script_path()
	local str = debug.getinfo(2, "S").source:sub(2)
	return str:match("(.*/)")
end

package.path = package.path .. ";" .. script_path() .. "/?.lua"

local dt = require("darktable")
local du = require("lib/dtutils")
local json = require("lib/dkjson")

local function t_contains(t, value)
	if next(t) == nil then
		return false
	else
		for _, v in pairs(t) do
			if v == value then
				return true
			end
		end
		return false
	end
end

local function set_tags(image, here)
	if here then
		dt.tags.attach(dt.tags.create("git-annex|here"), image)
		dt.tags.detach(dt.tags.create("git-annex|dropped"), image)
		-- update the thumbnail here
	else
		dt.tags.detach(dt.tags.create("git-annex|here"), image)
		dt.tags.attach(dt.tags.create("git-annex|dropped"), image)
		-- save the thumbnail here
	end

	dt.tags.attach(dt.tags.create("git-annex|annexed"), image)
end

-- borrowed from http://lua-users.org/lists/lua-l/2010-07/msg00087.html
local shell = {}

local function shell_escape(...)
	local command = type(...) == "table" and ... or { ... }
	for i, s in ipairs(command) do
		s = (tostring(s) or ""):gsub('"', '\\"')
		if s:find('[^A-Za-z0-9_."/-]') then
			s = '"' .. s .. '"'
		elseif s == "" then
			s = '""'
		end
		command[i] = s
	end
	return table.concat(command, " ")
end

local function shell_exeute(...)
	local cmd = shell_escape(...)
	print(cmd)
	--return os.execute(shell_escape(...))
	return os.execute(cmd)
end

local function shell_popen(...)
	local cmd = shell_escape(...)
	--print(cmd)
	--return os.execute(shell_escape(...))
	return io.popen(cmd)
end

-- end borrowed

local function annex_rootdir(image)
	local f_annex_rootdir = shell_popen({ "git", "-C", image.path, "rev-parse", "--show-toplevel" })
	return f_annex_rootdir:read("l")
end
local function annex_rootdir_bypath(path)
	local f_annex_rootdir = shell_popen({ "git", "-C", path, "rev-parse", "--show-toplevel" })
	return f_annex_rootdir:read("l")
end

local function call_git_annex_bulk(cmd, annex_path, ...)
	--local annex_path = file_chooser_button.value
	local command = { "git", "-C", annex_path, "annex", cmd, ... }
	return shell_exeute(command)
end

local function call_git_annex_p(annex_path, cmd, ...)
	local command = { "git", "-C", annex_path, "annex", cmd, ... }
	return shell_popen(command)
end

-- borrowed from http://en.wikibooks.org/wiki/Lua_Functional_Programming/Functions
local function map(func, array)
	local new_array = {}
	for i, v in ipairs(array) do
		new_array[i] = func(v)
	end
	return new_array
end
-- end borrowed

local function get_status(images)
	local paths = {}
	for _, image in ipairs(images) do
		if not paths[image.path] then
			paths[image.path] = {}
		end
		paths[image.path][image.filename] = image
	end

	for path, path_images in pairs(paths) do
		local filenames = {}
		for _, image in pairs(path_images) do
			table.insert(filenames, image.filename)
		end
		-- If there are more than 25 files, it's probably quicker to just
		-- load everything.
		if #filenames > 25 then
			filenames = {}
		end
		local out = call_git_annex_p(path, "whereis", "-j", table.unpack(filenames))
		for line in out:lines() do
			local status = json.decode(line)
			local whereis = status["whereis"]
			local here = false
			for _, location in ipairs(whereis) do
				if location["here"] then
					here = true
				end
			end
			if path_images[status["file"]] then
				set_tags(path_images[status["file"]], here)
			end
		end
	end
end

-- executes git annex with the given subcommand on the selected files
--   cmd - string, the git annex subcommand
--   msg - string, the verb to be displayed to the user
--   on_collection - bool, true if action shall be executed on whole collection, otherwise false
local function git_annex_bulk(cmd, msg, on_collection)
	local images = {}
	local notice = msg .. " from git annex"
	dt.print(notice)
	if on_collection then
		local col_images = dt.collection
		for i, image in ipairs(col_images) do
			table.insert(images, i, image)
		end
	else
		images = dt.gui.selection()
	end
	local t = {}
	local imagesMetatable = {
		__index = function(t, k, value)
			rawset(t, k, { value })
			return t
		end,
	}
	setmetatable(t, imagesMetatable)
	local function addfile(t, rootdir, filename)
		if type(t[rootdir]) == "table" then
			table.insert(t[rootdir], filename)
		end
	end
	for _, image in pairs(images) do
		addfile(t, annex_rootdir(image), image.path .. "/" .. image.filename)
	end
	for rootdir, filelist in pairs(t) do
		local result = call_git_annex_bulk(cmd, rootdir, table.unpack(filelist))
		if result then
			dt.print("finished " .. notice .. " in repository: " .. rootdir)
			get_status(images)
		else
			dt.print("errored " .. notice .. " in repository: " .. rootdir)
			get_status(images)
		end
	end
end

du.check_min_api_version("7.0.0", "darktable-git-annex module")

-- return data structure for script_manager

local script_data = {}

script_data.destroy = nil -- function to destory the script
script_data.destroy_method = nil -- set to hide for libs since we can't destroy them commpletely yet, otherwise leave as nil
script_data.restart = nil -- how to restart the (lib) script after it's been hidden - i.e. make it visible again
script_data.show = nil -- only required for libs since the destroy_method only hides them

-- translation

-- https://www.darktable.org/lua-api/index.html#darktable_gettext
local gettext = dt.gettext

gettext.bindtextdomain("git annex module", dt.configuration.config_dir .. "/lua/locale/")

local function _(msgid)
	return gettext.dgettext("git annex module", msgid)
end

-- declare a local namespace and a couple of variables we'll need to install the module
local mE = {}
mE.widgets = {}
mE.event_registered = false -- keep track of whether we've added an event callback or not
mE.module_installed = false -- keep track of whether the module is module_installed

--[[ We have to create the module in one of two ways depending on which view darktable starts
in.  In orker to not repeat code, we wrap the darktable.register_lib in a local function.
]]

local function install_module()
	if not mE.module_installed then
		-- https://www.darktable.org/lua-api/index.html#darktable_register_lib
		dt.register_lib(
			"git annex module", -- Module name
			"git annex module", -- name
			true, -- expandable
			false, -- resetable
			{ [dt.gui.views.lighttable] = { "DT_UI_CONTAINER_PANEL_RIGHT_CENTER", 100 } }, -- containers
			-- https://www.darktable.org/lua-api/types_lua_box.html
			dt
				.new_widget("box") -- widget
				({
					orientation = "vertical",
					dt.new_widget("section_label")({
						label = "git annex",
					}),
					table.unpack(mE.widgets),
				}),
			nil, -- view_enter
			nil -- view_leave
		)
		mE.module_installed = true
	end
end

-- script_manager integration to allow a script to be removed
-- without restarting darktable
local function destroy()
	dt.gui.libs["git annex module"].visible = false -- we haven't figured out how to destroy it yet, so we hide it for now
end

local function restart()
	dt.gui.libs["git annex module"].visible = true -- the user wants to use it again, so we just make it visible and it shows up in the UI
end

-- https://www.darktable.org/lua-api/types_lua_separator.html
local separator = dt.new_widget("separator")({
	orientation = "horizontal",
})

local selection_button_box = dt.new_widget("box")({
	orientation = "horizontal",
	sensitive = false,
	dt.new_widget("button")({
		label = _("Selection: add"),
		clicked_callback = function(_)
			git_annex_bulk("add", "get", false)
		end,
	}),
	dt.new_widget("button")({
		label = _("Selection: get"),
		clicked_callback = function(_)
			git_annex_bulk("get", "get", false)
		end,
	}),
	dt.new_widget("button")({
		label = _("Selection: drop"),
		clicked_callback = function(_)
			git_annex_bulk("drop", "drop", false)
		end,
	}),
})
local collection_button_box = dt.new_widget("box")({
	orientation = "horizontal",
	dt.new_widget("button")({
		label = _("Collection: add"),
		clicked_callback = function(_)
			git_annex_bulk("add", "add", true)
		end,
	}),
	dt.new_widget("button")({
		label = _("Collection: get"),
		clicked_callback = function(_)
			git_annex_bulk("get", "get", true)
		end,
	}),
	dt.new_widget("button")({
		label = _("Collection: drop"),
		clicked_callback = function(_)
			git_annex_bulk("drop", "drop", true)
		end,
	}),
})
local section_sync = dt.new_widget("section_label")({
	label = "sync",
})
local syncdir_entry = dt.new_widget("text_view")({
	tooltip = "list of directories to sync, one per line",
	-- text = [[/path/to/repository]]
})
local sync_separator = dt.new_widget("separator")({
	orientation = "horizontal",
})
local sync_checkbox = true

local function text2table(s)
	local t = {}
	for line in string.gmatch(s, "[^\r\n]+") do
		table.insert(t, line)
	end
	return t
end

local syncbox = dt.new_widget("box")({
	orientation = "horizontal",
	dt.new_widget("button")({
		label = _("git annex sync"),
		clicked_callback = function(_)
			for _, line in pairs(text2table(syncdir_entry.text)) do
				local syncdir = string.gsub(line, "\n", "")
				cmd = { "git", "-C", syncdir, "annex", "sync" }
				if sync_checkbox then
					table.insert(cmd, "--content")
				end
				local result = shell_exeute(cmd)
				if result then
					dt.print("sync for repo " .. syncdir .. " successfull")
				else
					dt.print("error syncing repo " .. syncdir)
				end
			end
		end,
	}),
	dt.new_widget("separator")({
		orientation = "vertical",
	}),
	dt.new_widget("check_button")({
		label = "--content",
		value = true,
		clicked_callback = function(w)
			sync_checkbox = w.value
		end,
	}),
})
local sync_scandb_button = dt.new_widget("button")({
	label = _("scan db"),
	clicked_callback = function(_)
		local t_rootdir = {}
		local t_path = {}
		for _, image in ipairs(dt.database) do
			if not t_contains(t_path, image.path) then
				table.insert(t_path, image.path)
			end
		end
		for _, path in pairs(t_path) do
			local rootdir = annex_rootdir_bypath(path)
			if not t_contains(t_rootdir, rootdir) then
				table.insert(t_rootdir, rootdir)
			end
		end
		local t_syncdir_entry = text2table(syncdir_entry.text)
		for k, v in pairs(t_rootdir) do
			if t_contains(t_syncdir_entry, v) then
				table.remove(t_rootdir, k)
			else
				syncdir_entry.text = string.format("%s\n%s", v, syncdir_entry.text)
			end
		end
	end,
})
-- pack the widgets in a table for loading in the module

table.insert(mE.widgets, separator)
table.insert(mE.widgets, selection_button_box)
table.insert(mE.widgets, collection_button_box)
table.insert(mE.widgets, section_sync)
table.insert(mE.widgets, syncdir_entry)
table.insert(mE.widgets, sync_separator)
table.insert(mE.widgets, sync_scandb_button)
table.insert(mE.widgets, syncbox)

-- ... and tell dt about it all

if dt.gui.current_view().id == "lighttable" then -- make sure we are in lighttable view
	install_module() -- register the lib
else
	if not mE.event_registered then -- if we are not in lighttable view then register an event to signal when we might be
		-- https://www.darktable.org/lua-api/index.html#darktable_register_event
		dt.register_event(
			"git annex module",
			"view-changed", -- we want to be informed when the view changes
			function(event, old_view, new_view)
				if new_view.name == "lighttable" and old_view.name == "darkroom" then -- if the view changes from darkroom to lighttable
					install_module() -- register the lib
				end
			end
		)
		mE.event_registered = true --  keep track of whether we have an event handler installed
	end
end

-- set the destroy routine so that script_manager can call it when
-- it's time to destroy the script and then return the data to
-- script_manager
script_data.destroy = destroy
script_data.restart = restart -- only required for lib modules until we figure out how to destroy them
script_data.destroy_method = "hide" -- tell script_manager that we are hiding the lib so it knows to use the restart function
script_data.show = restart -- if the script was "off" when darktable exited, the module is hidden, so force it to show on start

-- add
dt.register_event("git annex add", "shortcut", function()
	git_annex_bulk("add", "adding", false)
end, "git annex: add images")

-- get
dt.register_event("git annex get", "shortcut", function()
	git_annex_bulk("get", "get", false)
end, "git annex: get images")

-- drop
dt.register_event("git annex drop(bulk)", "shortcut", function()
	git_annex_bulk("drop", "drop", false)
end, "git annex: drop images")

-- status
dt.register_event("git annex status", "shortcut", function()
	--git_annex("status", dt.gui.action_images, "dropping")
	get_status(dt.gui.action_images)
end, "git annex: status")

dt.register_event("image selection changed", "selection-changed", function()
	if next(dt.gui.selection()) == nil then
		selection_button_box.sensitive = false
	else
		selection_button_box.sensitive = true
	end
end)
