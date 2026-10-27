-- Finds AirPlay (RAOP) speakers, and keeps their sinks working.
--
-- PipeWire's module-raop-discover adds a sink for each speaker Avahi finds,
-- loaded here rather than in the PipeWire daemon so that it can be reloaded
-- (below). Each sink's stream keeps running while nothing plays: when a
-- player pauses (VLC does while it buffers), PipeWire would stop the stream
-- and restart it on the same RTSP session with a jump in the RTP
-- timestamps, and AirPlay 2 speakers then drop everything that follows in
-- silence. For the same reason, it stays in the Dummy-Driver's group, so it
-- always runs on that clock: otherwise, while another sink such as HDMI
-- plays (a GNOME alert sound is enough), PipeWire moves it onto that sink's
-- clock and back, and its RTP timestamps jump.
--
-- Since those streams never stop, neither does their RTSP session, and a
-- speaker can drop it without telling PipeWire (a KEF LSX II did), which
-- then streams into it in silence for good. So once nothing has played to a
-- sink for a while, suspend it: PipeWire sends TEARDOWN, and the sink stays
-- suspended, with no session, until a stream linked to it plays again,
-- which sets up a new one (ANNOUNCE, SETUP, RECORD). Only a playing
-- ("running") stream counts: a paused one (Firefox keeps its stream linked
-- while paused) leaves the sink idle. Suspending as a stream starts instead
-- would race PipeWire's RAOP sink (1.6): the stream restarts in the old
-- session before the speaker answers the TEARDOWN, or the TEARDOWN cuts
-- into the new session's setup.
--
-- The RAOP sink destroys itself on any RTSP reply it doesn't expect, and
-- the discovery module only adds a sink again once the speaker leaves the
-- network and comes back, so the speaker would be gone from the outputs
-- until PipeWire restarts. So when a sink goes away, reload the discovery
-- module, which finds the speakers still on the network again. That also
-- happens when a speaker leaves the network, finding the others again, so
-- it waits while another AirPlay sink is playing.

log = Log.open_topic ("s-raop")

DISCOVER_ARGS = [[
{
  stream.rules = [
    {
      matches = [ { raop.ip = "~.*" } ]
      actions = {
        create-stream = {
          stream.props = {
            node.pause-on-idle = false
            node.always-process = true
            node.group = pipewire.dummy
          }
        }
      }
    }
  ]
}
]]

-- Seconds without a playing stream after which a sink's session ends:
-- longer than a track change, so those stay in the same session
IDLE_SECONDS = 30

-- Seconds before the discovery module is reloaded after a sink went away,
-- doubled each time a sink goes away again within STABLE_SECONDS of a
-- reload (a speaker that turns every session down), up to MAX_RETRY_SECONDS
MIN_RETRY_SECONDS = 5
MAX_RETRY_SECONDS = 300
STABLE_SECONDS = 60

nodes_om = ObjectManager {
  Interest { type = "node" },
}
nodes_om:activate ()

links_om = ObjectManager {
  Interest { type = "link" },
}
links_om:activate ()

-- Per sink (bound id): the timer that suspends it
timers = {}

discover = nil
-- When the discovery module was last loaded, in microseconds
loaded_at = 0
retry_seconds = MIN_RETRY_SECONDS
-- The timer that reloads the discovery module
reload_timer = nil
-- The sinks (bound ids) that a reload removes, so not ones that went away
reloaded = {}

function loadDiscover ()
  discover = LocalModule ("libpipewire-module-raop-discover", DISCOVER_ARGS, {})
  loaded_at = GLib.get_monotonic_time ()
end

function raopSinks ()
  return nodes_om:iterate {
    Constraint { "node.name", "matches", "raop_sink.*" },
  }
end

function isPlaying (id)
  for link in links_om:iterate () do
    if tonumber (link.properties ["link.input.node"]) == id then
      local out = nodes_om:lookup {
        Constraint { "bound-id", "=", tonumber (link.properties ["link.output.node"]),
          type = "gobject" },
      }
      if out ~= nil and out ["state"] == "running" then
        return true
      end
    end
  end
  return false
end

function update (sink)
  local id = sink ["bound-id"]

  if isPlaying (id) then
    if timers [id] ~= nil then
      timers [id]:destroy ()
      timers [id] = nil
    end
    return
  end

  if timers [id] ~= nil or sink ["state"] == "suspended" then
    return
  end
  timers [id] = Core.timeout_add (IDLE_SECONDS * 1000, function ()
    timers [id] = nil
    if (sink:get_active_features () & Feature.Proxy.BOUND) ~= 0 and
        sink ["state"] ~= "suspended" and not isPlaying (id) then
      log:info (sink, "nothing played for a while; suspending it to end its session")
      sink:send_command ("Suspend")
    end
    return false
  end)
end

function reload ()
  for sink in raopSinks () do
    if isPlaying (sink ["bound-id"]) then
      log:info ("an AirPlay sink is playing; looking for speakers again later")
      reload_timer = Core.timeout_add (MIN_RETRY_SECONDS * 1000, reload)
      return false
    end
  end
  reload_timer = nil

  log:info ("looking for AirPlay speakers again")
  for sink in raopSinks () do
    reloaded [sink ["bound-id"]] = true
  end
  discover = nil
  loadDiscover ()
  return false
end

SimpleEventHook {
  name = "raop@update",
  interests = {
    EventInterest {
      Constraint { "event.type", "=", "node-added" },
      Constraint { "node.name", "matches", "raop_sink.*" },
    },
    EventInterest {
      Constraint { "event.type", "=", "node-state-changed" },
    },
    EventInterest {
      Constraint { "event.type", "c", "link-added", "link-removed" },
    },
  },
  execute = function (event)
    for sink in raopSinks () do
      update (sink)
    end
  end
}:register ()

SimpleEventHook {
  name = "raop@node-removed",
  interests = {
    EventInterest {
      Constraint { "event.type", "=", "node-removed" },
      Constraint { "node.name", "matches", "raop_sink.*" },
    },
  },
  execute = function (event)
    local id = event:get_subject () ["bound-id"]
    if timers [id] ~= nil then
      timers [id]:destroy ()
      timers [id] = nil
    end

    if reloaded [id] then
      reloaded [id] = nil
      return
    end
    if reload_timer ~= nil then
      return
    end
    if GLib.get_monotonic_time () - loaded_at < STABLE_SECONDS * 1000000 then
      retry_seconds = math.min (retry_seconds * 2, MAX_RETRY_SECONDS)
    else
      retry_seconds = MIN_RETRY_SECONDS
    end
    log:info ("an AirPlay sink went away; looking for speakers again in " ..
      retry_seconds .. " s")
    reload_timer = Core.timeout_add (retry_seconds * 1000, reload)
  end
}:register ()

loadDiscover ()
