set -u
set -e
set -o pipefail

declare -r NL=$'\n'

selfdir="$(dirname "$0")"
tmp_files=()

dserver_eth_wan=enp2s0
dserver_eth_lan=enp4s0

mac_drouter_wan=52:54:00:54:6e:dd
mac_drouter_lan=52:54:00:54:6e:de
mac_kino=52:54:00:54:6e:ef
ip_kino=192.168.2.9

ssh_pubkey_igor="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINuRT02EgmvQdI96X/qGdUCCSUbTHlvRiHuF0BKpNhch igor@localhost.localdomain$NL"
ssh_pubkey_lubava="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKGV+r2T/Mf9QrEsupuxwWMv2UtLYgD3rjBQG/W5Dfxo lubava@localhost.localdomain$NL"

cleanup() {
    if [[ ${#tmp_files[@]} -ge 1 ]]; then
	rm -f "${tmp_files[@]}"
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

file_update=''
file_update_count=0

write_file() {
    local before_write="" owner=root:root mode=644 log_message=""
    local -i exec_cmd=0 log_message_default=1
    local OPTIND opt path body dir

    file_update=''
    while getopts b:el:m:o: opt; do
	case "$opt" in
	    b ) before_write="$OPTARG";;
	    e ) let exec_cmd=1;;
	    l ) log_message="$OPTARG"; log_message_default=0;;
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
	log "$log_message"
    fi
    if let log_message_default; then
	log "updating $path"
    fi

    if let ${#before_write}; then
	"$before_write" "$path"
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
    local log_message="" log_message_default=""
    local OPTIND opt

    file_update=''
    while getopts Ll: opt; do
	case "$opt" in
	    L ) log_message_default=1;;
	    l ) log_message="$OPTARG";;
	    * ) err "bad remove_file usage";;
	esac
    done

    shift $(($OPTIND - 1))
    [[ $# -ge 1 ]] || err "remove_file - missing path argument"
    [[ $# -le 2 ]] || err "remove_file - too many arguments"
    [[ -z "$log_message" || -z "$log_message_default" ]] || \
	err "remove_file - only one of -l , -L can be given"

    local path="$1"
    shift

    if [[ ! -e "$path" ]]; then
	return
    fi

    if [[ -n "$log_message" ]]; then
	log "$log_message"
    fi
    if [[ -n "$log_message_default" ]]; then
	log "removing $path"
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
