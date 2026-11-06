-- Actual attribute transitions and movement notifications; no input-button inference.
local Vitals = {}
Vitals.__index = Vitals
local function finite(n) return type(n)=="number" and n==n and math.abs(n)<math.huge end
function Vitals.new(emit, config)
    local self=setmetatable({emit=emit,config=config},Vitals);self:reset();return self
end
function Vitals:reset()
    self.values={}; self.airborne=false; self.peakDown=0; self.lastLanding=nil;self.lastJump=nil
    self.posture=nil;self.jumpActive=false;self.landingActive=false;self.falling=false
    self.sprintPending=false;self.landRequested=false
    self.movementHeld=nil;self.movementPlayed=false;self.movementSource=nil;self.movementDashSeen=false
    self.movementInputs={};self.movementComponent=nil;self.dashSeen={};self.dashOrder={}
end
function Vitals:movementInput(current)
    if type(current)~="table" then return end
    local changed=self.movementComponent and current.componentId and self.movementComponent~=current.componentId
    if changed then self.movementHeld=nil;self.movementInputs={} end
    local newPress=changed or (current.held==true and self.movementHeld==false)
    -- A press released and repeated between samples is visible as a reset of
    -- the SAME action's hold duration. Different actions can enter in stages.
    if current.held==true and not changed then
        for key,value in pairs(current.actions or {}) do
            local old=self.movementInputs[key]
            if old and old.actionId==value.actionId and old.held==true and value.held==true
                and finite(old.holdTime) and finite(value.holdTime) and value.holdTime+0.001<old.holdTime then newPress=true end
        end
    end
    if changed or newPress or current.held==false then
        self.movementPlayed=false;self.movementSource=nil;self.movementDashSeen=false
    end
    if type(current.held)=="boolean" then
        self.movementHeld=current.held
        self.movementInputs=current.actions or {}
    end -- Unknown is not a release; retain the last proven episode.
    if current.componentId then self.movementComponent=current.componentId end
