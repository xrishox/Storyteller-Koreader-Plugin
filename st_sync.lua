-- SPDX-License-Identifier: AGPL-3.0-or-later

local ButtonDialog = require("ui/widget/buttondialog")
local InfoMessage = require("ui/widget/infomessage")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local _ = require("gettext")

local Locator = require("st_locator")
local Models = require("st_models")
local Sidecar = require("st_sidecar")

local Sync = {}

local INELIGIBLE = "This book was not downloaded from Storyteller."
local STALE = "This local download is from an older Storyteller file version. Re-download it before syncing."
local AUTH_FAILED = "Storyteller authentication failed. Please relink device."

local VERIFY_OK = "ok"
local VERIFY_STALE = "stale"
local VERIFY_AUTH = "auth"
local VERIFY_TIMEOUT = "timeout"
local VERIFY_TRANSIENT = "transient"

local function show(text)
    UIManager:show(InfoMessage:new{ text = text })
end

function Sync:logPositionPayload(event_name, payload, extra)
    local data = extra or {}
    data.timestamp = payload and payload.timestamp or data.timestamp
    data.locator = Models.locatorForLog(payload and payload.locator or data.locator)
    data.locator_summary = Models.locatorSummary(payload and payload.locator or data.locator)
    self.plugin.log:info(event_name, data)
end

function Sync:new(plugin)
    local obj = {
        plugin = plugin,
        active = false,
        filepath = nil,
        sidecar = nil,
        book_meta = nil,
        pending_progress_payload = nil,
        progress_push_task = nil,
        remote_conflict_pending = false,
        autosync_error_dialog = nil,
        autosync_paused_until_reset = false,
        suppress_progress_capture = false,
        remote_apply_release_task = nil,
        last_page = nil,
        generation = 0,
    }
    setmetatable(obj, { __index = self })
    return obj
end

function Sync:documentFile()
    local ui = self.plugin.ui
    return ui and ui.document and ui.document.file
end

function Sync:message(text, silent)
    if not silent then
        show(text)
    end
end

function Sync:validateSidecar(silent)
    local filepath = self:documentFile()
    if not filepath or not self.plugin.config:isLoggedIn() or not self.plugin.config:get("server_url") then
        self:message(INELIGIBLE, silent)
        return nil
    end
    local ok, sidecar, reason = Sidecar:validate(filepath, self.plugin.config)
    if not ok then
        self.plugin.log:info("sync_ineligible", { reason = reason, filepath = filepath })
        self:message(INELIGIBLE, silent)
        return nil
    end
    return sidecar, filepath
end

function Sync:verifyAsset(sidecar, silent)
    local result = self.plugin.api:getBook(sidecar.book_uuid)
    if result.kind == "not_authenticated" then
        self:message(AUTH_FAILED, silent)
        return false, VERIFY_AUTH
    end
    if result.kind == "timeout" then
        self.plugin.log:warn("sync_book_verify_timeout", result)
        return false, VERIFY_TIMEOUT
    end
    if not result.ok or type(result.data) ~= "table" then
        self.plugin.log:warn("sync_book_verify_failed", result)
        if result.kind == "handled_error" and result.status == 404 then
            self:message(STALE, silent)
            return false, VERIFY_STALE
        end
        return false, VERIFY_TRANSIENT
    end
    if not Sidecar:assetFresh(sidecar, result.data) then
        self.plugin.log:info("sync_asset_stale", {
            book_uuid = sidecar.book_uuid,
            format = sidecar.format,
        })
        self:message(STALE, silent)
        return false, VERIFY_STALE
    end
    self.book_meta = result.data
    return true, VERIFY_OK
end

function Sync:handleVerifyFailure(kind, manual)
    if kind == VERIFY_TIMEOUT then
        if manual then
            show("Failed to connect to Storyteller server.")
        else
            self:showTimeoutPrompt()
        end
    elseif kind == VERIFY_TRANSIENT then
        if manual then
            show("Failed to verify Storyteller book.")
        end
    elseif kind == VERIFY_AUTH then
        -- verifyAsset already displayed the auth message when not silent.
    elseif kind == VERIFY_STALE then
        if not manual then
            self:stopAutoKeepPending()
        end
    end
