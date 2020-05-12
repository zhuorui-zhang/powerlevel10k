# Bash bindings for gitstatus.

[[ $- == *i* ]] || return  # non-interactive shell

# Starts gitstatusd in the background. Does nothing and succeeds if gitstatusd
# is already running.
#
# Usage: gitstatus_start [OPTION]...
#
#   -t FLOAT  Fail the self-check on initialization if not getting a response from
#             gitstatusd for this this many seconds. Defaults to 5.
#
#   -s INT    Report at most this many staged changes; negative value means infinity.
#             Defaults to 1.
#
#   -u INT    Report at most this many unstaged changes; negative value means infinity.
#             Defaults to 1.
#
#   -c INT    Report at most this many conflicted changes; negative value means infinity.
#             Defaults to 1.
#
#   -d INT    Report at most this many untracked files; negative value means infinity.
#             Defaults to 1.
#
#   -m INT    Report -1 unstaged, untracked and conflicted if there are more than this many
#             files in the index. Negative value means infinity. Defaults to -1.
#
#   -e        Count files within untracked directories like `git status --untracked-files`.
#
#   -U        Unless this option is specified, report zero untracked files for repositories
#             with status.showUntrackedFiles = false.
#
#   -W        Unless this option is specified, report zero untracked files for repositories
#             with bash.showUntrackedFiles = false.
#
#   -D        Unless this option is specified, report zero staged, unstaged and conflicted
#             changes for repositories with bash.showDirtyState = false.
function gitstatus_start() {
  unset OPTIND
  local opt timeout=5 max_dirty=-1 extra_flags
  local max_num_staged=1 max_num_unstaged=1 max_num_conflicted=1 max_num_untracked=1
  local ignore_status_show_untracked_files
  while getopts "t:s:u:c:d:m:eUWD" opt; do
    case "$opt" in
      t) timeout=$OPTARG;;
      s) max_num_staged=$OPTARG;;
      u) max_num_unstaged=$OPTARG;;
      c) max_num_conflicted=$OPTARG;;
      d) max_num_untracked=$OPTARG;;
      m) max_dirty=$OPTARG;;
      e) extra_flags+='--recurse-untracked-dirs ';;
      U) extra_flags+='--ignore-status-show-untracked-files ';;
      W) extra_flags+='--ignore-bash-show-untracked-files ';;
      D) extra_flags+='--ignore-bash-show-dirty-state ';;
      *) return 1;;
    esac
  done

  (( OPTIND == $# + 1 )) || { echo "usage: gitstatus_start [OPTION]..." >&2; return 1; }

  [[ -z "${GITSTATUS_DAEMON_PID:-}" ]] || return 0  # already started

  if [[ "${BASH_SOURCE[0]}" == */* ]]; then
    local gitstatus_plugin_dir="${BASH_SOURCE[0]%/*}"
    if [[ "$gitstatus_plugin_dir" != /* ]]; then
      gitstatus_plugin_dir="$PWD"/"$gitstatus_plugin_dir"
    fi
  else
    local gitstatus_plugin_dir="$PWD"
  fi

  local req_fifo resp_fifo

  function gitstatus_start_impl() {
    local log_level="${GITSTATUS_LOG_LEVEL:-}"
    [[ -n "$log_level" || "${GITSTATUS_ENABLE_LOGGING:-0}" != 1 ]] || log_level=INFO

    local uname_sm
    uname_sm="$(uname -sm)" || return
    uname_sm="${uname_sm,,}"
    local uname_s="${uname_sm% *}"
    local uname_m="${uname_sm#* }"

    if [[ "${GITSTATUS_NUM_THREADS:-0}" -gt 0 ]]; then
      local threads="$GITSTATUS_NUM_THREADS"
    else
      local cpus
      if ! command -v sysctl &>/dev/null || [[ "$uname_s" == linux ]] ||
         ! cpus="$(sysctl -n hw.ncpu)"; then
        if ! command -v getconf &>/dev/null || ! cpus="$(getconf _NPROCESSORS_ONLN)"; then
          cpus=8
        fi
      fi
      local threads=$((cpus > 16 ? 32 : cpus > 0 ? 2 * cpus : 16))
    fi

    local daemon_args=(
      --parent-pid="$$"
      --num-threads="$threads"
      --max-num-staged="$max_num_staged"
      --max-num-unstaged="$max_num_unstaged"
      --max-num-conflicted="$max_num_conflicted"
      --max-num-untracked="$max_num_untracked"
      --dirty-max-index-size="$max_dirty"
      $extra_flags)

    if [[ -n "$log_level" ]]; then
      GITSTATUS_DAEMON_LOG=$(mktemp "${TMPDIR:-/tmp}"/gitstatus.$$.log.XXXXXXXXXX) || return
      [[ "$log_level" == INFO ]] || daemon_args+=(--log-level="$log_level")
    else
      GITSTATUS_DAEMON_LOG=/dev/null
    fi

    req_fifo=$(mktemp -u "${TMPDIR:-/tmp}"/gitstatus.$$.pipe.req.XXXXXXXXXX)   || return
    resp_fifo=$(mktemp -u "${TMPDIR:-/tmp}"/gitstatus.$$.pipe.resp.XXXXXXXXXX) || return
    mkfifo "$req_fifo" "$resp_fifo"                                            || return

    {
      (
        trap '' INT
        [[ "$GITSTATUS_DAEMON_LOG" == /dev/null ]] || set -x
        builtin cd /

        (
          local fd_in fd_out
          exec {fd_in}<"$req_fifo" {fd_out}>"$resp_fifo" || exit
          echo "$BASHPID" >&"$fd_out"

          local _gitstatus_bash_daemon _gitstatus_bash_version _gitstatus_bash_downloaded

          function _gitstatus_set_daemon() {
            _gitstatus_bash_daemon="$1"
            _gitstatus_bash_version="$2"
            _gitstatus_bash_downloaded="$3"
          }

          set -- -d "$gitstatus_plugin_dir" -s "$uname_s" -m "$uname_m" \
            -p "printf '.\036' >&$fd_out" -- _gitstatus_set_daemon
          [[ "${GITSTATUS_AUTO_INSTALL:-1}" -ne 0 ]]  || set -- -n "$@"
          source "$gitstatus_plugin_dir"/install      || return
          [[ -n "$_gitstatus_bash_daemon" ]]          || return
          [[ -n "$_gitstatus_bash_version" ]]         || return
          [[ "$_gitstatus_bash_downloaded" == [01] ]] || return

          local sig=(QUIT TERM EXIT ILL PIPE)

          if [[ -x "$_gitstatus_bash_daemon" ]]; then
            "$_gitstatus_bash_daemon" \
              -G "$_gitstatus_bash_version" "${daemon_args[@]}" <&"$fd_in" >&"$fd_out" &
            local pid=$!
            trap "trap - ${sig[*]}; kill $pid &>/dev/null" ${sig[@]}
            wait "$pid"
            local ret=$?
            trap - ${sig[@]}
            case "$ret" in
              0|129|130|131|137|141|143)
                echo -nE $'bye\x1f0\x1e' >&"$fd_out"
                exit "$ret"
              ;;
            esac
          fi

          (( ! _gitstatus_bash_downloaded ))         || return
          [[ "${GITSTATUS_AUTO_INSTALL:-1}" -ne 0 ]] || return
          set -- -f "$@"
          _gitstatus_bash_daemon=
          _gitstatus_bash_version=
          _gitstatus_bash_downloaded=
          source "$gitstatus_plugin_dir"/install  || return
          [[ -n "$_gitstatus_bash_daemon" ]]       || return
          [[ -n "$_gitstatus_bash_version" ]]      || return
          [[ "$_gitstatus_bash_downloaded" == 1 ]] || return

          "$_gitstatus_bash_daemon" \
            -G "$_gitstatus_bash_version" "${daemon_args[@]}" <&"$fd_in" >&"$fd_out" &
          local pid=$!
          trap "trap - ${sig[*]}; kill $pid &>/dev/null" ${sig[@]}
          wait "$pid"
          trap - ${sig[@]}
          echo -nE $'bye\x1f0\x1e' >&"$fd_out"
        ) & disown
      ) & disown
    } 0</dev/null &>$GITSTATUS_DAEMON_LOG

    exec {_GITSTATUS_REQ_FD}>"$req_fifo" {_GITSTATUS_RESP_FD}<"$resp_fifo" || return
    command rm "$req_fifo" "$resp_fifo"                                    || return

    IFS='' read -r -u $_GITSTATUS_RESP_FD GITSTATUS_DAEMON_PID || return
    [[ $GITSTATUS_DAEMON_PID == [1-9]* ]] || return

    local reply
    echo -nE $'hello\x1f\x1e' >&$_GITSTATUS_REQ_FD                     || return
    local dl=
    while true; do
      IFS='' read -rd $'\x1e' -u $_GITSTATUS_RESP_FD -t "$timeout" reply || return
      [[ "$reply" == $'hello\x1f0' ]] && break
      [[ "$reply" == . ]] || return
      if [[ -z "$dl" ]]; then
        dl=1
        if [[ -t 2 ]]; then
          local spinner=('\b\033[33m-\033[0m' '\b\033[33m\\\033[0m' '\b\033[33m|\033[0m' '\b\033[33m/\033[0m')
          >&2 printf '[\033[33mgitstatus\033[0m] fetching \033[32mgitstatusd\033[0m ..  '
        else
          local spinner=('.')
          >&2 printf '[gitstatus] fetching gitstatusd ..'
        fi
      fi
      >&2 printf "${spinner[0]}"
      spinner=("${spinner[@]:1}" "${spinner[0]}")
    done

    if [[ -n "$dl" ]]; then
      if [[ -t 2 ]]; then
        >&2 printf '\b[\033[32mok\033[0m]\n'
      else
        >&2 echo ' [ok]'
      fi
    fi

    _GITSTATUS_DIRTY_MAX_INDEX_SIZE=$max_dirty
    _GITSTATUS_CLIENT_PID="$BASHPID"
  }

  if ! gitstatus_start_impl; then
    echo "gitstatus_start: failed to start gitstatusd" >&2
    [[ -z "${req_fifo:-}"  ]] || command rm -f "$req_fifo"
    [[ -z "${resp_fifo:-}" ]] || command rm -f "$resp_fifo"
    unset -f gitstatus_start_impl
    gitstatus_stop
    return 1
  fi

  unset -f gitstatus_start_impl

  if [[ "${GITSTATUS_STOP_ON_EXEC:-1}" == 1 ]]; then
    type -t _gitstatus_exec &>/dev/null    || function _gitstatus_exec()    { exec    "$@"; }
    type -t _gitstatus_builtin &>/dev/null || function _gitstatus_builtin() { builtin "$@"; }

    function _gitstatus_exec_wrapper() {
      (( ! $# )) || gitstatus_stop
      local ret=0
      _gitstatus_exec "$@" || ret=$?
      [[ -n "${GITSTATUS_DAEMON_PID:-}" ]] || gitstatus_start || true
      return $ret
    }

    function _gitstatus_builtin_wrapper() {
      while [[ "${1:-}" == builtin ]]; do shift; done
      if [[ "${1:-}" == exec ]]; then
        _gitstatus_exec_wrapper "${@:2}"
      else
        _gitstatus_builtin "$@"
      fi
    }

    alias exec=_gitstatus_exec_wrapper
    alias builtin=_gitstatus_builtin_wrapper

    _GITSTATUS_EXEC_HOOK=1
  else
    unset _GITSTATUS_EXEC_HOOK
  fi
}

# Stops gitstatusd if it's running.
function gitstatus_stop() {
  [[ "${_GITSTATUS_CLIENT_PID:-$BASHPID}" == "$BASHPID" ]]                         || return 0
  [[ -z "${_GITSTATUS_REQ_FD:-}"    ]] || exec {_GITSTATUS_REQ_FD}>&-              || true
  [[ -z "${_GITSTATUS_RESP_FD:-}"   ]] || exec {_GITSTATUS_RESP_FD}>&-             || true
  [[ -z "${GITSTATUS_DAEMON_PID:-}" ]] || kill "$GITSTATUS_DAEMON_PID" &>/dev/null || true
  if [[ -n "${_GITSTATUS_EXEC_HOOK:-}" ]]; then
    unalias exec builtin &>/dev/null || true
    function _gitstatus_exec_wrapper()    { _gitstatus_exec    "$@"; }
    function _gitstatus_builtin_wrapper() { _gitstatus_builtin "$@"; }
  fi
  unset _GITSTATUS_REQ_FD _GITSTATUS_RESP_FD GITSTATUS_DAEMON_PID _GITSTATUS_EXEC_HOOK
  unset _GITSTATUS_DIRTY_MAX_INDEX_SIZE _GITSTATUS_CLIENT_PID
}

# Retrives status of a git repository from a directory under its working tree.
#
# Usage: gitstatus_query [OPTION]...
#
#   -d STR    Directory to query. Defaults to $PWD. Has no effect if GIT_DIR is set.
#   -t FLOAT  Timeout in seconds. Will block for at most this long. If no results
#             are available by then, will return error.
#   -p        Don't compute anything that requires reading Git index. If this option is used,
#             the following parameters will be 0: VCS_STATUS_INDEX_SIZE,
#             VCS_STATUS_{NUM,HAS}_{STAGED,UNSTAGED,UNTRACKED,CONFLICTED}.
#
# On success sets VCS_STATUS_RESULT to one of the following values:
#
#   norepo-sync  The directory doesn't belong to a git repository.
#   ok-sync      The directory belongs to a git repository.
#
# If VCS_STATUS_RESULT is ok-sync, additional variables are set:
#
#   VCS_STATUS_WORKDIR              Git repo working directory. Not empty.
#   VCS_STATUS_COMMIT               Commit hash that HEAD is pointing to. Either 40 hex digits or
#                                   empty if there is no HEAD (empty repo).
#   VCS_STATUS_LOCAL_BRANCH         Local branch name or empty if not on a branch.
#   VCS_STATUS_REMOTE_NAME          The remote name, e.g. "upstream" or "origin".
#   VCS_STATUS_REMOTE_BRANCH        Upstream branch name. Can be empty.
#   VCS_STATUS_REMOTE_URL           Remote URL. Can be empty.
#   VCS_STATUS_ACTION               Repository state, A.K.A. action. Can be empty.
#   VCS_STATUS_INDEX_SIZE           The number of files in the index.
#   VCS_STATUS_NUM_STAGED           The number of staged changes.
#   VCS_STATUS_NUM_CONFLICTED       The number of conflicted changes.
#   VCS_STATUS_NUM_UNSTAGED         The number of unstaged changes.
#   VCS_STATUS_NUM_UNTRACKED        The number of untracked files.
#   VCS_STATUS_HAS_STAGED           1 if there are staged changes, 0 otherwise.
#   VCS_STATUS_HAS_CONFLICTED       1 if there are conflicted changes, 0 otherwise.
#   VCS_STATUS_HAS_UNSTAGED         1 if there are unstaged changes, 0 if there aren't, -1 if
#                                   unknown.
#   VCS_STATUS_NUM_STAGED_NEW       The number of staged new files. Note that renamed files
#                                   are reported as deleted plus new.
#   VCS_STATUS_NUM_STAGED_DELETED   The number of staged deleted files. Note that renamed files
#                                   are reported as deleted plus new.
#   VCS_STATUS_NUM_UNSTAGED_DELETED The number of unstaged deleted files. Note that renamed files
#                                   are reported as deleted plus new.
#   VCS_STATUS_HAS_UNTRACKED        1 if there are untracked files, 0 if there aren't, -1 if
#                                   unknown.
#   VCS_STATUS_COMMITS_AHEAD        Number of commits the current branch is ahead of upstream.
#                                   Non-negative integer.
#   VCS_STATUS_COMMITS_BEHIND       Number of commits the current branch is behind upstream.
#                                   Non-negative integer.
#   VCS_STATUS_STASHES              Number of stashes. Non-negative integer.
#   VCS_STATUS_TAG                  The last tag (in lexicographical order) that points to the same
#                                   commit as HEAD.
#   VCS_STATUS_PUSH_REMOTE_NAME     The push remote name, e.g. "upstream" or "origin".
#   VCS_STATUS_PUSH_REMOTE_URL      Push remote URL. Can be empty.
#   VCS_STATUS_PUSH_COMMITS_AHEAD   Number of commits the current branch is ahead of push remote.
#                                   Non-negative integer.
#   VCS_STATUS_PUSH_COMMITS_BEHIND  Number of commits the current branch is behind push remote.
#                                   Non-negative integer.
#   VCS_STATUS_NUM_SKIP_WORKTREE    The number of files in the index with skip-worktree bit set.
#                                   Non-negative integer.
#   VCS_STATUS_NUM_ASSUME_UNCHANGED The number of files in the index with assume-unchanged bit set.
#                                   Non-negative integer.
#
# The point of reporting -1 via VCS_STATUS_HAS_* is to allow the command to skip scanning files in
# large repos. See -m flag of gitstatus_start.
#
# gitstatus_query returns an error if gitstatus_start hasn't been called in the same
# shell or the call had failed.
function gitstatus_query() {
  unset OPTIND
  local opt dir timeout=() no_diff=0
  while getopts "d:c:t:p" opt "$@"; do
    case "$opt" in
      d) dir=$OPTARG;;
      t) timeout=(-t "$OPTARG");;
      p) no_diff=1;;
      *) return 1;;
    esac
  done
  (( OPTIND == $# + 1 )) || { echo "usage: gitstatus_query [OPTION]..." >&2; return 1; }

  [[ -n "$GITSTATUS_DAEMON_PID" ]] || return  # not started

  local req_id="$RANDOM.$RANDOM.$RANDOM.$RANDOM"
  if [[ -z "${GIT_DIR:-}" ]]; then
    [[ "$dir" == /* ]] || dir="$(pwd -P)/$dir" || return
  elif [[ "$GIT_DIR" == /* ]]; then
    dir=:"$GIT_DIR"
  else
    dir=:"$(pwd -P)/$GIT_DIR" || return
  fi
  echo -nE "$req_id"$'\x1f'"$dir"$'\x1f'"$no_diff"$'\x1e' >&$_GITSTATUS_REQ_FD || return

  local -a resp
  while true; do
    IFS=$'\x1f' read -rd $'\x1e' -a resp -u $_GITSTATUS_RESP_FD "${timeout[@]}" || return
    [[ "${resp[0]}" == "$req_id" ]] && break
  done

  if [[ "${resp[1]}" == 1 ]]; then
    VCS_STATUS_RESULT=ok-sync
    VCS_STATUS_WORKDIR="${resp[2]}"
    VCS_STATUS_COMMIT="${resp[3]}"
    VCS_STATUS_LOCAL_BRANCH="${resp[4]}"
    VCS_STATUS_REMOTE_BRANCH="${resp[5]}"
    VCS_STATUS_REMOTE_NAME="${resp[6]}"
    VCS_STATUS_REMOTE_URL="${resp[7]}"
    VCS_STATUS_ACTION="${resp[8]}"
    VCS_STATUS_INDEX_SIZE="${resp[9]}"
    VCS_STATUS_NUM_STAGED="${resp[10]}"
    VCS_STATUS_NUM_UNSTAGED="${resp[11]}"
    VCS_STATUS_NUM_CONFLICTED="${resp[12]}"
    VCS_STATUS_NUM_UNTRACKED="${resp[13]}"
    VCS_STATUS_COMMITS_AHEAD="${resp[14]}"
    VCS_STATUS_COMMITS_BEHIND="${resp[15]}"
    VCS_STATUS_STASHES="${resp[16]}"
    VCS_STATUS_TAG="${resp[17]}"
    VCS_STATUS_NUM_UNSTAGED_DELETED="${resp[18]}"
    VCS_STATUS_NUM_STAGED_NEW="${resp[19]:-0}"
    VCS_STATUS_NUM_STAGED_DELETED="${resp[20]:-0}"
    VCS_STATUS_PUSH_REMOTE_NAME="${resp[21]:-}"
    VCS_STATUS_PUSH_REMOTE_URL="${resp[22]:-}"
    VCS_STATUS_PUSH_COMMITS_AHEAD="${resp[23]:-0}"
    VCS_STATUS_PUSH_COMMITS_BEHIND="${resp[24]:-0}"
    VCS_STATUS_NUM_SKIP_WORKTREE="${resp[25]:-0}"
    VCS_STATUS_NUM_ASSUME_UNCHANGED="${resp[26]:-0}"
    VCS_STATUS_HAS_STAGED=$((VCS_STATUS_NUM_STAGED > 0))
    if (( _GITSTATUS_DIRTY_MAX_INDEX_SIZE >= 0 &&
          VCS_STATUS_INDEX_SIZE > _GITSTATUS_DIRTY_MAX_INDEX_SIZE_ )); then
      VCS_STATUS_HAS_UNSTAGED=-1
      VCS_STATUS_HAS_CONFLICTED=-1
      VCS_STATUS_HAS_UNTRACKED=-1
    else
      VCS_STATUS_HAS_UNSTAGED=$((VCS_STATUS_NUM_UNSTAGED > 0))
      VCS_STATUS_HAS_CONFLICTED=$((VCS_STATUS_NUM_CONFLICTED > 0))
      VCS_STATUS_HAS_UNTRACKED=$((VCS_STATUS_NUM_UNTRACKED > 0))
    fi
  else
    VCS_STATUS_RESULT=norepo-sync
    unset VCS_STATUS_WORKDIR
    unset VCS_STATUS_COMMIT
    unset VCS_STATUS_LOCAL_BRANCH
    unset VCS_STATUS_REMOTE_BRANCH
    unset VCS_STATUS_REMOTE_NAME
    unset VCS_STATUS_REMOTE_URL
    unset VCS_STATUS_ACTION
    unset VCS_STATUS_INDEX_SIZE
    unset VCS_STATUS_NUM_STAGED
    unset VCS_STATUS_NUM_UNSTAGED
    unset VCS_STATUS_NUM_CONFLICTED
    unset VCS_STATUS_NUM_UNTRACKED
    unset VCS_STATUS_HAS_STAGED
    unset VCS_STATUS_HAS_UNSTAGED
    unset VCS_STATUS_HAS_CONFLICTED
    unset VCS_STATUS_HAS_UNTRACKED
    unset VCS_STATUS_COMMITS_AHEAD
    unset VCS_STATUS_COMMITS_BEHIND
    unset VCS_STATUS_STASHES
    unset VCS_STATUS_TAG
    unset VCS_STATUS_NUM_UNSTAGED_DELETED
    unset VCS_STATUS_NUM_STAGED_NEW
    unset VCS_STATUS_NUM_STAGED_DELETED
    unset VCS_STATUS_PUSH_REMOTE_NAME
    unset VCS_STATUS_PUSH_REMOTE_URL
    unset VCS_STATUS_PUSH_COMMITS_AHEAD
    unset VCS_STATUS_PUSH_COMMITS_BEHIND
    unset VCS_STATUS_NUM_SKIP_WORKTREE
    unset VCS_STATUS_NUM_ASSUME_UNCHANGED
  fi
}

# Usage: gitstatus_check.
#
# Returns 0 if and only if gitstatus_start has succeeded previously.
# If it returns non-zero, gitstatus_query is guaranteed to return non-zero.
function gitstatus_check() {
  [[ -n "$GITSTATUS_DAEMON_PID" ]]
}