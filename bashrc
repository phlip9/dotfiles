# ~/.bashrc: executed by bash(1) for non-login shells.
# see /usr/share/doc/bash/examples/startup-files (in the package bash-doc)
# for examples

## INIT {{{

# If not running interactively, don't do anything
[ -z "$PS1" ] && return

# don't put duplicate lines in the history. See bash(1) for more options
# ... or force ignoredups and ignorespace
HISTCONTROL=ignoredups:ignorespace

# append to the history file, don't overwrite it
shopt -s histappend

# for setting history length see HISTSIZE and HISTFILESIZE in bash(1)
HISTSIZE=1000
HISTFILESIZE=2000

# check the window size after each command and, if necessary,
# update the values of LINES and COLUMNS.
shopt -s checkwinsize

# make less more friendly for non-text input files, see lesspipe(1)
[ -x /usr/bin/lesspipe ] && eval "$(SHELL=/bin/sh lesspipe)"

# use auto-complete after these words
complete -cf sudo
complete -cf man
complete -cf killall
complete -cf pkill

# set variable identifying the chroot you work in (used in the prompt below)
if [ -z "$debian_chroot" ] && [ -r /etc/debian_chroot ]; then
    debian_chroot=$(cat /etc/debian_chroot)
fi

# set a fancy prompt (non-color, unless we know we "want" color)
case "$TERM" in
    xterm-color) color_prompt=yes;;
esac

# uncomment for a colored prompt, if the terminal has the capability; turned
# off by default to not distract the user: the focus in a terminal window
# should be on the output of commands, not on the prompt
force_color_prompt=yes

if [ -n "$force_color_prompt" ]; then
    if [ -x /usr/bin/tput ] && tput setaf 1 >&/dev/null; then
	# We have color support; assume it's compliant with Ecma-48
	# (ISO/IEC-6429). (Lack of such support is extremely rare, and such
	# a case would tend to support setf rather than setaf.)
	color_prompt=yes
    else
	color_prompt=
    fi
fi

if [ "$color_prompt" = yes ]; then
    PS1='${debian_chroot:+($debian_chroot)}\[\033[01;32m\]\u@\h\[\033[00m\]:\[\033[01;34m\]\w\[\033[00m\]\$ '
else
    PS1='${debian_chroot:+($debian_chroot)}\u@\h:\w\$ '
fi
unset color_prompt force_color_prompt

# If this is an xterm set the title to user@host:dir
case "$TERM" in
xterm*|urxvt*)
    PS1="\[\e]0;${debian_chroot:+($debian_chroot)}\u@\h: \w\a\]$PS1"
    ;;
*)
    ;;
esac

# }}}

## ALIASES {{{

alias ls='ls --color=auto'

alias grep='grep --color=auto'
alias fgrep='fgrep --color=auto'
alias egrep='egrep --color=auto'

# some more ls aliases
alias ll='ls -alhF --color=auto'
alias la='ls -A --color=auto'
alias l='ls -CF --color=auto'

# annoying typos
alias ks='ls'
alias :q='quit'
alias cd..='cd ..'
alias cim='vim'
alias sl='ls'
alias shh='ssh'

# tmux 256 colors
alias tmux="TERM=screen-256color-bce tmux -2"

alias install='sudo apt-get install'
alias update='sudo apt-get update'
alias upgrade='sudo apt-get upgrade'

# pulseaudio sucks
alias restartpulse='sudo killall -9 pulseaudio; pulseaudio >/dev/null 2>&1 &'

# less with color
alias less='less -r'

# Add an "alert" alias for long running commands.  Use like so:
#   sleep 10; alert
alias alert='notify-send --urgency=low -i "$([ $? = 0 ] && echo terminal || echo error)" "$(history|tail -n1|sed -e '\''s/^\s*[0-9]\+\s*//;s/[;&|]\s*alert$//'\'')"'

