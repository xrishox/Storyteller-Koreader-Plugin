-- SPDX-License-Identifier: AGPL-3.0-or-later

local ButtonDialog = require("ui/widget/buttondialog")
local InfoMessage = require("ui/widget/infomessage")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local _ = require("gettext")

local Auth = {}

function Auth:new(plugin)
    local obj = {
        plugin = plugin,
        task = nil,
        dialog = nil,
        device_code = nil,
        interval = 5,
        expires_at = nil,
    }
    setmetatable(obj, { __index = self })
    return obj
end

function Auth:clear()
    if self.task then
        UIManager:unschedule(self.task)
    end
    self.task = nil
    self.device_code = nil
    self.interval = 5
    self.expires_at = nil
end

function Auth:closeDialog()
    if self.dialog then
        UIManager:close(self.dialog)
        self.dialog = nil
    end
end

function Auth:showMessage(text)
    UIManager:show(InfoMessage:new{ text = text })
end

function Auth:showWaitingDialog(data)
    self:closeDialog()
    local dialog
    dialog = ButtonDialog:new{
        title = string.format("Visit:\n%s\n\nEnter code:\n%s\n\nWaiting for authorization...",
            data.verification_uri or "", data.user_code or ""),
        buttons = {
            {{
                text = _("Cancel"),
                callback = function()
                    self:clear()
                    UIManager:close(dialog)
                    self.dialog = nil
                end,
            }},
        },
        dismissable = false,
    }
    self.dialog = dialog
    UIManager:show(dialog)
end

function Auth:start()
    local config = self.plugin.config
    if not config:get("server_url") then
        self.plugin:promptServerUrl(function(ok)
            if ok then
                self:start()
            end
        end)
        return
    end
    local server_url = config:get("server_url")
    NetworkMgr:runWhenConnected(function()
        if self.plugin.config:get("server_url") ~= server_url then
            return
        end
        local result = self.plugin.api:deviceStart()
        if not result.ok or type(result.data) ~= "table"
                or type(result.data.device_code) ~= "string"
                or result.data.device_code == "" then
            self.plugin.log:warn("device_start_failed", result)
            self:showMessage("Failed to start Storyteller device linking.")
            return
        end
        self.device_code = result.data.device_code
        self.interval = tonumber(result.data.interval) or 5
        self.expires_at = os.time() + (tonumber(result.data.expires_in) or 600)
        self:showWaitingDialog(result.data)
        self:schedulePoll(0)
    end)
end

function Auth:schedulePoll(delay)
    if self.task then
        UIManager:unschedule(self.task)
    end
    self.task = function()
        self.task = nil
        self:poll()
    end
    UIManager:scheduleIn(delay or self.interval, self.task)
end

function Auth:poll()
    if not self.device_code then
        return
    end
    if self.expires_at and os.time() >= self.expires_at then
        self:clear()
        self:closeDialog()
        self:showMessage("Device code expired. Please try again.")
        return
    end
    local device_code = self.device_code
    NetworkMgr:runWhenConnected(function()
        if self.device_code ~= device_code then
            return
        end
        local result = self.plugin.api:deviceToken(device_code)
        if result.ok and type(result.data) == "table" and result.data.access_token then
            self:onToken(result.data)
            return
        end
        if result.kind == "handled_error" and type(result.data) == "table" then
            local err = result.data.error
            if err == "authorization_pending" then
                self:schedulePoll(self.interval)
                return
            elseif err == "slow_down" then
                self.interval = self.interval + 5
                self:schedulePoll(self.interval)
                return
            elseif err == "expired_token" then
                self:clear()
                self:closeDialog()
                self:showMessage("Device code expired. Please try again.")
                return
            elseif err == "access_denied" then
                self:clear()
                self:closeDialog()
                self:showMessage("Authorization was denied.")
                return
            end
        end
        if result.kind == "timeout" or result.kind == "network_error" or result.kind == "http_error" then
            self.plugin.log:warn("device_token_retry", result)
            self:schedulePoll(self.interval)
            return
        end
        self.plugin.log:warn("device_token_failed", result)
        self:clear()
        self:closeDialog()
        self:showMessage("Failed to verify Storyteller user.")
    end)
end

function Auth:onToken(token_response)
    local user_result = self.plugin.api:getUser(token_response.access_token)
    if not user_result.ok or type(user_result.data) ~= "table" or not user_result.data.id then
        self.plugin.log:warn("device_user_verify_failed", user_result)
        self:clear()
        self:closeDialog()
        self:showMessage("Failed to verify Storyteller user.")
        return
    end
    self.plugin.config:saveAuth(token_response, user_result.data)
    self:clear()
    self:closeDialog()
    self:showMessage("Device linked successfully!")
end

return Auth
