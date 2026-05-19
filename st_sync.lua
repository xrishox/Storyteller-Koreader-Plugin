-- SPDX-License-Identifier: AGPL-3.0-or-later

local ButtonDialog = require("ui/widget/buttondialog")
local InfoMessage = require("ui/widget/infomessage")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local _ = require("gettext")

local Conflict = require("st_sync_conflict")
local Locator = require("st_locator")
local Models = require("st_models")
local Movement = require("st_sync_movement")
local Remote = require("st_sync_remote")
local State = require("st_sync_state")

local Sync = {}

local STALE = "This local download is from an older Storyteller file version. Re-download it before syncing."
local AUTH_FAILED = "Storyteller authentication failed. Please relink device."
local REMOTE_APPLY_SETTLE_SECONDS = 15

local function show(text)
    UIManager:show(InfoMessage:new{ text = text })
end

local function hasRemotePosition(position)
    return type(position) == "table"
        and type(position.locator) == "table"
        and Models.positionTimestamp(position) > 0
end

local function networkAvailable()
    return NetworkMgr:isConnected()
end

local function shouldShowAutosyncPrompt(reason)
    return reason ~= "suspend" and reason ~= "close_document"
end

function Sync:new(plugin)
    local obj = {
        plugin = plugin,
        state = State:new(),
        movement = Movement:new(plugin),
        remote = Remote:new(plugin),
        conflict_dialog = nil,
    }
    setmetatable(obj, { __index = self })
    return obj
end

function Sync:message(text, silent)
    if not silent then
        show(text)
    end
end

function Sync:documentFile()
    return self.remote:documentFile()
end

function Sync:validateSidecar(silent)
    return self.remote:validateCurrent(silent)
end

function Sync:handleVerifyFailure(kind, manual)
    if kind == Remote.VERIFY_TIMEOUT then
        if manual then
            show("Failed to connect to Storyteller server.")
        else
            self:showTimeoutPrompt()
        end
    elseif kind == Remote.VERIFY_TRANSIENT then
        if manual then
            show("Failed to verify Storyteller book.")
        end
    elseif kind == Remote.VERIFY_AUTH then
        if manual then
            show(AUTH_FAILED)
        else
            self.state.autosync_paused_until_reset = true
        end
    elseif kind == Remote.VERIFY_STALE then
        show(STALE)
        if not manual then
            self:stopAuto(false)
        end
    end
end

function Sync:manualSidecar()
    local sidecar, filepath = self:validateSidecar(false)
    if not sidecar then
        return nil
    end
    return sidecar, filepath
end

function Sync:localPayloadForComparison(sidecar)
    if self.state:hasPending() then
        return self.state:pendingPayload(function(timestamp)
            return self.remote:buildPayload(sidecar, timestamp)
        end)
    end
    return self.remote:buildPayload(sidecar, Models.nowMs())
end

function Sync:remoteDecision(sidecar, local_payload, remote, source)
    local decision, details = Conflict.remoteDecision(sidecar, local_payload, remote, source)
    self.plugin.log:info("sync_position_decision", details)
    return decision, details
end

function Sync:freshenPayloadTimestamp(payload)
    if type(payload) ~= "table" then
        return
    end
    payload.timestamp = Models.nowMs()
    if self.state.pending_payload == payload then
        self.state.pending_changed_at = payload.timestamp
    end
end

