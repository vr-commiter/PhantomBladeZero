-- All functions in this module are called synchronously on the game thread.
local A={}
function A.try(fn,...)
    local ok,result=pcall(fn,...);if ok then return result end
end
function A.unwrap(value)
    if value==nil then return nil end
    local ok,result=pcall(function() return value:get() end)
    if ok then return result end -- Preserve false and nil; do not turn false into a truthy wrapper.
    return value
end
function A.valid(obj) return obj~=nil and A.try(function() return obj:IsValid() end)==true end
function A.id(obj)
    if not A.valid(obj) then return nil end
    local address=A.try(function() return obj:GetAddress() end)
    return address and tostring(address) or A.try(function() return obj:GetFullName() end)
end
function A.same(a,b) local x=A.id(a);return x~=nil and x==A.id(b) end
function A.finite(n) return type(n)=="number" and n==n and math.abs(n)<math.huge end
function A.isA(object,path)
    if not A.valid(object) then return false end
    local result=A.try(function() return object:IsA(path) end)
    if type(result)=="boolean" then return result end
    local cls=A.try(function() return object:GetClass() end)
    for _=1,16 do
        if not A.valid(cls) then return false end
        local name=A.try(function() return cls:GetFullName():match("^[^ ]+ (.+)$") end)
        if name==path then return true end
        cls=A.try(function() return cls:GetSuperStruct() end)
    end
    return false
end
function A.abilityOwner(ability)
    for _,field in ipairs({"Character","CharacterBase"}) do
        local owner=A.try(function() return ability[field] end)
        if A.valid(owner) then return owner end
    end
    return A.try(function() return ability:GetAvatarActorFromActorInfo() end)
end
function A.wallVolume(ability)
    for _,field in ipairs({"CurrentSpecialMoveVolume","UpRunningVolume","Cur Special Move Volume"}) do
        local volume=A.try(function() return ability[field] end)
        if A.valid(volume) then return volume end
    end
end
function A.vector(value)
    value=A.unwrap(value)
    local x=A.try(function() return A.unwrap(value.X) end)
    local y=A.try(function() return A.unwrap(value.Y) end)
    local z=A.try(function() return A.unwrap(value.Z) end)
    if A.finite(x) and A.finite(y) and A.finite(z) then return {x=x,y=y,z=z} end
end
function A.position(pawn)
    return A.try(function() return A.vector(pawn:K2_GetActorLocation()) end)
end
function A.floorContact(pawn)
    local ok,result=pcall(function()
        if not A.valid(pawn) then error("floor query pawn is invalid") end
        local movement=pawn.CharacterMovement
        if not A.valid(movement) then error("floor query movement component is invalid") end
        local function componentPosition(component)
            if not A.valid(component) then return nil end
            return A.try(function() return A.vector(component:K2_GetComponentLocation()) end)
        end
        -- Use the collision component's current world location, never a mesh
        -- location or an unverified Actor origin. UpdatedComponent is the
        -- capsule moved by CharacterMovement when Character.CapsuleComponent
        -- is unavailable. No cached CurrentFloor is accepted as evidence.
        local position=componentPosition(A.try(function() return pawn.CapsuleComponent end))
            or componentPosition(A.try(function() return movement.UpdatedComponent end))
        if not position then error("capsule world location unavailable") end
        local floor={}
        -- KintaroModding/ue4ss 1ceefac8 fills this same OutStruct table in
        -- place; K2_FindFloor is void. Do not retain borrowed UE struct views.
        movement:K2_FindFloor({X=position.x,Y=position.y,Z=position.z},floor)
        local blocking,walkable,line=floor.bBlockingHit,floor.bWalkableFloor,floor.bLineTrace
        if type(blocking)~="boolean" or type(walkable)~="boolean" or type(line)~="boolean" then
            error("floor query did not populate contact flags")
        end
        local distance
        if line then distance=floor.LineDist else distance=floor.FloorDist end
        if not A.finite(distance) then error("floor query distance is not finite") end
        -- Unreal floor distance measures separation from the capsule bottom;
        -- a blocking walkable sweep far below the player is not a landing.
        return {grounded=blocking and walkable and distance<=3,distance=distance,blocking=blocking,walkable=walkable}
    end)
    if ok then return result end
    return nil,tostring(result)
