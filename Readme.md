# gh-source
This is a plugin manager for people who don't like plugin managers. It's a simple shell function that downloads and installs plugins from GitHub. It's designed to be used with [zsh](http://www.zsh.org/), but it should work with any shell.

## Installation
in the terminal
either clone this repo
```sh
git clone https://github.com/yarden-zamir/gh-source.git
```
or use a package manager
```sh
brew install yarden-zamir/tap/gh-source
```
then in your `.zshrc`   
```sh
source ~/location/gh-source/gh-source.zsh
```
(This is the last time you need to clone shell stuff manually)
## Problem domains / needs
1. Fast
2. Simple
3. Configuring/installing plugins in one location
4. Updating plugins
5. Opinionated - because all of my plugins are hosted on github, I can rely on that to make things easier and faster
6. Customizable

## Before / After
As someone who didn't like all the stuff that comes with all the popular pluigin managers and hated how most don't even ofer proper updating system. I usually did the following

---
in the terminal
```sh
git clone https://github.com/hlissner/zsh-autopair.git
```
then in my `.zshrc`
```sh
source ~/github/zsh-autopair/autopair.zsh
```
---
using gh-source, I don't need to run anything ahead of time, just add this line to my `.zshrc`
```sh
gh_source hlissner/zsh-autopair/autopair.zsh
```
and it will download and source the plugin for me. 

This is useful for sharing dotfiles, because I don't need to share an instruction manual for what to clone before hand or a seperate script. Better yet it lets me update all my plugins easily with `gh_source --update`

## Help
```sh
Usage: prog [options] [plugin] [install_command] [install_location]
Examples:
  gh-source owner/repo/script.zsh
  gh-source owner/repo 'source {}/script.zsh && echo potato'
  gh-source owner/repo 'source {}/script.zsh && echo potato' /home/user/special_location
  gh-source --update
Options:
  --help: print this help message
  --update: update all plugins
  --list: list all plugins
Arguments:
  plugin: the plugin to source. If no install_command is passed, it will assume the last segment is the file to source (default install command)
  install_command: the command to run to install the plugin (default: 'source {}/$(echo "$1" | cut -d'/' -f3-) where {} is replaced by install location. meaning that if your plugin is owner/repo/plug.zsh, it will run 'source $install_location/plug.zsh
  install_location: the location to install the plugin to (default: $GH_SOURCE_INSTALL_LOCATION/$(basename $install_source))
```
