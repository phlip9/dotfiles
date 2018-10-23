# ~/.bashrc: executed by bash(1) for non-login shells.
# see /usr/share/doc/bash/examples/startup-files (in the package bash-doc)
# for examples

## INIT {{{

# If not running interactively, don't do anything
[ -z "$PS1" ] && return

# Source global definitions
if [ -f /etc/bashrc ]; then
  source /etc/bashrc
fi

# Source Facebook definitions
if [ -f /usr/facebook/ops/rc/master.bashrc ]; then
  source /usr/facebook/ops/rc/master.bashrc
fi

# OS detection to make this bashrc *hopefully* cross-compatible
OS="UNKNOWN"
case "$OSTYPE" in
    linux*)  OS="LINUX" ;;
    darwin*) OS="OSX" ;;
    msys*)   OS="WIN" ;;
    cygwin*) OS="WIN" ;;
    win32*)  OS="WIN" ;;
    *)       echo "Uknown OS: $OSTYPE" ;;
esac

FB_DEVVM_RE="^devvm[0-9]+.*facebook\.com$"
if [[ $(uname --nodename) =~ $FB_DEVVM_RE ]]; then
    IS_FB_DEVVM=true
else
    IS_DB_DEVVM=false
fi

# Share history state across terminals
# Following: https://cdaddr.com/programming/keeping-bash-history-in-sync-on-disk-and-between-multiple-terminals/

# append to the history file, don't overwrite it
shopt -s histappend

# for setting history length see HISTSIZE and HISTFILESIZE in bash(1)
HISTSIZE=50000
HISTFILESIZE=1048576

# don't put duplicate lines in the history. See bash(1) for more options
# ... or force ignoredups and ignorespace
HISTCONTROL=ignoredups:ignorespace

# append the current history to ~/.bash_history and reload other terminal
# instances' history at every new bash prompt
export PROMPT_COMMAND="history -a; history -n"

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

if [ "$OS" == "LINUX" ]; then
    alias ls='ls --color=auto'

    alias grep='grep --color=auto'
    alias fgrep='fgrep --color=auto'
    alias egrep='egrep --color=auto'

    # some more ls aliases
    alias ll='ls -alhF --color=auto'
    alias la='ls -A --color=auto'
    alias l='ls -CF --color=auto'
elif [ "$OS" == "OSX" ]; then
    # some more ls aliases
    alias ll='ls -alhF'
    alias la='ls -A'
    alias l='ls -CF'
fi

# annoying typos
alias ks='ls'
alias :q='quit'
alias cd..='cd ..'
alias cim='vim'
alias sl='ls'
alias shh='ssh'

# tmux 256 colors
alias tmux="TERM=screen-256color tmux -2"

if [ "$OS" == "LINUX" ]; then
    alias install='sudo apt-get install'
    alias update='sudo apt-get update'
    alias upgrade='sudo apt-get upgrade'

    # pulseaudio sucks
    alias restartpulse='sudo killall -9 pulseaudio; pulseaudio >/dev/null 2>&1 &'

    # Add an "alert" alias for long running commands.  Use like so:
    #   sleep 10; alert
    alias alert='notify-send --urgency=low -i "$([ $? = 0 ] && echo terminal || echo error)" "$(history|tail -n1|sed -e '\''s/^\s*[0-9]\+\s*//;s/[;&|]\s*alert$//'\'')"'
fi

# less with color
alias less='less -r'

# latexmk alias
alias lmk='latexmk -pdf -pvc -shell-escape'

# makes a directory and cd's into it
function mcd() {
    mkdir "$@" && cd "$_" || exit
}

# pyvenv helpers

function mkvenv() {
    echo "Creating new python virtual env at '$PYTHON3_ENV_DIR/$1'"
    pyvenv "$PYTHON3_ENV_DIR/$1"
}

function lsvenv() {
    ls "$PYTHON3_ENV_DIR"
}

function rmvenv() {
    echo "Deleting python virtual env '$PYTHON3_ENV_DIR/$1'"
    rm -rf "${PYTHON3_ENV_DIR:?}/$1"
}

