-- SPDX-License-Identifier: AGPL-3.0-or-later

local DocSettings = require("docsettings")
local LuaSettings = require("luasettings")
local lfs = require("libs/libkoreader-lfs")

local Models = require("st_models")

local Storage = require("st_storage")

local Sidecar = {}
local verified_files = {}
local pending_writes = {}

local function fileHashMatches(filepath, expected)
    local stat = lfs.attributes(filepath)
    if not stat or type(expected) ~= "string" or #expected ~= 64 or not expected:match("^%x+$") then
        return false
    end
    local signature = table.concat({stat.size, stat.modification, stat.change or 0, stat.ino or 0}, ":")
    local cached = verified_files[filepath]
    if cached and cached.signature == signature and cached.hash == expected then return true end
    local file = io.open(filepath, "rb")
    if not file then return false end
    local hash = require("ffi/sha2").sha256()
    local bytes = 0
    while true do
        local chunk = file:read(65536)
        if not chunk then break end
        bytes = bytes + #chunk
        hash(chunk)
    end
    file:close()
    if bytes ~= stat.size or hash() ~= expected:lower() then return false end
    verified_files[filepath] = {signature = signature, hash = expected}
    return true
end

local REQUIRED_STRINGS = {
    "server_url",
    "user_id",
    "book_uuid",
    "book_title",
    "format",
    "asset_uuid",
    "asset_updated_at",
    "downloaded_hash",
}

local function isFile(path)
    if type(path) ~= "string" or path == "" then
        return false
    end
    return lfs.attributes(path, "mode") == "file"
end

local function isDir(path)
    if type(path) ~= "string" or path == "" then
        return false
    end
    return lfs.attributes(path, "mode") == "directory"
end

local function fileSize(path)
    if type(path) ~= "string" or path == "" then
        return nil
    end
    return lfs.attributes(path, "size")
end

local function ensureDir(path)
    if path == "" or isDir(path) then
        return true
    end
    local parent = path:match("^(.*)/[^/]+$")
    if parent and parent ~= path and parent ~= "" then
        if not ensureDir(parent) then
            return false
        end
    end
    if isDir(path) then
        return true
    end
    return lfs.mkdir(path) == true
end

function Sidecar:pathFor(filepath)
    if type(filepath) ~= "string" or filepath == "" then
        return nil
    end
    local dir = DocSettings:getSidecarDir(filepath)
    if dir == "" then
        return nil
    end
    return dir .. "/storyteller.lua"
end

function Sidecar:open(filepath)
    local path = self:pathFor(filepath)
    if not path then
        return nil
    end
    local data = self:read(filepath)
    return data and { data = data } or nil
end

function Sidecar:read(filepath)
    if not self:recoverDownload(filepath) then return nil end
    local path = self:pathFor(filepath)
    if not path then return nil end
    if pending_writes[path] then
        local data = pending_writes[path]
        if Storage:write(path, data) then pending_writes[path] = nil end
        return data, path
    end
    if not isFile(path) then return nil end
    local ok, settings = pcall(function()
        return LuaSettings:open(path)
    end)
    if ok and settings then
        return settings.data, path
    end
    return nil
end

function Sidecar:writeFull(filepath, data, remove_old)
    local path = self:pathFor(filepath)
    if not path then
        return false
    end
    local dir = path:match("^(.*)/[^/]+$")
    if dir and not ensureDir(dir) then
        return false
    end
    local ok, err = Storage:write(path, data)
    pending_writes[path] = not ok and data or nil
    if ok then os.remove(path .. ".old") end
    return ok, err
end

-- Journal new metadata before committing the EPUB. No old-book backup is created.
function Sidecar:commitDownload(filepath, temporary, data)
    local path = self:pathFor(filepath)
    if not path then return false, "sidecar_path" end
    local dir = path:match("^(.*)/[^/]+$")
    if not ensureDir(dir) then return false, "sidecar_directory" end
    local journal = path .. ".pending"
    local ok, err = Storage:write(journal, data)
    if not ok then return false, err end
    if not os.rename(temporary, filepath) then
        os.remove(journal)
        return false, "book_commit_failed"
    end
    verified_files[filepath] = nil
    if not require("ffi/util").fsyncDirectory(filepath) then return false, "metadata_pending" end
    if not self:writeFull(filepath, data) then return false, "metadata_pending" end
    os.remove(journal)
    return true
