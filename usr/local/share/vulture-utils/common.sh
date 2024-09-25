#!/usr/bin/env sh

COLOR_RESET='\033[0m'
COLOR_RED='\033[0;31m'
COLOR_YELLOW="\033[1;33m"
COLOR_GREEN="\033[0;32m"
TEXT_BLINK='\033[5m'

SNAPSHOT_PREFIX="VLT_"

JAILS_LIST="apache haproxy mongodb portal redis rsyslog"

AVAILABLE_DATASET_TYPES="SYSTEM JAIL DB HOMES TMPVAR"
SYSTEM_DATASETS="ROOT/$(/sbin/mount -l | /usr/bin/grep "on / " | /usr/bin/cut -d ' ' -f 1 | /usr/bin/cut -d / -f 3)"
JAIL_DATASETS="apache apache/var apache/usr portal portal/var portal/usr haproxy haproxy/var haproxy/usr mongodb mongodb/var mongodb/usr redis redis/var redis/usr rsyslog rsyslog/var rsyslog/usr"
DB_DATASETS="mongodb/var/db"
HOMES_DATASETS="usr/home"
TMPVAR_DATASETS="apache/var/log portal/var/log haproxy/var/log mongodb/var/log redis/var/log rsyslog/var/log tmp var/audit var/cache var/crash var/log var/tmp"
# 'usr' and 'var' are set to nomount, so they don't hold any data (data is held by the root dataset)
export AVAILABLE_DATASET_TYPES SYSTEM_DATASETS JAIL_DATASETS DB_DATASETS HOMES_DATASETS TMPVAR_DATASETS

# If "NO_COLOR" environment variable is present, or we aren't speaking to a
# tty, disable output colors.
if [ -n "${NO_COLOR}" ] || [ ! -t 1 ]; then
    COLOR_RESET=''
    COLOR_RED=''
    COLOR_YELLOW=''
    TEXT_BLINK=''
fi

info() {
    /usr/bin/printf "${COLOR_GREEN}$*${COLOR_RESET}\n"
}

warn() {
    /usr/bin/printf "${COLOR_YELLOW}$*${COLOR_RESET}\n"
}

error() {
    /usr/bin/printf "${COLOR_RED}$*${COLOR_RESET}\n" 1>&2
}

error_and_exit() {
    /usr/bin/printf "${COLOR_RED}$*${COLOR_RESET}\n" 1>&2
    exit 1
}

error_and_blink() {
    /usr/bin/printf "${COLOR_RED}${TEXT_BLINK}$*${COLOR_RESET}\n" 1>&2
}

######################
## System functions ##
######################
exec_mongo() {
    local _command="$1"
    local _hostname="$(hostname)"

    if ! /usr/sbin/jls | /usr/bin/grep -q mongodb; then
        return 1
    fi
    if [ -z "$_hostname" ] || [ -z "${_command}" ]; then
        return 1
    fi

    /usr/sbin/jexec mongodb mongo --ssl --sslCAFile /var/db/pki/ca.pem --sslPEMKeyFile /var/db/pki/node.pem "${_hostname}:9091" -eval "${_command}"
    return $?
}

add_to_motd() {
    if [ -f /var/run/motd ]; then
        /usr/bin/printf "$1\n" >> /var/run/motd
    fi
}

reset_motd() {
    /usr/sbin/service motd restart
}

get_jail_list() {
    echo "${JAILS_LIST}"
}

has_upgraded_kernel() {
    if [ "$(/usr/bin/uname -U)" -eq "$(/usr/bin/uname -K)" ]; then
        return 0
    else
        /usr/bin/sed -i '' '/Upgrade:/d' /var/run/motd
        error_and_blink "Upgrade: the system has a pending kernel/userland upgrade, please restart your machine to apply!" | /usr/bin/tee -a /var/run/motd
        return 1
    fi
}

#################
## hbsd-update ##
#################

download_system_update() {
    local _temp_dir="$1"
    local _use_dnssec="$2"
    local _system_version="$3"
    local _jail="$4"

    local _options=""

    if [ -f /usr/sbin/hbsd-update ] ; then
        if [ -n "$_jail" ] ; then
            if [ -d /.jail_system ]; then
                # upgrade base jail_system root with local hbsd-update.conf (for "thin" jails)
                _options="-n -r /.jail_system/"
            else
                # use -j flag from hbsd-update to let it handle upgrade of "full" jail
                _options="-n -j $_jail"
            fi
        fi
        if [ $_use_dnssec -eq 0 ]; then _options="${_options} -d"; fi
        if [ -n "$_system_version" ]; then
            # Add -U as non-last update versions cannot be verified
            echo "[!] Custom version of system update selected, this version will be installed without signature verification!"
            _options="${_options} -v $_system_version -U"
        fi
        if [ ! -f "${_temp_dir}/update.tar" ]; then
            # Store (-t) and keep (-T) downloads to ${_temp_dir} for later use
            # Do not install update yet (-f)
            /usr/sbin/hbsd-update -t "${_temp_dir}" -T -f $_options
        fi
        if [ $? -ne 0 ] ; then return 1 ; fi
    else
        error_and_exit "[!] Cannot upgrade FreeBSD systems, need HardenedBSD!"
    fi
}