function workon() {
    echo "Entering python virtual env '$1'. Use 'deactivate' to exit"
    source "$PYTHON3_ENV_DIR/$1/bin/activate"
}


# Alias definitions.
# You may want to put all your additions into a separate file like
# ~/.bash_aliases, instead of adding them here directly.
# See /usr/share/doc/bash-doc/examples in the bash-doc package.

if [ -f "$HOME/.bash_aliases" ]; then
    source "$HOME/.bash_aliases"
fi

## ALIASES }}}

## ENVIRONMENT VARIABLES {{{

export XDG_CONFIG_HOME=$HOME/.config

# Facebook devserver proxy
if [ "$IS_FB_DEVVM" == "true" ]; then
    export no_proxy=".fbcdn.net,.facebook.com,.thefacebook.com,.tfbnw.net,.fb.com,.fburl.com,.facebook.net,.sb.fbsbx.com,localhost"
    export http_proxy=fwdproxy:8080
    export https_proxy=fwdproxy:8080
fi

# Disable 'Couldn't connect to accessibility bus' error on opening gnome
# applications.
# http://askubuntu.com/questions/227515/terminal-warning-when-opening-a-file-in-gedit
if [ "$OS" == "LINUX" ]; then
    export NO_AT_BRIDGE=1
fi

# Java
JVM=/usr/lib/jvm
IBM_JAVA=$JVM/java-1.7.0-ibm-amd64/jre
OPENJDK_JAVA=$JVM/java-1.7.0-openjdk-amd64
ORACLE_JAVA=$JVM/java-1.8.0-oracle-amd64
export JAVA_HOME=$ORACLE_JAVA
export CLASSPATH=/usr/local/lib:$JAVA_HOME/lib
IDEA_BIN=$HOME/idea/bin
ECLIPSE=/opt/eclipse

# Go
export GOROOT=$HOME/go1.10.3
GO_BIN=$GOROOT/bin
export GOPATH=$HOME/dev/go
GO_HOME_BIN=$GOPATH/bin
if [ "$OS" == "LINUX" ]; then
    export GOOS=linux
    export GOARCH=amd64
fi

# solarized .Xresources fix (http://askubuntu.com/questions/302736/solarized-color-name-not-defined)
if [ "$OS" == "LINUX" ]; then
    export SYSRESOURCES=/etc/X11/Xresources
    export USRRESOURCES=$HOME/.Xresources
fi

# Android
export ANDROID_HOME=$HOME/android
export ANDROID_NDK=$ANDROID_HOME/ndk
export ANDROID_NDK_HOME=$ANDROID_NDK
ANDROID_STUDIO=$HOME/android-studio
ANDROID_ARM_TOOLCHAIN=$HOME/arm-linux-androideabi
ANDROID_STANDALONE_TOOLCHAIN=$ANDROID_ARM_TOOLCHAIN
ANDROID_PATH=$ANDROID_HOME/tools:$ANDROID_HOME/platform-tools:$ANDROID_NDK:$ANDROID_STANDALONE_TOOLCHAIN/bin

### Added by the Heroku Toolbelt
export HEROKU_TOOLBELT=/usr/local/heroku/bin

# Arduino
ARDUINO_SDK=$HOME/arduino-1.0.4

# Haskell
CABAL_BIN=$HOME/.cabal/bin

# Git submodule tools
GIT_SUBMODULE_TOOLS=$HOME/git-submodule-tools

INTEL_HOME=/opt/intel
INTEL_BIN=$INTEL_HOME/bin
INTEL_LIB=$INTEL_HOME/lib/intel64
if [ -f "$INTEL_HOME" ]; then
    export INTEL_LICENSE_FILE=$INTEL_HOME/licenses/l_CZSTLDHD.lic
fi

SPARK_HOME=$HOME/spark
SPARK_BIN=$SPARK_HOME/bin

NPM_HOME=$HOME/.npm
NPM_BIN=$NPM_HOME/bin

# JRuby
JRUBY_HOME=$HOME/jruby
JRUBY_BIN=$JRUBY_HOME/bin