end

function Sync:stopAutoKeepPending()
    local pending = self.pending_progress_payload
    self:stopAuto(false)
    self.pending_progress_payload = pending
end

function Sync:manualSidecar()
    local sidecar, filepath = self:validateSidecar(false)
    if not sidecar then
        return nil
    end
    return sidecar, filepath
end

function Sync:manualPush()
    local sidecar, filepath = self:manualSidecar()
    if not sidecar then
        return
    end
    local msg = InfoMessage:new{ text = "Pushing reading position..." }
    UIManager:show(msg)
    UIManager:forceRePaint()
    NetworkMgr:runWhenOnline(function()
        local verified, verify_kind = self:verifyAsset(sidecar, false)
        if not verified then
            UIManager:close(msg)
            self:handleVerifyFailure(verify_kind, true)
            return
        end
        if self:documentFile() ~= filepath then
            UIManager:close(msg)
            show("Failed to push reading position.")
            return
        end
        local payload = Locator:build(self.plugin.ui, sidecar)
        self:logPositionPayload("position_push_payload", payload, { source = "manual_push" })
        local result = self.plugin.api:savePosition(sidecar.book_uuid, payload.locator, payload.timestamp)
        UIManager:close(msg)
        if result.ok then
            Sidecar:updateSyncFields(filepath, payload.timestamp, "local_push", payload.locator)
            show("Reading position pushed.")
        elseif result.kind == "handled_error" and result.status == 409 then
            self:fetchConflictRemote(sidecar, filepath, payload, "push")
        elseif result.kind == "not_authenticated" then
            show(AUTH_FAILED)
        else
            self.plugin.log:warn("manual_push_failed", result)
            show("Failed to push reading position.")
        end
    end)
end

function Sync:manualFetch()
    local sidecar, filepath = self:manualSidecar()
    if not sidecar then
        return
    end
    local msg = InfoMessage:new{ text = "Fetching reading position..." }
    UIManager:show(msg)
    UIManager:forceRePaint()
    NetworkMgr:runWhenOnline(function()
        local verified, verify_kind = self:verifyAsset(sidecar, false)
        if not verified then
            UIManager:close(msg)
            self:handleVerifyFailure(verify_kind, true)
            return
        end
        local result = self.plugin.api:getPosition(sidecar.book_uuid)
        UIManager:close(msg)
        self.plugin.log:info("manual_fetch_position_result", {
            ok = result.ok,
            kind = result.kind,
            status = result.status,
            timestamp = result.data and result.data.timestamp or nil,
            locator = Models.locatorForLog(result.data and result.data.locator or nil),
            locator_summary = result.data and Models.locatorSummary(result.data.locator) or nil,
        })
        if result.ok and type(result.data) == "table" and result.data.locator then
            if self:documentFile() ~= filepath then
                show("Failed to fetch reading position.")
                return
            end
            local applied, precise = self:applyRemote(result.data, filepath)
            if applied then
                if precise then
                    show("Remote position applied.")
                else
                    show("Remote position fetched, but could not be restored precisely.")
                end
            else
                show("Failed to fetch reading position.")
            end
        elseif result.kind == "not_authenticated" then
            show(AUTH_FAILED)
        else
            self.plugin.log:warn("manual_fetch_failed", result)
            show("Failed to fetch reading position.")
        end
    end)
end

function Sync:fetchConflictRemote(sidecar, filepath, local_payload, kind)
    local remote = self.plugin.api:getPosition(sidecar.book_uuid)
    if remote.ok and type(remote.data) == "table" and remote.data.locator then
        self:showConflict(remote.data, filepath, local_payload, kind)
    else
        show("Failed to push reading position.")
    end
end

