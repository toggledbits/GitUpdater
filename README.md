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

GitUpdater uses the GitHub API version 3. Authnetication is not required for the operations
it performs under its current implementation--they can all be done through open, public
queries as long as the source repository is public.

## History ##

Vera home automation controllers have a "plugin store" where users can find and install published, approved plugins.
However, the infrastructure of this store seems to have frozen in time sometime a few years
ago. The current store, associated with an earlier version of Vera firmware, has not been updated to
keep pace with current firmware versions. Newer firmware still use the old store, but plugin developers
must continue to use the antiquated interface and its painful workflow to publish and update
their work. The process of uploading plugin files takes many steps, and in particular for updating
existing plugins, is very error prone in ways that can leave no indication that an error has been made.

Worse, apparently Vera rarely looks at the old store these days (even though all of their customers rely on it), 
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

To determine if an update is available, the plugin should load GitUpdater and call checkForUpdate().

The most basic form looks something like this:

```
ok,GitUpdater = pcall( require, "GitUpdater" )
if ok then
	-- GitUpdater is installed/available. Get last version installed
	lastVersionInfo = luup.variable_get( yourServiceId, "GUReleaseInfo", myDeviceNum ) or "0"
	if lastVersionInfo == "0" then lastVersionInfo = GitUpdater.MASTER_RELEASES end
	ok, canUpdate, updateInfo = pcall( GitUpdater.checkForUpdate,
		"githubuser", "reponame", lastVersionInfo, lastVersionInfo == GitUpdater.MASTER_RELEASES )
	if not ok then
		-- There was an error, and canUpdate will contain the error message
	end
	-- No error, canUpdate is boolean true if update available, false otherwise; updateInfo is data
	-- to pass to doUpdate() below
else
	-- GitUpdater is not installed. Do what you must.
end
```

Note that we make use of `pcall()`. This calls the named function, but does not stop Lua execution if an error occurs. This is a very defensive style of programming that will prevent any errors that occur in GitUpdater from stopping your plugin's operation.

Also note that the first time (ever) that this code is run, the `luup.variable_get()` will return `nil` because the state variable is not defined. The code shown above converts `nil` to "0" via the `or` clause. If the result string is "0", the next line changes the value to `GitUpdate.MASTER_RELEASES`, which is a GitUpdater constant that tells it to source updates from releases made on the Github "master" branch. The value is then passed as the third argument to `checkForUpdate()`. The fourth argument is a boolean that is *true* (only) when the GitUpdater constant is being sent. In all, the first run of `checkForUpdate()` will return update info for the highest release in the master branch. Later, when `doUpdate()` is called, that will be installed, and the `GUReleaseInfo` state variable will be rewritten with a new value to mark that that release has been installed. From there, future trips through the above code will simply pass whatever release information that state variable contains, so updates will only be flagged necessary when a new release, higher than the installed version, is detected in the Github repository.

The `checkForUpdate()` call returns two values. If the first value is `nil`, an error has occured and the error message is returned in the second value. Otherwise, the first value is a boolean indicating whether or not an update exists in the repository. If the first value is boolean *false*, then no update is pending, and the second value is `nil`. If the first value is boolean *true*, then the second value contains a table that will tell `doUpdate()` what it needs to install, so you'll need to pass that structure to `doUpdate()` at some point.

```
if GitUpdater and canUpdate then
    local ok, newInfo, errMessage = pcall( GitUpdater.doUpdate, updateInfo )
	if not ok then
		-- An error occurred, newInfo contains error message
	elseif newInfo then
        -- Update succeeded. Store the new revision reference in our state variable (same name used above)
        luup.variable_set( yourServiceId, "GUReleaseInfo", newInfo, myDeviceNum )
        -- Reload Luup to make the plugin changes take effect.
        luup.log("Plugin updated; reloading luup", 2) -- it's good form to log reason when reloading Luup
        luup.reload()
    end
end
```

Now, if there is an update pending, we pass back the second value returned by `checkForUpdate()` as the sole argument to `doUpdate()`, and it installs the revision found. If the process succeeds, `doUpdate()` returns an encoded string that should be stored and passed to future calls to `checkForUpdate()`. This creates a continuum of updates, so `checkForUpdate()` can know what the last installed version was, and correctly determine is anything newer is available. **You must store the return value of `doUpdate()` and pass it back in future calls to `checkForUpdate()`.

### Update "Channels" ###

