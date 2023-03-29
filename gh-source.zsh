gh_source() {
    # check if gh cli is installed
    if ! type -p gh >/dev/null; then 
        echo "gh not found on the system" >&2
        return
    fi
    [ -z "$PLUGINS" ] && export PLUGINS=""
    [ -z "$1" ] || [  "$1" = "--help" ] && {
        echo "Usage: prog [options] [plugin] [install_command] [install_location]"
        echo "Examples:"
        echo "  gh-source owner/repo/script.zsh"
        echo "  gh-source owner/repo 'source {}/script.zsh && echo potato'"
        echo "  gh-source owner/repo 'source {}/script.zsh && echo potato' /home/user/special_location"
        echo "  gh-source --update"
        echo "Options:"
        echo "  --help: print this help message"
        echo "  --update: update all plugins"
        echo "  --list: list all plugins"
        echo "Arguments:"
        echo "  plugin: the plugin to source. If no install_command is passed, it will assume the last segment is the file to source (default install command)"
        echo "  install_command: the command to run to install the plugin (default: 'source {}/\$(echo \"\$1\" | cut -d'/' -f3-) where {} is replaced by install location. meaning that if your plugin is owner/repo/plug.zsh, it will run 'source \$install_location/plug.zsh"
        echo "  install_location: the location to install the plugin to (default: \$GH_SOURCE_INSTALL_LOCATION/\$(basename \$install_source))"
        return
    }
    [ "$1" = "--update" ] && {
        if [ ! -z "$ZSH_VERSION" ]; then
            old_shwordsplit=$(set -o | grep shwordsplit | awk  '{print $2}')
            set -o shwordsplit
        fi

        GH_SOURCE_install_location=${GH_SOURCE_INSTALL_LOCATION:-$HOME/Github}

        for plugin in $PLUGINS; do
            echo "Updating $plugin"

            install_source=$(echo "$plugin" | cut -d'/' -f1,2)
            install_command=$(echo "$plugin" | cut -d'/' -f3-)
            install_location=$GH_SOURCE_install_location/$(basename $install_source)
            
            install_command=${install_command//\{\}/$install_location)}
            [ -d "$install_location" ] && \
                    git --git-dir $install_location/.git --work-tree $install_location pull && \
                    git --git-dir $install_location/.git --work-tree $install_location reset --hard --quiet
        done
        echo "Done updating"
        return
    }
    [ "$1" = "--list" ] && {
        echo $PLUGINS | tr ' ' '\n'
        return
    }
    export PLUGINS="$PLUGINS $1"
    GH_SOURCE_install_location=${GH_SOURCE_INSTALL_LOCATION:-$HOME/Github}

    install_source=$(echo "$1" | cut -d'/' -f1,2)
    install_command=${2:-"source {}/$(echo "$1" | cut -d'/' -f3-)"}
    install_location=${3:-$GH_SOURCE_install_location/$(basename $install_source)}
    
    install_command=${install_command//\{\}/$install_location}
    
    [ -d "$install_location" ] || gh repo clone $install_source $install_location &>/dev/null
    set --
    eval $install_command
}

# add shell completion to zsh FPATH
if [ ! -z "$ZSH_VERSION" ]; then
    export FPATH=$FPATH:$(dirname $0)/zsh-completion
fi
