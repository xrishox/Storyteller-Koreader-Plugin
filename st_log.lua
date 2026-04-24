-- SPDX-License-Identifier: AGPL-3.0-or-later

local DataStorage = require("datastorage")
local lfs = require("libs/libkoreader-lfs")
local rapidjson = require("rapidjson")

local Log = {
    config = nil,
}

local LEVELS = {
    error = 1,
    warn = 2,
    info = 3,
}

local SENSITIVE = {
    access_token = true,
    asset_uuid = true,
    authorization = true,
    Authorization = true,
    book_uuid = true,
    device_code = true,
    deviceCode = true,
    downloaded_hash = true,
    email = true,
    filepath = true,
    headers = true,
    path = true,
    qr_svg_url = true,
    raw_body = true,
    server_url = true,
    status_line = true,
    user_code = true,
    user_id = true,
    username = true,
    verification_uri = true,
    verification_uri_complete = true,
}

local function copyRedacted(value, key)
    if SENSITIVE[key] then
        return "REDACTED"
    end
    if type(value) ~= "table" then
        return value
    end
    local result = {}
    for k, v in pairs(value) do
        result[k] = copyRedacted(v, k)
    end
    return result
end

local function fileExists(path)
    return lfs.attributes(path, "mode") == "file"
end

function Log:setConfig(config)
    self.config = config
end

function Log:effectiveVerbosity()
    local configured = self.config and self.config:get("log_verbosity")
    if LEVELS[configured] then
        return configured
    end
    if fileExists(DataStorage:getSettingsDir() .. "/storyteller.debug") then
        return "info"
    end
    return "warn"
end

function Log:enabled(level)
    return LEVELS[level] <= LEVELS[self:effectiveVerbosity()]
end

function Log:write(level, event_name, data)
    if not self:enabled(level) then
        return
    end
    local line_data = ""
    if data ~= nil then
        local ok, encoded = pcall(rapidjson.encode, copyRedacted(data))
        if not ok then
            encoded = nil
        end
        line_data = encoded and (" " .. encoded) or " {}"
    end
    local file = io.open(DataStorage:getSettingsDir() .. "/storyteller.log", "a")
    if not file then
        return
    end
    file:write(os.date("%Y-%m-%d %H:%M:%S"), " [", level, "] ", event_name or "event", line_data, "\n")
    file:close()
end

function Log:error(event_name, data)
    self:write("error", event_name, data)
end

function Log:warn(event_name, data)
    self:write("warn", event_name, data)
end

function Log:info(event_name, data)
    self:write("info", event_name, data)
end

return Log
