local module_source = debug.getinfo(1, "S").source or ""
if module_source:sub(1, 1) == "@" then
    module_source = module_source:sub(2)
end
module_source = module_source:gsub("\\", "/")
local sdk_dir = module_source:match("^(.*)/[^/]+$")
if not sdk_dir then
    error("TrueGearSDK could not determine its installation directory")
end

local json = dofile(sdk_dir .. "/json.lua")
local base64 = dofile(sdk_dir .. "/base64.lua")

local sdk = {}
local Player = {}
Player.__index = Player

local bridge_exe = sdk_dir .. "/TrueGearBridge.exe"
local request_id = 0
local default_player = nil

local function quote_arg(value)
    value = tostring(value or "")
    if value:find('"', 1, true) then
        error("TrueGearSDK arguments cannot contain a double quote")
    end
    return '"' .. value .. '"'
end

local function sanitize_name(value)
    local result = tostring(value or "default"):gsub("[^%w%._%-]", "_")
    if result == "" then result = "default" end
    return result
end

local function ensure_directory(path)
    os.execute('if not exist ' .. quote_arg(path:gsub("/", "\\")) .. ' mkdir ' .. quote_arg(path:gsub("/", "\\")) .. ' >nul 2>nul')
end

local function append_line(path, line)
    local file, err = io.open(path, "ab")
    if not file then
        return false, err
    end
    file:write(line, "\n")
    file:flush()
    file:close()
    return true
end

local function file_size(path)
    local file = io.open(path, "rb")
    if not file then return 0 end
    local size = file:seek("end") or 0
    file:close()
    return size
end

local function read_all(path)
    local file = io.open(path, "rb")
    if not file then return nil end
    local value = file:read("*a")
    file:close()
    return value
end

local function make_rpc(method, body)
    local rpc = {
        Method = method,
        Body = body == "" and "" or base64.encode(body),
        ReqId = tostring(request_id),
    }
    request_id = request_id + 1
    return json.encode(rpc)
end

local function deep_copy(value, seen)
    if type(value) ~= "table" then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end
    local result = {}
    seen[value] = result
    for key, item in pairs(value) do
        result[deep_copy(key, seen)] = deep_copy(item, seen)
    end
    return result
end

function Player.new(app_id, api_key)
    local self = setmetatable({}, Player)
    self.app_id = tostring(app_id or "")
    self.api_key = tostring(api_key or "")
    self.runtime_dir = sdk_dir .. "/runtime/" .. sanitize_name(self.app_id)
    self.commands_path = self.runtime_dir .. "/commands.log"
    self.responses_path = self.runtime_dir .. "/responses.log"
    self.status_path = self.runtime_dir .. "/status.txt"
    self.response_offset = 0
    self.effects = {}
    self.pre_seek = {}
    self.started = false
    return self
end

function Player:start()
    if self.started then return true end
    ensure_directory(sdk_dir .. "/runtime")
    ensure_directory(self.runtime_dir)

    local command_file = io.open(self.commands_path, "ab")
    if not command_file then
        return false, "cannot open TrueGear bridge command queue"
    end
    command_file:close()

    local response_file = io.open(self.responses_path, "ab")
    if response_file then response_file:close() end
    self.response_offset = file_size(self.responses_path)

    self:_launch_bridge()
    self.started = true

    for uuid in pairs(self.pre_seek) do
        self:send_seek_effect_by_uuid(uuid)
    end
    return true
end

function Player:_launch_bridge()
    append_line(self.commands_path, "__restart__")
    local command = "start \"\" /b " .. quote_arg(bridge_exe:gsub("/", "\\"))
        .. " --runtime " .. quote_arg(self.runtime_dir:gsub("/", "\\"))
        .. " --app-id " .. quote_arg(self.app_id)
        .. " --api-key " .. quote_arg(self.api_key)
    os.execute(command)
end

function Player:get_status()
    local value = read_all(self.status_path)
    if not value then return false, "stopped" end
    value = value:gsub("^%s+", ""):gsub("%s+$", "")
    local state, heartbeat = value:match("^([^|]+)|(%d+)$")
    if not state then return false, value end
    local fresh = math.abs(os.time() - tonumber(heartbeat)) <= 5
    return state == "registered" and fresh, state
end

