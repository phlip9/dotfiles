# ~/.bashrc: executed by bash(1) for non-login shells.
# see /usr/share/doc/bash/examples/startup-files (in the package bash-doc)
# for examples

## INIT {{{

# If not running interactively, don't do anything
[ -z "$PS1" ] && return

# Source global definitions
[ -f /etc/bashrc ] && source /etc/bashrc

# Source Facebook definitions
[ -f /usr/facebook/ops/rc/master.bashrc ] \
    && source /usr/facebook/ops/rc/master.bashrc

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

# Detect Windows Subsystem for Linux (WSL)
[ -f /mnt/c/Windows/System32/wsl.exe ] && IS_WSL="true"

# Detect FB devserver
FB_DEVVM_RE="^devvm[0-9]+.*facebook\.com$"
[[ $(uname -n) =~ $FB_DEVVM_RE ]] && IS_FB_DEVVM="true"

# Open tmux automatically
# If a session exists, just connect to it instead of creating a new one.
if [[ -z $TMUX ]] && [[ "$TERM_PROGRAM" != "vscode" ]]; then
    if [[ $(tmux ls 2>&1) =~ "no server running" ]]; then
        tmux
    else
        tmux attach
    fi
fi

## INIT }}}

## SETTINGS {{{

# bash vi editing mode
set -o vi

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

# Tell macOS to stfu when it's using bash
export BASH_SILENCE_DEPRECATION_WARNING=1

# SETTINGS }}}

## ALIASES {{{

if [ "$OS" == "LINUX" ]; then
    # fix background for ls --color
    [ $IS_WSL ] && export LS_COLORS='ow=01;36;40'

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

# git shortcut
alias g='git'

# cargo shortcut
alias c='cargo'

# big money cargo fix + fmt + clippy + lint wombo combo
alias ccc='echo "Running cargo fix" && cargo fix --allow-staged --allow-dirty --all-targets \
    && echo "Running cargo fmt" && cargo fmt \
    && echo "Running cargo xclippy --all-targets" && cargo xclippy --all-targets \
    && echo "Running cargo x lint" && cargo x lint'

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
elif [ "$OS" == "OSX" ]; then
    alias alert='osascript -e "display notification \"Command completed\" with title \"Terminal Alert\""'
fi

# less with color
alias less='less -r'

# latexmk alias
alias lmk='latexmk -pdf -pvc -shell-escape'

# makes a directory and cd's into it
function mcd() {
    mkdir "$@" && cd "$_" || exit
}

# retry a command until it fails
function retry() {
    while "$@"; do :; done
}

# pyvenv helpers

