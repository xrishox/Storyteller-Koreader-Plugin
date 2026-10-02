-- SPDX-License-Identifier: AGPL-3.0-or-later

local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local socket = require("socket")

local Storage = require("st_storage")

local Config = {}
local instances = {}

Config.DEFAULTS = {
    sync_enabled = true,
    preferred_format = "ebook",
    log_verbosity = "warn",
}

local AUTH_KEYS = {
    "access_token",
    "token_expires_at",
    "token_type",
    "user_id",
    "username",
    "email",
}

local MAX_TOKEN_EXPIRES_IN_MS = 366 * 24 * 60 * 60 * 1000

local function trim(s)
    return (s or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function nowMs()
    if socket and socket.gettime then
        return math.floor(socket.gettime() * 1000)
    end
    return math.floor(os.time() * 1000)
end

local function saneFormat(value)
    if value == "ebook" or value == "readaloud" then
        return value
    end
    return Config.DEFAULTS.preferred_format
end

local function saneVerbosity(value)
    if value == "error" or value == "warn" or value == "info" then
        return value
    end
    return Config.DEFAULTS.log_verbosity
end

function Config:open()
    local path = DataStorage:getDataDir() .. "/storyteller.lua"
    -- FileManager, ReaderUI and SimpleUI must share current credentials.
    if instances[path] then return instances[path] end
    local settings = LuaSettings:open(path)
    local obj = {
        settings = settings,
        path = path,
        data = settings.data,
    }
    setmetatable(obj, { __index = self })
    obj:ensureDefaults()
    obj:repairAuthState()
    instances[path] = obj
    return obj
end

function Config:ensureDefaults()
    for key, value in pairs(self.DEFAULTS) do
        if self.data[key] == nil then
            self.data[key] = value
        end
    end
    self.data.preferred_format = saneFormat(self.data.preferred_format)
    self.data.log_verbosity = saneVerbosity(self.data.log_verbosity)
    return self:flush()
end

function Config:flush()
    local ok, err = Storage:write(self.path, self.data)
    if not ok then
        local UIManager = require("ui/uimanager")
        local InfoMessage = require("ui/widget/infomessage")
        UIManager:show(InfoMessage:new{ text = "Could not save Storyteller settings. Check free space and storage access." })
    end
    return ok, err
end

function Config:get(key, default)
    local value = self.data[key]
    if value == nil then
        return default
    end
    return value
end

function Config:set(key, value)
    if key == "server_url" then
        return self:setServerUrl(value)
    elseif key == "preferred_format" then
        value = saneFormat(value)
    elseif key == "log_verbosity" then
        value = saneVerbosity(value)
    end
    self.data[key] = value
    return self:flush()
end

function Config:normalizeServerUrl(input)
    local url = trim(input)
    if url == "" then
        return "", nil
    end
    if url:find("[%s?#@]") or (url:find("://", 1, true) and not url:match("^https?://")) then
        return nil, "invalid"
    end
    if not url:match("^https?://") then
        url = "http://" .. url
    end
    url = url:gsub("/+$", "")
    url = url:gsub("/api/v2$", "")
    local scheme, rest = url:match("^(https?)://(.+)$")
    if not scheme or not rest or rest == "" then
        return nil, "invalid"
    end
    local host = rest:match("^([^/%s]+)")
    if not host or host == "" then
        return nil, "invalid"
    end
    return url, nil
end

function Config:setServerUrl(input)
    local normalized, err = self:normalizeServerUrl(input)
    if not normalized then
        return nil, err
    end
    local server_url = normalized ~= "" and normalized or nil
    if self.data.server_url ~= server_url then
        for _, key in ipairs(AUTH_KEYS) do self.data[key] = nil end
    end
    self.data.server_url = server_url
    local ok, err = self:flush()
    if not ok then return nil, err end
    return normalized
end

function Config:isHttpServer()
    local url = self.data.server_url
    return type(url) == "string" and url:match("^http://") ~= nil
end

function Config:isLoggedIn()
    return type(self.data.access_token) == "string" and self.data.access_token ~= ""
        and type(self.data.user_id) == "string" and self.data.user_id ~= ""
end

function Config:repairAuthState()
    if self.data.access_token and not self.data.user_id then
        self:clearAuth()
    end
end

function Config:clearAuth()
    for _, key in ipairs(AUTH_KEYS) do
        self.data[key] = nil
    end
    return self:flush()
end

function Config:computeTokenExpiresAt(expires_in)
    if type(expires_in) ~= "number" then
        return nil
    end
    if expires_in <= 0 or expires_in > MAX_TOKEN_EXPIRES_IN_MS then
        return nil
    end
    return nowMs() + expires_in
end

function Config:saveAuth(token_response, user)
    self.data.access_token = token_response.access_token
    self.data.token_expires_at = self:computeTokenExpiresAt(token_response.expires_in)
    self.data.token_type = token_response.token_type
    self.data.user_id = user.id
    self.data.username = user.username
    self.data.email = user.email
    return self:flush()
end

function Config:nowMs()
    return nowMs()
end

return Config
