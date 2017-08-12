GitUpdater: Update Vera Plugins from GitHub Releases
=============

## Introduction ##

GitUpdater allows a Vera plugin to bypass the Vera plugin store for updating and update
itself directly from GitHub. Since many Vera plugins and related projects are already
in GitHub projects, this seemed like a natural source.

GitUpdater uses the GitHub release mechanism to determine if a current version is the 
latest, and if an update is needed, fetch and perform the update in place. GitUpdater
itself is a service library, which the plugin calls when it's opportune for it to check
for updates. A separate call performs the update, so it can be scheduled at any time, or
when user-allowed or user-driven.

## History ##

Vera home automation controllers have a "plugin store" where users can find and install published, approved plugins.
However, the infrastructure of this store seems to have frozen in time sometime a few years
ago. The current store, associated with an earlier version of Vera firmware, has not been updated to
keep pace with current firmware versions. Newer firmware still use the old store, but plugin developers
must continue to use the antiquated interface and its painful workflow to publish and update
their work. Worse, apparently Vera rarely looks at the old store (even though all of their customers rely on it), 
so plugins and updates submitted for approval can sit for days or weeks waiting for Vera to get around to them. 
In my personal experience, they don't, unless prompted by an email to support, and even then it can take
several days. 

This is tragic when an urgent fix is needed--the turnaround is just too long. As a result, 
developers often publish modified files directly in the Vera forums or as links to GitHub, 
where Vera users can download them and then push them up to their Vera's. It's the "hail Mary" of patching,
particularly when more than one file is required to be updated, and many accidents can happen
that lead to outright disruption of plugin operation or strange behaviors that are difficult for
developers to diagnose remotely.

