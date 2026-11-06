-- Pure damage classification and finite content; all inputs are copied scalars.
local Damage={}
local function clone(value)
    if type(value)~="table" then return value end
    local out={};for key,item in pairs(value) do out[key]=clone(item) end;return out
end
local function clamp(value,low,high) return math.max(low,math.min(high,value)) end
function Damage.content(template,details,config)
    details=details or {};config=config or {}
    local amount,max=details.amount or 0,details.maxHp or 0
    local ratio=max>0 and amount/max or 0
    local periodic=config.DotCauses and config.DotCauses[details.damageCause]==true
    local highRatio=math.max(0.000001,config.HighDamageRatio or 0.15)
    local kind=periodic and "periodic" or (ratio>=highRatio and "high" or "low")
    local minimum=clamp(math.floor(config.MinimumIntensity or 70),0,100)
    local lowRatio=clamp(config.LowDamageRatio or 0.05,0,highRatio-0.000001)
    local power=clamp((ratio-lowRatio)/(highRatio-lowRatio),0,1)
    -- Direct damage interpolates from70 at5% HP loss to100 at15%, then truncates.
    local shakeIntensity=clamp(math.floor(minimum+(clamp(config.ShakePeak or 100,minimum,100)-minimum)*power),minimum,100)
    local electricalIntensity=clamp(math.floor(minimum+(clamp(config.ElectricalPeak or 100,minimum,100)-minimum)*power),minimum,100)
    local out=clone(template)
    if periodic then
        local shake,electrical
        for _,track in ipairs(out.tracks) do
            if track.action_type=="Shake" and not shake then shake=track
            elseif track.action_type=="Electrical" and not electrical then electrical=track end
        end
        assert(shake,"PlayerDamage needs a Shake template")
        shake.start_time=0;shake.end_time=90
        out.tracks={shake}
        if electrical then
            electrical.start_time=0;electrical.end_time=90
            out.tracks[#out.tracks+1]=electrical
        end
        shakeIntensity=clamp(math.floor(config.PeriodicIntensity or 50),0,100)
        electricalIntensity=shakeIntensity
    end
    for _,track in ipairs(out.tracks) do
        if track.action_type=="Shake" then
            track.start_intensity=shakeIntensity;track.end_intensity=shakeIntensity
        elseif track.action_type=="Electrical" then
            track.start_intensity=electricalIntensity;track.end_intensity=electricalIntensity
            track.intensity_mode="Const"
            track.once=config.ElectricalOnce or "False"
            track.interval=periodic and (config.PeriodicElectricalInterval or 1) or (config.ElectricalInterval or 10)
        end
    end
    return out,kind,ratio
end
return Damage
