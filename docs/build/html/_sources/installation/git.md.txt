# Download the software with GIT

GitHub provides the repository for all versions of wsprdaemon.  Presently, the current master provides version 3.2.3.  The latest version 3.3.1 remains in a development branch.  

## Clone wsprdaemon from github.com

From /home/wsprdaemon (or the installing user's home directory) [See Preparing the Installation](./preparation.md)
```
git clone https://github.com/rrobinett/wsprdaemon.git
cd wsprdaemon
```
Execute all further git commands in the /home/wsprdaemon/wsprdaemon directory.

Ensure you have the latest stable version:
```
git checkout master
git status
git log
```

Subsequently, to apply any updates of the latest version, use:
```
git pull
```

To switch to a different branch, e.g., 3.3.1, use:
```
git checkout 3.3.1
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

This sets the stage and prompts you to configure your setup:
- [wsprdaemon configuration](../configuration/wd_conf.md)
- [radiod configuration](../configuration/radiod_conf.md)
- KiwiSDR
