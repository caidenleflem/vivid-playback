import Foundation

/// The Vivid Recorder plugin for grandMA3 (made for 2.3): import it into the show, run it once
/// to start and again to stop. While it runs, every change of cue (or on/off) on the sequences
/// of the fader page you're on goes to Vivid Playback, to record onto the selected song's lanes.
/// Run with the argument "test" (Plugin "Vivid Recorder" "test") it lists what it sees instead.
public enum DeskPlugin {
    public static let name = "VividRecorder"

    /// The two files to import: the plugin's XML and its Lua.
    public static func files(oscLine: Int = 1) -> [(name: String, contents: String)] {
        [("\(name).xml", xml), ("\(name).lua", lua(oscLine: oscLine))]
    }

    /// Both plugins' files: the recorder and Vivid Labels.
    public static func allFiles(oscLine: Int = 1) -> [(name: String, contents: String)] {
        files(oscLine: oscLine) + Labels.files(oscLine: oscLine)
    }

    /// Vivid Labels: run it on the desk and it sends the name of every sequence on the fader page
    /// you're on, so Vivid Playback can name the lanes that fire those executors.
    public enum Labels {
        public static let name = "VividLabels"

        public static func files(oscLine: Int = 1) -> [(name: String, contents: String)] {
            [("\(name).xml", xml), ("\(name).lua", lua(oscLine: oscLine))]
        }

        public static let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <GMA3 DataVersion="2.3.2.0">
        \t<Plugin Name="Vivid Labels" Version="1.0.0.0">
        \t\t<ComponentLua Name="\(name)" FileName="\(name).lua" />
        \t</Plugin>
        </GMA3>

        """

        public static func lua(oscLine: Int = 1) -> String {
            luaTemplate.replacingOccurrences(of: "__OSC_LINE__", with: String(max(1, oscLine)))
        }

        static let luaTemplate = #"""
        -- Vivid Labels for grandMA3 (made for 2.3)
        -- Run it on the fader page you want: it sends the name of each executor's sequence to
        -- Vivid Playback, which names the lanes that fire those executors.
        -- OSC_LINE is the line in Menu > In & Out > OSC that sends to the Mac running Vivid Playback.

        local OSC_LINE = __OSC_LINE__

        local function prop(h, key)
          if h == nil then return nil end
          local ok, v = pcall(function() return h:Get(key) end)
          if ok and v ~= nil then return v end
          ok, v = pcall(function() return h[key] end)
          if ok then return v end
          return nil
        end

        local function children(h)
          local ok, list = pcall(function() return h:Children() end)
          if ok and type(list) == "table" then return list end
          return {}
        end

        local function className(h)
          local ok, c = pcall(function() return h:GetClass() end)
          if ok then return tostring(c) end
          return ""
        end

        -- Text that can't break the OSC command: no quotes, commas or semicolons.
        local function clean(s)
          s = tostring(s or "")
          s = s:gsub('[",;]', " "):gsub("%s+", " "):gsub("^ ", ""):gsub(" $", "")
          return s
        end

        local function Main(display, argument)
          local page = CurrentExecPage()
          local pageNo = tonumber(prop(page, "No")) or 1
          local sent = 0
          for _, exec in ipairs(children(page)) do
            local seq = prop(exec, "Object")
            local no = tonumber(prop(exec, "No"))
            if seq ~= nil and no ~= nil and className(seq) == "Sequence" then
              local name = clean(prop(seq, "Name"))
              if name ~= "" then
                local cmd = string.format('SendOSC %d "/vivid/label,ss,%d.%d,%s"', OSC_LINE, pageNo, no, name)
                if not (CmdIndirect ~= nil and pcall(function() CmdIndirect(cmd) end)) then pcall(function() Cmd(cmd) end) end
                sent = sent + 1
                coroutine.yield(0.01)
              end
            end
          end
          Printf("Vivid Labels sent %d name%s from page %d on OSC line %d.", sent, sent == 1 and "" or "s", pageNo, OSC_LINE)
        end

        return Main
        """#
    }

    public static let xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <GMA3 DataVersion="2.3.2.0">
    \t<Plugin Name="Vivid Recorder" Version="1.0.0.0">
    \t\t<ComponentLua Name="\(name)" FileName="\(name).lua" />
    \t</Plugin>
    </GMA3>

    """

    public static func lua(oscLine: Int = 1) -> String {
        luaTemplate.replacingOccurrences(of: "__OSC_LINE__", with: String(max(1, oscLine)))
    }

