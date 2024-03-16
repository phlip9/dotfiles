nvim-settings
=============

Neovim settings for use across different computers


## Setup / Dependencies ##


### _Optional_: Powerline fonts ###

To get specialized glyphs like arrows, git symbols, etc... in the neovim status
bar, then install patched powerline fonts from:
https://github.com/powerline/fonts

I use the SourceCodePro font, so I would download and install the fonts from:
https://github.com/powerline/fonts/tree/master/SourceCodePro

To efficiently download and install all patched Source Code Pro fonts:

```bash
# (Ubuntu/Debian/Pop!_OS)
$ cd ~/.local/share/fonts

# (macOS)
$ cd ~/Downloads && mkdir fonts && cd fonts

# Download fonts (with extra query parameter cruft in filenames)
$ curl --proto '=https' --tlsv1.3 https://github.com/powerline/fonts/tree/master/SourceCodePro \
    | sed -n -e 's/^.*href="\(.*\.otf\)".*$/https:\/\/github.com\1?raw=true/p' \
    | xargs wget
# Remove query parameter cruft from the filenames
$ ls \
    | sed -n -e 's/^\(.*\)?raw=true/\1/p' \
    | xargs -p -I'{}' mv '{}'?raw=true '{}'

# (Ubuntu/Debian/Pop!_OS - Gnome)
$ sudo apt install gnome-tweaks

# Set Fonts > Monospace to 'Source Code Pro - Regular'

# (macOS) Manually open each font in finder
$ open .

# (macOS) Clean up
$ cd .. && rm -rf fonts
```


### _Optional_: Rust setup ###

```bash
$ curl --proto '=https' --tlsv1.3 -sSf https://sh.rustup.rs | bash

#  default host triple: default
#    default toolchain: stable
#              profile: default
# modify PATH variable: no

$ rustup update nightly
$ rustup component add rust-src rustfmt clippy

# Install rusty-tags
$ cargo install rusty-tags

# Generate tags
$ cd my_rust_project/
$ rusty-tags vi

# Install rust-analyzer
$ git clone --depth=1 https://github.com/rust-lang/rust-analyzer
$ cd rust-analyzer
# Compile with many optimizations. rust-analyzer is going to consume a LOT of
# CPU on our machine, might as well pay some extra upfront cost so it's faster
# while developing.
$ RUSTFLAGS="-C target-cpu=native" \
    CARGO_PROFILE_RELEASE_CODEGEN_UNITS=1 \
    CARGO_PROFILE_RELEASE_INCREMENTAL=false \
    CARGO_PROFILE_RELEASE_LTO=fat \
    cargo xtask install --server --jemalloc

# (OSX) If rust-lldb doesn't work:
$ brew unlink python
$ brew unlink python@2
```
