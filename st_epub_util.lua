-- SPDX-License-Identifier: AGPL-3.0-or-later

local Util = {}

function Util.dirname(path)
    return tostring(path or ""):match("^(.*)/[^/]*$") or ""
end

function Util.normalizePath(path)
    path = tostring(path or ""):gsub("\\", "/")
    local absolute = path:sub(1, 1) == "/"
    local parts = {}
    for part in path:gmatch("[^/]+") do
        if part == ".." then
            if #parts > 0 then
                table.remove(parts)
            end
        elseif part ~= "." and part ~= "" then
            table.insert(parts, part)
        end
    end
    return (absolute and "/" or "") .. table.concat(parts, "/")
end

function Util.joinPath(base, path)
    if not base or base == "" then
        return Util.normalizePath(path)
    end
    if not path or path == "" then
        return Util.normalizePath(base)
    end
    if path:sub(1, 1) == "/" then
        return Util.normalizePath(path:sub(2))
    end
    return Util.normalizePath(base .. "/" .. path)
end

function Util.percentDecode(value)
    return (tostring(value or ""):gsub("%%(%x%x)", function(hex)
        return string.char(tonumber(hex, 16))
    end))
end

function Util.stripFragment(path)
    return (tostring(path or ""):gsub("#.*$", ""))
end

function Util.hrefKey(path)
    path = tostring(path or "")
    path = path:gsub("%?.*$", "")
    path = path:gsub("^https?://[^/]+/api/v%d+/books/[^/]+/read/", "")
    path = path:gsub("^https?://[^/]+/api/v%d+/books/[^/]+/listen/", "")
    path = path:gsub("^/api/v%d+/books/[^/]+/read/", "")
    path = path:gsub("^/api/v%d+/books/[^/]+/listen/", "")
    path = Util.percentDecode(Util.stripFragment(path)):gsub("^/+", "")
    return Util.normalizePath(path)
end

function Util.parseAttrs(raw)
    local attrs = {}
    for key, _, value in tostring(raw or ""):gmatch("([%w_:%-]+)%s*=%s*([\"'])(.-)%2") do
        attrs[key] = value
    end
    return attrs
end

function Util.readDocumentFile(document, path)
    if not document or not document.getDocumentFileContent then
        return nil
    end
    local ok, data = pcall(function()
        return document:getDocumentFileContent(path)
    end)
    if ok then
        return data
    end
    return nil
end

function Util.isTextMediaType(media_type)
    media_type = type(media_type) == "string" and media_type:lower() or media_type
    return media_type == "application/xhtml+xml" or media_type == "text/html"
end

function Util.isReadableSpineItem(item)
    local linear = type(item) == "table" and item.linear
    linear = type(linear) == "string" and linear:lower() or linear
    return item
        and Util.isTextMediaType(item.media_type)
        and linear ~= "no"
        and item.href ~= nil
        and item.href ~= ""
end

function Util.storytellerHref(item)
    return item and (item.path or item.href) or ""
end

function Util.docFragmentNumber(item, fallback_zero_index)
    local spine_index = type(item) == "table" and tonumber(item.spine_index) or nil
    return (spine_index or fallback_zero_index or 0) + 1
end

function Util.parseXPointer(xpointer)
    if type(xpointer) ~= "string" then
        return nil
    end
    local n, path = xpointer:match("^/body/DocFragment%[(%d+)%]/body/?(.*)$")
    if not n then
        path = xpointer:match("^/body/DocFragment/body/?(.*)$")
        n = path and 1 or nil
    end
    n = tonumber(n)
    if not n then
        return nil
    end
    return n - 1, "/" .. (path or "")
end

function Util.normalizeXPointer(document, xpointer)
    if document and document.getNormalizedXPointer then
        local ok, normalized = pcall(function()
            return document:getNormalizedXPointer(xpointer)
        end)
        if ok and type(normalized) == "string" and normalized ~= "" then
            return normalized
        end
    end
    return xpointer
end

return Util
