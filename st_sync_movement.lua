-- SPDX-License-Identifier: AGPL-3.0-or-later

local Models = require("st_models")

local Movement = {}

Movement.READING = "reading"
Movement.NAVIGATION = "navigation"
Movement.SKIMMING = "skimming"
Movement.READALOUD_CHAPTER_TURN = "readaloud_chapter_turn"

local RAPID_PAGE_TURN_MS = 3000
local SKIM_RAPID_TURN_THRESHOLD = 3
local READING_SETTLE_TURN_THRESHOLD = 2

local function currentDocumentPage(ui)
    if not ui then
        return nil
    end
    local ok, page = pcall(function()
        if ui.getCurrentPage then
            local current = ui:getCurrentPage()
            if current then
                return current
            end
        end
        if ui.document and ui.document.getCurrentPage then
            return ui.document:getCurrentPage()
        end
    end)
    return ok and page or nil
end

local function currentDocumentFragment(ui, page)
    if not ui or not ui.document or not ui.document.getPageXPointer then
        return nil
    end
    page = page or currentDocumentPage(ui)
    if not page then
        return nil
    end
    local ok, xpointer = pcall(function()
        return ui.document:getPageXPointer(page)
    end)
    if not ok or type(xpointer) ~= "string" then
        return nil
    end
    return tonumber(xpointer:match("^/body/DocFragment%[(%d+)%]"))
end

local function isReadaloud(sidecar)
    return type(sidecar) == "table" and sidecar.format == "readaloud"
end

function Movement:new(plugin)
    local obj = {
        plugin = plugin,
        mode = self.READING,
        origin = nil,
        navigation_page_update_pending = false,
        last_page = nil,
        last_doc_fragment = nil,
        last_page_turn_timestamp = nil,
        rapid_adjacent_turns = 0,
        settle_adjacent_turns = 0,
    }
    setmetatable(obj, { __index = self })
    return obj
end

function Movement:capture()
    return {
        mode = self.mode,
        origin = self.origin,
        navigation_page_update_pending = self.navigation_page_update_pending,
        last_page = self.last_page,
        last_doc_fragment = self.last_doc_fragment,
        last_page_turn_timestamp = self.last_page_turn_timestamp,
        rapid_adjacent_turns = self.rapid_adjacent_turns,
        settle_adjacent_turns = self.settle_adjacent_turns,
    }
end

function Movement:restore(snapshot)
    snapshot = snapshot or {}
    self.mode = snapshot.mode or self.READING
    self.origin = snapshot.origin
    self.navigation_page_update_pending = snapshot.navigation_page_update_pending == true
    self.last_page = snapshot.last_page
    self.last_doc_fragment = snapshot.last_doc_fragment
    self.last_page_turn_timestamp = snapshot.last_page_turn_timestamp
    self.rapid_adjacent_turns = tonumber(snapshot.rapid_adjacent_turns) or 0
    self.settle_adjacent_turns = tonumber(snapshot.settle_adjacent_turns) or 0
end

function Movement:setBaseline(page)
    page = page or currentDocumentPage(self.plugin.ui)
    self.last_page = page
    self.last_doc_fragment = currentDocumentFragment(self.plugin.ui, page)
end

function Movement:resetReading(page)
    self.mode = self.READING
    self.origin = nil
    self.navigation_page_update_pending = false
    self.last_page_turn_timestamp = nil
    self.rapid_adjacent_turns = 0
    self.settle_adjacent_turns = 0
    self:setBaseline(page)
end

function Movement:clearOrigin()
    self.origin = nil
end

function Movement:enterNonReading(mode, page)
    self.mode = mode or self.NAVIGATION
    self.origin = self.mode
    self.navigation_page_update_pending = false
    self.last_page_turn_timestamp = nil
    self.rapid_adjacent_turns = 0
    self.settle_adjacent_turns = 0
    self:setBaseline(page)
end