function Sync:conflictTitle(remote, local_payload, kind)
    local current = {
        locator = local_payload and local_payload.locator,
        timestamp = self.sidecar and self.sidecar.last_sync_timestamp,
    }
    local heading = kind == "remote_newer"
        and "A newer reading position is available."
        or "The server has a newer reading position."
    return string.format("%s\n\nCurrent on device:\n%s\nLast synced: %s\n\nUpdated on server:\n%s\nUpdated: %s",
        heading,
        Models.positionPercent(current),
        Models.formatTimestamp(current.timestamp),
        Models.positionPercent(remote),
        Models.formatTimestamp(remote.timestamp))
end

function Sync:showConflict(remote, filepath, local_payload, kind)
    self.remote_conflict_pending = true
    local dialog
    dialog = ButtonDialog:new{
        title = self:conflictTitle(remote, local_payload, kind),
        buttons = {
            {{
                text = _("Do nothing"),
                callback = function()
                    self.remote_conflict_pending = false
                    UIManager:close(dialog)
                end,
            }},
            {{
                text = _("Use server"),
                callback = function()
                    self.remote_conflict_pending = false
                    UIManager:close(dialog)
                    self:applyRemote(remote, filepath)
                end,
            }},
            {{
                text = _("Keep local and sync"),
                callback = function()
                    self.remote_conflict_pending = false
                    UIManager:close(dialog)
                    self:pushFreshLocal(filepath)
                end,
            }},
        },
        dismissable = false,
    }
    UIManager:show(dialog)
end

function Sync:pushFreshLocal(filepath)
    local ok, sidecar = Sidecar:validate(filepath or self:documentFile(), self.plugin.config)
    if not ok then
        show(INELIGIBLE)
        return false
    end
    local payload = Locator:build(self.plugin.ui, sidecar, Models.nowMs())
    self:logPositionPayload("position_push_payload", payload, { source = "conflict_keep_local" })
    local result = self.plugin.api:savePosition(sidecar.book_uuid, payload.locator, payload.timestamp)
    if result.ok then
        Sidecar:updateSyncFields(filepath or self:documentFile(), payload.timestamp, "local_push", payload.locator)
        self.pending_progress_payload = nil
        self.sidecar = sidecar
        self.sidecar.last_sync_timestamp = payload.timestamp
        show("Reading position pushed.")
        return true
    end
    self.pending_progress_payload = payload
    show("Failed to push reading position.")
    return false
end

function Sync:applyRemote(remote, filepath)
    self:unschedulePush()
    self.pending_progress_payload = nil
    self.suppress_progress_capture = true
    if self.remote_apply_release_task then
        UIManager:unschedule(self.remote_apply_release_task)
    end
    self.remote_apply_release_task = function()
        self.suppress_progress_capture = false
        self.remote_apply_release_task = nil
    end
    UIManager:scheduleIn(1, self.remote_apply_release_task)

    self.plugin.log:info("apply_remote_begin", {
        timestamp = remote and remote.timestamp or nil,
        locator = Models.locatorForLog(remote and remote.locator or nil),
        locator_summary = Models.locatorSummary(remote and remote.locator or nil),
        document_has_pages = self.plugin.ui and self.plugin.ui.document
            and self.plugin.ui.document.info and self.plugin.ui.document.info.has_pages or nil,
    })
    local applied, precise, diagnostic = Locator:apply(self.plugin.ui, remote)
    self.plugin.log:info("apply_remote_result", {
        applied = applied,
        precise = precise,
        method = diagnostic and diagnostic.method or nil,
        reason = diagnostic and diagnostic.reason or nil,
        target = diagnostic and diagnostic.target or nil,
        attempts = diagnostic and diagnostic.attempts or nil,
        locator_summary = Models.locatorSummary(remote and remote.locator or nil),
    })
    if applied then
        Sidecar:updateSyncFields(filepath or self:documentFile(), remote.timestamp, "remote_apply", remote.locator)
        if self.sidecar then
            self.sidecar.last_sync_timestamp = remote.timestamp
        end
    end
    return applied, precise
