local function script_path()
	local str = debug.getinfo(2, "S").source:sub(2)
	return str:match("(.*/)")
end

package.path = package.path .. ";" .. script_path() .. "/?.lua"

local dt = require("darktable")
local du = require("lib/dtutils")
local json = require("lib/dkjson")

local MODULE = "git-annex"
local PREF_SYNC_DEFAULT_DIR = "sync_default_dir"

-- preferences
-- default sync directory
dt.preferences.register(MODULE,
                        PREF_SYNC_DEFAULT_DIR,
                        "directory",
                        "Git annex: default sync repository",
                        "A user defined repository to automatically add to sync directory list",
                        "")

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

setmetatable(shell, {
	__index = function(self, program)
	return function(...)
	return shell.execute(program, ...) == 0
	end
	end,
})

function shell.escape(...)
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

function shell.execute(...)
	local cmd = shell.escape(...)
	--print(cmd)
	return os.execute(cmd)
end

function shell.popen(...)
	local cmd = shell.escape(...)
	--print(cmd)
	return io.popen(cmd)
end

-- end borrowed

local function annex_rootdir(image)
	local f_annex_rootdir = shell.popen({ "git", "-C", image.path, "rev-parse", "--show-toplevel" })
	return f_annex_rootdir:read("l")
end
local function annex_rootdir_bypath(path)
	local f_annex_rootdir = shell.popen({ "git", "-C", path, "rev-parse", "--show-toplevel" })
	return f_annex_rootdir:read("l")
end

local function call_git_annex_bulk(cmd, annex_path, ...)
	--local annex_path = file_chooser_button.value
	local command = { "git", "-C", annex_path, "annex", cmd, ... }
	return shell.execute(command)
end

local function call_git_annex_p(annex_path, cmd, ...)
	local command = { "git", "-C", annex_path, "annex", cmd, ... }
	return shell.popen(command)
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

local sync_checkbox = true

local function text2table(s)
	local t = {}
	for line in string.gmatch(s, "[^\r\n]+") do
		table.insert(t, line)
	end
	return t
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
local mGa = {}
mGa.widgets = {}
mGa.event_registered = false -- keep track of whether we've added an event callback or not
mGa.module_installed = false -- keep track of whether the module is module_installed

-- sync function supposed to be called on startup and by button click 
local sync_btn_callback = function()
	for _, line in pairs(text2table(mGa.widgets.syncdir_entry.text)) do
		local syncdir = string.gsub(line, "\n", "")
		local cmd = { "git", "-C", syncdir, "annex", "sync" }
		if sync_checkbox then
			table.insert(cmd, "--content")
		end
		dt.print("sync for repo " .. syncdir)
		local result = shell.execute(cmd)
		if result then
			dt.print("sync for repo " .. syncdir .. " successfull")
		else
			dt.print("error syncing repo " .. syncdir)
		end
	end
end

local function install_module()
	if not mGa.module_installed then
		-- https://www.darktable.org/lua-api/index.html#darktable_register_lib
		dt.register_lib(
			"git annex module", -- Module name
			"git annex module", -- name
			true, -- expandable
			false, -- resetable
			{ [dt.gui.views.lighttable] = { "DT_UI_CONTAINER_PANEL_RIGHT_CENTER", 100 } }, -- containers
			-- https://www.darktable.org/lua-api/types_lua_box.html
			mGa.widgets.main_box,
			nil, -- view_enter
			nil -- view_leave
		)
		mGa.module_installed = true
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

