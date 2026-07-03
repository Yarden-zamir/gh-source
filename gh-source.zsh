if [ ! -z "$ZSH_VERSION" ]; then
    typeset -ga GH_SOURCE_PLUGINS
fi

_gh_source_parse_plugin() {
    _gh_source_plugin=$1

    if [ -z "$_gh_source_plugin" ] || [ "$_gh_source_plugin" = "${_gh_source_plugin#*/}" ]; then
        echo "Invalid plugin: $_gh_source_plugin" >&2
        return 1
    fi

    _gh_source_owner=${_gh_source_plugin%%/*}
    _gh_source_rest=${_gh_source_plugin#*/}
    _gh_source_repo=${_gh_source_rest%%/*}

    if [ -z "$_gh_source_owner" ] || [ -z "$_gh_source_repo" ]; then
        echo "Invalid plugin: $_gh_source_plugin" >&2
        return 1
    fi

    _gh_source_install_source="$_gh_source_owner/$_gh_source_repo"
    if [ "$_gh_source_rest" = "$_gh_source_repo" ]; then
        _gh_source_plugin_path=""
    else
        _gh_source_plugin_path=${_gh_source_rest#*/}
    fi
}

_gh_source_register_plugin() {
    if [ ! -z "$ZSH_VERSION" ]; then
        GH_SOURCE_PLUGINS+=("$1")
    fi

    if [ -z "${PLUGINS-}" ]; then
        export PLUGINS="$1"
    else
        export PLUGINS="$PLUGINS $1"
    fi
}

_gh_source_require_plugin() {
    required_plugin=$1

    if [ -z "$required_plugin" ]; then
        echo "Required plugin not provided" >&2
        return 1
    fi

    if [ ! -z "$ZSH_VERSION" ]; then
        for plugin in "${GH_SOURCE_PLUGINS[@]}"; do
            [ "$plugin" = "$required_plugin" ] && return 0
            _gh_source_parse_plugin "$plugin" >/dev/null 2>&1 && [ "$_gh_source_install_source" = "$required_plugin" ] && return 0
        done
    else
        for plugin in $PLUGINS; do
            [ "$plugin" = "$required_plugin" ] && return 0
            _gh_source_parse_plugin "$plugin" >/dev/null 2>&1 && [ "$_gh_source_install_source" = "$required_plugin" ] && return 0
        done
    fi

    echo "Required plugin : $required_plugin not found" >&2
    return 1
}

_gh_source_list_plugins() {
    if [ ! -z "$ZSH_VERSION" ]; then
        for plugin in "${GH_SOURCE_PLUGINS[@]}"; do
            echo "$plugin"
        done
        return
    fi

    for plugin in $PLUGINS; do
        echo "$plugin"
    done
}

_gh_source_ensure_repo() {
    [ -d "$2" ] && return 0

    if ! type -p gh >/dev/null; then
        echo "gh not found on the system" >&2
        return 1
    fi

    echo "Cloning $1 to $2"
    gh auth status &>/dev/null || {
        echo "You need to authenticate with gh cli first" >&2
        return 1
    }

    gh repo clone "$1" "$2" &>/dev/null || {
        echo "Failed to clone $1 to $2" >&2
        return 1
    }

    [ -d "$2" ] || {
        echo "Clone reported success but $2 does not exist" >&2
        return 1
    }
}

gh_source() {
    [ -z "$1" ] || [ "$1" = "--help" ] && {
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
        echo "  --require: check if a plugin is installed, if not, exit with error code 1"
        echo "Arguments:"
        echo "  plugin: the plugin to source. If no install_command is passed, it will assume the last segment is the file to source (default install command)"
        echo "  install_command: the command to run after the plugin is installed. {} is replaced by install location"
        echo "  install_location: the location to install the plugin to (default: \$GH_SOURCE_INSTALL_LOCATION/<repo>)"
        return
    }
    [ "$1" = "--require" ] && {
        _gh_source_require_plugin "$2"
        return $?
    }
    [ "$1" = "--update" ] && {
        if ! type -p git >/dev/null; then
            echo "git not found on the system" >&2
            return 1
        fi

        GH_SOURCE_install_location=${GH_SOURCE_INSTALL_LOCATION:-$HOME/Github}

        if [ ! -z "$ZSH_VERSION" ]; then
            plugins=("${GH_SOURCE_PLUGINS[@]}")
        else
            plugins=($PLUGINS)
        fi

        for plugin in "${plugins[@]}"; do
            echo "Updating $plugin"

            _gh_source_parse_plugin "$plugin" || return 1
            install_location=$GH_SOURCE_install_location/$_gh_source_repo

            [ -d "$install_location" ] &&
                git --git-dir "$install_location"/.git --work-tree "$install_location" pull &&
                git --git-dir "$install_location"/.git --work-tree "$install_location" reset --hard --quiet
        done
        echo "Done updating"
        return
    }
    [ "$1" = "--list" ] && {
        _gh_source_list_plugins
        return
    }

    _gh_source_parse_plugin "$1" || return 1
    _gh_source_register_plugin "$1"
    GH_SOURCE_install_location=${GH_SOURCE_INSTALL_LOCATION:-$HOME/Github}

    install_location=${3:-$GH_SOURCE_install_location/$_gh_source_repo}

    _gh_source_ensure_repo "$_gh_source_install_source" "$install_location" || return 1

    if [ $# -ge 2 ] && [ ! -z "$2" ]; then
        install_command=${2//\{\}/$install_location}
        set --
        eval "$install_command"
        return $?
    fi

    if [ -z "$_gh_source_plugin_path" ]; then
        echo "No plugin path provided for $1 and no install command was passed" >&2
        return 1
    fi

    set --
    source "$install_location/$_gh_source_plugin_path"
}

gh-source() {
    gh_source "$@"
}

ghsource() {
    gh_source $@
}

ghs() {
    gh_source $@
}

# add shell completion to zsh FPATH # todo use official brew implementation
if [ ! -z "$ZSH_VERSION" ]; then
    _gh_source_script=${(%):-%x}
    export FPATH=$FPATH:${_gh_source_script:A:h}/zsh-completion
fi
