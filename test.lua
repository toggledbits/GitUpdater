-- Defensive load
_, gu = pcall( require, 'GitUpdater' )
if gu == nil then
	print("GitUpdater is not installed.")
	return
end
print(gu)

json = require "dkjson"

for k,v in pairs(gu) do print(k,v) end

local updateInfo = gu.getBranchChannel( "stable" )

status,canUpdate,updateInfo = pcall( gu.checkForUpdate, "toggledbits", "Switchboard-Vera", updateInfo, true )
if not status then
	print("checkForUpdate threw an error:", canUpdate)
	os.exit(1)
end

if canUpdate then
	print(json.encode(updateInfo,{indent=4}))
    print("UPDATE AVAILABLE!")
    status,info = pcall( gu.doUpdate, updateInfo )
	if not status then
		print("doUpdate() failed:", info)
		os.exit(1)
	end
    -- Update succeeded, so tag contains the release tag we updated to. This should be saved and
    -- passed in all subsequent calls to checkForUpdate()
    print("UPDATE COMPLETE! Info to store is",info)
	
	canUpdate,updateInfo = gu.checkForUpdate( "toggledbits", "Switchboard-Vera", info )
	print("Round-trip status is",canUpdate,updateInfo)
else 
    print("NO UPDATE AVAILABLE")
end