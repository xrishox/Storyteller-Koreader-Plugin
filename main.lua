-- SPDX-License-Identifier: AGPL-3.0-or-later

local ConfirmBox = require("ui/widget/confirmbox")
local Dispatcher = require("dispatcher")
local Http = require("st_http")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local ButtonDialog = require("ui/widget/buttondialog")
local _ = require("gettext")

local Api = require("st_api")
local Auth = require("st_auth")
local Browser = require("st_browser")
local Config = require("st_config")
local Downloader = require("st_downloader")
local Log = require("st_log")
local Sync = require("st_sync")
local Models = require("st_models")

local Storyteller = WidgetContainer:extend{
    name = "storyteller",
    is_doc_only = false,
}

local function show(text)
    UIManager:show(InfoMessage:new{ text = text })
end

function Storyteller:init()
    self.config = Config:open()
    self.log = Log
    self.log:setConfig(self.config)
    self.http = Http:new(self.config, self.log)
    self.api = Api:new(self.http)
    self.auth = Auth:new(self)
    self.downloader = Downloader:new(self)
    self.browser = Browser:new(self)
    self.sync = Sync:new(self)
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
end

function Storyteller:onDispatcherRegisterActions()
    Dispatcher:registerAction("storyteller_push_progress", {
        category = "none",
        event = "StorytellerPushProgress",
        title = _("Push Storyteller reading position"),
        reader = true,
    })
    Dispatcher:registerAction("storyteller_fetch_progress", {
        category = "none",
        event = "StorytellerFetchProgress",
        title = _("Fetch Storyteller reading position"),
        reader = true,
    })
end

function Storyteller:isDocumentOpen()
    return self.ui and self.ui.document and self.ui.document.file
end

function Storyteller:addToMainMenu(menu_items)
    menu_items.storyteller = {
        text = _("Storyteller"),
        sorting_hint = "tools",
        sub_item_table = self:getMenuItems(),
        sub_item_table_func = function()
            return self:getMenuItems()
        end,
    }
end

function Storyteller:getMenuItems()
    self.config:repairAuthState()
    if not self.config:isLoggedIn() then
        return {
            {
                text = _("Set server URL"),
                callback = function()
                    self:promptServerUrl()
                end,
            },
            {
                text = _("Link device"),
                callback = function()
                    self.auth:start()
                end,
            },
        }
    end
    return {
        {
            text = _("Browse books"),
            callback = function()
                self.browser:open()
            end,
        },
        {
            text = _("Push reading position"),
            enabled_func = function() return self:isDocumentOpen() end,
            select_enabled_func = function() return self:isDocumentOpen() end,
            callback = function()
                self.sync:manualPush()
            end,
        },
        {
            text = _("Fetch reading position"),
            enabled_func = function() return self:isDocumentOpen() end,
            select_enabled_func = function() return self:isDocumentOpen() end,
            callback = function()
                self.sync:manualFetch()
            end,
        },
        {
            text = _("Auto-sync"),
            checked_func = function()
                return self.config:get("sync_enabled") == true
            end,
            callback = function()
                local enabled = not self.config:get("sync_enabled")
                self.config:set("sync_enabled", enabled)
                if enabled then
                    self.sync:startAuto()
                else
                    self.sync:stopAuto(false)
                end
            end,
        },
        {
            text_func = function()
                return string.format("Preferred download format (%s)",
                    Models.formatLabel(self.config:get("preferred_format", "ebook")))
            end,
            callback = function()
                self:showFormatMenu()
            end,
        },
        {
            text_func = function()
                return string.format("Log verbosity (%s)", self.config:get("log_verbosity", "warn"))
            end,
            callback = function()
                self:showLogVerbosityMenu()
            end,
        },
        {
            text = _("Unlink device"),
            callback = function()
                self:confirmUnlink()
            end,
        },
    }
end

function Storyteller:saveServerUrl(input, after)
    local normalized, err = self.config:normalizeServerUrl(input)
    if not normalized or err then
        show("Invalid Storyteller server URL.")
        if after then after(false) end
        return
    end
    local function save()
        self.config:set("server_url", normalized ~= "" and normalized or nil)
        if after then
            after(true)
        end
    end
    if normalized:match("^http://") then
        UIManager:show(ConfirmBox:new{
            text = "This Storyteller server URL uses HTTP. Traffic and tokens will not be encrypted.",
            ok_text = _("Continue"),
            ok_callback = save,
            cancel_callback = function()
                if after then after(false) end
            end,
        })
    else
        save()
    end
end

function Storyteller:promptServerUrl(after)
    local dialog
    dialog = InputDialog:new{
        title = _("Storyteller server URL"),
        input = self.config:get("server_url") or "",
        input_hint = "http://storyteller.local:8001",
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                        if after then after(false) end
                    end,
                },
                {
                    text = _("Save"),
                    is_enter_default = true,
                    callback = function()
                        local input = dialog:getInputText()
                        UIManager:close(dialog)
                        self:saveServerUrl(input, after)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
end

function Storyteller:showFormatMenu()
    local dialog
    dialog = ButtonDialog:new{
        title = _("Preferred download format"),
        buttons = {
            {{
                text = _("Read Aloud"),
                callback = function()
                    self.config:set("preferred_format", "readaloud")
                    UIManager:close(dialog)
                end,
            }},
            {{
                text = _("Standard EPUB"),
                callback = function()
                    self.config:set("preferred_format", "ebook")
                    UIManager:close(dialog)
                end,
            }},
        },
    }
    UIManager:show(dialog)
end

function Storyteller:showLogVerbosityMenu()
    local dialog
    dialog = ButtonDialog:new{
        title = _("Log verbosity"),
        buttons = {
            {{
                text = _("Error"),
                callback = function()
                    self.config:set("log_verbosity", "error")
                    UIManager:close(dialog)
                end,
            }},
            {{
                text = _("Warn"),
                callback = function()
                    self.config:set("log_verbosity", "warn")
                    UIManager:close(dialog)
                end,
            }},
            {{
                text = _("Info"),
                callback = function()
                    self.config:set("log_verbosity", "info")
                    UIManager:close(dialog)
                end,
            }},
        },
    }
    UIManager:show(dialog)
end

function Storyteller:confirmUnlink()
    UIManager:show(ConfirmBox:new{
        text = _("Unlink this device from Storyteller?"),
        ok_text = _("Unlink"),
        ok_callback = function()
            self.auth:clear()
            self.auth:closeDialog()
            self.sync:stopAuto(false)
            self.config:clearAuth()
            show("Device unlinked.")
        end,
    })
end

function Storyteller:onReaderReady()
    self.sync:startAuto()
end

function Storyteller:onCloseDocument()
    self.sync:onCloseDocument()
end

function Storyteller:onSuspend()
    self.sync:onSuspend()
end

function Storyteller:onResume()
    self.sync:onResume()
end

function Storyteller:onNetworkConnected()
    self.sync:onNetworkConnected()
end

function Storyteller:onPageUpdate(page)
    self.sync:onPageUpdate(page)
end

function Storyteller:onStorytellerPushProgress()
    self.sync:manualPush()
end

function Storyteller:onStorytellerFetchProgress()
    self.sync:manualFetch()
end

function Storyteller:onCloseWidget()
    if self.auth then
        self.auth:clear()
        self.auth:closeDialog()
    end
    if self.sync then
        self.sync:stopAuto(false)
    end
end

return Storyteller
