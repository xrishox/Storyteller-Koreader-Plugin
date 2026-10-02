-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Coroutines orchestrate UI work; only isolated HTTP/file work runs in forked children.
local UIManager = require("ui/uimanager")
local ffiutil = require("ffi/util")
local json = require("rapidjson")
local logger = require("logger")
local Async = {}
local tasks = setmetatable({}, { __mode = "k" })
local CANCELLED = {}

local function valid(task)
    return not task.cancelled and (not task.guard or task.guard())
end

local function resume(task, value)
    local ok, err = coroutine.resume(task.co, value)
    if not ok then logger.warn("Storyteller async coroutine failed", tostring(err)) end
end

function Async:isBusy()
    return next(tasks) ~= nil
end

function Async:current()
    return tasks[coroutine.running()]
end

function Async:run(owner, key, guard, fn, finished)
    owner._st_tasks = owner._st_tasks or {}
    if owner._st_tasks[key] then return false end
    local task = { guard = guard }
    owner._st_tasks[key] = task
    task.co = coroutine.create(function()
        UIManager:preventStandby()
        local ok, err = pcall(function()
            if not valid(task) then error(CANCELLED) end
            return fn()
        end)
        tasks[task.co] = nil
        owner._st_tasks[key] = nil
        UIManager:allowStandby()
        for _, cleanup in ipairs(task.cleanups or {}) do pcall(cleanup) end
        if finished then finished(ok, err == CANCELLED) end
        if not ok and err ~= CANCELLED then logger.warn("Storyteller task failed", key, tostring(err)) end
    end)
    tasks[task.co] = task
    resume(task)
    return true
end

function Async:onFinish(fn)
    local task = self:current()
    if task then
        task.cleanups = task.cleanups or {}
        table.insert(task.cleanups, fn)
    end
end

-- Cleanup must not close an already dismissed widget: KOReader sends CloseWidget
-- even if a widget is no longer on its stack.
function Async:trackWidget(widget)
    local closed = false
    local on_close = widget.onCloseWidget
    widget.onCloseWidget = function(w, ...)
        if closed then return end
        closed = true
        if on_close then return on_close(w, ...) end
    end
    local function close()
        if not closed then UIManager:close(widget); closed = true end
    end
    self:onFinish(close)
    return close
end

function Async:cancel(owner, key)
    if not owner._st_tasks then return end
    for name, task in pairs(owner._st_tasks) do
        if not key or key == name then
            task.cancelled = true
            -- Polling owns child cleanup and resumes the coroutine only after exit.
            if task.pid then ffiutil.terminateSubProcess(task.pid) end
        end
    end
end

function Async:await(fn, timeout)
    local task = self:current()
    if not task then return fn() end -- synchronous API remains available to existing clients
    if not valid(task) then error(CANCELLED) end
    local pid, fd = ffiutil.runInSubProcess(function(_, child_fd)
        -- The fork inherits the coroutine table, but must not recursively fork.
        tasks[coroutine.running()] = nil
        local ok, result = pcall(fn)
        if not ok then result = { ok = false, kind = "worker_error" } end
        local encoded_ok, encoded = pcall(json.encode, result)
        ffiutil.writeToFD(child_fd, encoded_ok and encoded or '{"ok":false,"kind":"worker_error"}', true)
    end, true)
    if not pid then return { ok = false, kind = "worker_error" } end
    task.pid = pid
    local started = os.time()
    local timed_out = false
    local poll
    poll = function()
        if not valid(task) or os.time() - started > (timeout or 120) then
            timed_out = valid(task)
            ffiutil.terminateSubProcess(pid)
        end
        local done = ffiutil.isSubProcessDone(pid)
        local available = ffiutil.getNonBlockingReadSize(fd)
        if done or (available and available > 0) then
            -- Child only writes once the work is complete, then immediately closes.
            local raw = ffiutil.readAllFromFD(fd)
            if not done then
                local reap
                reap = function()
                    if not ffiutil.isSubProcessDone(pid) then UIManager:scheduleIn(1, reap) end
                end
                UIManager:scheduleIn(1, reap)
            end
            task.pid = nil
            local decoded, result = pcall(json.decode, raw)
            resume(task, timed_out and {ok=false,kind="timeout"}
                or decoded and result or {ok=false,kind="worker_error"})
            return
        end
        UIManager:scheduleIn(0.1, poll)
    end
    UIManager:scheduleIn(0.1, poll)
    local result = coroutine.yield()
    if not valid(task) then error(CANCELLED) end
    return result
end

return Async
