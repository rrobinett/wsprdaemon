# Getting the software with GIT

### clone wsprdaemon from github.com

```
git clone https://github.com/rrobinett/wsprdaemon.git
cd wsprdaemon
```
Execute all git commands in the /home/wsprdaemon/wsprdaemon directory.

Ensure you have the latest version:
```
git checkout master
git status
git log
```
Subsequently, to update a given branch, use:
```
git pull
```

To switch to a different branch, e.g., 3.2.0, use:
```
git checkout 3.2.0
git pull
```

Ensure regular loading of all the wd aliases:
```
source bash-aliases ../.bash_aliases
```
