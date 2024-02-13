#!/usr/bin/env bash
# shellcheck source=/dev/null

## INIT {{{

# If not running interactively, don't do anything
[ -z "$PS1" ] && return

# Source global definitions
[ -f /etc/bashrc ] && source /etc/bashrc

# # Source homebrew shell environment
# [ -x /opt/homebrew/bin/brew ] \
#     && eval "$(/opt/homebrew/bin/brew shellenv)"

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

# # set variable identifying the chroot you work in (used in the prompt below)
# if [ -z "$debian_chroot" ] && [ -r /etc/debian_chroot ]; then
#     debian_chroot=$(cat /etc/debian_chroot)
# fi
#
# # set a fancy prompt (non-color, unless we know we "want" color)
# case "$TERM" in
#     xterm-color) color_prompt=yes;;
# esac
#
# # uncomment for a colored prompt, if the terminal has the capability; turned
# # off by default to not distract the user: the focus in a terminal window
# # should be on the output of commands, not on the prompt
# force_color_prompt=yes
#
# if [ -n "$force_color_prompt" ]; then
#     if [ -x /usr/bin/tput ] && tput setaf 1 >&/dev/null; then
#     # We have color support; assume it's compliant with Ecma-48
#     # (ISO/IEC-6429). (Lack of such support is extremely rare, and such
#     # a case would tend to support setf rather than setaf.)
#     color_prompt=yes
#     else
#     color_prompt=
#     fi
# fi
#
# if [ "$color_prompt" = yes ]; then
#     PS1='${debian_chroot:+($debian_chroot)}\[\033[01;32m\]\u@\h\[\033[00m\]:\[\033[01;34m\]\w\[\033[00m\]\$ '
# else
#     PS1='${debian_chroot:+($debian_chroot)}\u@\h:\w\$ '
# fi
# unset color_prompt force_color_prompt
#
# # If this is an xterm set the title to user@host:dir
# case "$TERM" in
# xterm*|urxvt*)
#     PS1="\[\e]0;${debian_chroot:+($debian_chroot)}\u@\h: \w\a\]$PS1"
#     ;;
# *)
#     ;;
# esac

PS1="\[\033[01;32m\]\u@\h\[\033[00m\]:\[\033[01;34m\]\w\[\033[00m\]\$ "

# Tell macOS to stfu when it's using bash
export BASH_SILENCE_DEPRECATION_WARNING=1

# Set $EDITOR depending on what's installed
if [ -x "$(command -v nvim)" ]; then
    export EDITOR=nvim
elif [ -x "$(command -v vim)" ]; then
    export EDITOR=vim
elif [ -x "$(command -v vi)" ]; then
    export EDITOR=vi
elif [ -x "$(command -v nano)" ]; then
    export EDITOR=nano
fi

if [ "$OS" == "OSX" ]; then
    # macOS doesn't appear to let you increase ulimit in a configuration file,
    # so gotta shove it in here...

    # Increase number of allowed open files per process.
    # -S = soft limit
    # -n = number of open files
    ulimit -Sn 1024
fi

# SETTINGS }}}

## ALIASES {{{

# fix background for ls --color
[ "$IS_WSL" ] && export LS_COLORS='ow=01;36;40'

# annoying typos
alias :q='quit'
alias cd..='cd ..'
alias cim='vim'
alias shh='ssh'

# To find the `complete` fn for a given command (ex: git): `complete -p git`

# git shortcut
alias g='git'
complete -o bashdefault -o default -o nospace -F __git_wrap__git_main g

# cargo shortcut
alias c='cargo'

# just shortcut
alias j='just'
complete -o bashdefault -o default -F _just j

# tmux 256 colors
alias tmux="TERM=screen-256color tmux -2"

# OS-specific aliases
if [ "$OS" == "LINUX" ]; then
    alias grep='grep --color=auto'
    alias fgrep='fgrep --color=auto'
    alias egrep='egrep --color=auto'

    alias install='sudo apt-get install'
    alias update='sudo apt-get update'
    alias upgrade='sudo apt-get upgrade'

    # pulseaudio sucks
    alias restartpulse='sudo killall -9 pulseaudio; pulseaudio >/dev/null 2>&1 &'

    # Add an "alert" alias for long running commands.  Use like so:
    #   sleep 10; alert
    alias alert='notify-send --urgency=low -i "$([ $? = 0 ] && echo terminal || echo error)" "$(history|tail -n1|sed -e '\''s/^\s*[0-9]\+\s*//;s/[;&|]\s*alert$//'\'')"'

    # Clean out $PATH for steam
    alias steam='PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/games:/usr/local/games steam'
elif [ "$OS" == "OSX" ]; then
    # alias sha256sum='shasum -a 256'

    alias alert='osascript -e "display notification \"Command completed\" with title \"Terminal Alert\""'
fi