function Movement:onNavigation()
    self.mode = self.NAVIGATION
    self.origin = self.NAVIGATION
    self.navigation_page_update_pending = true
    self.last_page_turn_timestamp = nil
    self.rapid_adjacent_turns = 0
    self.settle_adjacent_turns = 0
end

function Movement:source(default_source)
    return self.origin or default_source or self.READING
end

function Movement:onPageUpdate(page, sidecar)
    page = tonumber(page)
    if not page then
        return { kind = "ignore", reason = "invalid_page", clear_pending = false }
    end
    if not self.last_page then
        self:setBaseline(page)
        return { kind = "ignore", reason = "baseline", clear_pending = false }
    end

    local previous_page = tonumber(self.last_page)
    if not previous_page or page == previous_page then
        return { kind = "ignore", reason = "same_page", clear_pending = false }
    end

    if self.navigation_page_update_pending then
        self:enterNonReading(self.NAVIGATION, page)
        return { kind = "ignore", reason = "navigation_event", clear_pending = true }
    end

    local adjacent = math.abs(page - previous_page) == 1
    if not adjacent then
        self:enterNonReading(self.NAVIGATION, page)
        return { kind = "ignore", reason = "non_adjacent", clear_pending = true }
    end

    local now = Models.nowMs()
    local rapid = self.last_page_turn_timestamp ~= nil
        and now - self.last_page_turn_timestamp <= RAPID_PAGE_TURN_MS
    local previous_fragment = self.last_doc_fragment
    local current_fragment = currentDocumentFragment(self.plugin.ui, page)
    local readaloud_boundary = isReadaloud(sidecar)
        and previous_fragment ~= nil
        and current_fragment ~= nil
        and previous_fragment ~= current_fragment

    self.last_page = page
    self.last_doc_fragment = current_fragment or self.last_doc_fragment
    self.last_page_turn_timestamp = now
    if rapid then
        self.rapid_adjacent_turns = (self.rapid_adjacent_turns or 0) + 1
    else
        self.rapid_adjacent_turns = 1
    end

    if self.mode == self.SKIMMING then
        if rapid then
            self.settle_adjacent_turns = 0
            return { kind = "ignore", reason = "skimming", clear_pending = true }
        end
        self.settle_adjacent_turns = (self.settle_adjacent_turns or 0) + 1
        if self.settle_adjacent_turns < READING_SETTLE_TURN_THRESHOLD then
            return { kind = "ignore", reason = "settling_after_skimming", clear_pending = true }
        end
        self.mode = self.READING
        self.rapid_adjacent_turns = 0
        self.settle_adjacent_turns = 0
    elseif self.mode == self.NAVIGATION then
        if rapid then
            self.settle_adjacent_turns = 0
            if self.rapid_adjacent_turns >= SKIM_RAPID_TURN_THRESHOLD then
                self.mode = self.SKIMMING
                self.origin = self.SKIMMING
            end
            return { kind = "ignore", reason = "navigation_or_skimming", clear_pending = true }
        end
        self.settle_adjacent_turns = (self.settle_adjacent_turns or 0) + 1
        if self.settle_adjacent_turns < READING_SETTLE_TURN_THRESHOLD then
            return { kind = "ignore", reason = "settling_after_navigation", clear_pending = true }
        end
        self.mode = self.READING
        self.rapid_adjacent_turns = 0
        self.settle_adjacent_turns = 0
    elseif rapid and not readaloud_boundary then
        if self.rapid_adjacent_turns >= SKIM_RAPID_TURN_THRESHOLD then
            self:enterNonReading(self.SKIMMING, page)
            return { kind = "ignore", reason = "entered_skimming", clear_pending = true }
        end
        return { kind = "ignore", reason = "rapid_turn", clear_pending = true }
    else
        self.settle_adjacent_turns = 0
    end

    return {
        kind = "reading",
        page = page,
        source = self:source(readaloud_boundary and self.READALOUD_CHAPTER_TURN or self.READING),
        readaloud_boundary = readaloud_boundary,
    }
end

return Movement
