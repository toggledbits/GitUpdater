-- GitUpdater: A service module for updating Luup plugins from Github
-- (c) 2017 Patrick H. Rigney, All Rights Reserved
-- Distributed under GPL 3.0. For information see the LICENSE file at
--luacheck: std lua51,module,read globals luup debugMode,ignore 542 611 612 614 111/_,no max line length

module("GitUpdater", package.seeall)

local _VERSION="0.1"
local _VNUM = 19214
local debugMode = true

local https = require("ssl.https")
local http = require("socket.http")
local ltn12 = require("ltn12")
local json = require('dkjson')
local x

local function dump(t, seen)
	if t == nil then return "nil" end
	if seen == nil then seen = {} end
	local sep = ""
	local str = "{ "
	for k,v in pairs(t) do
		local val
		if type(v) == "table" then
			if seen[v] then val = "(recursion)"
			else
				seen[v] = true
				val = dump(v, seen)
			end
		elseif type(v) == "string" then
			val = string.format("%q", v)
		elseif type(v) == "number" and (math.abs(v-os.time()) <= 86400) then
			val = tostring(v) .. "(" .. os.date("%x.%X", v) .. ")"
		else
			val = tostring(v)
		end
		str = str .. sep .. k .. "=" .. val
		sep = ", "
	end
	str = str .. " }"
	return str
end

local function expand(msg, ...) -- luacheck: ignore 212
	local str
	if type(msg) == "table" then
		str = tostring(msg["prefix"] or "") .. tostring(msg["msg"])
	else
		str = "[GitUpdater] " .. msg
	end
	str = string.gsub(str, "%%(%d+)", function( n )
			n = tonumber(n)
			if n < 1 or n > #arg then return "nil" end
			local val = arg[n]
			if type(val) == "table" then
				return dump( val )
			elseif type(val) == "string" then
				return string.format("%q", val)
			end
			return tostring(val)
		end
	)
	return str
end

local function D(msg, ...)
	if debugMode then
		local str = expand( msg, ... )
		if type(debugMode) == "function" then
			debugMode(str)
		elseif type(luup)=="table" then
			luup.log(str)
		else
			print("* "..str)
		end
	end
end

local function doRequest(url, method, body, timeout)
	timeout = timeout or 30

	local src
	local tHeaders = { ['User-Agent']="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/75.0.3770.142 Safari/537.36" }

	-- Build post/put data
	if type(body) == "table" then
		body = json.encode(body)
		tHeaders["Content-Type"] = "application/json"
	end
	if body ~= nil then
		tHeaders["Content-Length"] = string.len(body)
		src = ltn12.source.string(body)
	end

	local r = {}
	local req = {
		url = url,
		source = src,
		sink = ltn12.sink.table(r),
		method = method or "GET",
		headers = tHeaders,
		redirect = false
	}

	-- HTTP or HTTPS?
	local requestor = http
	if url:lower():find("^https:") then
		requestor = https
		req.mode = "client"
		req.verify = "none"
		req.protocol = "tlsv1_2"
		-- req.options = "all"
	end

	-- Make the request.
	http.TIMEOUT = timeout -- N.B. http not https, regardless
	D("HTTP req %1", req)
	local respBody, httpStatus, httpHeaders, st = requestor.request( req )
	D("doRequest() request returned httpStatus=%1, respBody=%2, hd=%3, st=%4", httpStatus, respBody, httpHeaders, st )

	-- Since we're using the table sink, concatenate chunks to single string.
	respBody = table.concat(r)

	D("Response status %1, body length %2", httpStatus, string.len(respBody))

	-- See what happened. Anything 2xx we reduce to 200 (OK).
	if httpStatus == 302 then
		D("doRequest(): redirecting to %1", httpHeaders['location'])
		return doRequest( httpHeaders['location'], method, nil, timeout )
	end
	if httpStatus and httpStatus >= 200 and httpStatus <= 299 then
		-- Success response with no data, take shortcut.
		return false, respBody, 200
	end
	return true, respBody, httpStatus
