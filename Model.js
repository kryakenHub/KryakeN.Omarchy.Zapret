.pragma library

var state = {
  installed: false,
  running: false,
  enabled: false,
  config: "",
  strategy: "",
  profile: "",
  profiles: [],
  error: ""
}

function reset() {
  state.installed = false
  state.running = false
  state.enabled = false
  state.config = ""
  state.strategy = ""
  state.profile = ""
  state.profiles = []
  state.error = ""
}

function parseStatus(raw) {
  var text = String(raw || "").trim()
  if (text === "") {
    reset()
    return false
  }
  try {
    var o = JSON.parse(text)
    state.installed = !!o.installed
    state.running = !!o.active
    state.enabled = !!o.enabled
    state.config = String(o.config || "")
    state.strategy = String(o.strategy || "")
    state.profile = String(o.profile || "")
    state.profiles = Array.isArray(o.profiles) ? o.profiles : []
    state.error = String(o.error || "")
    return true
  } catch (e) {
    reset()
    state.error = "invalid status output"
    return false
  }
}