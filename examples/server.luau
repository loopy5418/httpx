--[[
	A small JSON API with static files.

	    sn run --entry examples/server.luau
	    curl localhost:8080/api/todos
	    curl -X POST localhost:8080/api/todos -d '{"title":"try httpx"}' -H 'content-type: application/json'
]]

local httpx = require("../init")

local app = httpx.app()
local mw = httpx.middleware

app:use(mw.logger())
app:use(mw.requestId())
app:use(mw.compress())
app:use(mw.cors())

-- In-memory data
local todos: { { id: number, title: string, done: boolean } } = {}
local nextId = 1

local api = httpx.router()

api:get("/todos", function(req)
	if req.query.done then
		local filtered = {}
		for _, todo in todos do
			if tostring(todo.done) == req.query.done then
				table.insert(filtered, todo)
			end
		end
		return filtered
	end
	return todos
end)

api:post("/todos", function(req, res)
	local body = req:json() -- 400 automatically if it isn't JSON
	if type(body.title) ~= "string" or body.title == "" then
		httpx.abort(422, "title is required")
	end
	local todo = { id = nextId, title = body.title, done = false }
	nextId += 1
	table.insert(todos, todo)
	res:status(201):header("Location", `/api/todos/{todo.id}`):json(todo)
end)

local function find(id: string)
	for index, todo in todos do
		if tostring(todo.id) == id then
			return todo, index
		end
	end
	return httpx.abort(404, "no such todo")
end

api:get("/todos/:id(%d+)", function(req)
	return (find(req.params.id))
end)

api:patch("/todos/:id(%d+)", function(req)
	local todo = find(req.params.id)
	local changes = req:json()
	if changes.done ~= nil then
		todo.done = changes.done == true
	end
	if type(changes.title) == "string" then
		todo.title = changes.title
	end
	return todo
end)

api:delete("/todos/:id(%d+)", function(req)
	local _, index = find(req.params.id)
	table.remove(todos, index)
	return 204
end)

app:mount("/api", api)

app:get("/", function()
	return [[<!doctype html>
<title>httpx</title>
<h1>httpx example</h1>
<p>Try <a href="/api/todos">/api/todos</a>.</p>]]
end)

app:onError(function(err, req, res)
	if httpx.server.isError(err) then
		res:json({ error = err.message, requestId = req.locals.requestId }, err.status)
	else
		res:json({ error = "something went wrong", requestId = req.locals.requestId }, 500)
	end
end)

local srv = assert(app:listen(8080))
print(`listening on {srv.url}`)