function Sync:checkRemoteBeforeLocalPush(sidecar, payload, reason, manual)
    local remote = self.remote:fetchPosition(sidecar)
    if remote.ok then
        if hasRemotePosition(remote.data) then
            local decision = self:remoteDecision(sidecar, payload, remote.data, reason or "push")
            if decision == "remote_ahead" or decision == "remote_newer" then
                return false, {
                    kind = "remote_conflict",
                    decision = decision,
                    remote = remote.data,
                }
            end
            if decision == "local_ahead" then
                local suspicious, details = Conflict.isSuspiciousForwardJump(
                    self.state.pending_source,
                    payload,
                    remote.data)
                if suspicious and not manual then
                    self.plugin.log:info("sync_safety_large_forward_jump", details)
                    return false, {
                        kind = "remote_conflict",
                        decision = "large_forward_jump",
                        remote = remote.data,
                    }
                end
            end
            self:freshenPayloadTimestamp(payload)
            return true, { kind = decision }
        end
        self:freshenPayloadTimestamp(payload)
        return true, { kind = "no_remote" }
    end
    if remote.kind == "handled_error" and remote.status == 404 then
        self:freshenPayloadTimestamp(payload)
        return true, { kind = "no_remote" }
    end
    if remote.kind == "timeout" then
        return false, { kind = "timeout", result = remote }
    end
    if remote.kind == "not_authenticated" then
        return false, { kind = "not_authenticated", result = remote }
    end
    self.plugin.log:warn("autosync_remote_fetch_failed", remote)
    return false, { kind = "fetch_failed", result = remote }
end

function Sync:handlePushRemoteBlock(block, manual, reason, filepath, payload)
    block = block or {}
    if block.kind == "remote_conflict" then
        if manual or shouldShowAutosyncPrompt(reason) then
            self:showConflict(block.remote, filepath, payload, block.decision)
        else
            self.plugin.log:info("sync_safety_prompt_deferred", {
                reason = reason,
                decision = block.decision,
            })
        end
    elseif block.kind == "timeout" then
        if manual then
            show("Failed to connect to Storyteller server.")
        elseif shouldShowAutosyncPrompt(reason) then
            self:showTimeoutPrompt()
        end
    elseif block.kind == "not_authenticated" then
        self.state.autosync_paused_until_reset = true
        show(AUTH_FAILED)
    elseif manual then
        show("Failed to verify Storyteller reading position.")
    end
end

function Sync:recordLocalPushSuccess(filepath, sidecar, payload)
    self.remote:updateSidecarSyncFields(filepath, payload.timestamp, "local_push", payload.locator)
    self.state:clearPending()
    self.state:clearIgnore()
    self.movement:clearOrigin()
    if self.state.active and self.state.filepath == filepath then
        self.state.sidecar = sidecar
        self.state.sidecar.last_sync_timestamp = payload.timestamp
    end
end

function Sync:manualPush()
    self.state:clearIgnore()
    self.movement:clearOrigin()
    local sidecar, filepath = self:manualSidecar()
    if not sidecar then
        return
    end
    NetworkMgr:runWhenConnected(function()
        local msg = InfoMessage:new{ text = "Pushing reading position..." }
        UIManager:show(msg)
        UIManager:forceRePaint()
        if self:documentFile() ~= filepath then
            UIManager:close(msg)
            show("Failed to push reading position.")
            return
        end
        local valid_sidecar, _, sidecar_reason = self.remote:validateCurrent(true)
        if not valid_sidecar then
            UIManager:close(msg)
            self.plugin.log:info("manual_push_sidecar_invalid", { reason = sidecar_reason })
            show("This book was not downloaded from Storyteller.")
            return
        end
        sidecar = valid_sidecar
        local verified, verify_kind = self.remote:verifyAsset(sidecar)
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
        local payload = self.remote:buildPayload(sidecar)
        if not self.remote:ensureStorytellerLocator(sidecar, payload, "manual_push", true) then
            UIManager:close(msg)
            return
        end
        if not self.remote:ensureReadaloudFragment(sidecar, payload, "manual_push", true) then
            UIManager:close(msg)
            return
        end
        local allowed, block = self:checkRemoteBeforeLocalPush(sidecar, payload, "manual_push", true)
        if not allowed then
            UIManager:close(msg)
            self:handlePushRemoteBlock(block, true, "manual_push", filepath, payload)
            return
        end
        if self:documentFile() ~= filepath then
            UIManager:close(msg)
            show("Failed to push reading position.")
            return
        end
        self.remote:logPositionPayload("position_push_payload", payload, { source = "manual_push" })
        local result = self.remote:savePosition(sidecar, payload)
        UIManager:close(msg)
        if result.ok then
            self.state:unschedulePush()
            self:recordLocalPushSuccess(filepath, sidecar, payload)
            show("Reading position pushed.")
        elseif result.kind == "handled_error" and result.status == 409 then
            self:handleSaveConflict(sidecar, filepath, payload, "manual_push_conflict", true, "manual_push")
        elseif result.kind == "not_authenticated" then
            show(AUTH_FAILED)
        else
            self.plugin.log:warn("manual_push_failed", result)
            show("Failed to push reading position.")
        end
    end)