update_jail_system() {
    local _jail="$1"
    local _temp_dir="$2"
    local _resolve_strategy="$3"
    local _system_version="$4"

    local _options=""

    if [ -f /usr/sbin/hbsd-update ] ; then
        # If a jail is specified, execute update in it
        if [ -n "$_jail" ] ; then
            if [ -d /.jail_system ]; then
                # upgrade base jail_system root with local hbsd-update.conf (for "thin" jails)
                _options="-n -r /.jail_system/"
            else
                # use -j flag from hbsd-update to let it handle upgrade of "full" jail
                _options="-n -j $_jail"
            fi
        fi
        if [ -n "$_system_version" ]; then
            # Add -U as non-last update versions cannot be verified
            echo "[!] Custom version of system update selected, this version will be installed without signature verification!"
            _options="${_options} -v $_system_version -U"
        fi
        # Store (-t) and keep (-T) downloads to ${_temp_dir} for later use
        # Previous download should be present in the '{_temp_dir}' folder already
        if [ -n "$_resolve_strategy" ] ; then
            # echo resolve strategy to hbsd-update for non-interactive resolution of conflicts in /etc/ via etcupdate
            /usr/bin/yes "$_resolve_strategy" | /usr/sbin/hbsd-update -d -t "${_temp_dir}" -T -D $_options
        else
            /usr/sbin/hbsd-update -d -t "${_temp_dir}" -T -D $_options
        fi
        if [ $? -ne 0 ] ; then return 1 ; fi
    else
        error_and_exit "[!] Cannot upgrade FreeBSD systems, need HardenedBSD!"
    fi
}

update_system() {
    local _temp_dir="$1"
    local _snapshot_system="$2"
    local _keep_previous_snap="$3"
    local _resolve_strategy="$4"
    local _system_version="$5"

    local _mountpoint="$(mktemp -d -p ${_temp_dir})"
    local _options=""

    if [ -f /usr/sbin/hbsd-update ] ; then
        if [ -n "${_system_version}" ]; then
            # Add -U as non-last update versions cannot be verified
            echo "[!] Custom version of system update selected, this version will be installed without signature verification!"
            _options="${_options} -v ${_system_version} -U"
        fi
        if [ "${_snapshot_system}" -gt 0 ]; then
            /sbin/bectl create "${_snap_name}" || finalize 1 "Could not create a new Boot Environment!"
            clean_old_BEs "${_keep_previous_snap}"
            /sbin/bectl mount "${_snap_name}" "${_mountpoint}" || finalize 1 "Could not mount new Boot Environement!"
            warn "[!] New BE has been created! System will need to be restarted!"
            _options="${_options} -r ${_mountpoint}"
        fi
        # Store (-t) and keep (-T) downloads to ${_temp_dir} for later use
        # Previous download should be present in the '{_temp_dir}' folder already
        if [ -n "${_resolve_strategy}" ] ; then
            # echo resolve strategy to hbsd-update for non-interactive resolution of conflicts in /etc/ via etcupdate
            /usr/bin/yes "${_resolve_strategy}" | /usr/sbin/hbsd-update -d -t "${_temp_dir}" -T -D $_options
        else
            /usr/sbin/hbsd-update -d -t "${_temp_dir}" -T -D $_options
        fi
        if [ $? -ne 0 ] ; then return 1 ; fi
    else
        error_and_exit "[!] Cannot upgrade FreeBSD systems, need HardenedBSD!"
    fi
}


###################
## Miscellaneous ##
###################
sublist() {
    local _object_list="$1"
    local _index_start="${2:-1}"
    local _index_stop="${3:-$(/bin/echo "$_object_list" | /usr/bin/wc -w | /usr/bin/xargs)}"
    local _delimiter="${4:- }"

    if [ -n "${_index_start}" ] && [ "${_index_start}" -gt "${_index_stop}" ]; then
        return 0
    fi

    /bin/echo "$_object_list" | /usr/bin/cut -d "${_delimiter}" -f "${_index_start}-${_index_stop}"
    return $((_index_stop - _index_start + 1))
}

contains() {
    local _list="$1"
    local _elem_in_list="$2"

    if echo "${_list}" | grep -q "${_elem_in_list}"; then
        return 0
    else
        return 1
    fi
}

################################
## Boot Environment functions ##
################################
list_unused_BEs() {
    # Order BEs (ordered, most recent first)
    /sbin/bectl list -H -Ccreation |\
    while read -r _name _status _rest; do
        if /bin/echo "${_name}" | /usr/bin/grep -q "${SNAPSHOT_PREFIX}"; then
            # filter out any BE that could be N, R, T or a combination of those (man bectl)
            if [ "${_status}" = "-" ]; then
                /usr/bin/printf "%s " "${_name}"
                # _deletable_BEs="${_deletable_BEs} ${_name}"
            fi
        fi
    done
}

