--[[
	A set of open connections (WebSockets, event streams, ...) to broadcast to. Members that
	close are dropped on their own.

	    local room = hub.new()
	    app:ws("/chat", function(ws)
	        room:add(ws)
	        for message in ws:messages() do
	            room:broadcast(message)
	        end
	    end)
]]

export type Member = {
	send: (self: any, ...any) -> any,
	closed: boolean,
	[string]: any,
}

export type Hub = {
	add: (self: Hub, member: Member) -> Member,
	remove: (self: Hub, member: Member) -> (),
	has: (self: Hub, member: Member) -> boolean,
	broadcast: (self: Hub, ...any) -> number,
	broadcastExcept: (self: Hub, except: Member?, ...any) -> number,
	each: (self: Hub, fn: (member: Member) -> ()) -> (),
	count: (self: Hub) -> number,
	members: (self: Hub) -> { Member },
	closeAll: (self: Hub, ...any) -> (),
}

local Hub = {}
Hub.__index = Hub

local hub = {}

function hub.new(): Hub
	return setmetatable({ _members = {} :: { [Member]: boolean } }, Hub) :: any
end

function Hub.add(self: any, member: Member): Member
	self._members[member] = true
	return member
end

function Hub.remove(self: any, member: Member)
	self._members[member] = nil
end

function Hub.has(self: any, member: Member): boolean
	return self._members[member] == true
end

-- Drops members that have closed.
function Hub._sweep(self: any)
	for member in self._members do
		if member.closed then
			self._members[member] = nil
		end
	end
end

--- Sends to every member (with the members' own `send` arguments). Returns how many got it.
function Hub.broadcast(self: any, ...: any): number
	return Hub.broadcastExcept(self, nil, ...)
end

--- Sends to every member except one (usually the sender).
function Hub.broadcastExcept(self: any, except: Member?, ...: any): number
	self:_sweep()
	local sent = 0
	for member in self._members do
		if member ~= except then
			local ok, result = pcall(member.send, member, ...)
			if ok and result ~= false then
				sent += 1
			elseif member.closed then
				self._members[member] = nil
			end
		end
	end
	return sent
end

--- Calls `fn` for every open member.
function Hub.each(self: any, fn: (Member) -> ())
	self:_sweep()
	for member in self._members do
		fn(member)
	end
end

function Hub.count(self: any): number
	self:_sweep()
	local n = 0
	for _ in self._members do
		n += 1
	end
	return n
end

function Hub.members(self: any): { Member }
	self:_sweep()
	local out = {}
	for member in self._members do
		table.insert(out, member)
	end
	return out
end

--- Closes every member (passing the arguments to their `close`) and empties the hub.
function Hub.closeAll(self: any, ...: any)
	for member in self._members do
		if type(member.close) == "function" then
			pcall(member.close, member, ...)
		end
	end
	table.clear(self._members)
end

return hub
