phlip9's dotfiles
=================

## New Machine Setup #


### Immediately install all system and package updates


### Install and setup Firefox

+ Download and install from: <https://www.mozilla.org/en-US/firefox/new/>

+ Open Firefox. Add to bar. Set as default browser. Login to FF sync. Hide bookmarks.

+ (macOS) disable Esc to exit fullscreen. Go to `about:config`. Toggle
  `browser.fullscreen.exit_on_escape`.


### (macOS) Install Xcode developer CLI tools

+ In Terminal.app, just enter

```bash
$ git --help
```

A popup will appear asking if you want to install the macOS Xcode developer tools.
Hit accept and install. This step will install some basic unix CLI tools, among
other things.


### Create a new ssh keypair and add to Github ###

```bash
$ ssh-keygen -a 100 -t ed25519 -f ~/.ssh/id_ed25519 -C "phlip9@<hostname>"
```

+ Note: don't use a password on Windows since the GUI password check doesn't seem
  to work for tty-less use (Obsidian Git)

+ Add the key to: https://github.com/settings/keys

+ Append the following to `~/.ssh/config`:

```
Host *
    UseKeychain yes
    AddKeysToAgent yes
    IdentityFile ~/.ssh/id_ed25519
```

```bash
# (OSX) Add private key to keychain
#       EDIT: -A and -K are deprecated on macOS. need to do some experimenting here
$ ssh-add -AK ~/.ssh/id_ed25519
```


### Install phlip9/dotfiles ###

```bash
$ mkdir ~/dev
$ cd ~/dev
$ git clone https://github.com/phlip9/dotfiles.git
$ cd dotfiles

# upgrade pip
$ sudo apt install python3-pip
$ sudo -H python3 -m pip install --upgrade pip

# run dotfiles install
$ python3 install.py

# (OSX) source our personal bashrc settings
$ echo "[ -f ~/.bashrc ] && source ~/.bashrc" >> ~/.bash_profile
$ source ~/.bash_profile
```


### Install Neovim and dev tooling