end
function A.hookMotion(pawn)
    local ok,result=pcall(function()
        if type(StaticFindObject)~="function" then error("class lookup unavailable") end
        if not A.valid(A.hookClass) then A.hookClass=StaticFindObject("/Script/AdvancedSpecialMove.SpecialMoveComponent") end
        if not A.valid(A.hookClass) then error("native SpecialMoveComponent not loaded") end
        local component=pawn:GetComponentByClass(A.hookClass)
        if not A.valid(component) or not A.same(component:GetOwner(),pawn) then error("local native SpecialMoveComponent unavailable") end
        local data=component:GetSpecialMoveRuntimeData()
        local active=A.unwrap(data.bEnableHookIK)
        if type(active)~="boolean" then error("HookIK state unavailable") end
        local volume=A.try(function() return component.CurrentSpecialMoveVolume end)
        local mode=A.unwrap(pawn.CharacterMovement.MovementMode)
        local travelling=mode==3 or mode==5 or mode==6
        local upRunning=A.unwrap(data.bEnableUpRunningIK)==true
        local rising=upRunning and A.try(function() return pawn:GetVelocity().Z>0 end)==true
        return {active=active,key="ik:"..A.id(component)..":"..tostring(A.id(volume)),
            root=active and travelling and A.unwrap(pawn:HasAnyRootMotion())==true,
            upRunning=upRunning,volume=volume,component=component,wallMoving=mode==6 or rising}
        -- HookData's animation-space transforms are deliberately not treated
        -- as world-space targets. Only explicit TargetWS callbacks supply one.
    end)
    if ok then return result end
    return nil,tostring(result)
end
function A.hookRootActive(pawn,instance)
    return A.try(function()
        if not A.valid(A.rmsLibrary) then A.rmsLibrary=StaticFindObject("/Script/RMS.Default__RMSLibrary") end
        if not A.valid(A.rmsLibrary) then return nil end
        return A.unwrap(A.rmsLibrary:IsRootMotionSourceValid(pawn.CharacterMovement,FName(instance)))
    end)
end
function A.name(value)
    value=A.unwrap(value)
    if value==nil then return nil end
    return A.try(function() return value:ToString() end) or tostring(value)
