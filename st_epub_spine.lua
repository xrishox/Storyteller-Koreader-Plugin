-- SPDX-License-Identifier: AGPL-3.0-or-later

local Util = require("st_epub_util")

local Spine = {}

local SPINE_CACHE = setmetatable({}, { __mode = "k" })

local function parseContainer(document)
    local container = Util.readDocumentFile(document, "META-INF/container.xml")
    if not container then
        return nil
    end
    return container:match("<[%w_%-]*:?rootfile[^>]-full%-path%s*=%s*[\"'](.-)[\"']")
end

local function parseOpf(document)
    local rootfile = parseContainer(document)
    if not rootfile then
        return nil
    end

    local opf = Util.readDocumentFile(document, rootfile)
    if not opf then
        return nil
    end

    local opf_dir = Util.dirname(rootfile)
    local manifest_by_id = {}
    for raw in opf:gmatch("<[%w_%-]*:?item%s+([^>]-)>") do
        local attrs = Util.parseAttrs(raw)
        if attrs.id and attrs.href then
            attrs.href = Util.percentDecode(attrs.href)
            attrs.path = Util.joinPath(opf_dir, attrs.href)
            manifest_by_id[attrs.id] = attrs
        end
    end

    local spine = {}
    for raw in opf:gmatch("<[%w_%-]*:?itemref%s+([^>]-)>") do
        local attrs = Util.parseAttrs(raw)
        local item = attrs.idref and manifest_by_id[attrs.idref]
        if item then
            local spine_item = {
                id = item.id,
                href = item.href,
                path = item.path,
                linear = attrs.linear,
                media_overlay = item["media-overlay"],
                media_type = item["media-type"],
            }
            spine_item.spine_index = #spine
            table.insert(spine, spine_item)
        end
    end

    local reading_order = {}
    for _, item in ipairs(spine) do
        if Util.isReadableSpineItem(item) then
            table.insert(reading_order, item)
        end
    end

    return {
        rootfile = rootfile,
        opf_dir = opf_dir,
        manifest_by_id = manifest_by_id,
        spine = spine,
        reading_order = reading_order,
        spine_package_step = 6,
    }
end

function Spine.getSpine(document)
    if SPINE_CACHE[document] then
        return SPINE_CACHE[document]
    end
    local data = parseOpf(document)
    if data then
        SPINE_CACHE[document] = data
    end
    return data
end

function Spine.resolveHref(document, href)
    local data = Spine.getSpine(document)
    if not data then
        return nil
    end

    local wanted = Util.hrefKey(href)
    if wanted == "" then
        return nil, nil, data, {
            requested_href = href,
            wanted = wanted,
            reason = "empty_href",
            spine_count = data.spine and #data.spine or 0,
            reading_order_count = data.reading_order and #data.reading_order or 0,
        }
    end

    local suffix_match
    local items = data.spine or data.reading_order
    local first_items = {}
    for index, item in ipairs(items) do
        if Util.isTextMediaType(item.media_type) then
            local spine_index = tonumber(item.spine_index) or (index - 1)
            local href_key = Util.hrefKey(item.href)
            local path_key = Util.hrefKey(item.path)
            if #first_items < 5 then
                table.insert(first_items, {
                    index = spine_index,
                    href = item.href,
                    path = item.path,
                    linear = item.linear,
                    media_type = item.media_type,
                })
            end
            if wanted == href_key or wanted == path_key then
                return spine_index, item, data, {
                    requested_href = href,
                    wanted = wanted,
                    match = "exact",
                    matched_index = spine_index,
                    matched_href = item.href,
                    matched_path = item.path,
                    spine_count = data.spine and #data.spine or 0,
                    reading_order_count = data.reading_order and #data.reading_order or 0,
                }
            end
            if href_key:sub(-#wanted) == wanted or path_key:sub(-#wanted) == wanted then
                suffix_match = suffix_match or { spine_index, item, data, {
                    requested_href = href,
                    wanted = wanted,
                    match = "suffix",
                    matched_index = spine_index,
                    matched_href = item.href,
                    matched_path = item.path,
                    spine_count = data.spine and #data.spine or 0,
                    reading_order_count = data.reading_order and #data.reading_order or 0,
                } }
            end
        end
    end

    if suffix_match then
        return suffix_match[1], suffix_match[2], suffix_match[3], suffix_match[4]
    end
    return nil, nil, data, {
        requested_href = href,
        wanted = wanted,
        reason = "not_found",
        spine_count = data.spine and #data.spine or 0,
        reading_order_count = data.reading_order and #data.reading_order or 0,
        first_items = first_items,
    }
end

return Spine
