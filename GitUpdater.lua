-- GitUpdater: A service module for updating Luup plugins from Github
-- (c) 2017 Patrick H. Rigney, All Rights Reserved
-- Distributed under GPL 3.0. For information see the LICENSE file at
-- http://
--
module("GitUpdater", package.seeall)

local _VERSION="0.1"

local https = require("ssl.https")
local http = require("socket.http")
local ltn12 = require("ltn12")
local dkjson = require('dkjson')

local debugMode = false

local function L(msg, ...)
    if type(msg) == "table" then
        str = msg["prefix"] .. msg["msg"]
    else
        str = "GitUpdater: " .. msg
    end
    str = string.gsub(str, "%%(%d+)", function( n )
            n = tonumber(n, 10)
            if n < 1 or n > #arg then return "nil" end
            local val = arg[n]
            if type(val) == "table" then
                return dkjson.encode(val)
            elseif type(val) == "string" then
                return string.format("%q", val)
            end
            return tostring(val)
        end
    )
    if luup then luup.log(str) else print(str) end
end

local function D(msg, ...)
    if debugMode then L({msg=msg,prefix="(debug)"}, unpack(arg)) end
end

local function doRequest(url, method, body, timeout)
    if method == nil then method = "GET" end
    if timeout == nil then timeout = 60 end

    local src
    local tHeaders = {}

    -- Build post/put data
    if type(body) == "table" then
        body = dkjson.encode(body)
        tHeaders["Content-Type"] = "application/json"
    end
    if body ~= nil then
        tHeaders["Content-Length"] = string.len(body)
        src = ltn12.source.string(body)
    else
        src = nil
    end

    -- HTTP or HTTPS?
    local requestor
    if url:lower():find("https:") then
        requestor = https
    else
        requestor = http
    end

    -- Make the request.
    local respBody, httpStatus, httpHeaders
    local r = {}
    http.TIMEOUT = timeout -- N.B. http not https, regardless
    D("HTTP %2 %1, headers=%3", url, method, tHeaders)
    respBody, httpStatus, httpHeaders = requestor.request{
        url = url,
        source = src,
        sink = ltn12.sink.table(r),
        method = method,
        headers = tHeaders,
        redirect = false
    }
    D("doRequest() request returned httpStatus=%1, respBody=%2", httpStatus, respBody)

    -- Since we're using the table sink, concatenate chunks to single string.
    respBody = table.concat(r)

    D("Response status %1, body length %2", httpStatus, string.len(respBody))

    -- See what happened. Anything 2xx we reduce to 200 (OK).
    if httpStatus == 302 then
        D("doRequest(): redirecting to %1", httpHeaders['location'])
        return doRequest( httpHeaders['location'], method, nil, timeout )
    end
    if httpStatus >= 200 and httpStatus <= 299 then
        -- Success response with no data, take shortcut.
        return false, respBody, 200
    end
    return true, respBody, httpStatus
end

local function jsonQuery(url)
    local err,body,httpStatus
    err,body,httpStatus = doRequest(url, "GET")
    D("doJSONQuery() returned httpStatus=%1", httpStatus, body)
    if httpStatus ~= 200 then
        return {},httpStatus
    else
        D("doJSONQuery() fixing up JSON response for parsing")
        -- Fix booleans, which dkjson doesn't seem to understand (gives nil)
        body = string.gsub( body, ": *true *,", ": 1," )
        body = string.gsub( body, ": *false *,", ": 0," )

        -- Process JSON response. First parse response.
        --D("jsonQuery(): final body is %1", body)
        local t, pos, err
        t, pos, err = dkjson.decode(body)
        if err then
            L("Unable to decode JSON response, %2 (dev %1)", luup.device, err)
            return {}, 500
        end

        D("doJSONQuery() parsed response")
        return t,200
    end
end

