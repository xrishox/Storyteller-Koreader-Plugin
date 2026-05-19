-- SPDX-License-Identifier: AGPL-3.0-or-later

local UIManager = require("ui/uimanager")

local Models = require("st_models")

local State = {}

local SYNC_SAFETY_IGNORE_SECONDS = 2 * 60
local SYNC_SAFETY_IGNORE_MS = SYNC_SAFETY_IGNORE_SECONDS * 1000

function State:new()
    local obj = {
        active = false,
        filepath = nil,
        sidecar = nil,
        generation = 0,
        pending_payload = nil,
        pending_dirty = false,
        pending_changed_at = nil,
        pending_source = nil,
        pending_page_turns = 0,
        push_task = nil,
        remote_check_task = nil,
        ignore_release_task = nil,
        remote_apply_release_task = nil,
        remote_conflict_pending = false,
        autosync_error_dialog = nil,
        autosync_paused_until_reset = false,
        sync_safety_ignore_until = 0,
        sync_safety_paused_until_manual = false,
        suppress_capture = false,
        suppress_capture_logged = false,
        suppress_capture_until = 0,
    }
    setmetatable(obj, { __index = self })
    return obj
end

function State:isCurrent(generation, filepath)
    return self.active and self.generation == generation and self.filepath == filepath
end

function State:activate(filepath, sidecar)
    self.active = true
    self.filepath = filepath
    self.sidecar = sidecar
    self.autosync_paused_until_reset = false
    self.remote_conflict_pending = false
    self:clearPending()
    self:clearIgnore()
    self.generation = self.generation + 1
end

function State:deactivate()
    self.active = false
    self.filepath = nil
    self.sidecar = nil
    self.autosync_paused_until_reset = false
    self.remote_conflict_pending = false
    self:clearPending()
    self:clearIgnore()
    self:clearCaptureSuppression()
    self.generation = self.generation + 1
    self:unschedulePush()
    self:unscheduleRemoteCheck()
end

function State:hasPending()
    return self.pending_payload ~= nil or self.pending_dirty == true
end

function State:clearPending()
    self.pending_payload = nil
    self.pending_dirty = false
    self.pending_changed_at = nil
    self.pending_source = nil
    self.pending_page_turns = 0
end

function State:markPending(source)
    self:unscheduleRemoteCheck()
    self.pending_payload = nil
    self.pending_dirty = true
    self.pending_changed_at = Models.nowMs()
    self.pending_source = source or "reading"
    self.pending_page_turns = (self.pending_page_turns or 0) + 1
end

function State:pendingPayload(builder)
    if self.pending_payload then
        return self.pending_payload
    end
    self.pending_payload = builder(self.pending_changed_at or Models.nowMs())
    return self.pending_payload
end

function State:capturePending()
    return {
        payload = self.pending_payload,
        dirty = self.pending_dirty,
        changed_at = self.pending_changed_at,
        source = self.pending_source,
        page_turns = self.pending_page_turns,
    }
end

function State:restorePending(snapshot)
    snapshot = snapshot or {}
    self.pending_payload = snapshot.payload
    self.pending_dirty = snapshot.dirty == true
    self.pending_changed_at = snapshot.changed_at
    self.pending_source = snapshot.source
    self.pending_page_turns = tonumber(snapshot.page_turns) or 0
end

function State:clearIgnore()
    if self.ignore_release_task then
        UIManager:unschedule(self.ignore_release_task)
        self.ignore_release_task = nil
    end
    self.sync_safety_ignore_until = 0
    self.sync_safety_paused_until_manual = false
end

function State:isIgnored()
    if self.sync_safety_paused_until_manual then
        return true, "manual"
    end
    local ignore_until = tonumber(self.sync_safety_ignore_until) or 0
    if ignore_until > Models.nowMs() then
        return true, "temporary"
    end
    if ignore_until > 0 then
        self:clearIgnore()
    end
    return false, nil
end

function State:pauseIgnore(mode, on_expire)
    self:unschedulePush()
    self:unscheduleRemoteCheck()
    self:clearIgnore()
    if mode == "temporary" then
        self.sync_safety_ignore_until = Models.nowMs() + SYNC_SAFETY_IGNORE_MS
        local generation = self.generation
        local filepath = self.filepath
        self.ignore_release_task = function()
            self.ignore_release_task = nil
            self.sync_safety_ignore_until = 0
            if self:isCurrent(generation, filepath) and type(on_expire) == "function" then
                on_expire()
            end
        end
        UIManager:scheduleIn(SYNC_SAFETY_IGNORE_SECONDS, self.ignore_release_task)
    elseif mode == "manual" then
        self.sync_safety_paused_until_manual = true
    end
end

function State:autoBlocked()
    if not self.active
            or self.remote_conflict_pending
            or self.autosync_paused_until_reset
            or self.autosync_error_dialog then
        return true
    end
    local ignored = self:isIgnored()
    return ignored == true
end

function State:schedulePush(callback, reason)
    if self:autoBlocked() or not self:hasPending() or self.push_task then
        return
    end
    local generation = self.generation
    local filepath = self.filepath
    self.push_task = function()
        self.push_task = nil
        if self:isCurrent(generation, filepath) then
            callback(reason or "page_turn")
        end
    end
    UIManager:nextTick(self.push_task)
end

function State:scheduleRemoteCheck(callback, reason, asset_already_verified)
    if self:autoBlocked() or self:hasPending() then
        return
    end
    self:unscheduleRemoteCheck()
    local generation = self.generation
    local filepath = self.filepath
    self.remote_check_task = function()
        self.remote_check_task = nil
        if self:isCurrent(generation, filepath) and not self:autoBlocked() and not self:hasPending() then
            callback(reason or "remote_check", asset_already_verified)
        end
    end
    UIManager:nextTick(self.remote_check_task)
end

function State:unschedulePush()
    if self.push_task then
        UIManager:unschedule(self.push_task)
        self.push_task = nil
    end
end

function State:unscheduleRemoteCheck()
    if self.remote_check_task then
        UIManager:unschedule(self.remote_check_task)
        self.remote_check_task = nil
    end
end

function State:captureSuppressed()
    return self.suppress_capture or Models.nowMs() < (self.suppress_capture_until or 0)
end

function State:beginCaptureSuppression(seconds, on_release)
    if self.remote_apply_release_task then
        UIManager:unschedule(self.remote_apply_release_task)
        self.remote_apply_release_task = nil
    end
    self.suppress_capture = true
    self.suppress_capture_logged = false
    self.suppress_capture_until = Models.nowMs() + seconds * 1000
    local generation = self.generation
    local filepath = self.filepath
    self.remote_apply_release_task = function()
        self.remote_apply_release_task = nil
        self.suppress_capture = false
        self.suppress_capture_logged = false
        self.suppress_capture_until = 0
        if self:isCurrent(generation, filepath) and type(on_release) == "function" then
            on_release()
        end
    end
    UIManager:scheduleIn(seconds, self.remote_apply_release_task)
end

function State:clearCaptureSuppression()
    if self.remote_apply_release_task then
        UIManager:unschedule(self.remote_apply_release_task)
        self.remote_apply_release_task = nil
    end
    self.suppress_capture = false
    self.suppress_capture_logged = false
    self.suppress_capture_until = 0
end

return State
