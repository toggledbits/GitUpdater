-- GitUpdater: A service module for updating Luup plugins from Github
-- (c) 2017 Patrick H. Rigney, All Rights Reserved
-- Distributed under GPL 3.0. For information see the LICENSE file at
--luacheck: std lua51,module,read globals luup debugMode,ignore 542 611 612 614 111/_,no max line length

local _M = {}

_M._VERSION="0.2"
_M._VNUM = 19273

local debugMode = true

local https = require("ssl.https")
local http = require("socket.http")
local ltn12 = require("ltn12")
local json = require('dkjson')

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

-- Matches str against patterns in arr. Any pattern starting ! inverts test (true if not matching)
local function matchesAny( arr, str )
	local _,_,f = str:find("/([^/]+)$")
	if not f then f = str end
	for _,p in ipairs( arr ) do
		local _,_,w = p:find("^!(.*)")
		if w then
			-- Invert pattern
			if not ( f:match(w) or str:match(w) ) then return true end
		else
			if f:match(p) or str:match(p) then return true end
		end
	end
	return false
end

local function Q(s)
	return "'"..s:gsub( "'", "\\'" ).."'"
end

_M.MASTER_RELEASES = { ['type']="rel", branch="master" }

local function getReleaseChannel( branch )
	if ( branch or "master" ) == "master" then return _M.MASTER_RELEASES end
	return { ['type']="rel", branch=branch }
end

local function getHeadChannel( branch )
	return { ['type']="branch", branch=branch or "master" }
end

