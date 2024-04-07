local function script_path()
	local str = debug.getinfo(2, "S").source:sub(2)
	return str:match("(.*/)")
end

package.path = package.path .. ";" .. script_path() .. "lib/share/lua/5.4/?.lua"

local dt = require("darktable")
local du = require("lib/dtutils")
local json = require("dkjson")
local plstringx = require "pl.stringx"
local pretty = require "pl.pretty"
local validation = require "resty.validation"

local MODULE = "git-annex"
local PREF_SYNC_DEFAULT_DIR = "sync_default_dir"
local PREF_METADATA_RULES = "metadata_rules"

local T_METADATA_KEYS = {
	"annex.numcopies",
	"author",
	"tag",
}

local T_OPERATORS = {
	["="] = function(x, y) return x == tonumber(y) end,
	[">"] = function(x, y) return x > tonumber(y) end,
	[">="] = function(x, y) return x >= tonumber(y) end,
	["<"] = function(x, y) return x < tonumber(y) end,
	["<="] = function(x, y) return x <= tonumber(y) end,
	["attached"] = function(x, y)
		local attached = false
		for _, tag in pairs(x) do
			if tag.name == y then
				attached = true
				break
			end
		end
		return attached
	end,
	["is"] = function (x, y) return tostring(x) == y end,
	["is not"] = function (x, y) return tostring(x) ~= y end,
}

local T_IMAGE_PROPS = {
	["rating"] = { 
		["f"] = function(image) return image.rating end,
		["compat"] = {"=", ">", "<" ,">=", "<="},
		["valid"] = function (x) local r, _ = validation.number:between(-1, 5)(tonumber(x)) return r end
	},
	["tag"] = {
		["f"] = function(image) return image.get_tags(image) end, 
		["compat"] = {"attached"},
		["valid"] = function (x) local r, _ = validation:minlen(1)(x) return r end
	},
	["altered"] = { 
		["f"] = function(image) return image.is_altered end, 
		["compat"] = {"is", "is not"},
		["valid"] = function (x) local r, _ = validation:oneof("true", "false")(string.lower(x)) return r end
	},
}

T_UTF8CHARS = {
	["star"] = utf8.char(0x2605),
	["reject"] = utf8.char(0x29BB),
	["tag"] = utf8.char(0x0001F3F7)
}

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
local function purge_combobox(widget)
	local entry_count = #widget
	if entry_count > 0 then
		for i=1,entry_count,1 do 
			widget[1] = nil
		end
	end
end
local function set_combobox_entries(widget, element_list, ...)
	local i = 1
	for _, element in pairs(element_list) do
		if t_contains(..., element) then
			widget[i] = element
			i = i +1
		end
	end
end
local function select_combobox_entry_by_value(widget, value)
	local entry_count = #widget
	local match = false
	for i=1, entry_count,1 do
		if widget[i] == value then
			widget.selected = i
			match = true
		end
		if match then break end
	end
end
local t_table_keys = function (t)
	local t_keys = {}
	for k, _ in pairs(t) do 
		table.insert(t_keys, k)
	end
	return t_keys
end

local function str_table_keys(t)
	local t_keys = {}
	local return_string = [[]]
	for k, _ in pairs(t) do
		table.insert(t_keys, k)
		return_string =
			[[
]] .. return_string .. [[
- ]] .. k .. [[

]]
	end
	return return_string
end

