-- SPDX-License-Identifier: AGPL-3.0-or-later

local ButtonDialog = require("ui/widget/buttondialog")
local InfoMessage = require("ui/widget/infomessage")
local ReaderUI = require("apps/reader/readerui")
local UIManager = require("ui/uimanager")
local lfs = require("libs/libkoreader-lfs")
local _ = require("gettext")

local Models = require("st_models")
local Sidecar = require("st_sidecar")

local Downloader = {}

local function isFile(path)
    if type(path) ~= "string" or path == "" then
        return false
    end
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

local function isDir(path)
    if type(path) ~= "string" or path == "" then
        return false
    end
    return lfs.attributes(path, "mode") == "directory"
end

local function ensureDir(path)
    if not path or path == "" or isDir(path) then
        return true
    end
    local parent = path:match("^(.*)/[^/]+$")
    if parent and parent ~= path and parent ~= "" and not ensureDir(parent) then
        return false
    end
    if isDir(path) then
        return true
    end
    return lfs.mkdir(path) == true
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

-- Set of entry names in dir, for reuse across many findExisting() calls.
function Downloader:listDirNames(dir)
    local names = {}
    if not isDir(dir) then
        return names
    end
    local ok, iter, dir_obj = pcall(lfs.dir, dir)
    if not ok then
        return names
    end
    for name in iter, dir_obj do
        names[name] = true
    end
    return names
end

