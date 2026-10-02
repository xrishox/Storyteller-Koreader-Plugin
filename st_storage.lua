-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Checked, atomic writes for this plugin only. The on-disk format stays LuaSettings-compatible.
local dump = require("dump")
local ffiutil = require("ffi/util")
local Storage = {}

function Storage:read(path)
    local ok, data = pcall(dofile, path)
    if ok and type(data) == "table" then return data end
    return nil
end

function Storage:write(path, data)
    local ok, serialized = pcall(dump, data, nil, true)
    if not ok then return false, "serialize_failed" end
    local temporary = path .. ".storyteller-writing"
    local file = io.open(temporary, "wb")
    if not file then return false, "open_failed" end
    local function fail(reason)
        pcall(file.close, file)
        os.remove(temporary)
        return false, reason
    end
    if not file:write("return ", serialized, "\n") then return fail("write_failed") end
    if not file:flush() then return fail("flush_failed") end
    if not ffiutil.fsyncOpenedFile(file) then return fail("sync_failed") end
    if not file:close() then return fail("close_failed") end
    if not os.rename(temporary, path) then return fail("rename_failed") end
    if not ffiutil.fsyncDirectory(path) then return false, "directory_sync_failed" end
    return true
end

return Storage
