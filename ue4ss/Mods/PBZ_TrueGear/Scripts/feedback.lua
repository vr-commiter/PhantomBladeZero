-- One serialized consumer calls the supplied Lua SDK. Bridge owns network I/O.
local Feedback = {}
Feedback.__index = Feedback
function Feedback.new(config, sdk, log, now, power)
    return setmetatable({config = config, sdk = sdk, log = log, now = now or os.time,
        queue = {}, started = false, ready = false, retryAt = 0, statusAt = 0,
        power=power,powerLogAt={},counts={queued=0,named=0,content=0,failed=0,dropped=0}}, Feedback)
end
function Feedback:PlayPower(name,power,generation,content,meta)
    if type(power)~="number" or power~=power or math.abs(power)==math.huge or power<=0 then return end
    local event=self:enqueue(name,"play-power",generation)
    if event then
        event.power=math.min(1,power);event.content=content;event.meta=meta or {};event.rumble=true
    end
    return event
end
function Feedback:enqueue(name, cause, generation)
    if not self.config.Enabled or not self.config.Events[name] then return end
    if #self.queue >= self.config.QueueLimit then
        self.counts.dropped=self.counts.dropped+1
        self.log("queue-full: dropped " .. name)
        return
    end
    local event = {name = name, cause = cause, generation = generation, at = self.now()}
    self.queue[#self.queue + 1] = event
    self.counts.queued=self.counts.queued+1
    return event
end
function Feedback:enqueueContent(name,content,generation,meta)
    local event=self:enqueue(name,"controller-rumble",generation)
    if event then event.content=content;event.rumble=true;event.meta=meta end
end
function Feedback:enqueuePrimaryContent(name,content,cause,generation,meta)
    local event=self:enqueue(name,cause,generation)
    if event then
        event.content=content;event.meta=meta or {};event.meta.primary=true
        -- Semantic contact content is not a generic rumble slice. A later
        -- primary event must not cancel this already confirmed foot contact.
    end
    return event
end
function Feedback:stopRumble(name,generation)
    local keep={}
    for _,event in ipairs(self.queue) do
        if not (event.rumble and event.name==name) then keep[#keep+1]=event end
    end
    self.queue=keep
    if #self.queue<self.config.QueueLimit then
        self.queue[#self.queue+1]={name=name,stop=true,generation=generation,at=self.now()}
    end
end
function Feedback:pump(generation)
    local now = self.now()
    if not self.started then
        if now < self.retryAt then self.queue = {}; return end
        self.retryAt = now + 5
        local ok, player = pcall(self.sdk.new, self.config.AppId, self.config.GameName)
        if ok then
            local started, result, err = pcall(player.start, player)
            if started and result then self.player, self.started = player, true
            else self.log("SDK start failed: " .. tostring(err or result)) end
        else self.log("SDK create failed: " .. tostring(player)) end
    end
    if not self.started then self.queue = {}; return end
    if now >= self.statusAt then
        self.statusAt = now + 1
        local ok, registered, state = pcall(self.player.get_status, self.player)
        registered = ok and registered == true
        if not self.reportedStatus or registered ~= self.ready then
            self.log("SDK registered=" .. tostring(registered) .. "; state=" .. tostring(state))
            self.reportedStatus = true
        end
        self.ready = registered
        if not registered and now >= self.retryAt then
            self.retryAt = now + 5
            pcall(self.player.send_register, self.player)
        end
    end
    local queued = self.queue
    self.queue = {} -- No stale replay, including after a send exception.
    if not self.ready or not self.config.Enabled then
        if #queued>0 then
            self.counts.dropped=self.counts.dropped+#queued
            if self.config.Debug and now ~= self.lastDropLog then
                self.lastDropLog = now
                self.log("SDK-skip queued=" .. #queued .. " registered=" .. tostring(self.ready) .. " enabled=" .. tostring(self.config.Enabled))
            end
        end
        return
    end
    for _, event in ipairs(queued) do
        if event.generation == generation and now - event.at <= 1 then
            local powerReady=true
            if event.power then
                local ok,content,reason=pcall(function()
                    if not self.power then return nil,"PlayPower helper unavailable" end
                    return self.power:content(self.player,event.name,event.power,event.content)
                end)
                powerReady=ok and content~=nil
                if powerReady then event.content=content
                else
                    self.counts.dropped=self.counts.dropped+1
                    if now>=(self.powerLogAt[event.name] or 0) then
                        self.powerLogAt[event.name]=now+5
                        self.log("PlayPower-skip "..event.name..": "..tostring(ok and reason or content))
                    end
                end
            end
            if powerReady then
                local method
                if event.stop then method=self.player.stop_effect
                elseif event.content then method=self.player.send_play_effect_by_content
                else method=self.player.send_play end
                local ok, sent, err = pcall(method, self.player, event.content or event.name)
                if ok and sent then
                    if event.stop then
                        if self.config.Debug then self.log("SDK-stop " .. event.name) end
                    elseif event.content then
                        self.counts.content=self.counts.content+1
                        local meta=event.meta or {}
                        if self.config.Debug or meta.input == "manual-test" then
                            local peak,points,unique=0,0,{}
                            for _,track in ipairs(event.content.tracks or {}) do
                                if track.action_type=="Shake" then
                                    peak=math.max(peak,track.start_intensity or 0)
                                    for _,point in ipairs(track.index or {}) do if not unique[point] then unique[point]=true;points=points+1 end end
                                end
                            end
                            self.log("SDK-content " .. event.name .. " input=" .. tostring(meta.input) .. " pulse_ms=" .. tostring(meta.pulse_ms)..
                                " shake_peak="..peak.." points="..points..(event.power and " power="..event.power or "")..
                                (meta.kind and " kind="..tostring(meta.kind) or "")..(meta.source and " source="..tostring(meta.source) or "")..
                                (meta.low_input_first and " low_input_first=true" or "")..
                                " submitted="..self.counts.content)
                        end
                    else
                        self.counts.named = self.counts.named + 1
                        if self.config.Debug then
                            self.log("SDK-submit " .. event.name .. " [" .. event.cause .. "]")
                        end
                    end
                else self.counts.failed=self.counts.failed+1;self.log("SDK-submit-failed " .. event.name .. ": " .. tostring(err or sent)) end
            end
        end
    end
end
return Feedback
