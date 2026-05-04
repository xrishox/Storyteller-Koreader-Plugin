-- SPDX-License-Identifier: AGPL-3.0-or-later

local InfoMessage = require("ui/widget/infomessage")
local Menu = require("ui/widget/menu")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")

local Models = require("st_models")

local Browser = {}

local function asList(value)
    if type(value) ~= "table" then
        return {}
    end
    return value
end

local function relationContains(relations, uuid)
    if type(relations) ~= "table" then
        return false
    end
    for _, relation in ipairs(relations) do
        if type(relation) == "table" and relation.uuid == uuid then
            return true
        end
    end
    return false
end

local function copyFilteredBooks(books, predicate)
    local result = {}
    for _, book in ipairs(books) do
        if predicate(book) then
            table.insert(result, book)
        end
    end
    return result
end

local function sortByTitle(books)
    table.sort(books, function(a, b)
        return Models.lowerTitle(a) < Models.lowerTitle(b)
    end)
end

function Browser:new(plugin)
    local obj = {
        plugin = plugin,
        menu = nil,
        books = {},
        collections = {},
        series = {},
    }
    setmetatable(obj, { __index = self })
    return obj
end

function Browser:open()
    local menu = Menu:new{
        title = "Storyteller",
        item_table = {
            { text = "Loading...", dim = true, select_enabled = false },
        },
    }
    self.menu = menu
    UIManager:show(menu)
    NetworkMgr:runWhenOnline(function()
        self:load()
    end)
end

function Browser:load()
    local books_result = self.plugin.api:listBooks()
    local collections_result = self.plugin.api:listCollections()
    local series_result = self.plugin.api:listSeries()
    if not books_result.ok then
        self.plugin.log:warn("library_load_failed", {
            books = books_result.kind,
            collections = collections_result.kind,
            series = series_result.kind,
        })
        UIManager:show(InfoMessage:new{ text = "Failed to load Storyteller library data." })
        return
    end
    if not collections_result.ok or not series_result.ok then
        self.plugin.log:warn("library_partial_load_failed", {
            collections = collections_result.kind,
            series = series_result.kind,
        })
    end
    self.books = copyFilteredBooks(asList(books_result.data), function(book)
        return type(book) == "table" and book.uuid and Models.hasDownloadableFormat(book)
    end)
    self.collections = collections_result.ok and asList(collections_result.data) or {}
    self.series = series_result.ok and asList(series_result.data) or {}
    self:showRoot()
end

function Browser:countBooks(predicate)
    local count = 0
    for _, book in ipairs(self.books) do
        if predicate(book) then
            count = count + 1
        end
    end
    return count
end

function Browser:rootItems()
    return {
        {
            text = "Currently Reading",
            mandatory = self:countBooks(function(book)
                return type(book.status) == "table" and book.status.name == "Reading"
            end),
            callback = function() self:showCurrentlyReading() end,
        },
        {
            text = "Recently Added",
            mandatory = #self.books,
            callback = function() self:showRecentlyAdded() end,
        },
        {
            text = "All books",
            mandatory = #self.books,
            callback = function() self:showBookList("All books", self:allBooks()) end,
        },
        {
            text = "Collections",
            mandatory = #self.collections,
            callback = function() self:showCollections() end,
        },
        {
            text = "Series",
            mandatory = #self.series,
            callback = function() self:showSeries() end,
        },
    }
end

function Browser:showRoot()
    if self.menu then
        self.menu:switchItemTable("Storyteller", self:rootItems())
    end
end

function Browser:bookItem(book)
    return {
        text = Models.bookTitle(book),
        mandatory = Models.authorText(book),
        callback = function()
            self.plugin.downloader:selectAndOpen(book)
        end,
    }
end

function Browser:itemsForBooks(books)
    local items = {
        { text = "Back", callback = function() self:showRoot() end },
    }
    if #books == 0 then
        table.insert(items, { text = "No downloadable books found.", dim = true, select_enabled = false })
        return items
    end
    for _, book in ipairs(books) do
        table.insert(items, self:bookItem(book))
    end
    return items
