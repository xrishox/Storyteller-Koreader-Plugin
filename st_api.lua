-- SPDX-License-Identifier: AGPL-3.0-or-later

local Models = require("st_models")

local Api = {}

function Api:new(http_client)
    local obj = { http = http_client }
    setmetatable(obj, { __index = self })
    return obj
end

-- Existing synchronous methods remain stable. UI callers opt into background waits.
function Api:run(fn, options)
    local Async = require("st_async")
    if Async:current() then return fn() end
    options = options or {}
    local config = self.http.config
    local server, user, token = config:get("server_url"), config:get("user_id"), config:get("access_token")
    return Async:run(options.owner or self, options.key or fn, function()
        return config:get("server_url") == server and config:get("user_id") == user
            and config:get("access_token") == token and (not options.guard or options.guard())
    end, fn, options.finished)
end

function Api:cancel(owner)
    require("st_async"):cancel(owner or self)
end

function Api:whenConnected(fn, options)
    local config = self.http.config
    local server, user = config:get("server_url"), config:get("user_id")
    local token = config:get("access_token")
    local launch
    launch = function()
        if config:get("server_url") ~= server or config:get("user_id") ~= user
                or config:get("access_token") ~= token or (options and options.guard and not options.guard()) then return end
        if not self:run(fn, options) then require("ui/uimanager"):scheduleIn(0.1, launch) end
    end
    require("ui/network/manager"):runWhenConnected(launch)
end

local function bookPath(book_uuid, suffix)
    return "/api/v2/books/" .. Models.urlEncode(book_uuid) .. (suffix or "")
end

function Api:deviceStart()
    return self.http:request{
        method = "POST",
        path = "/api/v2/device/start",
        authenticated = false,
        body = {},
    }
end

function Api:deviceToken(device_code)
    return self.http:request{
        method = "POST",
        path = "/api/v2/device/token",
        authenticated = false,
        handled_statuses = { [400] = true },
        body = { device_code = device_code },
    }
end

function Api:getUser(token)
    return self.http:request{
        method = "GET",
        path = "/api/v2/user",
        authenticated = true,
        token = token,
        handled_statuses = { [401] = true, [403] = true },
    }
end

function Api:listBooks()
    return self.http:request{ method = "GET", path = "/api/v2/books" }
end

function Api:listCollections()
    return self.http:request{ method = "GET", path = "/api/v2/collections" }
end

function Api:listSeries()
    return self.http:request{ method = "GET", path = "/api/v2/series" }
end

function Api:getBook(book_uuid)
    return self.http:request{
        method = "GET",
        path = bookPath(book_uuid),
        handled_statuses = { [404] = true },
    }
end

function Api:getPosition(book_uuid)
    return self.http:request{
        method = "GET",
        path = bookPath(book_uuid, "/positions"),
        handled_statuses = { [404] = true },
    }
end

function Api:savePosition(book_uuid, locator, timestamp)
    -- A percentage without a publication resource cannot be restored by Readium.
    if type(locator) ~= "table" or not Models.isNonEmptyString(locator.href)
            or not Models.isNonEmptyString(locator.type)
            or type(timestamp) ~= "number" or timestamp ~= timestamp
            or timestamp <= 0 or timestamp == math.huge then
        return { ok = false, kind = "invalid_position" }
    end
    return self.http:request{
        method = "POST",
        path = bookPath(book_uuid, "/positions"),
        handled_statuses = { [409] = true },
        body = {
            locator = locator,
            timestamp = timestamp,
        },
    }
end

function Api:downloadFile(book_uuid, format, filepath)
    return self.http:download{
        path = bookPath(book_uuid, "/files?format=" .. Models.urlEncode(format)),
        filepath = filepath,
        accept = "application/epub+zip,application/octet-stream",
    }
end

return Api
