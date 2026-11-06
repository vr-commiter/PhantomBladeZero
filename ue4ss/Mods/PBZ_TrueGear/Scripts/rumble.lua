-- UE force-feedback request -> finite TrueGear Shake content. No device/XInput polling.
local Rumble={}; Rumble.__index=Rumble
local EPSILON=0.000001
local function finite(n) return type(n)=="number" and n==n and math.abs(n)<math.huge end
local function active(n,threshold) return finite(n) and n>0 and n>=threshold end
local function clamp(n,a,b) return math.max(a,math.min(b,n)) end
local function copy(t)
    if type(t)~="table" then return t end
    local out={}; for k,v in pairs(t) do out[k]=copy(v) end; return out
end
function Rumble.curve(curve,t)
    local keys=curve.keys or {}
    if #keys==0 then return finite(curve.default) and curve.default or 0 end
    if t<=keys[1].time then return keys[1].value end
    if t>=keys[#keys].time then return keys[#keys].value end
    for i=1,#keys-1 do
        local a,b=keys[i],keys[i+1]
        if t>=a.time and t<b.time then
            local dt=b.time-a.time
            if dt<=0 then return b.value end
            local u=(t-a.time)/dt
            if a.interp==1 then return a.value end -- RCIM_Constant
            if a.interp==2 then -- Unweighted cubic Hermite; weighted curves are rejected at intake.
                local u2,u3=u*u,u*u*u
                return (2*u3-3*u2+1)*a.value+(u3-2*u2+u)*dt*(a.leave or 0)
                    +(-2*u3+3*u2)*b.value+(u3-u2)*dt*(b.arrive or 0)
            end
            return a.value+(b.value-a.value)*u
        end
    end
    return 0
end
function Rumble.new(config,templates,emit,stop,eventFlags)
    return setmetatable({config=config,templates=templates,emit=emit,stop=stop,eventFlags=eventFlags,streams={},nextEmit=0},Rumble)
end
local function restoreExecution(s)
    if not s.executionKey then return end
    s.name,s.kind,s.noElectrical=s.executionOriginalName,s.executionOriginalKind,s.executionOriginalNoElectrical
    s.executionKey,s.executionOriginalName,s.executionOriginalKind,s.executionOriginalNoElectrical=nil,nil,nil,nil
end
local function promoteExecution(self,s)
    local context=self.executionContext
    local eligible=context and finite(s.bornGame) and s.bornGame+EPSILON>=context.game
        and (s.executionOriginalKind or s.kind or "generic")=="generic"
    if not eligible then restoreExecution(s);return end
    if not s.executionKey then
        s.executionOriginalName,s.executionOriginalKind,s.executionOriginalNoElectrical=s.name,s.kind,s.noElectrical
    end
    s.executionKey=context.token;s.name,s.kind,s.noElectrical="ExecutionStart","attack",true
end
function Rumble:execution(context)
    if type(context)~="table" or type(context.key)~="string" or context.key=="" or
        not finite(context.game) or not finite(context.real) or not finite(context.generation) then context=nil end
    if self.eventFlags and not self.eventFlags.ExecutionStart then context=nil end
    local previous=self.executionContext
    if context and previous and context.key==previous.key and context.generation==previous.generation then return false end
    if not context and not previous then return false end
    if self.outputExecutionKey then
        if self.output then self.stop(self.output) end
        self.output,self.outputExecutionKey=nil,nil
    end
    for _,s in pairs(self.streams) do restoreExecution(s) end
    self.executionContext=context and {key=context.key,game=context.game,real=context.real,generation=context.generation,
        token=context.key..":"..context.generation} or nil
    for _,s in pairs(self.streams) do promoteExecution(self,s) end
    self.revision=(self.revision or 0)+1
    return true
end
function Rumble:reset()
    self.streams={}; self.nextEmit=0;self.cadenceOrigin=nil;self.executionContext=nil
    self.revision=(self.revision or 0)+1;self.lastStepReal=nil
    if self.output then self.stop(self.output); self.output=nil end
    self.outputExecutionKey=nil
end
function Rumble:remove(key)
    self.revision=(self.revision or 0)+1
    self.streams[key]=nil
    if next(self.streams)==nil and self.output then self.stop(self.output); self.output=nil;self.outputExecutionKey=nil end
end
function Rumble:asset(key,data,clocks)
    if not self.config.Enabled or not finite(data.duration) or data.duration<=0 or #data.channels==0 then return false end
    if self.eventFlags and not self.eventFlags[data.name] then return false end
    local count=0;for _ in pairs(self.streams) do count=count+1 end
    if not self.streams[key] and count>=self.config.MaxStreams then return false end
    local keepIntro,previousBorn=false,nil
    if data.tag and data.tag~="" and data.tag~="None" then
        for k,s in pairs(self.streams) do
            if s.tag==data.tag then
                if s.path==data.path and (s.executionOriginalName or s.name)==data.name and s.loop and data.loop then
                    keepIntro=s.intro;previousBorn=s.bornGame
                end
                self.streams[k]=nil
            end
        end
    end
    data.elapsed=0; data.game=clocks.game; data.real=clocks.real; data.intro=keepIntro;data.bornGame=previousBorn or clocks.game
    promoteExecution(self,data)
    self.revision=(self.revision or 0)+1
    self.streams[key]=data
    return true
end
function Rumble:dynamic(key,intensity,duration,flags,action,clocks)
    if not self.config.Enabled or not key or not finite(intensity) or not finite(duration) then return end
    if action==2 then self:remove(key); return end
    if action~=0 and action~=1 then return end
    if self.eventFlags and not self.eventFlags.ControllerRumble then return end
    if action==1 and not self.streams[key] then return end -- UE Update doesn't start an inactive action.
    if intensity<=0 or not (flags[1] or flags[2] or flags[3] or flags[4]) or duration==0 then self:remove(key); return end
    local count=0;for _ in pairs(self.streams) do count=count+1 end
    if not self.streams[key] and count>=self.config.MaxStreams then return end
    self.revision=(self.revision or 0)+1
    local previous=action==1 and self.streams[key]
    local data={intensity=clamp(intensity,0,1),duration=duration,flags=flags,elapsed=0,
        name="ControllerRumble",kind="generic",game=clocks.game,real=clocks.real,intro=previous and previous.intro or false,
        bornGame=previous and previous.bornGame or clocks.game}
    promoteExecution(self,data);self.streams[key]=data
end
function Rumble:stopAsset(path,tag)
    self.revision=(self.revision or 0)+1
    for key,s in pairs(self.streams) do
        if s.channels and (not path or s.path==path) and (not tag or tag=="None" or tag=="" or s.tag==tag) then self.streams[key]=nil end
    end
    if next(self.streams)==nil and self.output then self.stop(self.output); self.output=nil;self.outputExecutionKey=nil end
end
local function peakChannel(s,c,start,finish)
    if s.intensity then return s.intensity end
    local result=0
    -- Peak over the most recent short window; never anticipate a future curve peak.
    local span=math.max(0,finish-start)
    local count=math.max(1,math.ceil(span/0.01))
    for i=0,count do
        local time=start+span*i/count
        if s.loop then time=time%s.duration end
        result=math.max(result,Rumble.curve(c.curve,time))
    end
    return clamp(result,0,1)
end
local lowLeft={5,105}
local mediumLeft={1,5,9,101,105,109}
local function points(side,value,smallOnly,config)
    local ids={}
    if value<config.MediumRangeAt then ids=copy(lowLeft)
    elseif value<config.FullRangeAt then ids=copy(mediumLeft)
    else
        for row=0,(smallOnly and 2 or 4) do
            for col=0,1 do ids[#ids+1]=row*4+col;ids[#ids+1]=100+row*4+col end
        end
    end
    if side=="right" then
        for i,v in ipairs(ids) do local face=v>=100 and 100 or 0;local p=v-face;ids[i]=face+math.floor(p/4)*4+3-p%4 end
    end
    table.sort(ids);return ids
end
function Rumble:step(clocks,paused,scale,enabled,suppressGeneric,generation)
    if not self.config.Enabled or not enabled then self:reset();return end
    local deadzone=finite(self.config.Deadzone) and clamp(self.config.Deadzone,0,1) or 0
    if self.executionContext and self.eventFlags and not self.eventFlags.ExecutionStart then self:execution(nil) end
    if self.lastStepReal==clocks.real and self.lastStepRevision==(self.revision or 0) then return end
    self.lastStepReal,self.lastStepRevision=clocks.real,self.revision or 0
    local values={0,0,0,0};local winner,winningPeak;local remaining=0
    for key,s in pairs(self.streams) do
        local dt=(s.ignoreDilation and clocks.real-s.real or clocks.game-s.game)
        s.real,s.game=clocks.real,clocks.game
        if not paused or s.playPaused then s.elapsed=s.elapsed+math.max(0,dt) end
        if not s.loop and s.duration>=0 and s.elapsed>=s.duration and s.sampled then self.streams[key]=nil
        elseif not paused or (self.config.MirrorWhilePaused and s.playPaused) then
            local channels={0,0,0,0}
            local start=math.max(0,s.elapsed-self.config.SliceMs/1000)
            if not s.sampled and not s.loop and s.duration>=0 and start>=s.duration then start=0 end
            local finish=s.elapsed
            if not s.loop and s.duration>=0 then finish=math.min(finish,s.duration) end
            if s.intensity then
                for i=1,4 do if s.flags[i] then channels[i]=s.intensity end end
            else
                for _,c in ipairs(s.channels) do
                    local v=peakChannel(s,c,start,finish)
                    for i=1,4 do if c.flags[i] then channels[i]=math.max(channels[i],v) end end
                end
            end
            local p=math.max(table.unpack(channels))*scale
            if not (s.kind=="generic" and suppressGeneric) then
                for i=1,4 do values[i]=math.max(values[i],clamp(channels[i]*scale,0,1)) end
                local execution=s.executionKey~=nil and active(p,deadzone)
                local previousExecution=winner~=nil and winner.executionKey~=nil and active(winningPeak,deadzone)
                if not winningPeak or (execution and not previousExecution) or
                    (execution==previousExecution and p>winningPeak) then winner,winningPeak=s,p end
                if active(p,deadzone) then
                    if s.loop or s.duration<0 then remaining=math.huge
                    else remaining=math.max(remaining,s.duration-s.elapsed) end
                end
            end
            s.sampled=true
        end
    end
    local overall=math.max(table.unpack(values))
    if not winner or not active(overall,deadzone) then
        if self.output then self.stop(self.output);self.output=nil;self.outputExecutionKey=nil end
        return
    end
    if clocks.real+EPSILON<self.nextEmit then return end
    local name=winner.name or "ControllerRumble"
    local continuation=self.config.ContinuationMs
    if not finite(continuation) then continuation=200 end
    continuation=clamp(math.floor(continuation+0.5),70,250)
    -- Keep the existing strength-to-duration shape, adding a finite coverage
    -- allowance so the next 100ms refresh arrives before this slice expires.
    local baseMs=clamp(math.floor(70+30*overall+0.5),70,self.config.SliceMs)
    local pulseMs=math.min(continuation,baseMs+math.max(0,continuation-self.config.SliceMs))
    if finite(remaining) then pulseMs=math.max(70,math.min(pulseMs,math.ceil(remaining*1000))) end
    local effect={name=name,uuid=name,keep="False",priority=0,tracks={}}
    local sides={left=math.max(values[1],values[2]),right=math.max(values[3],values[4])}
    -- Explicit game hand cues determine their presentation side; motor flags do not identify a hand.
    if name=="LeftHandLadder" then sides={left=overall,right=0}
    elseif name=="RightHandLadder" then sides={left=0,right=overall} end
    local band=self.config.Bands[winner.kind] or self.config.Bands.generic
    local power=math.floor(band[1]+(band[2]-band[1])*overall+0.5)/100
    for _,side in ipairs({"left","right"}) do
        local value=sides[side]
        if active(value,deadzone) then
            -- Normalize the strongest side to 100. PlayPower scales the copy
            -- on submission; relative motor amplitudes, times and points remain.
            -- Round the desired SDK level first so normalization cannot turn
            -- an exact half-level (e.g. 10.5) into 10.499999999999998.
            local intensity=math.floor(band[1]+(band[2]-band[1])*value+0.5)/power
            effect.tracks[#effect.tracks+1]={start_time=0,end_time=pulseMs,stop_name="",start_intensity=intensity,
                end_intensity=intensity,intensity_mode="Const",action_type="Shake",once="False",interval=0,
                index=points(side,value,side=="left" and values[1]==0 or side=="right" and values[3]==0,self.config)}
        end
    end
    if #effect.tracks==0 then return end -- Never submit an empty or Electrical-only rumble slice.
    local lowInputFirst=overall<0.03 and not winner.intro
    if not winner.noElectrical and not winner.intro and self.templates[name] then
        for _,track in ipairs(self.templates[name].tracks) do
            if track.action_type=="Electrical" then effect.tracks[#effect.tracks+1]=copy(track) end
        end
    end
    winner.intro=true
    if self.output and self.output~=name then self.stop(self.output) end
    self.output=name;self.outputExecutionKey=winner.executionKey
    self.cadenceOrigin=self.cadenceOrigin or clocks.real
    local cadence=self.config.SliceMs/1000
    local nextSlot=math.floor((clocks.real-self.cadenceOrigin+EPSILON)/cadence)+1
    self.nextEmit=self.cadenceOrigin+nextSlot*cadence
    self.emit(name,effect,generation,{input=overall,power=power,pulse_ms=pulseMs,kind=winner.kind,
        source=winner.path or "PlayDynamicForceFeedback",low_input_first=lowInputFirst})
end
return Rumble
