-- PlayAngle's find/copy/transform/content pattern, with Shake power (0..1).
-- Called only by Feedback:pump. Finding a client effect can read SDK responses.
local Power={};Power.__index=Power
local function finite(n) return type(n)=="number" and n==n and math.abs(n)<math.huge end
local function clone(value)
    if type(value)~="table" then return value end
    local out={};for k,v in pairs(value) do out[k]=clone(v) end;return out
end
function Power.new(sdk,now)
    return setmetatable({sdk=sdk,now=now or os.time,seekAt={}},Power)
end
function Power:content(player,event,power,prepared)
    if type(event)~="string" or event=="" or not finite(power) then return nil,"invalid power request" end
    power=math.max(0,math.min(1,power))
    if power==0 then return nil,"zero power" end -- Includes Electrical: a silent request stays silent.
    local template=prepared
    if not template then
        if not player or type(player.find_effect_by_uuid)~="function" then return nil,"SDK effect lookup unavailable" end
        template=player:find_effect_by_uuid(event)
        if not template then
            local now=self.now()
            if now>=(self.seekAt[event] or -math.huge) then
                self.seekAt[event]=now+5 -- Consume before SDK I/O, even if it throws.
                if type(player.send_seek_effect_by_uuid)=="function" then player:send_seek_effect_by_uuid(event) end
            end
            return nil,"effect not ready"
        end
    end
    if type(template)~="table" or template.uuid~=event or type(template.tracks)~="table" then return nil,"invalid effect template" end
    local copy=self.sdk.copy_effect or clone
    local effect=copy(template)
    local activeShake=false
    for _,track in ipairs(effect.tracks) do
        if track.action_type=="Shake" then
            if not finite(track.start_intensity) or not finite(track.end_intensity) then return nil,"invalid Shake intensity" end
            track.start_intensity=math.floor(math.max(0,math.min(100,track.start_intensity))*power+0.5)
            track.end_intensity=math.floor(math.max(0,math.min(100,track.end_intensity))*power+0.5)
            activeShake=activeShake or track.start_intensity>0 or track.end_intensity>0
        end
    end
    if not activeShake then return nil,"no nonzero Shake track" end
    return effect
end
return Power
