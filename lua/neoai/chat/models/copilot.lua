local utils = require("neoai.utils")
local config = require("neoai.config")

local function http_request(url, method, headers, body)
    local cmd = "curl -sS --no-buffer --request " .. method .. " '" .. url .. "'"

    for key, value in pairs(headers) do
        cmd = cmd .. " --header '" .. key .. ": " .. value .. "'"
    end

    if body ~= nil and body ~= "" then
        cmd = cmd .. " ---raw '" .. vim.fn.json_encode(body) .. "'"
    end

    local handle = io.popen(cmd)

    if handle then
        local result = handle:read("*a")
        handle:close()
        return result
    end

    return ""
end

local store_token = function(token)
    local f = io.open("/tmp/copilot-labs_token.txt", "w")
    f:write(vim.fn.json_encode(token))
    f:close()
end

local get_token = function()
    local f = io.open("/tmp/copilot-labs_token.txt", "r")

    if f == nil then
        return nil
    end

    local token_str = f:read("*all")
    f:close()

    return vim.fn.json_decode(token_str)
end

local function get_copilot_credentials()
    local file = io.open(os.getenv("HOME") .. "/.config/github-copilot/hosts.json", "r")

    if file then
        local content = file:read("*all")
        file:close()

        local userdata = vim.fn.json_decode(content)

        local token = userdata["github.com"].oauth_token

        local result = http_request("https://api.github.com/user", "GET", {
            Authorization = "Bearer " .. token,
            ["User-Agent"] = "GithubCopilot/0.4.488",
        })
        local user = vim.fn.json_decode(result)

        return { user = user, token = token }
    end
end

local function get_copilot_token()
    local credentials = get_copilot_credentials()
    local token = credentials.token

    local result = http_request("https://api.github.com/copilot_internal/v2/token", "GET", {
        Authorization = "token " .. token,
        ["User-Agent"] = "GithubCopilot/0.4.488",
    })
    return vim.fn.json_decode(result)
end

local function is_token_still_valid(token)
    local now = os.time()
    local expires_at = token.expires_at
    expires_at = tonumber(expires_at)
    return now < expires_at
end

local function authenticate()
    local token = get_token()

    if token == nil or not is_token_still_valid(token) then
        token = get_copilot_token()
        store_token(token)
    end

    return token
end

local random = math.random
local function uuid()
    local template = "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx"
    return string.gsub(template, "[xy]", function(c)
        local v = (c == "x") and random(0, 0xf) or random(8, 0xb)
        return string.format("%x", v)
    end)
end

function generate_custom_id()
    local id_uuid = uuid()

    local timestamp = math.floor(os.time() * 1000)
    local custom_id = id_uuid .. timestamp

    return custom_id
end

---@type ModelModule
local M = {}

M.name = "Copilot"

local chunks = {}
local raw_chunks = {}
local token = nil

M.get_current_output = function()
    return table.concat(chunks, "")
end

---@param chunk string
---@param on_stdout_chunk fun(chunk: string) Function to call whenever a stdout chunk occurs
M._recieve_chunk = function(chunk, on_stdout_chunk)
    -- vim.pretty_print(chunk)
    for line in chunk:gmatch("[^\n]+") do
        local raw_json = string.gsub(line, "^data: ", "")

        table.insert(raw_chunks, raw_json)
        local ok, path = pcall(vim.json.decode, raw_json)
        if not ok then
            goto continue
        end

        path = path.choices
        if path == nil then
            goto continue
        end
        path = path[1]
        if path == nil then
            goto continue
        end
        path = path.delta
        if path == nil then
            goto continue
        end
        path = path.content
        if path == nil then
            goto continue
        end
        on_stdout_chunk(path)
        -- append_to_output(path, 0)
        table.insert(chunks, path)
        ::continue::
    end
end

---@param chat_history ChatHistory
---@param on_stdout_chunk fun(chunk: string) Function to call whenever a stdout chunk occurs
---@param on_complete fun(err?: string, output?: string) Function to call when model has finished
M.send_to_model = function(chat_history, on_stdout_chunk, on_complete)
    local api_key = os.getenv(config.options.open_api_key_env)

    local data = {
        model = chat_history.model,
        messages = chat_history.messages,
    }
    data = vim.tbl_deep_extend("force", {}, data, chat_history.params)

    chunks = {}
    raw_chunks = {}
    token = authenticate()

    utils.exec("curl", {
        "--silent",
        "--show-error",
        "--no-buffer",
        "https://copilot-proxy.githubusercontent.com/v1/chat/completions",
        "-H",
        "Authorization: Bearer " .. token.token,
        "-H",
        "X-Request-Id: " .. uuid(),
        "-H",
        "Openai-Organization: github-copilot",
        "-H",
        "VScode-SessionId: " .. generate_custom_id(),
        "-H",
        "Editor-Version: vscode/1.79.0-insider",
        "-H",
        "Editor-Plugin-Version: copilot/0.1.2023051601",
        "-H",
        "OpenAI-Intent: conversation-panel",
        "-d",
        vim.json.encode(data),
    }, function(chunk)
        M._recieve_chunk(chunk, on_stdout_chunk)
    end, function(err, _)
        local total_message = table.concat(raw_chunks, "")
        local ok, json = pcall(vim.json.decode, total_message)
        if ok then
            if json.error ~= nil then
                on_complete(json.error.message, nil)
                return
            end
        end
        on_complete(err, M.get_current_output())
    end)
end

return M
