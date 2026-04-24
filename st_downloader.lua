-- SPDX-License-Identifier: AGPL-3.0-or-later

local ButtonDialog = require("ui/widget/buttondialog")
local InfoMessage = require("ui/widget/infomessage")
local ReaderUI = require("apps/reader/readerui")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local lfs = require("libs/libkoreader-lfs")
local _ = require("gettext")

local Models = require("st_models")
local Sidecar = require("st_sidecar")

local Downloader = {}

local function isFile(path)
    return lfs.attributes(path, "mode") == "file"
end

local function sanitizeTitle(title)
    title = tostring(title or "book")
    title = title:gsub("[^%w%s%-%_]", "")
    title = title:gsub("%s+", " ")
    title = title:gsub("^%s+", ""):gsub("%s+$", "")
    if title == "" then
        title = "book"
    end
    while #title > 100 do
        title = title:sub(1, #title - 1)
    end
    return title
end

local function joinPath(dir, name)
    if dir:sub(-1) == "/" then
        return dir .. name
    end
    return dir .. "/" .. name
end

function Downloader:new(plugin)
    local obj = { plugin = plugin }
    setmetatable(obj, { __index = self })
    return obj
end

function Downloader:defaultDir()
    return self.plugin.config:get("download_dir")
        or G_reader_settings:readSetting("home_dir")
        or G_reader_settings:readSetting("download_dir")
        or require("datastorage"):getDataDir()
end

function Downloader:filename(book, format, disambiguator)
    local tag = Models.formatTag(format)
    local suffix = disambiguator and string.format(" [%s-%s]", tag, disambiguator)
        or string.format(" [%s]", tag)
    return sanitizeTitle(Models.bookTitle(book)) .. suffix .. ".epub"
end

function Downloader:pathFor(book, format, disambiguator, dir)
    return joinPath(dir or self:defaultDir(), self:filename(book, format, disambiguator))
end

function Downloader:firstAvailableDisambiguatedPath(book, format, dir)
    local uuid = tostring(book.uuid or "")
    for len = 3, #uuid do
        local path = self:pathFor(book, format, uuid:sub(1, len), dir)
        if not isFile(path) then
            return path
        end
    end
    for n = 2, 999 do
        local path = self:pathFor(book, format, uuid .. "-" .. tostring(n), dir)
        if not isFile(path) then
            return path
        end
    end
    return nil
end

function Downloader:findExisting(book, format, dir)
    local identity = Sidecar:identityFrom(self.plugin.config, book, format)
    if not identity then
        return nil
    end
    local relation = Models.getAssetRelation(book, format)
    local normal_path = self:pathFor(book, format, nil, dir)
    local paths = { normal_path }
    local uuid = tostring(book.uuid or "")
    for len = 3, #uuid do
        table.insert(paths, self:pathFor(book, format, uuid:sub(1, len), dir))
    end
    for n = 2, 999 do
        table.insert(paths, self:pathFor(book, format, uuid .. "-" .. tostring(n), dir))
    end
    for _, path in ipairs(paths) do
        if isFile(path) then
            local data = Sidecar:read(path)
            if Sidecar:identityMatches(data, identity) then
                if data.asset_updated_at == relation.updatedAt then
                    return path, "fresh"
                end
                return path, "stale"
            end
        end
    end
    if isFile(normal_path) then
        return normal_path, "collision"
    end
    return nil
end

local function basename(path)
    return tostring(path or ""):match("([^/]+)$")
end

function Downloader:chooseFolder(book, format, replace_path, forced_path)
    require("ui/downloadmgr"):new{
        title = _("Choose download directory"),
        onConfirm = function(path)
            self.plugin.config:set("download_dir", path)
            UIManager:nextTick(function()
                local new_forced_path
                if replace_path then
                    new_forced_path = joinPath(path, basename(replace_path))
                end
                if forced_path then
                    new_forced_path = joinPath(path, basename(forced_path))
                end
                self:confirm(book, format, nil, new_forced_path)
            end)
        end,
    }:chooseDir(self:defaultDir())
end

function Downloader:showNoFormat()
    UIManager:show(InfoMessage:new{ text = "This book has no downloadable EPUB format." })
end

function Downloader:selectAndOpen(book, requested_format)
    local preferred = self.plugin.config:get("preferred_format", "ebook")
    local format = Models.selectFormat(book, preferred, requested_format)
    if not format then
        self:showNoFormat()
        return
    end
    local dir = self:defaultDir()
    local path, state = self:findExisting(book, format, dir)
    if state == "fresh" then
        ReaderUI:showReader(path)
        return
    elseif state == "stale" then
        self:promptStale(book, format, path)
        return
    elseif state == "collision" then
        self:promptCollision(book, format, path)
        return
    end
    self:confirm(book, format)
end

function Downloader:promptStale(book, format, path)
    local dialog
    dialog = ButtonDialog:new{
        title = "This local download is from an older Storyteller file version.\n\nRe-download it before syncing?",
        buttons = {
            {{
                text = _("Cancel"),
                callback = function()
                    UIManager:close(dialog)
                end,
            }},
            {{
                text = _("Replace local book"),
                callback = function()
                    UIManager:close(dialog)
                    self:confirm(book, format, path)
                end,
            }},
        },
    }
    UIManager:show(dialog)
end

function Downloader:promptCollision(book, format, normal_path)
    local dialog
    dialog = ButtonDialog:new{
        title = "A different book with this same title is already downloaded.\n\nWhat would you like to do?",
        buttons = {
            {{
                text = _("Cancel"),
                callback = function()
                    UIManager:close(dialog)
                end,
            }},
            {{
                text = _("Replace local book"),
                callback = function()
                    UIManager:close(dialog)
                    self:confirm(book, format, normal_path)
                end,
            }},
            {{
                text = _("Keep both"),
                callback = function()
                    UIManager:close(dialog)
                    local path = self:firstAvailableDisambiguatedPath(book, format, self:defaultDir())
                    if path then
                        self:confirm(book, format, nil, path)
                    else
                        UIManager:show(InfoMessage:new{ text = "Download failed." })
                    end
                end,
            }},
        },
    }
    UIManager:show(dialog)
end

function Downloader:confirm(book, format, replace_path, forced_path)
    local dir = self:defaultDir()
    local final_path = forced_path or replace_path or self:pathFor(book, format, nil, dir)
    local dialog
    dialog = ButtonDialog:new{
        title = string.format("Download \"%s\" as %s?\n\nFolder: %s",
            Models.bookTitle(book), Models.formatLabel(format), dir),
        buttons = {
            {{
                text = _("Choose folder"),
                callback = function()
                    UIManager:close(dialog)
                    self:chooseFolder(book, format, replace_path, forced_path)
                end,
            }},
            {{
                text = _("Cancel"),
                callback = function()
                    UIManager:close(dialog)
                end,
            }},
            {{
                text = _("Download"),
                callback = function()
                    UIManager:close(dialog)
                    self:download(book, format, final_path, replace_path ~= nil)
                end,
            }},
        },
    }
    UIManager:show(dialog)
end

function Downloader:download(book, format, final_path, replacing)
    NetworkMgr:runWhenOnline(function()
        local dir = final_path:match("^(.*)/[^/]+$")
        if dir and lfs.attributes(dir, "mode") ~= "directory" then
            lfs.mkdir(dir)
        end
        local relation = Models.getAssetRelation(book, format)
        if not Models.isDownloadableRelation(book, format) or not relation.updatedAt then
            UIManager:show(InfoMessage:new{ text = "Download failed." })
            return
        end
        if not replacing and isFile(final_path) then
            self.plugin.log:warn("download_path_collision", { path = final_path })
            UIManager:show(InfoMessage:new{ text = "Download failed." })
            return
        end
        local tmp_path = final_path .. ".storyteller.tmp"
        os.remove(tmp_path)
        local result = self.plugin.api:downloadFile(book.uuid, format, tmp_path)
        if not result.ok or not result.downloaded_hash then
            os.remove(tmp_path)
            self.plugin.log:warn("download_failed", result)
            UIManager:show(InfoMessage:new{ text = "Download failed." })
            return
        end
        if replacing then
            Sidecar:remove(final_path)
        end
        if os.rename(tmp_path, final_path) ~= true then
            os.remove(tmp_path)
            UIManager:show(InfoMessage:new{ text = "Download failed." })
            return
        end
        local sidecar = Sidecar:build(self.plugin.config, final_path, book, format, result.downloaded_hash)
        if not Sidecar:writeFull(final_path, sidecar, replacing) then
            if not replacing then
                os.remove(final_path)
            end
            UIManager:show(InfoMessage:new{ text = "Download failed." })
            return
        end
        self:downloaded(final_path)
    end)
end

function Downloader:downloaded(path)
    local dialog
    dialog = ButtonDialog:new{
        title = "Downloaded to:\n" .. path,
        buttons = {
            {{
                text = _("Open"),
                callback = function()
                    UIManager:close(dialog)
                    ReaderUI:showReader(path)
                end,
            }},
            {{
                text = _("Stay"),
                callback = function()
                    UIManager:close(dialog)
                end,
            }},
        },
    }
    UIManager:show(dialog)
end

return Downloader