# Gurobi
if [ "$OS" == "LINUX" ]; then
    export GUROBI_HOME=$HOME/gurobi651/linux64
fi
export GRB_LICENSE_FILE=$HOME/gurobi.lic
GUROBI_BIN=$GUROBI_HOME/bin
GUROBI_LIB=$GUROBI_HOME/lib

# Rust
if [ -x "$(command -v rustc)" ]; then
    RUST_SYSROOT=$(rustc --print sysroot)
    export RUST_SRC_PATH=$RUST_SYSROOT/lib/rustlib/src/rust/src/
fi
export CARGO_HOME=$HOME/.cargo
CARGO_BIN=$CARGO_HOME/bin

# Google
DEPOT_TOOLS=$HOME/depot_tools

LOCAL_BIN=$HOME/.local/bin

# LD Path
if [ "$OS" == "LINUX" ]; then
    export LD_LIBRARY_PATH=$LD_LIBRARY_PATH:$INTEL_LIB:$GUROBI_LIB
fi

# python3
export PYTHON3_VERSION=python3.6
# pyvenv virtual environments
export PYTHON3_ENV_DIR=$HOME/virtualenvs
ANACONDA_HOME=$HOME/anaconda3/bin
if [ "$OS" == "LINUX" ]; then
    # Global python3 install
    export PYTHON3_BIN="/bin/$PYTHON3_VERSION"
elif [ "$OS" == "OSX" ]; then
    # Use Brew python3 install
    export PYTHON3_BIN="/opt/homebrew/bin/$PYTHON3_VERSION"
fi

# PATH
export PATH=$PATH:$JAVA_HOME/bin
export PATH=$PATH:$GO_BIN
export PATH=$PATH:$GO_HOME_BIN
export PATH=$PATH:$ANDROID_PATH
export PATH=$PATH:$ARDUINO_SDK
export PATH=$PATH:$GIT_SUBMODULE_TOOLS
export PATH=$PATH:$CABAL_BIN
export PATH=$PATH:$ANACONDA_HOME
export PATH=$PATH:$LOCAL_BIN
export PATH=$PATH:$INTEL_BIN
export PATH=$PATH:$NPM_BIN
export PATH=$PATH:$GUROBI_BIN
export PATH=$PATH:$CARGO_BIN
export PATH=$PATH:$DEPOT_TOOLS

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

## NPM COMPLETITON {{{

# npm command completion script

COMP_WORDBREAKS=${COMP_WORDBREAKS/=/}
COMP_WORDBREAKS=${COMP_WORDBREAKS/@/}
export COMP_WORDBREAKS

if type complete &>/dev/null; then
  _npm_completion () {
    local si="$IFS"
    IFS=$'\n' COMPREPLY=($(COMP_CWORD="$COMP_CWORD" \
                           COMP_LINE="$COMP_LINE" \
                           COMP_POINT="$COMP_POINT" \
                           npm completion -- "${COMP_WORDS[@]}" \
                           2>/dev/null)) || return $?
    IFS="$si"
  }
  complete -F _npm_completion npm
elif type compdef &>/dev/null; then
  _npm_completion() {
    si=$IFS
    compadd -- $(COMP_CWORD=$((CURRENT-1)) \
                 COMP_LINE=$BUFFER \
                 COMP_POINT=0 \
                 npm completion -- "${words[@]}" \
                 2>/dev/null)
    IFS=$si
  }
  compdef _npm_completion npm
elif type compctl &>/dev/null; then
  _npm_completion () {
    local cword line point words si
    read -Ac words
    read -cn cword
    let cword-=1
    read -l line
    read -ln point
    si="$IFS"
    IFS=$'\n' reply=($(COMP_CWORD="$cword" \
                       COMP_LINE="$line" \
                       COMP_POINT="$point" \
                       npm completion -- "${words[@]}" \
                       2>/dev/null)) || return $?
    IFS="$si"
  }
  compctl -K _npm_completion npm
fi

## }}}

# vim:foldmethod=marker