end

function Sync:manualFetch()
    self.state:clearIgnore()
    self.movement:clearOrigin()
    local sidecar, filepath = self:manualSidecar()
    if not sidecar then
        return
    end
    NetworkMgr:runWhenConnected(function()
        local msg = InfoMessage:new{ text = "Fetching reading position..." }
        UIManager:show(msg)
        UIManager:forceRePaint()
        if self:documentFile() ~= filepath then
            UIManager:close(msg)
            show("Failed to fetch reading position.")
            return
        end
        local valid_sidecar = self.remote:validateCurrent(true)
        if not valid_sidecar then
            UIManager:close(msg)
            show("This book was not downloaded from Storyteller.")
            return
        end
        sidecar = valid_sidecar
        local verified, verify_kind = self.remote:verifyAsset(sidecar)
        if not verified then
            UIManager:close(msg)
            self:handleVerifyFailure(verify_kind, true)
            return
        end
        local result = self.remote:fetchPosition(sidecar)
        UIManager:close(msg)
        self.plugin.log:info("manual_fetch_position_result", {
            ok = result.ok,
            kind = result.kind,
            status = result.status,
            timestamp = result.data and result.data.timestamp or nil,
            locator = Models.locatorForLog(result.data and result.data.locator or nil),
            locator_summary = result.data and Models.locatorSummary(result.data.locator) or nil,
        })
        if result.ok and hasRemotePosition(result.data) then
            if self:documentFile() ~= filepath then
                show("Failed to fetch reading position.")
                return
            end
            local applied, precise = self:applyRemote(result.data, filepath)
            if applied then
                show(precise and "Remote position applied."
                    or "Remote position fetched, but could not be restored precisely.")
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

function Sync:conflictTitle(remote, local_payload, kind)
    local current = {
        locator = local_payload and local_payload.locator,
        timestamp = self.state.sidecar and self.state.sidecar.last_sync_timestamp,
    }
    local heading
    if kind == "remote_ahead" then
        heading = "Storyteller has a farther reading position."
    elseif kind == "remote_newer" then
        heading = "Storyteller has a newer reading position."
    elseif kind == "large_forward_jump" then
        heading = "KOReader is much farther ahead than Storyteller."
    else
        heading = "Storyteller has a different reading position."
    end
    return string.format("%s\n\nKOReader:\n%s\nLast synced: %s\n\nStoryteller:\n%s\nUpdated: %s",
        heading,
        Models.positionPercent(current),
        Models.formatTimestamp(current.timestamp),
        Models.positionPercent(remote),
        Models.formatTimestamp(remote.timestamp))
end

function Sync:closeConflictDialog(dialog)
    if dialog then
        UIManager:close(dialog)
    end
    if not dialog or self.conflict_dialog == dialog then
        self.conflict_dialog = nil
    end
end

function Sync:showConflict(remote, filepath, local_payload, kind)
    if not hasRemotePosition(remote) then
        self.plugin.log:warn("sync_conflict_missing_remote_position", {
            kind = kind,
            remote = type(remote),
        })
        return false
    end
    if filepath and self:documentFile() ~= filepath then
        self.plugin.log:warn("sync_conflict_document_changed", { kind = kind })
        return false
    end
    self:closeConflictDialog(self.conflict_dialog)
    self.state.remote_conflict_pending = true
    local dialog
    dialog = ButtonDialog:new{
        title = self:conflictTitle(remote, local_payload, kind),
        buttons = {
            {{
                text = _("Use server"),
                callback = function()
                    self.state.remote_conflict_pending = false
                    self.state:clearIgnore()
                    self:closeConflictDialog(dialog)
                    if filepath and self:documentFile() ~= filepath then
                        show("Failed to fetch reading position.")
                        return
                    end
                    self:applyRemote(remote, filepath)
                end,
            }},
            {{
                text = _("Sync this position"),
                callback = function()
                    self.state.remote_conflict_pending = false
                    self.state:clearIgnore()
                    self:closeConflictDialog(dialog)
                    if filepath and self:documentFile() ~= filepath then
                        show("Failed to push reading position.")
                        return
                    end
                    self:pushFreshLocal(filepath)
                end,
            }},
            {{
                text = _("Ignore for 2 minutes"),
                callback = function()
                    self.state.remote_conflict_pending = false
                    self.state:pauseIgnore("temporary", function()
                        if self.state:hasPending() then
                            self:schedulePush("sync_safety_ignore_expired")
                        else
                            self:scheduleRemoteCheck("sync_safety_ignore_expired")
                        end
                    end)
                    self.plugin.log:info("sync_safety_paused", {
                        mode = "temporary",
                        kind = kind,
                        ignore_until = self.state.sync_safety_ignore_until,
                    })
                    self:closeConflictDialog(dialog)
                end,
            }},
            {{
                text = _("Ignore until manual sync"),
                callback = function()
                    self.state.remote_conflict_pending = false
                    self.state:pauseIgnore("manual")
                    self.plugin.log:info("sync_safety_paused", {
                        mode = "manual",
                        kind = kind,
                    })
                    self:closeConflictDialog(dialog)
                end,
            }},
        },
        dismissable = false,
    }
    self.conflict_dialog = dialog
    UIManager:show(dialog)
    return true
end

function Sync:pushFreshLocal(filepath)
    local current_file = self:documentFile()
    if filepath and current_file ~= filepath then
        show("Failed to push reading position.")
        return false
    end
    local target_file = filepath or current_file
    if not target_file then
        show("Failed to push reading position.")
        return false
    end
    local sidecar = self.remote:validateCurrent(true)
    if not sidecar then
        show("This book was not downloaded from Storyteller.")
        return false
    end
    local verified, verify_kind = self.remote:verifyAsset(sidecar)
    if not verified then
        self:handleVerifyFailure(verify_kind, true)
        return false
    end
    local payload = self.remote:buildPayload(sidecar, Models.nowMs())
    if not self.remote:ensureStorytellerLocator(sidecar, payload, "conflict_keep_local", true) then
        return false
    end
    if not self.remote:ensureReadaloudFragment(sidecar, payload, "conflict_keep_local", true) then
        return false
    end
    self.remote:logPositionPayload("position_push_payload", payload, { source = "conflict_keep_local" })
    local result = self.remote:savePosition(sidecar, payload)
    if result.ok then
        self.state:unschedulePush()
        self:recordLocalPushSuccess(target_file, sidecar, payload)
        show("Reading position pushed.")
        return true
    end
    self.state:clearPending()
    self.state.pending_payload = payload
    if self.state.active and self.state.filepath == target_file then
        self:schedulePush("conflict_keep_local_retry")
    end
    show("Failed to push reading position.")
    return false
end

function Sync:handleSaveConflict(sidecar, filepath, payload, source, manual, prompt_reason)
    prompt_reason = prompt_reason or source
    local remote = self.remote:fetchPosition(sidecar)
    if not remote.ok or not hasRemotePosition(remote.data) then
        if manual then
            show("Failed to push reading position.")
        else
            self.plugin.log:warn("autosync_conflict_fetch_failed", remote)
        end
        return false
    end

    local decision = self:remoteDecision(sidecar, payload, remote.data, source or "save_conflict")
    if decision == "local_ahead" then
        local suspicious, details = Conflict.isSuspiciousForwardJump(
            self.state.pending_source,
            payload,
            remote.data)
        if suspicious and not manual then
            self.plugin.log:info("sync_safety_large_forward_jump", details)
            if shouldShowAutosyncPrompt(prompt_reason) then
                self:showConflict(remote.data, filepath, payload, "large_forward_jump")
            else
                self.plugin.log:info("sync_safety_prompt_deferred", {
                    reason = prompt_reason,
                    decision = "large_forward_jump",
                })
            end
            return false
        end
        self:freshenPayloadTimestamp(payload)
        self.remote:logPositionPayload("position_push_payload", {
            locator = payload.locator,
            timestamp = payload.timestamp,
        }, {
            source = (source or "save_conflict") .. "_retry",
        })
        local retry = self.remote:savePosition(sidecar, payload)
        if retry.ok then
            self:recordLocalPushSuccess(filepath, sidecar, payload)
            if manual then
                show("Reading position pushed.")
            end
            return true
        end
        self.plugin.log:warn("position_push_conflict_retry_failed", retry)
        if manual then
            show("Failed to push reading position.")
        end
        return false
    end

    local conflict_kind = decision == "remote_ahead" and "remote_ahead" or "remote_newer"
    if manual or shouldShowAutosyncPrompt(prompt_reason) then
        self:showConflict(remote.data, filepath, payload, conflict_kind)
    else
        self.plugin.log:info("sync_safety_prompt_deferred", {
            reason = prompt_reason,
            decision = conflict_kind,
        })
    end
    return false
end

function Sync:applyRemote(remote, filepath)
    if filepath and self:documentFile() ~= filepath then
        return false, false, { reason = "document_changed" }
    end
    if not hasRemotePosition(remote) then
        return false, false, { reason = "missing_remote_position" }
    end
    local pending_before_apply = self.state:capturePending()
    local movement_before_apply = self.movement:capture()
    self.state:unschedulePush()
    self.state:beginCaptureSuppression(REMOTE_APPLY_SETTLE_SECONDS, function()
        self.state:clearPending()
        self.movement:resetReading()
        self.plugin.log:info("apply_remote_capture_resumed", {
            last_page = self.movement.last_page,
            last_doc_fragment = self.movement.last_doc_fragment,
        })
    end)

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
        self.state:clearPending()
        self.state:clearIgnore()
        self.movement:clearOrigin()
        self.remote:updateSidecarSyncFields(filepath or self:documentFile(), remote.timestamp, "remote_apply", remote.locator)
        if self.state.sidecar then
            self.state.sidecar.last_sync_timestamp = remote.timestamp
        end
    else
        self.state:clearCaptureSuppression()
        self.state:restorePending(pending_before_apply)
        self.movement:restore(movement_before_apply)
        if self.state.active and self.state:hasPending() then
            self:schedulePush("remote_apply_failed_pending")
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
    self.state:activate(filepath, sidecar)
    self.movement:resetReading()
    self:scheduleRemoteCheck("start")
end

function Sync:stopAuto(flush)
    if flush and self.state:hasPending() then
        self:pushProgressIfPossible("close_document")
    end
    self.state:deactivate()
    self.movement:resetReading(nil)
    if self.state.autosync_error_dialog then
        UIManager:close(self.state.autosync_error_dialog)
        self.state.autosync_error_dialog = nil
    end
    self:closeConflictDialog(self.conflict_dialog)
end

function Sync:onPageUpdate(page)
    if not self.state.active then
        return
    end
    if self.state:captureSuppressed() then
        self.state:clearPending()
        if not self.state.suppress_capture_logged then
            self.plugin.log:info("autosync_capture_suppressed", {
                page = page,
                suppress_progress_capture = self.state.suppress_capture,
                remote_apply_block_until = self.state.suppress_capture_until,
            })
            self.state.suppress_capture_logged = true
        end
        return
    end

    local event = self.movement:onPageUpdate(page, self.state.sidecar)
    if event.kind ~= "reading" then
        if event.clear_pending then
            self.state:unschedulePush()
            self.state:clearPending()
        end
        return
    end

    self.state:markPending(event.source)
    if event.readaloud_boundary then
        self:schedulePush("readaloud_chapter_turn")
    else
        self:schedulePush("page_turn")
    end
end

function Sync:onNavigation()
    if not self.state.active then
        return
    end
    self.state:unschedulePush()
    self.state:clearPending()
    self.movement:onNavigation()
end

function Sync:schedulePush(reason)
    self.state:schedulePush(function(push_reason)
        self:pushProgressIfPossible(push_reason)
    end, reason)
end

function Sync:scheduleRemoteCheck(reason, asset_already_verified)
    self.state:scheduleRemoteCheck(function(check_reason, verified)
        if not networkAvailable() then
            self.plugin.log:info("remote_check_offline", { reason = check_reason })
            return
        end
        local _, status = self:fetchRemoteIfNewer(verified, check_reason, true)
        if (status == "fetch_failed" or status == "timeout" or status == "transient")
                and not self.state.remote_conflict_pending
                and not self.state.autosync_error_dialog then
            self.plugin.log:warn("remote_check_failed", {
                reason = check_reason,
                status = status,
            })
        end
    end, reason, asset_already_verified)
end

function Sync:onCloseDocument()
    local had_pending = self.state:hasPending()
    self.state:unscheduleRemoteCheck()
    self.state:unschedulePush()
    if had_pending then
        if networkAvailable() then
            self:pushProgressIfPossible("close_document")
        else
            local pushed = NetworkMgr:goOnlineToRun(function()
                self:pushProgressIfPossible("close_document")
            end)
            if not pushed then
                self.plugin.log:warn("autosync_close_flush_skipped", { reason = "network_unavailable" })
            end
        end
    end
    self:stopAuto(false)
end

function Sync:onSuspend()
    self.state:unscheduleRemoteCheck()
    if not self.state:hasPending() then
        return
    end
    self.state:unschedulePush()
    if networkAvailable() then
        self:pushProgressIfPossible("suspend")
    else
        self.plugin.log:info("autosync_suspend_flush_skipped", { reason = "network_unavailable" })
    end
end

function Sync:onResume()
    if self.state.active then
        self.state.autosync_paused_until_reset = false
        if self.state:hasPending() then
            self:schedulePush("resume_pending")
        else
            self:scheduleRemoteCheck("resume")
        end
    else
        self:startAuto()
    end
end

function Sync:onNetworkConnected()
    if not self.state.active
            or self.state.remote_conflict_pending
            or self.state.autosync_paused_until_reset
            or self.state.autosync_error_dialog then
        return
    end
    if self.state:hasPending() then
        self:schedulePush("network_connected")
    else
        self:scheduleRemoteCheck("network_connected")
    end
end

function Sync:fetchRemoteIfNewer(asset_already_verified, reason, quiet)
    if not self.state.active or not self.state.sidecar then
        return false, "inactive"
    end
    if not networkAvailable() then
        return false, "offline"
    end
    local sidecar, _, sidecar_reason = self.remote:validateCurrent(true)
    if not sidecar then
        self.plugin.log:info("autosync_sidecar_invalid", {
            reason = sidecar_reason,
            fetch_reason = reason or "remote_check",
        })
        self.state.autosync_paused_until_reset = true
        return false, "sidecar_invalid"
    end
    self.state.sidecar = sidecar
    if not asset_already_verified then
        local verified, verify_kind = self.remote:verifyAsset(sidecar)
        if not verified then
            if not quiet or (verify_kind ~= Remote.VERIFY_TIMEOUT and verify_kind ~= Remote.VERIFY_TRANSIENT) then
                self:handleVerifyFailure(verify_kind, false)
            end
            return false, verify_kind
        end
    end
    local result = self.remote:fetchPosition(sidecar)
    if result.ok then
        if hasRemotePosition(result.data) then
            local local_payload = self:localPayloadForComparison(sidecar)
            local decision = self:remoteDecision(sidecar, local_payload, result.data, reason or "remote_check")
            if decision == "remote_ahead" or decision == "remote_newer" then
                self:showConflict(result.data, self.state.filepath, local_payload, decision)
                return true, decision
            end
            return false, decision
        end
        return false, "no_remote"
    elseif result.kind == "timeout" then
        if not quiet then
            self:showTimeoutPrompt()
        end
        return false, "timeout"
    elseif result.kind == "not_authenticated" then
        self.state.autosync_paused_until_reset = true
        show(AUTH_FAILED)
        return false, "auth"
    elseif result.kind == "handled_error" and result.status == 404 then
        return false, "no_remote"
    else
        self.plugin.log:warn("autosync_fetch_remote_failed", result)
        return false, "fetch_failed"
    end
end

function Sync:pushProgressIfPossible(reason)
    if not self.state.active or not self.state.sidecar or not self.state:hasPending() then
        return false
    end
    if self.state.remote_conflict_pending or self.state.autosync_paused_until_reset then
        return false
    end
    local ignored, pause_reason = self.state:isIgnored()
    if ignored then
        self.plugin.log:info("sync_safety_push_paused", {
            reason = reason,
            pause_reason = pause_reason,
        })
        return false
    end
    if not networkAvailable() then
        self.plugin.log:info("autosync_offline", { reason = reason })
        return false
    end
    local sidecar, _, sidecar_reason = self.remote:validateCurrent(true)
    if not sidecar then
        self.plugin.log:info("autosync_sidecar_invalid", {
            reason = sidecar_reason,
            push_reason = reason,
        })
        self.state.autosync_paused_until_reset = true
        return false
    end
    self.state.sidecar = sidecar
    local verified, verify_kind = self.remote:verifyAsset(sidecar)
    if not verified then
        if shouldShowAutosyncPrompt(reason) then
            self:handleVerifyFailure(verify_kind, false)
        end
        return false
    end

    local payload = self.state:pendingPayload(function(timestamp)
        return self.remote:buildPayload(sidecar, timestamp)
    end)
    if not self.remote:ensureStorytellerLocator(sidecar, payload, reason or "auto_push", false) then
        self.state:clearPending()
        return false
    end
    if not self.remote:ensureReadaloudFragment(sidecar, payload, reason or "auto_push", false) then
        self.state:clearPending()
        return false
    end
    local allowed, block = self:checkRemoteBeforeLocalPush(sidecar, payload, reason, false)
    if not allowed then
        self:handlePushRemoteBlock(block, false, reason, self.state.filepath, payload)
        return false
    end
    if self:documentFile() ~= self.state.filepath then
        return false
    end

    self.remote:logPositionPayload("position_push_payload", payload, { source = "auto_push", reason = reason })
    local result = self.remote:savePosition(sidecar, payload)
    if result.ok then
        self:recordLocalPushSuccess(self.state.filepath, sidecar, payload)
        return true
    elseif result.kind == "handled_error" and result.status == 409 then
        return self:handleSaveConflict(sidecar, self.state.filepath, payload, "auto_push_conflict", false, reason)
    elseif result.kind == "timeout" then
        if shouldShowAutosyncPrompt(reason) then
            self:showTimeoutPrompt()
        end
    elseif result.kind == "not_authenticated" then
        self.state.autosync_paused_until_reset = true
        show(AUTH_FAILED)
    else
        self.plugin.log:warn("autosync_push_failed", result)
    end
    return false
end

function Sync:showTimeoutPrompt()
    if self.state.autosync_error_dialog then
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
                    self.state.autosync_error_dialog = nil
                    UIManager:nextTick(function()
                        if self.state:hasPending() then
                            self:pushProgressIfPossible("timeout_retry")
                        else
                            self:scheduleRemoteCheck("timeout_retry")
                        end
                    end)
                end,
            }},
            {{
                text = _("Ignore This Time"),
                callback = function()
                    UIManager:close(dialog)
                    self.state.autosync_error_dialog = nil
                end,
            }},
            {{
                text = _("Pause Until Wake/Open"),
                callback = function()
                    self.state.autosync_paused_until_reset = true
                    UIManager:close(dialog)
                    self.state.autosync_error_dialog = nil
                end,
            }},
        },
        dismissable = false,
    }
    self.state.autosync_error_dialog = dialog
    UIManager:show(dialog)
end

return Sync
