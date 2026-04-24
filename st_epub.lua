-- SPDX-License-Identifier: AGPL-3.0-or-later

local Models = require("st_models")

local Epub = {}

local SPINE_CACHE = setmetatable({}, { __mode = "k" })

local NAMED_ENTITIES = {
    amp = "&",
    lt = "<",
    gt = ">",
    quot = '"',
    apos = "'",
    nbsp = " ",
    mdash = "-",
    ndash = "-",
    lsquo = "'",
    rsquo = "'",
    ldquo = '"',
    rdquo = '"',
    hellip = "...",
}

local VOID_ELEMENTS = {
    area = true,
    base = true,
    br = true,
    col = true,
    embed = true,
    hr = true,
    img = true,
    input = true,
    link = true,
    meta = true,
    param = true,
    source = true,
    track = true,
    wbr = true,
}

local function dirname(path)
    return path:match("^(.*)/[^/]*$") or ""
end

local function normalizePath(path)
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

local function joinPath(base, path)
    if not base or base == "" then
        return normalizePath(path)
    end
    if not path or path == "" then
        return normalizePath(base)
    end
    if path:sub(1, 1) == "/" then
        return normalizePath(path:sub(2))
    end
    return normalizePath(base .. "/" .. path)
end

local function percentDecode(value)
    return (tostring(value or ""):gsub("%%(%x%x)", function(hex)
        return string.char(tonumber(hex, 16))
    end))
end

local function stripFragment(path)
    return (tostring(path or ""):gsub("#.*$", ""))
end

local function hrefKey(path)
    path = percentDecode(stripFragment(path)):gsub("^/+", "")
    return normalizePath(path)
end

local function parseAttrs(raw)
    local attrs = {}
    for key, _, value in raw:gmatch("([%w_:%-]+)%s*=%s*([\"'])(.-)%2") do
        attrs[key] = value
    end
    return attrs
end

local function decodeEntities(text)
    text = text:gsub("&#x([%da-fA-F]+);", function(hex)
        local n = tonumber(hex, 16)
        if not n then
            return ""
        end
        if n < 128 then
            return string.char(n)
        end
        return " "
    end)
    text = text:gsub("&#(%d+);", function(dec)
        local n = tonumber(dec)
        if not n then
            return ""
        end
        if n < 128 then
            return string.char(n)
        end
        return " "
    end)
    return (text:gsub("&([%a]+);", function(name)
        return NAMED_ENTITIES[name] or " "
    end))
end

local function utf16Len(text)
    local len = 0
    local i = 1
    local bytes = #text
    while i <= bytes do
        local b = text:byte(i)
        local code
        local advance
        if not b then
            break
        elseif b < 0x80 then
            code = b
            advance = 1
        elseif b < 0xE0 then
            local b2 = text:byte(i + 1) or 0
            code = (b % 0x20) * 0x40 + (b2 % 0x40)
            advance = 2
        elseif b < 0xF0 then
            local b2 = text:byte(i + 1) or 0
            local b3 = text:byte(i + 2) or 0
            code = (b % 0x10) * 0x1000 + (b2 % 0x40) * 0x40 + (b3 % 0x40)
            advance = 3
        else
            local b2 = text:byte(i + 1) or 0
            local b3 = text:byte(i + 2) or 0
            local b4 = text:byte(i + 3) or 0
            code = (b % 0x08) * 0x40000 + (b2 % 0x40) * 0x1000 + (b3 % 0x40) * 0x40 + (b4 % 0x40)
            advance = 4
        end
        len = len + (code and code > 0xFFFF and 2 or 1)
        i = i + advance
    end
    return len
end

local function readDocumentFile(document, path)
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

local function bodyMarkup(html)
    local lower = html:lower()
    local body_start, body_open_end = lower:find("<body[^>]*>")
    if not body_open_end then
        return html
    end
    local body_close_start = lower:find("</body>", body_open_end + 1)
    if body_close_start then
        return html:sub(body_open_end + 1, body_close_start - 1)
    end
    return html:sub(body_open_end + 1)
end

local function countElementChild(parent, tag)
    local count = 0
    for _, child in ipairs(parent.children) do
        if child.type == "element" and child.tag == tag then
            count = count + 1
        end
    end
    return count + 1
end

local function countTextChild(parent)
    local count = 0
    for _, child in ipairs(parent.children) do
        if child.type == "text" then
            count = count + 1
        end
    end
    return count + 1
end

