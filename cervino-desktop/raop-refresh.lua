-- Gives an AirPlay (RAOP) sink a fresh RTSP session when a stream starts
-- playing to it after it has had none for a while.
--
-- The sinks keep streaming while nothing plays (node.always-process, so the
-- RTP timestamps never jump on a pause), so their session is never torn
-- down. A speaker can drop that session without telling PipeWire, which then
-- streams into it in silence for good. Suspending the sink makes PipeWire
-- send TEARDOWN, and with always-process it starts again at once. But
-- PipeWire's RAOP sink (1.6) defers the teardown while its send timer runs,
-- and that restart races it: the stream starts in the old session, which
-- the teardown then closes. So suspend it a second time a moment later:
-- with no session left, that restart sets up a new one (ANNOUNCE, SETUP,
-- RECORD).

log = Log.open_topic ("s-raop-refresh")

-- Seconds without streams after which the next one gets a fresh session:
-- longer than a track change, so those stay in the same session
IDLE_SECONDS = 30

nodes_om = ObjectManager {
  Interest {
    type = "node",
    Constraint { "node.name", "matches", "raop_sink.*" },
  },
}
nodes_om:activate ()

-- Per sink (bound id): its input links, and when the last one went
links = {}
idle_since = {}
-- Link id -> sink id, for the links into sinks
link_sink = {}

function lookupSink (id)
  return nodes_om:lookup {
    Constraint { "bound-id", "=", id, type = "gobject" },
  }
end

function countLinks (id)
  local n = 0
  for _ in pairs (links [id] or {}) do
    n = n + 1
  end
  return n
end

SimpleEventHook {
  name = "raop-refresh@link-added",
  interests = {
    EventInterest {
      Constraint { "event.type", "=", "link-added" },
    },
  },
  execute = function (event)
    local link = event:get_subject ()
    local id = tonumber (link.properties ["link.input.node"])
    local node = id and lookupSink (id)
    if node == nil then
      return
    end

    local since = idle_since [id]
    if countLinks (id) == 0 and since ~= nil and
        GLib.get_monotonic_time () - since >= IDLE_SECONDS * 1000000 then
      log:info (node, "idle for a while; suspending it for a fresh session")
      node:send_command ("Suspend")
      Core.timeout_add (1000, function ()
        if (node:get_active_features () & Feature.Proxy.BOUND) ~= 0 then
          node:send_command ("Suspend")
        end
        return false
      end)
    end

    links [id] = links [id] or {}
    links [id] [link.id] = true
    link_sink [link.id] = id
    idle_since [id] = nil
  end
}:register ()

SimpleEventHook {
  name = "raop-refresh@link-removed",
  interests = {
    EventInterest {
      Constraint { "event.type", "=", "link-removed" },
    },
  },
  execute = function (event)
    local link = event:get_subject ()
    local id = link_sink [link.id]
    if id == nil then
      return
    end
    link_sink [link.id] = nil
    links [id] [link.id] = nil
    if countLinks (id) == 0 then
      idle_since [id] = GLib.get_monotonic_time ()
    end
  end
}:register ()

SimpleEventHook {
  name = "raop-refresh@node-removed",
  interests = {
    EventInterest {
      Constraint { "event.type", "=", "node-removed" },
      Constraint { "node.name", "matches", "raop_sink.*" },
    },
  },
  execute = function (event)
    local id = event:get_subject () ["bound-id"]
    links [id] = nil
    idle_since [id] = nil
  end
}:register ()
