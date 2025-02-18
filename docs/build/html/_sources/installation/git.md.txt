# Getting the software with GIT

## Clone wsprdaemon from github.com

From /home/wsprdaemon (or the installing user's home directory) [See Preparing the Installation](./preparation.md)
```
git clone https://github.com/rrobinett/wsprdaemon.git
cd wsprdaemon
```
Execute all further git commands in the /home/wsprdaemon/wsprdaemon directory.

Ensure you have the latest version:
```
git checkout master
git status
git log
```
Subsequently, to update from master (or from any branch of master), use:
```
git pull
```

To switch to a different branch, e.g., 3.2.0, use:
```
git checkout 3.2.0
git pull
```

wsprdaemon provides lots of "aliases" for important and otherwise useful functions.  To have immediate access to these, run:
```
source bash-aliases ../.bash_aliases
```

Having prepared and cloned the wsprdaemon software, now you can run it:

```
wd
```
This sets the stage and tells you to configure wsprdaemon.conf.