local function split(s, sep)
    local t = {}
    local n = 0
    if (#s == 0) then return t,n end -- empty string returns nothing
    local i,j
    local k = 1
    repeat
        i, j = string.find(s, sep or "%s*,%s*", k)
        if (i == nil) then
            table.insert(t, string.sub(s, k, -1))
            n = n + 1
            break
        else
            table.insert(t, string.sub(s, k, i-1))
            n = n + 1
            k = j + 1
        end
    until k > string.len(s)
    return t, n
end

local function listFiles( dir )
    local pdir = io.popen("ls -lau '" .. dir .. "'")
    local t = {}
    for fl in pdir:lines() do
        if fl:sub(1,5) ~= "total" then
            local fx = split(fl, "%s+")
            local fn = fx[9]
            local ft = fx[1]:sub(1,1)
            if ft == "-" then ft = "f" end
            local fs = fx[5]
            local fp = fx[1]:sub(2)
            local v = { ['name']=fn, ['type']=ft, perms=fp, size=fs }
            table.insert(t, v)
        end
    end
    return t
end

local function locate( filePattern, dir )
    local files = listFiles( dir )
    local i, ff
    for i,ff in ipairs(files) do
        if ff['name']:find(filePattern) then return dir,ff['name'] end
        if ff['type'] == "d" and not ff['name']:find("^%.%.?$") then
            local subdir, name
            subdir,name = locate( filePattern, dir .. "/" .. ff['name'] )
            if subdir then return subdir, name end
        end
    end
    return nil
end

local function loadIgnoreFiles( dir )
    local t = { ['.guignore']=0, ['README.md']=0, ['LICENSE']=0 }
    local fh = io.open(dir .. "/.guignore", "r")
    if fh == nil then return t end
    local ll
    for ll in fh:lines() do
        t[ll] = true
    end
    return t
end

-- Check to see if there's an update. An update is a published release in the
-- repository, not marked as draft or pre-release, with a publication date
-- higher than the current release version. Note that the current release id
-- must be supplied for this comparison. If we don't know what's installed,
-- we don't install anything, unless forceHead is passed as true, in which case,
-- we'll set up to unconditionally update to the newest available release.
function checkForUpdate( guser, grepo, lastUpdateId, forceHead )
    if forceHead == nil then forceHead = false end
    assert(type(forceHead) == "boolean")
    
    -- Query the release list from GitHub
    L("checking for updates for %1/%2, current %3, force %4", guser, grepo, lastUpdateId, forceHead)
    local url = "https://api.github.com/repos/" .. guser .. "/" .. grepo .. "/releases"
    local releaseData, httpStatus
    releaseData,httpStatus = jsonQuery( url )
    if httpStatus ~= 200 then
        L("checkForUpdate() failed to get release data for %3", guser, grepo, url)
        return false
    end
    
    -- Find the current (if we can) and newest published, non-pre-release, non-draft release.
    local i, r
    local newest = nil
    local current = nil
    for i,r in ipairs(releaseData) do
        D("checkForUpdate() checking release id %3 tag %1 published %2", r.tag_name, r['published_at'], r.id)
        if lastUpdateId ~= nil and tostring(lastUpdateId) == tostring(r.id) then
            D("checkForUpdate() this is the current installed release")
            current = r
        end
        if r.draft == 0 and r.prerelease == 0 then
            local pdate = r['published_at']
            if newest == nil or pdate > newest.pubdate then
                newest = r
                newest['pubdate'] = pdate
            end
        end
    end
    
    -- If we've got a release newer than what we're on, package up to return that.
    D("checkForUpdate() end of search. The current release is %1; the newest is %2", current, newest)
    if (forceHead or (current ~= nil and newest.published_at > current.published_at)) then
        if current ~= nil then
            L("%1 currently at %2 (%4), update available %3 (%5)", grepo, current.tag_name, newest.tag_name, current.id, newest.id)
        else
            L("%1 update available %2 (%3)", grepo, newest.tag_name, newest.id)
        end
        return true, { repository={ name=grepo, ['user']=guser }, tag=newest.tag_name, id=newest.id, published=newest.pubdate, tarball=newest.tarball_url, name=newest.name, comment=newest.body }
    end
    
    -- Nah.
    L("no updates available for %1/%2", guser, grepo)
    return false
end

-- Perform an update using information previously provided by checkForUpdate()
function doUpdate( uInfo )
    local guser = uInfo.repository['user']
    local grepo = uInfo.repository.name
    local err, body, httpStatus
    L("attempting to update %1/%2 to %3 (%4)", guser, grepo, uInfo.tag, uInfo.id )

    -- Fetch the tarball with the release files
    D("doUpdate() fetching tarball %1", uInfo.tarball)
    err,body,httpStatus = doRequest( uInfo.tarball, "GET" )
    if httpStatus ~= 200 then
        return false, "Invalid HTTP return status " .. httpStatus
    else
        -- Have tarball (in memory); write to temporary file
        D("doUpdate() returned body with %1 bytes", string.len(body))
        local fn = os.tmpname() .. ".tgz"
        local dd = "/tmp/" .. grepo:lower() .. "-" .. uInfo.tag:lower()
        local fh = io.open( fn, "wb" )
        if fh == nil then
            return false, "Unable to save GitHub tarball in " .. fn
        end
        fh:write( body )
        fh:close()

        -- Make a temporary directory as a target for un-tarring
        D("doUpdate() wrote %1, creating %2", fn, dd)
        local st = os.execute("mkdir -p " .. dd)
        if st ~= 0 then
            return false, "Unable to create temporary directory " .. dd
        end

        -- Un-tar the temporary file into the temporary directory
        D("doUpdate() untarring %1 to %2", fn, dd)
        st = os.execute("cd " .. dd .. " && tar xzf " .. fn)
        if st ~= 0 then
            return false, "Unable to un-tar release archive"
        end

        -- Since the tarball has directory structure we can't control, locate
        -- a device file in the un-tarred tree to figure out where things are.
        local fd, ff
        fd,ff = locate("D_.*%.xml", dd)
        if fd == nil then
            L("Unable to locate any device files in %1; unable to update.", dd)
            return false
        end

        -- Now get all the files in that directory, and copy them to /etc/cmh-ludl,
        -- except any listed in a file called ".guignore" (if it exists).
        local uf = listFiles( fd )
        local ignoreFiles = loadIgnoreFiles( fd )
        local nCopy = 0
        for i, ff in ipairs(uf) do
            D("doUpdate() considering copying %1/%2", fd, ff['name'])
            if ff['type'] == "f" and not (ff['name']:find("^%.") or ignoreFiles[ff['name']]) then
                if luup then
                    -- On Vera, compress the source file in the installation directory
                    st = os.execute("umask 022 && pluto-lzo c '" .. fd .. "/" .. ff['name'] .. "' '/etc/cmh-ludl/" .. ff['name'] .. "'")
                else
                    -- Elsewhere, just copy it. ??? Can we detect openLuup somehow?
                    st = os.execute("umask 022 && cp '" .. fd .. "/" .. ff['name'] .. "' /etc/cmh-ludl/")
                end
                if st == 0 then nCopy = nCopy + 1
                else
                    D("doUpdate(): failed to install %1, status %2... that's not good!", fd .. "/" .. ff['name'], st)
                end
            end
        end

        -- Clean up
        os.execute("rm '" .. fn .. "'")
        os.execute("rm -rf '" .. dd .. "'")

        -- If nothing was copied, it's the same as not updating, so bail.
        if nCopy == 0 then
            return false, "Unable to successfully install any of the release files from " .. dd
        end

        -- Something happened. Hope it's complete. ??? Not yet sure what to do if all
        -- of the files weren't copied successfully.
        L("update of %1 to %2 complete, %3 files installed.", grepo, uInfo.tag, nCopy)
        return true, uInfo.id
    end
end
