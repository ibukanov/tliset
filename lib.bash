set -u
set -e
set -o pipefail
shopt -s lastpipe

declare -r NL=$'\n'

selfdir="$(dirname "$0")"

dserver_eth_wan=enp2s0
dserver_eth_lan=enp4s0

dserver_bridge=macvlan0

mac_kino=52:54:00:54:6e:ef
mac_macbook_air=8c:29:37:e8:0e:e2
mac_tablet=34:23:ba:a4:0f:85

ip_kino=192.168.2.9
ip_drouter=192.168.2.8
ip_tablet=192.168.2.20
ip_macbook_air=192.168.2.21

dserver_port_forwards=(
    "tcp:9092:$ip_kino"
    "tcp:51413:$ip_kino"
    "udp:51413:$ip_kino"
    "tcp:25565:$ip_macbook_air"
    "udp:25565:$ip_macbook_air"
)

hippyru_www_pubkey="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIeBgbo19/jj/VDoX3nOybsmrbN95lIBeQYQv+FAOs/z"
media_pubkey="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILTrJnFcAg4qiYW8o8E0ieXc+hhnxc7ozAXlUAz1JHT6"
dzetacon_pubkey="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBGPGP6D7o3E3cl3gwx8Wa3XTAWOWeNAvcj2ZKY/OhbT"

readonly ssh_kino_wrap="/run/tliset/ssh_kino_wrap"
readonly kino_password_file="/var/lib/tliset/kino_password"

tmp_files=()

cleanup() {
    if [[ ${#tmp_files[@]} -ge 1 ]]; then
	rm -rf "${tmp_files[@]}"
    fi
}

trap cleanup EXIT

err() {
    printf '%s:%d:%s: %s\n' "${BASH_SOURCE[0]}" "${BASH_LINENO[0]}" "${FUNCNAME[0]}" "$*" >&2
    exit 1
}

usage_err() {
    echo "$0: $@" 1>&2
    echo "Try $0 -h for usage" 1>&2
    exit 1
}

getopts_err() {
    local name=$1 optarg=$2 msg
    case "$name" in
	: ) msg="$-optarg requires an argument" ;;
	\? ) msg="unknown option -$optarg" ;;
	* ) msg="-$name is listed in getopts arguments but not processed" ;;
    esac
    if let "${#FUNCNAME[@]} <= 2"; then
	usage_err "$msg"
    else
	err "${FUNCNAME[1]} - $msg"
    fi
}

log_indent_level=0

log() {
    local indent='' i
    for ((i=0; i<log_indent_level; i+=1)); do
	indent+='  '
    done
    printf '%s%s\n' "$indent" "$*" 1>&2
}

cmd_log() {
    log "$*"
    "$@"
}

inc_log_level() {
    let log_indent_level+=1 || true
}

dec_log_level() {
    [[ $log_indent_level -ge 1 ]] || err "dec_log_level without inc_log_level"
    let log_indent_level-=1 || true
}

get_temp() {
    if [[ $# -ge 1 ]]; then
	tmp="$(mktemp "$1.XXXXXXXXXX")"
    else
	tmp="$(mktemp)"
    fi
    tmp_files+=("$tmp")
}

ensure_dir() {
    local mode group user OPTIND opt dir
    mode=
    group=
    user=

    while getopts :g:m:u: opt; do
    case "$opt" in
    g ) group="$OPTARG";;
    m ) mode="$OPTARG";;
    u ) user="$OPTARG";;
    * ) err "bad ensure_dir usage";;
    esac
    done
    shift $(($OPTIND - 1))

    if test -z "${mode}"; then
	mode=0755
    fi
    if test -z "${user}"; then
	user=root
    fi
    if test -z "${group}"; then
	group="${user}"
    fi

    if test $# -eq 0; then
	return
    fi

    local dir
    for dir in "$@"; do
	test -n "${dir}" || err "directory cannot be empty"
	test "x${dir}" = "x${dir%/}" || err "directory must not end with slash - ${dir}"
	test "x${dir}" != "x${dir#/}" || err "directory must be an absolute path - ${dir}"
	if test ! -d "${dir}"; then
	    test ! -e "${dir}" && ! -h "${dir}"  || err "${dir} exists and is not a directory"
	    cmd_log mkdir -m "${mode}" "${dir}"
	else
	    test ! -h "${dir}" || \
		err "$path exists and is a symbilic link, not a directory - ${dir}"
	fi
	local s
	s="$(find "${dir}" -maxdepth 0 -perm "${mode}" -user "${user}" -group "${group}")"
	if test -z "${s}"; then
	    cmd_log chmod "=${mode}" "${dir}"
	    cmd_log chown "${user}:${group}" "${dir}"
	fi
    done
}

