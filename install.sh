#!/bin/sh

set -u
set -e

self="$(dirname $0)"
ssh_config=/etc/ssh/ssh_config
auto_master=/etc/auto.master.d/tliset.autofs
set_etc=/etc/tliset
set_key_dir="$set_etc/ssh_keys"
auto_map="$set_etc/automap"
ssh_known_hosts="/var/local/sshfs_known_hosts"
sshfs_timeout=60
mount_dir=/set

install=
uninstall=
show_usage=
dry_run=

loop_mount_dirs() {
    test $# -ge 1 || err "loop_mount_dirs requires an argument"
    "$@" bergenrabbit-photo www.hippyru.net bergenrabbit.net /www/site/hippy.ru/html
    "$@" hippy.ru www.hippyru.net hippy.ru /www/site/hippy.ru/html
    "$@" lubava.info www.hippyru.net lubava.info /www/site/lubava.info/html
    "$@" rkino rkino user /user
    test dserver = "$(hostname -s)" || "$@" kino dserver kino /set/kino
}

err() {
    echo "$0: $@" 1>&2
    exit 1
}

usage_err() {
    echo "$0: $@" 1>&2
    echo "Try $0 -h for usage" 1>&2
    exit 1
}

dump_seperator() {
    if test -n "$dry_run"; then
	echo "-----------------------------------------------------------------"
    fi
}

log() {
    if test -n "$dry_run"; then
	echo "$@"
    else
	echo "$@" 1>&2
    fi
}

cmd() {
    local cmd
    cmd="$1"
    shift
    dump_seperator
    log "cmd $cmd $@"
    if test -z "$dry_run"; then
	"$cmd" "$@"
    fi
}

rm_if_empty_dir() {
    local dir
    dir="$1"
    if test -d "$dir"; then
	cmd rmdir --ignore-fail-on-non-empty "$dir"
    else
	dump_seperator
	log "skip rmdir: !test -d $dir"
    fi
}

rm_if_exists() {
    local file
    file="$1"
    if test -e "$file"; then
	cmd rm "$file"
    else
	dump_seperator
	log "skip rm: !test -e $file"
    fi
}

new_file() {
    local mode path
    mode="$1"
    path="$2"
    rm_if_exists "$path"
    dump_seperator
    log "new_file $mode $path"
    if test -z "$dry_run"; then
	touch "$path"
	chmod "$mode" "$path"
    fi
}

add_line() {
    local path text
    path="$1"
    text="$2"
    if test -n "$dry_run"; then
	echo "$text"
    else
	echo "$text" >> "$path"
    fi
}

add_sshfs_dir() {
    local dir host user remote_dir s

    dir="$1"
    host="$2"
    user="$3"
    remote_dir="$4"

    s="-fstype=fuse.sshfs,"
    s="${s}rw,nodev,nosuid,noatime,allow_other,nonempty,"
    s="${s}max_read=65536,reconnect,intr,"
    s="${s}workaround=all,transform_symlinks,follow_symlinks,"
    s="${s}uid=\$UID,gid=\$GID,"
    s="${s}IdentityFile=\$HOME/.ssh/id_rsa,"
    s="${s}IdentityFile=\$HOME/.ssh/id_ed25519,"
    s="${s}IdentityFile=$set_key_dir/$dir,"
    s="${s}ServerAliveInterval=5,ServerAliveCountMax=2,"
    s="${s}StrictHostKeyChecking=no,"
    s="${s}UserKnownHostsFile=$ssh_known_hosts,"
    s="${s}ControlPath=none"
    add_line "$auto_map" "$mount_dir/$dir $s ${user}@${host}:$remote_dir"
}

do_install() {
    if test -f "$ssh_config.orig"; then
	cmd mv "$ssh_config" "$ssh_config.orig"
    fi
    cmd install -m 755 -d "$set_etc" "$set_key_dir" "$mount_dir"
    cmd install -m 644 -T "$self/ssh_config" "$ssh_config"

    new_file 644 "$auto_master"
    add_line "$auto_master" "/- file:$auto_map --timeout=$sshfs_timeout"

    new_file 644 "$auto_map"
    loop_mount_dirs add_sshfs_dir

    new_file 644 "$ssh_known_hosts"

    cmd systemctl restart autofs
}

remove_mount_dir() {
    # $2-$4 are ignored
    rm_if_empty_dir "$mount_dir/$1"
}

do_uninstall() {
    local i
    if test -f "$ssh_config.orig"; then
	cmd mv -f "$ssh_config.orig" "$ssh_config"
    fi
    rm_if_exists "$auto_map"
    rm_if_exists "$auto_master"
    rm_if_empty_dir "$set_key_dir"
    rm_if_empty_dir "$set_etc"

    cmd systemctl restart autofs

    rm_if_exists "$ssh_known_hosts"
    loop_mount_dirs remove_mount_dir
    rm_if_empty_dir "$mount_dir"
}

while getopts :dihu opt; do
    case "$opt" in
	d ) dry_run=1 ;;
	i ) install=1 ;;
	h ) show_usage=1 ;;
	u ) uninstall=1 ;;
	/? ) usage_err "option -$OPTARG requires an argument" ;;
	* ) usage_err "unknown -$OPTARG option" ;;
    esac
done
shift $(($OPTIND - 1))

test $# -eq 0 || usage_err "Unexpected extra arguments: $@"

if test -n "$show_usage"; then
    echo "Usage: $0 [OPTION]..."
    echo "Install or uninstall automount config for the home network."
    echo
    echo "  -d  dump to stdout actions to be performed without changing anything"
    echo "  -h  show this help and exit"
    echo "  -i  install automount config"
    echo "  -u  uninstall automount config"
    echo
    echo "If neither -i nor -u is given, behave as if run with -i -d. If both -u and -i are given, run uninstall and then install."
    exit
fi

if test -z "$install" -a -z "$uninstall"; then
    dry_run=1
    install=1
fi

if test -n "$uninstall"; then
    do_uninstall
fi

if test -n "$install"; then
    do_install
fi
