-- SPDX-License-Identifier: AGPL-3.0-or-later

local Models = require("st_models")

local Conflict = {}

Conflict.PROGRESS_AHEAD_THRESHOLD = 0.01
Conflict.LARGE_FORWARD_JUMP_THRESHOLD = 0.10

local function locatorTotalProgression(locator)
    local locations = type(locator) == "table" and locator.locations
    local progression = type(locations) == "table" and tonumber(locations.totalProgression)
    if not progression then
        return nil
    end
    return Models.clamp(progression, 0, 1)
end

function Conflict.positionTotalProgression(position)
    return type(position) == "table" and locatorTotalProgression(position.locator) or nil
end

function Conflict.compareProgress(local_payload, remote)
    local local_progress = Conflict.positionTotalProgression(local_payload)
    local remote_progress = Conflict.positionTotalProgression(remote)
    if not local_progress or not remote_progress then
        return "unknown", nil, local_progress, remote_progress
    end
    local delta = remote_progress - local_progress
    if delta > Conflict.PROGRESS_AHEAD_THRESHOLD then
        return "remote_ahead", delta, local_progress, remote_progress
    elseif delta < -Conflict.PROGRESS_AHEAD_THRESHOLD then
        return "local_ahead", delta, local_progress, remote_progress
    end
    return "same", delta, local_progress, remote_progress
end

function Conflict.remoteDecision(sidecar, local_payload, remote, source)
    local progress_state, progress_delta, local_progress, remote_progress =
        Conflict.compareProgress(local_payload, remote)
    local remote_ts = Models.positionTimestamp(remote)
    local last_ts = tonumber(sidecar and sidecar.last_sync_timestamp) or 0
    local decision = "local_current"
    local reason = progress_state == "same" and "same_progress" or "unknown_progress"

    if progress_state == "remote_ahead" then
        decision = "remote_ahead"
        reason = "progress"
    elseif progress_state == "local_ahead" then
        decision = "local_ahead"
        reason = "progress"
    elseif remote_ts > last_ts then
        decision = "remote_newer"
        reason = "timestamp"
    end

    return decision, {
        decision = decision,
        reason = reason,
        source = source,
        progress_state = progress_state,
        progress_delta = progress_delta,
        local_progress = local_progress,
        remote_progress = remote_progress,
        remote_timestamp = remote_ts,
        last_sync_timestamp = last_ts,
        local_locator_summary = Models.locatorSummary(local_payload and local_payload.locator or nil),
        remote_locator_summary = Models.locatorSummary(remote and remote.locator or nil),
    }
end

function Conflict.isSuspiciousForwardJump(source, local_payload, remote)
    if source == nil or source == "reading" or source == "readaloud_chapter_turn" then
        return false, nil
    end
    local local_progress = Conflict.positionTotalProgression(local_payload)
    local remote_progress = Conflict.positionTotalProgression(remote)
    if not local_progress or not remote_progress then
        return false, nil
    end
    local delta = local_progress - remote_progress
    if delta > Conflict.LARGE_FORWARD_JUMP_THRESHOLD then
        return true, {
            source = source,
            progress_delta = delta,
            local_progress = local_progress,
            remote_progress = remote_progress,
        }
    end
    return false, nil
end

return Conflict
