-- SPDX-License-Identifier: AGPL-3.0-or-later

local Position = require("st_epub_position")
local Spine = require("st_epub_spine")
local Text = require("st_epub_text")

local Epub = {}

function Epub:getSpine(document)
    return Spine.getSpine(document)
end

function Epub:resolveHref(document, href)
    return Spine.resolveHref(document, href)
end

function Epub:readChapter(document, item)
    return Text.readChapter(document, item)
end

function Epub:totalProgressionToLocator(document, total_progression, format)
    return Position.totalProgressionToLocator(document, total_progression, format)
end

function Epub:xpointerToLocator(document, xpointer, total_progression, format)
    return Position.xpointerToLocator(document, xpointer, total_progression, format)
end

function Epub:hrefProgressionToXPointer(document, href, progression)
    return Position.hrefProgressionToXPointer(document, href, progression)
end

function Epub:hrefFragmentToXPointer(document, href, fragment)
    return Position.hrefFragmentToXPointer(document, href, fragment)
end

function Epub:hrefStartToXPointer(document, href)
    return Position.hrefStartToXPointer(document, href)
end

function Epub:totalProgressionToXPointer(document, total_progression)
    return Position.totalProgressionToXPointer(document, total_progression)
end

function Epub:locatorToXPointer(document, locator, validator)
    return Position.locatorToXPointer(document, locator, validator)
end

return Epub