While I knew I was not the only plugin developer facing these issues, I was wondering what
other solutions had been proposed or discussed. In a search of the Vera forums,
I found this discussion (http://forum.micasaverde.com/index.php/topic,37979.msg283760.html#msg283760).
As I was, at the moment, working on two new plugins, the thought of having them "self-update" 
had occurred to me, and this conversation provided some validation that the idea was not
necessarily a bad one.

And thus GitUpdater was born on a pizza-fueled August night.

## Incorporating GitUpdater ##

Since GitUpdater is a service library and not a plug-in, it is not installed in the traditional way.
It can be installed with a plugin, if the developer chooses to include it as an adjunct library.
It can also be installed by the user. Either way, if left named as shown in the GitHub repository,
it should be possible for any plugin to benefit from its use.

### Determining if Updates are Available ###

To determine if an update is available, the plugin should load GitUpdater and call checkForUpdates().

<code>GitUpdater = require("GitUpdater")
lastVersionId = luup.variable_get( myServiceId, "GitHubReleaseId", myDeviceNum )
canUpdate, updateInfo = GitUpdater.checkForUpdates( "githubuser", "reponame", lastVersionId, lastVersionId == nil )
if canUpdate then
    local success, newId = GitUpdater.doUpdate( "githubuser", "reponame", updateInfo )
    if success then
        luup.variable_set( myServiceId, "GitHubReleaseId", myDeviceNum )
        luup.reload()
    end
end
</code>

Let's break down how this works, line by line.

Line 1 makes sure the GitUpdater module is loaded and locally available. If it has not been loaded,
require() will load it. Either way, the module reference is returned.

Line 2 gets the GitHub release ID of the currently installed version of the plugin.

Line 3 calls GitUpdater's checkForUpdates() function, passing the GitHub username, repository name,
and the release ID determine in line 2. The fourth parameter, a boolean called "forceNewest",
will always cause checkForUpdates() to indicate that an update should be made to latest GitHub release.
Typically, this should only be set true if the current release ID is not store or otherwise unknown, as is shown here.
checkForUpdates() will return two parameters: a boolean indicating updates are available (true), or not (false); and
a table containing information about the newest release eligible.

Line 4 determines if an update is available, and if so...

Line 5 performs the update by passing the GitHub username, repository name, and release information table (returned
by checkForUpdates()). The doUpdate() function itself then returns two parameters. The first is a boolean success flag,
which if true indicates that the update was completed. In this case, the second return value is the ID of the installed
release, which the plugin must store so it can use it in subsequent calls to checkForUpdates(). If the first return value
is false (update failed), the second value is an error message indicating the reason for the failure.

Line 6 



## Reporting Bugs/Enhancement Requests ##

Bug reports and enhancement requests are welcome! Please use the "Issues" link for the repository to open a new bug report or make an enhancement request.

## License ##

DeusExMachina is offered under GPL (the GNU Public License).

## Additional Documentation ##

### Installation ###

The plugin is installed in the usual way: go to Apps in the left navigation, and click on "Install Apps". 
Search for "Deus Ex Machina II" (make sure you include the "II" at the end to get the UI7-compatible version), 
and then click the "Details" button in its listing of the search results. From here, simply click "Install" 
and wait for the install to complete. A full refresh of the UI is necessary (e.g. Ctrl-F5 on Windows) after installation.

Once you have installed the plugin and refreshed the browser, you can proceed to device configuation.

### Simple Configuration ###

Deus Ex Machina's "Configure" tab gives you a set of simple controls to control the behavior of your vacation haunt.

#### Lights-Out Time ####

The "Lights Out" time is a time, expressed in 24-hour HH:MM format, that is the time at which lights should begin 
shutting off. This time should be after sunset. Keep in mind that sunset is a moving target, and
at certain times of year in some places can be quite late, so a Lights Out time of 20:15, for example, may not be 
a good choice for the longest days of summer. The lights out time can be a time after midnight.

#### House Modes ####

The next group of controls is the House Modes in which DEMII should be active when enabled. If no house mode is selected,
DEMII will operate in _any_ house mode.

#### Controlled Devices ####

Next is a set of checkboxes for each of the devices you'd like DEMII to control.
Selecting the devices to be controlled is a simple matter of clicking the check boxes. Because the operating cycle of
the plug-in is random, any controlled device may be turned on and off several times during the cycling period (between sunset and Lights Out time).
Dimming devices can be set to any level by setting the slider that appears to the right of the device name. 
Non-dimming devices are simply turned on and off (no dimmer slider is shown for these devices).

> Note: all devices are listed that implement the SwitchPower1 and Dimming1 services. This leads to some oddities,
> like some motion sensors and thermostats being listed. It may not be entirely obvious (or standard) what a thermostat, for example, 
> might do when you try to turn it off and on like a light, so be careful selecting these devices.

#### Scene Control ####

The next group of settings allows you to use scenes with DEMII. 
Scenes must be specified in pairs, with
one being the "on" scene and the other being an "off" scene. This not only allows more patterned use of lights, but also gives the user
the ability to handle device-specific capabilities that would be difficult to implement in DEMII. For example, while DEMII can
turn Philips Hue lights on and off (to dimming levels, even), it cannot control their color because there's no UI for that in
DEMII. But a scene could be used to control that light or a group of lights, with their color, as an alternative to direct control by DEMII.

Both scenes and individual devices (from the device list above) can be used simultaneously.

#### Maximum "On" Targets ####

This value sets the limit on the number of targets (devices or scenes) that DEMII can have "on" simultaneously. 
If 0, there is no limit. If you have DEMII controlling a large number of devices, it's probably not a bad idea to 
set this value to some reasonable limit.

#### Final Scene ####

DEMII allows a "final scene" to run when DEMII is disabled or turns off the last light after the "lights out" time. This could be used for any purpose. I personally use it to make sure a whole-house off is run, but you could use it to ensure your alarm system is armed, or your garage door is closed, etc.

The scene can differentiate between DEMII being disabled and DEMII just going to sleep by checking the `Target` variable in service `urn:upnp-org:serviceId:SwitchPower1`. If the value is "0", then DEMII is being disabled. Otherwise, DEMII is going to sleep. The following code snippet, added as scene Lua, will allow the scene to only run when DEMII is being disabled:

```
local val = luup.variable_get("urn:upnp-org:serviceId:SwitchPower1", "Target", pluginDeviceId)
if val == "0" then
    -- Disabling, so return true (scene execution continues).
    return true
else
    -- Not disabling, just going to sleep. Returning false stops scene execution.
    return false
end
```

### Control of DEMII by Scenes and Lua ###

DeusExMachina can be enabled or disabled like a light switch in scenes or through the regular graphical interface (no Lua required),
or by scripting in Lua.
DEMII implements the SwitchPower1 service, so enabling and disabling is the same as turning a light switch on and off:
you simply use the SetTarget action to enable (newTargetValue=1) or disable (newTargetValue=0) DEMII. 
The MiOS GUI for devices and scenes takes care of this for you in its code; if scripting in Lua, you simply do this:

```
luup.call_action("urn:upnp-org:serviceId:SwitchPower1", "SetTarget", { newTargetValue = "0|1" }, pluginDeviceId)
```

### Triggers ###

DEMII signals changes to its enabled/disabled state and changes to its internal operating mode. 
These can be used as triggers for scenes or notifications. DEMII's operating modes are:

* Standby - DEMII is disabled (this is equivalent to the "device is disabled" state event);

* Ready - DEMII is enabled and waiting for the next sunset (and house mode, if applicable);

* Cycling - DEMII is cycling lights, that is, it is enabled, in the period between sunset and the set "lights out" time, and correct house mode (if applicable);

* Shut-off - DEMII is enabled and shutting off lights, having reached the "lights out" time.

When disabled, DEMII is always in Standby mode. When enabled, DEMII enters the Ready mode, then transitions to Cycling mode at sunset, then Shut-off mode at the "lights out" time,
and then when all lights have been shut off, returns to the Ready mode waiting for the next day's sunset. The transition between Ready, Cycling, and Shut-off continues until DEMII 
is disabled (at which point it goes to Standby).

It should be noted that DEMII can enter Cycling or Shut-off mode immediately, without passing through Ready, if it is enabled after sunset or after the "lights out" time, 
respectively. DEMII will also transition into or out of Standby mode immediately and from any other mode when disabled or enabled, respectively.

### Cycle Timing ###

DEMII's cycle timing is controlled by a set of state variables. By default, DEMII's random cycling of lights occurs at randomly selected intervals between 300 seconds (5 minutes) and 1800 seconds (30 minutes), as determined by the `MinCycleDelay` and `MaxCycleDelay` variables. You may change these values to customize the cycling time for your application.

When DEMII is in its "lights out" (shut-off) mode, it uses a different set of shorter (by default) cycle times, to more closely imitate actual human behavior. The random interval for lights-out is between 60 seconds and 300 seconds (5 minutes), as determined by `MinOffDelay` and `MaxOffDelay`. These intervals could be kept short, particularly if DEMII is controlling a large number of lights.

### Troubleshooting ###

If you're not sure what DEMII is going, the easiest way to see is to go into the Settings interface for the plugin. 
There is a text field to the right of the on/off switch in that interface that will tell you what DEMII is currently
doing when enabled (it's blank when DEMII is disabled).

If DEMII isn't behaving as expected, post a message in the MCV forums 
[in this thread](http://forum.micasaverde.com/index.php/topic,11333.0.html)
or open up an issue in the 
[GitHub repository](https://github.com/toggledbits/DeusExMachina/issues).

Please don't just say "DEMII isn't working for me." I can't tell you how long your piece of string is without seeing 
_your_ piece of string. Give me details of what you are doing, how you are configured, and what behavior you observe.
Screen shots help. In many cases, log output may be needed.

#### Test Mode and Log Output ####

If I'm troubleshooting a problem with you, I may ask you to enable test mode, run DEMII a bit, and send me the log output. Here's how you do that:

1. Go into the settings for the DEMII device, and click the "Advanced" tab.
1. Click on the "Variables" tab.
1. Set the "TestMode" variable to 1 (just change the field and hit the TAB key). If the variable doesn't exist, you'll need to create it using the "New Service" tab, which requires you to enter the service ID _exactly_ as shown here (use copy/paste if possible): `urn:toggledbits-com:serviceId:DeusExMachinaII1`
1. If requested, set the TestSunset value to whatever I ask you (this allows the sunset time to be overriden so we don't have to wait for real sunset to see what DEMII is doing).
1. After operating for a while, I'll ask you to email me your log file (`/etc/cmh/LuaUPnP.log` on your Vera). This will require you
to log in to your Vera directly with ssh, or use the Vera's native "write log to USB drive" function, or use one of the many
log capture scripts that's available.
1. Don't forget to turn TestMode off (0) when finished.

Above all, I ask that you please be patient. You probably already know that it can be frustrating at times to figure out
what's going on in your Vera's head. It's no different for developers--it can be a challenging development environment
when the Vera is sitting in front of you, and moreso when dealing with someone else's Vera at a distance.

## FAQ ##

<dl>
    <dt>My lights aren't cycling at sunset. Why?</dt>
    <dd>The most common reasons that lights don't start cycling at midnight are: <ol>
	<li>The time and location on your Vera are not set correctly. Go into Settings > Location on your
		Vera and make sure everything is correct for the Vera's physical location. Remember that in
		the western hemisphere (North, Central & South America, principally) your longitude will
		be a negative number. If you are below the equator, latitude will be negative. If you're not
		sure what your latitude/longitude are, use a site like <a href="http://mygeoposition.com">MyGeoPosition.com</a>.
		If you make any changes to your time or location configuration, restart your Vera.</li>
	<li>You're not waiting long enough. DEMII doesn't instantly jump into action at sunset, it employs its
		configured cycle delays as well, so cycling will usually begin sometime after sunset, up to the
		configured maximum cycle delay (30 minutes by default).</li>
	<li>Your house mode isn't "active." If you've configured DEMII to operate only in certain house modes,
		make sure you're in one of those modes, otherwise DEMII will just sit, even though it's enabled.</li>
	</ol>
    </dd>

    <dt>I made configuration changes, but when I go back into configuration, they seem to be back to the old
        settings.</dt>
    <dd>Refresh your browser or flush your browser cache. On most browsers, you do this by using the F5 key, or
        Ctrl-F5, or Command + R or Option + R on Macs.</dd>

    <dt>What happens if DEMII is enabled afer sunset? Does it wait until the next day to start running?</dt>
    <dd>No. If DEMII is enabled during its active period (between sunset and the configured "lights out" time,
        it will begin cycling the configured devices and scenes. If you enable DEMII after "lights-out," it will
        wait until the next sunset.</dd>

    <dt>What's the difference between House Mode and Enabled/Disabled? Can I just use House Mode to enable and disable DEMII?</dt>
    <dd>The enabled/disabled state of DEMII is the "big red button" for its operation. If you configure DEMII to only run in certain
        house modes, then you can theoretically leave DEMII enabled all the time, as it will only operate (cycle lights) when a
        selected house mode is active. But, some people don't use House Modes for various reasons, so having a master switch
        for DEMII is necessary.</dd>
     
    <dt>I have a feature request. Will you implement it?</dt>
    <dd>Absolutely definitely maybe. I'm willing to listen to what you want to do. But, keep in mind, nobody's getting rich writing Vera
        plugins, and I do other things that put food on my table. And, what seems like a good idea to you may be just that: a good idea for 
        the way <em>you</em> want to use it. The more generally applicable your request is, the higher the likelihood that I'll entertain it. What
        I don't want to do is over-complicate this plug-in so it begins to rival PLEG for size and weight (no disrespect intended there at
        all--I'm a huge PLEG fan and use it extensively, but, dang). DEMII really has a simple job: make lights go on and off to cast a serious
        shadow of doubt in the mind of some knucklehead who might be thinking your house is empty and ripe for his picking. In any case,
        the best way to give me feature requests is to open up an issue (if you have a list, one issue per feature, please) in the
        <a href="https://github.com/toggledbits/DeusExMachina/issues">GitHub repository</a>. 
	Second best is sending me a message via the MCV forums (I'm user `rigpapa`).
        </dd>
</dl>        

