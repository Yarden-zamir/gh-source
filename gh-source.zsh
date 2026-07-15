if [[ -z ${ZSH_VERSION-} ]]; then
  printf 'gh-source requires Zsh\n' >&2
  return 1
fi

typeset -ga GH_SOURCE_LOADED_SOURCE_ORDER
typeset -gA GH_SOURCE_LOADED_SOURCES GH_SOURCE_REPOSITORY_CHECKOUTS GH_SOURCE_VALIDATED_CHECKOUTS

_gh_source_error() {
  print -u2 -r -- "gh-source: $*"
  return 1
}

_gh_source_normalize_relative_path() {
  builtin emulate -L zsh
  local relative_path=$1 segment
  local -a segments
  [[ -n $relative_path && $relative_path != /* ]] || return 1
  for segment in ${(s:/:)relative_path}; do
    [[ -n $segment && $segment != .. ]] || return 1
    [[ $segment == . ]] || segments+=("$segment")
  done
  REPLY=${(j:/:)segments}
  [[ -n $REPLY ]] || REPLY=.
}

_gh_source_parse_spec() {
  builtin emulate -L zsh
  local spec=$1 owner repository_and_path repository source_file=''
  [[ -n $spec && $spec == */* ]] || {
    _gh_source_error "invalid repository specification: $spec"
    return 1
  }
  owner=${spec%%/*}
  repository_and_path=${spec#*/}
  repository=${repository_and_path%%/*}
  [[ -n $owner && -n $repository && $owner != . && $owner != .. && $repository != . && $repository != .. ]] || {
    _gh_source_error "invalid repository specification: $spec"
    return 1
  }
  if [[ $repository_and_path != $repository ]]; then
    source_file=${repository_and_path#*/}
    _gh_source_normalize_relative_path "$source_file" || {
      _gh_source_error "invalid source path: $source_file"
      return 1
    }
    source_file=$REPLY
  fi
  reply=("$owner" "$repository" "$source_file")
}