[phlip9/dotfiles > nvim/README.md](https://github.com/phlip9/dotfiles/blob/master/nvim/README.md)


## Debian|Ubuntu|WSL

### Install tmux

#### Intall tmux (apt)

+ If the installation is recent enough, the `tmux` in the package repos
  should be new enough (>=3.0).

```bash
$ sudo apt install tmux
```


#### Install tmux (source)

+ Install tmux build dependencies

```bash
$ sudo apt install m4 libevent-dev libncurses5-dev autogen automake pkg-config libtool perl bison
```

+ Build tmux from source

```bash
$ cd ~/dev
$ git clone git@github.com:tmux/tmux.git
$ cd tmux
$ git checkout 3.0
$ ./autogen.sh
$ ./configure
$ make && sudo make install
```


### Remap Caps Lock -> Escape (tap) + Ctrl (hold)

+ Install `interception-tools` and `interception-caps2esc`

#### Install interception-tools (ppa on Ubuntu <= 20.04)

```bash
# These ppa's were out-of-date when I tried installing on a recent Pop!_OS 22.04
$ sudo add-apt-repository ppa:deafmute/interception
$ sudo apt install interception-tools interception-caps2esc
```

#### Install interception-tools (source)

+ Install build pre-reqs

```bash
$ sudo apt install cmake libudev-dev libyaml-cpp-dev libevdev-dev libboost-dev
```

+ Build and install `interception-tools`

```bash
$ git clone --depth 1 https://gitlab.com/interception/linux/tools.git \
    interception-tools
$ cd interception-tools
$ cmake -B build -DCMAKE_BUILD_TYPE=Release
$ cmake --build build
$ sudo cmake --install build
```

+ Build and install `interception-caps2esc` plugin

```bash
$ git clone --depth 1 https://gitlab.com/interception/linux/plugins/caps2esc.git \
    interception-caps2esc
$ cd interception-caps2esc
$ cmake -B build -DCMAKE_BUILD_TYPE=Release
$ cmake --build build
$ sudo cmake --install build
```

+ Create config dir

```bash
$ sudo mkdir -p /etc/interception/udevmon.d/
```

+ Create systemd service

```service
# /etc/systemd/system/udevmon.service
[Unit]
Description=interception-tools udevmon service
Wants=systemd-udev-settle.service
After=systemd-udev-settle.service
Documentation=man:udev(7)

[Service]
ExecStart=/usr/local/bin/udevmon
Nice=-20
Restart=on-failure
OOMScoreAdjust=-1000

[Install]
WantedBy=multi-user.target
```

+ Enable and start udevmon service

```bash
$ sudo systemctl enable --now udevmon
```

#### caps2esc default config

+ Default config

```yaml
# File: /etc/interception/udevmon.d/deafmute-ppa-caps2esc.yaml
- JOB: intercept -g $DEVNODE | caps2esc | uinput -d $DEVNODE
  DEVICE:
    EVENTS:
      EV_KEY: [KEY_CAPSLOCK, KEY_ESC]
```


### Install htop

```bash
$ sudo apt install lm-sensors htop
```


### Firefox touch screen support and smooth scrolling

+ Add `MOZ_USE_XINPUT2 DEFAULT=1` to `/etc/security/pam_env.conf` and then relog.


### Install nix

See up-to-date version: <https://github.com/DeterminateSystems/nix-installer/releases>

```bash
$ curl --proto '=https' --tlsv1.2 -sSfL https://install.determinate.systems/nix/tag/v0.9.1 \
    | bash -s -- install --diagnostic-endpoint ""
```

NOTE: this is using the unofficial DeterminateSystems nix installer.


### Install alacritty

+ Install build pre-reqs

```bash
# (Ubuntu/Debian/Pop!_OS)
$ sudo apt install cmake pkg-config libfreetype6-dev libfontconfig1-dev \
    libxcb-xfixes0-dev libxkbcommon-dev python3
```

+ Build and install

```bash
$ git clone --depth=1 https://github.com/alacritty/alacritty.git
$ cd alacritty

# (Linux X11)
$ RUSTFLAGS="-C target-cpu=native" cargo build \
    --release \
    --no-default-features \
    --features=x11

# (Linux Wayland)
$ RUSTFLAGS="-C target-cpu=native" cargo build \
    --release
    --no-default-features \
    --features=wayland

# Install
$ sudo cp target/release/alacritty /usr/local/bin/
```

+ Post-build

```bash
# Install terminfo
$ sudo tic -xe alacritty,alacritty-direct extra/alacritty.info

# Install desktop entry
$ sudo cp extra/logo/alacritty-term.svg /usr/share/pixmaps/Alacritty.svg
$ sudo desktop-file-install extra/linux/Alacritty.desktop
$ sudo update-desktop-database

# Install man page
$ sudo mkdir -p /usr/local/share/man/man1
$ gzip -c extra/alacritty.man | sudo tee /usr/local/share/man/man1/alacritty.1.gz > /dev/null
$ gzip -c extra/alacritty-msg.man | sudo tee /usr/local/share/man/man1/alacritty-msg.1.gz > /dev/null

# Install bash completions
$ mkdir -p ~/.local/share/alacritty
$ cp extra/completions/alacritty.bash ~/.local/share/alacritty/alacritty.bash
$ chmod a+x ~/.local/share/alacritty/alacritty.bash
```


### Install gh cli

```bash
# (Ubuntu/Debian/Pop!_OS)
$ curl --proto '=https' --tlsv1.3 \
    https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    | sudo dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg
$ echo "deb [arch=$(dpkg --print-architecture)" \
    "signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg]" \
    "https://cli.github.com/packages stable main" \
    | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null
$ sudo apt update
$ sudo apt install gh
$ gh auth login
```


### Install Signal

```bash
# (flatpak)
$ flatpak install flathub org.signal.Signal

# (Ubuntu/Debian)
$ curl --proto '=https' --tlsv1.3 -sL \
    https://updates.signal.org/desktop/apt/keys.asc \
    | gpg --dearmor \
    | sudo tee /usr/share/keyrings/signal-desktop-keyring.gpg > /dev/null
$ echo "deb [arch=$(dpkg --print-architecture)" \
    "signed-by=/usr/share/keyrings/signal-desktop-keyring.gpg]" \
    "https://updates.signal.org/desktop/apt $(lsb_release -cs) main" \
    | sudo tee /etc/apt/sources.list.d/signal-desktop.list
$ sudo apt update
$ sudo apt install signal-desktop
```


## OSX ##


### Temporarily use system `bash` as login shell ###

+ We'll update to a newer bash in a moment. For now this is nicer that dealing
  with `zsh`...

```bash
$ chsh -s /bin/bash
```

+ Then restart for this to take effect.


### Install Karabiner for Caps Lock -> Escape (tap) + Ctrl (hold) ###

+ Download and install from:
  https://pqrs.org/osx/karabiner/index.html

+ Under "Complex Modifications", hit "+ Add Rule", then "Import more rules from internet"

+ Import the "Change caps_lock key (rev. 5)" rules

+ Unmap Escape

+ Remap Caps Lock -> Control when used as a modifier and Caps Lock -> Escape when hit alone


### Install Alacritty ###

```bash
$ git clone --depth=1 https://github.com/alacritty/alacritty.git
$ cd alacritty
$ RUSTFLAGS="-C target-cpu=native" make app
$ cp -r target/release/osx/Alacritty.app /Applications/

# install terminfo
$ sudo tic -xe alacritty,alacritty-direct extra/alacritty.info
```


### (Optional) Install iTerm2 ###

+ Download and install from:
  https://iterm2.com/downloads.html

+ View > Customize Touch Bar > Remove everything from the touchbar

+ Use `/bin/bash` as the default shell over `zsh`.

+ Import `onehalfdark.mod.itermcolors`. Go to Preferences > Profiles > Default > Colors > Color Presets > Import. Select the file. Then make sure you actually enable the imported colorscheme in the dropdown.


### Install Brew ###

```bash
$ /bin/bash -c "$(curl --proto '=https' --tlsv1.3 -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# disable analytics
$ /opt/homebrew/bin/brew analytics off
```


### Install recent `bash` version ###

```bash
$ brew install bash

# Add the brew-bash to set of acceptable login shells
$ echo "/opt/homebrew/bin/bash" | sudo tee -a /etc/shells

# Set our login shell
$ chsh -s /opt/homebrew/bin/bash
```


### Install python via brew

```bash
$ brew install python3

# ensure your shell is reloaded with the brew python first in $PATH

# update pip stuff
$ python3 -m pip install --upgrade setuptools
$ python3 -m pip install --upgrade pip
```


### Install tmux ###

```bash
$ brew install tmux
```

### Install utilities

```bash
$ brew install wget htop jq
```


### (Optional) Install Magnets from the Apple App Store ###


### (Optional) Install Irssi for IRC ###

```bash
$ brew install irssi
```


## RHEL|Fedora|CentOS ##


## Setup the dotfiles

```bash
$ mkdir ~/dev
$ cd ~/dev
$ git clone git@github.com:phlip9/dotfiles.git
$ python3 install.py
```


## Install autoconf/automake

```bash
sudo yum install autoconf automake
```


## Upgrade `tmux`

+ The default tmux version (2.2) is too old.

```bash
$ git clone git@github.com:tmux/tmux.git
$ cd tmux
$ git checkout 3.0
$ sudo yum install libevent-devel ncurses-devel
$ ./autogen.sh
$ ./configure
$ make && sudo make install
```


## Windows

### Enable IPv6

1. Open Control Panel > Network and Sharing Center > Change adapter settings
2. Right click on the WAN-facing adapter ("Ethernet" in my case) and select "Properties"
3. In the list, check "Internet Protocol Verstion 6 (TCP/IPv6)"
4. Confirm with OK

### Disable `wpad.lan` DNS spam

+ Settings > Network & Internet > Proxy > Automatically detect settings -> Off

### Disable dumb windows services that listen on ports and just cause vulns

+ https://www.drivethelife.com/windows-drivers/disable-tcp-port-135-avoid-wannacry-ransomware-windows-10-8-7-vista-xp.html

+ Create two new rules in Windows Defender Firewall that block ports 135-139, 445 on TCP and UDP. 

### Install MSYS2

+ https://www.msys2.org/

+ Enable > Run MSYS2 now

```bash
$ pacman --sync --refresh --sysupgrade
```

+ Run MSYS2 MSYS from the Start Menu

```bash
$ pacman --sync --sysupgrade
```

+ Basic `pacman` reference (https://www.msys2.org/docs/package-management/)

+ Add profile to Windows Terminal `settings.json`

```json
{
    // ..
    "profiles": 
    {
        "list": 
            [
            // ..
            {
                "closeOnExit": "always",
                    "commandline": "C:/msys64/msys2_shell.cmd -defterm -here -no-start -msys",
                    "guid": "{71160544-14d8-4194-af25-d05feeac7233}",
                    "icon": "C:/msys64/msys2.ico",
                    "name": "MSYS / MSYS2",
                    "startingDirectory": "C:/msys64/home/%USERNAME%"
            }
            ],
            // ..
    }
}
```

### Install scoop

+ In PowerShell

```powershell
PS> Set-ExecutionPolicy RemoteSigned -scope CurrentUser
PS> iwr -useb get.scoop.sh | iex
```

+ Install mingit-busybox

```powershell
PS> scoop install mingit-busybox
PS> scoop install openssh
PS> [environment]::setenvironmentvariable('GIT_SSH', (resolve-path (scoop which ssh)), 'USER')
```

### Install nmap

+ https://nmap.org/download.html

+ Install the Npcap drivers first, then nmap.


### Install SharpKeys for Caps Lock -> Escape remap that works everywhere

+ https://github.com/randyrants/sharpkeys/releases

+ Remap "Special: Caps Lock" to "Special: Escape"

+ Write to Registry


### Install AutoHotKey for Escape -> Escape (tap) + Ctrl (hold) remap

+ https://www.autohotkey.com/download/ahk-install.exe

+ Compile the following autohotkey script

```
; key_remaps.ahk

; Remap Escape -> Escape (when pressed alone)
;              -> Ctrl (when pressed with other keys)

g_EscDown := 0

*Esc::
    Send {Blind}{Ctrl Down}
    g_EscDown := A_TickCount
Return

*Esc up::
    ; Modify the threshold time (in milliseconds) as necessary
    If ((A_TickCount - g_EscDown) < 500 and A_PriorKey == "Escape")
        Send {Blind}{Ctrl Up}{Esc}
    Else
        Send {Blind}{Ctrl Up}
Return

; Remap desktop switch commands

^Left::^#Left
^Right::^#Right
```

+ Create a shortcut and add it to the Startup directory: "C:\Users\phlip9\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup"


### Install WSL

+ https://docs.microsoft.com/en-us/windows/wsl/install-win10

+ Restart, enter BIOS, and enable Intel HyperV Virtualization

+ Open PowerShell as Admin

```powershell
PS> dism.exe /online /enable-feature /featurename:Microsoft-Windows-Subsystem-Linux /all /norestart
PS> dism.exe /online /enable-feature /featurename:VirtualMachinePlatform /all /norestart
```

+ Restart

+ Open PowerShell as Admin

```powershell
PS> wsl --set-default-version 2
```

+ Install Ubuntu 20.04 LTS (https://www.microsoft.com/store/apps/9n6svws3rx71)


### Install "Cascadia Mono PL" font (https://github.com/microsoft/cascadia-code/releases)

+ Install "ttf/Cascadia Mono PL.ttf" in the release zip


### Install Windows Terminal Preview

+ https://www.microsoft.com/en-us/p/windows-terminal-preview/9n8g5rfz9xk3

+ Open settings

+ Set "defaultProfile" to Ubuntu WSL profile's uuid

```json
{
    // ..
    "confirmCloseAllTabs": false,
    "alwaysShowTabs": false,
    "showTabsInTitlebar": true,
    "showTerminalTitleInTitlebar": true,
    "theme": "dark",
    "profiles": {
        "defaults": {
            "fontFace": "Cascadia Mode PL",
            "colorScheme": "One Half Dark",
            "fontSize": 10,
            "padding": "16, 16, 16, 16",
            "scrollbarState": "hidden"
        },
        "list": [ /* .. */ ],
    },
    // ..
}
```

+ Inside WSL, install `keychain`, an ssh-agent frontend

```bash
$ sudo apt install keychain
```

Then add `AddKeysToAgent yes` to `~/.ssh/config`. Make sure it has the right
permissions too, `chmod 644 ~/.ssh/config`.

+ Inside WSL install, follow "Debian|Ubuntu|WSL" setup

### Support opening links in firefox from WSL

```bash
$ sudo apt install xdg-utils wslview
$ sudo ln -s "/mnt/c/Program Files/Mozilla Firefox/firefox.exe" /usr/local/bin/firefox
```


## Setup Obsidian Notes


### Pull notes

```bash
$ git clone git@github.com:phlip9/notes-private.git notes
```


### Install Obsidian

+ Use the `flatpak` app

```bash
# (flatpak)
$ flatpak install Obsidian
```

+ On other platforms, just download from their site: <https://obsidian.md/>


### Open notes vault

+ Obsidian > Open folder as vault




## nix

### home-manager

#### first time setup

```bash
# (if this is a new machine)
$ cp ./home/phlipdesk.nix ./home/$(hostname)
$ nvim ./home/flake.nix # copy an existing home-manager config for the new host

$ nix run home-manager/master -- --flake ./home#$(hostname) switch
```

#### active new config

If first time setup is already complete, then just:

```bash
$ hm switch
```