end
function Vitals:dash(key,generation,cause)
    if type(key)~="string" or self.dashSeen[key] then return false end
    self.dashSeen[key]=true;self.dashOrder[#self.dashOrder+1]=key
    if #self.dashOrder>256 then self.dashSeen[table.remove(self.dashOrder,1)]=nil end
    local joined=self.movementHeld==true and self.movementPlayed and self.movementSource=="sprint" and not self.movementDashSeen
    if self.movementHeld==true then
        self.movementPlayed=true;self.movementDashSeen=true
        if not joined then self.movementSource="dash" end
    end
    if joined then return false end
    self.emit("SlideStart",cause or "confirmed-dash/actual-timeline",generation)
    return true
end
function Vitals:sample(pawn, values, generation)
    if not pawn or not finite(values.hp) or values.hp<=0 then self.values={}; return end
    local old=self.values
    self.values=values -- Consume every observed transition before external calls.
    if old.pawn~=pawn then values.pawn=pawn; return end
    values.pawn=pawn
    local function fire(name) self.emit(name,"actual-attribute-transition",generation) end
    if finite(values.shield) and finite(old.shield) and values.shieldMax==old.shieldMax then
        if old.shield>0 and values.shield<old.shield then
            fire(values.shield<=0 and "ShieldBreak" or "ShieldHit")
        end
    end
    if finite(values.max) and values.max>0 and values.max==old.max then
        if old.hp/values.max>self.config.LowHealthRatio and values.hp/values.max<=self.config.LowHealthRatio then
            fire("LowHealthWarning")
        end
    end
    if finite(values.shachi) and finite(old.shachi) and finite(values.shachiMax) and values.shachiMax>0 and values.shachiMax==old.shachiMax then
        if old.shachi>0 and values.shachi<=0 then fire("ShachiDepleted")
        elseif old.shachi/values.shachiMax>self.config.LowResourceRatio and values.shachi>0 and values.shachi/values.shachiMax<=self.config.LowResourceRatio then fire("ShachiLow") end
    end
    if finite(values.ultimateCount) and finite(old.ultimateCount) and values.ultimateMax==old.ultimateMax then
        if values.ultimateCount>old.ultimateCount then fire("UltimateChargeGained")
        elseif values.ultimateCount<old.ultimateCount then fire("UltimateChargeSpent") end
    end
    if finite(values.awakening) and finite(old.awakening) and finite(values.awakeningMax) and values.awakeningMax>0 and values.awakeningMax==old.awakeningMax then
        if old.awakening<values.awakeningMax and values.awakening>=values.awakeningMax then fire("AwakeningReady") end
    end
    for key,event in pairs(self.config.BuildupEvents) do
        if finite(values[key]) and finite(old[key]) and old[key]<=0 and values[key]>0 then fire(event) end
    end
end
function Vitals:motion(falling, vz)
    if falling and not self.falling then self.landingActive=false end
    self.falling=falling
    if falling and not self.landingActive then
        self.airborne=true
        if finite(vz) then self.peakDown=math.max(self.peakDown,-vz) end
    end
end
function Vitals:jump(now,generation,cause)
    if (now~=nil and not finite(now)) or self.jumpActive then return end
    self.lastJump=now
    self.airborne=true;self.jumpActive=true;self.landingActive=false;self.landRequested=false
    self.emit("PlayerJump",cause or "confirmed-jump-state/OnJumped",generation)
end
function Vitals:wallBegin()
    -- Wall traversal can enter Custom movement without an Engine jump/fall.
    self.airborne=true;self.landingActive=false;self.peakDown=0;self.landRequested=false
end
function Vitals:requestLand()
    -- OnLanded is a candidate only. It can run while still Falling, and a
    -- Blueprint may invoke it before the capsule is physically on the floor.
    if self.landingActive then return end
    self.landRequested=true
end
function Vitals:land(now,generation)
    if (now~=nil and not finite(now)) or self.landingActive then return end
    self.lastLanding=now; self.airborne=false; self.peakDown=0;self.jumpActive=false;self.landingActive=true;self.landRequested=false
    -- Speed alone cannot establish drop height (jump, grapple and wall motion
    -- can all accelerate downward). User requested normal fallback without it.
    self.emit("PlayerLand","OnLanded/normal-height-unverified",generation)
end
function Vitals:samplePosture(current,generation)
    local previous=self.posture
    self.posture=current
    if not previous then
        self.sprintPending=false
        if current.sprinting==true and self.movementHeld==true and not self.movementPlayed then
            self.movementPlayed=true;self.movementSource="baseline"
        end
        -- Loading into a pose is quiet. A prior explicit collision candidate
        -- may still complete on the first independently confirmed floor query.
        if current.grounded==true and self.landRequested then self:land(nil,generation) end
        return
    end
    if current.dashActive==true or current.sprinting~=true then
        self.sprintPending=false
    elseif previous.sprinting==false then
        self.sprintPending=true
    end
    if self.sprintPending and finite(current.speedXY) and current.speedXY>1 then
        self.sprintPending=false -- Consume before emitting, including reentry/errors.
        if self.movementHeld~=true or not self.movementPlayed then
            if self.movementHeld==true then self.movementPlayed=true;self.movementSource="sprint" end
            self.emit("SlideStart","confirmed-sprint-state/moving",generation)
        end
    end
    if previous.jumped==false and current.jumped==true then self:jump(nil,generation) end
    if current.jumped==false and previous.jumped==true then self.jumpActive=false end
    if previous.crouched==false and current.crouched==true then
        self.emit("PlayerCrouch","actual-crouch-state-entered",generation)
    elseif previous.crouched==true and current.crouched==false then
        self.emit("PlayerCrouch","actual-crouch-state-exited/stand-up",generation)
    end
    if current.grounded==true and (self.landRequested or (previous.grounded==false and self.airborne)) then
        self:land(nil,generation)
    end
end
return Vitals