end

function Sync:startAuto()
    self:stopAuto(false)
    if not self.plugin.config:isLoggedIn() or self.plugin.config:get("sync_enabled") ~= true then
        return
    end
    local sidecar, filepath = self:validateSidecar(true)
    if not sidecar then
        return
    end
    self.active = true
    self.filepath = filepath
    self.sidecar = sidecar
    self.autosync_paused_until_reset = false
    self.last_page = nil
    self.generation = self.generation + 1
    local generation = self.generation
    UIManager:nextTick(function()
        if not self.active or self.generation ~= generation or self.filepath ~= filepath then
            return
        end
        if not NetworkMgr:isOnline() then
            self.plugin.log:info("autosync_start_offline")
            return
        end
        local verified, verify_kind = self:verifyAsset(sidecar, false)
        if not verified then
            self:handleVerifyFailure(verify_kind, false)
            return
        end
        self:fetchRemoteIfNewer()
    end)
end

function Sync:stopAuto(flush)
    if flush and self.pending_progress_payload then
        self:pushProgressIfPossible("close_document")
    end
    self.active = false
    self.filepath = nil
    self.sidecar = nil
    self.book_meta = nil
    self.pending_progress_payload = nil
    self.remote_conflict_pending = false
    self.suppress_progress_capture = false
    self.autosync_paused_until_reset = false
    self.generation = self.generation + 1
    self:unschedulePush()
    if self.remote_apply_release_task then
        UIManager:unschedule(self.remote_apply_release_task)
        self.remote_apply_release_task = nil
    end
    if self.autosync_error_dialog then
        UIManager:close(self.autosync_error_dialog)
        self.autosync_error_dialog = nil
    end
end

function Sync:onPageUpdate(page)
    if not self.active or self.suppress_progress_capture then
        return
    end
    if page == nil or page == self.last_page then
        return
    end
    self.last_page = page
    self.pending_progress_payload = Locator:build(self.plugin.ui, self.sidecar, Models.nowMs())
    self:schedulePush()
end

function Sync:schedulePush()
    if self.autosync_paused_until_reset or self.autosync_error_dialog then
        return
    end
    self:unschedulePush()
    self.progress_push_task = function()
        self.progress_push_task = nil
        self:pushProgressIfPossible("debounce")
    end
    UIManager:scheduleIn(5, self.progress_push_task)
end

function Sync:unschedulePush()
    if self.progress_push_task then
        UIManager:unschedule(self.progress_push_task)
        self.progress_push_task = nil
    end
end

function Sync:onCloseDocument()
    local had_pending = self.pending_progress_payload ~= nil
    self:unschedulePush()
    if had_pending then
        self:pushProgressIfPossible("close_document")
    end
    self:stopAuto(false)
end

function Sync:onSuspend()
    if self.progress_push_task then
        self:unschedulePush()
        self:pushProgressIfPossible("suspend")
    end
end

function Sync:onResume()
    if self.active then
        self.autosync_paused_until_reset = false
        self:fetchRemoteIfNewer()
    else
        self:startAuto()
    end
end

function Sync:fetchRemoteIfNewer()
    if not self.active or not self.sidecar then
        return
    end
    if not NetworkMgr:isOnline() then
        return
    end
    local result = self.plugin.api:getPosition(self.sidecar.book_uuid)
    if result.ok and type(result.data) == "table" and result.data.locator then
        local remote_ts = tonumber(result.data.timestamp) or 0
        local last_ts = tonumber(self.sidecar.last_sync_timestamp) or 0
        if remote_ts > last_ts then
            local local_payload = Locator:build(self.plugin.ui, self.sidecar)
            self.pending_progress_payload = local_payload
            self:showConflict(result.data, self.filepath, local_payload, "remote_newer")
        end
    elseif result.kind == "timeout" then
        self:showTimeoutPrompt()
    elseif result.kind == "not_authenticated" then
        show(AUTH_FAILED)
    elseif result.kind == "handled_error" and result.status == 404 then
        return
    else
        self.plugin.log:warn("autosync_fetch_remote_failed", result)
    end