local function update_edit_form(mGa, t_metadata_rules_parsed, rule_selected)
	-- dirty hack: misuse image.prop_combox.name as shared value to indicate desired target value for operator combobox
	mGa.widgets.metadata_settings_edit_image_prop_combobox.name = t_metadata_rules_parsed[rule_selected]["op"]
	select_combobox_entry_by_value(mGa.widgets.metadata_settings_edit_image_prop_combobox, t_metadata_rules_parsed[rule_selected]["image_prop"])
	mGa.widgets.metadata_settings_edit_label_entry.text = t_metadata_rules_parsed[rule_selected]["label"]
	mGa.widgets.metadata_settings_edit_description_entry.text = t_metadata_rules_parsed[rule_selected]["description"]
	mGa.widgets.metadata_settings_edit_value_entry.text = t_metadata_rules_parsed[rule_selected]["value"]
	if mGa.widgets.metadata_settings_combobox.selected == 2 then
		mGa.widgets.metadata_settings_edit_add_btn.label = "modify"
		mGa.widgets.metadata_settings_edit_add_btn.name = rule_selected
	end
	if mGa.widgets.metadata_settings_combobox.selected == 1 then
		mGa.widgets.metadata_settings_edit_add_btn.label = "add"
		mGa.widgets.metadata_settings_edit_add_btn.name = nil
	end
end
local function clear_edit_form(mGa)
	mGa.widgets.metadata_settings_stack.active = 1
	mGa.widgets.metadata_settings_edit_image_prop_combobox.selected = 0
	mGa.widgets.metadata_settings_edit_op_combobox.selected = 0
	mGa.widgets.metadata_settings_edit_label_entry.text = ""
	mGa.widgets.metadata_settings_edit_description_entry.text = ""
	mGa.widgets.metadata_settings_edit_value_entry.text = ""
	mGa.widgets.metadata_settings_edit_add_btn.label = "add"
	mGa.widgets.metadata_settings_edit_add_btn.name = nil
end

PREF_METADATA_RULES_DEFAULT =
[[label=1%star%,description='Rating = %star%',image_prop=rating,op=%=%,value=1
label=%tag%,description='tag attached: private',image_prop=tag,op=%attached%,value='private']]

local PREF_METADATA_RULES_TOOLTIP =
	[[
- fields: label, description, image_prop, op, value
		- label: string displayed in module next to check button
		- description: string - tooltip for label
		- image_prop: property of image to compare (see below)
		- operator: comparison operator (see below)
		- value: the comparison value
- UTF8CHARS enclosed with %%, e.g. %label% or %star%

=========
operators
=========
]] .. str_table_keys(T_OPERATORS) .. [[
==========
utf8-chars
==========
]] .. str_table_keys(T_UTF8CHARS) .. [[
================
image properties
================
]] .. str_table_keys(T_IMAGE_PROPS) .. [[
]]


-- preferences
-- default sync directory 
dt.preferences.register(
	MODULE,
	PREF_SYNC_DEFAULT_DIR,
	"directory",
	"Git annex: default sync repository",
	"A user defined repository to automatically add to sync directory list",
	""
)

MDRULE_PREFIX = ":mdrule:"
local function get_metadata_pref_keys()
	-- get all preference keys from dt that prefix with MDRULE_PREFIX
	-- e.g.
	-- 	lua/git-annex/metadata_rules:mdrule:1
	--  lua/git-annex/metadata_rules:mdrule:2
	local t = {}
	for _, k in pairs(dt.preferences.get_keys()) do
		if plstringx.startswith(k, "lua/" .. MODULE .. "/" .. PREF_METADATA_RULES .. MDRULE_PREFIX) then
			table.insert(t, k)
		end
	end
	return t
end
local function get_metadata_rules()
	local t_metadata_rules = {}
	local t = get_metadata_pref_keys()
	table.sort(t)
	if next(t) == nil then
		return ""
	else
		for _, k in pairs(t) do
			local _,_, prefix = table.unpack(plstringx.split(k, "/", 3))
			table.insert(t_metadata_rules, dt.preferences.read(MODULE, prefix, "string"))
		end
		local str_metadata_rules = plstringx.join("\n", t_metadata_rules)
		return str_metadata_rules
	end
end

local function purge_metadata_preferences()
	for _, k in pairs(get_metadata_pref_keys()) do
		local _,_, prefix = table.unpack(plstringx.split(k, "/", 3))
		dt.preferences.destroy(MODULE, prefix)
	end
end

