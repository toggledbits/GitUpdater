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

To determine if an update is available, the plugin should load GitUpdater and call checkForUpdates().

```GitUpdater = require("GitUpdater")
lastVersionId = luup.variable_get( myServiceId, "GitHubReleaseId", myDeviceNum )
canUpdate, updateInfo = GitUpdater.checkForUpdates( "githubuser", "reponame", lastVersionId, lastVersionId == nil )
```

Immediately or at some point later, the plugin can then call for the update to occur, using the information
passed back by the prior call to checkForUpdates().

```if canUpdate then
    local success, newId = GitUpdater.doUpdate( "githubuser", "reponame", updateInfo )
    if success then
        luup.variable_set( myServiceId, "GitHubReleaseId", myDeviceNum )
        luup.reload()
    end
end
'''

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

Line 6 determines if the doUpdate() call was successful, and if so...

Line 7 stores the release ID returned by doUpdate().

Line 8 restarts Luup. This is an important step after a successful update, as the new plugin code will not be running
until Luup reloads.

Lines 9 and 10 finish off the conditionals on lines 6 and 4, respectively.

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

## Additional Considerations for Developers ##

The checkForUpdates() and doUpdate() calls have been coded as separate functions because it may
be the case that a develop would want to make a user aware of an update, but defer the update until
a later time and/or after the user approves it. 

Developers should not check for updates frequently, as in most cases, updates will be rare. However, since this
is effectively a polling interface to GitHub, it has to be called with sufficient frequency to meet the expectations
of both the developer and user with regard to timeliness of updates once published. For this, once or twice a day
is probably sufficient. The author would consider a frequency of once every four hours the limit, and anything more
frequent is excessive.

Making the check during the startup call to the plugin implementation seems useful. In practice, Luup reloads fairly
frequently, so this approach may give a reasonable frequency to updates without addition coding necessary for timed
checks. It also allows user to cause update checks, as Luup reloads are easily initiated by the user from the Vera
dashboard.

## Reporting Bugs/Enhancement Requests ##

Bug reports and enhancement requests are welcome! Please use the "Issues" link for the repository to open a new bug report or make an enhancement request.

## License ##

GitUpdater is offered under GPL (the GNU Public License). See the file LICENSE.