The example/walk-through above sets up your plugin to update from releases made on the Github "master" branch (not *commits*, *releases*--there's a difference!).

GitUpdater can update from either releases or head commits on any branch; which is determined by calling `getReleaseChannel()` or `getHeadChannel`, respectively, passing the name of the branch to check. For example, to update from head commits on the "stable" branch, we would change the code before the `checkForUpdate()` call above to look something like this:

```
	lastVersionInfo = luup.variable_get( yourServiceId, "GUReleaseInfo", myDeviceNum ) or "0"
	local forceUpdate = false
	if lastVersionInfo == "0" then 
		lastVersionInfo = getHeadChannel( "stable" ) -- or whatever branch you want
		forceUpdate = true
	end
	ok, canUpdate, updateInfo = pcall( GitUpdater.checkForUpdate, "githubuser", "reponame", lastVersionId, forceUpdate )
```

If GitUpdater has previously run with another channel, then you must also set the state variable value to "0" to get a correct reinitialization and switch-over to the branch channel.

Likewise, would could then later to the release channel by putting back the original code from above, and settings the state variable value to "0" to force the switch-over.

### Handling the GitHub Side ###

The GitHub dependencies are basic. First, the plugin's repository has to be public. Updates for the plugins are then
created by using GitHub's release mechanism. Any release that is (1) not marked as a draft, and (2) not marked as a
pre-release becomes an eligible update. The release tag is used to identify the version, although this is strictly
visual and is not parsed or given any significance by GitUpdater. When comparing releases, only the publish date matters.

GitUpdater in its current form will always update to the newest eligible release. That means that if more than
one release on GitHub occurs between checks by GitUpdater, it will skip those interim releases and go directly to the 
most recent. Developers should be aware of this, and avoid creating dependencies in the upgrade tasks a plugin may perform
on the immediately prior release (that is, plugins should be coded so that they can always go from version 1.0 to 2.0 without
needing 1.2 or 1.5 installed first).

Typical GitHub repositories also include files that are not really part of the plugin itself, such as a README.md file, a LICENSE
file, and maybe a change log or list of future plans/to-do's. In order to avoid GitUpdater installing these files on the Vera
as if they are part of the plugin source, provide a file called <tt>.guignore</tt> in the same directory as the device file(s)
(D_xxx.xml) with the names of any files that should <em>not</em> be installed in <tt>/etc/cmh-ludl/</tt>. GitUpdater will skip
these listed files. Whether or not a <tt>.guignore</tt> file is provided, GitUpdater will always ignore the following files:
<tt>.guignore, README.md, LICENSE</tt>.

### Self-Updating GitUpdater ###

To update GitUpdater, call `selfUpdate()`. If this function returns `true`, then GitUpdater updated itself
and should be reloaded. The following code fragment shows a self-update update process with a module reload
that does not require a Luup reload:

```
gu = require "GitUpdater"

if gu.selfUpdate() then
	-- Make the loader think we're not loaded
	package.loaded.GitUpdater = nil
	-- Reload
	gu = require "GitUpdater"
end
...etc...
```

Of course, in practice, you want to guard the `require` and call to `selfUpdate()` using `pcall()`, as shown in the other examples. It has been omitted here only for clarity, but its use is always recommended.

## Additional Considerations for Developers ##

### Timing and Frequency of Updates ###

The `checkForUpdate()` and `doUpdate()` calls have been coded as separate functions because it may
be the case that a developer would want to make a user aware of an update, but defer the update until
a later time and/or after the user approves it. 

Developers should not check for updates too frequently, as in most cases, updates will be rare. However, since this
is effectively a polling interface to GitHub, it has to be called with sufficient frequency to meet the expectations
of both the developer and user with regard to timeliness of updates published. For this, once or twice a day
is probably sufficient. The author considers a frequency of once every four hours to be the high limit, and anything more
frequent is excessive.

### Skipping Files: .guignore

The file `.guignore`, if present in your repository, may contain a list of patterns that match files that should *not* be installed, one per line. These are Lua patterns, and they are matched against filenames only, not subdirectory names, as of this writing.

### Side-Effects ###

Vera maintains versions of plugin code in its store (using svn or cvs?), and maintains an agreement between its version
and an installed version. Directly changing the installed code on the Vera as I am currently doing in GitUpdater has no
effect on the installed version number of the plugin shown, so even though the plugin may be getting updates, neither the Vera
not the Vera Store are aware of any updates. This is probably OK for a while, but could leave to confusion on the part of the user.

As a recommended hedge against such confusion, developers can (should) periodically push their latest, stable release
from their GitHub repository into the Vera Store. Eventually, remote Veras will be updated through the Vera store, although
that update will effectively install the same code that GitUpdater has already installed. Thus, this update merely updates
Vera's idea of the version number, and a peaceful coexistence between the two systems should prevail. Of course, this
makes the inconvenience of updating through the Vera store an ongoing necessity, but it can be done with much lower frequency,
and the benefit GitUpdater provides of faster updates when hotfixes or interim releases are published is still realized.

Conversely, it is theoretically possible that the Vera store could be used to publish the first, base version of the plugin,
and no updates are ever subsequently published to the store by the developer, leaving all updates to be done through GitUpdater. 
This gives the developer the exposure, and users ease of installation, that the Vera store can offer, while relieving the 
developer of any further trials in managing updates through the store.

Taking this notion to the extreme, it is possible that the first, base version of any plugin could simply be a minimal template
implementation that does nothing more than call GitUpdater to get and install the latest code from GitHub. The plugin is 
effectively loading a "bootloader" from the Vera store, leaving GitUpdater to bring in the rest of the code on the first run.

Of course, it should go without saying that Vera could change the way plugins are installed, change file or directory permissions, or make
other system changes that would render GitUpdater unable to perform its work. At the moment, however, it seems that Vera has much
greater interests in other areas than what is going on in their plugin community.

### Encrypted Plugin Files ###

Currently, GitUpdater does not handle encryption of plugin files.

## Reference

### `checkForUpdate( githubUser, githubRepo, updateInfo [, forceUpdate ] )`

The optional `forceUpdate` parameter causes `checkForUpdate()` to set up for `doUpdate()` to install the highest matching revision in the channel, regardless of what revision is currently installed. This is normally only used when switching channels.

```
local GitUpdater = pcall( require, "GitUpdater" )

...

-- Check for update to plugin; install if available.
if GitUpdater then
	-- Fetch updateInfo from wherever we last stored it...
	local updateInfo = ...
	-- Pass it to checkForUpdate()
	local status, checkInfo = pcall( GitUpdater.checkForUpdate, "user", "repo", updateInfo )
	if status == nil then
		-- Error occurred
		luup.log("GitUpdater threw an error checking for updates: "..tostring(checkInfo), 2)
	elseif status == false then
		-- No updates are pending
	else
		-- An update is pending. Install it now.
		status, updateInfo = pcall( GitUpdater.doUpdate, checkInfo )
		if not status then
			luup.log("GitUpdater failed to install the available update: "..tostring(updateInfo), 2)
		else
			-- Successful install. Store updateInfo somewhere...
			...
			--- And reload Luup
			luup.reload()
		end
	end
end
```

### `doUpdate( checkInfo )`

This function installs an update using information returned by `checkForUpdate()`. It returns a single value, which should be stored (e.g. in a state variable) and passed back to future calls to `checkForUpdate()`, so that it knows what the last version installed was and can determine if a newer version is eligible.

Calls to `doUpdate()` should be made through `pcall()`, as it throws errors for any problem is has in its operation. When using `pcall()`, then, the return value of the first return value will be `nil` if there is an error, and a second return value will be passed containing the error message.

```
local updateInfo,errMessage = doUpdate( checkInfo )
if not updateInfo then -- simple test OK in this case
	print("An error occurred: "..tostring(errMessage))
else
	-- Successful update. Store updateInfo somewhere for later checkForUpdate() calls
	...
	-- And reload Luup to make the changes take effect
	luup.reload()
end
```

### `MASTER_RELEASES`

This constant can be passed as the `updateInfo` parameter to `checkForUpdate()` to source updates from *releases* made from the "master" branch. This is the default source/channel.

### `getReleaseChannel( branchName )`

This function returns an `updateInfo` table that draws update information from *releases* on the supplied branch name, or "master" if the branch name is not supplied.

The result value of this call is normally only used once, the first time `checkForUpdate()` is called in a new installation (or upon switching channels). It is recommended that the `forceUpdate` argument to `checkForUpdate()` also be passed *true* in this case. Thereafter, the value of whatever `doUpdate()` returns should be used (and `forceUpdate` not provided or *false*).

### `getHeadChannel( branchName )`

This function returns an `updateInfo` table that tells `checkForUpdate()` to watch the HEAD of the named branch ("master" by default). Any commit on the branch is considered an update eligible to be installed. 

A common usage of this is to have a "stable" branch that publishes lightly-tested development releases that are believed to be stable. Following this branch, users can ride your "bleeding edge" of new work without riding what is perhaps the "hemorraging edge" of a direct development branch, which may contain completely untested code and work in progress that would often break users.

The result value of this call is normally only used once, the first time `checkForUpdate()` is called in a new installation (or upon switching channels). It is recommended that the `forceUpdate` argument to `checkForUpdate()` also be passed *true* in this case. Thereafter, the value of whatever `doUpdate()` returns should be used (and `forceUpdate` not provided or *false*).

## Reporting Bugs/Enhancement Requests ##

Bug reports and enhancement requests are welcome! Please use the "Issues" link for the repository to open a new bug report or make an enhancement request.

## License ##

GitUpdater is offered under GPL (the GNU Public License). See the file LICENSE.
