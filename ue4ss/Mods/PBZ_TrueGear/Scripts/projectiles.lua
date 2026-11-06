-- Actual projectile starts and spawn batches. Receives copied scalar identities
-- only; the caller validates owner/type/status and provides unique shot groups.
local P={};P.__index=P
local LIMIT=4096
local function text(value) return type(value)=="string" and value~="" and value~="None" end
local function generation(value)
    return type(value)=="number" and value==value and value>=0 and value<math.huge and value%1==0
end
function P.new(emit)
    assert(type(emit)=="function","projectiles requires an emit callback")
    local self=setmetatable({emit=emit,limit=LIMIT},P);self:reset();return self
end
function P:reset()
    self.bullets,self.groups={},{}
    self.bulletCount,self.groupCount,self.serial=0,0,0
    self.head,self.tail,self.generation=nil,nil,nil
end
local function record(self,id)
    local item=self.bullets[id]
    if item then return item end
    if self.bulletCount>=self.limit then
        local oldest,oldSerial
        for key,value in pairs(self.bullets) do
            if not value.active and (not oldSerial or value.serial<oldSerial) then oldest,oldSerial=key,value.serial end
        end
        if not oldest then return nil end -- Never discard a live seen bit and rearm it.
        self.bullets[oldest]=nil;self.bulletCount=self.bulletCount-1
    end
    self.serial=self.serial+1
    item={epoch=0,active=true,serial=self.serial}
    self.bullets[id]=item;self.bulletCount=self.bulletCount+1
    return item
end
function P:initialize(id)
    if not text(id) then return false end
    local item=record(self,id)
    if not item then return false end
    item.epoch=item.epoch+1;item.seenEpoch,item.seenGeneration=nil,nil
    self.serial=self.serial+1;item.serial=self.serial;item.active=true
    return item.epoch
end
function P:deactivate(id)
    local item=text(id) and self.bullets[id]
    if not item then return false end
    item.active=false
    self.serial=self.serial+1;item.serial=self.serial
    return true
end
function P:reactivate(id)
    local item=text(id) and self.bullets[id]
    if not item or item.active then return false end
    return self:initialize(id)
end
local function unlink(self,node)
    if node.previous then node.previous.next=node.next else self.head=node.next end
    if node.next then node.next.previous=node.previous else self.tail=node.previous end
    node.previous,node.next=nil,nil
end
local function group(self,key,gen)
    local token=tostring(gen).."|"..key
    local node=self.groups[token]
    if node then unlink(self,node)
    else
        if self.groupCount>=self.limit then
            local old=self.head
            unlink(self,old);self.groups[old.token]=nil;self.groupCount=self.groupCount-1
        end
        node={token=token,emitted=false};self.groups[token]=node;self.groupCount=self.groupCount+1
    end
    node.previous=self.tail
    if self.tail then self.tail.next=node else self.head=node end
    self.tail=node
    return node
end
function P:burst(ids,key,gen,cause)
    if type(ids)~="table" or not text(key) or not generation(gen) then return false end
    local unique,ordered={},{}
    for _,id in ipairs(ids) do
        if text(id) and not unique[id] then unique[id]=true;ordered[#ordered+1]=id end
    end
    if #ordered==0 then return false end
    if self.generation~=nil and gen<self.generation then return false end
    if self.generation~=nil and gen~=self.generation then self:reset() end
    self.generation=gen
    local node=group(self,key,gen)
    local duplicate,full=node.emitted,false
    for _,id in ipairs(ordered) do
        local item=record(self,id)
        if not item then full=true
        else
            duplicate=duplicate or not item.active or (item.seenEpoch==item.epoch and item.seenGeneration==gen)
            item.seenEpoch,item.seenGeneration=item.epoch,gen
        end
    end
    -- Even when another route already submitted one member, consume all other
    -- members of this batch so their later Start notifications cannot add cues.
    node.emitted=true
    if duplicate or full then return false end
    self.emit("ProjectileLaunch",text(cause) and cause or "actual-projectile-start",gen)
    return true
end
function P:start(id,key,gen,cause)
    return self:burst({id},key,gen,cause)
end
return P
