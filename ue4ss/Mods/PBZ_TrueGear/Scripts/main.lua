local source = debug.getinfo(1, "S").source:gsub("^@", ""):gsub("\\", "/")
local root = assert(source:match("^(.*)/Scripts/[^/]+$"), "Cannot locate PBZ_TrueGear")
local Config = dofile(root .. "/Scripts/config.lua")
local Core = dofile(root .. "/Scripts/core.lua")
local Feedback = dofile(root .. "/Scripts/feedback.lua")
local Vitals = dofile(root .. "/Scripts/vitals.lua")
local Rumble = dofile(root .. "/Scripts/rumble.lua")
local Templates = dofile(root .. "/Scripts/templates.lua")
local Routes = dofile(root .. "/Scripts/routes.lua")
local A = dofile(root .. "/Scripts/engine_adapter.lua")
local Combat = dofile(root .. "/Scripts/combat.lua")
local Damage = dofile(root .. "/Scripts/damage.lua")
local Power = dofile(root .. "/Scripts/play_power.lua")
local Consumables = dofile(root .. "/Scripts/consumables.lua")
local Projectiles = dofile(root .. "/Scripts/projectiles.lua")
-- Private SDK copy prevents collisions with other mods' shared TrueGearSDK modules.
local sdk = dofile(root .. "/SDK/TrueGearSDK.lua")
local UEHelpers = require("UEHelpers")
local function log(s) print("[PBZ_TrueGear " .. Config.Version .. "] " .. tostring(s) .. "\n") end
local feedback = Feedback.new(Config, sdk, log,nil,Power.new(sdk))
local primarySinceSample=false
local initializing=0
local rumble
local fallbackLoops={}
local wallActions={}
local wallAbilities={}
local wallFootTimes={}
local wallPulseActive,wallIKPrevious=false,nil
local dashAbilities={}
local observeDash
local executionActions={}
local observeExecution
local hookTargets,hookRequest,grappleMotion={},nil,nil
local inventoryState,backpack
local inventoryTicks,inventoryInitializing=0,0
local use={actions={},counts={},stack={},epoch=0,sequence=0}
local consumed,healUseKey,observeUses
local freshGrounded
local shotContext={stack={},sequence=0}
local notices={}
local rumbleRequests={asset=0,dynamic=0}
local function notice(key,message)
    if notices[key] then return end
    notices[key]=true;log(message)
end
local function contentDuration(effect)
    local duration=0;for _,track in ipairs(effect.tracks) do duration=math.max(duration,track.end_time) end;return duration
end
local function emit(name,cause,gen,details)
    if initializing>0 or not Config.Enabled or not Config.Events[name] then return end
    if name=="PlayerHeal" and not (details and details.consumable) and consumed and healUseKey then
        local key=healUseKey()
        if key and consumed:wasPlayed(key) then return end
        if key then consumed:onHeal(key,gen) end
    end
    if name=="PlayerLand" then
        -- Clear traversal only after a fresh collision query confirms contact.
        hookTargets,hookRequest,grappleMotion={},nil,nil
        wallActions,wallAbilities,wallFootTimes={},{},{}
        wallPulseActive,wallIKPrevious=false,nil
    end
    primarySinceSample=true
    if rumble and rumble.output=="ControllerRumble" then
        feedback:stopRumble("ControllerRumble",gen)
        rumble.output=nil
    end
    if name=="PlayerDamage" and details then
        local effect,kind,ratio=Damage.content(Templates.PlayerDamage,details,Config.Damage)
        if Config.Debug then log("damage-observe type="..kind.." amount="..details.amount.." ratio="..ratio.." cause="..tostring(details.damageCause)) end
        local event=feedback:enqueuePrimaryContent(name,effect,cause,gen,{input="damage-"..kind,pulse_ms=contentDuration(effect)})
        if event then event.damage=details end
    elseif name=="PlayerLand" or name=="HardLanding" then
        feedback:enqueuePrimaryContent(name,Templates[name],cause,gen,{input="landing",pulse_ms=contentDuration(Templates[name])})
    elseif name=="PlayerHeal" or name=="ItemCollected" then
        local input=name=="PlayerHeal" and (details and details.consumable and "consumable-used" or "healing-whole-torso") or "collection-top-down"
        feedback:enqueuePrimaryContent(name,Templates[name],cause,gen,{input=input,pulse_ms=contentDuration(Templates[name])})
    elseif name=="WallClimbStart" then
        local input=cause and cause:find("confirmed-hook-travel/",1,true)==1 and "grapple-pull" or "wall-start"
        feedback:enqueuePrimaryContent(name,Templates[name],cause,gen,{input=input,pulse_ms=contentDuration(Templates[name])})
    elseif name=="SlideStart" and cause and (cause:find("confirmed-dash/",1,true)==1 or cause:find("confirmed-sprint-state/",1,true)==1) then
        feedback:enqueuePrimaryContent(name,Templates[name],cause,gen,{input=cause:find("confirmed-dash/",1,true)==1 and "dash-start" or "sprint-start",pulse_ms=contentDuration(Templates[name])})
    elseif name=="ProjectileLaunch" then
        feedback:enqueuePrimaryContent(name,Templates[name],cause,gen,{input="confirmed-projectile-fire",pulse_ms=contentDuration(Templates[name])})
    else feedback:enqueue(name,cause,gen) end
end
local state = Core.new(emit,Config.Healing)
consumed=Consumables.new(emit,{PendingSeconds=8})
local combat = Combat.new(emit)
local shots = Projectiles.new(emit)
local vitals = Vitals.new(emit,Config.Attributes)
local function PlayPower(event,power,content,generation,meta)
    return feedback:PlayPower(event,power,generation or state.generation,content,meta)
end
rumble = Rumble.new(Config.Rumble,Templates,
    function(name,content,gen,meta) PlayPower(name,meta.power,content,gen,meta) end,
    function(name) feedback:stopRumble(name,state.generation) end,Config.Events)
local hooks, failed = {}, {}
local tickPawn,tickReal,tickDelta=nil,nil,0
local lastPawn, localPawn, localController
local attempt,unwrap,valid,id,same=A.try,A.unwrap,A.valid,A.id,A.same
local function reset()
    tickPawn,tickReal,tickDelta=nil,nil,0
    state:reset();combat:reset();vitals:reset();rumble:reset();primarySinceSample=false;fallbackLoops={};wallActions={}
    wallAbilities={};wallFootTimes={}
    wallPulseActive,wallIKPrevious=false,nil;dashAbilities={}
    executionActions={}
    hookTargets,hookRequest,grappleMotion={},nil,nil
    inventoryState,backpack,inventoryTicks=nil,nil,0
    use.actions,use.counts,use.stack={},{},{};use.epoch=use.epoch+1;consumed:reset()
    freshGrounded=nil
    shots:reset();shotContext.stack={}
end
local function resolvePlayer()
    if not valid(localController) then localController = UEHelpers.GetPlayerController() end
    if not valid(localController) or
        attempt(function() return localController:IsLocalPlayerController() end) ~= true then return nil end
    localPawn = attempt(function() return localController.Pawn end)
    if not valid(localPawn) then return nil end
    return localPawn
end
local function healthValues(pawn)
    return attempt(function()
        local attrs = pawn.AttributeSetBase
        if not valid(attrs) then return nil end
        local out={hp = attrs.Health.CurrentValue, max = attrs.Health_Max.CurrentValue}
        local fields={shield="Shield",shieldMax="Shield_Max",shachi="Shachi",shachiMax="Shachi_Max",
            ultimateCount="UltimateChargeCount",ultimateMax="UltimateChargeCount_Max",
            awakening="Awakening",awakeningMax="Awakening_Max",ignite="Ignite_Accumulation",
            poison="Poison_Accumulation",frost="Frost_Accumulation",thunder="Thunder_Accumulation",bleed="Bleed_Accumulation"}
        for key,field in pairs(fields) do out[key]=attempt(function() return attrs[field].CurrentValue end) end
        return out
    end)
end
local function observe(cause,damageCause)
    local pawn = resolvePlayer()
    local pawnId = id(pawn)
    if not pawnId then
        if lastPawn ~= nil then reset(); lastPawn = nil end
        return
    end
    if pawnId ~= lastPawn then
        reset(); lastPawn = pawnId
        log("local-pawn " .. tostring(attempt(function() return pawn:GetFullName() end)))
    end
    local values = healthValues(pawn)
    if values then
        local gen=state.generation
        local clocks=A.clocks(UEHelpers,pawn)
        state:health(pawnId, values.hp, values.max, cause,damageCause,clocks and clocks.real or os.time())
        if state.generation~=gen then
            combat:reset();vitals:reset();rumble:reset();consumed:reset();shots:reset()
            shotContext.stack={}
            executionActions={}
            use.actions,use.counts,use.stack={},{},{};use.epoch=use.epoch+1
        end
        vitals:sample(pawnId,values,state.generation)
    end
    if values and values.hp>0 then
        local input=A.movementInput(pawn,localController)
        vitals:movementInput(input)
        if not input or input.held==nil then notice("movement-input","movement-input-unavailable; waiting for a known input episode")
        elseif Config.Debug then notice("movement-input-ready","movement-input-ready native held-action episodes; no movement cooldown") end
    end
    if observeDash then observeDash() end
    if observeExecution then observeExecution() end
    local motion=attempt(function() local v=pawn:GetVelocity();return {mode=pawn.CharacterMovement.MovementMode,vz=v.Z,vx=v.X,vy=v.Y} end)
    if motion then vitals:motion(motion.mode==3,motion.vz) end
    if values and values.hp>0 then
        local pose=A.posture(pawn)
        if pose.stateError then notice("state-api","state-sampling-unavailable "..pose.stateError)
        elseif Config.Debug then notice("state-api-ready","state-sampling-ready jump/crouch; first pose is a silent baseline") end
        local floor,err=A.floorContact(pawn)
        freshGrounded=floor and floor.grounded
        pose.grounded=freshGrounded
        if not floor then notice("floor-api","landing-contact-unavailable "..tostring(err)) end
        if motion then pose.falling=motion.mode==3 end
        if motion and A.finite(motion.vx) and A.finite(motion.vy) then pose.speedXY=math.sqrt(motion.vx^2+motion.vy^2) end
        pose.dashActive=false;for _,record in pairs(dashAbilities) do if record.confirmed then pose.dashActive=true;break end end
        vitals:samplePosture(pose,state.generation)
    else vitals.posture=nil;freshGrounded=nil end
end
local function isLocal(obj)
    local pawn = resolvePlayer()
    return valid(pawn) and same(obj, pawn)
end
local function guarded(fn)
    return function(...)
        local ok, err = pcall(fn, ...)
        if not ok then log("callback-error " .. tostring(err)) end
        -- Never return a value: UE4SS can use it to replace game return values.
    end
