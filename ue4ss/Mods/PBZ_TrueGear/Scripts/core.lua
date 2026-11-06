-- Pure event state. All callers supply copied values, never deferred UObjects.
local Core = {}
Core.__index = Core
local function finite(n)
    return type(n) == "number" and n == n and n > -math.huge and n < math.huge
end
function Core.new(emit, healingConfig)
    local gap=healingConfig and healingConfig.QuietGapSeconds
    if not finite(gap) or gap<=0 then gap=1.0 end
    return setmetatable({emit = emit, generation = 0, traces = {}, parries = {},healQuietGap=gap}, Core)
end
function Core:reset()
    self.generation = self.generation + 1
    self.pawn, self.hp, self.maxHp = nil, nil, nil
    self.traces, self.parries = {}, {}
    self.lastHealAt=nil
end
function Core:baseline(pawn, hp, maxHp)
    self.pawn, self.hp, self.maxHp = pawn, hp, maxHp
    self.lastHealAt=nil
end
function Core:health(pawn, hp, maxHp, cause, damageCause, observedAt)
    if not pawn or not finite(hp) or not finite(maxHp) or maxHp <= 0 or hp < 0 then
        self.hp = nil
        self.lastHealAt=nil
        return
    end
    if self.pawn ~= pawn or self.hp == nil or self.maxHp ~= maxHp then
        self:reset()
        self:baseline(pawn, hp, maxHp)
        return -- Creation, possession, restore and max-health changes are silent.
    end
    local old = self.hp
    self.hp = hp -- Consume the transition before any logger or external callback.
    if hp==0 or old<=0 then self.lastHealAt=nil end
    if old > 0 and hp < old - 0.0001 then
        if hp == 0 then
            self.emit("PlayerDeath", cause or "health", self.generation)
        else
            self.emit("PlayerDamage", cause or "health", self.generation,
                {amount=old-hp,maxHp=maxHp,hpAfter=hp,damageCause=damageCause})
        end
    elseif old > 0 and hp > old + 0.0001 then
        -- One cue for a contiguous healing series. Update on every actual HP
        -- gain, including suppressed gains; damage does not split regeneration.
        -- Without a valid observation clock retain the legacy per-gain behavior.
        local timed=finite(observedAt)
        local first=not timed or self.lastHealAt==nil or observedAt<self.lastHealAt
            or observedAt-self.lastHealAt>=self.healQuietGap
        self.lastHealAt=timed and observedAt or nil
        if first then self.emit("PlayerHeal", cause or "health", self.generation) end
    end -- 0 -> positive is respawn, not a healing action.
end
function Core:traceStart(pawn, trace)
    if pawn ~= self.pawn or not self.hp or self.hp <= 0 or not trace or self.traces[trace] then return end
    self.traces[trace] = {hit = false}
    self.emit("MeleeAttack", "attack-trace-enabled", self.generation)
end
function Core:traceStop(trace)
    if trace then self.traces[trace] = nil end
end
function Core:traceHit(pawn, trace, hasOtherActor)
    local action = trace and self.traces[trace]
    if pawn ~= self.pawn or not self.hp or self.hp <= 0 or not action or action.hit or not hasOtherActor then return end
    action.hit = true
    self.emit("MeleeHit", "attack-trace-hit", self.generation)
end
function Core:parry(action, defender, attacker, result)
    if defender ~= self.pawn or not self.hp or self.hp <= 0 or not action or not attacker then return end
    -- Verified EParryResult: None=0 Normal=1 PrePerfect=2 Perfect=3 PostPerfect=4 Fail=5.
    if result ~= 1 and result ~= 2 and result ~= 3 and result ~= 4 then return end
    local key = action .. "|" .. attacker .. "|" .. defender
    if self.parries[key] then return end
    self.parries[key] = true
    self.emit(result == 3 and "PerfectParry" or "Parry", "parry-impact", self.generation)
end
function Core:parryBegin(action)
    -- Reused action objects get a new lifetime at result determination.
    local prefix = action and (action .. "|")
    if not prefix then return end
    for key in pairs(self.parries) do
        if key:sub(1, #prefix) == prefix then self.parries[key] = nil end
    end
end
return Core