end

local function jsonQuery(url)
	local _,body,httpStatus = doRequest(url, "GET")
	if httpStatus ~= 200 then
		D("doJSONQuery() returned httpStatus=%1, body=%2", httpStatus, body)
		return {},httpStatus
	else
		D("doJSONQuery() fixing up JSON response for parsing")
		-- Fix booleans, which json doesn't seem to understand (gives nil)
		body = string.gsub( body, ": *true *,", ": 1," )
		body = string.gsub( body, ": *false *,", ": 0," )

		-- Process JSON response. First parse response.
		--D("jsonQuery(): final body is %1", body)
		local t, pos, err = json.decode(body)
		if err then
			D("Unable to decode JSON response, %2 at %3 (dev %1)", luup.device, err, pos)
			return {}, 500
		end
		return t,200
	end
end

local function split( str, sep )
	if sep == nil then sep = "," end
	local arr = {}
	if str == nil or #str == 0 then return arr, 0 end
	local rest = string.gsub( str or "", "([^" .. sep .. "]*)" .. sep, function( m ) table.insert( arr, m ) return "" end )
	table.insert( arr, rest )
	return arr, #arr
end

local function shallowCopy( t )
	local r = {}
	for k,v in pairs( t ) do
		r[k] = v
	end
	return r
end

local function listFiles( dir )
	local pdir = io.popen("ls -lau '" .. dir .. "'")
	local t = {}
	for fl in pdir:lines() do
		if fl:sub(1,5):lower() ~= "total" then
			local fx = split(fl, "%s+")
			local fn = fx[9]
			if fn ~= "." and fn ~= ".." then
				local ft = fx[1]:sub(1,1)
				if ft == "-" then ft = "f" end
				local fs = fx[5]
				local fp = fx[1]:sub(2)
				table.insert(t, { name=fn, ['type']=ft, perms=fp, size=(ft~="d") and fs or nil })
			end
		end
	end
	return t
end

local function locate( filePattern, dir )
	local files = listFiles( dir )
	for _,ff in ipairs(files) do
		if ff.name:find(filePattern) then return dir,ff.name end
		if ff['type'] == "d" and not ff.name:find("^%.%.?$") then
			local subdir,name = locate( filePattern, dir .. "/" .. ff.name )
			if subdir then return subdir, name end
		end
	end
	return nil
end

local function loadIgnoreFiles( dir )
	local t = { '^%.', '%.md$' } -- default ignore all files starting with dot, and markdown
	local fh = io.open(dir .. "/.guignore", "r")
	if fh == nil then return t end
	for ll in fh:lines() do
		if string.byte(ll) ~= 59 then
			table.insert( t, (ll:gsub( "%s+;.*", "" )) )
		end
	end
	fh:close()
	return t
end

local function matchesAny( arr, str )
	for _,p in ipairs( arr ) do
		if str:match( p ) then 
			D("matchesAny() %1 matches %2", str, p)
			return true 
		end
	end
	return false
end

DEFAULT_RELEASES = { ['type']="rel", branch="master" }
DEFAULT_BRANCHHEAD = { ['type']="branch", branch="master" }

