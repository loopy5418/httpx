--[[
	Static files: content types, ETag / Last-Modified with 304 answers, byte ranges, index
	files, clean URLs, SPA fallback and directory listings.

	    app:static("/", "public")
	    app:static("/assets", "dist/assets", { maxAge = 31536000, immutable = true })
	    app:use(server.static("site", { extensions = { "html" }, spa = true }))

	Files can come from somewhere other than the disk, e.g. assets packed into the program
	with @sonata/pocket:

	    local pocket = require("@sonata/pocket")
	    app:static("/", "www", {
	        read = function(p) return pocket.tryRead(p) end,
	        stat = function(p)
	            local data = pocket.tryRead(p)
	            return data and { kind = "file", size = #data, modified = 0 } or nil
	        end,
	    })
]]

local net = require("@sonata/net")
local fs = require("@sonata/fs")
local path = require("@sonata/path")
local pocket = require("@sonata/pocket")
local types = require("./types")
local httpErrors = require("./errors")

export type StaticOptions = types.StaticOptions

type Stat = { kind: string, size: number, modified: number }

type Source = {
	stat: (p: string) -> Stat?,
	read: (p: string) -> string?,
	list: ((p: string) -> { { name: string, kind: string, size: number?, modified: number? } }?)?,
	reader: ((p: string) -> any)?, -- a chunked reader, for big files on disk
	join: (root: string, rel: string) -> string,
}

local static = {}

local STREAM_THRESHOLD = 1024 * 1024
local CHUNK = 64 * 1024

local function fsSource(): Source
	return {
		stat = function(p: string): Stat?
			local ok, st = pcall(fs.stat, p)
			if ok then
				return st
			end
			return nil
		end,
		read = function(p: string): string?
			local ok, data = pcall(fs.readFile, p)
			return if ok then data else nil
		end,
		list = function(p: string)
			local ok, entries = pcall(fs.readDir, p)
			if not ok then
				return nil
			end
			local out = {}
			for _, e in entries do
				local item: { [string]: any } = { name = e.name, kind = e.kind }
				local okStat, st = pcall(fs.stat, path.join(p, e.name))
				if okStat then
					item.size = st.size
					item.modified = st.modified
					item.kind = st.kind
				end
				table.insert(out, item)
			end
			return out :: any
		end,
		reader = function(p: string)
			return fs.openReader(p, { size = CHUNK })
		end,
		join = function(root: string, rel: string): string
			return path.join(root, rel)
		end,
	}
end

local function customSource(options: StaticOptions): Source
	local read = options.read :: (string) -> string?
	return {
		stat = options.stat or function(p: string): Stat?
			local data = read(p)
			if data == nil then
				return nil
			end
			return { kind = "file", size = #data, modified = 0 }
		end,
		read = read,
		list = if options.list
			then function(p: string)
				local names = (options.list :: any)(p)
				if names == nil then
					return nil
				end
				local out = {}
				for _, name in names do
					table.insert(out, { name = name, kind = "file" })
				end
				return out
			end
			else nil,
		reader = nil,
		join = function(root: string, rel: string): string
			local joined = path.posix.join(root, rel)
			return (string.gsub(joined, "^%./", ""))
		end,
	}
end

local function sourceFor(options: StaticOptions?): Source
	if options and options.read then
		return customSource(options)
	end
	return fsSource()
end

local function contentTypeOf(file: string): string
	local mime = net.mime.lookup(file) or "application/octet-stream"
	if net.mime.isText(mime) and not string.find(mime, "charset", 1, true) then
		mime ..= "; charset=utf-8"
	end
	return mime
end

local function etagOf(st: Stat): string
	return string.format('W/"%x-%x"', st.size, math.floor(st.modified or 0))
end

-- Whether the request's validators say the client's copy is still good.
local function notModified(req: any, etag: string?, modified: number?): boolean
	local inm = req.headers:get("if-none-match")
	if inm then
		if etag == nil then
			return false
		end
		for tag in string.gmatch(inm, "[^,]+") do
			tag = string.gsub(tag, "^%s+", "")
			tag = string.gsub(tag, "%s+$", "")
			if tag == "*" or tag == etag or "W/" .. tag == etag or tag == string.gsub(etag, "^W/", "") then
				return true
			end
		end
		return false
	end
	local ims = req.headers:get("if-modified-since")
	if ims and modified and modified > 0 then
		local t = net.http.parseDate(ims)
		return t ~= nil and math.floor(modified) <= t
	end
	return false
end

-- Parses a single byte range. Returns first, last (0-based, inclusive); nil for no usable
-- range; false when unsatisfiable.
local function parseRange(header: string, size: number): (number | boolean | nil, number?)
	local spec = string.match(header, "^%s*bytes%s*=%s*(.-)%s*$")
	if spec == nil or string.find(spec, ",", 1, true) then
		return nil, nil -- not bytes, or several ranges: send the whole file
	end
	local a, b = string.match(spec, "^(%d*)%s*%-%s*(%d*)$")
	if a == nil then
		return nil, nil
	end
	local first, last
	if a == "" then
		if b == "" then
			return nil, nil
		end
		local suffix = tonumber(b) :: number
		if suffix == 0 then
			return false, nil
		end
		first = math.max(0, size - suffix)
		last = size - 1
	else
		first = tonumber(a) :: number
		last = if b == "" then size - 1 else math.min(tonumber(b) :: number, size - 1)
	end
	if first >= size or first > last then
		return false, nil
	end
	return first, last
end

-- Reads bytes [first, last] of a file through a chunked reader.
local function readSlice(reader: any, first: number, last: number): string
	local out = {}
	local firstChunk = first // CHUNK + 1
	local lastChunk = last // CHUNK + 1
	for i = firstChunk, lastChunk do
		local data = reader:readChunk(i)
		local chunkStart = (i - 1) * CHUNK
		local from = math.max(first - chunkStart, 0) + 1
		local to = math.min(last - chunkStart, #data - 1) + 1
		table.insert(out, string.sub(data, from, to))
	end
	return table.concat(out)
end

--- Sends one file as the response. Returns `false` (without answering) if it doesn't exist.
function static.sendFile(req: any, res: any, file: string, options: StaticOptions?): boolean
	local opts: StaticOptions = options or {}
	local source = (opts :: any)._source or sourceFor(opts)
	local st = source.stat(file)
	if st == nil or st.kind ~= "file" then
		return false
	end

	local headers = res.headers
	headers:setDefault("Content-Type", contentTypeOf(file))
	local etag: string? = nil
	if opts.etag ~= false then
		etag = etagOf(st)
		headers:set("ETag", etag)
	end
	if opts.lastModified ~= false and st.modified and st.modified > 0 then
		headers:set("Last-Modified", net.http.formatDate(st.modified))
	end
	if opts.cacheControl then
		headers:set("Cache-Control", opts.cacheControl)
	elseif opts.cacheControl ~= false then
		local value = `public, max-age={opts.maxAge or 0}`
		if opts.immutable then
			value ..= ", immutable"
		end
		headers:setDefault("Cache-Control", value)
	end
	if opts.headers then
		opts.headers(res, file, st)
	end

	if (req.method == "GET" or req.method == "HEAD") and notModified(req, etag, st.modified) then
		res:status(304):send()
		return true
	end

	if opts.transform and (opts.transformMatch == nil or string.match(file, opts.transformMatch)) then
		local content = source.read(file)
		if content == nil then
			return false
		end
		content = opts.transform(content, file, req)
		headers:delete("ETag")
		res:send(content)
		return true
	end

	local size = st.size
	local rangeHeader = if opts.ranges ~= false then req.headers:get("range") else nil
	if opts.ranges ~= false then
		headers:set("Accept-Ranges", "bytes")
	end
	if rangeHeader and req.method == "GET" then
		local ifRange = req.headers:get("if-range")
		local rangeOk = ifRange == nil or ifRange == etag or (st.modified and net.http.parseDate(ifRange) == math.floor(st.modified))
		if rangeOk then
			local first, last = parseRange(rangeHeader, size)
			if first == false then
				headers:set("Content-Range", `bytes */{size}`)
				res:status(416):send()
				return true
			elseif type(first) == "number" then
				local slice: string
				if source.reader and size > STREAM_THRESHOLD then
					local reader = source.reader(file)
					slice = readSlice(reader, first, last :: number)
					reader:close()
				else
					slice = string.sub(source.read(file) or "", first + 1, (last :: number) + 1)
				end
				headers:set("Content-Range", `bytes {first}-{last}/{size}`)
				res:status(206)
				res._compress = nil -- ranges refer to the raw bytes
				res:send(slice)
				return true
			end
		end
	end

	if source.reader and size > STREAM_THRESHOLD then
		-- Big files go out in chunks with a known length.
		headers:set("Content-Length", tostring(size))
		if req.method == "HEAD" then
			res:write("")
			res:finish()
			return true
		end
		local reader = source.reader(file)
		for _, chunk in reader:chunks() do
			local ok = res:write(chunk)
			if not ok then
				break
			end
		end
		reader:close()
		res:finish()
		return true
	end

	local content = source.read(file)
	if content == nil then
		return false
	end
	res:send(content)
	return true
end

local function escapeHtml(text: string): string
	return (string.gsub(text, "[&<>\"']", {
		["&"] = "&amp;",
		["<"] = "&lt;",
		[">"] = "&gt;",
		['"'] = "&quot;",
		["'"] = "&#39;",
	}))
end

local function formatSize(bytes: number?): string
	if bytes == nil then
		return ""
	end
	local units = { "B", "KiB", "MiB", "GiB", "TiB" }
	local value = bytes
	local unit = 1
	while value >= 1024 and unit < #units do
		value /= 1024
		unit += 1
	end
	if unit == 1 then
		return `{value} B`
	end
	return string.format("%.1f %s", value, units[unit])
end

--- An HTML page listing a directory's entries.
function static.listing(urlPath: string, entries: { { name: string, kind: string, size: number?, modified: number? } }, showDotfiles: boolean?): string
	table.sort(entries, function(a, b)
		local ad, bd = a.kind == "directory", b.kind == "directory"
		if ad ~= bd then
			return ad
		end
		return string.lower(a.name) < string.lower(b.name)
	end)
	local rows = {}
	local base = if string.sub(urlPath, -1) == "/" then urlPath else urlPath .. "/"
	if base ~= "/" then
		table.insert(rows, '<tr><td><a href="../">../</a></td><td></td><td></td></tr>')
	end
	for _, e in entries do
		if showDotfiles or string.sub(e.name, 1, 1) ~= "." then
			local isDir = e.kind == "directory"
			local name = if isDir then e.name .. "/" else e.name
			local href = net.url.encode(e.name) .. (if isDir then "/" else "")
			local modified = if e.modified and e.modified > 0 then os.date("!%Y-%m-%d %H:%M", e.modified) else ""
			table.insert(
				rows,
				`<tr><td><a href="{escapeHtml(href)}">{escapeHtml(name)}</a></td><td>{if isDir then "" else formatSize(e.size)}</td><td>{modified}</td></tr>`
			)
		end
	end
	local template = pocket.read("assets/listing.html")
	local title = escapeHtml(net.url.decode(base))
	local page = string.gsub(template, "{{title}}", function()
		return title
	end)
	page = string.gsub(page, "{{rows}}", function()
		return table.concat(rows, "\n")
	end)
	return page
end

--- Middleware serving files from `root`.
function static.handler(root: string, options: StaticOptions?): types.Handler
	local opts: any = table.clone(options or {})
	local source = sourceFor(opts)
	opts._source = source
	local onDisk = opts.read == nil
	local resolvedRoot = if onDisk then path.resolve(root) else root
	local indexes: { string } = {}
	if opts.index == nil then
		indexes = { "index.html", "index.htm" }
	elseif type(opts.index) == "string" then
		indexes = { opts.index :: string }
	elseif type(opts.index) == "table" then
		indexes = opts.index :: { string }
	end
	local dotfiles = opts.dotfiles or "ignore"
	local fallthrough = opts.fallthrough ~= false

	local function miss(req: any, res: any, nextFn: any)
		if fallthrough then
			nextFn()
			return
		end
		res:error(404)
	end

	return function(req: any, res: any, nextFn: any)
		if req.method ~= "GET" and req.method ~= "HEAD" then
			nextFn()
			return
		end
		local rel = net.url.decode(req.path)
		if string.find(rel, "\0", 1, true) then
			httpErrors.abort(400, "invalid path")
		end
		rel = string.gsub(rel, "\\", "/")
		for segment in string.gmatch(rel, "[^/]+") do
			if segment == ".." then
				httpErrors.abort(403, "forbidden")
			end
			if string.sub(segment, 1, 1) == "." and segment ~= "." then
				if dotfiles == "deny" then
					httpErrors.abort(403, "forbidden")
				elseif dotfiles == "ignore" then
					miss(req, res, nextFn)
					return
				end
			end
		end
		rel = string.gsub(rel, "^/+", "")
		local target = source.join(resolvedRoot, rel)
		if onDisk and not path.isInside(target, resolvedRoot) then
			httpErrors.abort(403, "forbidden")
		end

		local st = source.stat(target)
		if st and st.kind == "directory" then
			if string.sub(req.originalPath, -1) ~= "/" and opts.redirect ~= false then
				local location = req.originalPath .. "/"
				if req.rawQuery and req.rawQuery ~= "" then
					location ..= "?" .. req.rawQuery
				end
				res:redirect(location, 301)
				return
			end
			for _, index in indexes do
				if static.sendFile(req, res, source.join(target, index), opts) then
					return
				end
			end
			if opts.listing and source.list then
				local entries = source.list(target)
				if entries then
					res:html(static.listing(req.baseUrl .. req.path, entries, dotfiles == "allow"))
					return
				end
			end
			miss(req, res, nextFn)
			return
		end
		if st and st.kind == "file" then
			if static.sendFile(req, res, target, opts) then
				return
			end
		end
		-- Clean URLs: /about -> about.html
		if opts.extensions and rel ~= "" and string.sub(rel, -1) ~= "/" then
			for _, ext in opts.extensions do
				local candidate = target .. "." .. string.gsub(ext, "^%.", "")
				if static.sendFile(req, res, candidate, opts) then
					return
				end
			end
		end
		-- Single-page apps: unknown paths get the app's index page.
		if opts.spa and not string.match(rel, "%.%w+$") and req:accepts("html") == "html" then
			local spaFile = if type(opts.spa) == "string" then opts.spa else "index.html"
			if static.sendFile(req, res, source.join(resolvedRoot, spaFile :: string), opts) then
				return
			end
		end
		miss(req, res, nextFn)
		return
	end
end

return static