ensure_symlink() {
    local target="$1"
    local link_dir="$2"
    [[ $target ]] || err "link target cannot be empty"
    [[ -d "$link_dir" ]] || err "link directory $link_dir does not exist or is not a directory"

    local link_name="${3-}"
    if [[ -z $link_name ]]; then
	link_name="${target##*/}"
    fi
    local link_location="$link_dir/$link_name"
    if [[ -h "$link_location" ]]; then
	local current_target
	current_target="$(readlink -n "$link_location")"
	[[ $current_target == "$target" ]] && return
    fi
    if [[ -d "$link_location" ]]; then
	cmd_log rmdir "$link_location" || \
	    err "remove symbolic link location $link_location manually and run again"
    fi
    cmd_log ln -sfT "$target" "$link_location"
}

file_update=0
file_update_count=0

write_file() {

    local user group mode OPTIND opt
    user=
    group=
    mode=
    while getopts :g:m:u: opt; do
	case "$opt" in
	g ) group="$OPTARG";;
	m ) mode="$OPTARG";;
	u ) user="$OPTARG";;
	* ) err "bad write_file usage";;
	esac
    done

    shift $((${OPTIND} - 1))
    test $# -eq 2 || err "write_file requires path and body arguments when $# argument was given"

    local path body
    path="$1"
    body="$2"
    if test -z "${user}"; then
	user=root
    fi
    if test -z "${group}"; then
	group="${user}"
    fi
    if test -z "${mode}"; then
	mode=0644
    fi

    local wanted_umask need_chmod
    need_chmod=
    case "${mode}" in
    0644 ) wanted_umask=022 ;;
    0640 ) wanted_umask=027 ;;
    0600 ) wanted_umask=077 ;;
    0660 ) wanted_umask=007 ;;
    0755 ) wanted_umask=022 need_chmod=1 ;;
    * ) err "unsupported mode - ${mode}" ;;
    esac

    while :; do
	if test ! -f "${path}" -o -h "${path}"; then
	    log "creating new ${path}"
	    break;
	fi
	local s
	s="$(find "$path" -maxdepth 0 -perm "$mode" -user "$user" -group "$group" -printf 1)"
	if test -z "${s}"; then
	    log "updating ${path} - permission changes"
	    break;
	fi

	if printf %s "${body}" | cmp -s "${path}" -; then
	    # Permissions and text matches
	    file_update=
	    return
	fi

	log "updating ${path} - content changes"
	break
    done

    # Use temporary to ensure atomic operation on filesystem
    local tmp
    tmp="${path}.tmp"
    if test -f "${tmp}"; then
	rm "${tmp}"
    fi

    umask "${wanted_umask}"
    printf %s "${body}" > "${tmp}"
    if test -n "${need_chmod}"; then
	chmod "${mode}" "${tmp}"
    fi
    chown "${user}:${group}" "${tmp}"
    mv -fT "${tmp}" "${path}"

    file_update=1
    : $((file_update_count+=1))
}

remove_file() {
    local log_message="removing %s"
    local OPTIND opt

    file_update=
    while getopts l: opt; do
	case "$opt" in
	    l ) log_message="$OPTARG";;
	    * ) err "bad remove_file usage";;
	esac
    done

    shift $(($OPTIND - 1))
    [[ $# -ge 1 ]] || err "remove_file - missing path argument"
    [[ $# -le 2 ]] || err "remove_file - too many arguments"

    local path="$1"
    shift

    if [[ ! -e "$path" ]]; then
	return
    fi

    if let ${#log_message}; then
	log "$(printf "$log_message" "$path")"
    fi

    rm "$path"
    file_update=1
    : $((file_update_count+=1))
}

run_remotely() {
    local OPTIND opt ssh_user machine_host
    ssh_user=root
    machine_host=
    while getopts :m:u: opt; do
	case "$opt" in
	m ) machine_host="${OPTARG}";;
	u ) ssh_user="${OPTARG}";;
	* ) getopts_err "$opt" "${OPTARG-}";;
	esac
    done
    shift $(($OPTIND - 1))

    local target_host="$1"
    shift

    # I need to send the directory and allow to use terminal to ask
    # for password or secreets. So just emebedd the archive into the
    # command as base64 and ensure that ssh allocates tty.
    local data=$(tar -C "${selfdir}" --exclude .git --exclude README.md --exclude LICENSE -cf - . | gzip -9 | base64 -w0)

    local i cmd
    cmd=$(printf %q "/tmp/tliset/$(basename "$0")")
    for i in "$@"; do
	cmd+=" $(printf %q "$i")"
    done

    local cmd="rm -rf /tmp/tliset && mkdir /tmp/tliset && printf %s $data | base64 -d | tar -C /tmp/tliset -xzf - && $cmd"

    local wrapped_cmd
    if [[ ${machine_host} ]]; then
	wrapped_cmd="systemd-run -M ${target_host} --quiet --tty --wait"
	wrapped_cmd+=" /bin/bash -c $(printf %q "$cmd")"
	if [[ ${ssh_user} != root ]]; then
	    wrapped_cmd="sudo ${wrapped_cmd}"
	fi
	target_host="${machine_host}"
    elif [[ ${ssh_user} != root ]]; then
	wrapped_cmd="sudo /bin/bash -c $(printf %q "$cmd")"
    else
	wrapped_cmd="${cmd}"
    fi
    exec ssh -t "${ssh_user}@${target_host}" "${wrapped_cmd}"
}
