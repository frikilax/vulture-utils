#!/usr/bin/env sh

. /usr/local/share/vulture/common.sh

#############
# variables #
#############
rollback_SYSTEM=0
rollback_JAIL=0
rollback_DB=0
rollback_HOMES=0
rollback_TMPVAR=0
clean_rollback_triggers=0
list_rollbacks=0
rollback_to=""
_need_restart=0

# 'usr' and 'var' are set to nomount, so they don't hold any data (data is held by the root dataset)

#############
# functions #
#############
usage() {
    echo "USAGE ${0} OPTIONS"
    echo "This stript triggers rollbacks on all or specific datasets, machine should then be restarted to apply the rollbacks"
    echo ""
    echo "OPTIONS:"
    echo "	-A	act on all underlying datasets"
    echo "	-S	act on the system dataset(s)"
    echo "	-J	act on the jail(s) dataset(s)"
    echo "	-H	act on the home dataset(s)"
    echo "	-D	act on the databases dataset(s)"
    echo "	-T	act on the tmp/var dataset(s)"
    echo "	-c	Reset selected dataset(s) rollback triggers"
    echo "	-l	List all datasets and their planned rollbacks"
    echo "	-r	<timestamp>	Select a custom timestamp to rollback to (snapshot should exist with that timestamp, you can get valid timestamps for every dataset with the 'snapshot.sh -l' command)"
    exit 1
}


if [ "$(/usr/bin/id -u)" != "0" ]; then
    error "[!] This script must be run as root"
    exit 1
fi

while getopts 'hASJHDTclr:' opt; do
    case "${opt}" in
        A)  rollback_SYSTEM=1;
            rollback_JAIL=1;
            rollback_DB=1;
            rollback_HOMES=1;
            rollback_TMPVAR=1;
            ;;
        S)  rollback_SYSTEM=1;
            ;;
        J)  rollback_JAIL=1;
            ;;
        D)  rollback_DB=1;
            ;;
        H)  rollback_HOMES=1;
            ;;
        T)  rollback_TMPVAR=1;
            ;;
        c)  clean_rollback_triggers=1;
            ;;
        l)  list_rollbacks=1;
            ;;
        r)  rollback_to=${OPTARG};
            ;;
        h|*)  usage;
            ;;
    esac
done
shift $((OPTIND-1))

trap finalize SIGINT

finalize(){
    if [ "${_need_restart}" -gt 0 ];then
        info "Dataset have planned rollbacks, restart machine to apply them!"
    fi
}

for _type in ${AVAILABLE_DATASET_TYPES}; do
    _type_datasets="$(eval 'echo "$'"$_type"'_DATASETS"')"
    _rollback_list="$(list_pending_rollbacks "$(echo "${_type_datasets}" | cut -d ' ' -f1)")"

    if [ "${list_rollbacks}" -gt 0 ]; then
        printf "%s:\t" "${_type}"
        for _rollback in $_rollback_list; do
            printf "%s\t" "$_rollback"
        done
        printf "\n"
        continue
    fi

    # Ignore datasets not explicitely selected from here
    if [ "$(eval 'echo "$rollback_'"$_type"'"')" -lt 1 ]; then
        continue
    fi

    if [ $clean_rollback_triggers -gt 0 ]; then
        clean_rollback_state_on_datasets "${_type_datasets}"
    else
        echo "rollbacking ${_type}"
        clean_rollback_state_on_datasets "${_type_datasets}"
        _snapshot_list="$(list_snapshots "$(echo "${_type_datasets}" | cut -d ' ' -f1)")"
        # Get latest snapshot by default
        _snapshot_to_rollback="$(sublist "${_snapshot_list}" "1" "1")"
        if [ -n "${rollback_to}" ]; then
            _snapshot_to_rollback="$(echo "${_snapshot_list}" | grep -o "${rollback_to}")"
        fi
        if [ -z "${_snapshot_to_rollback}" ];then
            error_and_exit "[!] Snapshot not found, cannot rollback ${_type} dataset(s)"
        else
            _need_restart=1
            tag_snapshots_for_rollback "${_type_datasets}" "${_snapshot_to_rollback}"
        fi
    fi
done

finalize
