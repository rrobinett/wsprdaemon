# Download the software with GIT

GitHub hosts the repository for all versions of WD.  Presently, the current master provides version 3.2.3.  The latest development version, 3.3.1, remains in a branch.  

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

WD provides lots of shell "aliases" to important and otherwise useful functions.  To have immediate access to these, run:
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

# To install ka9q-radio independently:

ka9q-radio has many uses outside its integrated role with WD. You can install and run it without WD.
Keep in mind that Rob checks out a particular version of ka9q-radio that he knows works with WD.  
So, if you use another version, you may find its interaction with WD problematic. YMMV.

For details of ka9q-radio installation, consult the docs sub-directory in the ka9q-radio created after performing a `git clone`.

[KA9Q_RADIO_GIT_URL](https://github.com/ka9q/ka9q-radio.git)
[KA9Q_FT8_GIT_URL](https://github.com/ka9q/ft8_lib.git)
[PSK_UPLOADER_GIT_URL](https://github.com/pjsg/ftlib-pskreporter.git)

## To install ka9q-web:

ka9q-web requires ka9q-radio of course, but also the web server package, onion, produced by David Moreno, so install it first.

[ONION_GIT_URL](https://github.com/davidmoreno/onion)

Use the following bash scripts as scripts or just as a guide to installation:

`declare ONION_LIBS_NEEDED="libgnutls28-dev libgcrypt20-dev cmake"
if [[ ${OS_RELEASE} =~ 24.04 ]]; then
    ONION_LIBS_NEEDED="${ONION_LIBS_NEEDED} libgnutls30t64 libgcrypt20"
fi

function build_onion() {
    local project_subdir=$1
    local project_logfile="${project_subdir}-build.log"

    wd_logger 2 "Building ${project_subdir}"
    (
    cd ${project_subdir}
    mkdir -p build
    cd build
    cmake -DONION_USE_PAM=false -DONION_USE_PNG=false -DONION_USE_JPEG=false -DONION_USE_XML2=false -DONION_USE_SYSTEMD=false -DONION_USE_SQLITE3=false -DONION_USE_REDIS=false -DONION_USE_GC=false -DONION_USE_TESTS=false -DONION_EXAMPLES=false -DONION_USE_BINDINGS_CPP=false ..
    make
    sudo make install
    sudo ldconfig
    )     >& ${project_logfile}
    rc=$?
    if [[ ${rc} -ne 0 ]]; then
         wd_logger 1 "ERROR: compile of '${project_subdir}' returned ${rc}:\n$( < ${project_logfile} )"
         exit 1
     fi
     wd_logger 2 "Done"
    return 0
}`

[KA9Q_WEB_GIT_URL](https://github.com/scottnewell/ka9q-web)

function build_ka9q_web() {
    local project_subdir=$1
    local project_logfile="${project_subdir}_build.log"

    wd_logger 2 "Building ${project_subdir}"
    (
    cd  ${project_subdir}
    make
    sudo make install
    ) >&  ${project_logfile}
    rc=$? ; if (( rc )); then
        wd_logger 1 "ERROR: compile of 'ka9q-web' returned ${rc}:\n$(< ${project_logfile})"
        exit 1
    fi
    wd_logger 2 "Done"
    return 0
}
