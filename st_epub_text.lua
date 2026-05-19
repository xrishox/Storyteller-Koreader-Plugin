-- SPDX-License-Identifier: AGPL-3.0-or-later

local Models = require("st_models")
local Util = require("st_epub_util")

local Text = {}

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

local function bodyMarkup(html)
    local lower = html:lower()
    local _, body_open_end = lower:find("<body[^>]*>")
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

function Text.parseBodyTree(html)
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
            -- Ignore comments, declarations, and processing instructions.
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
                local attrs = Util.parseAttrs(raw)
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
                local id = attrs.id or attrs["xml:id"]
                if id and id ~= "" then
                    root.ids[id] = offset
                    local decoded_id = Util.percentDecode(id)
                    if decoded_id ~= id then
                        root.ids[decoded_id] = offset
                    end
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

function Text.xpathToOffset(root, path)
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

local function findTextAtOffset(node, offset, inclusive_end)
    for _, child in ipairs(node.children or {}) do
        if child.type == "text" then
            local child_end = child.start_offset + child.length
            if offset >= child.start_offset
                    and (offset < child_end or (inclusive_end and offset <= child_end)) then
                return child
            end
        else
            local start_offset = child.start_offset or 0
            local end_offset = child.end_offset or start_offset
            if offset >= start_offset
                    and (offset < end_offset or (inclusive_end and offset <= end_offset)) then
                local found = findTextAtOffset(child, offset, inclusive_end)
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

function Text.offsetToXPath(root, offset)
    offset = Models.clamp(math.floor(offset or 0), 0, root.total_length or 0)
    local text_node = findTextAtOffset(root, offset)
    if not text_node and offset >= (root.total_length or 0) and (root.total_length or 0) > 0 then
        text_node = findTextAtOffset(root, offset, true)
    end
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

function Text.readChapter(document, item)
    local html = item and Util.readDocumentFile(document, item.path)
    if not html and item then
        html = Util.readDocumentFile(document, item.href)
    end
    if not html then
        return nil
    end
    return html, Text.parseBodyTree(html)
end

return Text
