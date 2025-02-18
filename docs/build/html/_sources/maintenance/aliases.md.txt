# Aliases for monitoring and interacting with wsprdaemon

These aliases (in ~wsprdaemon/bash-aliases) can provide very useful functions with a few keystrokes.  The documentation for what they do remains minimal.  Also, take note that some of them will only work in a particular directory.

## Latest Aliases from branch 3.3.1

### This file ~/wsprdaemon/bash-aliases  includes functions and aliases which are helpful in running and debugging WD systems
alias wdtw="test_get_wav_file_list"
### Each element containsa the function name, a comma-seperated list of its aliases, and a description of it
    local alias_name_field_width=${#WD_BASH_HELP_HEADER_LINE_LIST[1]}
        local alias_names="${help_string_list[1]}"
        if [[ ${#alias_names} -gt ${alias_name_field_width} ]]; then
            alias_name_field_width=${#alias_names}
    printf "%${function_name_field_width}s  %${alias_name_field_width}s  %s\n" \
        local alias_names="${help_string_list[1]}"
        printf "%${function_name_field_width}s  %${alias_name_field_width}s  %s\n" "${function_name}" "${alias_names}" "${description_string}"
alias wd-k=wd-kill-uploader
alias wdk=wd-kill-uploader
alias wd-un=wd-watch-wsprnet-upload-log
alias wdln=wd-watch-wsprnet-upload-log
alias wd-gp='git push'
alias wd-gl='git log | head -n 12'
### Add sourcing this file to ~/.bash_aliases so that these bash aliases and functions are defined in every bash session
    if [[ ! -f ~/.bash_aliases ]] || ! grep '/bash-aliases' ~/.bash_aliases > /dev/null ; then
if [[ -f ~/wsprdaemon/bash-aliases ]]; then
    source ~/wsprdaemon/bash-aliases
" >> ~/.bash_aliases
         echo "A reference to '~/wsprdaemon/bash-aliases' has been added to ' ~/.bash_aliases'"
         [[ ${verbosity-0} -gt 1 ]] && echo "bash-aliases has already been installed in ~/.bash_aliases"
alias wdrci='wd-rci'
### Reload the local bash aliases and funtions defined in its ~/.bash_aliases, which will include this file after 'rci' has been executed
alias wd-rcc='source ~/.bash_aliases'
alias wd-rcc='wd-rcc'
alias l='ls -CF'
alias ll='ls -l'
alias lrt='ls -lrt'
alias la='ls -A'
alias pd=pushd
alias d=dirs
alias ag='alias | grep'
alias h=history
alias hg='history | grep'
alias j=jobs
alias cdw='cd ~/wsprdaemon/'
alias cdk='cd ~/wsprdaemon/ka9q-radio'
alias cdr='cd /etc/radio'
alias cdrf='cd /run/ft8'
alias cds='cd /etc/systemd/system'
alias cdt='cd /dev/shm/wsprdaemon'
alias cdu='cd /dev/shm/wsprdaemon/uploads.d/'
alias cdww='cd ~/wsprdaemon/wav-archive.d/'
alias vib='vi ~/wsprdaemon/bash-aliases'
alias vibb='vi ~/.bash_aliases'
alias viw='vi ~/wsprdaemon/wsprdaemon.sh'
alias vic='vi ~/wsprdaemon/wsprdaemon.conf'
alias vir='vi ~/wsprdaemon/radiod@rx888-wsprdaemon.conf'
alias virr='vi /etc/radio/radiod@rx888-wsprdaemon.conf'
alias tf='tail -F -n 40'
alias tfd='tf decoding_daemon.log'
alias tfr='tf wav_recording_daemon.log'
alias tfw='tf ~/wsprdaemon/watchdog_daemon.log'
alias g='git'
alias gc='git commit'
alias gd='git diff'
alias gs='git status | grep -B 100 "Untracked files"'
alias gl='git log | head'
alias catss='cat ~/.ssh/*pub'
    scp -p ~/.vimrc ~/.bash_aliases ${remote_ip}:
alias wd='~/wsprdaemon/wsprdaemon.sh'
alias wdl='wd -l'
alias wdle='wd -l e'
alias wdld='wd -l d'
alias wda='wd -a'       ### Instruct systemctl to if needed install and configure WD as a service, and then run 'systemctl start wsprdaemon'
alias WDA='wd -A'       ### Start WD from this terminal session so stderr messages go to this terminal.  This is how I run WD when debugging
alias wdz='wd-killall'  ### Quickly stops all WD-associated services and kills all WD daemons and zombies
alias wds='wd -s'
alias wdv='wd -V'
alias wdvv='(cd ~/wsprdaemon; echo "$(git symbolic-ref --short HEAD 2>/dev/null)-$(git rev-list --count HEAD)" )'
alias wdd='wd -d'       ### Increment the verbosity level of all running daemons in CWD
alias wddd='wd -D'      ### Decrement
alias wdgi='wd-grape-info'
alias wd-wav-archive='df -h ~ ; du -sh ~/wsprdaemon/wav-archive.d/ ; ls -lt ~/wsprdaemon/wav-archive.d/ | head  -n 3; ls -lt ~/wsprdaemon/wav-archive.d/ | tail -n 2'
alias wdwaf=wd-wav-archive-fix
alias wdssp=wd-ssh-psws
alias wd-ov='wd-overloads'
alias wdov='wd-ov'
alias wd-q='wd-query'
alias wdq='wd-query'
alias wd-syslog='sudo tail -F /var/log/syslog'
alias wd-syslogl='sudo less /var/log/syslog'
alias wdsl='wd-syslog'
alias wd-wd-rec='watch "ps aux | grep wd-rec | grep -v grep | sort -k 14,14n -k 15r"'
alias wdwd='wd-wd-rec'
#alias wd-rl='sudo journalctl -u radiod@rx888-wsprdaemon.service'     ### show the syslog entries for the radiod service.  add -f to watch new log lines appear
alias wdrl='wd-rl'
alias wd-ra='wd-radiod-action start'  ### show it's status
alias wdra='wd-ra'
alias wd-rz='wd-radiod-action stop'  ### show it's status
alias wdrz='wd-rz'
alias wd-rs='wd-radiod-action status'  ### show it's status
alias wdrs='wd-rs'
alias wdrv='wd-radiod-conf-edit'
alias wd-ss='sudo systemctl'
alias wdss=wd-ss
alias wd-wd-start='sudo systemctl start wsprdaemon.service'
alias wdwa='wd-wd-start'
alias wd-wd-stop='sudo systemctl stop wsprdaemon.service'
alias wdwz='wd-wd-stop'
alias wd-wd-status='sudo systemctl status wsprdaemon.service'
alias wdws='wd-wd-status'
alias wd9c=wd-radiod-control
alias wdrc=wd-radiod-control
alias wdrg='wd-rc-gain'
alias wd9m=wd-9m
### tmux alias
alias wd-wait='wd-wait-for_wspr-gap'
alias wd-nf="awk '{printf \"%2d: %s\n\", NF, \$0}'"
### git aliases
alias wd-get-my-public_ip="dig TXT +short o-o.myaddr.l.google.com @ns1.google.com | sed 's/\"//g'"
alias wd-watch-wavs >& /dev/null && unalias wd-watch-wavs
alias wdww='wd-watch-wavs'
alias wdps='ps aux | grep "wd-record\|pcmrecord" | grep -v grep'
alias wdssr=wd-ssh-to-wdclient
###  Reloads these functions and aliases into the users running bash (must be an alias)
alias wd-bash_aliases='source ~/wsprdaemon/bash-aliases'
alias wdba='wd-bash_aliases'
alias wd-='wd-help'
alias wd-h='wd-help'
alias wdg='wd -g'

---

### Aliases from 3.2.3 circa 18-04-2024

- alias wd-k=wd-kill-uploader 
- alias wdk=wd-kill-uploader 
- alias wd-un=wd-watch-wsprnet-upload-log 
- alias wdln=wd-watch-wsprnet-upload-log 
- alias wd-gp='git push' 
- alias wd-gl='git log | head -n 12' 
- alias wd-rc='source ~/wsprdaemon/bash-aliases' ### Just reload this file 
- alias wdrc='wd-rc' 
- alias wdrci='wd-rci'

### Reload the local bash aliases and funtions defined in its ~/.bash_aliases, which will include this file after 'rci' has been executed
- alias wd-rcc='source ~/.bash_aliases' 
- alias wd-rcc='wd-rcc'

### Common usages of Linux commands
- alias l='ls -CF' 
- alias ll='ls -l' 
- alias lrt='ls -lrt' 
- alias la='ls -A' 
- alias pd=pushd 
- alias d=dirs 
- alias ag='alias | grep' 
- alias h=history 
- alias hg='history | grep' 
- alias j=jobs 
- alias cdw='cd ~/wsprdaemon/' 
- alias cdww='cd ~/wsprdaemon/wav-archive.d/' 
- alias cdk='cd ~/wsprdaemon/ka9q-radio' 
- alias cdt='cd /dev/shm/wsprdaemon' 
- alias cdu='cd /dev/shm/wsprdaemon/uploads.d/'

- alias vib='vi ~/wsprdaemon/bash-aliases' 
- alias vibb='vi ~/.bash_aliases' 
- alias viw='vi ~/wsprdaemon/wsprdaemon.sh' 
- alias vic='vi ~/wsprdaemon/wsprdaemon.conf' 
- alias vir='vi ~/wsprdaemon/radiod@rx888-wsprdaemon.conf' 
- alias virr='vi /etc/radio/radiod@rx888-wsprdaemon.conf'

- alias tf='tail -F -n 40' 
- alias tfd='tf decoding_daemon.log' 
- alias tfr='tf wav_recording_daemon.log' 
- alias tfw='tf ~/wsprdaemon/watchdog_daemon.log'

- alias g='git' 
- alias gc='git commit' 
- alias gd='git diff' 
- alias gs='git status'

### Get pub file for a copy/past to remote server's .ssh/authorized_keys file
- alias catss='cat ~/.ssh/*pub'

### Aliases which call WD
- alias wd='~/wsprdaemon/wsprdaemon.sh' 
- alias wdl='wd -l' 
- alias wdle='wd -l e' 
- alias wdld='wd -l d' 
- alias wda='wd -a' 
- alias wdz='wd -z' 
- alias wds='wd -s' 
- alias wdv='wd -V' 
- alias wdd='wd -d' ### Increment the verbosity level of all running daemons in CWD 
- alias wddd='wd -D' ### Decrement

- alias wdgi='wd-grape-info'

- alias wd-wav-archive='df -h ~ ; du -sh ~/wsprdaemon/wav-archive.d/ ; ls -lt ~/wsprdaemon/wav-archive.d/ | head -n 3; ls -lt ~/wsprdaemon/wav-archive.d/ | tail -n 2'

- alias wdwaf=wd-wav-archive-fix

- alias wdssp=wd-ssh-psws

- alias wd-ov='wd-overloads' 
- alias wdov='wd-ov'

- alias wd-q='wd-query' 
- alias wdq='wd-query'

- alias wd-syslog='sudo tail -F /var/log/syslog' 
- alias wd-syslogl='sudo less /var/log/syslog' 
- alias wdsl='wd-syslog' 
- alias wd-wd-rec='watch "ps aux | grep wd-rec | grep -v grep | sort -k 14,14n -k 15r"' 
- alias wdwd='wd-wd-rec'

- alias wdrl='wd-rl'

- alias wd-ra='wd-radiod-action start' ### show it's status 
- alias wdra='wd-ra'

- alias wd-rz='wd-radiod-action stop' ### show it's status 
- alias wdrz='wd-rz'

- alias wd-rs='wd-radiod-action status' ### show it's status 
- alias wdrs='wd-rs'

- alias wdrv='wd-radiod-conf-edit'

### WD systemctl
- alias wd-wd-start='sudo systemctl start wsprdaemon.service' 
- alias wdwa='wd-wd-start'

- alias wd-wd-stop='sudo systemctl stop wsprdaemon.service' 
- alias wdwz='wd-wd-stop'

- alias wd-wd-status='sudo systemctl status wsprdaemon.service' 
- alias wdws='wd-wd-status'

- alias wd9c=wd-radiod-control 
- alias wdrc=wd-radiod-control

- alias wd9m=wd-9m

### tmux aliases
- alias tm='tmux' 
- alias tml='tmux ls' 
- alias tm0='tmux a -t 0' 
- alias tm1='tmux a -t 1' 
- alias tm2='tmux a -t 2' 
- alias tm3='tmux a -t 3' 
- alias tm4='tmux a -t 4' 
- alias tm5='tmux a -t 5' 
- alias tm6='tmux a -t 6' 
- alias tm7='tmux a -t 7' 
- alias tm8='tmux a -t 8' 
- alias tm9='tmux a -t 9'

- alias wd-wait='wd-wait-for_wspr-gap'

- alias wd-nf="awk '{printf "%2d: %s\n", NF, $0}'"

### git aliases
- alias wd-get-my-public_ip="dig TXT +short o-o.myaddr.l.google.com @ns1.google.com | sed 's/"//g'"

- alias wd-watch-wavs='watch "ls -lr *.wav"' ### watch for wd-record or kiwirecorder to create wav files in cwd 
- alias wdww='wd-watch-wavs' 
- alias wdps='ps aux | grep wd-record | grep -v grep'

- alias wdssr=wd-ssh-to-wdclient

### Reloads these functions and aliases into the users running bash (must be an alias)
- alias wd-bash_aliases='source ~/wsprdaemon/bash-aliases' 
- alias wdba='wd-bash_aliases'

- alias wd-='wd-help' 
- alias wd-h='wd-help'

- alias wdg='wd -g'