-- Check to see if there's an update. An update is a published release in the
-- repository, not marked as draft or pre-release, with a publication date
-- higher than the current release version. Note that the current release id
-- must be supplied for this comparison. If we don't know what's installed,
-- we don't install anything, unless forceHead is passed as true, in which case,
-- we'll set up to unconditionally update to the newest available release.
function checkForUpdate( guser, grepo, uInfo, forceHead )
	if not uInfo then
		-- Default highest release associated with master branch
		uInfo = shallowCopy( DEFAULT_RELEASES )
	elseif type(uInfo) == "string" then
		-- Base64 encoded round-trip string from previous doUpdate() call.
		local mime = require "mime"
		local s = mime.unb64( uInfo )
		if not s then
			-- Not base64. Number in a string?
			s = tonumber( uInfo )
			if not s then error("Invalid revision info block") end
			-- Old, old way #2, just a number (as a string)
			uInfo = { ['type']="rel", branch="master", tag=uInfo }
		else
			uInfo = json.decode( s )
			if not s then error("Invalid revision info data") end
			if uInfo.version == nil or uInfo.version > _VNUM then
				error("Revision data is from a later version of GitUpdater. Please update GitUpdater!")
			end
		end
	elseif type(uInfo) ~= "table" then
		-- Old, old way, just a number
		uInfo = { ['type']="rel", branch="master", tag=uInfo }
	end

	if uInfo.type == "rel" then
		-- Query the release list from GitHub
		D("checkForUpdate() checking for releases for %1/%2, current %3, force %4", guser, grepo, uInfo, forceHead)
		local url = "https://api.github.com/repos/" .. guser .. "/" .. grepo .. "/releases"
		local releaseData, httpStatus = jsonQuery( url )
		if httpStatus ~= 200 then
			D("checkForUpdate() failed to get release data for %3", guser, grepo, url)
			error(string.format("Failed to fetch release data for %s/%s", tostring(guser),tostring(grepo)))
		end

		-- Find the current (if we can) and newest published, non-pre-release, non-draft release.
		local newest = nil
		local current = nil
		for _,r in ipairs(releaseData) do
			D("checkForUpdate() checking release id %3 tag %1 published %2", r.tag_name, r.published_at, r.id)
			if uInfo.tag and tostring(uInfo.tag) == tostring(r.id) then
				D("checkForUpdate() this is the current installed release")
				current = r
			end
			if ( r.draft or 0 ) == 0 and ( r.prerelease or 0 ) == 0 and
				(uInfo.branch or "master") == r.target_commitish then
				local pdate = r['published_at']
				if newest == nil or pdate > newest.pubdate then
					newest = r
					newest['pubdate'] = pdate
				end
			end
		end

		-- If we've got a release newer than what we're on, package up to return that.
		D("checkForUpdate() end of search. The current release is %1; the newest is %2; forceHead=%3", (current or {}).id, (newest or {}).id, forceHead)
		if newest and (forceHead or (current and current.published_at < newest.published_at)) then
			if current then
				D("%1 currently at %2 (%4), update available %3 (%5)", grepo, current.tag_name, newest.tag_name, current.id, newest.id)
			else
				D("%1 update available %2 (%3)", grepo, newest.tag_name, newest.id)
			end
			return true, {
				id={ version=_VNUM, repo=grepo, user=guser, ['type']="rel", branch=uInfo.branch or "master", tag=newest.id, tagname=newest.tag_name, url=newest.tarball_url },
				text="release "..newest.name.." ("..newest.tag_name..", "..(uInfo.branch or "master")..")",
				repository=guser.."/"..grepo,
				branch=uInfo.branch or "master",
				tag=newest.tag_name,
				name=newest.name,
				published=newest.pubdate,
				comment=newest.body
			}
		end
	elseif uInfo.type == "branch" then
		-- Query the branch for new commits
		D("checkForUpdate() checking for branch updates in %1/%2, current %3, force %4", guser, grepo, uInfo, forceHead)
		local url = "https://api.github.com/repos/" .. guser .. "/" .. grepo .. "/branches/" .. (uInfo.branch or "master")
		local data, httpStatus = jsonQuery( url )
		if httpStatus ~= 200 then
			D("checkForUpdate() failed to get branch data for %3", guser, grepo, url)
			error(string.format("Failed to fetch branch data for %s/%s", tostring(guser), tostring(grepo)))
		end
		-- Simple on a branch -- head commit should match if we're up-to-date.
		D("checkForUpdate() checking head commit %1 against last %2", data.commit.sha, uInfo.commit)
		if data.commit.sha ~= uInfo.commit or forceHead then
			return true, {
				id={ version=_VNUM, repo=grepo, user=guser, ['type']="branch", branch=uInfo.branch or "master", commit=data.commit.sha, url=data.commit.commit.tree.url },
				text="branch "..(uInfo.branch or "master").." (head)",
				repository=guser.."/"..grepo,
				commit=data.commit.sha,
				published=data.commit.commit.committer.date,
				comment=data.commit.commit.message,
			}
		end
	else
		D("checkForUpdate() unknown updateID %1", uInfo)
		error("Invalid update type--is your info from a newer version of GitUpdater?")
	end

	-- Nah.
	D("no updates available for %1/%2", guser, grepo)
	return false
