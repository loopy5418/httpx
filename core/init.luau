--[[
	httpx/core: the building blocks every category shares.

	    local core = require("@httpx/core")
	    local h = core.headers.new({ accept = "application/json" })
]]

local types = require("./types")

export type Headers = types.Headers
export type HeadersInit = types.HeadersInit
export type HeaderValue = types.HeaderValue
export type Query = types.Query
export type Url = types.Url
export type Part = types.Part
export type MultipartInit = types.MultipartInit
export type Body = types.Body
export type BodyStream = types.BodyStream
export type BodyReader = types.BodyReader
export type Cookie = types.Cookie
export type CookieJar = types.CookieJar
export type ErrorKind = types.ErrorKind
export type Tls = types.Tls

return {
	headers = require("./headers"),
	url = require("./url"),
	body = require("./body"),
	io = require("./io"),
	cookies = require("./cookies"),
	errors = require("./errors"),
}
