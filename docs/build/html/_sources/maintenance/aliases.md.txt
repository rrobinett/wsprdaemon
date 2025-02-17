# Aliases for monitoring and interacting with wsprdaemon

source : wsprdaemon/bash-aliases on 18-04-2024

alias wd-k=wd-kill-uploader 
alias wdk=wd-kill-uploader 
alias wd-un=wd-watch-wsprnet-upload-log 
alias wdln=wd-watch-wsprnet-upload-log 
alias wd-gp='git push' 
alias wd-gl='git log | head -n 12' 
alias wd-rc='source ~/wsprdaemon/bash-aliases' ### Just reload this file 
alias wdrc='wd-rc' 
alias wdrci='wd-rci'

Reload the local bash aliases and funtions defined in its ~/.bash_aliases, which will include this file after 'rci' has been executed
alias wd-rcc='source ~/.bash_aliases' 
alias wd-rcc='wd-rcc'

Common usages of Linux commands
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
alias cdww='cd ~/wsprdaemon/wav-archive.d/' 
alias cdk='cd ~/wsprdaemon/ka9q-radio' 
alias cdt='cd /dev/shm/wsprdaemon' 
alias cdu='cd /dev/shm/wsprdaemon/uploads.d/'

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
alias gs='git status'

Get pub file for a copy/past to remote server's .ssh/authorized_keys file
alias catss='cat ~/.ssh/*pub'

Aliases which call WD
alias wd='~/wsprdaemon/wsprdaemon.sh' 
alias wdl='wd -l' 
alias wdle='wd -l e' 
alias wdld='wd -l d' 
alias wda='wd -a' 
alias wdz='wd -z' 
alias wds='wd -s' 
alias wdv='wd -V' 
alias wdd='wd -d' ### Increment the verbosity level of all running daemons in CWD 
alias wddd='wd -D' ### Decrement

alias wdgi='wd-grape-info'

alias wd-wav-archive='df -h ~ ; du -sh ~/wsprdaemon/wav-archive.d/ ; ls -lt ~/wsprdaemon/wav-archive.d/ | head -n 3; ls -lt ~/wsprdaemon/wav-archive.d/ | tail -n 2'

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

alias wdrl='wd-rl'

alias wd-ra='wd-radiod-action start' ### show it's status 
alias wdra='wd-ra'

alias wd-rz='wd-radiod-action stop' ### show it's status 
alias wdrz='wd-rz'

alias wd-rs='wd-radiod-action status' ### show it's status 
alias wdrs='wd-rs'

alias wdrv='wd-radiod-conf-edit'

WD systemctl
alias wd-wd-start='sudo systemctl start wsprdaemon.service' 
alias wdwa='wd-wd-start'

alias wd-wd-stop='sudo systemctl stop wsprdaemon.service' 
alias wdwz='wd-wd-stop'

alias wd-wd-status='sudo systemctl status wsprdaemon.service' 
alias wdws='wd-wd-status'

alias wd9c=wd-radiod-control 
alias wdrc=wd-radiod-control

alias wd9m=wd-9m

tmux aliases
alias tm='tmux' 
alias tml='tmux ls' 
alias tm0='tmux a -t 0' 
alias tm1='tmux a -t 1' 
alias tm2='tmux a -t 2' 
alias tm3='tmux a -t 3' 
alias tm4='tmux a -t 4' 
alias tm5='tmux a -t 5' 
alias tm6='tmux a -t 6' 
alias tm7='tmux a -t 7' 
alias tm8='tmux a -t 8' 
alias tm9='tmux a -t 9'

alias wd-wait='wd-wait-for_wspr-gap'

alias wd-nf="awk '{printf "%2d: %s\n", NF, $0}'"

git aliases
alias wd-get-my-public_ip="dig TXT +short o-o.myaddr.l.google.com @ns1.google.com | sed 's/"//g'"

alias wd-watch-wavs='watch "ls -lr *.wav"' ### watch for wd-record or kiwirecorder to create wav files in cwd 
alias wdww='wd-watch-wavs' 
alias wdps='ps aux | grep wd-record | grep -v grep'

alias wdssr=wd-ssh-to-wdclient

Reloads these functions and aliases into the users running bash (must be an alias)
alias wd-bash_aliases='source ~/wsprdaemon/bash-aliases' 
alias wdba='wd-bash_aliases'

alias wd-='wd-help' 
alias wd-h='wd-help'

alias wdg='wd -g'
