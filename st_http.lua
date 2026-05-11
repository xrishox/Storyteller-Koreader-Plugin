-- SPDX-License-Identifier: AGPL-3.0-or-later

local http = require("socket.http")
local https = require("ssl.https")
local ltn12 = require("ltn12")
local rapidjson = require("rapidjson")
local socket = require("socket")
local socketutil = require("socketutil")

local Models = require("st_models")

local Http = {}

local SUCCESS_STATUSES = {
    [200] = true,
    [201] = true,
    [204] = true,
}

local AUTH_ERROR_VALUES = {
    not_authenticated = true,
    unauthorized = true,
    forbidden = true,
}

local function isTimeoutCode(code)
    return code == socketutil.TIMEOUT_CODE
        or code == socketutil.SSL_HANDSHAKE_CODE
        or code == socketutil.SINK_TIMEOUT_CODE
end

local function classifyAuthFailure(status, data)
    if status == 401 or status == 403 then
        return true
    end
    if type(data) == "table" then
        local err = data.error or data.code or data.message
        if type(err) == "string" and AUTH_ERROR_VALUES[string.lower(err)] then
            return true
        end
    end
    return false
end

local function decodeJson(raw_body)
    if not raw_body or raw_body == "" then
        return nil, nil
    end
    local ok, data_or_err = pcall(rapidjson.decode, raw_body)
    if ok and data_or_err ~= nil then
        return data_or_err, nil
    end
    if ok then
        return nil, "invalid json"
    end
    return nil, data_or_err or "invalid json"
end

local function encodeJson(value)
    local ok, data_or_err = pcall(rapidjson.encode, value)
    if ok and data_or_err then
        return data_or_err, nil
    end
    if ok then
        return nil, "json encode failed"
    end
    return nil, data_or_err or "json encode failed"
end

local function requestJsonBody(body)
    local data, err = encodeJson(body)
    if data then
        return data, nil
    end
    return nil, tostring(err or "json encode failed")
end

local function contentType(headers)
    local value = Models.header(headers, "Content-Type")
    return type(value) == "string" and string.lower(value) or ""
end

local function contentLength(headers)
    local value = Models.header(headers, "Content-Length")
    return tonumber(value)
end

function Http:new(config, log)
    local obj = {
        config = config,
        log = log,
    }
    setmetatable(obj, { __index = self })
    return obj
end

function Http:baseUrl()
    local base_url = self.config:get("server_url")
    if type(base_url) ~= "string" or base_url == "" then
        return nil
    end
    if self.config.normalizeServerUrl then
        local normalized = self.config:normalizeServerUrl(base_url)
        if normalized and normalized ~= "" then
            base_url = normalized
        end
    end
    return base_url
end

function Http:makeUrl(path)
    local base_url = self:baseUrl()
    if not base_url then
        return nil
    end
    return base_url .. path
end

function Http:transportFor(url)
    if url:match("^https://") then
        return https
    end
    return http
end