# Read Git metadata directly to avoid spawning git during shell startup.
_gh_source_git_config_path() {
  builtin emulate -L zsh
  local checkout=$1 git_directory git_file_line common_directory
  if [[ -d $checkout/.git ]]; then
    REPLY=$checkout/.git/config
    [[ -f $REPLY ]]
    return
  fi
  [[ -f $checkout/.git ]] || return 1
  IFS= read -r git_file_line < "$checkout/.git" || return 1
  [[ $git_file_line == 'gitdir: '* ]] || return 1
  git_directory=${git_file_line#gitdir: }
  [[ $git_directory == /* ]] || git_directory=$checkout/$git_directory
  git_directory=${git_directory:A}
  if [[ -f $git_directory/commondir ]]; then
    IFS= read -r common_directory < "$git_directory/commondir" || return 1
    [[ $common_directory == /* ]] || common_directory=$git_directory/$common_directory
    REPLY=${common_directory:A}/config
  else
    REPLY=$git_directory/config
  fi
  [[ -f $REPLY ]]
}

_gh_source_origin_from_config() {
  builtin emulate -L zsh
  builtin setopt extendedglob
  local config_path=$1 config_line section='' origin_url
  while IFS= read -r config_line; do
    config_line=${config_line##[[:space:]]#}
    config_line=${config_line%%[[:space:]]#}
    if [[ $config_line == \[*\] ]]; then
      section=$config_line
      continue
    fi
    [[ $section == '[remote "origin"]' && $config_line == url[[:space:]]#=* ]] || continue
    origin_url=${config_line#*=}
    origin_url=${origin_url##[[:space:]]#}
    origin_url=${origin_url%%[[:space:]]#}
    [[ $origin_url == \"*\" ]] && origin_url=${origin_url[2,-2]}
    REPLY=$origin_url
    return 0
  done < "$config_path"
  return 1
}

_gh_source_normalize_origin() {
  builtin emulate -L zsh
  local url=${1%.git} identity
  url=${url%/}
  case $url in
    https://github.com/*) identity=${url#https://github.com/} ;;
    git@github.com:*) identity=${url#git@github.com:} ;;
    *) return 1 ;;
  esac
  [[ $identity == */* ]] || return 1
  REPLY=${(L)identity}
}

_gh_source_validate_checkout_origin() {
  builtin emulate -L zsh
  local checkout=${1:A} expected_identity=${(L)2}
  local cached_identity=${GH_SOURCE_VALIDATED_CHECKOUTS[$checkout]-} config_path origin_url
  if [[ -n $cached_identity ]]; then
    [[ $cached_identity == $expected_identity ]] || {
      _gh_source_error "$checkout belongs to $cached_identity, not $expected_identity"
      return 1
    }
    return 0
  fi
  _gh_source_git_config_path "$checkout" || {
    _gh_source_error "not a Git checkout: $checkout"
    return 1
  }
  config_path=$REPLY
  _gh_source_origin_from_config "$config_path" || {
    _gh_source_error "cannot read the origin for $checkout"
    return 1
  }
  origin_url=$REPLY
  _gh_source_normalize_origin "$origin_url" || {
    _gh_source_error "origin is not a GitHub repository: $origin_url"
    return 1
  }
  [[ $REPLY == $expected_identity ]] || {
    _gh_source_error "$checkout belongs to $REPLY, not $expected_identity"
    return 1
  }
  GH_SOURCE_VALIDATED_CHECKOUTS[$checkout]=$expected_identity
}

_gh_source_clone_repository() {
  builtin emulate -L zsh
  local repository_identity=$1 storage_path=$2
  [[ ! -e $storage_path ]] || return 0
  command -v gh >/dev/null 2>&1 || {
    _gh_source_error 'gh is required to clone repositories'
    return 1
  }
  command mkdir -p -- "${storage_path:h}" || return 1
  print -u2 -r -- "Cloning $repository_identity to $storage_path"
  command gh repo clone "$repository_identity" "$storage_path" >&2 || {
    command rm -rf -- "$storage_path"
    _gh_source_error "failed to clone $repository_identity"
    return 1
  }
  [[ -e $storage_path/.git ]] || {
    command rm -rf -- "$storage_path"
    _gh_source_error "clone did not create a checkout at $storage_path"
    return 1
  }
}

_gh_source_find_checkout_candidates() {
  builtin emulate -L zsh
  local storage_path=$1 head_line primary_branch worktree_name checkout
  reply=()
  [[ -e $storage_path/.git ]] && reply+=("${storage_path:A}")
  if [[ -f $storage_path/.bare/HEAD ]] && IFS= read -r head_line < "$storage_path/.bare/HEAD" &&
    [[ $head_line == 'ref: refs/heads/'* ]]; then
    primary_branch=${head_line#ref: refs/heads/}
    worktree_name=${primary_branch:t}
  else
    worktree_name=main
  fi
  checkout=$storage_path/$worktree_name
  if [[ -e $checkout/.git ]]; then
    checkout=${checkout:A}
    [[ ${reply[(Ie)$checkout]} -gt 0 ]] || reply+=("$checkout")
  fi
  checkout=$storage_path/main
  if [[ $worktree_name != main && -e $checkout/.git ]]; then
    checkout=${checkout:A}
    [[ ${reply[(Ie)$checkout]} -gt 0 ]] || reply+=("$checkout")
  fi
}

# Populates the reserved _ghs_* activation state declared by gh_source.
_gh_source_prepare_activation() {
  builtin emulate -L zsh
  local spec=$1 owner repository shorthand_source storage_path checkout relative_path attempted_sources
  local needs_discovery=1 candidate_complete=0
  local -a checkout_candidates conventional_sources
  shift
  _gh_source_parse_spec "$spec" || return 1
  owner=$reply[1]
  repository=$reply[2]
  shorthand_source=$reply[3]
  _ghs_repository_identity=$owner/$repository
  _ghs_repository_key=${(L)_ghs_repository_identity}
  if [[ -n $shorthand_source ]]; then
    _ghs_source_files+=("$shorthand_source")
    needs_discovery=0
  fi
  while (( $# > 0 )); do
    case $1 in
      --source|--path|--fpath)
        (( $# >= 2 )) || {
          _gh_source_error "$1 requires a relative path"
          return 1
        }
        _gh_source_normalize_relative_path "$2" || {
          _gh_source_error "invalid relative path: $2"
          return 1
        }
        case $1 in
          --source) _ghs_source_files+=("$REPLY") ;;
          --path) _ghs_path_directories+=("$REPLY") ;;
          --fpath) _ghs_function_directories+=("$REPLY") ;;
        esac
        needs_discovery=0
        shift 2
        ;;
      --preserve-zsh-options) _ghs_preserve_options=1; shift ;;
      --skip-build-if-present)
        (( $# >= 2 )) || {
          _gh_source_error '--skip-build-if-present requires a value'
          return 1
        }
        _ghs_build_predicates+=("$2")
        shift 2
        ;;
      --build)
        shift
        (( $# > 0 )) || {
          _gh_source_error '--build requires a command'
          return 1
        }
        _ghs_build_command=("$@")
        needs_discovery=0
        set --
        ;;
      *)
        _gh_source_error "unknown action: $1"
        return 1
        ;;
    esac
  done
  if (( ${#_ghs_build_command} > 0 && ${#_ghs_build_predicates} == 0 )); then
    _gh_source_error '--build requires at least one --skip-build-if-present'
    return 1
  fi
  if (( ${#_ghs_build_command} == 0 && ${#_ghs_build_predicates} > 0 )); then
    _gh_source_error '--skip-build-if-present requires --build'
    return 1
  fi
  _ghs_storage_root=${_ghs_storage_root:A}
  storage_path=$_ghs_storage_root/$repository
  _gh_source_clone_repository "$_ghs_repository_identity" "$storage_path" || return 1
  _gh_source_find_checkout_candidates "$storage_path"
  checkout_candidates=("${reply[@]}")
  (( ${#checkout_candidates} > 0 )) || {
    _gh_source_error "no usable checkout found for $_ghs_repository_identity"
    return 1
  }
  if (( needs_discovery )); then
    conventional_sources=("$repository.plugin.zsh" "$repository.zsh" init.zsh)
    # Conventional filename priority intentionally takes precedence over checkout priority.
    for relative_path in "${conventional_sources[@]}"; do
      for checkout in "${checkout_candidates[@]}"; do
        _gh_source_validate_checkout_origin "$checkout" "$_ghs_repository_identity" || return 1
        if [[ -f $checkout/$relative_path && -r $checkout/$relative_path ]]; then
          _ghs_checkout_root=$checkout
          _ghs_source_files=("$relative_path")
          break 2
        fi
      done
    done
    if [[ -z $_ghs_checkout_root ]]; then
      attempted_sources=${(j:, :)conventional_sources}
      _gh_source_error "no conventional source found for $_ghs_repository_identity; tried: $attempted_sources"
      return 1
    fi
    return 0
  fi
  for checkout in "${checkout_candidates[@]}"; do
    _gh_source_validate_checkout_origin "$checkout" "$_ghs_repository_identity" || return 1
    candidate_complete=1
    for relative_path in "${_ghs_source_files[@]}"; do
      if [[ ! -f $checkout/$relative_path || ! -r $checkout/$relative_path ]]; then
        candidate_complete=0
        break
      fi
    done
    if (( candidate_complete )); then
      for relative_path in "${_ghs_path_directories[@]}" "${_ghs_function_directories[@]}"; do
        if [[ -n $relative_path && ! -d $checkout/$relative_path ]]; then
          candidate_complete=0
          break
        fi
      done
    fi
    if (( candidate_complete )); then
      _ghs_checkout_root=$checkout
      return 0
    fi
  done
  _gh_source_error "no checkout for $_ghs_repository_identity contains every declared resource"
}

_gh_source_build_predicate_satisfied() {
  local checkout_root=$1 predicate=$2
  [[ -f $checkout_root/$predicate ]] || command -v -- "$predicate" >/dev/null 2>&1
}

_gh_source_shorthand_is_loaded() {
  builtin emulate -L zsh
  local source_spec=$1 source_key
  _gh_source_parse_spec "$source_spec" >/dev/null 2>&1 || return 1
  [[ -n $reply[3] ]] || return 1
  source_key=${(L)reply[1]}/${(L)reply[2]}/$reply[3]
  [[ -n ${GH_SOURCE_LOADED_SOURCES[$source_key]-} ]]
}

_gh_source_source_files() {
  local _ghs_preserve_options=$1 _ghs_checkout_root=$2 _ghs_caller_directory=$3
  shift 3
  local -a _ghs_source_files=("$@")
  local _ghs_source_file _ghs_status=0
  # Ordinary sources inherit caller options; preservation creates one local scope for the group.
  if (( _ghs_preserve_options )); then
    builtin zmodload -F zsh/parameter p:options 2>/dev/null || {
      _gh_source_error 'cannot load the Zsh options parameter'
      return 1
    }
    builtin setopt localoptions
    local -hA options
  fi
  {
    for _ghs_source_file in "${_ghs_source_files[@]}"; do
      set --
      {
        if builtin source "$_ghs_checkout_root/$_ghs_source_file"; then
          _ghs_status=0
        else
          _ghs_status=$?
        fi
      } always {
        builtin cd -q -- "$_ghs_caller_directory"
      }
      (( _ghs_status == 0 )) || break
    done
  } always {
    # A sourced `emulate` can disable LOCAL_OPTIONS; re-enable it to restore caller state.
    (( _ghs_preserve_options )) && builtin setopt localoptions
    builtin cd -q -- "$_ghs_caller_directory"
  }
  return $_ghs_status
}

_gh_source_activation_is_loaded() {
  builtin emulate -L zsh
  local activation_spec=$1 repository_key source_key
  local -a spec_parts
  _gh_source_parse_spec "$activation_spec" >/dev/null 2>&1 || return 1
  spec_parts=("${reply[@]}")
  repository_key=${(L)spec_parts[1]}/${(L)spec_parts[2]}
  if [[ -z $spec_parts[3] ]]; then
    [[ -n ${GH_SOURCE_REPOSITORY_CHECKOUTS[$repository_key]-} ]]
    return
  fi
  source_key=$repository_key/$spec_parts[3]
  [[ -n ${GH_SOURCE_LOADED_SOURCES[$source_key]-} ]]
}

_gh_source_update() {
  builtin emulate -L zsh
  local checkout_root changes update_status=0
  local -A updated_roots
  command -v git >/dev/null 2>&1 || {
    _gh_source_error 'git is required to update repositories'
    return 1
  }
  for checkout_root in "${(@v)GH_SOURCE_REPOSITORY_CHECKOUTS}"; do
    [[ -n ${updated_roots[$checkout_root]-} ]] && continue
    updated_roots[$checkout_root]=1
    changes=$(command git -C "$checkout_root" status --porcelain --untracked-files=normal 2>&1) || {
      print -u2 -r -- "gh-source: cannot inspect $checkout_root: $changes"
      update_status=1
      continue
    }
    if [[ -n $changes ]]; then
      print -u2 -r -- "gh-source: refusing to update dirty checkout: $checkout_root"
      update_status=1
      continue
    fi
    print -u2 -r -- "Updating $checkout_root"
    command git -C "$checkout_root" pull --ff-only >&2 || update_status=1
  done
  return $update_status
}

_gh_source_help() {
  print -r -- 'Usage:
  gh_source owner/repo[/file.zsh] [actions]
  gh_source --loaded owner/repo[/file.zsh] | --list | --update
Actions: --source, --path, --fpath, --preserve-zsh-options,
  --skip-build-if-present, --build
See Readme.md for action arguments and examples.'
}

gh_source() {
  if (( $# == 0 )); then
    _gh_source_help
    return 0
  fi
  case $1 in
    --help)
      (( $# == 1 )) || { _gh_source_error '--help does not accept arguments'; return 1; }
      _gh_source_help
      return
      ;;
    --list)
      (( $# == 1 )) || { _gh_source_error '--list does not accept arguments'; return 1; }
      print -rl -- "${GH_SOURCE_LOADED_SOURCE_ORDER[@]}"
      return
      ;;
    --loaded)
      (( $# == 2 )) || { _gh_source_error '--loaded requires one repository or source'; return 1; }
      _gh_source_activation_is_loaded "$2"
      return
      ;;
    --update)
      (( $# == 1 )) || { _gh_source_error '--update does not accept arguments'; return 1; }
      _gh_source_update
      return
      ;;
    --*)
      _gh_source_error "unknown command: $1"
      return 1
      ;;
  esac
  # A lone loaded source shorthand can skip repository planning entirely.
  (( $# == 1 )) && _gh_source_shorthand_is_loaded "$1" && return 0

  local _ghs_storage_root=${GH_SOURCE_ROOT:-$HOME/Github}
  local _ghs_repository_identity _ghs_repository_key _ghs_checkout_root
  local _ghs_preserve_options=0 _ghs_source_file _ghs_source_key _ghs_status=0
  local _ghs_directory _ghs_absolute_directory
  local -a _ghs_source_files _ghs_path_directories _ghs_function_directories
  local -a _ghs_build_predicates _ghs_build_command _ghs_pending_sources _ghs_function_path_prepend
  local -A _ghs_seen_sources
  local _ghs_caller_directory=$PWD

  _gh_source_prepare_activation "$@" || return 1

  if (( ${#_ghs_build_command[@]} > 0 )); then
    local _ghs_build_not_needed=0 _ghs_build_verified=0 _ghs_build_predicate
    for _ghs_build_predicate in "${_ghs_build_predicates[@]}"; do
      if _gh_source_build_predicate_satisfied "$_ghs_checkout_root" "$_ghs_build_predicate"; then
        _ghs_build_not_needed=1
        break
      fi
    done
    if (( !_ghs_build_not_needed )); then
      (
        builtin cd -q -- "$_ghs_checkout_root" || exit 1
        export GH_SOURCE_DIR=$_ghs_checkout_root
        export GH_SOURCE_REPO=$_ghs_repository_identity
        export GH_SOURCE_REPO_NAME=${_ghs_repository_identity#*/}
        command "${_ghs_build_command[@]}"
      ) >&2
      _ghs_status=$?
      (( _ghs_status == 0 )) || return $_ghs_status
      for _ghs_build_predicate in "${_ghs_build_predicates[@]}"; do
        if _gh_source_build_predicate_satisfied "$_ghs_checkout_root" "$_ghs_build_predicate"; then
          _ghs_build_verified=1
          break
        fi
      done
      (( _ghs_build_verified )) || {
        _gh_source_error 'build succeeded but no presence predicate became true'
        return 1
      }
    fi
  fi

  if (( ${#_ghs_path_directories} )); then
    for _ghs_directory in "${_ghs_path_directories[@]}"; do
      _ghs_absolute_directory=$_ghs_checkout_root/$_ghs_directory
      path+=("${_ghs_absolute_directory:A}")
    done
    typeset -gU path
  fi
  if (( ${#_ghs_function_directories} )); then
    for _ghs_directory in "${_ghs_function_directories[@]}"; do
      _ghs_absolute_directory=$_ghs_checkout_root/$_ghs_directory
      _ghs_function_path_prepend+=("${_ghs_absolute_directory:A}")
    done
    fpath=("${_ghs_function_path_prepend[@]}" "${fpath[@]}")
    typeset -gU fpath
  fi

  for _ghs_source_file in "${_ghs_source_files[@]}"; do
    _ghs_source_key=$_ghs_repository_key/$_ghs_source_file
    [[ -n ${_ghs_seen_sources[$_ghs_source_key]-} ]] && continue
    _ghs_seen_sources[$_ghs_source_key]=1
    if [[ -z ${GH_SOURCE_LOADED_SOURCES[$_ghs_source_key]-} ]]; then
      _ghs_pending_sources+=("$_ghs_source_file")
    fi
  done
  if (( ${#_ghs_pending_sources[@]} > 0 )); then
    _gh_source_source_files \
      "$_ghs_preserve_options" \
      "$_ghs_checkout_root" \
      "$_ghs_caller_directory" \
      "${_ghs_pending_sources[@]}"
    _ghs_status=$?
    builtin cd -q -- "$_ghs_caller_directory" || return 1
    (( _ghs_status == 0 )) || return $_ghs_status
  fi
  for _ghs_source_file in "${_ghs_pending_sources[@]}"; do
    _ghs_source_key=$_ghs_repository_key/$_ghs_source_file
    if [[ -z ${GH_SOURCE_LOADED_SOURCES[$_ghs_source_key]-} ]]; then
      GH_SOURCE_LOADED_SOURCE_ORDER+=("$_ghs_repository_identity/$_ghs_source_file")
    fi
    GH_SOURCE_LOADED_SOURCES[$_ghs_source_key]=$_ghs_checkout_root/$_ghs_source_file
  done
  GH_SOURCE_REPOSITORY_CHECKOUTS[$_ghs_repository_key]=${_ghs_checkout_root:A}
}

() {
  builtin emulate -L zsh
  local completion_dir=${${(%):-%x}:A:h}/zsh-completion
  [[ ${fpath[(Ie)$completion_dir]} -gt 0 ]] || fpath+=("$completion_dir")
}