has_pending_BE() {
    local _temp_be_search="$(/sbin/bectl list -H | cut -f 2 | grep -F 'T')"
    local _stable_be_search="$(/sbin/bectl list -H | cut -f 2 | grep -E '(RN|NR)')"

    if [ -z "${_temp_be_search}" ] && [ -n "${_stable_be_search}" ]; then
        return 0
    else
        sed -i '' '/Upgrade:/d' /var/run/motd
        error_and_blink "Upgrade: the system has a pending new Boot Environment, please restart your machine to apply!" | tee -a /var/run/motd
        return 1
    fi
}

clean_old_BEs() {
    local _number_to_keep="$1"
    local _deletable_BEs="$(list_unused_BEs)"

    if [ "${_number_to_keep}" -ne "${_number_to_keep}" ]; then
        return 1
    fi

    _to_delete="$(sublist "${_deletable_BEs}" $((_number_to_keep+1)))"
    for _be in $_to_delete; do
        /bin/echo "Destroying old BE: '${_be}'"
        /sbin/bectl destroy -o "$_be"
    done
}


############################
## Snapshotting functions ##
############################
get_root_zpool_name() {
    /sbin/mount -l | /usr/bin/grep "on / " | /usr/bin/cut -d / -f 1
}

snapshot_datasets() {
    local _datasets="$1"
    local _snapshot_name="$2"
    local _zpool="$(get_root_zpool_name)"

    if [ -z "${_datasets}" ] || [ -z "${_snapshot_name}" ]; then
        return 1
    fi

    for dataset in ${_datasets}; do
        /sbin/zfs snap "${_zpool}/${dataset}@${_snapshot_name}"
    done
}

list_snapshots() {
    local _dataset="$1"
    local _zpool="$(get_root_zpool_name)"

    if [ -z "${_dataset}" ]; then
        return 1
    fi

    # List snapshot names only, ordering by descending order (most recent first)
    /sbin/zfs list -H -tsnap -oname -Screation "${_zpool}/${_dataset}" |\
        # Get snapshot name part (remove dataset part)
        /usr/bin/cut -d '@' -f 2 |\
        # filter out snapshot not created by scripts
        /usr/bin/grep -E "^${SNAPSHOT_PREFIX}.*" |\
        # remove leading/trailing whitespaces and return a single string with elements separated by a space
        /usr/bin/xargs
}

clean_previous_snapshots() {
    local _datasets="$1"
    local _number_to_keep="$2"
    local _zpool="$(get_root_zpool_name)"

    # arguments are mandatory
    if [ -z "${_datasets}" ] || [ -z "${_number_to_keep}" ]; then
        return 1
    fi
    # _number_to_keep should be a number
    if [ "${_number_to_keep}" -ne "${_number_to_keep}" ]; then
        return 1
    fi

    for _dataset in ${_datasets}; do
        # most recent are first in list
        _ordered_snapshots="$(list_snapshots "${_dataset}")"

        # List index begins at 1, so remove from the next element to the last
        _snaps_to_remove="$(sublist "${_ordered_snapshots}" "$((_number_to_keep+1))")"
        for _snap in $_snaps_to_remove; do
            /bin/echo "removing snapshot '${_zpool}/${_dataset}@${_snap}'"
            /sbin/zfs destroy "${_zpool}/${_dataset}@${_snap}"
        done
    done
}


###########################
## Rollbacking functions ##
###########################
tag_snapshots_for_rollback() {
    local _datasets="$1"
    local _snapshot="$2"
    local _zpool="$(get_root_zpool_name)"

    # arguments are mandatory
    if [ -z "${_datasets}" ] || [ -z "${_snapshot}" ]; then
        return 1
    fi
    for _dataset in ${_datasets}; do
        echo "will rollback to ${_zpool}/${_dataset}@${_snapshot}"
        /sbin/zfs set snapshot:restore=YES "${_zpool}/${_dataset}@${_snapshot}"
    done
}

list_pending_rollbacks() {
    local _dataset="$1"
    local _zpool="$(get_root_zpool_name)"
    local _snap_name=""

    # argument is mandatory
    if [ -z "${_dataset}" ]; then
        return 1
    fi

    zfs list -tsnap -o name,snapshot:restore "${_zpool}/${_dataset}" 2>/dev/null |\
    while read -r _name _status; do
        if [ "${_status}" = "YES" ]; then
            _snap_name=$(echo "${_name}" | cut -d @ -f 2)
            /usr/bin/printf "%s " "${_snap_name}"
        fi
    done
}

clean_rollback_state_on_datasets() {
    local _datasets="$1"
    local _zpool="$(get_root_zpool_name)"

    # argument is mandatory
    if [ -z "${_datasets}" ]; then
        return 1
    fi

    for _dataset in ${_datasets}; do
        _snapshot_list="$(list_pending_rollbacks "${_dataset}")"
        for _snapshot in ${_snapshot_list}; do
            echo "Resetting rollback state for ${_dataset}"
            /sbin/zfs inherit snapshot:restore "${_zpool}/${_dataset}@${_snapshot}"
        done
    done
}