local function parseBodyTree(html)
    local body = bodyMarkup(html)
    local root = {
        type = "element",
        tag = "body",
        index = 1,
        children = {},
        start_offset = 0,
        ids = {},
    }
    local stack = { root }
    local offset = 0
    local pos = 1
    while true do
        local tag_start, tag_end = body:find("<[^>]*>", pos)
        local text = tag_start and body:sub(pos, tag_start - 1) or body:sub(pos)
        if text ~= "" then
            local decoded = decodeEntities(text)
            local len = utf16Len(decoded)
            if len > 0 then
                local parent = stack[#stack]
                table.insert(parent.children, {
                    type = "text",
                    parent = parent,
                    index = countTextChild(parent),
                    start_offset = offset,
                    length = len,
                })
                offset = offset + len
            end
        end
        if not tag_start then
            break
        end
        local raw = body:sub(tag_start + 1, tag_end - 1)
        if raw:match("^!%-%-") or raw:match("^!") or raw:match("^%?") then
            -- ignored
        elseif raw:match("^/") then
            local close_tag = raw:match("^/%s*([%w:_%-]+)")
            close_tag = close_tag and close_tag:lower()
            while #stack > 1 do
                local node = table.remove(stack)
                node.end_offset = offset
                if node.tag == close_tag then
                    break
                end
            end
        else
            local tag = raw:match("^%s*([%w:_%-]+)")
            if tag then
                tag = tag:lower()
                local parent = stack[#stack]
                local attrs = parseAttrs(raw)
                local node = {
                    type = "element",
                    tag = tag,
                    attrs = attrs,
                    parent = parent,
                    index = countElementChild(parent, tag),
                    children = {},
                    start_offset = offset,
                }
                table.insert(parent.children, node)
                if attrs.id and attrs.id ~= "" then
                    root.ids[attrs.id] = offset
                end
                if not raw:match("/%s*$") and not VOID_ELEMENTS[tag] then
                    table.insert(stack, node)
                else
                    node.end_offset = offset
                end
            end
        end
        pos = tag_end + 1
    end
    while #stack > 1 do
        local node = table.remove(stack)
        node.end_offset = offset
    end
    root.end_offset = offset
    root.total_length = offset
    return root
end

local function selectElement(parent, tag, index)
    index = tonumber(index) or 1
    local count = 0
    for _, child in ipairs(parent.children or {}) do
        if child.type == "element" and child.tag == tag then
            count = count + 1
            if count == index then
                return child
            end
        end
    end
    return nil
end

local function selectText(parent, index)
    index = tonumber(index) or 1
    local count = 0
    for _, child in ipairs(parent.children or {}) do
        if child.type == "text" then
            count = count + 1
            if count == index then
                return child
            end
        end
    end
    return nil
end

local function selectElementOrdinal(parent, index)
    index = tonumber(index) or 1
    local count = 0
    for _, child in ipairs(parent.children or {}) do
        if child.type == "element" then
            count = count + 1
            if count == index then
                return child
            end
        end
    end
    return nil
end

local function elementFromStep(parent, step)
    local tag, index = step:match("^([%w:_%-]+)%[(%d+)%]$")
    if not tag then
        tag = step:match("^([%w:_%-]+)$")
        index = 1
    end
    if not tag then
        return nil
    end
    tag = tag:lower()
    if tag == "body" and parent.tag == "body" then
        return parent
    end
    return selectElement(parent, tag, index)
end

local function xpathToOffset(root, path)
    if type(path) ~= "string" or path == "" then
        return 0
    end
    path = path:gsub("^/+", "")
    local current = root
    for step in path:gmatch("[^/]+") do
        local text_index, text_offset = step:match("^text%(%)[%[](%d+)%][%.:](%d+)$")
        if not text_index then
            text_offset = step:match("^text%(%)[%.:](%d+)$")
            text_index = 1
        end
        if text_offset then
            local text_node = selectText(current, text_index)
            if not text_node then
                return current.start_offset or 0
            end
            return text_node.start_offset + tonumber(text_offset)
        end

        local element_step, char_offset = step:match("^(.+)[%.:](%d+)$")
        if element_step then
            local node = elementFromStep(current, element_step)
            return (node and node.start_offset or current.start_offset or 0) + tonumber(char_offset)
        end

        current = elementFromStep(current, step)
        if not current then
            return 0
        end
    end
    return current.start_offset or 0
end

local function findTextAtOffset(node, offset)
    for _, child in ipairs(node.children or {}) do
        if child.type == "text" then
            if offset >= child.start_offset and offset <= child.start_offset + child.length then
                return child
            end
        else
            local start_offset = child.start_offset or 0
            local end_offset = child.end_offset or start_offset
            if offset >= start_offset and offset <= end_offset then
                local found = findTextAtOffset(child, offset)
                if found then
                    return found
                end
            end
        end
    end
    return nil
end

local function pathForElement(node)
    local parts = {}
    while node and node.parent do
        table.insert(parts, 1, string.format("%s[%d]", node.tag, node.index or 1))
        node = node.parent
    end
    return "/" .. table.concat(parts, "/")
end

local function offsetToXPath(root, offset)
    offset = Models.clamp(math.floor(offset or 0), 0, root.total_length or 0)
    local text_node = findTextAtOffset(root, offset)
    if text_node then
        local parent_path = pathForElement(text_node.parent)
        if parent_path == "/" then
            parent_path = ""
        end
        return string.format("%s/text()[%d].%d", parent_path, text_node.index or 1,
            math.max(0, offset - text_node.start_offset))
    end
    return ""
end

local function parseXPointer(xpointer)
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

local function normalizeXPointer(document, xpointer)
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

local function parseContainer(document)
    local container = readDocumentFile(document, "META-INF/container.xml")
    if not container then
        return nil
    end
    return container:match("<rootfile[^>]-full%-path%s*=%s*[\"'](.-)[\"']")
end

local function parseOpf(document)
    local rootfile = parseContainer(document)
    if not rootfile then
        return nil
    end
    local opf = readDocumentFile(document, rootfile)
    if not opf then
        return nil
    end
    local opf_dir = dirname(rootfile)
    local manifest_by_id = {}
    for raw in opf:gmatch("<item%s+([^>]-)>") do
        local attrs = parseAttrs(raw)
        if attrs.id and attrs.href then
            attrs.href = percentDecode(attrs.href)
            attrs.path = joinPath(opf_dir, attrs.href)
            manifest_by_id[attrs.id] = attrs
        end
    end
    local spine = {}
    for raw in opf:gmatch("<itemref%s+([^>]-)>") do
        local attrs = parseAttrs(raw)
        local item = attrs.idref and manifest_by_id[attrs.idref]
        if item then
            table.insert(spine, {
                id = item.id,
                href = item.href,
                path = item.path,
                media_overlay = item["media-overlay"],
                media_type = item["media-type"],
            })
        end
    end
    return {
        rootfile = rootfile,
        opf_dir = opf_dir,
        manifest_by_id = manifest_by_id,
        spine = spine,
        spine_package_step = 6,
    }
end

function Epub:getSpine(document)
    if SPINE_CACHE[document] then
        return SPINE_CACHE[document]
    end
    local data = parseOpf(document)
    if data then
        SPINE_CACHE[document] = data
    end
    return data
end

function Epub:resolveHref(document, href)
    local data = self:getSpine(document)
    if not data then
        return nil
    end
    local wanted = hrefKey(href)
    local suffix_match
    for index, item in ipairs(data.spine) do
        local href_key = hrefKey(item.href)
        local path_key = hrefKey(item.path)
        if wanted == href_key or wanted == path_key then
            return index - 1, item, data
        end
        if href_key:sub(-#wanted) == wanted or path_key:sub(-#wanted) == wanted then
            suffix_match = suffix_match or { index - 1, item, data }
        end
    end
    if suffix_match then
        return suffix_match[1], suffix_match[2], suffix_match[3]
    end
    return nil
end

function Epub:readChapter(document, item)
    local html = item and readDocumentFile(document, item.path)
    if not html and item then
        html = readDocumentFile(document, item.href)
    end
    if not html then
        return nil
    end
    return html, parseBodyTree(html)
end

local function smilFragments(document, data, item)
    if not item or not item.media_overlay then
        return {}
    end
    local overlay = data.manifest_by_id[item.media_overlay]
    if not overlay then
        return {}
    end
    local smil = readDocumentFile(document, overlay.path) or readDocumentFile(document, overlay.href)
    if not smil then
        return {}
    end
    local smil_dir = dirname(overlay.path)
    local chapter_href = hrefKey(item.href)
    local chapter_path = hrefKey(item.path)
    local fragments = {}
    for raw_src in smil:gmatch("<text[^>]-src%s*=%s*[\"'](.-)[\"']") do
        local src_path, fragment = raw_src:match("^(.-)#(.+)$")
        if fragment then
            local absolute_src = hrefKey(joinPath(smil_dir, src_path))
            local plain_src = hrefKey(src_path)
            if plain_src == chapter_href or plain_src == chapter_path
                    or absolute_src == chapter_href or absolute_src == chapter_path then
                table.insert(fragments, fragment)
            end
        end
    end
    return fragments
end

local function chooseReadaloudFragment(root, overlay_fragments, offset)
    local candidates = {}
    local overlay_set = {}
    for _, id in ipairs(overlay_fragments or {}) do
        overlay_set[id] = true
    end
    local prefer_overlay = next(overlay_set) ~= nil
    for id, id_offset in pairs(root.ids or {}) do
        if not prefer_overlay or overlay_set[id] then
            table.insert(candidates, { id = id, offset = id_offset })
        end
    end
    if #candidates == 0 and prefer_overlay then
        for id, id_offset in pairs(root.ids or {}) do
            table.insert(candidates, { id = id, offset = id_offset })
        end
    end
    table.sort(candidates, function(a, b)
        if a.offset == b.offset then
            return a.id < b.id
        end
        return a.offset < b.offset
    end)
    local selected = candidates[1]
    for _, candidate in ipairs(candidates) do
        if candidate.offset <= offset then
            selected = candidate
        else
            break
        end
    end
    return selected and selected.id
end

function Epub:xpointerToLocator(document, xpointer, total_progression, format)
    local chapter_index, body_path = parseXPointer(xpointer)
    if not chapter_index then
        return nil
    end
    local data = self:getSpine(document)
    local item = data and data.spine[chapter_index + 1]
    if not item then
        return nil
    end
    local _, root = self:readChapter(document, item)
    local progression = 0
    local fragment
    if root then
        local offset = xpathToOffset(root, body_path)
        if root.total_length and root.total_length > 0 then
            progression = Models.clamp(offset / root.total_length, 0, 1)
        end
        if format == "readaloud" then
            fragment = chooseReadaloudFragment(root, smilFragments(document, data, item), offset)
        end
    end
    local locations = {
        progression = progression,
        totalProgression = Models.clamp(total_progression or 0, 0, 1),
    }
    if fragment then
        locations.fragments = { fragment }
    end
    return {
        href = item.path or item.href,
        type = "application/xhtml+xml",
        locations = locations,
    }
end

function Epub:hrefProgressionToXPointer(document, href, progression)
    local chapter_index, item = self:resolveHref(document, href)
    if not item then
        return nil
    end
    local _, root = self:readChapter(document, item)
    if not root then
        return nil
    end
    local offset = math.floor((root.total_length or 0) * Models.clamp(progression or 0, 0, 1))
    local xpath = offsetToXPath(root, offset)
    return normalizeXPointer(document, string.format("/body/DocFragment[%d]/body%s", chapter_index + 1, xpath))
end

function Epub:hrefFragmentToXPointer(document, href, fragment)
    local chapter_index, item = self:resolveHref(document, href)
    if not item then
        return nil
    end
    local _, root = self:readChapter(document, item)
    if not root or not root.ids or root.ids[fragment] == nil then
        return nil
    end
    local xpath = offsetToXPath(root, root.ids[fragment])
    return normalizeXPointer(document, string.format("/body/DocFragment[%d]/body%s", chapter_index + 1, xpath))
end

function Epub:hrefStartToXPointer(document, href)
    local chapter_index = self:resolveHref(document, href)
    if chapter_index == nil then
        return nil
    end
    return normalizeXPointer(document, string.format("/body/DocFragment[%d]/body/", chapter_index + 1))
end

function Epub:locatorToXPointer(document, locator)
    if type(locator) ~= "table" then
        return nil
    end
    local locations = type(locator.locations) == "table" and locator.locations or {}
    if type(locations.fragments) == "table" and locations.fragments[1] then
        local xpointer = self:hrefFragmentToXPointer(document, locator.href, locations.fragments[1])
        if xpointer then
            return xpointer, true
        end
    end
    if locations.progression ~= nil then
        local xpointer = self:hrefProgressionToXPointer(document, locator.href, locations.progression)
        if xpointer then
            return xpointer, true
        end
    end
    local xpointer = self:hrefStartToXPointer(document, locator.href)
    if xpointer then
        return xpointer, false
    end
    return nil, false
end

return Epub
