-- SPDX-License-Identifier: AGPL-3.0-or-later

local socket = require("socket")

local Models = {}

Models.FORMATS = {
    readaloud = {
        label = "Read Aloud",
        tag = "r",
        relation = "readaloud",
    },
    ebook = {
        label = "Standard EPUB",
        tag = "e",
        relation = "ebook",
    },
}

local function isNonEmptyString(value)
    return type(value) == "string" and value ~= ""
end

function Models.isNonEmptyString(value)
    return isNonEmptyString(value)
end

function Models.formatLabel(format)
    return Models.FORMATS[format] and Models.FORMATS[format].label or tostring(format)
end

function Models.formatTag(format)
    return Models.FORMATS[format] and Models.FORMATS[format].tag or "x"
end

function Models.formatRelation(format)
    return Models.FORMATS[format] and Models.FORMATS[format].relation or format
end

function Models.isValidFormat(format)
    return Models.FORMATS[format] ~= nil
end

function Models.isDownloadableRelation(book, format)
    if type(book) ~= "table" or not Models.isValidFormat(format) then
        return false
    end
    local relation = book[Models.formatRelation(format)]
    if type(relation) ~= "table" then
        return false
    end
    if not isNonEmptyString(relation.uuid) or not isNonEmptyString(relation.filepath) then
        return false
    end
    if relation.missing == true then
        return false
    end
    if format == "readaloud" and relation.status ~= "ALIGNED" then
        return false
    end
    return true
end

function Models.hasDownloadableFormat(book)
    return Models.isDownloadableRelation(book, "readaloud")
        or Models.isDownloadableRelation(book, "ebook")
end

function Models.selectFormat(book, preferred, requested)
    if requested then
        if Models.isDownloadableRelation(book, requested) then
            return requested
        end
        return nil, "unavailable"
    end
    if Models.isDownloadableRelation(book, preferred) then
        return preferred
    end
    if Models.isDownloadableRelation(book, "readaloud") then
        return "readaloud"
    end
    if Models.isDownloadableRelation(book, "ebook") then
        return "ebook"
    end
    return nil, "unavailable"
end

function Models.getAssetRelation(book, format)
    if type(book) ~= "table" then
        return nil
    end
    return book[Models.formatRelation(format)]
end

function Models.bookTitle(book)
    if type(book) == "table" and isNonEmptyString(book.title) then
        return book.title
    end
    return "Untitled"
end

function Models.authorText(book)
    if type(book) ~= "table" or type(book.authors) ~= "table" then
        return nil
    end
    local names = {}
    for _, author in ipairs(book.authors) do
        if type(author) == "table" and isNonEmptyString(author.name) then
            table.insert(names, author.name)
        end
    end
    if #names == 0 then
        return nil
    end
    return table.concat(names, ", ")
end

function Models.lowerTitle(book)
    return string.lower(Models.bookTitle(book))
end

function Models.parseDate(value)
    if type(value) ~= "string" or #value < 19 then
        return 0
    end
    local y = tonumber(value:sub(1, 4))
    local m = tonumber(value:sub(6, 7))
    local d = tonumber(value:sub(9, 10))
    local h = tonumber(value:sub(12, 13))
    local min = tonumber(value:sub(15, 16))
    local s = tonumber(value:sub(18, 19))
    if not y or not m or not d or not h or not min or not s then
        return 0
    end
    return os.time{ year = y, month = m, day = d, hour = h, min = min, sec = s } or 0
end

function Models.urlEncode(value)
    value = tostring(value or "")
    return (value:gsub("([^A-Za-z0-9_%.%-%~])", function(c)
        return string.format("%%%02X", string.byte(c))
    end))
end

function Models.header(headers, name)
    if type(headers) ~= "table" then
        return nil
    end
    local wanted = string.lower(name)
    for key, value in pairs(headers) do
        if string.lower(tostring(key)) == wanted then
            return value
        end
    end
    return nil
end

function Models.clamp(value, min, max)
    value = tonumber(value) or 0
    if value < min then
        return min
    end
    if value > max then
        return max
    end
    return value
end

function Models.nowMs()
    if socket and socket.gettime then
        return math.floor(socket.gettime() * 1000)
    end
    return math.floor(os.time() * 1000)
end

function Models.positionTimestamp(position)
    if type(position) == "table" then
        return tonumber(position.timestamp) or 0
    end
    return 0
end

function Models.positionPercent(position)
    local locator = position and position.locator
    local locations = type(locator) == "table" and locator.locations
    local progression = type(locations) == "table" and tonumber(locations.totalProgression)
    if not progression then
        return "Unknown"
    end
    return tostring(math.floor(Models.clamp(progression, 0, 1) * 100 + 0.5)) .. "%"
end

function Models.formatTimestamp(timestamp)
    timestamp = tonumber(timestamp)
    if not timestamp or timestamp <= 0 then
        return "Unknown"
    end
    if timestamp > 9999999999 then
        timestamp = math.floor(timestamp / 1000)
    end
    return os.date("%Y-%m-%d %H:%M:%S", timestamp) or "Unknown"
end

function Models.locatorSummary(locator)
    if type(locator) ~= "table" then
        return nil
    end
    local locations = type(locator.locations) == "table" and locator.locations or {}
    local fragment
    if type(locations.fragments) == "table" then
        fragment = locations.fragments[1]
    end
    return {
        href = locator.href,
        total_progression = locations.totalProgression,
        progression = locations.progression,
        fragment = fragment,
    }
end

function Models.locatorForLog(locator)
    if type(locator) ~= "table" then
        return nil
    end
    local locations = type(locator.locations) == "table" and locator.locations or {}
    local fragments
    if type(locations.fragments) == "table" then
        fragments = {}
        for index, fragment in ipairs(locations.fragments) do
            fragments[index] = fragment
        end
    end
    return {
        href = locator.href,
        type = locator.type,
        locations = {
            fragments = fragments,
            progression = locations.progression,
            totalProgression = locations.totalProgression,
            position = locations.position,
        },
    }
end

return Models