function Http:request(args)
    local path = args.path or ""
    local url = self:makeUrl(path)
    if not url then
        return { ok = false, kind = "server_url_missing" }
    end

    local authenticated = args.authenticated ~= false
    local token = args.token or self.config:get("access_token")
    if authenticated and (type(token) ~= "string" or token == "") then
        return { ok = false, kind = "not_authenticated" }
    end

    local headers = {
        ["Accept"] = "application/json",
        ["Accept-Encoding"] = "identity",
    }
    if authenticated then
        headers["Authorization"] = "Bearer " .. token
    end

    local body_json
    if args.body ~= nil then
        local encoded, err = requestJsonBody(args.body)
        if not encoded then
            return { ok = false, kind = "decode_error", raw_body = tostring(err or "json encode failed") }
        end
        body_json = encoded
        headers["Content-Type"] = "application/json"
        headers["Content-Length"] = tostring(#body_json)
    end

    local sink = {}
    socketutil:set_timeout(args.timeout_block or socketutil.LARGE_BLOCK_TIMEOUT,
        args.timeout_total or socketutil.LARGE_TOTAL_TIMEOUT)
    local request = {
        url = url,
        method = args.method or "GET",
        headers = headers,
        sink = socketutil.table_sink(sink),
    }
    if body_json then
        request.source = ltn12.source.string(body_json)
    end

    self.log:info("http_request", {
        method = request.method,
        path = path,
        authenticated = authenticated,
    })

    local ok, code, response_headers, status_line = pcall(function()
        return socket.skip(1, self:transportFor(url).request(request))
    end)
    socketutil:reset_timeout()

    if not ok then
        return { ok = false, kind = "network_error", status_line = tostring(code) }
    end
    if isTimeoutCode(code) then
        return { ok = false, kind = "timeout", status_line = status_line }
    end
    if type(code) ~= "number" then
        return { ok = false, kind = "network_error", status_line = tostring(code) }
    end

    local raw_body = table.concat(sink)
    local data, decode_err = decodeJson(raw_body)
    if data == nil and decode_err and raw_body ~= "" then
        return {
            ok = false,
            status = code,
            kind = "decode_error",
            raw_body = raw_body,
            headers = response_headers,
            status_line = status_line,
        }
    end
    if type(data) == "table" and data.status == nil then
        data.status = code
    end

    if classifyAuthFailure(code, data) then
        return {
            ok = false,
            status = code,
            kind = "not_authenticated",
            data = data,
            raw_body = raw_body,
            headers = response_headers,
            status_line = status_line,
        }
    end

    if SUCCESS_STATUSES[code] then
        return {
            ok = true,
            status = code,
            kind = "success",
            data = data,
            raw_body = raw_body,
            headers = response_headers,
            status_line = status_line,
        }
    end

    if args.handled_statuses and args.handled_statuses[code] then
        return {
            ok = false,
            status = code,
            kind = "handled_error",
            data = data,
            raw_body = raw_body,
            headers = response_headers,
            status_line = status_line,
        }
    end

    return {
        ok = false,
        status = code,
        kind = "http_error",
        data = data,
        raw_body = raw_body,
        headers = response_headers,
        status_line = status_line,
    }
end

function Http:download(args)
    local url = self:makeUrl(args.path)
    if not url then
        return { ok = false, kind = "server_url_missing" }
    end

    local token = args.token or self.config:get("access_token")
    if type(token) ~= "string" or token == "" then
        return { ok = false, kind = "not_authenticated" }
    end

    local file, err = io.open(args.filepath, "wb")
    if not file then
        return { ok = false, kind = "network_error", status_line = err }
    end
    local function fail(result)
        pcall(function()
            file:close()
        end)
        os.remove(args.filepath)
        return result
    end

    local headers = {
        ["Accept"] = args.accept or "application/epub+zip,application/octet-stream",
        ["Accept-Encoding"] = "identity",
        ["Authorization"] = "Bearer " .. token,
    }
    socketutil:set_timeout(args.timeout_block or socketutil.FILE_BLOCK_TIMEOUT,
        args.timeout_total or socketutil.FILE_TOTAL_TIMEOUT)
    local request = {
        url = url,
        method = "GET",
        headers = headers,
        sink = socketutil.file_sink(file),
    }

    self.log:info("http_download", { path = args.path })

    local ok, code, response_headers, status_line = pcall(function()
        return socket.skip(1, self:transportFor(url).request(request))
    end)
    socketutil:reset_timeout()

    if not ok then
        return fail{ ok = false, kind = "network_error", status_line = tostring(code) }
    end
    if isTimeoutCode(code) then
        return fail{ ok = false, kind = "timeout", status_line = status_line }
    end
    if type(code) ~= "number" then
        return fail{ ok = false, kind = "network_error", status_line = tostring(code) }
    end
    if classifyAuthFailure(code) then
        return fail{
            ok = false,
            status = code,
            kind = "not_authenticated",
            headers = response_headers,
            status_line = status_line,
        }
    end
    if code == 200 or code == 206 then
        local ctype = contentType(response_headers)
        if ctype:match("^text/html") or ctype:find("application/json", 1, true) then
            return fail{
                ok = false,
                status = code,
                kind = "unexpected_content_type",
                headers = response_headers,
                status_line = status_line,
            }
        end
        local expected_length = contentLength(response_headers)
        if expected_length and expected_length <= 0 then
            return fail{
                ok = false,
                status = code,
                kind = "empty_download",
                headers = response_headers,
                status_line = status_line,
            }
        end
        return {
            ok = true,
            status = code,
            kind = "success",
            headers = response_headers,
            status_line = status_line,
            downloaded_hash = Models.header(response_headers, "X-Storyteller-Hash"),
        }
    end
    return fail{
        ok = false,
        status = code,
        kind = "http_error",
        headers = response_headers,
        status_line = status_line,
    }
end

return Http