function mkvenv() {
    echo "Creating new python virtual env at '$PYTHON3_ENV_DIR/$1'"
    $PYTHON3_BIN -m venv "$PYTHON3_ENV_DIR/$1"
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

# Fix some directory permissions when brew complains
alias brewperm='sudo chown -R $(whoami) /usr/local/bin /usr/local/lib /usr/local/sbin && chmod u+w /usr/local/bin /usr/local/lib /usr/local/sbin'

# Fix /dev/kvm device permissions in WSL2
alias kvmperm='sudo chgrp kvm /dev/kvm && sudo chmod g+rw /dev/kvm'

# aws multi-factor auth script
alias aws-mfa='source $HOME/.local/bin/aws-mfa'

# delete all ctags "tags" files and remove all empty directories
function cleantags() {
    find . -name "tags" -and -not -path "*/.git/*" -print0 | xargs -0 rm -v
    find . -type d -and -not -path "*/.git/*" -empty -print0 | xargs -0 rmdir
}

function urldecode() {
    python3 -c "import sys; from urllib.parse import unquote; print(unquote(sys.stdin.read()));"
}

function minbright() {
    sudo su -c "echo 4 > /sys/class/backlight/intel_backlight/brightness"
}

function aoe4rank() {
    local JSON='{"region":"7","versus":"players","matchType":"unranked","teamSize":"1v1","searchPlayer":"'
    local JSON+="$1"
    local JSON+='","page":1,"count":3}'
    curl --no-progress-meter -d $JSON -H 'Content-Type: application/json' https://api.ageofempires.com/api/ageiv/Leaderboard \
        | jq '.items[] | { name: .userName, elo: .elo, rank: .rank, win_rate: .winPercent, wins: .wins, losses: .losses  }'
}

[ "$IS_WSL" ] && alias firefox='/mnt/c/Program\ Files/Mozilla\ Firefox/firefox.exe'
[ "$IS_WSL" ] && alias explorer='/mnt/c/Windows/explorer.exe'

function wsl_open() {
    local WSL_FS_PREFIX="file://///wsl.localhost/Ubuntu-18.04"

    if [[ "$1" =~ ^(http|https)://.+$ ]]; then
        firefox "$1"
    elif [[ -f "$1" ]]; then
        local ABS_PATH=$(realpath -e "$1")
        firefox "$WSL_FS_PREFIX$ABS_PATH"
    else
        local ABS_PATH=$(realpath -e "$1")
        explorer "$WSL_FS_PREFIX$ABS_PATH"
    fi
}

[ "$IS_WSL" ] && alias open='wsl_open'

# Alias definitions.
# You may want to put all your additions into a separate file like
# ~/.bash_aliases, instead of adding them here directly.
# See /usr/share/doc/bash-doc/examples in the bash-doc package.

if [ -f "$HOME/.bash_aliases" ]; then
    source "$HOME/.bash_aliases"
fi

## ALIASES }}}

## ENV VARS {{{

export XDG_CONFIG_HOME=$HOME/.config

# Facebook devserver proxy
if [ $IS_FB_DEVVM ]; then
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

# Java SDKMAN
export SDKMAN_DIR="$HOME/.sdkman"

# Go
if [ "$OS" == "LINUX" ]; then
    export GOROOT=$HOME/go1.10.3
    export GOOS=linux
    export GOARCH=amd64
elif [ "$OS" == "OSX" ]; then
    export GOROOT=/usr/local/opt/go/libexec
    export GOOS=darwin
    export GOARCH=amd64
fi
export GOPATH=$HOME/dev/go
GO_BIN=$GOROOT/bin
GO_HOME_BIN=$GOPATH/bin

# solarized .Xresources fix (http://askubuntu.com/questions/302736/solarized-color-name-not-defined)
if [ "$OS" == "LINUX" ]; then
    export SYSRESOURCES=/etc/X11/Xresources
    export USRRESOURCES=$HOME/.Xresources
fi

# Android
export ANDROID_SDK_ROOT=$HOME/android
export ANDROID_NDK=$ANDROID_SDK_ROOT/ndk
export ANDROID_NDK_HOME=$ANDROID_NDK
ANDROID_STUDIO=$HOME/android-studio
ANDROID_ARM_TOOLCHAIN=$HOME/arm-linux-androideabi
ANDROID_STANDALONE_TOOLCHAIN=$ANDROID_ARM_TOOLCHAIN
ANDROID_SDK_VERSION=31.0.0
ANDROID_PATH=$ANDROID_SDK_ROOT/cmdline-tools/latest/bin:$ANDROID_SDK_ROOT/build-tools/$ANDROID_SDK_VERSION:$ANDROID_SDK_ROOT/tools:$ANDROID_SDK_ROOT/tools/bin
ANDROID_PATH=$ANDROID_PATH:$ANDROID_SDK_ROOT/platform-tools:$ANDROID_NDK:$ANDROID_STANDALONE_TOOLCHAIN/bin

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

# Rust Cargo
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
export PYTHON3_VERSION=python3.9
# pyvenv virtual environments
export PYTHON3_ENV_DIR=$HOME/virtualenvs
export ENV_DIR=$PYTHON3_ENV_DIR
ANACONDA_HOME=$HOME/anaconda3/bin
if [ "$OS" == "LINUX" ]; then
    # Try global python3 install
    if [ -f /bin/$PYTHON3_VERSION ]; then
        export PYTHON3_BIN="/bin/$PYTHON3_VERSION"
    elif [ -f /usr/bin/$PYTHON3_VERSION ]; then
        export PYTHON3_BIN="/usr/bin/$PYTHON3_VERSION"
    fi
elif [ "$OS" == "OSX" ]; then
    # Use Brew python3 install
    export PYTHON3_BIN="/opt/homebrew/bin/$PYTHON3_VERSION"
fi

# FZF
export FZF_HOME=$HOME/.fzf

# NVM
export NVM_DIR=$XDG_CONFIG_HOME/nvm

# Yarn
YARN_HOME=$HOME/.yarn
YARN_BIN=$YARN_HOME/bin
YARN_NODE_MODULES_BIN=$XDG_CONFIG_HOME/yarn/global/node_modules/.bin

# Move Prover Tools
export DOTNET_ROOT=$HOME/.dotnet
export DOTNET_BIN=$DOTNET_ROOT/tools
export BOOGIE_EXE=$DOTNET_BIN/boogie
export Z3_EXE=$LOCAL_BIN/z3
export CVC4_EXE=$LOCAL_BIN/cvc4

# arm-linux-gnueabihf toolchain
ARM_TOOLCHAIN_BIN=$HOME/gcc-arm-8.3-2019.03-x86_64-arm-linux-gnueabihf/bin

# PATH
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
export PATH=$PATH:$YARN_BIN
export PATH=$PATH:$YARN_NODE_MODULES_BIN
export PATH=$PATH:$DOTNET_BIN
export PATH=$PATH:$ARM_TOOLCHAIN_BIN

# set RUST_SRC_PATH based on current rustup version
if [ -x "$(command -v rustc)" ]; then
    RUST_SYSROOT=$(rustc --print sysroot)
    export RUST_SRC_PATH=$RUST_SYSROOT/lib/rustlib/src/rust/src/
fi

# Use ripgrep for fzf filename searching
if [ -x "$(command -v rg)" ]; then
    export FZF_DEFAULT_COMMAND='rg --files --fixed-strings --ignore-case '\
'--no-ignore --hidden --follow '\
'--glob "!.git/*" --glob "!target/*" '
fi

## ENV VARS }}}

## SSH AGENT {{{

# When in WSL, Start the keychain ssh-agent frontend in lazy mode.
if [[ $IS_WSL && -x "$(command -v keychain)" ]]; then
    keychain --nogui --noask --quiet
    source $HOME/.keychain/$HOSTNAME-sh
fi

## }}}

## COMPLETIONS {{{

# enable programmable completion features (you don't need to enable
# this, if it's already enabled in /etc/bash.bashrc and /etc/profile
# sources /etc/bash.bashrc).
if [ -f /etc/bash_completion ] && ! shopt -oq posix; then
    source /etc/bash_completion
fi

# NVM setup and bash completions
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"

# FZF keybindings and fuzzy autocomplete
[ -f ~/.fzf.bash ] && source ~/.fzf.bash

# git autocomplete
# Download git-completion.bash if you don't have it already:
#     curl https://raw.githubusercontent.com/git/git/master/contrib/completion/git-completion.bash -o ~/.git-completion.bash
[ -f ~/.git-completion.bash ] && source ~/.git-completion.bash

# Homebrew bash completions
if [ -x "$(command -v brew)" ]; then
    HOMEBREW_PREFIX="$(brew --prefix)"
    if [[ -r "${HOMEBREW_PREFIX}/etc/profile.d/bash_completion.sh" ]]; then
        source "${HOMEBREW_PREFIX}/etc/profile.d/bash_completion.sh"
    else
        for COMPLETION in "${HOMEBREW_PREFIX}/etc/bash_completion.d/"*; do
            [[ -r "$COMPLETION" ]] && source "$COMPLETION"
        done
    fi
fi

# Java SDKMAN
[[ -s "$HOME/.sdkman/bin/sdkman-init.sh" ]] && source "$HOME/.sdkman/bin/sdkman-init.sh"

# Nix env setup
[ -f "$HOME/.nix-profile/etc/profile.d/nix.sh" ] && source "$HOME/.nix-profile/etc/profile.d/nix.sh"

## COMPLETIONS }}}

# vim:foldmethod=marker