local function parse_pref_metadata_rule(s)
	local t_metadata_rule_parsed = {}
	local t_metadata_rule_parsed_string = {}
	local t_words = plstringx.split(s, ",")
	for _, v in pairs(t_words) do
		-- replace utf8char placeholders with actual utf8char
		for utf8_k, utf8_v in pairs(T_UTF8CHARS) do
			v = plstringx.replace(v, "%" .. utf8_k .. "%", utf8_v)
		end
		table.insert(t_metadata_rule_parsed_string, v)
	end
	for _, w in pairs(t_metadata_rule_parsed_string) do
		local field, value = table.unpack(plstringx.split(w, "=", 2))
		do
			t_metadata_rule_parsed[field] = value
		end
	end
	-- replace string in op field with actual operator e.g. %=% -> =
	t_metadata_rule_parsed.op = plstringx.replace(t_metadata_rule_parsed.op, "%", "")
	-- replace surrounding quotation marks in value & description field e.g. 'private' -> private
	t_metadata_rule_parsed.value = plstringx.replace(t_metadata_rule_parsed.value, "'", "")
	t_metadata_rule_parsed.value = plstringx.replace(t_metadata_rule_parsed.value, '"', '')
	t_metadata_rule_parsed.description = plstringx.replace(t_metadata_rule_parsed.description, "'", "")
	t_metadata_rule_parsed.description = plstringx.replace(t_metadata_rule_parsed.description, '"', '')
	return t_metadata_rule_parsed
end

-- parsed metadata rules prefs
local t_metadata_rules_parsed = {}
local str = get_metadata_rules()
if not (str == nil or str == "") then
	for line in plstringx.lines(str) do
		table.insert(t_metadata_rules_parsed, parse_pref_metadata_rule(line))
	end
end
-- write metadata rules to preferences
local function write_metadata_rules_to_pref(t)
	for i, condition in pairs(t) do
		local str = plstringx.join(",", {
			"label=".. condition["label"],
			"description=" .. condition["description"],
			"image_prop=" .. condition["image_prop"],
			"op=%" .. condition["op"],
			"value=" .. condition["value"]
		})
		dt.preferences.write(MODULE, PREF_METADATA_RULES .. MDRULE_PREFIX .. i, "string", str)
	end
end

local function match_metadata_condition(condition, image)
	local prop = T_IMAGE_PROPS[condition["image_prop"]].f(image)
	local value = condition["value"]
	return T_OPERATORS[condition["op"]](prop, value)
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

local function set_annex_metadata(metadata_widget_box, ...)
	for _, image in pairs(...) do
		for i, condition in pairs(t_metadata_rules_parsed) do
			local active = metadata_widget_box[i][1].value
			local prop = metadata_widget_box[i][2].value
			local value = metadata_widget_box[i][3].text
			if active and not (value == "") then
				if match_metadata_condition(condition, image) then
					dt.print(image.filename .. ": apply metadata" .. prop .. "=" .. value)
					local result = shell.execute({ "git", "-C", image.path, "annex", "metadata",
						image.filename, "-s", prop .. "=" .. value })
					if result then
						dt.print(image.filename .. ": apply metadata ok")
					else
						dt.print(image.filename .. ": apply metadata failed")
					end
				end
			end
		end
	end
end

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

du.check_min_api_version("7.0.0", "darktable-git-annex module")

-- return data structure for script_manager

local script_data = {}