end

function Browser:showBookList(title, books)
    if self.menu then
        self.menu:switchItemTable(title, self:itemsForBooks(books))
    end
end

function Browser:allBooks()
    local books = copyFilteredBooks(self.books, function() return true end)
    sortByTitle(books)
    return books
end

function Browser:showCurrentlyReading()
    local books = copyFilteredBooks(self.books, function(book)
        return type(book.status) == "table" and book.status.name == "Reading"
    end)
    table.sort(books, function(a, b)
        local at = Models.positionTimestamp(a.position)
        local bt = Models.positionTimestamp(b.position)
        if at == bt then
            return Models.lowerTitle(a) < Models.lowerTitle(b)
        end
        return at > bt
    end)
    self:showBookList("Currently Reading", books)
end

function Browser:showRecentlyAdded()
    local books = copyFilteredBooks(self.books, function() return true end)
    table.sort(books, function(a, b)
        local at = Models.parseDate(a.createdAt)
        local bt = Models.parseDate(b.createdAt)
        if at == bt then
            return Models.lowerTitle(a) < Models.lowerTitle(b)
        end
        return at > bt
    end)
    self:showBookList("Recently Added", books)
end

function Browser:showCollections()
    local items = {
        { text = "Back", callback = function() self:showRoot() end },
    }
    local collections = asList(self.collections)
    table.sort(collections, function(a, b)
        return string.lower(a.name or "") < string.lower(b.name or "")
    end)
    if #collections == 0 then
        table.insert(items, { text = "No collections found.", dim = true, select_enabled = false })
    else
        for _, collection in ipairs(collections) do
            local collection_ref = collection
            local count = self:countBooks(function(book)
                return relationContains(book.collections, collection_ref.uuid)
            end)
            table.insert(items, {
                text = collection_ref.name or "Collection",
                mandatory = count,
                callback = function()
                    local books = copyFilteredBooks(self.books, function(book)
                        return relationContains(book.collections, collection_ref.uuid)
                    end)
                    sortByTitle(books)
                    self:showBookList(collection_ref.name or "Collection", books)
                end,
            })
        end
    end
    self.menu:switchItemTable("Collections", items)
end

function Browser:showSeries()
    local items = {
        { text = "Back", callback = function() self:showRoot() end },
    }
    local series = asList(self.series)
    table.sort(series, function(a, b)
        return string.lower(a.name or "") < string.lower(b.name or "")
    end)
    if #series == 0 then
        table.insert(items, { text = "No series found.", dim = true, select_enabled = false })
    else
        for _, series_item in ipairs(series) do
            local series_ref = series_item
            local count = self:countBooks(function(book)
                return relationContains(book.series, series_ref.uuid)
            end)
            table.insert(items, {
                text = series_ref.name or "Series",
                mandatory = count,
                callback = function()
                    self:showSeriesBooks(series_ref)
                end,
            })
        end
    end
    self.menu:switchItemTable("Series", items)
end

function Browser:seriesPosition(book, uuid)
    if type(book.series) ~= "table" then
        return nil
    end
    for _, relation in ipairs(book.series) do
        if type(relation) == "table" and relation.uuid == uuid then
            return tonumber(relation.position)
        end
    end
    return nil
end

function Browser:showSeriesBooks(series_item)
    local books = copyFilteredBooks(self.books, function(book)
        return relationContains(book.series, series_item.uuid)
    end)
    table.sort(books, function(a, b)
        local ap = self:seriesPosition(a, series_item.uuid)
        local bp = self:seriesPosition(b, series_item.uuid)
        if ap and bp and ap ~= bp then
            return ap < bp
        elseif ap and not bp then
            return true
        elseif bp and not ap then
            return false
        end
        return Models.lowerTitle(a) < Models.lowerTitle(b)
    end)
    self:showBookList(series_item.name or "Series", books)
end

return Browser
