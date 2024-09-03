#!/usr/bin/env sh

. /usr/local/share/vulture-utils/common.sh

#############
# variables #
#############
snap_name="${SNAPSHOT_PREFIX}SNAP_$(date +%Y-%m-%dT%H:%M:%S)"
snap_SYSTEM=0
snap_JAIL=0
snap_DB=0
snap_HOMES=0
snap_TMPVAR=0
list_snaps=0
keep_previous_snap=-1
_mongo_locked=0

#############
# functions #
#############
usage() {
    echo "USAGE snapshot OPTIONS"
    echo "OPTIONS:"
    echo "	-A	Snapshot all underlying datasets"
    echo "	-S	Snapshot the system dataset(s)"
    echo "	-J	Snapshot the jail(s) dataset(s)"
    echo "	-H	Snapshot the home dataset(s)"
    echo "	-D	Snapshot the databases dataset(s)"
    echo "	-T	Snapshot the tmp/var dataset(s)"
    echo "	-l	Only list datasets"
    echo "	-k <num>	Keep <num> snapshots for the targeted datasets"
    exit 1
}


if [ "$(/usr/bin/id -u)" != "0" ]; then
    error "[!] This script must be run as root"
    exit 1
fi

while getopts 'hASJDHTlk:' opt; do
    case "${opt}" in
        A)  snap_SYSTEM=1;
            snap_JAIL=1;
            snap_DB=1;
            snap_HOMES=1;
            snap_TMPVAR=1;
            ;;
        S)  snap_SYSTEM=1;
            ;;
        J)  snap_JAIL=1;
            ;;
        D)  snap_DB=1;
            ;;
        H)  snap_HOMES=1;
            ;;
        T)  snap_TMPVAR=1;
            ;;
        l)  list_snaps=1;
            ;;
        k)  keep_previous_snap=${OPTARG};
            ;;
        h|*)  usage;
            ;;
    esac
done
shift $((OPTIND-1))

trap finalize SIGINT

finalize(){
    if [ "$_mongo_locked" -gt 0 ]; then
        exec_mongo "db.fsyncUnlock()" > /dev/null
        _mongo_locked=0
    fi
}

for _type in ${AVAILABLE_DATASET_TYPES}; do
    _type_datasets="$(eval 'echo "$'"$_type"'_DATASETS"')"
    _snapshot_list="$(list_snapshots "$(echo "${_type_datasets}" | cut -d ' ' -f1)")"

    # List snapshots
    if [ "${list_snaps}" -gt 0 ]; then
        printf "%s:\t" "${_type}"
        for _snap in $_snapshot_list; do
            printf "%s\t" "$_snap"
        done
        printf "\n"
    # snapshotting datasets
    else
        # Ignore datasets not explicitely selected
        if [ "$(eval 'echo "$snap_'"$_type"'"')" -lt 1 ]; then
            continue
        fi
        if [ "${snap_DB}" -gt 0 ] && [ "${_mongo_locked}" -eq 0 ]; then
            exec_mongo "db.fsyncLock()" > /dev/null
            _mongo_locked=1
        fi
        echo "making new snapshot for ${_type} datasets"
        snapshot_datasets "$_type_datasets" "$snap_name"
        if [ "$keep_previous_snap" -ge 0 ]; then
            echo "keeping only $keep_previous_snap version(s) for '${_type}' dataset(s)"
            clean_previous_snapshots "$_type_datasets" "$keep_previous_snap"
        fi
    fi
done

finalize