end

-- Perform an update using information previously provided by checkForUpdate()
function doUpdate( uInfo )
	if uInfo.type == nil and (uInfo.id or {})['type'] ~= nil then
		-- Caller passed full return structure, just grab "id" subkey, all we need here.
		uInfo = uInfo.id
	end
	if uInfo.url == nil then error("Invalid update info; this update may already have been completed.") end
	if uInfo.version == nil or uInfo.version > _VNUM then
		error("Update info is from a later version of GitUpdater. Please update GitUpdater!")
	end
	local guser = uInfo['user']
	local grepo = uInfo.repo
	D("doUpdate() attempting to update %1/%2 to %3 (%4)", guser, grepo, uInfo.tag, uInfo.id )
	if not guser or not grepo then error "Invalid repo data" end
	local tmpdir,instdir,instfiles,st

	if uInfo.type == "rel" then
		-- Fetch the tarball with the release files
		D("doUpdate() fetching tarball %1", uInfo.url)
		local fn = os.tmpname() .. ".tgz"
		st = os.execute( "curl -s -S -L -o '"..fn.."' '"..uInfo.url.."'" )
		D("curl -s -S -L -o '"..fn.."' '"..uInfo.url.."' returns %1", st)
		if st ~= 0 then error "Download of release archive failed" end
		local fh = io.open( fn, "r" )
		if not fh then error "Download of update failed" end
		fh:close()

		-- Make a temporary directory as a target for un-tarring
		tmpdir = "/tmp/" .. grepo:lower() .. "-" .. uInfo.tagname:lower():gsub( "^v", "" )
		D("doUpdate() wrote %1, creating %2", fn, tmpdir)
		st = os.execute("mkdir -p '" .. tmpdir .. "'")
		if st ~= 0 then
			os.execute( "rm -f -- '"..fn.."'" )
			error("Unable to create temporary directory " .. tmpdir)
		end

		-- Un-tar the temporary file into the temporary directory
		D("doUpdate() untarring %1 to %2", fn, tmpdir)
		st = os.execute("cd '" .. tmpdir .. "' && tar xzf '" .. fn .. "'")
		if st ~= 0 then error "Unable to un-tar release archive" end

		-- Remove tarball now that we're done with it.
		if not debugMode then
			os.execute( "rm -f -- '"..fn.."'" )
		end

		-- Since the tarball has directory structure we can't control, locate
		-- a device file in the un-tarred tree to figure out where things are.
		instdir = locate("D_.*%.xml", tmpdir)
		if not instdir then error "Unable to locate any device files in %1; unable to update." end

		-- Now get all the files in that directory, and copy them to /etc/cmh-ludl,
		-- except any listed in a file called ".guignore" (if it exists).
		instfiles = listFiles( instdir )
	elseif uInfo.type == "branch" then
		-- Fetch all files in the specified commit and store them in the temporary directory.
		local mime = require "mime"
		instfiles = {}
		tmpdir = os.tmpname():gsub( "/[^/]+$", "/" )
		tmpdir = tmpdir .. grepo:lower() .. "-" .. uInfo.commit
		instdir = tmpdir -- same as tmpdir for branch
		st = os.execute( "mkdir -p '"..tmpdir.."'" )
		if st ~= 0 then error("Unable to create temporary directory "..tmpdir) end
		local data, httpStatus = jsonQuery( uInfo.url )
		if httpStatus ~= 200 then error("Failed to fetch commit tree "..uInfo.url) end
		for _,ff in ipairs( data.tree or {} ) do
			local fh = io.open( tmpdir .. "/" .. ff.path, "r" )
			if fh then
				fh:close()
				D("doUpdate() %1/%2 already exists, not fetching", tmpdir, ff.path)
				-- ??? future: check size? correct? non-zero?
			else
				D("doUpdate() fetching %1 to %2", ff.path, tmpdir)
				local fs
				fs, httpStatus = jsonQuery( ff.url )
				if httpStatus ~= 200 then error("Failed to fetch file from commit tree "..ff.url) end
				D("doUpdate() writing %1/%2", tmpdir, ff.path)
				-- Write a temporary file first.
				fh = io.open( tmpdir .. "/" .. ff.path .. ".tmp", "w" )
				if fs.content ~= "" then
					if fs.encoding == "base64" then
						fs.content = fs.content:gsub( "[\r\n]+", "" )
						fh:write( (mime.unb64( fs.content )) )
					else
						fh:close()
						error("Unknown encoding "..tostring(fs.encoding).. " for "..ff.path)
					end
				end
				fh:close()
				fs.content = nil
				-- Move the finished temporary file into place as final.
				os.execute( "mv -f '"..tmpdir.."/"..ff.path..".tmp' '"..tmpdir.."/"..ff.path.."'" )
			end
			table.insert( instfiles, { name=ff.path, ['type']="f", mode=ff.mode } )
			if false and ff.mode then
				-- Set file mode as specified?
			else
				os.execute( "chmod 0644 '"..tmpdir.."/"..ff.path.."'" )
			end
		end
	end

	local nCopy = 0
	local ignoreFiles = loadIgnoreFiles( instdir )
	for _,ff in ipairs( instfiles ) do
		D("doUpdate() considering copying %1/%2 (%3)", instdir, ff.name, ff.type)
		if ff.type == "f" and not matchesAny( ignoreFiles, ff.name ) then
			D("doUpdate() copying %1/%2 to /etc/cmh-ludl/", instdir, ff.name )
			if type(luup) == "table" then
				-- On Vera, compress the source file in the installation directory
				st = os.execute("umask 022 && pluto-lzo c '" .. instdir .. "/" .. ff.name .. "' '/etc/cmh-ludl/" .. ff.name .. ".lzo'")
				if st == 0 then os.execute( "rm -f -- '/etc/cmh-ludl/" .. ff.name .. "'" ) end
			else
				-- Elsewhere, just copy it. ??? Can we detect openLuup somehow?
				st = os.execute("umask 022 && cp -fp '" .. instdir .. "/" .. ff.name .. "' /etc/cmh-ludl/")
			end
			if st == 0 then nCopy = nCopy + 1
			else
				D("doUpdate(): failed to install %1, status %2... that's not good!", instdir .. "/" .. ff.name, st)
			end
		end
	end

	if not debugMode then
		-- Clean up
		os.execute("rm -rf -- '" .. tmpdir .. "'")
	end

	-- If nothing was copied, it's the same as not updating, so bail.
	if nCopy == 0 then
		error("Unable to successfully install any of the release files from " .. instdir)
	end

	-- Finished. Return a "round trip" string that can be passed to checkUpdate()
	-- in future to see if any updates have been committed since.
	D("doUpdate() update of %1 to %2 %3 complete, %4 files installed.", grepo, uInfo.branch, uInfo.tag or uInfo.commit, nCopy)
	uInfo = shallowCopy( uInfo ) -- Don't modify passed-in original
	uInfo.url = nil -- remove from returned struct (indicates final)
	return (require("mime").b64( json.encode( uInfo )))
end