# expressvpn shits all over systemd's resolv.conf.
# unshittify this when stopping the vpn.
alias expressvpn-unfuck='sudo ln -sf /run/resolveconf/resolv.conf /etc/resolv.conf'

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
    python3 -m venv "$PYTHON3_ENV_DIR/$1"
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
    curl --no-progress-meter -d "$JSON" -H 'Content-Type: application/json' https://api.ageofempires.com/api/ageiv/Leaderboard \
        | jq '.items[] | { name: .userName, elo: .elo, rank: .rank, win_rate: .winPercent, wins: .wins, losses: .losses  }'
}

[ "$IS_WSL" ] && alias firefox='/mnt/c/Program\ Files/Mozilla\ Firefox/firefox.exe'
[ "$IS_WSL" ] && alias explorer='/mnt/c/Windows/explorer.exe'

function wsl_open() {
    local WSL_FS_PREFIX="file://///wsl.localhost/Ubuntu-18.04"

    if [[ "$1" =~ ^(http|https)://.+$ ]]; then
        firefox "$1"
    elif [[ -f "$1" ]]; then
        local ABS_PATH
        ABS_PATH=$(realpath -e "$1")
        firefox "$WSL_FS_PREFIX$ABS_PATH"
    else
        local ABS_PATH
        ABS_PATH=$(realpath -e "$1")
        explorer "$WSL_FS_PREFIX$ABS_PATH"
    fi
}

[ "$IS_WSL" ] && alias open='wsl_open'

# nix home-manager, but with configuration in my dotfiles git repo.
alias hm='home-manager --flake ~/dev/dotfiles#$(hostname -s)'
complete -o default -F _home-manager_completions hm
alias hms='home-manager --flake ~/dev/dotfiles#$(hostname -s) switch'

## ALIASES }}}

## ENV VARS {{{

export XDG_CONFIG_HOME=$HOME/.config
export XDG_CACHE_HOME=$HOME/.cache
export XDG_DATA_HOME=$HOME/.local/share
export XDG_STATE_HOME=$HOME/.local/state

# Facebook devserver proxy
if [ "$IS_FB_DEVVM" ]; then
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
export SDKMAN_DIR="$HOME/.local/sdkman"

# Go
export GOROOT=$HOME/.local/go1.19.3
GOROOT_BIN=$GOROOT/bin

# solarized .Xresources fix (http://askubuntu.com/questions/302736/solarized-color-name-not-defined)
if [ "$OS" == "LINUX" ]; then
    export SYSRESOURCES=/etc/X11/Xresources
    export USRRESOURCES=$HOME/.Xresources
fi

# Android
export ANDROID_HOME=$HOME/.local/android
ANDROID_SDK_VERSION=33.0.1
ANDROID_PATH=$ANDROID_HOME/cmdline-tools/latest/bin
ANDROID_PATH=$ANDROID_PATH:$ANDROID_HOME/build-tools/$ANDROID_SDK_VERSION
ANDROID_PATH=$ANDROID_PATH:$ANDROID_HOME/platform-tools

# export ANDROID_NDK=$ANDROID_SDK_ROOT/ndk
# export ANDROID_NDK_HOME=$ANDROID_NDK
# ANDROID_STUDIO=$HOME/android-studio
# ANDROID_ARM_TOOLCHAIN=$HOME/arm-linux-androideabi
# ANDROID_STANDALONE_TOOLCHAIN=$ANDROID_ARM_TOOLCHAIN
# ANDROID_SDK_VERSION=31.0.0
# ANDROID_PATH=$ANDROID_SDK_ROOT/cmdline-tools/latest/bin:$ANDROID_SDK_ROOT/build-tools/$ANDROID_SDK_VERSION:$ANDROID_SDK_ROOT/tools:$ANDROID_SDK_ROOT/tools/bin
# ANDROID_PATH=$ANDROID_PATH:$ANDROID_SDK_ROOT/platform-tools:$ANDROID_NDK:$ANDROID_STANDALONE_TOOLCHAIN/bin

# Flutter

FLUTTER_HOME=$HOME/.local/flutter
FLUTTER_BIN=$FLUTTER_HOME/bin

# Dart

DART_PUB_BIN=$HOME/.pub-cache/bin

### Added by the Heroku Toolbelt
export HEROKU_TOOLBELT=/usr/local/heroku/bin

# Arduino
ARDUINO_SDK=$HOME/arduino-1.0.4

# Haskell
CABAL_BIN=$HOME/.cabal/bin

# Git submodule tools
GIT_SUBMODULE_TOOLS=$HOME/git-submodule-tools

# INTEL_HOME=/opt/intel
# INTEL_BIN=$INTEL_HOME/bin
# INTEL_LIB=$INTEL_HOME/lib/intel64
# if [ -f "$INTEL_HOME" ]; then
#     export INTEL_LICENSE_FILE=$INTEL_HOME/licenses/l_CZSTLDHD.lic
# fi

# SPARK_HOME=$HOME/spark
# SPARK_BIN=$SPARK_HOME/bin

NPM_HOME=$HOME/.npm
NPM_BIN=$NPM_HOME/bin

# # JRuby
# JRUBY_HOME=$HOME/jruby
# JRUBY_BIN=$JRUBY_HOME/bin

# # Gurobi
# if [ "$OS" == "LINUX" ]; then
#     export GUROBI_HOME=$HOME/gurobi651/linux64
# fi
# export GRB_LICENSE_FILE=$HOME/gurobi.lic
# GUROBI_BIN=$GUROBI_HOME/bin
# GUROBI_LIB=$GUROBI_HOME/lib

# Rust Cargo
CARGO_HOME=$HOME/.cargo
CARGO_BIN=$CARGO_HOME/bin

# Google
DEPOT_TOOLS=$HOME/depot_tools

LOCAL_BIN=$HOME/.local/bin

# # LD Path
# if [ "$OS" == "LINUX" ]; then
#     export LD_LIBRARY_PATH=$LD_LIBRARY_PATH:$INTEL_LIB:$GUROBI_LIB
# fi

# python3
# venv virtual environments
export PYTHON3_ENV_DIR=$HOME/.local/state/venv
export ENV_DIR=$PYTHON3_ENV_DIR

# # NVM
# export NVM_DIR=$XDG_CONFIG_HOME/nvm

# # Yarn
# YARN_HOME=$HOME/.yarn
# YARN_BIN=$YARN_HOME/bin
# YARN_NODE_MODULES_BIN=$XDG_CONFIG_HOME/yarn/global/node_modules/.bin

# Move Prover Tools
export DOTNET_ROOT=$HOME/.dotnet
export DOTNET_BIN=$DOTNET_ROOT/tools
export BOOGIE_EXE=$DOTNET_BIN/boogie
export Z3_EXE=$LOCAL_BIN/z3
export CVC4_EXE=$LOCAL_BIN/cvc4

# ATS1
export ATSHOME=$HOME/dev/ats1
export ATSHOMERELOC=ATS-0.2.13

# ATS2
export PATSHOME=$HOME/dev/ats2
PATSBIN=$PATSHOME/bin
export PATSCONTRIB=$HOME/dev/ats2-contrib
export PATSHOMERELOC=$PATSCONTRIB

# Ruby Gems
export GEM_HOME=$HOME/.local/gem
GEM_BIN=$GEM_HOME/bin

# PATH
export PATH=$PATH:$GOROOT_BIN
export PATH=$PATH:$ANDROID_PATH
export PATH=$PATH:$FLUTTER_BIN
export PATH=$PATH:$DART_PUB_BIN
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
# export PATH=$PATH:$YARN_BIN
# export PATH=$PATH:$YARN_NODE_MODULES_BIN
export PATH=$PATH:$DOTNET_BIN
export PATH=$PATH:$PATSBIN
export PATH=$PATH:$GEM_BIN

# Java SDKMAN
[[ -s "$SDKMAN_DIR/bin/sdkman-init.sh" ]] && source "$SDKMAN_DIR/bin/sdkman-init.sh"

# TODO: do we still need this?
# # set RUST_SRC_PATH based on current rustup version
# if [ -x "$(command -v rustc)" ]; then
#     RUST_SYSROOT=$(rustc --print sysroot)
#     export RUST_SRC_PATH=$RUST_SYSROOT/lib/rustlib/src/rust/src/
# fi

## ENV VARS }}}

## SSH AGENT {{{

# When in WSL, Start the keychain ssh-agent frontend in lazy mode.
if [[ $IS_WSL && -x "$(command -v keychain)" ]]; then
    keychain --nogui --noask --quiet
    source "$HOME/.keychain/$HOSTNAME-sh"
fi

## }}}

## COMPLETIONS {{{

# # NVM setup and bash completions
# [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
# [ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"

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
            [[ -r "${COMPLETION}" ]] && source "${COMPLETION}"
        done
    fi
fi

# Bash completions from nix profiles
for PROFILE in $NIX_PROFILES; do
    for COMPLETION in "${PROFILE}/share/bash-completion/completions/"*; do
        [[ -r "${COMPLETION}" ]] && source "${COMPLETION}"
    done
done

# Alacritty
[ -f "$HOME/.local/share/alacritty/alacritty.bash" ] && source "$HOME/.local/share/alacritty/alacritty.bash"

## COMPLETIONS }}}

## NIX POSTLUDE {{{

# Nix env setup
[ -f "$HOME/.nix-profile/etc/profile.d/nix.sh" ] && source "$HOME/.nix-profile/etc/profile.d/nix.sh"

## NIX POSTLUJDE }}}

# vim:foldmethod=marker