script_data.destroy = nil        -- function to destory the script
script_data.destroy_method = nil -- set to hide for libs since we can't destroy them commpletely yet, otherwise leave as nil
script_data.restart = nil        -- how to restart the (lib) script after it's been hidden - i.e. make it visible again
script_data.show = nil           -- only required for libs since the destroy_method only hides them

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
	for _, line in pairs(plstringx.splitlines(mGa.widgets.syncdir_entry.text)) do
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
			"git annex module",                                                   -- Module name
			"git annex module",                                                   -- name
			true,                                                                 -- expandable
			false,                                                                -- resetable
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
mGa.widgets.selection_add_btn = dt.new_widget("button")({
	label = _("Selection: add"),
	clicked_callback = function(_)
		git_annex_bulk("add", "add", false)
	end,
})
-- get
mGa.widgets.selection_get_btn = dt.new_widget("button")({
	label = _("Selection: get"),
	clicked_callback = function(_)
		git_annex_bulk("get", "get", false)
	end,
})
-- drop
mGa.widgets.selection_drop_btn = dt.new_widget("button")({
	label = _("Selection: drop"),
	clicked_callback = function(_)
		git_annex_bulk("drop", "drop", false)
	end,
})
-- horizontal box containing selection action buttons
mGa.widgets.selection_box = dt.new_widget("box")({
	orientation = "horizontal",
	sensitive = false,
	mGa.widgets.selection_add_btn,
	mGa.widgets.selection_get_btn,
	mGa.widgets.selection_drop_btn,
})
-- collection action buttons
-- add
mGa.widgets.collection_add_btn = dt.new_widget("button")({
	label = _("Collection: add"),
	clicked_callback = function(_)
		git_annex_bulk("add", "add", true)
	end,
})
-- get
mGa.widgets.collection_get_btn = dt.new_widget("button")({
	label = _("Collection: get"),
	clicked_callback = function(_)
		git_annex_bulk("get", "get", true)
	end,
})
-- drop
mGa.widgets.collection_drop_btn = dt.new_widget("button")({
	label = _("Collection: drop"),
	clicked_callback = function(_)
		git_annex_bulk("drop", "drop", true)
	end,
})
-- horizontal box containing collection action buttons
mGa.widgets.collection_button_box = dt.new_widget("box")({
	orientation = "horizontal",
	mGa.widgets.collection_add_btn,
	mGa.widgets.collection_get_btn,
	mGa.widgets.collection_drop_btn,
})
-- action box
mGa.widgets.action_box = dt.new_widget("box")({
	dt.new_widget("section_label")({
		label = "git annex",
	}),
	mGa.widgets.selection_box,
	mGa.widgets.collection_button_box,
})
-- multiline input for user defined sync directories
mGa.widgets.syncdir_entry = dt.new_widget("text_view")({
	tooltip = "list of directories to sync, one per line",
	text = dt.preferences.read(MODULE, PREF_SYNC_DEFAULT_DIR, "directory"),
})
-- git annex sync button
mGa.widgets.sync_btn = dt.new_widget("button")({
	label = _("git annex sync"),
	clicked_callback = sync_btn_callback,
})
-- check button for '--content' argument
mGa.widgets.sync_content_check_btn = dt.new_widget("check_button")({
	label = "--content",
	value = true,
	clicked_callback = function(w)
		sync_checkbox = w.value
	end,
})
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
		local t_syncdir_entry = plstringx.splitlines(mGa.widgets.syncdir_entry.text)
		for k, v in pairs(t_rootdir) do
			if not t_contains(t_syncdir_entry, v) then
				mGa.widgets.syncdir_entry.text = string.format("%s\n%s", v, mGa.widgets.syncdir_entry.text)
			end
		end
	end,
})
-- sync box
mGa.widgets.sync_box = dt.new_widget("box")({
	orientation = "vertical",
	dt.new_widget("section_label")({
		label = "git annex sync",
	}),
	mGa.widgets.syncdir_entry,
	mGa.widgets.sync_scandb_btn,
	dt.new_widget("box")({
		orientation = "horizontal",
		mGa.widgets.sync_btn,
		dt.new_widget("separator")({
			orientation = "vertical",
		}),
		mGa.widgets.sync_content_check_btn,
	}),
})

mGa.widgets.metadata_header_box = dt.new_widget("box") {
	orientation = "vertical",
	dt.new_widget("section_label") {
		label = "Metadata",
	},
	dt.new_widget("combobox") {
		"rules",
		"settings",
		editable = false,
		changed_callback = function(self)
			mGa.widgets.metadata_stack.active = self.selected
		end
	}
}

