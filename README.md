phlip9's dotfiles
=================

+ Install neovim:
https://github.com/phlip9/dotfiles/blob/master/nvim/README.md


# New Machine Setup #


### Create a new ssh keypair and add to Github ###

```
$ ssh-keygen -a 100 -t ed25519 -f ~/.ssh/id_ed25519 -C "phlip9@phliptop"
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

```
# (OSX) Add private key to keychain
$ ssh-add -AK ~/.ssh/id_ed25519
```

## Debian|Ubuntu|WSL ##

### Install tmux (apt) ###

+ If the installation is recent enough, the `tmux` in the package repos
  should be new enough (>=3.0).

```bash
$ sudo apt install tmux
```


### Install tmux (source) ###

+ Install tmux build dependencies

```
$ sudo apt install m4 libevent-dev libncurses5-dev autogen automake pkg-config libtool perl bison
```

+ Build tmux from source

```
$ cd ~/dev
$ git clone git@github.com:tmux/tmux.git
$ cd tmux
$ git checkout 3.0
$ ./autogen.sh
$ ./configure
$ make && sudo make install
```


### Install URxvt

+ Install from apt

```bash
$ sudo apt install rxvt-unicode xsel
```


### Remap Caps Lock -> Escape (tap) + Ctrl (hold)

+ Install `interception-tools` and `interception-caps2esc`

```bash
$ sudo add-apt-repository ppa:deafmute/interception
$ sudo apt install interception-tools interception-caps2esc
```

+ Default config

```yaml
# File: /etc/interception/udevmon.d/deafmute-ppa-caps2esc.yaml
- JOB: intercept -g $DEVNODE | caps2esc | uinput -d $DEVNODE
  DEVICE:
    EVENTS:
      EV_KEY: [KEY_CAPSLOCK, KEY_ESC]
```


### Install Obsidian.md and sync notes

```bash
# (flatpak)
$ flatpak install Obsidian

$ git clone git@github.com:phlip9/notes.git
```

+ Open vault in notes directory.


### Install htop

```bash
$ sudo apt install lm-sensors htop
```


### Firefox touch screen support and smooth scrolling

+ Add `MOZ_USE_XINPUT2 DEFAULT=1` to `/etc/security/pam_env.conf` and then relog.


### Install nix

```bash
$ curl --proto '=https' --tlsv1.2 -sSfL https://nixos.org/nix/install | bash
```

+ Remove the line the installer adds in `$HOME/.profile`.

+ Upgrade to unstable

```bash
$ nix-env -f '<nixpkgs>' -iA nixUnstable
$ mkdir ~/.config/nix
$ echo 'experimental-features = nix-command flakes' >> ~/.config/nix/nix.conf
```


## OSX ##


### Install iTerm2 ###

+ Download and install from:
  https://iterm2.com/downloads.html

+ View > Customize Touch Bar > Remove everything from the touchbar


### Clone phlip9/dotfiles ###

```
$ mkdir ~/dev
$ cd ~/dev
$ git clone https://github.com/phlip9/dotfiles.git
$ cd dotfiles

# upgrade pip
$ sudo -H python3 -m pip install --upgrade pip

# run dotfiles install
$ python3 install.py

# source our personal bashrc settings
$ echo "[ -f ~/.bashrc ] && source ~/.bashrc" >> ~/.bash_profile
$ source ~/.bash_profile
```


### Install Brew ###

```
$ curl --proto '=https' --tlsv1.2 -sSf https://raw.githubusercontent.com/Homebrew/install/master/install.sh | bash
$ brewperm
```


### Install tmux ###

```
$ brew install tmux
```


### Install Magnets from the Apple App Store ###


### Install Irssi for IRC ###

```
brew install irssi
```


### Install Karabiner for Caps Lock -> Escape (tap) + Ctrl (hold) ###

+ Download and install from:
  https://pqrs.org/osx/karabiner/index.html

+ Under complex rules, hit import from internet

+ Import the Caps Lock rev. 2 rules

+ Unmap Escape

+ Remap Caps Lock -> Control when as a modifier and Escape when hit alone



## RHEL|Fedora|CentOS ##


## Setup the dotfiles

```
$ mkdir ~/dev
$ cd ~/dev
$ git clone git@github.com:phlip9/dotfiles.git
$ python3.6 install.py
```


## Install autoconf/automake

```
sudo yum install autoconf automake
```


## Upgrade `tmux`

+ The default tmux version (2.2) is too old.

```
$ git clone git@github.com:tmux/tmux.git
$ cd tmux
$ git checkout 3.0
$ sudo yum install libevent-devel ncurses-devel
$ ./autogen.sh
$ ./configure
$ make && sudo make install
```


## Windows

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

```
PS> Set-ExecutionPolicy RemoteSigned -scope CurrentUser
PS> iwr -useb get.scoop.sh | iex
```

+ Install mingit-busybox

```
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

```
> dism.exe /online /enable-feature /featurename:Microsoft-Windows-Subsystem-Linux /all /norestart
> dism.exe /online /enable-feature /featurename:VirtualMachinePlatform /all /norestart
```

+ Restart

+ Open PowerShell as Admin

```
> wsl --set-default-version 2
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

```sh
$ sudo apt install keychain
```

Then add `AddKeysToAgent yes` to `~/.ssh/config`. Make sure it has the right
permissions too, `chmod 644 ~/.ssh/config`.

+ Inside WSL install, follow "Debian|Ubuntu|WSL" setup
