--!nonstrict
-- Screen Capture — headless service.
--
-- Owns the recording. The bar widget and control-center tile are thin clients:
-- they open the "menu" panel so the user picks source/audio/webcam, then publish
-- a command here. This service runs the picker itself, because the panel has to
-- be closed before slurp freezes the screen, and turns the choice into a
-- scripts/record.sh run.
--
-- Everything goes through the panel; a right click replays the last choice
-- ("record-last") without opening it.

local state = "idle" -- idle | selecting | starting | stopping | recording
local outputPath = ""
local available = false
local recorder = nil
local lastChoice = nil

local scriptPath

local SOURCES = { region = true, window = true, fullscreen = true }
local AUDIOS = { none = true, default_output = true, default_input = true, both = true }

local function cfg(key) return noctalia.getConfig(key) end
local function log(msg) noctalia.log(`screen-capture: {msg}`) end
local function recordScript() return scriptPath end
local function sibling(name) return scriptPath:gsub("record%.sh$", name) end

-- ── state ──────────────────────────────────────────────────────────────────────

local function publish()
  noctalia.state.set("status", {
    state = state,
    available = available,
    outputPath = outputPath,
    choice = lastChoice,
  })
end

local function setState(next)
  if state == next then
    return
  end
  state = next
  publish()
end

-- ── notifications ──────────────────────────────────────────────────────────────

local function parseResult(result)
  local file, preview
  for line in (result.stdout or ""):gmatch("[^\r\n]+") do
    if line:match("^file=") then
      file = line:sub(6)
    elseif line:match("^preview=") then
      preview = line:sub(9)
    end
  end
  return file, preview
end

local function notifySaved(file, preview)
  if not file or file == "" then
    return
  end
  noctalia.notify(
    noctalia.tr("notify.saved"),
    noctalia.tr("notify.savedHint") .. "\n" .. file,
    preview ~= "" and preview or nil
  )
  if cfg("copy_to_clipboard") == true then
    noctalia.copyToClipboard("file://" .. file, "text/uri-list")
  end
end

-- ── choices ────────────────────────────────────────────────────────────────────

-- Seed a run from the panel's choice, falling back to the plugin settings.
local function normalize(choice)
  choice = choice or {}
  local source = SOURCES[choice.source] and choice.source or nil
  local audio = AUDIOS[choice.audio] and choice.audio or nil
  return {
    source = source or (lastChoice and lastChoice.source) or "region",
    audio = audio or (lastChoice and lastChoice.audio) or cfg("audio_source") or "both",
    webcam = choice.webcam == true,
  }
end

local function currentChoice()
  return lastChoice or normalize(nil)
end

local function baseArgs(chosen)
  local dir = noctalia.expandPath(cfg("directory") or "~/Videos/Recordings")
  if dir:sub(-1) ~= "/" then
    dir ..= "/"
  end
  noctalia.mkdirAll(dir)

  local webcam = "off"
  if chosen.webcam then
    webcam = cfg("webcam_size") or "medium"
  end

  return {
    string.format("--directory=%s", dir),
    string.format("--filename-pattern=%s", cfg("filename_pattern") or "capture_%Y-%m-%d_%H-%M-%S"),
    string.format("--audio=%s", chosen.audio),
    string.format("--frame-rate=%s", tostring(cfg("frame_rate") or 60)),
    string.format("--framerate-mode=%s", cfg("framerate_mode") or "cfr"),
    string.format("--quality=%s", cfg("quality") or "high"),
    string.format("--cursor=%s", cfg("show_cursor") == false and "no" or "yes"),
    string.format("--normalize=%s", cfg("normalize_audio") == false and "no" or "yes"),
    string.format("--webcam=%s", webcam),
  }
end

-- ── target resolution ──────────────────────────────────────────────────────────

-- pick-region.sh prints "X,Y WxH" for a rectangle and record.sh wants
-- "region:WxH+X+Y"; a whole-monitor selection already arrives as "monitor:NAME".
local function selectionToTarget(selection)
  if not selection or selection == "" then
    return nil
  end
  if selection:match("^monitor:") then
    return selection
  end
  local x, y, w, h = selection:match("^(-?%d+),(-?%d+)%s+(%d+)x(%d+)$")
  if not x then
    return nil
  end
  return string.format("region:%sx%s+%s+%s", w, h, x, y)
end

local function resolveTarget(chosen, onDone)
  if chosen.source == "fullscreen" then
    -- Ask the compositor through pick-region.sh rather than
    -- noctalia.focusedOutputName(): the latter can report nothing while the menu
    -- panel is still closing, which is how "no focused monitor" happened.
    noctalia.runAsync({ sibling("pick-region.sh"), "fullscreen", "--match-monitor" }, function(result)
      local target = selectionToTarget((result.stdout or ""):match("[^\r\n]+"))
      if target then
        onDone(target)
        return
      end
      -- Last resort if the picker could not resolve a monitor.
      local monitor = noctalia.focusedOutputName()
      if monitor and monitor ~= "" then
        onDone(string.format("monitor:%s", monitor))
      else
        noctalia.notifyError(noctalia.tr("notify.failed"), noctalia.tr("notify.noMonitor"))
        onDone(nil)
      end
    end)
    return
  end

  -- "window" feeds slurp the window rectangles and snaps a click to one;
  -- "region" is freeform. Both upgrade a full-monitor selection to a native
  -- monitor capture.
  local mode = chosen.source == "window" and "windows" or "region"

  -- Let the panel finish closing before the picker freezes the screen, or the
  -- panel shape ends up in the frozen frame.
  noctalia.runAsync({ "sleep", "0.25" }, function()
    if state ~= "selecting" then
      return
    end
    noctalia.runAsync({ sibling("pick-region.sh"), mode, "--match-monitor" }, function(result)
      onDone(selectionToTarget((result.stdout or ""):match("[^\r\n]+")))
    end)
  end)