local t_widgets_metadata_rules = {}

local function toogle_widget_sens(widget, value)
	widget.sensitive = value
end

for i, condition in pairs(t_metadata_rules_parsed) do
	t_widgets_metadata_rules[i] = {
		["entry"] = dt.new_widget("entry") {},
		["combobox"] = dt.new_widget("combobox") {
			table.unpack(T_METADATA_KEYS)
		}
	}
	t_widgets_metadata_rules[i]["box"] = dt.new_widget("box") {
		orientation = "horizontal",
		dt.new_widget("check_button") {
			value = true,
			label = condition["label"],
			tooltip = condition["description"],
			clicked_callback = function(self)
				toogle_widget_sens(t_widgets_metadata_rules[i].combobox, self.value)
				toogle_widget_sens(t_widgets_metadata_rules[i].entry, self.value)
			end
		},
		t_widgets_metadata_rules[i].combobox,
		t_widgets_metadata_rules[i].entry
	}
end
local t_widgets_metadata_rules_box = {}
for _, v in pairs(t_widgets_metadata_rules) do
	table.insert(t_widgets_metadata_rules_box, v.box)
end
-- metadata action button: Selection
mGa.widgets.metadata_action_selection_btn = dt.new_widget("button") {
	label = _("Selection: apply"),
	clicked_callback = function(_)
		set_annex_metadata(t_widgets_metadata_rules_box, dt.gui.selection())
	end
}
-- metadata action button: Collection
mGa.widgets.metadata_action_collection_btn = dt.new_widget("button") {
	label = _("Collection: apply"),
	clicked_callback = function(_)
		set_annex_metadata(t_widgets_metadata_rules_box, dt.collection)
	end
}
-- metadata action button box
mGa.widgets.metadata_action_box = dt.new_widget("box") {
	orientation = "horizontal",
	mGa.widgets.metadata_action_selection_btn,
	mGa.widgets.metadata_action_collection_btn
}
-- metadata rules box
mGa.widgets.metadata_rules_box = dt.new_widget("box") {
	orientation = "vertical",
	mGa.widgets.metadata_action_box,
	table.unpack(t_widgets_metadata_rules_box),
}
mGa.widgets.metadata_settings_text_view = dt.new_widget("text_view") {
	editable = false,
	tooltip = PREF_METADATA_RULES_TOOLTIP
}
mGa.widgets.metadata_settings_selection_combobox = dt.new_widget("combobox"){
	label = "Select",
	changed_callback = function (self)
		if self.selected > 0 then
			mGa.widgets.metadata_settings_text_view.text = plstringx.join("\n", {
				"Label: " .. t_metadata_rules_parsed[self.selected]["label"],
				"description: " .. t_metadata_rules_parsed[self.selected]["description"],
				"property: " .. t_metadata_rules_parsed[self.selected]["image_prop"],
				"operator: " .. t_metadata_rules_parsed[self.selected]["op"],
				"value: " .. t_metadata_rules_parsed[self.selected]["value"]
			})
			if mGa.widgets.metadata_settings_combobox.selected == 2 then
				update_edit_form(mGa, t_metadata_rules_parsed, self.selected)
			end
		else 
			mGa.widgets.metadata_settings_text_view.text = ""
		end
	end
}
for i, condition in pairs(t_metadata_rules_parsed) do
	mGa.widgets.metadata_settings_selection_combobox[i] = condition["label"] .. " | " .. condition["description"]
