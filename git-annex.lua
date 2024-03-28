local dt = require "darktable"
local du = require "lib/dtutils"
local json = require "lib/dkjson"

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
mE.event_registered = false  -- keep track of whether we've added an event callback or not
mE.module_installed = false  -- keep track of whether the module is module_installed

--[[ We have to create the module in one of two ways depending on which view darktable starts
in.  In orker to not repeat code, we wrap the darktable.register_lib in a local function.
]]

local function install_module()
    if not mE.module_installed then
        -- https://www.darktable.org/lua-api/index.html#darktable_register_lib
        dt.register_lib(
        "git annex module",     -- Module name
        "git annex module",     -- name
        true,                -- expandable
        false,               -- resetable
        {[dt.gui.views.lighttable] = {"DT_UI_CONTAINER_PANEL_RIGHT_CENTER", 100}},   -- containers
        -- https://www.darktable.org/lua-api/types_lua_box.html
        dt.new_widget("box") -- widget
        {
            orientation = "vertical",
            dt.new_widget("label")
            {
                label = "git annex root dir"
            },
            table.unpack(mE.widgets),
        },
        nil,-- view_enter
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

local file_chooser_button = dt.new_widget("file_chooser_button")
{
    title = _("set git annex root directory"),  -- The title of the window when choosing a file
    value = "",                       -- The currently selected file
    is_directory = true               -- True if the file chooser button only allows directories to be selected
}

-- https://www.darktable.org/lua-api/types_lua_separator.html
local separator = dt.new_widget("separator"){}

local button_selection_get = dt.new_widget("button")
{
    label = _("Selection: get (bulk)"),
    clicked_callback = function (_)
        git_annex_bulk("get", dt.gui.action_images, "bulk get")
    end
}

local button_selection_drop = dt.new_widget("button")
{
    label = _("Selection: drop (bulk)"),
    clicked_callback = function (_)
        git_annex_bulk("drop", dt.gui.action_images, "bulk drop")
    end
}

-- pack the widgets in a table for loading in the module

table.insert(mE.widgets, file_chooser_button)
table.insert(mE.widgets, separator)
table.insert(mE.widgets, button_selection_get)
table.insert(mE.widgets, button_selection_drop)

-- ... and tell dt about it all

if dt.gui.current_view().id == "lighttable" then -- make sure we are in lighttable view
    install_module()  -- register the lib
else
    if not mE.event_registered then -- if we are not in lighttable view then register an event to signal when we might be
        -- https://www.darktable.org/lua-api/index.html#darktable_register_event
        dt.register_event(
        "git annex module", "view-changed",  -- we want to be informed when the view changes
        function(event, old_view, new_view)
            if new_view.name == "lighttable" and old_view.name == "darkroom" then  -- if the view changes from darkroom to lighttable
            install_module()  -- register the lib
            end
        end
        )
        mE.event_registered = true  --  keep track of whether we have an event handler installed
    end
end

-- set the destroy routine so that script_manager can call it when
-- it's time to destroy the script and then return the data to 
-- script_manager
script_data.destroy = destroy
script_data.restart = restart  -- only required for lib modules until we figure out how to destroy them
script_data.destroy_method = "hide" -- tell script_manager that we are hiding the lib so it knows to use the restart function
script_data.show = restart  -- if the script was "off" when darktable exited, the module is hidden, so force it to show on start

-- bulk add
dt.register_event("git annex add", "shortcut", function()
    git_annex_bulk("add", dt.gui.action_images, "adding")
end, "git annex: add images")

-- bulk get
dt.register_event("git annex get(bulk)", "shortcut", function()
    git_annex_bulk("get", dt.gui.action_images, "bulk get")
end, "git annex: get images(bulk)")

-- bulk drop
dt.register_event("git annex drop(bulk)", "shortcut", function()
    git_annex_bulk("drop", dt.gui.action_images, "bulk drop")
end, "git annex: drop images(bulk)")

-- status
dt.register_event("git annex status", "shortcut", function()
    --git_annex("status", dt.gui.action_images, "dropping")
    get_status(dt.gui.action_images)
end, "git annex: status")


-- executes git annex with the given subcommand on the selected files
--   cmd - string, the git annex subcommand
--   images - table, of dt_lua_image_t
--   msg - string, the verb to be displayed to the user
local function git_annex_bulk(cmd, images, msg)
    notice = msg.. " from git annex"
    dt.print(notice)
    local filelist = {}
    for _,image in pairs(images) do
        filepath = image.path.."/" .. image.filename
        table.insert(filelist, filepath)
    end
    result = call_git_annex_bulk(cmd, table.unpack(filelist))
    if result then
        dt.print("finished "..notice)
        get_status(images)
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
shell = {}

local function shell.escape(...)
    local command = type(...) == 'table' and ... or { ... }
    for i, s in ipairs(command) do
        s = (tostring(s) or ''):gsub('"', '\\"')
        if s:find '[^A-Za-z0-9_."/-]' then
            s = '"' .. s .. '"'
        elseif s == '' then
            s = '""'
        end
        command[i] = s
    end
    return table.concat(command, ' ')
    end

local function shell.execute(...)
    cmd = shell.escape(...)
    print(cmd)
    --return os.execute(shell.escape(...))
    return os.execute(cmd)
end

local function shell.popen(...)
    cmd = shell.escape(...)
    print(cmd)
    --return os.execute(shell.escape(...))
    return io.popen(cmd)
end


-- end borrowed

local function call_git_annex_bulk(cmd, ...)
    local annex_path = file_chooser_button.value
    command = { "git", "-C", annex_path, "annex", cmd, ...}
    return shell.execute(command)
end

local function call_git_annex_p(annex_path, cmd, ...)
    command = { "git", "-C", annex_path, "annex", cmd, ... }
    return shell.popen(command)
end


-- borrowed from http://en.wikibooks.org/wiki/Lua_Functional_Programming/Functions
local function map(func, array)
    local new_array = {}
    for i,v in ipairs(array) do
        new_array[i] = func(v)
    end
    return new_array
end
-- end borrowed

local function get_status(images)
    paths = {}
    for _, image in ipairs(images) do
        if not paths[image.path] then
            paths[image.path] = {}
        end
        paths[image.path][image.filename] = image
    end

    for path, path_images in pairs(paths) do
        print(path)
        filenames = {}
        for _, image in pairs(path_images) do
            table.insert(filenames, image.filename)
        end
        -- If there are more than 25 files, it's probably quicker to just
        -- load everything.
        if #filenames > 25 then
            filenames = {}
        end
        out=call_git_annex_p(path, "whereis", "-j", table.unpack(filenames))
        for line in out:lines() do
            status = json.decode(line)
            whereis = status["whereis"]
            here = false
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