end

-- ── recording ──────────────────────────────────────────────────────────────────

local function launch(chosen, target)
  local argv = { recordScript(), "start" }
  for _, arg in ipairs(baseArgs(chosen)) do
    table.insert(argv, arg)
  end

  local device = cfg("webcam_device")
  if chosen.webcam and device and device ~= "" then
    table.insert(argv, string.format("--webcam-device=%s", device))
  end
  table.insert(argv, string.format("--target=%s", target))

  log(`starting: {table.concat(argv, " ")}`)

  local started = noctalia.runAsync(argv, function(result)
    local file = parseResult(result)
    if result.exitCode == 0 then
      outputPath = file or ""
      setState("recording")
    else
      outputPath = ""
      setState("idle")
      noctalia.notifyError(noctalia.tr("notify.failed"), noctalia.tr("notify.failedHint"))
    end
  end, 120000)

  if not started then
    setState("idle")
    noctalia.notifyError(noctalia.tr("notify.failed"), noctalia.tr("notify.launchFailed"))
  end
end

local function start(choice)
  if state ~= "idle" then
    return
  end

  local chosen = normalize(choice)
  lastChoice = chosen
  setState("selecting")

  resolveTarget(chosen, function(target)
    if state ~= "selecting" then
      return
    end
    if not target then
      -- Cancelled picker: no error, just back to idle.
      setState("idle")
      return
    end
    setState("starting")
    launch(chosen, target)
  end)
end

local function stop()
  if state == "idle" or state == "stopping" then
    return
  end

  -- While selecting, the picker is ours rather than record.sh's, so record.sh
  -- cannot cancel it. Kill slurp: the picker exits non-zero and resolveTarget
  -- sees the cancel.
  if state == "selecting" then
    noctalia.runAsync({ "pkill", "-x", "slurp" })
    setState("idle")
    return
  end

  setState("stopping")
  log("stopping recording")

  noctalia.runAsync({ recordScript(), "stop" }, function(result)
    local file, preview = parseResult(result)
    setState("idle")
    notifySaved(file, preview)
    outputPath = ""
  end, 60000)
end

-- ── commands ───────────────────────────────────────────────────────────────────

-- record.sh is serialized on its own lock, so a start that lands while one is
-- running means "stop what is running".
local function handleCommand(payload)
  local action = type(payload) == "table" and payload.action or payload
  if type(action) ~= "string" then
    return
  end

  if action == "start" then
    if type(payload) == "table" then
      start({ source = payload.source, audio = payload.audio, webcam = payload.webcam })
    else
      start(currentChoice())
    end
  elseif action == "record-last" or action == "toggle" then
    if state == "idle" then
      start(currentChoice())
    else
      stop()
    end
  elseif action == "record-fullscreen" then
    if state ~= "idle" then
      stop()
    else
      local base = currentChoice()
      start({ source = "fullscreen", audio = base.audio, webcam = base.webcam })
    end
  elseif action == "stop" then
    stop()
  elseif action == "resize-webcam" then
    local size = type(payload) == "table" and payload.size or nil
    if size then
      noctalia.runAsync({ sibling("webcam-resize.sh"), size })
    end
  end
end

-- External IPC (`noctalia msg plugin ...:service all <action> [arg]`).
function onIpc(event, payload)
  if type(payload) == "table" then
    handleCommand(payload)
  elseif type(payload) == "string" and payload ~= "" and event == "start" then
    -- `start region` overrides the source for that run.
    handleCommand({ action = "start", source = payload })
  else
    handleCommand(event)
  end
end

-- ── lifecycle ──────────────────────────────────────────────────────────────────

-- A recording ended from a terminal, or the recorder died on its own, would
-- otherwise leave the widget showing "recording" forever. Polling runs rarely
-- enough to stay invisible, and only while a recording is in flight.
noctalia.setUpdateInterval(2000)

function update()
  if recorder ~= nil then
    return
  end
  if state ~= "recording" and state ~= "starting" then
    return
  end

  recorder = noctalia.runAsync({ recordScript(), "status" }, function(result)
    recorder = nil
    local reported = (result.stdout or ""):match("state=([%w_]+)")
    if reported == "recording" then
      return
    end
    if state == "recording" then
      log("recorder is gone; clearing state")
      outputPath = ""
      setState("idle")
    end
  end)
end

function onConfigChanged()
  publish()
end

function onExit()
  -- A reload or disable must not leave a picker, a recorder, or a webcam overlay
  -- running with nothing left to stop it.
  if state == "selecting" then
    noctalia.runAsync({ "pkill", "-x", "slurp" })
  end
  if state == "recording" or state == "starting" then
    noctalia.runAsync({ recordScript(), "stop" })
  end
end

function onEnable()
  local dir = noctalia.pluginDir()
  scriptPath = dir and (dir .. "/scripts/record.sh") or nil
  available = scriptPath ~= nil
    and noctalia.commandExists("gpu-screen-recorder")
    and noctalia.commandExists("slurp")
  if not available then
    log("unavailable: record.sh or a required command is missing")
  end
  publish()
end

onEnable()

-- The widget and shortcut drive the recorder through this channel.
noctalia.state.watch("command", handleCommand)
