-- SPDX-License-Identifier: AGPL-3.0-or-later

local Models = require("st_models")
local Readaloud = require("st_epub_readaloud")
local Spine = require("st_epub_spine")
local Text = require("st_epub_text")
local Util = require("st_epub_util")

local Position = {}

local function locatorFromItem(item, progression, total_progression, fragment)
    local locations = {
        progression = Models.clamp(progression or 0, 0, 1),
        totalProgression = Models.clamp(total_progression or 0, 0, 1),
    }
    if fragment then
        locations.fragments = { fragment }
    end
    return {
        href = Util.storytellerHref(item),
        type = "application/xhtml+xml",
        locations = locations,
    }
end

local function chaptersForProgression(document, reading_order)
    local chapters = {}
    local total_length = 0
    for index, item in ipairs(reading_order) do
        local _, root = Text.readChapter(document, item)
        local length = root and root.total_length or 0
        table.insert(chapters, {
            index = index - 1,
            item = item,
            root = root,
            length = length,
        })
        total_length = total_length + length
    end
    return chapters, total_length
end

local function selectChapterByTotalProgression(chapters, total_length, target)
    local target_offset = math.floor(total_length * target)
    if target_offset <= 0 then
        return chapters[1], 0
    end
    if target_offset >= total_length then
        local selected = chapters[#chapters]
        return selected, selected and selected.length or 0
    end

    local consumed = 0
    local selected = chapters[#chapters]
    for _, chapter in ipairs(chapters) do
        if target_offset < consumed + chapter.length then
            selected = chapter
            break
        end
        consumed = consumed + chapter.length
    end
    return selected, target_offset - consumed
end

local function idOffset(root, fragment)
    if not root or not root.ids then
        return nil
    end
    if root.ids[fragment] ~= nil then
        return root.ids[fragment]
    end
    local decoded = Util.percentDecode(fragment)
    if decoded ~= fragment then
        return root.ids[decoded]
    end
    return nil
end

function Position.totalProgressionToLocator(document, total_progression, format)
    local data = Spine.getSpine(document)
    local reading_order = data and data.reading_order or nil
    if type(reading_order) ~= "table" or #reading_order == 0 then
        return nil
    end

    local target = Models.clamp(total_progression or 0, 0, 1)
    local chapters, total_length = chaptersForProgression(document, reading_order)
    if total_length <= 0 then
        local index = math.floor(target * #reading_order) + 1
        if index > #reading_order then
            index = #reading_order
        end
        return locatorFromItem(reading_order[index], 0, target)
    end

    local selected, selected_offset = selectChapterByTotalProgression(chapters, total_length, target)
    local progression = 0
    local fragment
    if selected and selected.length and selected.length > 0 then
        progression = Models.clamp(selected_offset / selected.length, 0, 1)
    end
    if format == "readaloud" and selected and selected.root then
        fragment = Readaloud.chooseFragment(selected.root,
            Readaloud.smilFragments(document, data, selected.item), selected_offset)
    end
    return locatorFromItem(selected and selected.item, progression, target, fragment)
end

function Position.xpointerToLocator(document, xpointer, total_progression, format)
    local chapter_index, body_path = Util.parseXPointer(xpointer)
    if not chapter_index then
        return nil
    end

    local data = Spine.getSpine(document)
    local item = data and data.spine and data.spine[chapter_index + 1]
    if not Util.isReadableSpineItem(item) then
        item = data and data.reading_order and data.reading_order[chapter_index + 1]
    end
    if not Util.isReadableSpineItem(item) then
        return Position.totalProgressionToLocator(document, total_progression, format)
    end

    local _, root = Text.readChapter(document, item)
    local progression = 0
    local fragment
    if root then
        local offset = Text.xpathToOffset(root, body_path)
        if root.total_length and root.total_length > 0 then
            progression = Models.clamp(offset / root.total_length, 0, 1)
        end
        if format == "readaloud" then
            fragment = Readaloud.chooseFragment(root, Readaloud.smilFragments(document, data, item), offset)
        end
    end
    return locatorFromItem(item, progression, total_progression, fragment)
end

function Position.hrefProgressionToXPointer(document, href, progression)
    local chapter_index, item = Spine.resolveHref(document, href)
    if not item then
        return nil
    end
    local _, root = Text.readChapter(document, item)
    if not root then
        return nil
    end
    local offset = math.floor((root.total_length or 0) * Models.clamp(progression or 0, 0, 1))
    local xpath = Text.offsetToXPath(root, offset)
    return Util.normalizeXPointer(document, string.format("/body/DocFragment[%d]/body%s", chapter_index + 1, xpath))
end

function Position.hrefFragmentToXPointer(document, href, fragment)
    local chapter_index, item = Spine.resolveHref(document, href)
    if not item then
        return nil
    end
    local _, root = Text.readChapter(document, item)
    local offset = idOffset(root, fragment)
    if offset == nil then
        return nil
    end
    local xpath = Text.offsetToXPath(root, offset)
    return Util.normalizeXPointer(document, string.format("/body/DocFragment[%d]/body%s", chapter_index + 1, xpath))
end

function Position.hrefStartToXPointer(document, href)
    local chapter_index = Spine.resolveHref(document, href)
    if chapter_index == nil then
        return nil
    end
    return Util.normalizeXPointer(document, string.format("/body/DocFragment[%d]/body/", chapter_index + 1))
end

function Position.totalProgressionToXPointer(document, total_progression)
    local data = Spine.getSpine(document)
    local reading_order = data and data.reading_order or nil
    if type(reading_order) ~= "table" or #reading_order == 0 then
        return nil
    end

    local target = Models.clamp(total_progression or 0, 0, 1)
    local chapters, total_length = chaptersForProgression(document, reading_order)
    if total_length <= 0 then
        local index = math.floor(target * #reading_order) + 1
        if index > #reading_order then
            index = #reading_order
        end
        return Util.normalizeXPointer(document, string.format("/body/DocFragment[%d]/body/",
            Util.docFragmentNumber(reading_order[index], index - 1)))
    end

    local selected, offset = selectChapterByTotalProgression(chapters, total_length, target)
    if not selected or not selected.root then
        local chapter_index = selected and selected.index or 0
        return Util.normalizeXPointer(document, string.format("/body/DocFragment[%d]/body/",
            Util.docFragmentNumber(reading_order[chapter_index + 1], chapter_index)))
    end
    if offset < 0 then
        offset = 0
    elseif offset > selected.length then
        offset = selected.length
    end
    local xpath = Text.offsetToXPath(selected.root, offset)
    local index = (selected.index or 0) + 1
    return Util.normalizeXPointer(document, string.format("/body/DocFragment[%d]/body%s",
        Util.docFragmentNumber(reading_order[index], index - 1), xpath))
end

function Position.locatorToXPointer(document, locator, validator)
    if type(locator) ~= "table" then
        return nil, false, { reason = "missing_locator" }
    end
    local locations = type(locator.locations) == "table" and locator.locations or {}
    local attempts = {}
    local fragment_failed = false

    local function acceptCandidate(attempt, xpointer)
        if not xpointer then
            attempt.resolved = false
            return false
        end
        attempt.resolved = true
        attempt.target = xpointer
        if type(validator) == "function" and not validator(xpointer) then
            attempt.accepted = false
            attempt.reason = "target_not_in_document"
            return false
        end
        attempt.accepted = true
        return true
    end

    if type(locations.fragments) == "table" and locations.fragments[1] then
        table.insert(attempts, {
            method = "fragment",
            href = locator.href,
            fragment = locations.fragments[1],
        })
        local _, _, _, href_diagnostic = Spine.resolveHref(document, locator.href)
        attempts[#attempts].href_diagnostic = href_diagnostic
        local xpointer = Position.hrefFragmentToXPointer(document, locator.href, locations.fragments[1])
        if acceptCandidate(attempts[#attempts], xpointer) then
            return xpointer, true, { method = "fragment", attempts = attempts }
        end
        fragment_failed = true
    end

    if fragment_failed and tonumber(locations.progression) == 0 and locations.totalProgression ~= nil then
        table.insert(attempts, {
            method = "total_progression_after_fragment",
            total_progression = locations.totalProgression,
        })
        local xpointer = Position.totalProgressionToXPointer(document, locations.totalProgression)
        if acceptCandidate(attempts[#attempts], xpointer) then
            return xpointer, false, { method = "total_progression_after_fragment", attempts = attempts }
        end
    end

    if locations.progression ~= nil then
        table.insert(attempts, {
            method = "progression",
            href = locator.href,
            progression = locations.progression,
        })
        local _, _, _, href_diagnostic = Spine.resolveHref(document, locator.href)
        attempts[#attempts].href_diagnostic = href_diagnostic
        local xpointer = Position.hrefProgressionToXPointer(document, locator.href, locations.progression)
        if acceptCandidate(attempts[#attempts], xpointer) then
            return xpointer, true, { method = "progression", attempts = attempts }
        end
    end

    table.insert(attempts, {
        method = "chapter_start",
        href = locator.href,
    })
    local _, _, _, href_diagnostic = Spine.resolveHref(document, locator.href)
    attempts[#attempts].href_diagnostic = href_diagnostic
    local xpointer = Position.hrefStartToXPointer(document, locator.href)
    if acceptCandidate(attempts[#attempts], xpointer) then
        return xpointer, false, { method = "chapter_start", attempts = attempts }
    end

    if locations.totalProgression ~= nil then
        table.insert(attempts, {
            method = "total_progression",
            total_progression = locations.totalProgression,
        })
        local xpointer = Position.totalProgressionToXPointer(document, locations.totalProgression)
        if acceptCandidate(attempts[#attempts], xpointer) then
            return xpointer, false, { method = "total_progression", attempts = attempts }
        end
    end

    return nil, false, { reason = "unresolved", attempts = attempts }
end

return Position
