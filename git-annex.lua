dt = require "darktable"

json = require ("dkjson")

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
function git_annex_bulk(cmd, images, msg)
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

function set_tags(image, here)
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

function shell.escape(...)
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

function shell.execute(...)
 cmd = shell.escape(...)
 print(cmd)
 --return os.execute(shell.escape(...))
 return os.execute(cmd)
end

function shell.popen(...)
 cmd = shell.escape(...)
 print(cmd)
 --return os.execute(shell.escape(...))
 return io.popen(cmd)
end


-- end borrowed

function call_git_annex_bulk(cmd, ...)
    local annex_path = "/home/michael/Bilder"
    command = { "git", "-C", annex_path, "annex", cmd, ...}
    return shell.execute(command)
end

function call_git_annex_p(annex_path, cmd, ...)
    command = { "git", "-C", annex_path, "annex", cmd, ... }
    return shell.popen(command)
end


-- borrowed from http://en.wikibooks.org/wiki/Lua_Functional_Programming/Functions
function map(func, array)
  local new_array = {}
  for i,v in ipairs(array) do
    new_array[i] = func(v)
  end
  return new_array
end
-- end borrowed

function get_status(images)
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