end
mGa.widgets.metadata_settings_selection_combobox.selected = 0
mGa.widgets.metadata_settings_remove_btn = dt.new_widget("button") {
	label = _("Delete"),
	clicked_callback = function (_)
		local id = mGa.widgets.metadata_settings_selection_combobox.selected
		table.remove(t_metadata_rules_parsed, id)
		purge_combobox(mGa.widgets.metadata_settings_selection_combobox)
		for i, condition in pairs(t_metadata_rules_parsed) do
			mGa.widgets.metadata_settings_selection_combobox[i] = condition["label"] .. " | " .. condition["description"]
		end
		clear_edit_form(mGa)
		mGa.widgets.metadata_settings_selection_combobox.selected = 0
	end
}
mGa.widgets.metadata_settings_edit_description_entry = dt.new_widget("entry"){
	placeholder = "description"
}
mGa.widgets.metadata_settings_edit_label_entry = dt.new_widget("entry"){
	placeholder = "label "
}
mGa.widgets.metadata_settings_edit_label_description_box = dt.new_widget("box"){
	orientation = "horizontal",
	mGa.widgets.metadata_settings_edit_label_entry,
	mGa.widgets.metadata_settings_edit_description_entry,
}
mGa.widgets.metadata_settings_edit_op_combobox = dt.new_widget("combobox"){
	label = "operator",
}
mGa.widgets.metadata_settings_edit_image_prop_combobox = dt.new_widget("combobox"){
	label = "property",
	name = nil,
	changed_callback = function (self)
		-- clean up operator combobox
		purge_combobox(mGa.widgets.metadata_settings_edit_op_combobox)
		-- set op combobox values with matching values unless no selection is done
		if self.selected > 0 then 
			set_combobox_entries(mGa.widgets.metadata_settings_edit_op_combobox, t_table_keys(T_OPERATORS), T_IMAGE_PROPS[self.value].compat)
			if not (self.name == nil) then
				select_combobox_entry_by_value(mGa.widgets.metadata_settings_edit_op_combobox, self.name)
				self.name = nil
			end
		end
	end,
	table.unpack(t_table_keys(T_IMAGE_PROPS)),
}
set_combobox_entries(
	mGa.widgets.metadata_settings_edit_op_combobox,
	t_table_keys(T_OPERATORS), 
	T_IMAGE_PROPS[mGa.widgets.metadata_settings_edit_image_prop_combobox.value].compat
)
mGa.widgets.metadata_settings_edit_value_entry = dt.new_widget("entry"){
	placeholder = "value"
}
mGa.widgets.metadata_settings_apply_btn = dt.new_widget("button") {
	label = _("Apply (Restart to take effect)"),
	clicked_callback = function(_)
		purge_metadata_preferences()
		write_metadata_rules_to_pref(t_metadata_rules_parsed)
		dt.print("Metadata rules applied, please restart dt")
	end
}
mGa.widgets.metadata_settings_edit_params_box = dt.new_widget("box"){
	orientation = "horizontal",
	mGa.widgets.metadata_settings_edit_image_prop_combobox,
	mGa.widgets.metadata_settings_edit_op_combobox,
	dt.new_widget("separator"){
		orientation = "horizontal"
	},
	mGa.widgets.metadata_settings_edit_value_entry
}
mGa.widgets.metadata_settings_edit_add_btn = dt.new_widget("button"){
	name = nil,
	label = _("add"),
	clicked_callback = function (self)
		local str = plstringx.join(",",{
		"label=" .. mGa.widgets.metadata_settings_edit_label_entry.text,
		"description=" .. mGa.widgets.metadata_settings_edit_description_entry.text,
		"image_prop=" .. mGa.widgets.metadata_settings_edit_image_prop_combobox.value,
		"op=" .. mGa.widgets.metadata_settings_edit_op_combobox.value,
		"value=" .. mGa.widgets.metadata_settings_edit_value_entry.text
		})
		-- validate input value of value entry first
		if not 
		T_IMAGE_PROPS[mGa.widgets.metadata_settings_edit_image_prop_combobox.value]
		.valid(mGa.widgets.metadata_settings_edit_value_entry.text) then
			dt.print("value is not valid")
			return
		end
		if self.label == "add" then
			table.insert(t_metadata_rules_parsed, parse_pref_metadata_rule(str))
		end
		if self.label == "modify" then
			t_metadata_rules_parsed[tonumber(self.name)] = parse_pref_metadata_rule(str)
		end
		purge_combobox(mGa.widgets.metadata_settings_selection_combobox)
		for i, condition in pairs(t_metadata_rules_parsed) do
			mGa.widgets.metadata_settings_selection_combobox[i] = condition["label"] .. " | " .. condition["description"]
		end
		clear_edit_form(mGa)
		mGa.widgets.metadata_settings_selection_combobox.selected = 0
	end
}
mGa.widgets.metadata_settings_edit_box = dt.new_widget("box"){
	orientation = "vertical",
	mGa.widgets.metadata_settings_edit_label_description_box,
	mGa.widgets.metadata_settings_edit_params_box,
	mGa.widgets.metadata_settings_edit_add_btn,
}
mGa.widgets.metadata_settings_info_text_view = dt.new_widget("text_view") {
	editable = false,
	text = PREF_METADATA_RULES_TOOLTIP
}
mGa.widgets.metadata_settings_stack = dt.new_widget("stack"){
	v_size_fixed = false,
	h_size_fixed = false,
	mGa.widgets.metadata_settings_edit_box,
	mGa.widgets.metadata_settings_info_text_view,
}
mGa.widgets.metadata_settings_combobox = dt.new_widget("combobox"){
	"new",
	"edit",
	"help",
	changed_callback = function (self)
		-- selected new
		if self.selected == 1 then
			clear_edit_form(mGa)
		end
		-- selected help
		if self.selected == 3 then
			mGa.widgets.metadata_settings_stack.active = 2
		end
		-- selected edit
		if self.selected == 2 then
			mGa.widgets.metadata_settings_stack.active = 1
			local rule_selected = mGa.widgets.metadata_settings_selection_combobox.selected
			if rule_selected > 0 then
				update_edit_form(mGa, t_metadata_rules_parsed, rule_selected)
				mGa.widgets.metadata_settings_edit_add_btn.name = mGa.widgets.metadata_settings_selection_combobox.selected
			end
		end
	end
}
mGa.widgets.metadata_settings_box = dt.new_widget("box") {
	orientation = "vertical",
	mGa.widgets.metadata_settings_selection_combobox,
	mGa.widgets.metadata_settings_text_view,
	mGa.widgets.metadata_settings_remove_btn,
	mGa.widgets.metadata_settings_apply_btn,
	mGa.widgets.metadata_settings_combobox,
	mGa.widgets.metadata_settings_stack
}
mGa.widgets.metadata_stack = dt.new_widget("stack") {
	v_size_fixed = false,
	h_size_fixed = false,
	mGa.widgets.metadata_rules_box,
	mGa.widgets.metadata_settings_box,
}
-- main box
mGa.widgets.main_box = dt.new_widget("box")({
	mGa.widgets.action_box,
	mGa.widgets.sync_box,
	mGa.widgets.metadata_header_box,
	mGa.widgets.metadata_stack,
})

-- ... and tell dt about it all

if dt.gui.current_view().id == "lighttable" then -- make sure we are in lighttable view
	install_module()                             -- register the lib
else
	if not mGa.event_registered then             -- if we are not in lighttable view then register an event to signal when we might be
		-- https://www.darktable.org/lua-api/index.html#darktable_register_event
		dt.register_event(
			"git annex module",
			"view-changed",                                               -- we want to be informed when the view changes
			function(event, old_view, new_view)
				if new_view.name == "lighttable" and old_view.name == "darkroom" then -- if the view changes from darkroom to lighttable
					install_module()                                      -- register the lib
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
script_data.restart = restart       -- only required for lib modules until we figure out how to destroy them
script_data.destroy_method =
"hide"                              -- tell script_manager that we are hiding the lib so it knows to use the restart function
script_data.show =
restart                             -- if the script was "off" when darktable exited, the module is hidden, so force it to show on start

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
		mGa.widgets.metadata_action_selection_btn.sensitive = false
	else
		mGa.widgets.selection_box.sensitive = true
		mGa.widgets.metadata_action_selection_btn.sensitive = true
	end
end)



return script_data
