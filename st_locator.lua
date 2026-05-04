-- SPDX-License-Identifier: AGPL-3.0-or-later

local Event = require("ui/event")

local Epub = require("st_epub")
local Models = require("st_models")

local Locator = {}

local function currentTotalProgress(ui)
    if ui and ui.document and ui.document.info and ui.document.info.has_pages then
        if ui.paging and ui.paging.getLastPercent then
            return ui.paging:getLastPercent() or 0
        end
    elseif ui and ui.rolling and ui.rolling.getLastPercent then
        return ui.rolling:getLastPercent() or 0
    end
    return 0
end

function Locator:build(ui, sidecar, timestamp)
    local total_progression = Models.clamp(currentTotalProgress(ui), 0, 1)
    local locator = {
        href = "",
        type = "application/xhtml+xml",
        locations = {
            totalProgression = total_progression,
        },
    }

    if ui and ui.document and ui.document.info and not ui.document.info.has_pages
            and ui.rolling and ui.rolling.getLastProgress then
        local xpointer = ui.rolling:getLastProgress()
        local epub_locator = Epub:xpointerToLocator(ui.document, xpointer, total_progression, sidecar and sidecar.format)
        if epub_locator then
            locator = epub_locator
        end
    end

    return {
        locator = locator,
        timestamp = timestamp or Models.nowMs(),
    }
end

function Locator:apply(ui, remote)
    if not ui or not remote or type(remote.locator) ~= "table" then
        return false, false
    end
    local locator = remote.locator
    local locations = type(locator.locations) == "table" and locator.locations or {}

    if ui.document and ui.document.info and ui.document.info.has_pages then
        local total = tonumber(locations.totalProgression)
        if not total or not ui.document.getPageCount then
            return false, false
        end
        local page_count = ui.document:getPageCount()
        local page = math.floor(Models.clamp(total, 0, 1) * page_count)
        if page < 1 then
            page = 1
        elseif page > page_count then
            page = page_count
        end
        ui:handleEvent(Event:new("GotoPage", page))
        return true, false
    end

    local xpointer, precise, diagnostic = Epub:locatorToXPointer(ui.document, locator)
    if not xpointer then
        return false, false, diagnostic
    end
    if ui.document and ui.document.isXPointerInDocument then
        local ok, in_document = pcall(function()
            return ui.document:isXPointerInDocument(xpointer)
        end)
        if ok and not in_document then
            if type(diagnostic) ~= "table" then
                diagnostic = {}
            end
            diagnostic.target = xpointer
            diagnostic.reason = "target_not_in_document"
            return false, false, diagnostic
        end
    end
    ui:handleEvent(Event:new("GotoXPointer", xpointer))
    if type(diagnostic) ~= "table" then
        diagnostic = {}
    end
    diagnostic.target = xpointer
    return true, precise, diagnostic
end

function Locator:summary(locator)
    return Models.locatorSummary(locator)
end

return Locator
