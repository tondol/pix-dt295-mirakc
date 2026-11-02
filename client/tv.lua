-- tv.sh が mpv に読み込ませる局切替スクリプト
--   1〜9: リモコン番号の局 / ↑↓・OSC の ◀◀▶▶: 局リストの前後 / l: 局リスト表示
local utils = require "mp.utils"
local opts = { stations = "", mirakc = "", start = 0, watchdog = 12 }
require("mp.options").read_options(opts, "tv")

local f = io.open(opts.stations, "r")
local stations = f and utils.parse_json(f:read("*a")) or {}
if f then f:close() end
if #stations == 0 then
  mp.msg.error("局一覧が空です")
  return
end

local cur = 1          -- 選局中の局（stations の添字）
local retries = 0
local debounce, watchdog, hide_timer

local ov = mp.create_osd_overlay("ass-events")
ov.res_y = 720
local function osd(text, dur)
  ov.data = text
  ov:update()
  if hide_timer then hide_timer:kill() end
  hide_timer = mp.add_timeout(dur or 3, function() ov:remove() end)
end

-- 全局リストを出し、選局中の局だけ色を変える
local function show_list(dur, note)
  local t = "{\\an7}{\\fs28}{\\bord2}"
  for i, s in ipairs(stations) do
    if i == cur then
      t = t .. "{\\c&H00D7FF&}{\\b1}▶ " .. s.key .. "  " .. s.name .. "{\\r}{\\fs28}{\\bord2}\\N"
    else
      t = t .. "{\\alpha&H30&}\\h\\h\\h" .. s.key .. "  " .. s.name .. "{\\r}{\\fs28}{\\bord2}\\N"
    end
  end
  if note then t = t .. "{\\c&H5050FF&}" .. note .. "\\N" end
  osd(t, dur)
end

local function load(retry)
  if watchdog then watchdog:kill() end
  local s = stations[cur]
  if not retry then retries = 0 end
  mp.msg.info(("tune %s %s (retry %d)"):format(s.key, s.name, retries))
  mp.set_property("force-media-title", s.name)
  mp.commandv("loadfile", opts.mirakc .. "/api/services/" .. s.id .. "/stream", "replace")
  mp.set_property_bool("pause", false)
  -- 映像が出ないまま一定時間たったら選び直す（最大 3 回）
  watchdog = mp.add_timeout(tonumber(opts.watchdog), function()
    if retries < 3 then
      retries = retries + 1
      show_list(3, "受信できないので選局し直します（" .. retries .. "/3）")
      load(true)
    else
      show_list(10, "受信できません")
    end
  end)
end

-- 連打は 0.35 秒以内の要求をまとめて、最後の局だけ選局する
local function tune(i)
  cur = (i - 1) % #stations + 1
  show_list(5)
  if debounce then debounce:kill() end
  debounce = mp.add_timeout(0.35, function() load(false) end)
end

mp.register_event("playback-restart", function()
  if watchdog then watchdog:kill(); watchdog = nil end
end)

local function by_key(k)
  for i, s in ipairs(stations) do
    if s.key == k then tune(i); return end
  end
end
for k = 1, 9 do
  mp.add_forced_key_binding(tostring(k), "tv-key-" .. k, function() by_key(tostring(k)) end)
end
mp.add_forced_key_binding("UP", "tv-prev", function() tune(cur - 1) end, { repeatable = true })
mp.add_forced_key_binding("DOWN", "tv-next", function() tune(cur + 1) end, { repeatable = true })
mp.add_forced_key_binding("l", "tv-list", function() show_list(5) end)
mp.register_script_message("tv-step", function(dir)
  tune(dir == "prev" and cur - 1 or cur + 1)
end)

cur = tonumber(opts.start) + 1
load(false)
show_list(5)
