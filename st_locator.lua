-- SPDX-License-Identifier: AGPL-3.0-or-later

local Event = require("ui/event")

local Epub = require("st_epub")
local Models = require("st_models")

local Locator = {}

local function currentTotalProgress(ui)
    if not ui then
        return 0
    end
    if ui.paging and ui.paging.getLastPercent then
        local ok, percent = pcall(function()
            return ui.paging:getLastPercent()
        end)
        if ok and percent then
            return percent
        end
    end
    if ui.rolling and ui.rolling.getLastPercent then
        local ok, percent = pcall(function()
            return ui.rolling:getLastPercent()
        end)
        if ok and percent then
            return percent
        end
    end
    if ui.document and ui.document.getCurrentPage and ui.document.getPageCount then
        local ok, page, page_count = pcall(function()
            return ui.document:getCurrentPage(), ui.document:getPageCount()
        end)
        page = tonumber(page)
        page_count = tonumber(page_count)
        if ok and page and page_count and page_count > 0 then
            return page / page_count
        end
    end
    return 0
end

local function currentXPointer(ui)
    if not ui or not ui.document then
        return nil
    end
    if ui.rolling and ui.rolling.getLastProgress then
        local ok, xpointer = pcall(function()
            return ui.rolling:getLastProgress()
        end)
        if ok and type(xpointer) == "string" and xpointer ~= "" then
            return xpointer
        end
    end
    if ui.document.getPageXPointer then
        local page
        local ok = pcall(function()
            page = ui.getCurrentPage and ui:getCurrentPage() or ui.document:getCurrentPage()
        end)
        if ok and page then
            local xpointer_ok, xpointer = pcall(function()
                return ui.document:getPageXPointer(page)
            end)
            if xpointer_ok and type(xpointer) == "string" and xpointer ~= "" then
                return xpointer
            end
        end
    end
    if ui.document.getXPointer then
        local ok, xpointer = pcall(function()
            return ui.document:getXPointer()
        end)
        if ok and type(xpointer) == "string" and xpointer ~= "" then
            return xpointer
        end
    end
    return nil
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

    if ui and ui.document then
        local xpointer = currentXPointer(ui)
        local epub_locator = Epub:xpointerToLocator(ui.document, xpointer, total_progression, sidecar and sidecar.format)
            or Epub:totalProgressionToLocator(ui.document, total_progression, sidecar and sidecar.format)
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
            return false, false, { reason = "missing_page_progress" }
        end
        local ok, page_count = pcall(function()
            return ui.document:getPageCount()
        end)
        if not ok or not tonumber(page_count) or tonumber(page_count) < 1 then
            return false, false, { reason = "invalid_page_count" }
        end
        page_count = tonumber(page_count)
        local page = math.floor(Models.clamp(total, 0, 1) * page_count)
        if page < 1 then
            page = 1
        elseif page > page_count then
            page = page_count
        end
        ok = pcall(function()
            ui:handleEvent(Event:new("GotoPage", page))
        end)
        if not ok then
            return false, false, { reason = "goto_page_failed", page = page }
        end
        return true, false, { method = "page", target = page }
    end

    local function validateXPointer(xpointer)
        if not ui.document or not ui.document.isXPointerInDocument then
            return true
        end
        local ok, in_document = pcall(function()
            return ui.document:isXPointerInDocument(xpointer)
        end)
        if not ok then
            return true
        end
        return in_document
    end

    local xpointer, precise, diagnostic = Epub:locatorToXPointer(ui.document, locator, validateXPointer)
    if not xpointer then
        return false, false, diagnostic
    end
    local ok = pcall(function()
        ui:handleEvent(Event:new("GotoXPointer", xpointer))
    end)
    if not ok then
        if type(diagnostic) ~= "table" then
            diagnostic = {}
        end
        diagnostic.reason = "goto_xpointer_failed"
        diagnostic.target = xpointer
        return false, false, diagnostic
    end
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
