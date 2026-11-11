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
                Cmd(string.format('SendOSC %d "/vivid/label,ss,%d.%d,%s"', OSC_LINE, pageNo, no, name))
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
    -- Run it once to start, again to stop. While it runs, every change of cue, or on/off, on the
    -- sequences of the fader page you're on is sent to Vivid Playback over OSC, to record onto
    -- the selected song's lanes. Plugin "Vivid Recorder" "test" lists what it sees instead.
    --
    -- OSC_LINE is the line in Menu > In & Out > OSC that sends to the Mac running Vivid Playback
    -- (its address and the port Vivid listens on, with Send on).

    local OSC_LINE = __OSC_LINE__
    local LOOK_EVERY = 0.02   -- seconds between looks at the executors

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

    -- Where a sequence is: on or off, the cue number, its place in the list (0 = first), its name.
    local function where(seq)
      local ok, current = pcall(function() return seq:CurrentChild() end)
      if not ok or current == nil then return false, nil, -1, nil end
      local number = cueNumber(current)
      if number == nil or number <= 0 then return false, nil, -1, nil end
      local index = -1
      for i, c in ipairs(realCues(seq)) do
        if cueNumber(c) == number then index = i - 1 break end
      end
      return true, number, index, prop(current, "Name")
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

    local function send(key, now, before)
      Cmd(string.format('SendOSC %d "/vivid/seq,sssssss,%s,%s,%s,%d,%d,%s,%s"',
        OSC_LINE, key, now.on and "on" or "off", cueText(now.number), now.index,
        before.index, before.on and "on" or "off", clean(now.name)))
    end

    local function test()
      Printf("Vivid Recorder sees, on this page:")
      for _, e in ipairs(onThisPage()) do
        local on, number, index, name = where(e.seq)
        Printf("  %s  %s  cue %s (place %d)  %s", e.key, on and "on" or "off", cueText(number), index, tostring(name or ""))
      end
      Printf("It would send them on OSC line %d.", OSC_LINE)
    end

    local function Main(display, argument)
      if argument == "test" then test() return end
      if _G.VividRecorderRunning then
        _G.VividRecorderRunning = false
        Printf("Vivid Recorder stopped.")
        return
      end
      _G.VividRecorderRunning = true
      Printf("Vivid Recorder is sending to Vivid Playback on OSC line %d. Run it again to stop.", OSC_LINE)
      local last = {}
      while _G.VividRecorderRunning do
        for _, e in ipairs(onThisPage()) do
          local on, number, index, name = where(e.seq)
          local now = { on = on, number = number, index = index, name = name }
          local before = last[e.key]
          -- Off keeps the cue it was on, so turning it back on there reads as On.
          if not on and before ~= nil then
            now.number, now.index, now.name = before.number, before.index, before.name
          end
          -- The first look at an executor (or a page) only learns where it is.
          if before ~= nil and (before.on ~= now.on or before.number ~= now.number) then
            send(e.key, now, before)
          end
          last[e.key] = now
        end
        coroutine.yield(LOOK_EVERY)
      end
    end

    return Main
    """#
}
