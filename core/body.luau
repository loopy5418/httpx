--[[
	Encoding bodies (JSON, forms, multipart, files, streams) and decoding compressed content.
]]

local net = require("@sonata/net")
local json = require("@sonata/json")
local fs = require("@sonata/fs")
local path = require("@sonata/path")
local compress = require("@sonata/compress")
local types = require("./types")
local url = require("./url")

export type Body = types.Body
export type BodyStream = types.BodyStream
export type MultipartInit = types.MultipartInit
export type Part = types.Part

--- The fields a request or response may use to describe its body. At most one is used, in
--- this order: "body", "json", "form", "multipart", "file".
export type BodyOptions = {
	body: (string | buffer | BodyStream)?,
	json: any?,
	form: { [string]: any }?,
	multipart: MultipartInit?,
	file: string?,
}

local body = {}

body.FILE_CHUNK = 64 * 1024

--- A body made of one string.
function body.fromString(data: string, contentType: string?): Body
	return { data = data, length = #data, contentType = contentType, replayable = true }
end

--- A body produced by a function called until it returns "nil". "length", when known, is
--- sent as Content-Length; otherwise the body is sent chunked.
function body.fromStream(stream: BodyStream, length: number?, contentType: string?): Body
	return { stream = stream, length = length, contentType = contentType, replayable = false }
end

--- A body read from a file, in chunks, with its MIME type guessed from the name.
function body.fromFile(file: string, contentType: string?): Body
	local stat = fs.stat(file)
	if stat.kind ~= "file" then
		error(`not a file: {file}`, 2)
	end
	local reader: any = nil
	local function stream(): string?
		if reader == nil then
			reader = fs.openReader(file, { size = body.FILE_CHUNK })
		end
		local chunk = reader:read()
		if chunk == nil then
			reader:close()
		end
		return chunk
	end
	local result: any = body.fromStream(stream, stat.size, contentType or net.mime.lookup(file) or "application/octet-stream")
	-- A file can be read again, so redirects and retries can resend it.
	result.replayable = true
	result.reopen = function()
		return body.fromFile(file, contentType)
	end
	return result
end

local function toPart(name: string, value: any): Part
	if type(value) == "table" then
		if value.file then
			local file: string = value.file
			return {
				name = name,
				value = fs.readFile(file),
				filename = value.filename or path.basename(file),
				contentType = value.contentType or net.mime.lookup(file) or "application/octet-stream",
				headers = value.headers,
			}
		end
		local part = table.clone(value)
		part.name = part.name or name
		part.value = tostring(part.value or "")
		return part :: Part
	end
	return { name = name, value = tostring(value) }
end

--- Encodes a multipart/form-data body.
---
---     body.multipart({ title = "Report", attachment = { file = "report.pdf" } })
---     body.multipart({ { name = "a", value = "1" }, { name = "f", value = data, filename = "f.txt" } })
function body.multipart(parts: MultipartInit, boundary: string?): Body
	local list: { Part } = {}
	if #parts > 0 then
		for _, part in parts :: { any } do
			table.insert(list, toPart(part.name, part))
		end
	else
		local names = {}
		for name in parts :: { [string]: any } do
			table.insert(names, name)
		end
		table.sort(names)
		for _, name in names do
			local value = (parts :: any)[name]
			if type(value) == "table" and #value > 0 then
				for _, v in value do
					table.insert(list, toPart(name, v))
				end
			else
				table.insert(list, toPart(name, value))
			end
		end
	end
	local data, contentType = net.http.encodeMultipart(list, boundary)
	return body.fromString(data, contentType)
end

--- Builds a body from request or response options. Returns "nil" when there is none.
function body.encode(options: BodyOptions): Body?
	local raw = options.body
	if raw ~= nil then
		if type(raw) == "string" then
			return body.fromString(raw)
		elseif type(raw) == "buffer" then
			return body.fromString(buffer.tostring(raw))
		elseif type(raw) == "function" then
			return body.fromStream(raw)
		elseif type(raw) == "table" and (raw.data or raw.stream) then
			return raw :: any -- already an encoded Body
		end
		error(`unsupported body of type {typeof(raw)} (use a string, a function, or the json/form/multipart options)`, 3)
	end
	if options.json ~= nil then
		return body.fromString(json.encode(options.json), "application/json")
	end
	if options.form ~= nil then
		return body.fromString(url.buildQuery(options.form), "application/x-www-form-urlencoded")
	end
	if options.multipart ~= nil then
		return body.multipart(options.multipart)
	end
	if options.file ~= nil then
		return body.fromFile(options.file)
	end
	return nil
end

--- Reads a whole body into a string.
function body.collect(b: Body): string
	if b.data then
		return b.data
	end
	local out = {}
	local stream = b.stream :: BodyStream
	while true do
		local chunk = stream()
		if chunk == nil then
			break
		end
		table.insert(out, chunk)
	end
	return table.concat(out)
end

--- The content codings this build can decode, for Accept-Encoding.
function body.acceptEncoding(): string
	local formats = compress.formats()
	local accepted = { "gzip", "deflate" }
	if table.find(formats, "zstd") then
		table.insert(accepted, "zstd")
	end
	return table.concat(accepted, ", ")
end

--- Whether a Content-Encoding value can be decoded.
function body.canDecode(encoding: string?): boolean
	if encoding == nil then
		return true
	end
	encoding = string.lower(encoding)
	if encoding == "" or encoding == "identity" then
		return true
	end
	if encoding == "gzip" or encoding == "x-gzip" or encoding == "deflate" then
		return true
	end
	if encoding == "zstd" then
		return table.find(compress.formats(), "zstd") ~= nil
	end
	return false
end

--- A streaming decoder for a Content-Encoding: returns "write(chunk) -> decoded" and
--- "finish() -> decoded", or "nil" for identity.
function body.decoder(encoding: string?, maxSize: number?): (((string) -> string)?, (() -> string)?)
	if encoding == nil then
		return nil
	end
	encoding = string.lower(encoding)
	if encoding == "" or encoding == "identity" then
		return nil
	end
	if encoding == "gzip" or encoding == "x-gzip" or encoding == "zstd" then
		local write, finish = compress.decoder(if encoding == "zstd" then "zstd" else "gzip", maxSize)
		return write, finish
	end
	if encoding == "deflate" then
		-- "deflate" should be zlib-wrapped, but some servers send raw deflate: decide on the
		-- first bytes.
		local write: ((string) -> string)? = nil
		local finish: (() -> string)? = nil
		local pending = ""
		local function start(data: string)
			if compress.detect(data) == "zlib" then
				write, finish = compress.decoder("zlib", maxSize)
			else
				write, finish = compress.decoder("deflate", maxSize)
			end
		end
		return function(chunk: string): string
			if write == nil then
				pending ..= chunk
				if #pending < 2 then
					return ""
				end
				start(pending)
				chunk, pending = pending, ""
			end
			return (write :: any)(chunk)
		end, function(): string
			if write == nil then
				if pending == "" then
					return ""
				end
				start(pending)
				local out = (write :: any)(pending)
				return out .. (finish :: any)()
			end
			return (finish :: any)()
		end
	end
	error(`unsupported content encoding '{encoding}'`)
end

--- Whether a Content-Type is JSON (application/json, application/*+json, ...).
function body.isJson(contentType: string?): boolean
	if contentType == nil then
		return false
	end
	local essence = string.lower((string.match(contentType, "^[^;]*") :: string))
	essence = string.gsub(essence, "%s", "")
	return essence == "application/json" or string.sub(essence, -5) == "+json" or essence == "text/json"
end

--- Whether a Content-Type is worth compressing.
function body.isCompressible(contentType: string?): boolean
	if contentType == nil then
		return false
	end
	local essence = string.lower((string.match(contentType, "^[^;]*") :: string))
	if net.mime.isText(essence) or body.isJson(essence) then
		return true
	end
	return essence == "image/svg+xml"
		or essence == "application/javascript"
		or essence == "application/xml"
		or essence == "application/wasm"
		or string.sub(essence, -4) == "+xml"
end

return body
