-- Consumption evidence and actual HP feedback share one local action key.
-- This module receives copied values only; it never reads engine objects/time.
local C = {}
C.__index = C

local function finite(n)
    return type(n)=="number" and n==n and n>-math.huge and n<math.huge
end
local function text(s)
    return type(s)=="string" and s~="" and s~="None"
end
local function generation(n)
    return finite(n) and n>=0 and n%1==0
end
local function count(n)
    return finite(n) and n>=0
end

function C.new(emit, config)
    assert(type(emit)=="function", "consumables requires an emit callback")
    config=type(config)=="table" and config or {}
    local limit=config.MaxRetained
    if not finite(limit) or limit<1 or limit%1~=0 or limit>4096 then limit=128 end
    local seconds=config.PendingSeconds
    if not finite(seconds) or seconds<=0 then seconds=8 end
    return setmetatable({emit=emit,maxRetained=limit,pendingSeconds=seconds,
        active={},order={}},C)
end

function C:reset()
    self.active,self.order,self.generation={},{},nil
end

function C:_prune(now)
    if not finite(now) then return end
    for _,action in pairs(self.active) do
        if action.at and (now<action.at or now-action.at>self.pendingSeconds) then
            -- Keep its tombstone until bounded retention evicts it. A duplicate
            -- begin cannot reopen an expired action or clear its played bit.
            action.expired=true
        end
    end
end

function C:begin(key,kind,id,before,gen,now)
    if not text(key) or not text(kind) or not text(id) or not count(before)
        or not generation(gen) or not finite(now) then return false end
    if self.generation~=nil and gen<self.generation then return false end
    if self.generation~=gen then
        self:reset()
        self.generation=gen
    end
    self:_prune(now)
    local old=self.active[key]
    if old then
        -- The same ability activation can reach native, UI and polling routes.
        return not old.expired and old.kind==kind and old.id==id and old.generation==gen
    end
    while #self.order>=self.maxRetained do
        local oldest=table.remove(self.order,1)
        self.active[oldest]=nil
    end
    self.active[key]={key=key,kind=kind,id=id,before=before,count=before,
        generation=gen,at=now,played=false,confirmed=false}
    self.order[#self.order+1]=key
    return true
end

function C:_action(key,gen)
    if not text(key) or not generation(gen) or self.generation~=gen then return nil end
    local action=self.active[key]
    if not action or action.expired or action.generation~=gen then return nil end
    return action
end

function C:confirm(key,kind,id,before,after,gen,cause)
    local action=self:_action(key,gen)
    if not action or action.kind~=kind or action.id~=id or not count(before)
        or not count(after) or after>=before or action.confirmed then return false end
    -- Consume both confirmation and feedback state before an external callback.
    action.confirmed,action.after,action.confirmedBefore=true,after,before
    if action.played then return false end
    action.played=true
    self.emit("PlayerHeal",type(cause)=="string" and cause or "consumable-used",gen,
        {consumable=true,key=key,id=id,kind=kind,before=before,after=after})
    return true
end

function C:onHeal(key,gen)
    local action=self:_action(key,gen)
    if not action or action.played then return false end
    -- The caller emits the real HP feedback when this returns true. Its later
    -- consumption notification must still update evidence without another cue.
    action.played=true
    action.healed=true
    return true
end

function C:wasPlayed(key)
    local action=text(key) and self.active[key]
    return action and action.played==true or false
end

function C:healKey(gen,now)
    if not generation(gen) or self.generation~=gen then return nil end
    self:_prune(now)
    local found
    for key,action in pairs(self.active) do
        if action.generation==gen and not action.expired then
            -- A confirmed action remains eligible so a subsequent HP gain can
            -- merge with its cue. Ambiguous independent actions need exact keys.
            if found then return nil end
            found=key
        end
    end
    return found
end

return C