# media nfs mount shortcut
alias phlipnfs='sudo mount -t nfs 192.168.0.43:/export/media ~/media'

# makes a directory and cd's into it
function mcd() {
    mkdir $@ && cd $_
}

function ssh-copy-key() {
    cat ~/.ssh/id_rsa.pub | ssh $@ 'cat >> ~/.ssh/authorized_keys'
}

# Alias definitions.
# You may want to put all your additions into a separate file like
# ~/.bash_aliases, instead of adding them here directly.
# See /usr/share/doc/bash-doc/examples in the bash-doc package.

if [ -f ~/.bash_aliases ]; then
    source ~/.bash_aliases
fi

## ALIASES }}}

## ENVIRONMENT VARIABLES {{{

export UTORRENT=$HOME/utorrent
export NLTK_DATA=$HOME/nltk_data
export TIDE_SDK=$HOME/.tidesdk/sdk/linux/1.3.1-beta

# Disable 'Couldn't connect to accessibility bus' error on opening gnome
# applications.
# http://askubuntu.com/questions/227515/terminal-warning-when-opening-a-file-in-gedit
export NO_AT_BRIDGE=1

# Java
export JAVA_HOME=/usr/lib/jvm/default-java
export CS61B_LIBS=$HOME/dev/cs61b/afx/lib
export CLASSPATH=/usr/local/lib:$JAVA_HOME/lib:$CS61B_LIBS
IDEA_BIN=$HOME/idea/bin
ECLIPSE=/opt/eclipse

# solarized .Xresources fix (http://askubuntu.com/questions/302736/solarized-color-name-not-defined)
export SYSRESOURCES=/etc/X11/Xresources
export USRRESOURCES=$HOME/.Xresources

# Python
THE_ONE_TRUE_PYTHON=/usr/bin/python3

# virtualenvwrapper
export WORKON_HOME=$HOME/.virtualenvs
export VIRTUALENVWRAPPER_PYTHON=$THE_ONE_TRUE_PYTHON
VIRTUALENV_WRAPPER=/usr/local/bin/virtualenvwrapper.sh

[ -f $VIRTUALENV_WRAPPER ] && source $VIRTUALENV_WRAPPER

# Anaconda3
ANACONDA_HOME=$HOME/anaconda3/bin

# Android
export ANDROID_HOME=$HOME/android
export ANDROID_NDK=$ANDROID_HOME/ndk
export ANDROID_STUDIO=$HOME/android-studio
ANDROID_PATH=$HOME/android/tools:$HOME/android/platform-tools:$ANDROID_STUDIO/bin

### Added by the Heroku Toolbelt
export HEROKU_TOOLBELT=/usr/local/heroku/bin

# Arduino
ARDUINO_SDK=$HOME/arduino-1.0.4

# Haskell
CABAL_BIN=$HOME/.cabal/bin

# Git submodule tools
GIT_SUBMODULE_TOOLS=$HOME/git-submodule-tools

# PATH
export PATH=$PATH:$HEROKU_TOOLBELT:$ANDROID_PATH:$ECLIPSE:$TIDE_SDK:$ARDUINO_SDK:$JAVA_HOME:$GIT_SUBMODULE_TOOLS:$CABAL_BIN:$IDEA_BIN:$ANACONDA_HOME

## SHELL VARIABLES }}}

## MISC {{{

# enable programmable completion features (you don't need to enable
# this, if it's already enabled in /etc/bash.bashrc and /etc/profile
# sources /etc/bash.bashrc).
if [ -f /etc/bash_completion ] && ! shopt -oq posix; then
    source /etc/bash_completion
fi

# bash vi editing mode
set -o vi

# Open tmux automatically
# If a session exists, just connect to it instead of creating a new one.
if [[ -z $TMUX ]]; then
    if [[ $(tmux ls 2>&1) =~ "no server running" ]]; then
        tmux
    else
        tmux attach
    fi
fi

## MISC }}}

# vim:foldmethod=marker