    static let luaTemplate = #"""
    -- Vivid Recorder for grandMA3 (made for 2.3)
    -- Vivid Playback starts and stops it with Record desk (Plugin "Vivid Recorder" "start" / "stop");
    -- run by hand it starts, and run again it stops. It stops by itself after three hours.
    -- While it runs, each press-made change of cue, or on/off, on the sequences of the fader page
    -- you're on goes to Vivid Playback over OSC. It never sends the instant a cue fires: changes
    -- wait a quarter of a second and go through the command queue, so a macro a cue starts runs
    -- undisturbed (each one carries the desk's time, so the wait doesn't move it in Vivid).
    -- Plugin "Vivid Recorder" "test" lists what it sees instead.
    --
    -- OSC_LINE is the line in Menu > In & Out > OSC that sends to the Mac running Vivid Playback
    -- (its address and the port Vivid listens on, with Send on).

    local OSC_LINE = __OSC_LINE__
    local LOOK_EVERY = 0.01   -- seconds between looks at the executors
    local SETTLE = 25         -- looks to wait before sending a change (a quarter of a second)
    local MAX_LOOKS = 3 * 60 * 60 * 100   -- stops by itself after three hours

    -- Sends a command without cutting into whatever the desk is running (a macro a cue started):
    -- through the command queue when the desk offers it.
    local function issue(cmd)
      local ok = false
      if CmdIndirect ~= nil then ok = pcall(function() CmdIndirect(cmd) end) end
      if not ok then pcall(function() Cmd(cmd) end) end
    end

    local function prop(h, key)
      if h == nil then return nil end
      local ok, v = pcall(function() return h:Get(key) end)
      if ok and v ~= nil then return v end
      ok, v = pcall(function() return h[key] end)
      if ok then return v end
      return nil
    end

    local function children(h)
      local ok, list = pcall(function() return h:Children() end)
      if ok and type(list) == "table" then return list end
      return {}
    end

    local function className(h)
      local ok, c = pcall(function() return h:GetClass() end)
      if ok then return tostring(c) end
      return ""
    end

    -- Cue numbers can come back as text ("5.5") or in thousandths (5500).
    local function cueNumber(cue)
      local n = tonumber(prop(cue, "No"))
      if n == nil then return nil end
      if n >= 1000 and n % 1 == 0 then n = n / 1000 end
      return n
    end

    local function cueText(n)
      if n == nil then return "-" end
      if n % 1 == 0 then return string.format("%d", n) end
      return (string.format("%.3f", n):gsub("0+$", ""):gsub("%.$", ""))
    end

    -- Text that can't break the OSC command: no quotes, commas or semicolons.
    local function clean(s)
      s = tostring(s or "")
      s = s:gsub('[",;]', " ")
      if s == "" then return "-" end
      return s
    end

