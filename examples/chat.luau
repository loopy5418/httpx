--[[
	A chat room over WebSockets, with a server-sent events feed of who's online.

	    sn run --entry examples/chat.luau
	    open http://localhost:8080 in two browser tabs
]]

local json = require("@sonata/json")
local httpx = require("../init")

local app = httpx.app()
local room = httpx.websocket.hub()
local presence = httpx.sse.hub()

local PAGE = [[<!doctype html>
<meta charset="utf-8">
<title>httpx chat</title>
<style>body{font:15px system-ui;max-width:640px;margin:24px auto;padding:0 16px}#log{border:1px solid #ccc;height:320px;overflow:auto;padding:8px}input{width:100%;padding:8px;box-sizing:border-box;margin-top:8px}</style>
<h1>httpx chat</h1>
<p id="online">connecting…</p>
<div id="log"></div>
<input id="msg" placeholder="Say something and press Enter" autofocus>
<script>
const log = document.getElementById("log");
const ws = new WebSocket(`ws://${location.host}/ws`);
ws.onmessage = (e) => {
  const m = JSON.parse(e.data);
  const line = document.createElement("div");
  line.textContent = `${m.from}: ${m.text}`;
  log.append(line);
  log.scrollTop = log.scrollHeight;
};
document.getElementById("msg").onkeydown = (e) => {
  if (e.key === "Enter" && e.target.value) { ws.send(e.target.value); e.target.value = ""; }
};
new EventSource("/presence").addEventListener("online", (e) => {
  document.getElementById("online").textContent = `${e.data} online`;
});
</script>]]

local function announce()
	presence:broadcast(tostring(room:count()), "online")
end

app:get("/", function()
	return PAGE
end)

app:ws("/ws", function(ws, req)
	local name = `guest-{req.port}`
	room:add(ws)
	announce()
	room:broadcast(json.encode({ from = "server", text = `{name} joined` }))
	for message in ws:messages() do
		room:broadcast(json.encode({ from = name, text = message }))
	end
	room:broadcast(json.encode({ from = "server", text = `{name} left` }))
	announce()
end)

app:sse("/presence", function(stream)
	presence:add(stream)
	stream:send(tostring(room:count()), "online")
end)

local srv = assert(app:listen(8080))
print(`chat on {srv.url}`)