-- Selection action Buttons
-- add
mGa.widgets.selection_add_btn = dt.new_widget("button"){
	label = _("Selection: add"),
	clicked_callback = function(_)
		git_annex_bulk("add", "add", false)
	end
}
-- get
mGa.widgets.selection_get_btn =	dt.new_widget("button"){
	label = _("Selection: get"),
	clicked_callback = function(_)
		git_annex_bulk("get", "get", false)
	end
}
-- drop
mGa.widgets.selection_drop_btn =dt.new_widget("button"){
	label = _("Selection: drop"),
	clicked_callback = function(_)
		git_annex_bulk("drop", "drop", false)
	end
}
-- horizontal box containing selection action buttons
mGa.widgets.selection_box = dt.new_widget("box")({
	orientation = "horizontal",
	sensitive = false,
	mGa.widgets.selection_add_btn,
	mGa.widgets.selection_get_btn,
	mGa.widgets.selection_drop_btn
})
-- collection action buttons
-- add
mGa.widgets.collection_add_btn = dt.new_widget("button"){
	label = _("Collection: add"),
	clicked_callback = function(_)
		git_annex_bulk("add", "add", true)
	end
}
-- get
mGa.widgets.collection_get_btn = dt.new_widget("button"){
	label = _("Collection: get"),
	clicked_callback = function(_)
		git_annex_bulk("get", "get", true)
	end
}
-- drop
mGa.widgets.collection_drop_btn = dt.new_widget("button"){
	label = _("Collection: drop"),
	clicked_callback = function(_)
		git_annex_bulk("drop", "drop", true)
	end
}
-- horizontal box containing collection action buttons
mGa.widgets.collection_button_box = dt.new_widget("box")({
	orientation = "horizontal",
	mGa.widgets.collection_add_btn,
	mGa.widgets.collection_get_btn,
	mGa.widgets.collection_drop_btn
})
-- action box
mGa.widgets.action_box = dt.new_widget("box"){
	dt.new_widget("section_label"){
		label = "git annex"
	},
	mGa.widgets.selection_box,
	mGa.widgets.collection_button_box
}
-- multiline input for user defined sync directories
mGa.widgets.syncdir_entry = dt.new_widget("text_view")({
	tooltip = "list of directories to sync, one per line",
	text = dt.preferences.read(MODULE, PREF_SYNC_DEFAULT_DIR, "directory")
})
-- git annex sync button
mGa.widgets.sync_btn = dt.new_widget("button"){
	label = _("git annex sync"),
	clicked_callback = sync_btn_callback
}
-- check button for '--content' argument
mGa.widgets.sync_content_check_btn = dt.new_widget("check_button"){
	label = "--content",
	value = true,
	clicked_callback = function(w)
		sync_checkbox = w.value
	end,
}
-- scandb db button (scan dt libary for git repositories and add them to syncdir_entry
mGa.widgets.sync_scandb_btn = dt.new_widget("button")({
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
		local t_syncdir_entry = text2table(mGa.widgets.syncdir_entry.text)
		for k, v in pairs(t_rootdir) do
			if t_contains(t_syncdir_entry, v) then
				table.remove(t_rootdir, k)
			else
				mGa.widgets.syncdir_entry.text = string.format("%s\n%s", v, mGa.widgets.syncdir_entry.text)
			end
		end
	end,
})
-- sync box
mGa.widgets.sync_box = dt.new_widget("box"){
	orientation = "vertical",
	dt.new_widget("section_label"){
		label = "git annex sync"
	},
	mGa.widgets.syncdir_entry,
	mGa.widgets.sync_scandb_btn,
	dt.new_widget("box"){
		orientation = "horizontal",
		mGa.widgets.sync_btn,
		dt.new_widget("separator")({
			orientation = "vertical",
		}),
		mGa.widgets.sync_content_check_btn
	}
}
-- main box
mGa.widgets.main_box = dt.new_widget("box"){
	mGa.widgets.action_box,
	mGa.widgets.sync_box
}

-- ... and tell dt about it all

if dt.gui.current_view().id == "lighttable" then -- make sure we are in lighttable view
	install_module() -- register the lib
else
	if not mGa.event_registered then -- if we are not in lighttable view then register an event to signal when we might be
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
		mGa.event_registered = true --  keep track of whether we have an event handler installed
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
		mGa.widgets.selection_box.sensitive = false
	else
		mGa.widgets.selection_box.sensitive = true
	end
end)

return script_data