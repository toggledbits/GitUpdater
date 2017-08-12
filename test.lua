gu = require('GitUpdater')

canUpdate,updateInfo = gu.checkForUpdate( "toggledbits", "SiteSensor", 7341314 )

if canUpdate then
    print("UPDATE AVAILABLE!")
    status, tag = gu.doUpdate( "toggledbits", "SiteSensor", updateInfo )
    if status then
        -- Update succeeded, so tag contains the release tag we updated to. This should be saved and
        -- passed in all subsequent calls to checkForUpdate()
        print("UPDATE COMPLETE! We are now at " .. tag .. ". Need to do luup.reload() now!")
    else
        -- Update failed, tag will contain an error message
        print("UPDATE FAILED: " .. tag)
    end
else 
    print("NO UPDATE AVAILABLE")
end

gu.checkForUpdate("toggledbits", "SiteSensor", 7349375 )