end
function A.damageTags(value)
    if value==nil then return {} end
    local out,seen={},{}
    local count,limited=0,false
    local ok,err=pcall(function()
        local container=A.unwrap(value)
        if container==nil then return end
        -- Only tags carried by this damage event are evidence. ParentTags and
        -- actor-owned status tags must not turn unrelated hits into a DoT.
        local tags=A.unwrap(container.GameplayTags)
        if tags==nil then error("damage GameplayTags array unavailable") end
        local function append(_,entry)
            count=count+1
            if count>32 then limited=true;error("damage tag input exceeds32 entries") end
            local tag=A.unwrap(entry)
            local name=A.unwrap(tag.TagName)
            if name==nil then error("damage tag has no TagName") end
            if type(name)~="string" then name=A.unwrap(name:ToString()) end
            if type(name)~="string" then error("damage TagName is not a string") end
            if name~="" and name~="None" and not seen[name] then
                seen[name]=true;out[#out+1]=name
            end
        end
        local forEach=tags.ForEach
        if type(forEach)=="function" then forEach(tags,append)
        elseif type(tags)=="table" then
            for index,entry in ipairs(tags) do append(index,entry) end
        else error("damage GameplayTags does not support bounded iteration") end
    end)
    if ok then return out end
    if limited then return out,"damage tag input exceeds32 entries; truncated" end
    return {},"damage tags unavailable: "..tostring(err)
end
function A.damageSource(source,dotCauses,effectCauses)
    local out={tags={}}
    local errors={}
    local function note(label,detail)
        errors[#errors+1]=label..(detail~=nil and (": "..tostring(detail)) or "")
    end
    local function read(label,fn)
        local ok,value=pcall(fn)
        if not ok then note(label,value);return nil end
        return value
    end
    local object=A.unwrap(source)
    if not A.valid(object) then out.error="damage source unavailable or invalid";return out end
    local label=read("source name",function() return object:GetFullName() end)
    if type(label)=="string" then out.label=label else note("source name is not a string") end
    -- Tags have this meaning only on the reflected gameplay-effect source type.
    -- A similarly named bullet/object must not grant itself periodic semantics.
    local typed=read("source IsA",function()
        return A.unwrap(object:IsA("/Script/SGameCombatSystem.DamageSource_GameplayEffect"))
    end)
    if typed==true then
        local tagsValue=read("source Tags",function() return object.Tags end)
        if tagsValue==nil then note("source Tags unavailable")
        else
            local tags,err=A.damageTags(tagsValue)
            out.tags=tags
            if err then note("source Tags",err) end
            for _,name in ipairs(tags) do
                if type(dotCauses)=="table" and dotCauses[name]==true then out.cause=name;break end
            end
        end
    elseif typed~=false and typed~=nil then note("source IsA did not return a boolean") end
    local visited={}
    local current=object
    for depth=0,2 do
        if not A.valid(current) then note("source outer invalid");break end
        if visited[current] then note("source outer cycle");break end
        visited[current]=true
        local cls=read("source class",function() return A.unwrap(current:GetClass()) end)
        local path
        if A.valid(cls) then
            local full=read("source class name",function() return cls:GetFullName() end)
            if type(full)=="string" then
                path=full:match("^%S+ (/.+)$") or (full:sub(1,1)=="/" and full or nil)
                if not path then note("source class path unavailable") end
            else note("source class name is not a string") end
        else note("source class invalid") end
        if depth==0 then out.classPath=path end
        local mapped=path and type(effectCauses)=="table" and effectCauses[path]
        if type(mapped)=="string" and mapped~="" then
            out.effect=path
            if not out.cause then out.cause=mapped end
            break
        end
        if depth==2 then break end
        current=read("source outer",function() return A.unwrap(current:GetOuter()) end)
        if current==nil then break end
    end
    if not out.cause then note("unrecognized damage source") end
    if #errors>0 then out.error=table.concat(errors,"; ") end
    return out
end
function A.clocks(helpers,pawn)
    local ok,result=pcall(function()
        local statics=helpers.GetGameplayStatics()
        local game,real=statics:GetTimeSeconds(pawn),statics:GetRealTimeSeconds(pawn)
        if not A.finite(game) or not A.finite(real) then error("game/real clock is not a finite number") end
        return {game=game,real=real,paused=statics:IsGamePaused(pawn)==true}
    end)
    if ok then return result end
    return nil,tostring(result)
end
function A.movementInput(pawn,controller,actualActions)
    local ok,result=pcall(function()
        if not A.valid(pawn) or not A.valid(controller)
            or A.try(function() return A.unwrap(controller:IsLocalPlayerController()) end)~=true
            or not A.same(A.try(function() return A.unwrap(controller.Pawn) end),pawn) then
            error("movement input requires the current local pawn/controller")
        end
        if type(StaticFindObject)~="function" then error("movement input lookup unavailable") end
        if not A.valid(A.sgameInputUtils) then A.sgameInputUtils=StaticFindObject("/Script/SGameInputSystem.Default__SGameInputUtils") end
        if not A.valid(A.sgameInputUtils) then error("SGameInputUtils default object unavailable") end
        local component
        for _,actor in ipairs({pawn,controller}) do
            local candidate=A.try(function() return A.sgameInputUtils:GetSGameInputComponent(actor) end)
            local owner=A.valid(candidate) and A.try(function() return candidate:GetOwner() end)
            if A.isA(candidate,"/Script/SGameInputSystem.SGameInputComponent")
                and (A.same(owner,pawn) or A.same(owner,controller)) then component=candidate;break end
        end
        if not component then error("local SGameInputComponent unavailable") end
        local specs={
            {"dodge","/PBZDeflectSystem/Input/IA_Dodge.IA_Dodge"},
            {"dodgeHold","/PBZDeflectSystem/Input/IA_DodgeHold.IA_DodgeHold"},
            {"sprint","/SGameLocomotionDriver/Input/IA_Sprint.IA_Sprint"},
            {"sprintSwitch","/SGameLocomotionDriver/Input/IA_SprintSwitch.IA_SprintSwitch"},
        }
        local out={actions={},componentId=A.id(component),pawnId=A.id(pawn),actionCount=0}
        local anyHeld,unknown=false,false
        A.movementInputActions=A.movementInputActions or {}
        for _,spec in ipairs(specs) do
            local key,path=spec[1],spec[2]
            local action=type(actualActions)=="table" and A.unwrap(actualActions[key]) or nil
            if not A.isA(action,"/Script/EnhancedInput.InputAction") then
                action=A.movementInputActions[key]
                if not A.valid(action) then action=StaticFindObject(path);A.movementInputActions[key]=action end
            end
            -- An unloaded asset cannot currently drive input and is omitted.
            -- A loaded action whose getter fails is an unknown, not released.
            if A.isA(action,"/Script/EnhancedInput.InputAction") then
                out.actionCount=out.actionCount+1
                local held=A.try(function() return A.unwrap(component:IsHolding(action)) end)
                if type(held)~="boolean" then held=nil;unknown=true end
                local time
                if held then
                    anyHeld=true
                    local value=A.try(function() return A.unwrap(component:GetHoldTime(action)) end)
                    if A.finite(value) and value>=0 then time=value end
                end
                out.actions[key]={held=held,holdTime=time,actionId=A.id(action)}
            end
        end
        if anyHeld then out.held=true
        elseif out.actionCount>0 and not unknown then out.held=false end
        -- GetHoldTime is copied elapsed hold data, not an assumed press ID.
        -- The caller can recognize a new per-action episode after an observed
        -- release or a falling holdTime. No input observation emits feedback.
        return out
    end)
    if ok then return result end
    return nil,tostring(result)
end
function A.posture(pawn)
    local result={}
    local ok,err=pcall(function()
        local component=pawn:GetActorStateComponent()
        if not A.valid(component) then error("actor-state component is invalid") end
        A.stateTags=A.stateTags or {jump={TagName=FName("CharacterState.AirState.Jumped")},crouch={TagName=FName("CharacterState.Crouching")},
            sprint={TagName=FName("CharacterState.Sprinting")},nativeSprint={TagName=FName("CharacterState.Native.Attitude.Sprinting")}}
        result.jumped=component:InExactState(A.stateTags.jump)==true
        result.crouched=component:InExactState(A.stateTags.crouch)==true
        result.sprinting=component:InExactState(A.stateTags.sprint)==true or component:InExactState(A.stateTags.nativeSprint)==true
    end)
    local crouched=A.try(function() return pawn.bIsCrouched end)
    if crouched==true then result.crouched=true
    elseif result.crouched==nil and type(crouched)=="boolean" then result.crouched=crouched end
    if not ok then result.stateError=tostring(err) end
    return result
end
function A.inAttackFrame(pawn)
    return A.try(function()
        A.attackTag=A.attackTag or {TagName=FName("CharacterState.InAttackFrame")}
        return pawn:GetActorStateComponent():InExactState(A.attackTag)==true
    end)==true
end
function A.realBullet(bullet)
    return A.isA(bullet,"/Script/SGameCombatSystem.BulletObjectBase") or A.isA(bullet,"/Script/SGameCombatSystem.BulletActorBase")
end
function A.bulletUsable(bullet)
    if A.try(function() return A.unwrap(bullet.Destroyed) end)==true then return false,"destroyed" end
    local status=A.try(function() return A.unwrap(bullet.BulletStatus) end)
    if A.finite(status) and status~=2 then return false,"inactive-status-"..status end
    return true
end
function A.projectileInfo(bullet,localPawn)
    local ok,result=pcall(function()
        local function reject(reason) error(reason,0) end
        bullet=A.unwrap(bullet);localPawn=A.unwrap(localPawn)
        if not A.valid(localPawn) then reject("local-pawn-invalid") end
        if not A.realBullet(bullet) then reject("not-a-real-bullet") end
        local function runtimeObject(object)
            local name=A.try(function() return object:GetFullName() end)
            if type(name)~="string" or name=="" then return false end
            local lower=name:lower()
            return not (name:find("Default__",1,true) or name:find("REINST_",1,true)
                or name:find("SKEL_",1,true) or lower:find("preview",1,true))
        end
        if not runtimeObject(bullet) then reject("default-or-preview-bullet") end
        if A.unwrap(bullet.BulletStatus)~=2 then reject("bullet-not-running") end
        if A.try(function() return A.unwrap(bullet.Destroyed) end)==true then reject("destroyed-bullet") end
        local debug=A.unwrap(bullet.Debug)
        if debug~=false then reject(debug==true and "debug-bullet" or "debug-state-unavailable") end
        local child=A.unwrap(bullet.bWasInitializedWithParentBullet)
        if child~=false then reject(child==true and "child-bullet" or "parent-initialization-unknown") end
        if A.valid(A.unwrap(bullet.ParentBullet)) then reject("parent-bullet-present") end
        local owner=A.unwrap(bullet.BulletOwnerAvatar)
        if not A.same(owner,localPawn) then reject("bullet-owner-not-local") end
        local data=A.unwrap(bullet.BulletData)
        if not A.valid(data) then reject("bullet-data-invalid") end
        if A.isA(data,"/Script/PBZCombatAsset.PBZ_DamageBulletDataBase") then
            -- DamageCause is reflected only on this real damage-data base;
            -- emitter/other data do not expose it. Unknown cause stays neutral.
            local cause=A.try(function() return A.name(data.DamageCause.TagName) end)
            if A.nonDirectDamage(cause) then reject("non-direct-damage-bullet") end
        end
        local ability=A.unwrap(bullet.BulletSourceAbility)
        local abilityOwner,activation
        if A.valid(ability) then
            if not runtimeObject(ability) then reject("default-or-preview-source-ability") end
            abilityOwner=A.abilityOwner(ability)
            if A.valid(abilityOwner) and not A.same(abilityOwner,localPawn) then reject("source-ability-owner-not-local") end
            local count=A.try(function() return A.unwrap(ability.ActivationCount) end)
            if A.finite(count) and count>=0 and count%1==0 then activation=count end
        else ability=nil end
        local function hasAttackModule()
            local count,attack=0,false
            -- The module array and entries are borrowed engine views. Inspect
            -- their real reflected types here, retain only the boolean result.
            bullet.Modules:ForEach(function(_,value)
                count=count+1;if count>64 then reject("attack-modules-exceed-bound") end
                if A.isA(A.unwrap(value),"/Script/SGameCombatSystem.BulletAttackModule") then attack=true end
            end)
            return attack
        end
        local kind
        if A.isA(bullet,"/Script/PBZCombatAsset.PBZ_ProjectileEmitter")
            or A.isA(data,"/Script/PBZCombatAsset.PBZ_ProjectileEmitterData") then kind="emitter"
        elseif A.isA(bullet,"/Script/PBZCombatAsset.PBZ_ProjectileBullet")
            or A.isA(data,"/Script/PBZCombatAsset.PBZ_ProjectileBulletData") then kind="projectile"
        elseif ability and A.valid(abilityOwner) and A.same(abilityOwner,localPawn) and activation~=nil
            and A.isA(ability,"/PBZCombatAsset/Prototypes/Abilities/Base/BP_ShachiAbility_Base_Ranged.BP_ShachiAbility_Base_Ranged_C")
            and A.try(function() return A.unwrap(ability:IsAbilityRunning()) end)==true then
            -- Nonphysical ranged instances need an actual attack module and
            -- active source; a leftover buff/aura source is not a new shot.
            if not hasAttackModule() then reject("ranged-bullet-has-no-attack-module") end
            kind="ranged"
        elseif ability and A.valid(abilityOwner) and A.same(abilityOwner,localPawn) and activation~=nil
            and A.isA(ability,"/PBZCombatAsset/Prototypes/Abilities/Base/BP_ShachiAbility_Base.BP_ShachiAbility_Base_C")
            and A.try(function() return A.unwrap(ability:IsAbilityRunning()) end)==true and A.inAttackFrame(localPawn) then
            if not hasAttackModule() then reject("shadow-bullet-has-no-attack-module") end
            -- This is an actual generated shadow-weapon attack instance, not
            -- necessarily a physical projectile. Main joins its action/batch.
            kind="shadow-attack"
        else reject("not-a-verified-projectile-or-local-ranged-shot") end
        local bulletId,dataId=A.id(bullet),A.id(data)
        if not bulletId or not dataId then reject("projectile-identity-unavailable") end
        -- Metadata and these object references are consumed synchronously by
        -- main on the game thread. Nothing here retains an interface view.
        return {bullet=bullet,id=bulletId,owner=owner,ability=ability,activation=activation,kind=kind,dataId=dataId}
    end)
    if ok then return result end
    return nil,tostring(result)
end
function A.nonDirectDamage(cause)
    if type(cause)~="string" then return false end
    for _,prefix in ipairs({"Damage.Cause.StatusInfliction","Damage.Cause.Deflect","Damage.Cause.Accessory","Damage.Cause.Debuff"}) do
        if cause==prefix or cause:sub(1,#prefix+1)==prefix.."." then return true end
    end
    return false
end
function A.confirmJumpAbility(ability,pawn)
    -- This game's jump ability can bypass Character.OnJumped. Read its own
    -- configured state, never treat an arbitrary upward knockback as a jump.
    local tag=A.try(function() return A.name(ability["Air State Tag"].TagName) end)
    if not tag or tag=="None" or tag=="" then return false,"missing configured air-state tag" end
    local confirmed=A.try(function()
        return pawn:GetActorStateComponent():InExactState({TagName=FName(tag)})==true
    end)
    local launched=A.try(function() return pawn.CharacterMovement.PendingLaunchVelocity.Z>0 end)==true
    local rising=A.try(function() return pawn.CharacterMovement.MovementMode==3 and pawn:GetVelocity().Z>0 end)==true
    return confirmed==true or launched or rising,"ability-state="..tag.." active="..tostring(confirmed).." launch="..tostring(launched).." rising="..tostring(rising)
end
function A.executionInfo(action,localPawn)
    local ok,result=pcall(function()
        local function reject(reason) error(reason,0) end
        action=A.unwrap(action);localPawn=A.unwrap(localPawn)
        if not A.valid(localPawn) then reject("execution-local-pawn-invalid") end
        if not A.isA(action,"/SGameExecution/GA/GA_ExecutionAbilityBase.GA_ExecutionAbilityBase_C") then
            reject("not-an-executor-ability")
        end
        local name=A.try(function() return action:GetFullName() end)
        if type(name)~="string" or name=="" then reject("execution-identity-unavailable") end
        if name:find("Default__",1,true) or name:find("REINST_",1,true)
            or name:find("SKEL_",1,true) or name:lower():find("preview",1,true) then reject("default-or-preview-execution") end
        if not A.same(A.abilityOwner(action),localPawn) then reject("execution-owner-not-local") end
        if A.try(function() return A.unwrap(action:IsAbilityRunning()) end)~=true then reject("execution-not-running") end
        local activation=A.try(function() return A.unwrap(action.ActivationCount) end)
        if not A.finite(activation) or activation<0 or activation%1~=0 then reject("execution-activation-unavailable") end
        local timeline=A.try(function() return A.unwrap(action.ExecutionTimeline) end)
        if not A.valid(timeline) then reject("execution-timeline-unavailable") end
        if A.try(function() return A.unwrap(action:IsPlayingTimeline(timeline)) end)~=true then reject("execution-timeline-not-playing") end
        local identity,timelineId=A.id(action),A.id(timeline)
        if not identity or not timelineId then reject("execution-identity-unavailable") end
        -- Caller also compares its actual PlayTimeline parameter to timelineId.
        -- No weak execution cache, native UInterface or time-based guess is used.
        return {id=identity,key=identity..":"..activation,activation=activation,timelineId=timelineId}
    end)
    if ok then return result end
    return nil,tostring(result)
end
function A.bulletSource(source)
    source=A.unwrap(source)
    if not A.valid(source) then return nil end
    local bullet=A.try(function() return source.Bullet end)
    if not A.valid(bullet) then bullet=source end
    local owner=A.try(function() return bullet.BulletOwnerAvatar end)
    if not A.valid(owner) then owner=A.try(function() return source.LastOwnerAvatar end) end
    if not A.valid(owner) then owner=A.try(function() return source:GetOwnerAvatar() end) end
    local ability=A.try(function() return bullet.BulletSourceAbility end)
    local count=A.valid(ability) and A.try(function() return ability.ActivationCount end)
    local lifetime=A.finite(count) and (A.id(ability)..":"..tostring(count)) or nil
    return bullet,owner,lifetime
end
function A.inventoryCount(subsystem,item)
    local count=0
    subsystem.Inventories:ForEach(function(key,value)
        if A.name(key)==A.name(item) then
            local info=A.unwrap(value)
            if not A.valid(info) then error("invalid inventory entry") end
            count=info.CurrentAmount
        end
    end)
    if not A.finite(count) or count<0 then error("invalid inventory amount") end
    return count
end
function A.captureHealthModification(payload,returnedMapWrapper)
    local requests=A.healthModificationRequests
    local request=requests and requests[#requests]
    if not request then return end -- Never inspect unsolicited native returns.
    if A.id(A.unwrap(payload))~=request.payload or request.captured then return end
    request.captured=true
    local ok,result=pcall(function()
        -- Called only inside the native post hook, while its ReturnValue and
        -- map elements still live. Copy scalars here, never retain the views.
        local map=A.unwrap(returnedMapWrapper)
        local amount,count=0,0
        map:ForEach(function(key,value)
            count=count+1;if count>128 then error("health modification map exceeds 128 entries",0) end
            local attribute=A.unwrap(key)
            local name=A.name(attribute.AttributeName)
            local delta=A.unwrap(value)
            if (name=="Health" or (name and name:match("[%.:]Health$"))) and A.finite(delta) and delta<0 then
                amount=amount-delta
                if not A.finite(amount) then error("health modification sum is not finite",0) end
            end
        end)
        return amount
    end)
    if ok then request.amount=result else request.error=tostring(result) end
end
function A.healthModification(payload)
    payload=A.unwrap(payload)
    local identity=A.id(payload)
    if not identity then error("health modification payload is invalid",0) end
    A.healthModificationRequests=A.healthModificationRequests or {}
    local requests=A.healthModificationRequests
    if #requests>=16 then error("health modification request nesting exceeds 16",0) end
    local request={payload=identity,captured=false}
    requests[#requests+1]=request
    local ok,err=pcall(function()
        -- The pinned loader returns a Lua table of non-owning RemoteParams.
        -- Ignore that return entirely; the native post hook supplies a scalar.
        payload:GetTargetAttributesModification()
    end)
    local popped=table.remove(requests) -- Also pop after getter/capture errors.
    if popped~=request then error("health modification request stack mismatch",0) end
    if not ok then error(err,0) end
    if request.error then error(request.error,0) end
    if not request.captured then error("native post health modification capture unavailable",0) end
    return request.amount
end
function A.backpack(pawn)
    if not A.valid(A.backpackDefaults) then
        A.backpackDefaults=StaticFindObject("/Script/ProjectPBZ.Default__PBZBackPackSubsystem")
    end
    if not A.valid(A.backpackDefaults) then error("backpack default object unavailable") end
    local subsystem=A.backpackDefaults:GetBackPackSubsytemByContextObject(pawn)
    if not A.valid(subsystem) or not A.same(subsystem:GetWorld(),pawn:GetWorld()) then error("no backpack in local pawn world") end
    return subsystem
end
function A.inventorySnapshot(subsystem,pawn)
    -- Renewal's actual currencies are separate Blueprint fields. GAS Coin is
    -- retained only as compatibility fallback for other character classes.
    local result={coin=A.try(function() return pawn.Coin end),dust=A.try(function() return pawn.ConsciousnessDust end)}
    if not A.finite(result.coin) then result.coin=A.try(function() return pawn.AttributeSetBase.Coin.CurrentValue end) end
    if not A.finite(result.coin) or result.coin<0 then result.coin=nil end
    if not A.finite(result.dust) or result.dust<0 then result.dust=nil end
    if not A.valid(subsystem) then return result end
    local counts,kinds={},{}
    local maps={{"Inventories","item",true},{"MainWeaponInfos","weapon"},{"ShaqiWeaponInfos","shaqi-weapon"},
        {"MedicineInfos","medicine"},{"Accessories","accessory"}}
    local entries=0
    for _,spec in ipairs(maps) do
        local map=subsystem[spec[1]]
        if map then
            map:ForEach(function(key,value)
                entries=entries+1;if entries>8192 then error("inventory snapshot exceeds bounded entry limit") end
                local name=A.name(key);local info=A.unwrap(value)
                if not name or name=="" or name=="None" or not A.valid(info) then error("invalid owned inventory entry") end
                local amount=1
                if spec[3] then amount=A.unwrap(info.CurrentAmount) end
                if not A.finite(amount) or amount<0 then error("invalid owned inventory amount") end
                -- A weapon/medicine may also have an Inventories entry. Join by
                -- actual item ID so one acquisition does not vibrate twice.
                counts[name]=math.max(counts[name] or 0,amount);kinds[name]=kinds[name] or spec[2]
            end)
        elseif spec[3] then error("Inventories map unavailable") end
    end
    result.counts,result.kinds,result.entries=counts,kinds,entries
    return result
end
local function flags(c)
    return {A.unwrap(c.bAffectsLeftLarge)==true,A.unwrap(c.bAffectsLeftSmall)==true,
        A.unwrap(c.bAffectsRightLarge)==true,A.unwrap(c.bAffectsRightSmall)==true}
end
function A.curve(runtime)
    local rich
    local external=A.unwrap(runtime.ExternalCurve)
    if A.valid(external) then rich=external.FloatCurve else rich=runtime.EditorCurveData end
    local out={keys={}}
    local default=A.unwrap(rich.DefaultValue)
    if A.finite(default) and math.abs(default)<1e30 then out.default=default end
    rich.Keys:ForEach(function(_,param)
        if #out.keys>=512 then error("curve has more than 512 keys") end
        local k=A.unwrap(param)
        local time,value=A.unwrap(k.Time),A.unwrap(k.Value)
        local weight=A.unwrap(k.TangentWeightMode)
        local interp=A.unwrap(k.InterpMode)
        if not A.finite(time) or not A.finite(value) then error("nonfinite curve key") end
        if weight~=nil and weight~=0 then error("weighted curve not supported by this Lua evaluator") end
        if interp~=0 and interp~=1 and interp~=2 then error("unsupported curve interpolation") end
        out.keys[#out.keys+1]={time=time,value=value,interp=interp,
            arrive=A.unwrap(k.ArriveTangent) or 0,leave=A.unwrap(k.LeaveTangent) or 0}
    end)
    table.sort(out.keys,function(a,b) return a.time<b.time end)
    for i=2,#out.keys do if out.keys[i].time<=out.keys[i-1].time then error("duplicate curve key times") end end
    return out
end
function A.asset(effect,params,route)
    local ok,data=pcall(function()
        local overrides=0
        effect.PerDeviceOverrides:ForEach(function() overrides=overrides+1 end)
        if overrides>0 then error("per-device overrides need current platform selection; using semantic fallback") end
        local out={channels={},duration=A.unwrap(effect.duration),path=effect:GetFullName():match("^[^ ]+ (.+)$"),
            tag=A.name(params.Tag),loop=A.unwrap(params.bLooping)==true,
            ignoreDilation=A.unwrap(params.bIgnoreTimeDilation)==true,playPaused=A.unwrap(params.bPlayWhilePaused)==true,
            name=route and route.name or "ControllerRumble",kind=route and route.kind or "generic"}
        effect.ChannelDetails:ForEach(function(_,param)
            if #out.channels>=16 then error("too many force-feedback channels") end
            local c=A.unwrap(param)
            local curve=A.curve(c.Curve)
            for _,key in ipairs(curve.keys) do out.duration=math.max(out.duration or 0,key.time) end
            out.channels[#out.channels+1]={flags=flags(c),curve=curve}
        end)
        if not A.finite(out.duration) or out.duration<=0 then error("missing/zero asset duration") end
        return out
    end)
    if ok then return data end
    return nil,tostring(data)
end
function A.blockedSource(label)
    label=(label or ""):lower()
    return label:find("footstep",1,true) or label:find("climbladder_leftfoot",1,true)
        or label:find("climbladder_rightfoot",1,true) or label:find("itemrelease",1,true)
        or label:find("dropitem",1,true)
end
return A
