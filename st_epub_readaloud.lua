-- SPDX-License-Identifier: AGPL-3.0-or-later

local Util = require("st_epub_util")

local Readaloud = {}

function Readaloud.smilFragments(document, data, item)
    if not item or not item.media_overlay then
        return {}
    end
    local manifest = data and data.manifest_by_id
    local overlay = manifest and manifest[item.media_overlay]
    if not overlay then
        return {}
    end

    local smil = Util.readDocumentFile(document, overlay.path)
        or Util.readDocumentFile(document, overlay.href)
    if not smil then
        return {}
    end

    local smil_dir = Util.dirname(overlay.path)
    local chapter_href = Util.hrefKey(item.href)
    local chapter_path = Util.hrefKey(item.path)
    local fragments = {}
    for raw_src in smil:gmatch("<[%w_%-]*:?text[^>]-src%s*=%s*[\"'](.-)[\"']") do
        local src_path, fragment = raw_src:match("^(.-)#(.+)$")
        if fragment then
            fragment = Util.percentDecode(fragment)
            local absolute_src = Util.hrefKey(Util.joinPath(smil_dir, src_path))
            local plain_src = Util.hrefKey(src_path)
            if plain_src == chapter_href or plain_src == chapter_path
                    or absolute_src == chapter_href or absolute_src == chapter_path then
                table.insert(fragments, fragment)
            end
        end
    end
    return fragments
end

function Readaloud.chooseFragment(root, overlay_fragments, offset)
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

return Readaloud
