-- SPDX-License-Identifier: AGPL-3.0-or-later

local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")

local Locator = require("st_locator")
local Models = require("st_models")
local Sidecar = require("st_sidecar")

local Remote = {}

Remote.VERIFY_OK = "ok"
Remote.VERIFY_STALE = "stale"
Remote.VERIFY_AUTH = "auth"
Remote.VERIFY_TIMEOUT = "timeout"
Remote.VERIFY_TRANSIENT = "transient"

local function show(text)
    UIManager:show(InfoMessage:new{ text = text })
end

local function locatorFragment(locator)
    local locations = type(locator) == "table" and locator.locations
    local fragments = type(locations) == "table" and locations.fragments
    local fragment = type(fragments) == "table" and fragments[1] or nil
    if type(fragment) == "string" and fragment ~= "" then
        return fragment
    end
    return nil
end

local function isReadaloud(sidecar)
    return type(sidecar) == "table" and sidecar.format == "readaloud"
end

local function hasStorytellerHref(locator)
    return type(locator) == "table"
        and type(locator.href) == "string"
        and locator.href ~= ""
end

function Remote:new(plugin)
    local obj = { plugin = plugin }
    setmetatable(obj, { __index = self })
    return obj
end

function Remote:documentFile()
    local ui = self.plugin.ui
    return ui and ui.document and ui.document.file
end

function Remote:validateCurrent(silent)
    local filepath = self:documentFile()
    if not filepath or not self.plugin.config:isLoggedIn() or not self.plugin.config:get("server_url") then
        if not silent then
            show("This book was not downloaded from Storyteller.")
        end
        return nil, nil, "ineligible"
    end
    local ok, sidecar, reason = Sidecar:validate(filepath, self.plugin.config)
    if not ok then
        self.plugin.log:info("sync_ineligible", { reason = reason, filepath = filepath })
        if not silent then
            show("This book was not downloaded from Storyteller.")
        end
        return nil, filepath, reason
    end
    return sidecar, filepath, nil
end

function Remote:verifyAsset(sidecar)
    local result = self.plugin.api:getBook(sidecar.book_uuid)
    if result.kind == "not_authenticated" then
        return false, self.VERIFY_AUTH
    end
    if result.kind == "timeout" then
        self.plugin.log:warn("sync_book_verify_timeout", result)
        return false, self.VERIFY_TIMEOUT
    end
    if not result.ok or type(result.data) ~= "table" then
        self.plugin.log:warn("sync_book_verify_failed", result)
        if result.kind == "handled_error" and result.status == 404 then
            return false, self.VERIFY_STALE
        end
        return false, self.VERIFY_TRANSIENT
    end
    if not Sidecar:assetFresh(sidecar, result.data) then
        self.plugin.log:info("sync_asset_stale", {
            book_uuid = sidecar.book_uuid,
            format = sidecar.format,
        })
        return false, self.VERIFY_STALE
    end
    return true, self.VERIFY_OK
end

function Remote:buildPayload(sidecar, timestamp)
    return Locator:build(self.plugin.ui, sidecar, timestamp)
end

function Remote:ensureStorytellerLocator(sidecar, payload, source, manual)
    local locator = payload and payload.locator
    if hasStorytellerHref(locator) then
        return true
    end
    self.plugin.log:warn("storyteller_locator_missing_skip", {
        source = source,
        format = sidecar and sidecar.format or nil,
        locator = Models.locatorForLog(locator),
        locator_summary = Models.locatorSummary(locator),
    })
    if manual then
        show("Could not find a Storyteller reading position for this book.")
    end
    return false
end

function Remote:ensureReadaloudFragment(sidecar, payload, source, manual)
    if not isReadaloud(sidecar) or locatorFragment(payload and payload.locator) then
        return true
    end
    self.plugin.log:warn("readaloud_fragment_missing_skip", {
        source = source,
        locator = Models.locatorForLog(payload and payload.locator or nil),
        locator_summary = Models.locatorSummary(payload and payload.locator or nil),
    })
    if manual then
        show("Could not find a Storyteller readaloud fragment for this position.")
    end
    return false
end

function Remote:updateSidecarSyncFields(filepath, timestamp, source, locator)
    local ok = Sidecar:updateSyncFields(filepath, timestamp, source, locator)
    if not ok then
        self.plugin.log:warn("sidecar_sync_update_failed", { source = source })
    end
    return ok
end

function Remote:logPositionPayload(event_name, payload, extra)
    local data = {}
    for key, value in pairs(extra or {}) do
        data[key] = value
    end
    local raw_locator = payload and payload.locator or data.locator
    data.timestamp = payload and payload.timestamp or data.timestamp
    data.locator = Models.locatorForLog(raw_locator)
    data.locator_summary = Models.locatorSummary(raw_locator)
    self.plugin.log:info(event_name, data)
end

function Remote:fetchPosition(sidecar)
    return self.plugin.api:getPosition(sidecar.book_uuid)
end

function Remote:savePosition(sidecar, payload)
    return self.plugin.api:savePosition(sidecar.book_uuid, payload.locator, payload.timestamp)
end

return Remote