    -- The real cues of a sequence, in order (no OffCue, no CueZero).
    local function realCues(seq)
      local out = {}
      for _, c in ipairs(children(seq)) do
        local n = cueNumber(c)
        local name = tostring(prop(c, "Name") or "")
        if n ~= nil and n > 0 and name ~= "OffCue" and name ~= "CueZero" then
          out[#out + 1] = c
        end
      end
      return out
    end

    -- How a cue is triggered ("Go", "Follow", "Time", "Sound", "BPM", "Timecode"…), from the cue
    -- or its first part. "" when the desk doesn't say.
    local function trigOf(cue)
      for _, h in ipairs({ cue, children(cue)[1] }) do
        for _, key in ipairs({ "Trig", "TrigType", "Trigger" }) do
          local v = prop(h, key)
          if v ~= nil and tostring(v) ~= "" then return tostring(v) end
        end
      end
      return ""
    end

    -- A cue that runs by itself (Follow, Time, Sound, BPM, Timecode) isn't a button press.
    local function firesItself(cue)
      local t = string.lower(trigOf(cue))
      return t:find("follow") or t:find("time") or t:find("sound") or t:find("bpm") or t:find("timecode")
    end

    -- Where a sequence is: on or off, the cue number, its place in the list (0 = first), its name.
    local function where(seq)
      local ok, current = pcall(function() return seq:CurrentChild() end)
      if not ok or current == nil then return false, nil, -1, nil, false end
      local number = cueNumber(current)
      if number == nil or number <= 0 then return false, nil, -1, nil, false end
      local index = -1
      for i, c in ipairs(realCues(seq)) do
        if cueNumber(c) == number then index = i - 1 break end
      end
      return true, number, index, prop(current, "Name"), firesItself(current)
    end

    -- The executors with a sequence on the fader page you're on.
    local function onThisPage()
      local page = CurrentExecPage()
      local pageNo = tonumber(prop(page, "No")) or 1
      local out = {}
      for _, exec in ipairs(children(page)) do
        local seq = prop(exec, "Object")
        local no = tonumber(prop(exec, "No"))
        if seq ~= nil and no ~= nil and className(seq) == "Sequence" then
          out[#out + 1] = { key = string.format("%d.%d", pageNo, no), seq = seq }
        end
      end
      return out
    end

    -- The desk's clock, so Vivid can put each change where it happened even when a burst of
    -- them takes a while to send. -1 when it can't be read.
    local function deskTime()
      local ok, t = pcall(function() return Time() end)
      if ok and type(t) == "number" then return t end
      return -1
    end

    local function message(key, now, before, stamp)
      return string.format('SendOSC %d "/vivid/seq,ssssssss,%s,%s,%s,%d,%d,%s,%s,%.4f"',
        OSC_LINE, key, now.on and "on" or "off", cueText(now.number), now.index,
        before.index, before.on and "on" or "off", clean(now.name), stamp)
    end

    -- Lists the desk's timecode shows (their tracks and first events) so Vivid can learn how they
    -- look on this desk, to tell a timecode show's own moves from a press.
    local function describe(v)
      if type(v) == "string" or type(v) == "number" or type(v) == "boolean" then return tostring(v) end
      return className(v) .. ":" .. tostring(prop(v, "Name") or "")
    end

    local function dumpTimecodes()
      local dp = nil
      pcall(function() dp = DataPool() end)
      if dp == nil then Printf("Timecode shows: DataPool() can't be read.") return end
      local pool = nil
      for _, c in ipairs(children(dp)) do
        local n = tostring(prop(c, "Name") or "")
        if className(c):find("Timecode") or n:find("Timecode") then pool = c break end
      end
      if pool == nil then Printf("Timecode shows: no timecode pool found in the data pool.") return end
      Printf("Timecode shows (%s):", describe(pool))
      local lines = 0
      local function walk(h, depth)
        if lines >= 60 then return end
        local bits = {}
        for _, k in ipairs({ "No", "Name", "Time", "Token", "Cmd", "Object", "Target", "Status", "Playing", "CurrentTime", "Duration", "TCSlot" }) do
          local v = prop(h, k)
          if v ~= nil and tostring(v) ~= "" then bits[#bits + 1] = k .. "=" .. describe(v) end
        end
        Printf("%s%s  %s", string.rep("  ", depth + 1), className(h), table.concat(bits, " "))
        lines = lines + 1
        if depth < 6 then
          for i, c in ipairs(children(h)) do
            if i > 4 then break end
            walk(c, depth + 1)
          end
        end
      end
      for i, tc in ipairs(children(pool)) do
        if i > 2 then break end
        walk(tc, 0)
      end
    end

    local function test()
      Printf("Vivid Recorder sees, on this page:")
      for _, e in ipairs(onThisPage()) do
        local on, number, index, name, auto = where(e.seq)
        local current = nil
        pcall(function() current = e.seq:CurrentChild() end)
        Printf("  %s  %s  cue %s (place %d)  %s  trig: %s%s", e.key, on and "on" or "off", cueText(number), index,
          tostring(name or ""), current and trigOf(current) or "-", auto and "  (runs itself: not recorded)" or "")
      end
      Printf("It would send them on OSC line %d. Desk clock reads %s.", OSC_LINE, tostring(deskTime()))
      dumpTimecodes()
    end

    local function Main(display, argument)
      local arg = string.lower(tostring(argument or ""))
      if arg == "test" then test() return end
      if arg == "stop" or (arg ~= "start" and _G.VividRecorderRunning) then
        if _G.VividRecorderRunning then Printf("Vivid Recorder stopped.") end
        _G.VividRecorderRunning = false
        return
      end
      if _G.VividRecorderRunning then return end   -- "start" while already running
      _G.VividRecorderRunning = true
      Printf("Vivid Recorder is sending to Vivid Playback on OSC line %d.", OSC_LINE)
      local last = {}
      local pending = {}
      local looks = 0
      while _G.VividRecorderRunning do
        looks = looks + 1
        if looks > MAX_LOOKS then
          _G.VividRecorderRunning = false
          Printf("Vivid Recorder stopped by itself after three hours.")
          break
        end
        -- One stamp per look: everything that changed since the last look happened just now.
        local stamp = deskTime()
        for _, e in ipairs(onThisPage()) do
          local on, number, index, name, auto = where(e.seq)
          local now = { on = on, number = number, index = index, name = name }
          local before = last[e.key]
          -- Off keeps the cue it was on, so turning it back on there reads as On.
          if not on and before ~= nil then
            now.number, now.index, now.name = before.number, before.index, before.name
          end
          -- The first look at an executor (or a page) only learns where it is.
          -- Only presses: a cue that ran by itself (Follow, Time…) moves on without being sent.
          if before ~= nil and (before.on ~= now.on or before.number ~= now.number) and not (on and auto) then
            pending[#pending + 1] = { at = looks, cmd = message(e.key, now, before, stamp) }
          end
          last[e.key] = now
        end
        -- Send what has waited long enough, oldest first.
        while #pending > 0 and looks - pending[1].at >= SETTLE do
          issue(table.remove(pending, 1).cmd)
        end
        coroutine.yield(LOOK_EVERY)
      end
      -- Whatever was still waiting when it stopped.
      for _, p in ipairs(pending) do issue(p.cmd) end
    end

    return Main
    """#
}