end

function Sync:pushProgressIfPossible(reason)
    if not self.active or not self.sidecar then
        return false
    end
    local ok, sidecar = Sidecar:validate(self.filepath, self.plugin.config)
    if not ok then
        self.plugin.log:info("autosync_sidecar_invalid", { reason = reason })
        return false
    end
    self.sidecar = sidecar
    if self.remote_conflict_pending or self.autosync_paused_until_reset then
        return false
    end
    if not NetworkMgr:isOnline() then
        self.plugin.log:info("autosync_offline", { reason = reason })
        return false
    end
    local verified, verify_kind = self:verifyAsset(sidecar, false)
    if not verified then
        self:handleVerifyFailure(verify_kind, false)
        return false
    end

    local remote = self.plugin.api:getPosition(sidecar.book_uuid)
    if remote.ok and type(remote.data) == "table" and remote.data.locator then
        local remote_ts = tonumber(remote.data.timestamp) or 0
        local last_ts = tonumber(sidecar.last_sync_timestamp) or 0
        if remote_ts > last_ts then
            self:showConflict(remote.data, self.filepath, self.pending_progress_payload, "remote_newer")
            return false
        end
    elseif remote.kind == "timeout" then
        self:showTimeoutPrompt()
        return false
    elseif remote.kind == "not_authenticated" then
        show(AUTH_FAILED)
        return false
    elseif remote.kind ~= "handled_error" or remote.status ~= 404 then
        self.plugin.log:warn("autosync_remote_fetch_failed", remote)
    end

    local payload = self.pending_progress_payload or Locator:build(self.plugin.ui, sidecar)
    self.pending_progress_payload = payload
    self:logPositionPayload("position_push_payload", payload, { source = "auto_push", reason = reason })
    local result = self.plugin.api:savePosition(sidecar.book_uuid, payload.locator, payload.timestamp)
    if result.ok then
        self.pending_progress_payload = nil
        Sidecar:updateSyncFields(self.filepath, payload.timestamp, "local_push", payload.locator)
        self.sidecar.last_sync_timestamp = payload.timestamp
        return true
    elseif result.kind == "handled_error" and result.status == 409 then
        local conflict_remote = self.plugin.api:getPosition(sidecar.book_uuid)
        if conflict_remote.ok and type(conflict_remote.data) == "table" then
            self:showConflict(conflict_remote.data, self.filepath, payload, "push")
        else
            self.plugin.log:warn("autosync_conflict_fetch_failed", conflict_remote)
        end
    elseif result.kind == "timeout" then
        self:showTimeoutPrompt()
    elseif result.kind == "not_authenticated" then
        show(AUTH_FAILED)
    else
        self.plugin.log:warn("autosync_push_failed", result)
    end
    return false
end

function Sync:showTimeoutPrompt()
    if self.autosync_error_dialog then
        return
    end
    local dialog
    dialog = ButtonDialog:new{
        title = "Could not connect to the Storyteller server.\n\nWhat would you like to do with auto-sync?",
        buttons = {
            {{
                text = _("Try Again"),
                callback = function()
                    UIManager:close(dialog)
                    self.autosync_error_dialog = nil
                    UIManager:nextTick(function()
                        self:pushProgressIfPossible("timeout_retry")
                    end)
                end,
            }},
            {{
                text = _("Ignore This Time"),
                callback = function()
                    UIManager:close(dialog)
                    self.autosync_error_dialog = nil
                end,
            }},
            {{
                text = _("Pause Until Wake/Open"),
                callback = function()
                    self.autosync_paused_until_reset = true
                    UIManager:close(dialog)
                    self.autosync_error_dialog = nil
                end,
            }},
        },
        dismissable = false,
    }
    self.autosync_error_dialog = dialog
    UIManager:show(dialog)
end

return Sync