function Player:_send(method, body)
    if not self.started then
        local ok, err = self:start()
        if not ok then return false, err end
    else
        local status = read_all(self.status_path)
        local heartbeat = status and status:match("|(%d+)%s*$")
        if not heartbeat or math.abs(os.time() - tonumber(heartbeat)) > 5 then
            self:_launch_bridge()
        end
    end
    return append_line(self.commands_path, make_rpc(method, body or ""))
end

function Player:send_play(uuid)
    return self:_send("play_effect_by_uuid", self.app_id .. ";" .. tostring(uuid))
end

function Player:send_play_effect_by_content(effect)
    return self:_send("play_effect_by_content", json.encode(effect))
end

function Player:send_seek_effect_by_uuid(uuid)
    uuid = tostring(uuid)
    self.pre_seek[uuid] = true
    return self:_send("seek_by_uuid", self.app_id .. ";" .. uuid)
end

function Player:pre_seek_effect(uuid)
    uuid = tostring(uuid)
    self.pre_seek[uuid] = true
    if self.started then
        return self:send_seek_effect_by_uuid(uuid)
    end
    return true
end

function Player:stop_effect(uuid)
    return self:_send("stop", tostring(uuid))
end

function Player:stop_all()
    return self:_send("stop_all", "")
end

function Player:send_register()
    if not self.started then
        return self:start()
    end
    self:_launch_bridge()
    return true
end

function Player:update()
    local file = io.open(self.responses_path, "rb")
    if not file then return 0 end
    local size = file:seek("end") or 0
    if size < self.response_offset then self.response_offset = 0 end
    file:seek("set", self.response_offset)

    local count = 0
    for line in file:lines() do
        local ok_rpc, rpc = pcall(json.decode, line)
        if ok_rpc and type(rpc) == "table" and rpc.Method == "seek_by_uuid" and rpc.Result then
            local ok_body, body = pcall(base64.decode, rpc.Result)
            if ok_body and body and body ~= "" then
                local ok_effect, effect = pcall(json.decode, body)
                if ok_effect and type(effect) == "table" then
                    local uuid = effect.uuid or effect.name
                    if uuid then
                        self.effects[uuid] = effect
                        count = count + 1
                    end
                end
            end
        end
    end
    self.response_offset = file:seek() or size
    file:close()
    return count
end

function Player:find_effect_by_uuid(uuid)
    self:update()
    return self.effects[tostring(uuid)]
end

function Player:shutdown()
    if self.started then
        append_line(self.commands_path, "__shutdown__")
        self.started = false
    end
end

-- TrueGearSDK.dll-style method aliases for easy ports from C# mods.
Player.Start = Player.start
Player.GetStatus = Player.get_status
Player.SendRegist = Player.send_register
Player.SendPlay = Player.send_play
Player.SendPlayEffectByContent = Player.send_play_effect_by_content
Player.SendSeekEffectByContent = Player.send_seek_effect_by_uuid
Player.PreSeekEffect = Player.pre_seek_effect
Player.FindEffectByUuid = Player.find_effect_by_uuid
Player.StopEffect = Player.stop_effect
Player.StopAll = Player.stop_all
Player.Update = Player.update
Player.Shutdown = Player.shutdown

sdk.Player = Player
sdk.new = Player.new
sdk.copy_effect = deep_copy

function sdk.init(app_id, api_key)
    default_player = Player.new(app_id, api_key)
    local ok, err = default_player:start()
    if not ok then return false, err end
    return true
end

local function current()
    if not default_player then
        error("TrueGearSDK.init(app_id, api_key) must be called first")
    end
    return default_player
end

function sdk.get_status() return current():get_status() end
function sdk.play_effect_by_uuid(uuid) return current():send_play(uuid) end
function sdk.play_effect_by_content(effect) return current():send_play_effect_by_content(effect) end
function sdk.seek_by_uuid(uuid) return current():send_seek_effect_by_uuid(uuid) end
function sdk.pre_seek_effect(uuid) return current():pre_seek_effect(uuid) end
function sdk.find_effect(uuid) return current():find_effect_by_uuid(uuid) end
function sdk.stop_effect(uuid) return current():stop_effect(uuid) end
function sdk.stop_all() return current():stop_all() end
function sdk.update() return current():update() end
function sdk.shutdown() return current():shutdown() end

return sdk
