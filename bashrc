#!/usr/bin/env bash
# shellcheck source=/dev/null

## INIT {{{

# If not running interactively, don't do anything
[[ $- != *i* ]] && return

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

# If a tmux session exists, just connect to it instead of creating a new one.
[[ -z "$TMUX" && ! ("$(tmux ls 2>&1)" =~ "no server running") ]] && tmux attach

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

# use auto-complete after these words
complete -cf sudo
complete -cf man
complete -cf killall
complete -cf pkill

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

# annoying typos
alias :q='quit'
alias cd..='cd ..'
alias cim='vim'
alias shh='ssh'

# trace all files sourced by bash
# -l : invoke as if bash is a login shell
# -i : bash interactive
# -x : print each line as it's executed
# -c exit : exit after
alias bash-trace="bash -lixc exit 2>&1 | sed -n 's/^+* \(source\|\.\) //p'"

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

# delete all ctags "tags" files and remove all empty directories
function cleantags() {
    find . -name "tags" -and -not -path "*/.git/*" -print0 | xargs -0 rm -v
    find . -type d -and -not -path "*/.git/*" -empty -print0 | xargs -0 rmdir
}

function urldecode() {
    python3 -c "import sys; from urllib.parse import unquote; print(unquote(sys.stdin.read()));"
}

function aoe4rank() {
    local JSON='{"region":"7","versus":"players","matchType":"unranked","teamSize":"1v1","searchPlayer":"'
    local JSON+="$1"
    local JSON+='","page":1,"count":3}'
    curl --no-progress-meter -d "$JSON" -H 'Content-Type: application/json' https://api.ageofempires.com/api/ageiv/Leaderboard \
        | jq '.items[] | { name: .userName, elo: .elo, rank: .rank, win_rate: .winPercent, wins: .wins, losses: .losses  }'
}

# nix home-manager, but with configuration in my dotfiles git repo.
alias hm='home-manager --flake ~/dev/dotfiles#$(hostname -s)'
complete -o default -F _home-manager_completions hm
alias hms='home-manager --flake ~/dev/dotfiles#$(hostname -s) switch'

## ALIASES }}}

## ENV VARS {{{

pathappend() {
    [[ -d "$1" && ":$PATH:" != *":$1:"* ]] && PATH="${PATH:+"$PATH:"}$1"
}
pathprepend() {
    [[ -d "$1" && ":$PATH:" != *":$1:"* ]] && PATH="$1${PATH:+":$PATH"}"
}

export XDG_CONFIG_HOME=$HOME/.config
export XDG_CACHE_HOME=$HOME/.cache
export XDG_DATA_HOME=$HOME/.local/share
export XDG_STATE_HOME=$HOME/.local/state

# Disable 'Couldn't connect to accessibility bus' error on opening gnome
# applications.
# http://askubuntu.com/questions/227515/terminal-warning-when-opening-a-file-in-gedit
if [ "$OS" == "LINUX" ]; then
    export NO_AT_BRIDGE=1
fi

# solarized .Xresources fix (http://askubuntu.com/questions/302736/solarized-color-name-not-defined)
if [ "$OS" == "LINUX" ]; then
    export SYSRESOURCES=/etc/X11/Xresources
    export USRRESOURCES=$HOME/.Xresources
fi

# Go
export GOROOT=$HOME/.local/go1.19.3

# Android
export ANDROID_HOME=$HOME/.local/android
ANDROID_SDK_VERSION=33.0.1
ANDROID_PATH=$ANDROID_HOME/cmdline-tools/latest/bin
ANDROID_PATH=$ANDROID_PATH:$ANDROID_HOME/build-tools/$ANDROID_SDK_VERSION
ANDROID_PATH=$ANDROID_PATH:$ANDROID_HOME/platform-tools

# Ruby Gems
export GEM_HOME=$HOME/.local/gem

pathappend "$GOROOT/bin"
pathappend "$HOME/.local/flutter/bin"
pathappend "$HOME/.pub-cache/bin" # dart
pathappend "$HOME/.cargo/bin"
pathappend "$HOME/.local/bin"
pathappend "$GEM_HOME/bin"

# Java SDKMAN
if [[ -s "$SDKMAN_DIR/bin/sdkman-init.sh" ]]; then
    export SDKMAN_DIR="$HOME/.local/sdkman"
    source "$SDKMAN_DIR/bin/sdkman-init.sh"
fi

# TODO: do we still need this?
# # set RUST_SRC_PATH based on current rustup version
# if [ -x "$(command -v rustc)" ]; then
#     RUST_SYSROOT=$(rustc --print sysroot)
#     export RUST_SRC_PATH=$RUST_SYSROOT/lib/rustlib/src/rust/src/
# fi

## ENV VARS }}}

## COMPLETIONS {{{

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

# vim:foldmethod=marker