function Downloader:findExisting(book, format, dir, dir_names)
    local identity = Sidecar:identityFrom(self.plugin.config, book, format)
    if not identity then
        return nil
    end
    local relation = Models.getAssetRelation(book, format)
    dir = dir or self:defaultDir()
    if type(dir) ~= "string" or dir == "" then
        return nil
    end
    dir_names = dir_names or self:listDirNames(dir)
    local normal_name = self:filename(book, format)
    local normal_path = joinPath(dir, normal_name)
    -- Disambiguated downloads are "<title> [<tag>-<disambiguator>].epub":
    -- the normal name with "-<disambiguator>" spliced in before the "]".
    local disamb_prefix = normal_name:sub(1, -#"].epub" - 1) .. "-"
    local candidates = {}
    if dir_names[normal_name] then
        table.insert(candidates, normal_name)
    end
    local disambiguated = {}
    for name in pairs(dir_names) do
        if name:sub(1, #disamb_prefix) == disamb_prefix and name:sub(-#"].epub") == "].epub" then
            table.insert(disambiguated, name)
        end
    end
    table.sort(disambiguated)
    for _, name in ipairs(disambiguated) do
        table.insert(candidates, name)
    end
    for _, name in ipairs(candidates) do
        local path = joinPath(dir, name)
        local data = Sidecar:read(path)
        if Sidecar:identityMatches(data, identity) then
            if data.asset_uuid == relation.uuid and data.asset_updated_at == relation.updatedAt then
                return path, "fresh"
            end
            return path, "stale"
        end
    end
    if dir_names[normal_name] and isFile(normal_path) then
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
            if type(path) ~= "string" or path == "" then
                UIManager:show(InfoMessage:new{ text = "Download failed." })
                return
            end
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
    if type(dir) ~= "string" or dir == "" then
        UIManager:show(InfoMessage:new{ text = "Download failed." })
        return
    end
    local path, state = self:findExisting(book, format, dir)
    if state == "fresh" then
        ReaderUI:showReader(path)
        return
    elseif state == "stale" then
        self.plugin.api:whenConnected(function()
            local valid, sidecar = Sidecar:validate(path, self.plugin.config)
            if not valid then
                self:promptStale(book, format, path)
                return
            end
            local current = self.plugin.api:getBook(sidecar.book_uuid)
            if not current.ok then
                UIManager:show(InfoMessage:new{ text = "Failed to verify Storyteller book. Please try again." })
                return
            end
            local fresh, reason = Sidecar:verifyAsset(sidecar, current.data, self.plugin.api, path)
            if fresh then
                ReaderUI:showReader(path)
            elseif reason == "stale" then
                self:promptStale(book, format, path)
            else
                UIManager:show(InfoMessage:new{ text = "Failed to verify Storyteller book. Please try again." })
            end
        end, {owner=self,key="verify"})
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
    if type(dir) ~= "string" or dir == "" then
        UIManager:show(InfoMessage:new{ text = "Download failed." })
        return
    end
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
    if type(book) ~= "table" or type(book.uuid) ~= "string" or book.uuid == "" then
        UIManager:show(InfoMessage:new{ text = "Download failed." })
        return
    end
    if type(final_path) ~= "string" or final_path == "" then
        UIManager:show(InfoMessage:new{ text = "Download failed." })
        return
    end
    local server_url = self.plugin.config:get("server_url")
    local user_id = self.plugin.config:get("user_id")
    self.plugin.api:whenConnected(function()
        if self.plugin.config:get("server_url") ~= server_url
                or self.plugin.config:get("user_id") ~= user_id then
            UIManager:show(InfoMessage:new{ text = "Download failed." })
            return
        end
        local dir = final_path:match("^(.*)/[^/]+$")
        if dir and not ensureDir(dir) then
            UIManager:show(InfoMessage:new{ text = "Download failed." })
            return
        end
        if not replacing and isFile(final_path) then
            self.plugin.log:warn("download_path_collision", { path = final_path })
            UIManager:show(InfoMessage:new{ text = "Download failed." })
            return
        end
        local book_result = self.plugin.api:getBook(book.uuid)
        if not book_result.ok or type(book_result.data) ~= "table" then
            self.plugin.log:warn("download_book_verify_failed", book_result)
            UIManager:show(InfoMessage:new{ text = "Download failed." })
            return
        end
        local download_book = book_result.data
        if type(download_book.uuid) ~= "string" or download_book.uuid == "" then
            download_book.uuid = book.uuid
        end
        local relation = Models.getAssetRelation(download_book, format)
        if not Models.isDownloadableRelation(download_book, format) or not relation.updatedAt then
            UIManager:show(InfoMessage:new{ text = "Download failed." })
            return
        end
        local tmp_path = final_path .. ".storyteller.tmp"
        os.remove(tmp_path)
        local Async = require("st_async")
        local dialog = ButtonDialog:new{
            title = "Downloading from Storyteller...",
            buttons = {{{text = _("Cancel"), callback = function() Async:cancel(self) end}}},
            dismissable = false,
        }
        UIManager:show(dialog)
        local close_dialog = Async:trackWidget(dialog)
        Async:onFinish(function() os.remove(tmp_path) end)
        local result = self.plugin.api:downloadFile(download_book.uuid or book.uuid, format, tmp_path)
        if not result.ok or not result.downloaded_hash then
            os.remove(tmp_path)
            self.plugin.log:warn("download_failed", result)
            UIManager:show(InfoMessage:new{ text = "Download failed." })
            return
        end
        -- Do not associate downloaded bytes with metadata that changed while
        -- the transfer was in progress (e.g. the server realigned the EPUB).
        local latest = self.plugin.api:getBook(book.uuid)
        local latest_relation = latest.ok and Models.getAssetRelation(latest.data, format)
        if type(latest_relation) ~= "table" or latest_relation.uuid ~= relation.uuid
                or latest_relation.updatedAt ~= relation.updatedAt
                or not Models.isDownloadableRelation(latest.data, format) then
            os.remove(tmp_path)
            self.plugin.log:warn("download_asset_changed")
            UIManager:show(InfoMessage:new{ text = "The Storyteller file changed during download. Please try again." })
            return
        end
        local sidecar = Sidecar:build(self.plugin.config, tmp_path, download_book, format, result.downloaded_hash)
        local committed, commit_error = Sidecar:commitDownload(final_path, tmp_path, sidecar)
        if not committed then
            os.remove(tmp_path)
            UIManager:show(InfoMessage:new{ text = commit_error == "metadata_pending"
                and "Book downloaded, but its details could not be saved. They will be recovered when the book is next opened or browsed. Check free space and storage access."
                or "Could not save the download. Check free space and storage access." })
            return
        end
        close_dialog()
        self:downloaded(final_path)
    end, {owner=self,key="download"})
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
