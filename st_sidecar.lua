-- SPDX-License-Identifier: AGPL-3.0-or-later

local DocSettings = require("docsettings")
local LuaSettings = require("luasettings")
local lfs = require("libs/libkoreader-lfs")

local Models = require("st_models")

local Sidecar = {}

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
    return lfs.attributes(path, "mode") == "file"
end

local function isDir(path)
    return lfs.attributes(path, "mode") == "directory"
end

local function fileSize(path)
    return lfs.attributes(path, "size")
end

local function ensureDir(path)
    if path == "" or isDir(path) then
        return true
    end
    local parent = path:match("^(.*)/[^/]+$")
    if parent and parent ~= path and parent ~= "" then
        ensureDir(parent)
    end
    if isDir(path) then
        return true
    end
    return lfs.mkdir(path)
end

function Sidecar:pathFor(filepath)
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
    return LuaSettings:open(path)
end

function Sidecar:read(filepath)
    local path = self:pathFor(filepath)
    if not path or not isFile(path) then
        return nil
    end
    return LuaSettings:open(path).data, path
end

function Sidecar:remove(filepath)
    local path = self:pathFor(filepath)
    if not path then
        return
    end
    os.remove(path)
    os.remove(path .. ".old")
end

function Sidecar:writeFull(filepath, data, remove_old)
    local path = self:pathFor(filepath)
    if not path then
        return false
    end
    local dir = path:match("^(.*)/[^/]+$")
    ensureDir(dir)
    if remove_old then
        os.remove(path)
        os.remove(path .. ".old")
    end
    local settings = LuaSettings:open(path)
    settings.data = data
    settings:flush()
    return true
end

function Sidecar:updateSyncFields(filepath, timestamp, source, locator)
    local settings = self:open(filepath)
    if not settings then
        return false
    end
    settings.data.last_sync_timestamp = timestamp
    settings.data.last_sync_source = source
    settings.data.last_sync_locator_summary = Models.locatorSummary(locator)
    settings:flush()
    return true
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
        and sidecar.asset_uuid == identity.asset_uuid
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
    return true, data, nil
end

function Sidecar:assetFresh(sidecar, book)
    local relation = Models.getAssetRelation(book, sidecar and sidecar.format)
    if not relation then
        return false
    end
    return relation.uuid == sidecar.asset_uuid
        and relation.updatedAt == sidecar.asset_updated_at
        and Models.isDownloadableRelation(book, sidecar.format)
end

return Sidecar