-- Check to see if there's an update. An update is a published release in the
-- repository, not marked as draft or pre-release, with a publication date
-- higher than the current release version. Note that the current release id
-- must be supplied for this comparison. If we don't know what's installed,
-- we don't install anything, unless forceHead is passed as true, in which case,
-- we'll set up to unconditionally update to the newest available release.
local function checkForUpdate( guser, grepo, uInfo, forceHead )
	if not uInfo then
		-- Default highest release associated with master branch
		uInfo = shallowCopy( MASTER_RELEASES )
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
			if uInfo.version == nil or uInfo.version > _M._VNUM then
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
				id={ version=_M._VNUM, repo=grepo, user=guser, ['type']="rel", branch=uInfo.branch or "master", tag=newest.id, tagname=newest.tag_name, url=newest.tarball_url },
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
				id={ version=_M._VNUM, repo=grepo, user=guser, ['type']="branch", branch=uInfo.branch or "master", commit=data.commit.sha, url=data.commit.commit.tree.url },
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
local function doUpdate( uInfo, installPath )
	installPath = installPath or "/etc/cmh-ludl/"
	assert( installPath:match( "%/$"), "Install path must have trailing /" )
	local mime = require "mime"
	if uInfo.type == nil and (uInfo.id or {})['type'] ~= nil then
		-- Caller passed full return structure, just grab "id" subkey, all we need here.
		uInfo = uInfo.id
	end
	if uInfo.url == nil then error("Invalid update info; this update may already have been completed.") end
	if uInfo.version == nil or uInfo.version > _M._VNUM then
		error("Update info is from a later version of GitUpdater. Please update GitUpdater!")
	end
	local guser = uInfo['user']
	local grepo = uInfo.repo
	D("doUpdate() attempting to update %1/%2 to %3 (%4)", guser, grepo, uInfo.tag, uInfo.id )
	if not guser or not grepo then error "Invalid repo data" end
	local tmpdir,instdir,instfiles,st,guinfo

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
		instdir = locate("I_.*%.xml", tmpdir)
		if not instdir then error "Unable to locate any implementation files in %1; unable to update." end

		-- Now get all the files in that directory, and copy them to /etc/cmh-ludl,
		-- except any listed in a file called ".guignore" (if it exists).
		instfiles = listFiles( instdir )
		guinfo = exists( tmpdir .. ".guinfo" ) and ".guinfo"
	elseif uInfo.type == "branch" then
		-- Fetch all files in the specified commit and store them in the temporary directory.
		instfiles = {}
		tmpdir = os.tmpname():gsub( "/[^/]+$", "/" )
		tmpdir = tmpdir .. grepo:lower() .. "-" .. uInfo.commit
		st = os.execute( "mkdir -p '"..tmpdir.."'" )
		if st ~= 0 then error("Unable to create temporary directory "..tmpdir) end
		-- Note recursive fetch https://developer.github.com/v3/git/trees/#get-a-tree-recursively
		local data, httpStatus = jsonQuery( uInfo.url .. "?recursive=1" )
		if httpStatus ~= 200 then error("Failed to fetch commit tree "..uInfo.url) end
		for _,ff in ipairs( data.tree or {} ) do
			if ff.type == "tree" then
				D("doUpdate() creating subdirectory for tree %1 as %1/%2", ff.path, tmpdir, ff.path)
				os.execute( "mkdir -p '" .. tmpdir .. "/" .. ff.path .. "'" )
			elseif ff.type == "blob" then
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
					-- Write a temporary file first. Write binary, so nothing is translated.
					fh = io.open( tmpdir .. "/" .. ff.path .. ".tmp", "wb" )
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
				local file = ff.path:match( "[^/]+$" )
				local path = (#ff.path > #file) and ff.path:sub( 1, #ff.path-#file-1 ) or nil
				table.insert( instfiles, { name=file, ['type']="f", mode=ff.mode, path=path } )
				D("doUpdate() listing %1 as dir=%2, file=%3", ff.path, path, file)
				if false and ff.mode then
					-- Set file mode as specified?
				else
					os.execute( "chmod 0644 '"..tmpdir.."/"..ff.path.."'" )
				end
				if not instdir and file:match("I_%w+%.xml$") then
					instdir = path
					D("doUpdate() marking instdir %1", instdir)
				end
				if ff.path:match( "^%.guinfo$" ) then
					guinfo = ".guinfo"
				end
			else
				D("doUpdate() ignoring unknown object type %1", ff.type)
			end
		end
	end

	-- If we have an info file telling us what to install, set up for that. 
	-- Otherwise, set up to filter out all files not adjacent to the impl file.
	local nCopy = 0
	local ignoreFiles = loadIgnoreFiles( tmpdir )
	if guinfo then
	else
		-- If we know install directory (where impl lives), as non-match pattern
		if instdir then table.insert( ignoreFiles, 1, "!^"..instdir.."/" ) end
	end
	D("doUpdate() ignoreFiles=%1", ignoreFiles)
	for _,ff in ipairs( instfiles ) do
		local fp = ff.path and ( ff.path .. "/" .. ff.name ) or ff.name
		D("doUpdate() considering copying %1/%2 (%3)", tmpdir, fp, ff.type)
		if ff.type == "f" and not matchesAny( ignoreFiles, fp ) then
			D("doUpdate() copying %1/%2 to %3", tmpdir .. fp, installPath )
			if luup.openLuup then
				-- OpenLuup, just copy the file.
				print("umask 022 && cp -fp -- " .. Q(tmpdir .. "/" .. fp) .. " " .. Q(installPath))
				st = os.execute("umask 022 && cp -fp -- " .. Q(tmpdir .. "/" .. fp) .. " " .. Q(installPath))
			else
				-- On Vera, compress the source file in the installation directory
				st = os.execute("umask 022 && pluto-lzo c " .. Q(tmpdir .. "/" .. fp) .. " " .. Q(installPath .. ff.name .. ".lzo"))
				if st == 0 then os.execute( "rm -f -- " .. Q(installPath .. ff.name)) end
			end
			if st == 0 then nCopy = nCopy + 1
			else
				D("doUpdate(): failed to install %1 to %3, status %2... that's not good!", tmpdir .. "/" .. fp, st, installPath)
			end
		end
	end

	if not debugMode then
		-- Clean up
		os.execute("rm -rf -- '" .. tmpdir .. "'")
	end

	-- If nothing was copied, it's the same as not updating, so bail.
	-- ??? What if only partial copy
	if nCopy == 0 then
		error("Unable to successfully install any of the release files from " .. tmptdir)
	end

	-- Finished. Return a "round trip" string that can be passed to checkUpdate()
	-- in future to see if any updates have been committed since.
	D("doUpdate() update of %1 to %2 %3 complete, %4 files installed.", grepo, uInfo.branch, uInfo.tag or uInfo.commit, nCopy)
	uInfo = shallowCopy( uInfo ) -- Don't modify passed-in original
	uInfo.url = nil -- remove from returned struct (indicates final)
	uInfo.installed = os.time()
	return mime.b64( json.encode( uInfo ) )
end

-- NOTE: DO NOT USE THIS AS AN EXAMPLE OF HOW TO USE GITUPDATER! THIS IS A SPECIAL UPDATE PROCESS
--       INTENDED ONLY FOR SELF-UPDATING OF THIS LIBRARY. SEE THE DOCS FOR CORRECT USAGE.
local function selfUpdate( uinfo, forceUpdate )
	if forceUpdate == nil then forceUpdate = uinfo == nil or uinfo == _M.MASTER_RELEASES end
	local _,upid = checkForUpdate( "toggledbits", "GitUpdater", uinfo or _M.MASTER_RELEASES, forceUpdate )
	D("%1", upid)
	if forceUpdate or upid.tag ~= string.format("v%s", _M._VERSION) then
		D("GitUpdater self-updating from v%1 to %2", _M._VERSION, upid.tag)
		local path
		if luup.openLuup then
			local loader = require "openLuup.loader"
			if loader.find_file then
				path = loader.find_file( "GitUpdater.lua" ):gsub( "GitUpdater.lua$", "" )
			else
				path = "./"
			end
		end
		doUpdate( upid, path )
		return true
	else
		D("Up to date -- we are v%1, release is %2", _M._VERSION, upid.tag)
		return false
	end
end

-- Function exports
_M.getReleaseChannel = getReleaseChannel
_M.getBranchChannel = getBranchChannel
_M.checkForUpdate = checkForUpdate
_M.doUpdate = doUpdate
_M.selfUpdate = selfUpdate

return _M