end

function Sidecar:recoverDownload(filepath)
    local path = self:pathFor(filepath)
    if not path or not isFile(path .. ".pending") then return true end
    local data = Storage:read(path .. ".pending")
    if not data or data.schema_version ~= 1 then return false end
    if fileHashMatches(filepath, data.downloaded_hash) then
        if not self:writeFull(filepath, data) then return false end
    else
        -- Crash before the EPUB rename: old EPUB and old metadata remain paired.
        os.remove(filepath .. ".storyteller.tmp")
    end
    os.remove(path .. ".pending")
    return true
end

function Sidecar:updateSyncFields(filepath, timestamp, source, locator, pending)
    local settings = self:open(filepath)
    if not settings then
        return false
    end
    settings.data.last_sync_timestamp = timestamp
    settings.data.last_sync_source = source
    settings.data.last_sync_locator_summary = Models.locatorSummary(locator)
    settings.data.pending_position = pending
    return self:writeFull(filepath, settings.data)
end

function Sidecar:setPendingPosition(filepath, payload)
    local settings = self:open(filepath)
    if not settings then return false end
    settings.data.pending_position = payload
    return self:writeFull(filepath, settings.data)
end

function Sidecar:identityFrom(config, book, format)
    local relation = Models.getAssetRelation(book, format)
    if not relation then
        return nil
    end
    return {
        server_url = config:get("server_url"),
        user_id = config:get("user_id"),
        book_uuid = book.uuid,
        format = format,
        asset_uuid = relation.uuid,
    }
end

function Sidecar:identityMatches(sidecar, identity)
    if type(sidecar) ~= "table" or type(identity) ~= "table" then
        return false
    end
    return sidecar.server_url == identity.server_url
        and sidecar.user_id == identity.user_id
        and sidecar.book_uuid == identity.book_uuid
        and sidecar.format == identity.format
end

function Sidecar:build(config, filepath, book, format, downloaded_hash)
    local relation = Models.getAssetRelation(book, format)
    return {
        schema_version = 1,
        server_url = config:get("server_url"),
        user_id = config:get("user_id"),
        username = config:get("username"),
        book_uuid = book.uuid,
        book_title = Models.bookTitle(book),
        format = format,
        asset_uuid = relation.uuid,
        asset_updated_at = relation.updatedAt,
        downloaded_hash = downloaded_hash,
        downloaded_at = config:nowMs(),
        local_file_size = fileSize(filepath) or 0,
        last_sync_timestamp = nil,
        last_sync_source = nil,
        last_sync_locator_summary = nil,
    }
end

function Sidecar:validate(filepath, config)
    if not isFile(filepath) then
        return false, nil, "file_missing"
    end
    local data = self:read(filepath)
    if type(data) ~= "table" then
        return false, nil, "sidecar_missing"
    end
    if data.schema_version ~= 1 then
        return false, data, "schema_version"
    end
    for _, key in ipairs(REQUIRED_STRINGS) do
        if not Models.isNonEmptyString(data[key]) then
            return false, data, "missing_" .. key
        end
    end
    if data.server_url ~= config:get("server_url") then
        return false, data, "server_mismatch"
    end
    if data.user_id ~= config:get("user_id") then
        return false, data, "user_mismatch"
    end
    if not Models.isValidFormat(data.format) then
        return false, data, "format"
    end
    if tonumber(data.local_file_size) ~= tonumber(fileSize(filepath)) then
        return false, data, "size_mismatch"
    end
    if not fileHashMatches(filepath, data.downloaded_hash) then
        return false, data, "hash_mismatch"
    end
    return true, data, nil
end

function Sidecar:assetFresh(sidecar, book)
    if type(sidecar) ~= "table" then
        return false
    end
    local relation = Models.getAssetRelation(book, sidecar and sidecar.format)
    if not relation then
        return false
    end
    return relation.uuid == sidecar.asset_uuid
        and relation.updatedAt == sidecar.asset_updated_at
        and Models.isDownloadableRelation(book, sidecar.format)
end

return Sidecar
