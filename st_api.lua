-- SPDX-License-Identifier: AGPL-3.0-or-later

local Models = require("st_models")

local Api = {}

function Api:new(http_client)
    local obj = { http = http_client }
    setmetatable(obj, { __index = self })
    return obj
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