end
local specs = {}
local function add(path, pre, post)
    specs[#specs + 1] = {path = path, pre = pre, post = post}
end
local function after(path, fn)
    -- Native paths use post; ProcessInternal script events use callback #2.
    add(path, nil, fn)
end
local function registerMissing()
    for _, spec in ipairs(specs) do
        if not hooks[spec.path] then
            local native = not spec.script
            local ok, a, b
            local waiting = false
            -- In this loader RegisterHook allocates its Lua state before target
            -- lookup. Don't repeatedly allocate hooks for unloaded Blueprints.
            if type(StaticFindObject)=="function" and not valid(attempt(StaticFindObject,spec.path)) then
                ok,a=false,"target not loaded; waiting"
                waiting = true
            elseif native then
                ok, a, b = pcall(RegisterHook, spec.path, guarded(spec.pre or function() end), guarded(spec.post or function() end))
            else
                ok, a, b = pcall(RegisterHook, spec.path, guarded(spec.post or function() end))
            end
            if ok and type(a) == "number" and type(b) == "number" then
                hooks[spec.path] = {a, b}; failed[spec.path] = nil
                if Config.Debug then log("hook-ready " .. spec.path) end
            else
                local status = waiting and "waiting" or "failed"
                if failed[spec.path] ~= status and (Config.Debug or not waiting) then
                    failed[spec.path] = status
                    local label = waiting and "hook-pending " or "hook-failed "
                    log(label .. spec.path .. ": " .. tostring(a))
                end
            end
        end
    end
end
local function scriptAfter(path, fn)
    after(path, fn); specs[#specs].script = true
end
local watchers={}
local function watchMissing()
    if type(NotifyOnNewObject)~="function" then return end
    local owners={}
    for _,spec in ipairs(specs) do
        if not hooks[spec.path] then owners[spec.path:match("^(.*):[^:]+$")]=true end
    end
    for owner in pairs(owners) do
        if not watchers[owner] then
            local ok,err=pcall(NotifyOnNewObject,owner,function()
                -- The pinned loader holds its unload mutex for object notices.
                -- Retry here, never mutate its script-hook vector from a Tick.
                local ready,result=pcall(function()
                    registerMissing()
                    for _,spec in ipairs(specs) do
                        if spec.path:match("^(.*):[^:]+$")==owner and not hooks[spec.path] then return false end
                    end
                    return true
                end)
                if not ready then notice("watch-error:"..owner,"hook-watch-error "..tostring(result));return false end
                if result then watchers[owner]=nil end
                return result -- true cancels this object's loader notification.
            end)
            if ok then watchers[owner]=true else notice("watch:"..owner,"hook-watch-unavailable "..tostring(err)) end
        end
    end
end
local function refineQueuedDamage(cause,amount,route)
    if not Config.Damage.DotCauses[cause] or not A.finite(amount) or amount<=0 then return end
    for _,queued in ipairs(feedback.queue) do
        local info=queued.damage
        if info and info.damageCause~=cause and queued.generation==state.generation and info.hpAfter==state.hp and math.abs(amount-info.amount)<0.0001 then
            info.damageCause=cause
            local effect,kind=Damage.content(Templates.PlayerDamage,info,Config.Damage)
            queued.content=effect;queued.meta={input="damage-"..kind,pulse_ms=contentDuration(effect),primary=true}
            if Config.Debug then log("damage-observe refined type="..kind.." amount="..info.amount.." cause="..cause.." route="..route) end
        end
    end
end
local damageTagLogCount,damageTagLogAt=0,0
local damageSourceLogCount,damageSourceLogAt=0,0
scriptAfter("/Script/ProjectPBZ.PBZCharacter:OnDamage", function(context,damageAmount,damageTags)
    if not isLocal(unwrap(context)) then return end
    local tags,tagError=A.damageTags(damageTags)
    local cause
    for _,tag in ipairs(tags) do if Config.Damage.DotCauses[tag] then cause=tag;break end end
    local amount=unwrap(damageAmount)
    observe("OnDamage/actual-HP",cause)
    refineQueuedDamage(cause,amount,"OnDamage/GameplayTags")
    if Config.Debug then
        local now=os.time()
        if damageTagLogCount<24 or now>damageTagLogAt then
            damageTagLogCount=damageTagLogCount+1;damageTagLogAt=now
            log("damage-tags route=OnDamage amount="..tostring(amount).." hp="..tostring(state.hp).." tags="..table.concat(tags,"|")..
                " selected="..tostring(cause)..(tagError and " error="..tostring(tagError):sub(1,200) or ""))
        end
    end
end)
scriptAfter("/Script/ProjectPBZ.PBZCharacter:OnHeal", function(context)
    if isLocal(unwrap(context)) then observe("OnHeal/actual-HP") end
end)
after("/Script/CharacterBasics.BasicAttributeSet:OnRep_Health", function(context)
    local pawn = resolvePlayer()
    if valid(pawn) and same(unwrap(context), attempt(function() return pawn.AttributeSetBase end)) then
        observe("OnRep_Health/actual-HP")
    end
end)
after("/Script/ProjectPBZ.PBZCharacter:PostInitializeCharacterData", function(context)
    if isLocal(unwrap(context)) then reset(); observe("initialization") end
end)
add("/Script/ProjectPBZ.PBZCharacter_Player:InitAttribute", function(context)
    if isLocal(unwrap(context)) then initializing=initializing+1;reset() end
end, function(context)
    if isLocal(unwrap(context)) then reset(); observe("InitAttribute/baseline");initializing=math.max(0,initializing-1) end
end)
after("/Script/ProjectPBZ.PBZHitTraceComponent:EnableHitTrace", function(context, _, owner)
    owner = unwrap(owner)
    if isLocal(owner) then
        observe("trace/baseline")
        state:traceStart(id(owner), id(unwrap(context)))
    end
end)
add("/Script/ProjectPBZ.PBZHitTraceComponent:DisableHitTrace", function(context)
    state:traceStop(id(unwrap(context)))
end)
after("/Script/ProjectPBZ.LGAAction_TraceHit:OnHitActor", function(_, trace, results)
    trace, results = unwrap(trace), unwrap(results)
    local traceId = id(trace)
    if not traceId or not state.traces[traceId] then return end
    local pawn = resolvePlayer()
    if id(pawn) ~= state.pawn then return end
    local hasOther = false
    if results then
        results:ForEach(function(_, hit)
            local actor = attempt(UEHelpers.GetActorFromHitResult, unwrap(hit))
            if valid(actor) and not same(actor, pawn) then hasOther = true end
        end)
    end
    state:traceHit(id(pawn), traceId, hasOther)
end)
scriptAfter("/Script/ProjectPBZ.LGAAction_CheckParry:NotifyParrayResultDetermine", function(context)
    state:parryBegin(id(unwrap(context)))
end)
scriptAfter("/Script/ProjectPBZ.LGAAction_CheckParry:NotifyParrayImpact", function(context, attacker, defender, result)
    defender = unwrap(defender)
    if not isLocal(defender) then return end
    observe("parry/baseline")
    state:parry(id(unwrap(context)), id(defender), id(unwrap(attacker)), tonumber(unwrap(result)))
end)
-- The current SGame combat system does not require the legacy PBZHitTrace
-- window. DamageTakenPayload exists after damage settlement, unlike Pretake.
local combatObserved={}
local contactSamples={generation=nil,count=0}
local comboSamples={generation=nil,count=0}
local function combatLog(key,message)
    if not Config.Debug or combatObserved[key] then return end
    combatObserved[key]=true
    log("combat-observe "..message)
end
local function damagePayload(payload,sourceActor)
    payload,sourceActor=unwrap(payload),unwrap(sourceActor)
    if not valid(payload) then return end
    if Config.Combat and Config.Combat.PreferContactNotifications then return end
    local label=attempt(function() return payload:GetFullName() end) or ""
    if not label:match("^DamageTakenPayload ") or label:find("Default__",1,true) then return end
    if not isLocal(sourceActor) then return end
    local target=attempt(function() return payload.TargetActor end)
    local hp=valid(target) and attempt(function() return target.AttributeSetBase.Health.CurrentValue end)
    if not valid(target) or same(target,localPawn) or not A.finite(hp) then
        combatLog("damage-target","damage-payload rejected: target is self or has no character HP")
        return
    end
    observe("damage-payload/baseline")
    combat:damage(id(payload).."|"..label,id(sourceActor),id(target),hp,state.generation)
end
after("/Script/SGameAttributes.DamageTakenPayload:GetDamageSourceOwner",function(context,result)
    combatLog("damage-owner","DamageTakenPayload:GetDamageSourceOwner callback reached")
    damagePayload(context,result)
end)
after("/Script/SGameAttributes.DamageTakenPayload:GetTargetAttributesModification",function(context,result)
    -- Read the map only while the native ReturnValue frame owns it. The
    -- loader's ordinary Lua return table contains unowned parameter views.
    A.captureHealthModification(context,result)
end)
local function contact(source,target,route,damageCause,settledHealthLoss,settledPayload)
    if Config.Debug then combatLog("entry:"..route,"callback reached route="..route) end
    local bullet,owner,lifetime=A.bulletSource(source)
    target=unwrap(target)
    if not isLocal(owner) then
        if Config.Debug then
            combatLog("owner:"..route,"contact filtered route="..route.." owner="..tostring((attempt(function() return owner:GetFullName() end)))..
                " source="..tostring((attempt(function() return unwrap(source):GetFullName() end))))
        end
        return
    end
    if not valid(target) or same(target,owner) then
        if Config.Debug then combatLog("target:"..route,"contact filtered route="..route.." invalid/self target") end
        return
    end
    local settled=false
    if route=="GA_CommonUtilitiesPassive.OnTaken" then
        if A.nonDirectDamage(damageCause) then
            if Config.Debug then combatLog("cause:"..tostring(damageCause),"contact filtered non-direct cause="..tostring(damageCause)) end
            return
        end
        if not A.realBullet(bullet) then
            if Config.Debug then combatLog("non-bullet:"..route,"contact filtered: damage source is not a verified bullet") end
            return
        end
        settled=A.finite(settledHealthLoss) and settledHealthLoss>0
            and A.isA(unwrap(source),"/Script/SGameCombatSystem.BulletAttackModule")
    end
    local usable,reason=A.bulletUsable(bullet)
    if not usable then
        if settled and reason=="inactive-status-3" then
            combatLog("late-deactivated-settlement","accepted direct health settlement after source deactivation")
        else
            if Config.Debug then combatLog("inactive:"..route,"contact filtered route="..route.." reason="..reason) end
            return
        end
    end
    if route=="GA_CommonUtilitiesPassive.OnTaken" then
        if not A.inAttackFrame(owner) then
            -- Damage may settle after the attack-frame state has ended.
            -- A typed attack module plus an accepted negative Health modifier
            -- proves that contact without relying on the player's current pose.
            if not settled then
                if Config.Debug then combatLog("no-attack-frame:"..route,"contact filtered: local InAttackFrame inactive; no confirmed attack-module health settlement; cause="..tostring(damageCause)) end
                return
            end
            if Config.Debug then combatLog("late-attack-settlement","accepted attack-module health settlement after InAttackFrame; amount="..settledHealthLoss) end
        end
    end
    local label=attempt(function() return target:GetFullName() end) or ""
    if label:find("Default__",1,true) then return end
    observe("bullet-contact/baseline")
    if not state.hp or state.hp<=0 then return end
    if Config.Debug then combatLog("contact:"..route,"local contact route="..route.." target="..label) end
    local settlement
    if settled and valid(settledPayload) then
        local payloadId=id(settledPayload)
        if payloadId then
            local hp=attempt(function() return unwrap(target.AttributeSetBase.Health.CurrentValue) end)
            if not A.finite(hp) or hp<0 then hp=nil end
            settlement={payload=payloadId.."|"..tostring(attempt(function() return settledPayload:GetFullName() end)),hp=hp,loss=settledHealthLoss}
        end
    end
    local clocks=A.clocks(UEHelpers,localPawn)
    local accepted,decision=combat:contact(id(bullet),id(owner),id(target),state.generation,lifetime,"confirmed-contact/"..route,settlement,clocks and clocks.game)
    if Config.Debug and settlement then
        if comboSamples.generation~=state.generation then comboSamples={generation=state.generation,count=0} end
        if comboSamples.count<24 then
            comboSamples.count=comboSamples.count+1
            log("contact-settlement decision="..tostring(decision).." accepted="..tostring(accepted).." hp="..tostring(settlement.hp)..
                " loss="..settlement.loss.." bullet="..tostring(id(bullet)).." lifetime="..tostring(lifetime).." payload="..settlement.payload.." target="..label)
        end
    end
end
-- OnTaken is the Blueprint notification used by the common character passive.
-- It carries DamageTakenPayload directly; no reliance on a native getter being
-- called via ProcessEvent. Consume every struct/interface view in this callback.
scriptAfter("/PBZCombatAsset/Prototypes/Abilities/GA_CommonUtilitiesPassive.GA_CommonUtilitiesPassive_C:OnTaken",function(_,event)
    combatLog("taken-entry","callback reached route=GA_CommonUtilitiesPassive.OnTaken")
    event=unwrap(event)
    local found=false
    for _,field in ipairs({"OptionalObject","OptionalObject2"}) do
        local payload=event and unwrap(attempt(function() return event[field] end))
        local label=valid(payload) and attempt(function() return payload:GetFullName() end) or ""
        if label:match("^DamageTakenPayload ") and not label:find("Default__",1,true) then
            found=true
            local target=attempt(function() return payload.TargetActor end)
            local cause=attempt(function() return A.name(payload.DamageCause.TagName) end)
            local source=attempt(function() return payload.DamageSource end)
            local readOK,settledHealthLoss=pcall(A.healthModification,payload)
            local readError
            if not readOK then
                readError=tostring(settledHealthLoss)
                settledHealthLoss=nil
                notice("damage-modifier-read","damage-modifier-read-failed "..readError)
            end
            if Config.Debug then
                local bullet,owner,lifetime=A.bulletSource(source)
                if isLocal(owner) and valid(target) and not same(target,owner) then
                    if contactSamples.generation~=state.generation then contactSamples={generation=state.generation,count=0} end
                    if contactSamples.count<12 then
                        contactSamples.count=contactSamples.count+1
                        log("contact-sample route=OnTaken status="..tostring(attempt(function() return bullet.BulletStatus end))..
                            " attack_frame="..tostring(A.inAttackFrame(owner)).." settled_loss="..tostring(settledHealthLoss)..
                            " cause="..tostring(cause).." lifetime="..tostring(lifetime)..
                            " source="..tostring(attempt(function() return unwrap(source):GetFullName() end))..
                            " target="..tostring(attempt(function() return target:GetFullName() end))..
                            (readError and " modifier_error="..readError or ""))
                    end
                end
            end
            if isLocal(target) then
                local info=A.damageSource(source,Config.Damage.DotCauses,Config.Damage.EffectCauses)
                local originalCause=cause
                local policy
                if cause==nil or cause=="" or cause=="None" then
                    cause=info.cause or cause
                    if not info.cause and #info.tags==0 then
                        policy=Config.Damage.UnclassifiedEffectPolicies and Config.Damage.UnclassifiedEffectPolicies[info.classPath]
                        cause=policy or cause
                    end
                end
                observe("DamageTaken/local-HP",cause)
                -- An earlier same-frame OnDamage callback may have queued the
                -- HP delta without its cause. Refine only an unsent matching
                -- delta; never emit the same damage again.
                refineQueuedDamage(cause,settledHealthLoss,"OnTaken/DamageCause")
                if Config.Debug then
                    local now=os.time()
                    if damageSourceLogCount<24 or now>damageSourceLogAt then
                        damageSourceLogCount=damageSourceLogCount+1;damageSourceLogAt=now
                        log("damage-source amount="..tostring(settledHealthLoss).." payload_cause="..tostring(originalCause)..
                            " selected="..tostring(cause).." source="..tostring(info.label).." class="..tostring(info.classPath)..
                            " tags="..table.concat(info.tags,"|").." effect="..tostring(info.effect).." policy="..tostring(policy)..
                            (info.error and " error="..tostring(info.error):sub(1,200) or ""))
                    end
                end
            end
            contact(source,target,"GA_CommonUtilitiesPassive.OnTaken",cause,settledHealthLoss,payload)
        end
    end
    if not found then combatLog("taken-no-payload","OnTaken filtered: no DamageTakenPayload in OptionalObject/OptionalObject2") end
end)
scriptAfter("/Game/PBZContent/Blueprint/Physics/ChaosSpawner/Base/BP_ChaosMaster_Spawner.BP_ChaosMaster_Spawner_C:OnBulletHit",function(context,source,_,component)
    component=unwrap(component)
    local target=valid(component) and attempt(function() return component:GetOwner() end) or unwrap(context)
    contact(source,target,"ChaosMaster.OnBulletHit")
end)
scriptAfter("/Game/PBZContent/Blueprint/Physics/ChaosSpawner/Base/BP_ChaosMaster_MultipleSpawner.BP_ChaosMaster_MultipleSpawner_C:OnBulletHit",function(context,source,_,component)
    component=unwrap(component)
    local target=valid(component) and attempt(function() return component:GetOwner() end) or unwrap(context)
    contact(source,target,"ChaosMasterMultiple.OnBulletHit")
end)
scriptAfter("/SGameCombatSystem/Bullet/Event/BP_BulletEvent_HitEffect.BP_BulletEvent_HitEffect_C:Trigger",function(_,source,data)
    data=unwrap(data)
    local target=data and attempt(function() return data.EventActor end)
    if not valid(target) then
        target=data and attempt(function() return data.EventBody.Component:GetOwner() end)
    end
    contact(source,target,"BP_BulletEvent_HitEffect")
end)
after("/Script/SGameCombatSystem.HitreactEffectPlayerBase:PlayHit",function(context,source,_,_,_,component)
    combatLog("play-hit-entry","callback reached route=HitreactEffectPlayerBase.PlayHit")
    local player=unwrap(context)
    local label=valid(player) and attempt(function() return player:GetFullName() end) or ""
    if label:find("BP_DeflectEffectPlayer_",1,true) then return end
    component=unwrap(component)
    local target=valid(component) and attempt(function() return component:GetOwner() end)
    contact(source,target,"HitreactEffectPlayerBase.PlayHit")
end)
after("/Script/SGameCombatSystem.BulletModuleBase:OnBulletDeactivated",function(context)
    local bullet=attempt(function() return unwrap(context).Bullet end)
    combat:bulletReset(id(bullet))
    local key=id(bullet)
    if key then shots:deactivate(key) end
end)
after("/Script/SGameCombatSystem.BulletModuleBase:OnBulletReactivated",function(context)
    local bullet=attempt(function() return unwrap(context).Bullet end)
    combat:bulletReset(id(bullet))
    local key=id(bullet)
    if key then shots:reactivate(key) end
end)

-- Both Blueprint entry points are used by PBZ. A nested wrapper is one
-- dispatch; independent dispatches in the same frame remain independent.
local dispatches={}
local function eventBegin(_,actor,tag,payload)
    actor,tag,payload=unwrap(actor),unwrap(tag),unwrap(payload)
    local name=tag and A.name(attempt(function() return tag.TagName end))
    local function payloadId(field)
        return tostring(id(payload and attempt(function() return unwrap(payload[field]) end)))
    end
    local localDefender=Combat.defenseTags[name]~=nil and isLocal(actor)
    -- All parameter wrappers are consumed inside this callback. Native pre/post
    -- hook storage must not retain FGameplayEventData or FGameplayTag views.
    if name=="GameplayEvent.Damage.Taken" and not (Config.Combat and Config.Combat.PreferContactNotifications) then
        for _,field in ipairs({"OptionalObject","OptionalObject2"}) do
            local object=payload and attempt(function() return unwrap(payload[field]) end)
            if valid(object) then damagePayload(object,attempt(function() return object:GetDamageSourceOwner() end)) end
        end
    end
    dispatches[#dispatches+1]={localDefender=localDefender,pawn=id(localPawn),tag=name,generation=state.generation,
        key=tostring(id(actor)).."|"..tostring(name).."|"..payloadId("Instigator").."|"..payloadId("Target")..
            "|"..payloadId("OptionalObject").."|"..payloadId("OptionalObject2")}
end
local function eventEnd()
    local record=table.remove(dispatches)
    if not record or record.done or record.generation~=state.generation then return end
    local name=record.tag
    if Combat.defenseTags[name] and record.localDefender and record.pawn==id(resolvePlayer()) and
        not (Config.Combat and Config.Combat.PreferImpactNotifications) then
        observe("deflect-settlement/baseline")
        if state.hp and state.hp>0 then
            for _,parent in ipairs(dispatches) do if parent.key==record.key then parent.done=true end end
            combatLog(name,"local defender settlement "..name)
            emit(Combat.defenseTags[name],name,state.generation)
        end
    end
end
add("/Script/GameplayAbilities.AbilitySystemBlueprintLibrary:SendGameplayEventToActor",eventBegin,eventEnd)
add("/Script/ProjectPBZ.PBZAbilityBlueprintLibrary:SendGameplayEventToActorWithReturn",eventBegin,eventEnd)
scriptAfter("/PBZDeflectSystem/BPL_DeflectUtils.BPL_DeflectUtils_C:Send Impact Event",function(_,ability,result)
    result=unwrap(result)
    local defender=result and attempt(function() return result.DefenderAvatar end)
    if not isLocal(defender) then return end
    local tag=attempt(function() return A.name(result.DeflectResult.TagName) end) or "unknown"
    if Config.Debug then combatLog("impact:"..tag,"Send Impact Event result="..tag.." IsHit="..tostring(unwrap(result.IsHit))) end
    if not (Config.Combat and Config.Combat.PreferImpactNotifications) then return end
    local bullet,source,lifetime=A.bulletSource(attempt(function() return result.SourceBullet end))
    source=valid(source) and source or attempt(function() return result.SourceAvatar end)
    local hitTime=attempt(function() return unwrap(result.HitGameTime) end)
    observe("deflect-impact/baseline")
    if state.hp and state.hp>0 then
        combat:deflect(id(bullet),id(source),id(defender),hitTime,tag,state.generation,lifetime)
    end
end)
local assetSerial=0
local unsupportedAssets={}
after("/Script/Engine.PlayerController:ClientPlayForceFeedback_Internal", function(context, effect, params)
    if not same(unwrap(context), localController) then resolvePlayer() end
    if not same(unwrap(context), localController) then return end
    rumbleRequests.asset=rumbleRequests.asset+1
    effect = unwrap(effect)
    local fullName = valid(effect) and attempt(function() return effect:GetFullName() end)
    local path = fullName and fullName:match("^[^ ]+ (.+)$")
    if not path or A.blockedSource(path) or (Config.Rumble.ExcludedAssets or {})[path] then return end
    if Config.Debug then notice("rumble-asset:"..path,"rumble-capture asset="..path) end
    local route=Routes[path]
    if route and not Config.Events[route.name] then return end
    local clocks=valid(localPawn) and A.clocks(UEHelpers,localPawn)
    local settings=attempt(function() return {enabled=localController.bForceFeedbackEnabled,scale=localController.ForceFeedbackScale} end)
    if not settings then notice("rumble-settings","rumble-settings-unavailable: controller force-feedback settings could not be read") end
    if not clocks then
        local _,err=A.clocks(UEHelpers,localPawn);notice("rumble-clock","rumble-clock-unavailable "..tostring(err))
    end
    local mirrorDisabled=Config.Rumble.MirrorWhenGameFeedbackDisabled==true
    if Config.Debug and settings and settings.enabled~=true then notice("rumble-disabled","rumble-game-motors-disabled; vest mirror="..tostring(mirrorDisabled)) end
    if Config.Rumble.Enabled and clocks and params and settings and (settings.enabled==true or mirrorDisabled) then
        local data,err=A.asset(effect,unwrap(params),route)
        if data then
            assetSerial=assetSerial+1
            if observeExecution then observeExecution() end
            if rumble:asset("A:"..assetSerial,data,clocks) then
                if Config.Debug then
                    local keyCount,first,last=0,nil,nil
                    for _,channel in ipairs(data.channels) do
                        for _,key in ipairs(channel.curve.keys or {}) do
                            keyCount=keyCount+1;first=math.min(first or key.time,key.time);last=math.max(last or key.time,key.time)
                        end
                    end
                    notice("rumble-source:"..path,"rumble-source duration="..data.duration.." loop="..tostring(data.loop)..
                        " channels="..#data.channels.." keys="..keyCount.." key_first="..tostring(first).." key_last="..tostring(last)..
                        " tag="..tostring(data.tag).." game_feedback_enabled="..tostring(settings and settings.enabled)..
                        " force_scale="..tostring(settings and settings.scale).." source="..path)
                end
                return
            end
        elseif not unsupportedAssets[path] then
            unsupportedAssets[path]=true;log("rumble-asset-fallback "..path..": "..tostring(err))
        end
        if not data then
            local tag=A.name(unwrap(params).Tag)
            if tag and tag~="None" and tag~="" then rumble:stopAsset(nil,tag) end
        end
    end
    if route then
        local p=params and unwrap(params)
        if p and unwrap(p.bLooping)==true then
            local tag=A.name(p.Tag)
            local key=path..":"..tostring(tag)
            if fallbackLoops[key] then return end
            fallbackLoops[key]={path=path,tag=tag}
        end
        emit(route.name,"game-force-feedback-cue/fixed-fallback",state.generation)
    end
end)
after("/Script/Engine.PlayerController:ClientStopForceFeedback",function(context,effect,tag)
    if not same(unwrap(context),localController) then return end
    effect=unwrap(effect)
    local path=valid(effect) and attempt(function() return effect:GetFullName():match("^[^ ]+ (.+)$") end) or nil
    tag=A.name(tag)
    rumble:stopAsset(path,tag)
    for key,entry in pairs(fallbackLoops) do
        if (not path or entry.path==path) and (not tag or tag=="None" or tag=="" or entry.tag==tag) then fallbackLoops[key]=nil end
    end
end)
after("/Script/Engine.PlayerController:PlayDynamicForceFeedback",function(context,intensity,duration,ll,ls,rl,rs,action,latent)
    if not same(unwrap(context),localController) then resolvePlayer() end
    if not same(unwrap(context),localController) then return end
    rumbleRequests.dynamic=rumbleRequests.dynamic+1
    if Config.Debug then notice("rumble-dynamic-input","rumble-capture dynamic request reached local controller") end
    if not Config.Rumble.MirrorUnknownDynamic or not valid(localPawn) then return end
    latent=unwrap(latent)
    local target=latent and unwrap(latent.CallbackTarget)
    local uuid=latent and unwrap(latent.UUID)
    if not id(target) or not A.finite(uuid) then notice("rumble-latent","rumble-skip invalid latent callback identity");return end
    if A.blockedSource(A.name(latent.ExecutionFunction)) then return end
    local clocks,clockError=A.clocks(UEHelpers,localPawn)
    if clocks then
        rumble:dynamic("D:"..id(localController)..":"..id(target)..":"..uuid,
            unwrap(intensity),unwrap(duration),{unwrap(ll)==true,unwrap(ls)==true,unwrap(rl)==true,unwrap(rs)==true},unwrap(action),clocks)
    else notice("rumble-clock","rumble-clock-unavailable "..tostring(clockError)) end
end)
after("/Script/Engine.Character:OnJumped",function(context)
    if not isLocal(unwrap(context)) then return end
    observe("OnJumped/baseline")
    local clocks=A.clocks(UEHelpers,localPawn)
    if state.hp and state.hp>0 then vitals:jump(clocks and clocks.game,state.generation) end
end)
local function jumpAbility(context,route)
    local ability=unwrap(context)
    local pawn=valid(ability) and attempt(function() return ability:GetAvatarActorFromActorInfo() end)
    if not isLocal(pawn) then return end
    observe("jump-ability/baseline")
    local confirmed,reason=A.confirmJumpAbility(ability,pawn)
    if Config.Debug then notice("jump-ability:"..route..":"..tostring(confirmed),"jump-observe route="..route.." confirmed="..tostring(confirmed).." "..reason) end
    if confirmed and state.hp and state.hp>0 then vitals:jump(nil,state.generation,"jump-ability-confirmed/"..route) end
end
scriptAfter("/PBZCombatAsset/Prototypes/Abilities/Base/BP_Jump_Base.BP_Jump_Base_C:K2_ActivateAbility",function(context)
    jumpAbility(context,"BP_Jump_Base")
end)
scriptAfter("/PBZCombatAsset/ActorData/Players/Hun/Abilities/GA_Hun_Jump.GA_Hun_Jump_C:K2_ActivateAbility",function(context)
    jumpAbility(context,"GA_Hun_Jump")
end)
local function landed(context)
    if not isLocal(unwrap(context)) then return end
    if state.hp and state.hp>0 then vitals:requestLand() end
    observe("landing/actual-state")
end
scriptAfter("/Script/Engine.Character:OnLanded",landed)
scriptAfter("/Game/RenewalContent/Actors/Players/BP_Renewal_Hun.BP_Renewal_Hun_C:OnLanded",landed)
local function distance(a,b)
    return math.sqrt((a.x-b.x)^2+(a.y-b.y)^2+(a.z-b.z)^2)
end
after("/Script/AdvancedSpecialMove.SpecialMoveComponent:AddOrUpdateHookMotionData",function(context,key,character,targetWS)
    character=unwrap(character);local component=unwrap(context)
    if not isLocal(character) or not same(attempt(function() return component:GetOwner() end),character) then return end
    observe("hook-target/baseline")
    local name=A.name(unwrap(key));local target=A.vector(attempt(function() return unwrap(targetWS).Translation end))
    local clocks=A.clocks(UEHelpers,character)
    if not name or name=="None" or not target or not clocks then return end
    local count=0;for _ in pairs(hookTargets) do count=count+1 end
    if count>=16 then hookTargets={} end
    hookTargets[name]={target=target,generation=state.generation,at=clocks.game}
    if Config.Debug then notice("grapple-target","grapple-observe TargetWS callback reached") end
end)
after("/Script/AdvancedSpecialMove.SpecialMoveUtilitiesLibrary:ApplyHookMotionSource",function(_,character,instance,duration)
    character=unwrap(character);duration=unwrap(duration)
    if not isLocal(character) or not A.finite(duration) or duration<=0 then return end
    observe("hook-motion/baseline")
    local name=A.name(unwrap(instance));local clocks=A.clocks(UEHelpers,character)
    local position=A.position(character)
    if not name or name=="None" or not clocks or not position then return end
    local target=hookTargets[name]
    if target and (target.generation~=state.generation or clocks.game-target.at<0 or clocks.game-target.at>2) then target=nil end
    hookRequest={instance=name,key="root:"..name,generation=state.generation,pawn=id(character),
        origin=position,target=target and target.target,at=clocks.game,expires=clocks.game+math.min(duration,15)+0.2}
    if Config.Debug then notice("grapple-apply","grapple-observe ApplyHookMotionSource reached; waiting for valid root motion and displacement") end
end)
local function observeGrapple(wallActive,observed,err)
    if not valid(localPawn) or not state.hp or state.hp<=0 or wallActive or next(wallActions) then
        hookTargets,hookRequest,grappleMotion={},nil,nil;return
    end
    local clocks=A.clocks(UEHelpers,localPawn)
    if not clocks or clocks.paused then return end
    local signal
    if hookRequest and hookRequest.instance then
        if hookRequest.generation~=state.generation or hookRequest.pawn~=id(localPawn) or clocks.game<hookRequest.at or clocks.game>hookRequest.expires then hookRequest=nil
        else
            local active=A.hookRootActive(localPawn,hookRequest.instance)
            if active==true then
                signal={active=true,root=true,key=hookRequest.key,origin=hookRequest.origin,target=hookRequest.target,route="named-root-motion"}
            elseif active==false then hookRequest=nil end
        end
    end
    if observed then
        if Config.Debug then notice("grapple-api-ready","grapple-observe native HookIK sampling ready") end
        if Config.Debug and observed.active then notice("grapple-ik-active","grapple-observe HookIK active; travel-root="..tostring(observed.root)) end
        if observed.active and not signal then observed.route="native-hook-ik";signal=observed end
    else notice("grapple-api:"..tostring(err),"grapple-observe sampling unavailable: "..tostring(err)) end
    if not signal or not signal.active then grappleMotion=nil;return end
    local position=A.position(localPawn)
    if not position then notice("grapple-position","grapple-observe actor location unavailable");return end
    local motion=grappleMotion
    -- Native source and IK observations can describe the same action. Join
    -- them until both are inactive rather than playing once for each route.
    if not motion or motion.generation~=state.generation then
        motion={generation=state.generation,origin=signal.origin or position,target=signal.target,emitted=false}
        grappleMotion=motion
    end
    local moved=distance(position,motion.origin)
    if signal.root~=true then motion.origin=position;return end
    local toward=not motion.target or distance(motion.origin,motion.target)-distance(position,motion.target)>=3
    if signal.root==true and moved>=3 and toward and not motion.emitted then
        motion.emitted=true
        vitals:wallBegin()
        if Config.Debug then log("grapple-observe confirmed route="..signal.route.." displacement="..moved) end
        emit("WallClimbStart","confirmed-hook-travel/"..signal.route,state.generation)
    end
end
local function dashKind(action)
    return A.isA(action,"/PBZDeflectSystem/Abilities/BP_PlayerDodge_Base.BP_PlayerDodge_Base_C")
        or A.isA(action,"/PBZCombatAsset/Prototypes/Abilities/Base/BP_SpecialDash_Base.BP_SpecialDash_Base_C")
end
observeDash=function()
    if not state.hp or state.hp<=0 then dashAbilities={};return end
    for key,record in pairs(dashAbilities) do
        local action=record.action
        local owner=valid(action) and A.abilityOwner(action)
        local running=valid(action) and attempt(function() return action:IsAbilityRunning() end)
        if record.generation~=state.generation or not valid(action) or running==false or not isLocal(owner) then dashAbilities[key]=nil
        else
            local timeline=attempt(function() return action["Current Dash Timeline"] end)
            record.confirmed=running==true and valid(timeline) and attempt(function() return action:IsPlayingTimeline(timeline) end)==true
            if record.confirmed and not record.emitted and state.hp and state.hp>0 then
                record.emitted=true
                local emitted=vitals:dash(key..":"..tostring(record.activation)..":"..state.generation,state.generation,"confirmed-dash/"..record.route)
                if Config.Debug then log("movement-observe "..(emitted and "dash-start" or "dash-joined-sprint").." route="..record.route.." activation="..tostring(record.activation).." held-input="..tostring(vitals.movementHeld)) end
            end
        end
    end
end
local function registerDashAbility(context,route)
    local action=unwrap(context)
    if not valid(action) or not dashKind(action) or not isLocal(A.abilityOwner(action)) then return end
    local key=id(action);local activation=attempt(function() return action.ActivationCount end)
    local previous=dashAbilities[key]
    if not previous or previous.activation~=activation or previous.generation~=state.generation then
        dashAbilities[key]={action=action,activation=activation,generation=state.generation,route=route,emitted=false}
    end
    observe("dash-ability/baseline") -- Confirmation runs before sprint pose sampling.
end
scriptAfter("/PBZDeflectSystem/Abilities/BP_PlayerDodge_Base.BP_PlayerDodge_Base_C:K2_ActivateAbility",function(context)
    registerDashAbility(context,"dodge-activate")
end)
scriptAfter("/PBZDeflectSystem/Abilities/BP_PlayerDodge_Base.BP_PlayerDodge_Base_C:Play 4 Way Rotation Timeline",function(context)
    registerDashAbility(context,"dodge-timeline")
end)
scriptAfter("/PBZDeflectSystem/Abilities/BP_PlayerDodge_Base.BP_PlayerDodge_Base_C:K2_OnEndAbility",function(context)
    dashAbilities[id(unwrap(context)) or false]=nil
end)
scriptAfter("/PBZCombatAsset/Prototypes/Abilities/Base/BP_SpecialDash_Base.BP_SpecialDash_Base_C:K2_ActivateAbility",function(context)
    registerDashAbility(context,"special-dash")
end)
scriptAfter("/PBZCombatAsset/Prototypes/Abilities/Base/BP_SpecialDash_Base.BP_SpecialDash_Base_C:K2_OnEndAbility",function(context)
    dashAbilities[id(unwrap(context)) or false]=nil
end)
observeExecution=function()
    local selected
    if not state.hp or state.hp<=0 then executionActions={} end
    for key,record in pairs(executionActions) do
        local info=A.executionInfo(record.action,localPawn)
        if record.generation~=state.generation or not info or info.activation~=record.activation then executionActions[key]=nil
        elseif not selected or record.real>selected.real then selected=record end
    end
    rumble:execution(selected and {key=selected.key,game=selected.game,real=selected.real,generation=selected.generation} or nil)
end
local function registerExecution(action,timeline)
    local info=A.executionInfo(action,resolvePlayer())
    if not info or info.timelineId~=id(timeline) then return false end
    observe("execution-timeline/baseline")
    info=A.executionInfo(action,localPawn)
    local clocks=A.clocks(UEHelpers,localPawn)
    if not info or info.timelineId~=id(timeline) or not clocks or not state.hp or state.hp<=0 then return false end
    local previous=executionActions[info.id]
    if not previous or previous.activation~=info.activation or previous.generation~=state.generation then
        executionActions[info.id]={action=action,activation=info.activation,key=info.key..":"..state.generation,
            generation=state.generation,game=clocks.game,real=clocks.real}
        if Config.Debug then log("execution-rumble active ability="..tostring(attempt(function() return action:GetFullName() end)).." activation="..info.activation) end
    end
    observeExecution()
    return true
end
local function wallStart(action,owner,cause)
    if not isLocal(owner) then return end
    observe("wall-traversal/baseline")
    local key=id(action)
    if not key or wallActions[key] or not state.hp or state.hp<=0 then return end
    wallActions[key]=true
    if not wallPulseActive then
        wallPulseActive=true
        vitals:wallBegin()
        if Config.Debug then log("wall-observe start confirmed cause="..tostring(cause)) end
        emit("WallClimbStart",cause,state.generation)
    end
end
local function wallKind(action)
    local allowed={
        ["/Script/AdvancedSpecialMove.SpecialMoveAbility_UpRunning"]=true,
        ["/Script/AdvancedSpecialMove.SpecialMoveAbility_Mantle"]=true,
        ["/Script/AdvancedSpecialMove.SpecialMoveAbility_PoseSearchUpRunning"]=true,
        ["/AdvancedSpecialMove/GA/GA_ASM_UpRunning_Base.GA_ASM_UpRunning_Base_C"]=true,
    }
    for path in pairs(allowed) do if A.isA(action,path) then return true end end
    local cls=attempt(function() return action:GetClass() end)
    for _=1,12 do
        if not valid(cls) then return false end
        local path=attempt(function() return cls:GetFullName():match("^[^ ]+ (.+)$") end)
        if allowed[path] then return true end
        cls=attempt(function() return cls:GetSuperStruct() end)
    end
    return false
end
after("/Script/AdvancedSpecialMove.SpecialMoveAbility_Standard:StartStandardSpecialMove",function(context,startTimeline)
    local action=unwrap(context)
    if not valid(action) or not valid(unwrap(startTimeline)) or not wallKind(action) then return end
    local owner=A.abilityOwner(action)
    local volume=A.wallVolume(action)
    if valid(volume) and attempt(function() return action:IsPlayingTimeline(unwrap(startTimeline)) end)==true then wallStart(action,owner,"standard-wall-traversal-started") end
end)
after("/Script/LegoAbility.LegoAbility:PlayTimeline",function(context,timeline)
    local action=unwrap(context);timeline=unwrap(timeline)
    if registerExecution(action,timeline) then return end
    if valid(action) and dashKind(action) then registerDashAbility(action,"play-timeline");return end
    if not valid(action) or not valid(timeline) or not wallKind(action) then return end
    local playing=attempt(function() return action:IsPlayingTimeline(timeline) end)
    local owner=A.abilityOwner(action)
    local volume=A.wallVolume(action)
    if playing==true and valid(volume) then wallStart(action,owner,"wall-timeline-is-playing") end
end)
after("/Script/LegoAbility.LegoAbility:EndTimeline",function(context,timeline)
    local action=unwrap(context);timeline=unwrap(timeline)
    local main=valid(action) and attempt(function() return action.MainTimeline end)
    if same(main,timeline) and attempt(function() return action:IsPlayingTimeline(timeline) end)==false then
        wallActions[id(action) or false]=nil
        if not next(wallActions) then wallPulseActive=false end
    end
end)
after("/Script/AdvancedSpecialMove.SpecialMoveAbilityBase:EndSpecialMove",function(context)
    local key=id(unwrap(context)) or false
    wallActions[key]=nil;wallAbilities[key]=nil
    if not next(wallActions) then wallPulseActive=false end
end)
scriptAfter("/AdvancedSpecialMove/GA/GA_ASM_UpRunning_Base.GA_ASM_UpRunning_Base_C:StateLoopIn",function(context)
    local action=unwrap(context)
    local owner=valid(action) and attempt(function() return action:GetAvatarActorFromActorInfo() end)
    wallStart(action,owner,"up-running-loop-entered")
end)
scriptAfter("/AdvancedSpecialMove/GA/GA_ASM_UpRunning_Base.GA_ASM_UpRunning_Base_C:StateLoopOut",function(context)
    local key=id(unwrap(context)) or false
    wallActions[key]=nil;wallAbilities[key]=nil
    if not next(wallActions) then wallPulseActive=false end
end)
local function stopWallAbility(action)
    local key=id(action)
    if not key then return end
    wallAbilities[key]=nil;wallActions[key]=nil
    if not next(wallAbilities) then wallFootTimes={} end
    if not next(wallActions) then wallPulseActive=false end
end
local function observeWalls(native)
    if not state.hp or state.hp<=0 then
        wallActions,wallAbilities,wallFootTimes={},{},{}
        wallPulseActive,wallIKPrevious=false,nil;return false
    end
    local active=false
    for key,record in pairs(wallAbilities) do
        local action=record.action
        local running=valid(action) and attempt(function() return action:IsAbilityRunning() end)
        local owner=valid(action) and A.abilityOwner(action)
        if record.generation~=state.generation or not valid(action) or running==false or not isLocal(owner) then
            wallAbilities[key]=nil;wallActions[key]=nil
        else
            local volume=A.wallVolume(action)
            local playing=false
            for _,field in ipairs({"MainTimeline","Start","StartFar","StartTimeline"}) do
                local timeline=attempt(function() return action[field] end)
                if valid(timeline) and attempt(function() return action:IsPlayingTimeline(timeline) end)==true then playing=true;break end
            end
            record.confirmed=running==true and playing and valid(volume)
            if record.confirmed then
                active=true
                wallStart(action,owner,"wall-ability-main-timeline/"..record.route)
            elseif Config.Debug and not record.reported then
                record.reported=true;log("wall-observe pending route="..record.route.." running="..tostring(running).." playing="..tostring(playing).." volume="..tostring(id(volume)))
            end
        end
    end
    if native then
        local current=freshGrounded~=true and native.upRunning==true and native.wallMoving==true and valid(native.volume)
        if wallIKPrevious==nil then
            wallIKPrevious=current
            if current then wallActions["native-wall"]=true;wallPulseActive=true;vitals:wallBegin() end
        else
            wallIKPrevious=current
            if current then
                wallStart(native.component,localPawn,"native-up-running-ik-start")
                wallActions["native-wall"]=true
                -- A single stable key tracks this source; no leaked component ID.
                wallActions[id(native.component) or false]=nil
            else wallActions["native-wall"]=nil end
        end
        active=active or current
    elseif wallActions["native-wall"] then active=true end
    if not next(wallActions) then wallPulseActive=false end
    if not active then wallFootTimes={} end
    return active
end
local function registerWallAbility(context,route)
    local action=unwrap(context)
    local owner=valid(action) and A.abilityOwner(action)
    if not isLocal(owner) then return end
    observe("wall-ability/baseline")
    local key=id(action);if not key then return end
    local activation=attempt(function() return action.ActivationCount end)
    local previous=wallAbilities[key]
    if previous and previous.activation~=activation then wallActions[key]=nil;wallFootTimes={};wallPulseActive=false end
    wallAbilities[key]={action=action,activation=activation,route=route,generation=state.generation}
    if Config.Debug then notice("wall-entry:"..route,"wall-observe ability callback reached route="..route) end
    observeWalls()
end
scriptAfter("/AdvancedSpecialMove/GA/GA_ASM_CommonStandard.GA_ASM_CommonStandard_C:StateStartIn",function(context)
    local action=unwrap(context)
    if wallKind(action) then registerWallAbility(action,"legacy-wall-start") end
end)
scriptAfter("/AdvancedSpecialMove/GA/GA_ASM_UpRunning_Base.GA_ASM_UpRunning_Base_C:K2_OnEndAbility",function(context)
    stopWallAbility(unwrap(context))
end)
scriptAfter("/AdvancedSpecialMove/GA/GA_SpecialMove_UpRunning_Base.GA_SpecialMove_UpRunning_Base_C:K2_ActivateAbility",function(context)
    registerWallAbility(context,"GA_SpecialMove_UpRunning_Base")
end)
scriptAfter("/Game/RenewalContent/Actors/SpecialMove/GA/GA_SpecialMove_UpRunning.GA_SpecialMove_UpRunning_C:K2_ActivateAbility",function(context)
    registerWallAbility(context,"GA_SpecialMove_UpRunning")
end)
scriptAfter("/AdvancedSpecialMove/GA/GA_SpecialMove_UpRunning_Base.GA_SpecialMove_UpRunning_Base_C:K2_OnEndAbility",function(context)
    stopWallAbility(unwrap(context))
end)
local function wallFootPlant(context,foot)
    local anim=unwrap(context)
    local owner=valid(anim) and attempt(function() return anim:TryGetPawnOwner() end)
    if not isLocal(owner) then return end
    local active=observeWalls()
    if Config.Debug then notice("wall-foot-entry:"..foot..":"..tostring(active),"wall-observe foot-plant="..foot.." active-wall="..tostring(active)) end
    if not active or not state.hp or state.hp<=0 then return end
    local clocks=A.clocks(UEHelpers,owner)
    if not clocks or clocks.paused then return end
    -- Parent/child anim Blueprints can forward the same notify. Join the same
    -- local foot at the same game time, retaining both feet in one frame.
    if wallFootTimes[foot]==clocks.game then return end
    wallFootTimes[foot]=clocks.game
    if initializing>0 then return end
    primarySinceSample=true
    if rumble.output=="ControllerRumble" then feedback:stopRumble("ControllerRumble",state.generation);rumble.output=nil end
    -- Derive a short lower-vest impulse from the existing validated resource.
    -- No new UUID/import and no electrical track. The original template stays intact.
    local sourceTrack=Templates.WallClimbStart.tracks[1]
    local points={};for _,point in ipairs(sourceTrack.index) do points[#points+1]=point end
    local effect={name="WallClimbStart",uuid="WallClimbStart",keep="False",priority=0,tracks={{
        start_time=0,end_time=90,stop_name="",start_intensity=40,end_intensity=40,intensity_mode="Const",
        action_type="Shake",once="False",interval=0,index=points}}}
    if Config.Debug then log("wall-observe contact="..foot.." game_time="..clocks.game) end
    feedback:enqueuePrimaryContent("WallClimbStart",effect,"actual-wall-foot-plant/"..foot,state.generation,
        {input="wall-foot-"..foot,pulse_ms=90})
end
scriptAfter("/HuaShira/Characters/Hero/Hero_Hun/Animation/PBZ_ABP_Hun_Base.PBZ_ABP_Hun_Base_C:AnimNotify_AN_FootPlant_Left",function(context)
    wallFootPlant(context,"left")
end)
scriptAfter("/HuaShira/Characters/Hero/Hero_Hun/Animation/PBZ_ABP_Hun_Base.PBZ_ABP_Hun_Base_C:AnimNotify_AN_FootPlant_Right",function(context)
    wallFootPlant(context,"right")
end)
scriptAfter("/HuaShira/Characters/TemplateBP/PBZ_ABP_Base_Template.PBZ_ABP_Base_Template_C:AnimNotify_AN_FootPlant_Left",function(context)
    wallFootPlant(context,"left")
end)
scriptAfter("/HuaShira/Characters/TemplateBP/PBZ_ABP_Base_Template.PBZ_ABP_Base_Template_C:AnimNotify_AN_FootPlant_Right",function(context)
    wallFootPlant(context,"right")
end)
do
    local function alive()
        return initializing==0 and state.hp and state.hp>0 and state.pawn==id(resolvePlayer())
    end
    local function snapshot(bullet,route)
        bullet=unwrap(bullet)
        local info,reason=A.projectileInfo(bullet,resolvePlayer())
        if not info then
            if Config.Debug then
                -- Log each concrete local source once so a new weapon can be
                -- classified from actual runtime evidence rather than its name.
                local owner=attempt(function() return bullet.BulletOwnerAvatar end)
                if isLocal(owner) then
                    local ability=attempt(function() return bullet.BulletSourceAbility end)
                    local label=attempt(function() return ability:GetFullName() end) or "unknown"
                    notice("shot-filter:"..route..":"..label..":"..tostring(reason),
                        "projectile-filter route="..route.." reason="..tostring(reason).." ability="..label)
                end
            end
            return nil
        end
        if Config.Debug then
            notice("shot-source:"..tostring(id(info.ability))..":"..info.dataId,
                "projectile-source kind="..info.kind.." ability="..tostring(attempt(function() return info.ability:GetFullName() end))..
                " data="..tostring(attempt(function() return bullet.BulletData:GetFullName() end)))
        end
        return info
    end
    local function group(info)
        if info.kind=="shadow-attack" then return "shadow:"..id(info.ability)..":"..info.activation end
        for index=#shotContext.stack,1,-1 do
            local record=shotContext.stack[index]
            if record.eligible and record.generation==state.generation and record.owner==id(info.owner)
                and (not record.ability or record.ability==id(info.ability)) then return record.group end
        end
        local clocks=A.clocks(UEHelpers,localPawn)
        -- Exact same-frame births from one ability activation form one volley.
        -- There is no elapsed-time cooldown; later frames and native batches
        -- remain independent. Without a source/clock use only bullet identity.
        if clocks and valid(info.ability) and A.finite(info.activation) then
            return "frame:"..id(info.ability)..":"..info.activation..":"..clocks.game
        end
        return "bullet:"..info.id
    end
    local function started(context,route)
        observe("projectile-start/baseline")
        if not alive() then return end
        local info=snapshot(context,route)
        if info then
            -- Running is freshly verified above. A pool can restart without
            -- forwarding its Reactivate notification through ProcessEvent.
            shots:reactivate(info.id)
            shots:start(info.id,group(info),state.generation,"confirmed-projectile-fire/"..route)
        end
    end
    local function initialize(context,owner)
        local bullet=unwrap(context);local key=id(bullet)
        if key and A.realBullet(bullet) and isLocal(unwrap(owner)) then shots:initialize(key) end
    end
    local function blueprintInitialize(context,_,owner)
        initialize(context,owner)
    end
    -- Never hook native BulletInterface methods: this loader receives their
    -- interface-this address as Context, then treats it as a UObject. Even
    -- context:get()/IsValid can fault before Lua error handling is reached.
    after("/Script/SGameCombatSystem.BulletModuleBase:OnBulletStarted",function(context)
        started(attempt(function() return unwrap(context).Bullet end),"BulletModule.OnBulletStarted")
    end)
    scriptAfter("/PBZCombatAsset/Prototypes/Bullet/Bullets/BP_PBZ_ProjectileBullet.BP_PBZ_ProjectileBullet_C:Received_Initialize",blueprintInitialize)
    scriptAfter("/PBZCombatAsset/Prototypes/Bullet/Bullets/BP_PBZ_ProjectileEmitter.BP_PBZ_ProjectileEmitter_C:Received_Initialize",blueprintInitialize)
    scriptAfter("/PBZCombatAsset/ActorData/Players/Hun/Bullets/BP_Bullet_Common_Head.BP_Bullet_Common_Head_C:Received_Initialize",blueprintInitialize)
    scriptAfter("/PBZCombatAsset/Prototypes/Bullet/Bullets/BP_PBZ_ProjectileBullet.BP_PBZ_ProjectileBullet_C:Received_PostStart",function(context)
        started(context,"BP_ProjectileBullet.PostStart")
    end)
    scriptAfter("/PBZCombatAsset/Prototypes/Bullet/Bullets/BP_PBZ_ProjectileEmitter.BP_PBZ_ProjectileEmitter_C:Received_PostStart",function(context)
        started(context,"BP_ProjectileEmitter.PostStart")
    end)
    scriptAfter("/PBZCombatAsset/ActorData/Players/Hun/Bullets/BP_Bullet_Common_Head.BP_Bullet_Common_Head_C:Received_PostStart",function(context)
        started(context,"BP_CommonHead.PostStart")
    end)
    add("/Script/SGameCombatSystem.BulletSpawnBurst:SpawnBullets",function(context,owner,ability,_,data)
        shotContext.sequence=shotContext.sequence+1
        local record={context=unwrap(context),eligible=false,generation=state.generation,
            group="native:"..shotContext.sequence}
        shotContext.stack[#shotContext.stack+1]=record -- Reserve a paired post even if pre fails.
        if isLocal(unwrap(owner)) then
            observe("projectile-burst/baseline")
            if shotContext.stack[#shotContext.stack]~=record then shotContext.stack[#shotContext.stack+1]=record end
            record.generation=state.generation;record.owner=id(unwrap(owner));record.ability=id(unwrap(ability))
            record.eligible=alive()
            ability,data=unwrap(ability),unwrap(data)
            local activation=valid(ability) and attempt(function() return ability.ActivationCount end)
            if record.ability and A.finite(activation) and
                A.isA(ability,"/PBZCombatAsset/Prototypes/Abilities/Base/BP_ShachiAbility_Base.BP_ShachiAbility_Base_C") and
                not A.isA(ability,"/PBZCombatAsset/Prototypes/Abilities/Base/BP_ShachiAbility_Base_Ranged.BP_ShachiAbility_Base_Ranged_C") and
                not A.isA(data,"/Script/PBZCombatAsset.PBZ_ProjectileBulletData") and
                not A.isA(data,"/Script/PBZCombatAsset.PBZ_ProjectileEmitterData") then
                -- A melee/martial weapon may create many attack volumes during
                -- one swing. Its activation gets one neutral weapon pulse.
                record.group="shadow:"..record.ability..":"..activation
            end
        end
    end,function(context,_,_,_,_,_,spawned)
        local record=shotContext.stack[#shotContext.stack]
        if not record or not same(record.context,unwrap(context)) then return end
        local ok,err=pcall(function()
            if not record.eligible or record.generation~=state.generation or not alive() then return end
            local ids={};local count=0;local observedGroup
            local array=unwrap(spawned)
            if array then array:ForEach(function(_,param)
                count=count+1;if count>256 then error("projectile batch exceeds bounded observation limit") end
                local info=snapshot(param,"BulletSpawnBurst.SpawnBullets")
                if info and (not record.ability or record.ability==id(info.ability)) then
                    shots:reactivate(info.id)
                    ids[#ids+1]=info.id
                    local actualGroup=info.kind=="shadow-attack" and ("shadow:"..id(info.ability)..":"..info.activation) or record.group
                    observedGroup=observedGroup==nil and actualGroup or (observedGroup==actualGroup and actualGroup or record.group)
                end
            end) end
            shots:burst(ids,observedGroup or record.group,state.generation,"confirmed-projectile-fire/BulletSpawnBurst.SpawnBullets")
        end)
        if shotContext.stack[#shotContext.stack]==record then table.remove(shotContext.stack) end
        if not ok then error(err) end
    end)
    scriptAfter("/Script/ProjectPBZ.LGAAction_LaunchProjectile:OnProjectileSpawned",function(_,projectile)
        projectile=unwrap(projectile)
        if A.realBullet(projectile) then started(projectile,"legacy-SGame-projectile");return end
        local owner=valid(projectile) and attempt(function() return projectile:GetOwner() end)
        if not isLocal(owner) then return end
        observe("legacy-projectile/baseline")
        if alive() then shots:start(id(projectile),"legacy:"..id(projectile),state.generation,"valid-local-owned-projectile-spawned") end
    end)
end
after("/Script/SGameExecution.ExecutionComponent:PerformExecution",function(context,result)
    -- This UE4SS native post-hook puts ReturnValue immediately after Context.
    local component=unwrap(context)
    local owner=valid(component) and attempt(function() return component:GetOwner() end)
    if isLocal(owner) and unwrap(result)==true then emit("ExecutionStart","PerformExecution-returned-true",state.generation) end
end)
local transactions={}
local function txKey(path,context) return path..":"..tostring(id(context)) end
local function push(path,context,record)
    local key=txKey(path,context);local stack=transactions[key] or {};transactions[key]=stack
    stack[#stack+1]=record
end
local function pop(path,context)
    local stack=transactions[txKey(path,context)]
    return stack and table.remove(stack) or nil
end
local function localInventory(component)
    local pawn=resolvePlayer()
    return valid(component) and valid(pawn) and same(attempt(function() return component:GetWorld() end),attempt(function() return pawn:GetWorld() end))
end
do
    local function now()
        local clocks=A.clocks(UEHelpers,localPawn)
        return clocks and clocks.real
    end
    local function itemName(item)
        local name=A.name(item)
        if name and name~="" and name~="None" then return name end
    end
    local function ready(component)
        return initializing==0 and inventoryInitializing==0 and state.hp and state.hp>0
            and state.pawn==id(resolvePlayer()) and localInventory(component)
    end
    local function pack()
        if not localInventory(backpack) then backpack=attempt(A.backpack,resolvePlayer()) end
        if localInventory(backpack) then return backpack end
    end
    local function count(component,kind,item)
        if not localInventory(component) then return nil end
        local value=attempt(function()
            if kind=="medicine" then
                local current,maximum,display={},{},{}
                -- The pinned loader writes scalar out values by parameter name.
                if component:GetCurrentMedicineNum(FName(item),current,maximum,display)==true then return current.CurrentNum end
            else return component:GetUsePropAmount(FName(item)) end
        end)
        if A.finite(value) and value>=0 then return value end
    end
    local function countKey(kind,item) return kind..":"..item end
    local function active(record)
        if record.epoch~=use.epoch or record.generation~=state.generation then return false end
        local clock=now()
        if clock and record.at and (clock<record.at or clock-record.at>8) then return false end
        return valid(record.ability) and isLocal(A.abilityOwner(record.ability))
            and attempt(function() return record.ability.ActivationCount end)==record.activation
            and attempt(function() return record.ability:IsAbilityRunning() end)==true
    end
    local function actionFor(item)
        local found
        for _,record in pairs(use.actions) do
            if record.item==item and active(record) and (not found or record.sequence>found.sequence) then found=record end
        end
        return found
    end
    healUseKey=function()
        for index=#use.stack,1,-1 do
            local record=use.stack[index]
            if record.eligible and record.epoch==use.epoch and record.generation==state.generation then return record.key end
        end
        local found
        for _,candidate in pairs(use.actions) do
            if active(candidate) then
                if found then return nil end -- Ambiguous HP ownership must remain a real healing cue.
                found=candidate
            end
        end
        return found and found.key
    end
    local function confirm(record,after,route)
        if record.epoch~=use.epoch or record.generation~=state.generation or not ready(record.component) then return end
        if not A.finite(record.before) or not A.finite(after) or after>=record.before or after<0 then return end
        local cache=countKey(record.kind,record.item)
        local previous=use.counts[cache]
        use.counts[cache]=after
        if previous~=nil and after>=previous then return end -- Native/HUD/poll share one consumption observation.
        if Config.Debug then log("consumable-observe kind="..record.kind.." item="..record.item.." amount="..record.before.."->"..after.." via="..route) end
        consumed:confirm(record.key,record.kind,record.item,record.before,after,record.generation,
            "actual-consumable-use/"..record.kind.."/"..record.item.."/"..route)
    end
    local function registerAction(context,requested)
        local ability=unwrap(context)
        if not valid(ability) or not isLocal(A.abilityOwner(ability)) then return end
        if requested~=nil and (not A.finite(requested) or requested<=0) then return end
        observe("consumable-action/baseline")
        local component=pack()
        if not ready(component) then return end
        local item=itemName(attempt(function() return ability["Current Medicine "] end))
        local activation=attempt(function() return ability.ActivationCount end)
        if not item or not A.finite(activation) then return end
        local kind="medicine";local before=count(component,kind,item)
        if before==nil then kind="prop";before=count(component,kind,item) end
        if before==nil then notice("consume-count","consumable-count-unavailable; waiting for a verified amount");return end
        local key=state.generation.."|"..id(ability).."|"..activation.."|"..item
        if use.actions[key] then return end
        use.sequence=use.sequence+1
        local record={key=key,kind=kind,item=item,before=before,component=component,ability=ability,
            activation=activation,generation=state.generation,epoch=use.epoch,at=now(),sequence=use.sequence}
        use.actions[key]=record;use.counts[countKey(kind,item)]=before
        consumed:begin(key,kind,item,before,state.generation,record.at)
        -- Reused abilities replace their previous activation, keeping UObject references bounded.
        for old,other in pairs(use.actions) do
            if old~=key and (same(other.ability,ability) or not active(other) or use.sequence-other.sequence>=128) then use.actions[old]=nil end
        end
        if Config.Debug then notice("consume-action","consumable-action-ready; activation is a candidate, actual quantity decrease confirms use") end
    end
    local function beginNative(context,item,num,kind)
        -- Reserve the paired post slot before any engine access. A failed pre
        -- must never leave its post able to consume an outer native use.
        local record={eligible=false,kind=kind,epoch=use.epoch,generation=state.generation}
        use.stack[#use.stack+1]=record
        local component=unwrap(context);item=itemName(item);num=unwrap(num)
        record.component=component
        if item and A.finite(num) and num>0 and localInventory(component) then
            if state.pawn~=id(resolvePlayer()) then
                observe("consumable-native/identity-baseline")
                -- Identity changes intentionally invalidate all old transactions.
                if use.stack[#use.stack]~=record then use.stack[#use.stack+1]=record end
            end
            if ready(component) then
                backpack=component
                local before=count(component,kind,item)
                if before~=nil then
                    local action=actionFor(item)
                    use.sequence=use.sequence+1
                    local parent=use.stack[#use.stack-1]
                    record.eligible=true;record.item=item;record.before=before
                    record.epoch=use.epoch;record.generation=state.generation;record.at=now()
                    record.parent=parent and parent.eligible and parent or nil
                    record.key=record.parent and record.parent.key or action and action.key or
                        (state.generation.."|native-use|"..use.sequence.."|"..item)
                    if not record.parent then
                        use.counts[countKey(kind,item)]=before
                        consumed:begin(record.key,kind,item,before,state.generation,record.at)
                    end
                end
            end
        end
    end
    local function endNative(kind,result,context)
        local record=use.stack[#use.stack]
        local component=unwrap(context)
        if not record or record.kind~=kind or (record.component~=component and not same(record.component,component)) then return end
        local ok,err=pcall(function()
            if record.eligible and record.epoch==use.epoch and record.generation==state.generation then
                if not record.parent and (kind=="medicine" or unwrap(result)==true) then
                    confirm(record,count(record.component,record.kind,record.item),"native-"..kind)
                end
                observe("consumable-settled/actual-HP") -- Keep the exact transaction key while sampling its HP gain.
            end
        end)
        if use.stack[#use.stack]==record then table.remove(use.stack) end
        if not ok then error(err) end
    end
    scriptAfter("/Game/PBZContent/Blueprint/Item/Ability/GA_UseItemActionBase.GA_UseItemActionBase_C:K2_ActivateAbility",function(context)
        registerAction(context)
    end)
    scriptAfter("/Game/PBZContent/Blueprint/Item/Ability/GA_UseItemActionBase.GA_UseItemActionBase_C:Use Item",function(context,num)
        registerAction(context,unwrap(num))
    end)
    add("/Script/ProjectPBZ.PBZBackPackSubsystem:UseMedicine",function(context,item,num)
        beginNative(context,item,num,"medicine")
    end,function(context) endNative("medicine",nil,context) end)
    add("/Script/ProjectPBZ.PBZBackPackSubsystem:UseProps",function(context,item,num)
        beginNative(context,item,num,"prop")
    end,function(context,result) endNative("prop",result,context) end)
    scriptAfter("/Game/PBZContent/UI/UINew/HUD/WB_quickslot.WB_quickslot_C:UseMedicineDelegate_Event",function(context,item,current,kind)
        local widget=unwrap(context);item=itemName(item);current=unwrap(current);kind=unwrap(kind)
        if not valid(widget) or not same(attempt(function() return widget:GetOwningPlayer() end),localController) or not item or (kind~=0 and kind~=1) then return end
        local component=pack()
        if not ready(component) then return end
        local after=count(component,"medicine",item)
        if after~=current then return end
        local cache=countKey("medicine",item);local before=use.counts[cache]
        if before==nil then use.counts[cache]=after;return end
        if after>=before then use.counts[cache]=after;return end
        local record
        for index=#use.stack,1,-1 do
            local pending=use.stack[index]
            if pending.eligible and pending.epoch==use.epoch and pending.generation==state.generation
                and pending.kind=="medicine" and pending.item==item then record=pending.parent or pending;break end
        end
        record=record or actionFor(item)
        if not record then
            use.sequence=use.sequence+1
            record={key=state.generation.."|hud-use|"..use.sequence.."|"..item,kind="medicine",item=item,before=before,
                component=component,epoch=use.epoch,generation=state.generation,at=now()}
            consumed:begin(record.key,record.kind,item,before,state.generation,record.at)
        end
        confirm(record,after,"hud-use-notification")
    end)
    observeUses=function(seed)
        if initializing>0 or inventoryInitializing>0 or not state.hp or state.hp<=0 then
            if next(use.actions) or next(use.counts) then
                use.actions,use.counts,use.stack={},{},{};use.epoch=use.epoch+1;consumed:reset()
            end
            return
        end
        for key,record in pairs(use.actions) do
            if active(record) then
                confirm(record,count(record.component,record.kind,record.item),"local-action-quantity")
            end
            if not active(record) then use.actions[key]=nil end
        end
        if seed then
            local component=pack()
            if ready(component) then
                attempt(function() component.MedicineInfos:ForEach(function(key)
                    local item=itemName(key)
                    if item then use.counts[countKey("medicine",item)]=count(component,"medicine",item) end
                end) end)
            end
        end
    end
end
local function sampleInventory(component,cause)
    if Config.Inventory and Config.Inventory.LegacyGrantFallback then return end
    local pawn=resolvePlayer()
    if inventoryInitializing>0 or initializing>0 or not valid(pawn) or state.pawn~=id(pawn) or not state.hp or state.hp<=0 then
        inventoryState=nil;return
    end
    if localInventory(component) then backpack=component end
    if not localInventory(backpack) then
        backpack=nil
        local ok,value=pcall(A.backpack,pawn)
        if ok then backpack=value
        else notice("inventory-resolve","inventory-unavailable "..tostring(value)) end
    end
    local ok,current=pcall(A.inventorySnapshot,backpack,pawn)
    if not ok then notice("inventory-read","inventory-read-unavailable "..tostring(current));return end
    if not current.counts and current.coin==nil and current.dust==nil then return end
    local identity=tostring(id(pawn)).."|"..tostring(id(backpack)).."|"..state.generation
    local previous=inventoryState
    inventoryState={identity=identity,counts=current.counts,coin=current.coin,dust=current.dust}
    if not previous or previous.identity~=identity then
        if Config.Debug then log("inventory-ready entries="..tostring(current.entries).." coin="..tostring(current.coin).." dust="..tostring(current.dust).."; first snapshot is silent") end
        return
    end
    -- Commit all scalar observations before emitting. Native grant callbacks,
    -- Blueprint pickup completion and polling consume the same baseline.
    if current.counts and previous.counts then
        local names={};for name in pairs(current.counts) do names[#names+1]=name end;table.sort(names)
        for _,name in ipairs(names) do
            local old,amount=previous.counts[name] or 0,current.counts[name]
            if amount>old then
                if Config.Debug then log("inventory-observe item="..name.." amount="..old.."->"..amount.." via="..cause) end
                emit("ItemCollected","actual-inventory-increase/"..name,state.generation)
            end
        end
    end
    if A.finite(previous.coin) and A.finite(current.coin) and current.coin>previous.coin then
        if Config.Debug then log("inventory-observe coin="..previous.coin.."->"..current.coin.." via="..cause) end
        emit("ItemCollected","actual-coin-increase",state.generation)
    end
    if A.finite(previous.dust) and A.finite(current.dust) and current.dust>previous.dust then
        if Config.Debug then log("inventory-observe dust="..previous.dust.."->"..current.dust.." via="..cause) end
        emit("ItemCollected","actual-consciousness-dust-increase",state.generation)
    end
end
local function inventoryBegin(context,item,allowed)
    local component=unwrap(context);item=unwrap(item)
    if not (Config.Inventory and Config.Inventory.LegacyGrantFallback) then
        if Config.Debug then notice("inventory-native-grant","inventory-callback native grant reached; UI flag does not gate actual amount monitoring") end
        sampleInventory(component,"native-grant-before");return
    end
    local count
    if allowed and inventoryInitializing==0 and localInventory(component) and state.hp and state.hp>0 then
        count=attempt(A.inventoryCount,component,item)
        if count==nil then notice("inventory-api","inventory-sampling-unavailable: Inventories/CurrentAmount could not be read") end
    end
    push("inventory",component,{count=count,item=item,pawn=id(localPawn),generation=state.generation})
end
local function inventoryEnd(context)
    local component=unwrap(context);local record=pop("inventory",component)
    if not (Config.Inventory and Config.Inventory.LegacyGrantFallback) then sampleInventory(component,"native-grant-after");return end
    if not record or record.count==nil or inventoryInitializing>0 or record.generation~=state.generation or record.pawn~=id(resolvePlayer()) then return end
    local count=attempt(A.inventoryCount,component,record.item)
    if A.finite(count) and count>math.max(record.count,record.coveredThrough or 0) then
        for _,parent in ipairs(transactions[txKey("inventory",component)] or {}) do
            if parent.count~=nil and A.name(parent.item)==A.name(record.item) and parent.generation==record.generation then
                parent.coveredThrough=math.max(parent.coveredThrough or parent.count,count)
            end
        end
        emit("ItemCollected","visible-inventory-grant/amount-increased",state.generation)
    end
end
add("/Script/ProjectPBZ.PBZBackPackSubsystem:AddPropsToBackPack",function(context,num,item,show)
    inventoryBegin(context,item,A.finite(unwrap(num)) and unwrap(num)>0 and unwrap(show)==true)
end,inventoryEnd)
add("/Script/ProjectPBZ.PBZBackPackSubsystem:AddWeaponItem",function(context,item,_,show,loading)
    inventoryBegin(context,item,unwrap(show)==true and unwrap(loading)==false)
end,inventoryEnd)
add("/Script/ProjectPBZ.PBZBackPackSubsystem:PushMedicineToInventory",function(context,item,_,show)
    inventoryBegin(context,item,unwrap(show)==true)
end,inventoryEnd)
local function inventoryLoadBegin()
    inventoryInitializing=inventoryInitializing+1;inventoryState=nil
    use.actions,use.counts,use.stack={},{},{};use.epoch=use.epoch+1;consumed:reset()
end
local function inventoryLoadEnd() inventoryInitializing=math.max(0,inventoryInitializing-1);inventoryState=nil end
add("/Script/ProjectPBZ.PBZBackPackSubsystem:LoadGame",inventoryLoadBegin,inventoryLoadEnd)
add("/Script/ProjectPBZ.PBZBackPackSubsystem:InitItemList",inventoryLoadBegin,inventoryLoadEnd)
add("/Script/ProjectPBZ.PBZBackPackSubsystem:PreLoadJsonGame",inventoryLoadBegin,inventoryLoadEnd)
add("/Script/ProjectPBZ.PBZBackPackSubsystem:AddDustNum",function(context)
    sampleInventory(unwrap(context),"native-dust-before")
end,function(context)
    sampleInventory(unwrap(context),"native-dust-after")
end)
scriptAfter("/Game/PBZContent/Blueprint/FlowGraph/FlowGraphNode/LootItems.LootItems_C:PickupItems",function(context)
    local node=unwrap(context)
    if localInventory(node) then sampleInventory(nil,"LootItems.PickupItems-completed") end
end)
scriptAfter("/Game/RenewalContent/Prototypes/Character/BP_RenewalPlayer.BP_RenewalPlayer_C:ChangeDustNumInternal",function(context)
    if isLocal(unwrap(context)) then sampleInventory(nil,"ChangeDustNumInternal") end
end)
add("/Script/SGameCombatSystem.CharacterWeaponsComponent:SetCurrentWeapon",function(context,slot)
    local component=unwrap(context);local owner=valid(component) and attempt(function() return component:GetOwner() end)
    local before=isLocal(owner) and attempt(function() return component:GetCurrentWeaponIndex(unwrap(slot),false) end)
    push("switch",component,{before=before,generation=state.generation,pawn=id(owner)})
end,function(context,result,slot)
    local component=unwrap(context);local record=pop("switch",component)
    if not record or record.generation~=state.generation or record.pawn~=state.pawn or unwrap(result)~=true then return end
    local current=attempt(function() return component:GetCurrentWeaponIndex(unwrap(slot),false) end)
    if A.finite(record.before) and A.finite(current) and record.before>=0 and current>=0 and record.before~=current then
        emit("WeaponSwitch","SetCurrentWeapon-success-and-index-changed",state.generation)
    end
end)
add("/Script/SGameCombatSystem.CharacterWeaponsComponent:SetArmed",function(context,slot)
    local component=unwrap(context);local owner=valid(component) and attempt(function() return component:GetOwner() end)
    local before
    if isLocal(owner) then before=attempt(function() return component:IsArmed(unwrap(slot)) end) end
    push("armed",component,{before=before,generation=state.generation,pawn=id(owner)})
end,function(context,slot)
    local component=unwrap(context);local record=pop("armed",component)
    if not record or record.generation~=state.generation or record.pawn~=state.pawn or type(record.before)~="boolean" then return end
    local current=attempt(function() return component:IsArmed(unwrap(slot)) end)
    if type(current)=="boolean" and current~=record.before then emit(current and "WeaponDraw" or "WeaponSheathe","actual-armed-state-changed",state.generation) end
end)
after("/Script/Engine.PlayerController:ClientRestart", function(context)
    if attempt(function() return unwrap(context):IsLocalPlayerController() end) then
        localController = unwrap(context); lastPawn = nil;reset();transactions={}
    end
end)
RegisterLoadMapPostHook(guarded(function()
    localController, localPawn, lastPawn = nil, nil, nil
    reset();initializing=0;inventoryInitializing=0;transactions={}
    registerMissing();watchMissing()
end))
local selfTestPending=false
local function selfTest()
    selfTestPending=false
    if not Config.Enabled or not Config.Events.ControllerRumble then log("self-test skipped: mod or ControllerRumble disabled");return end
    log("self-test requested: 100ms Shake30; captures asset="..rumbleRequests.asset.." dynamic="..rumbleRequests.dynamic)
    primarySinceSample=true
    local effect={name="ControllerRumble",uuid="ControllerRumble",keep="False",priority=0,tracks={{
        start_time=0,end_time=100,stop_name="",start_intensity=30,end_intensity=30,
        intensity_mode="Const",action_type="Shake",once="False",interval=0,index={5,6,105,106}}}}
    feedback:enqueueContent("ControllerRumble",effect,state.generation,{input="manual-test",pulse_ms=100})
end
if type(RegisterKeyBind)=="function" and Key and ModifierKey then
    RegisterKeyBind(Key.F8,{ModifierKey.CONTROL,ModifierKey.ALT},function()
        selfTestPending=true -- Consumed by the protected player script Tick.
    end)
    if Config.Debug then log("manual-test ready: Ctrl+Alt+F8; finite Shake only") end
end
-- Bridge owns network I/O. Bootstrap once before hook callbacks begin; further
-- Lua sampling, queues and SDK-file pumping use a script hook. In loader
-- 1ceefac8 this holds the same mutex as LuaMod::uninstall; timers do not.
local function gameUpdate()
            local ok, err = pcall(function()
                observe("health-poll/unknown-source")
                local native,err
                if valid(localPawn) then native,err=A.hookMotion(localPawn) end
                local wallActive=observeWalls(native)
                observeGrapple(wallActive,native,err)
                inventoryTicks=inventoryTicks+1
                local interval=math.max(1,math.ceil(((Config.Inventory and Config.Inventory.SampleMs) or 250)/Config.PollMs))
                if inventoryTicks>=interval then inventoryTicks=0;sampleInventory(nil,"inventory-poll") end
                observeUses(inventoryTicks==0)
                if selfTestPending then selfTest() end
                -- Flush after identity/primary-event observation, before queuing
                -- this sample's generic slice, so same-frame primary hooks can cancel it.
                feedback:pump(state.generation)
                if valid(localPawn) then
                    local clocks=A.clocks(UEHelpers,localPawn)
                    local settings=attempt(function() return {enabled=localController.bForceFeedbackEnabled,scale=localController.ForceFeedbackScale} end)
                    if clocks and settings and A.finite(settings.scale) then
                        local scale=(settings.enabled~=true and Config.Rumble.MirrorWhenGameFeedbackDisabled==true) and 1 or math.max(0,settings.scale)
                        rumble:step(clocks,clocks.paused,scale,(settings.enabled==true or Config.Rumble.MirrorWhenGameFeedbackDisabled==true) and Config.Enabled,primarySinceSample,state.generation)
                    end
                end
                primarySinceSample=false
            end)
            if not ok then notice("poll-error:"..tostring(err),"poll-error " .. tostring(err)) end
end
scriptAfter("/Game/RenewalContent/Actors/Players/BP_Renewal_Hun.BP_Renewal_Hun_C:ReceiveTick",function(context,delta)
    local pawn=unwrap(context)
    if not isLocal(pawn) then return end
    local pawnId=id(pawn)
    local clocks=A.clocks(UEHelpers,pawn)
    local real=clocks and clocks.real
    if tickPawn~=pawnId or (real and tickReal and real<tickReal) then
        tickPawn,tickReal,tickDelta=pawnId,nil,0
    end
    delta=unwrap(delta)
    if A.finite(delta) and delta>=0 then tickDelta=tickDelta+delta end
    local interval=math.max(1,Config.PollMs)/1000
    if tickReal~=nil and tickDelta+0.000001<interval and (not real or real-tickReal+0.000001<interval) then return end
    -- One sample even after a long frame/pause; never replay a missed backlog.
    gameUpdate()
    tickPawn,tickReal,tickDelta=pawnId,real or 0,0
    notice("tick-ready","sampling-ready protected-player-script-tick; no loader timer")
end)
feedback:pump(state.generation)
registerMissing();watchMissing()
log("loaded; protected player script Tick; no loader timers; full restart recommended for updates; damage direction=unknown")
if Config.Debug then log("attack settlement compatibility ready; revision=immortal-compat-1") end
