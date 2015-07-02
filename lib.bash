set -u
set -e
set -o pipefail

declare -r NL=$'\n'

selfdir="$(dirname "$0")"

dserver_eth_wan=enp2s0
dserver_eth_lan=enp4s0

dserver_bridge=macvlan0

mac_drouter_wan=52:54:00:54:6e:dd
mac_drouter_lan=52:54:00:54:6e:de
mac_kino=52:54:00:54:6e:ef
mac_mc=52:54:00:54:6e:f0

ip_kino=192.168.2.9
ip_drouter=192.168.2.8
ip_mc=192.168.2.7

dserver_port_forwards=(
    "tcp:9092:$ip_kino"
    "tcp:51413:$ip_kino"
    "udp:51413:$ip_kino"
)

ssh_pubkey_igor="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINuRT02EgmvQdI96X/qGdUCCSUbTHlvRiHuF0BKpNhch igor@localhost.localdomain$NL"
ssh_pubkey_lubava="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKGV+r2T/Mf9QrEsupuxwWMv2UtLYgD3rjBQG/W5Dfxo lubava@localhost.localdomain$NL"

kino_ssh_port=9092
autofs_ssh_known_hosts="/var/local/sshfs_known_hosts"


tmp_files=()

cleanup() {
    if [[ ${#tmp_files[@]} -ge 1 ]]; then
	rm -rf "${tmp_files[@]}"
    fi
}

trap cleanup EXIT

err() {
    printf 'Error: %s\n' "$*" 1>&2
    exit 1
}

usage_err() {
    echo "$0: $@" 1>&2
    echo "Try $0 -h for usage" 1>&2
    exit 1
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

# mkdir -p -m mode path does not apply mode to the intermediate
# directories it creates.
ensure_dir() {
    local mode=755 OPTIND opt dir

    while getopts m: opt; do
	case "$opt" in
	    m ) mode="$OPTARG";;
	    * ) err "bad ensure_dir usage";;
	esac
    done
    shift $(($OPTIND - 1))
    [[ $# -ge 1 ]] || err "ensure_dir - missing dir argument"
    [[ $# -le 2 ]] || err "ensure_dir - too many arguments"
    dir="$1"
    if [[ ! -d "$dir" ]]; then
	ensure_dir -m "$mode" "$(dirname "$dir")"
	mkdir -m "$mode" "$dir"
    fi
}

file_update=0
file_update_count=0

write_file() {
    local owner=root:root mode=644 log_message="updating %s"
    local -i exec_cmd=0
    local OPTIND opt path body dir

    file_update=0
    while getopts el:m:o: opt; do
	case "$opt" in
	    e ) let exec_cmd=1;;
	    l ) log_message="$OPTARG";;
	    m ) mode="$OPTARG";;
	    o ) owner="$OPTARG";;
	    * ) err "bad write_file usage";;
	esac
    done

    shift $(($OPTIND - 1))
    let "$#>=1" || err "write_file - missing path argument"
    if let exec_cmd; then
	let "$#>=2" || err "write_file - -e option requires command argument"
    else
	let "$#<=2" || err "write_file - too many arguments"
    fi

    path="$1"
    shift

    # Use base64 to support arbitrary binary data
    if let "$#==0"; then
	body="$(base64 -w0)"
    elif let exec_cmd; then
	body="$("$@" | base64 -w0)"
    else
	body="$(printf %s "$1" | base64 -w0)"
    fi

    while true; do
	if [[ ! -f "$path" || -L "$path" ]]; then
	    break;
	fi
	if [[ "$(stat -c %U:%G:%a "$path")" != "${owner}:${mode}" ]]; then
	    break;
	fi

	if [[ "$body" != "$(base64 -w0 "$path")" ]]; then
	    break;
	fi

	# No need to write anything
	return
    done

    if let ${#log_message}; then
	log "$(printf "$log_message" "$path")"
    fi

    ensure_dir "$(dirname "$path")"

    # Use temporary to ensure atomic operation on filesystem
    get_temp "$path"
    base64 -d <<< "$body" > "$tmp"
    chmod "$mode" "$tmp"
    chown "$owner" "$tmp"
    mv -f "$tmp" "$path"

    file_update=1
    let file_update_count+=1
}

remove_file() {
    local log_message="removing %s"
    local OPTIND opt

    file_update=0
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
    let file_update_count+=1
}

run_remotely() {
    local host="$1"
    shift

    # I need to send the directory and allow to use terminal to ask
    # for password or secreets. So just emebedd the archive into the
    # command as base64 and ensure that ssh allocates tty.
    local data="$(tar -C "$selfdir" --exclude .git --exclude README.md --exclude LICENSE -czf - . | base64 -w0)"
    ssh ${SSH_ARGS-} -t "$remote" "rm -rf /tmp/tliset && mkdir /tmp/tliset && printf %s $data | base64 -d | tar -C /tmp/tliset -xzf - && /tmp/tliset/$(basename "$0") $*"
    exit
}
