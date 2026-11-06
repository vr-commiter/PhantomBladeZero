-- Confirmed post-damage payloads and exact defender settlement tags.
-- Holds copied scalar identities only; never keeps a deferred game UObject.
local Combat={}
Combat.__index=Combat
local function finite(n) return type(n)=="number" and n==n and math.abs(n)<math.huge end
function Combat.new(emit)
    return setmetatable({emit=emit,seen={},order={},contacts={},contactOrder={},settlements={},settlementOrder={},defenses={},defenseOrder={}},Combat)
end
function Combat:reset()
    self.seen={};self.order={};self.contacts={};self.contactOrder={}
    self.settlements={};self.settlementOrder={};self.defenses={};self.defenseOrder={}
end
function Combat:bulletReset(bullet)
    if not bullet then return end
    local keep={}
    for _,key in ipairs(self.contactOrder) do
        if self.contacts[key].bullet==bullet then self.contacts[key]=nil else keep[#keep+1]=key end
    end
    self.contactOrder=keep
    keep={}
    for _,key in ipairs(self.settlementOrder) do
        if self.settlements[key]==bullet then self.settlements[key]=nil else keep[#keep+1]=key end
    end
    self.settlementOrder=keep
    keep={}
    for _,key in ipairs(self.defenseOrder) do
        if self.defenses[key]==bullet then self.defenses[key]=nil else keep[#keep+1]=key end
    end
    self.defenseOrder=keep
end
function Combat:contact(bullet,source,target,generation,lifetime,cause,settlement,frame)
    if not bullet or not source or not target or source==target then return false,"invalid-contact" end
    local key=bullet.."|"..tostring(lifetime).."|"..source.."|"..target.."|"..tostring(generation)
    local record=self.contacts[key]
    if not record then
        record={bullet=bullet};self.contacts[key]=record;self.contactOrder[#self.contactOrder+1]=key
        if #self.contactOrder>1024 then self.contacts[table.remove(self.contactOrder,1)]=nil end
    end
    local verified=type(settlement)=="table" and type(settlement.payload)=="string" and settlement.payload~=""
        and finite(settlement.loss) and settlement.loss>0
        and (settlement.hp==nil or (finite(settlement.hp) and settlement.hp>=0))
    local decision="new-contact"
    if verified then
        -- A sweep can legally damage the same target again in one ability
        -- activation. Keep each copied settlement identity, not just the bullet.
        local token=key.."|"..settlement.payload.."|"..tostring(settlement.hp).."|"..tostring(settlement.loss)
        if self.settlements[token] then
            record.emitted=true;record.hasSettlement=true;record.pendingFrame=nil
            return false,"duplicate-settlement"
        end
        self.settlements[token]=bullet;self.settlementOrder[#self.settlementOrder+1]=token
        if #self.settlementOrder>2048 then self.settlements[table.remove(self.settlementOrder,1)]=nil end
        -- HitEffect may run before HP changes, then OnTaken reports the same
        -- hit after settlement. Claim that earlier feedback only in its exact
        -- game frame. An old contact must not swallow a later combo settlement.
        local joined=record.emitted and not record.hasSettlement and finite(frame) and frame==record.pendingFrame
        record.hasSettlement=true;record.pendingFrame=nil;record.emitted=true
        if joined then return false,"joined-contact-settlement" end
        decision="new-settlement"
    else
        if record.emitted then return false,"duplicate-contact" end
        record.emitted=true;record.pendingFrame=finite(frame) and frame or nil
    end
    -- Consume both the contact and settlement before invoking external code.
    self.emit("MeleeHit",cause or "actual-bullet-contact/enemy-or-object",generation)
    return true,decision
end
function Combat:deflect(bullet,source,target,hitTime,result,generation,lifetime)
    local name=({["Deflect.Result.Normal"]="Parry",["Deflect.Result.Perfect"]="PerfectParry"})[result]
    if not name or not source or not target or source==target or type(hitTime)~="number" or hitTime~=hitTime or math.abs(hitTime)==math.huge then return false end
    local key=tostring(bullet).."|"..tostring(lifetime).."|"..source.."|"..target.."|"..hitTime.."|"..result
    if self.defenses[key] then return false end
    self.defenses[key]=bullet or source;self.defenseOrder[#self.defenseOrder+1]=key
    if #self.defenseOrder>512 then self.defenses[table.remove(self.defenseOrder,1)]=nil end
    self.emit(name,"Send-Impact-Event/"..result,generation)
    return true
end
function Combat:damage(payload,source,target,hp,generation)
    if not payload or not source or not target or source==target or type(hp)~="number" or hp~=hp or hp<0 then return false end
    -- Payload identity joins repeated source/target notifications. Include actual HP
    -- so a pooled payload can report a later damage settlement to the same actor.
    local fingerprint=source.."|"..target.."|"..tostring(hp)
    if self.seen[payload]==fingerprint then return false end
    if not self.seen[payload] then
        self.order[#self.order+1]=payload
        if #self.order>512 then self.seen[table.remove(self.order,1)]=nil end
    end
    self.seen[payload]=fingerprint -- Consume before calling external event code.
    self.emit("MeleeHit","DamageTakenPayload/local-source",generation)
    return true
end
Combat.defenseTags={
    ["GameplayEvent.Ability.Action.Deflect.Defender.Normal"]="Parry",
    ["GameplayEvent.Ability.Action.Deflect.Defender.Perfect"]="PerfectParry",
}
return Combat
