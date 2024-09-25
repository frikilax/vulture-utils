#!/usr/bin/env sh

TIME_START="$(date -Iseconds)"
TIME_START_SAFE="$(date +%Y%m%d_%H%M%S)"
. /usr/local/share/vulture-utils/common.sh

###########
# options #
###########
temp_dir="/tmp/vulture_update"
resolve_strategy="mf"
system_version=""
keep_temp_dir=0
download_only=0
use_dnssec=0
clean_cache=0
snapshot_system=0
keep_previous_snap=2 # by default, only keep 2 snapshot versions: the current one, and the previous one
upgrade_root=1
jails=""
### Internal ###
_action_str="OS upgrade"
_need_maintenance_toggle=1
_snap_name="${SNAPSHOT_PREFIX}UPGRADE_${TIME_START_SAFE}"
_params=""

#############
# functions #
#############
usage() {
    echo "USAGE upgrade-os OPTIONS <all|jails|[jail name]>"
    echo "OPTIONS:"
    echo "	-D	only download OS upgrades in temporary dir (implies -T)"
    echo "	-T	keep temporary directory"
    echo "	-V	set a custom system OS version (as specified by 'hbsd-update -v')"
    echo "	-c	clean tempdir at the end of the script (incompatible with -T and -D)"
    echo "	-d	use dnssec while downloading OS upgrades (disabled by default)"
    echo "	-b	Use a Boot Environment to install updates, and activate it on success"
    echo "	-k <num>	Number of BEs to keep (default is 2)"
    echo "	-t <tmpdir>	temporary directory to use (default is /tmp/vulture_update/)"
    echo "	-r <strategy>	(non-interactive) resolve strategy to pass to hbsd-update script while upgrading system configuration files (see man etcupdate for more info, default is 'mf')"
    exit 0
}


initialize() {
    if [ "$(/usr/bin/id -u)" != "0" ]; then
        /bin/echo "This script must be run as root" 1>&2
        exit 1
    fi

    if [ "${upgrade_root}" -gt 0 ]; then
        has_pending_BE || exit 1
        has_upgraded_kernel || exit 1
    fi

    echo "[${TIME_START}+00:00] Beginning ${_action_str}"

    trap finalize_early SIGINT

    if [ $_need_maintenance_toggle -gt 0 ]; then
        /usr/local/bin/sudo -u vlt-os /home/vlt-os/env/bin/python /home/vlt-os/vulture_os/manage.py toggle_maintenance --on 2>/dev/null || true
    fi

    # Ensure temporary directory is created
    mkdir -p "${temp_dir}" || echo "Temp directory exists, keeping"

    if [ -f /etc/rc.conf.proxy ]; then
        . /etc/rc.conf.proxy
        export http_proxy=${http_proxy}
        export https_proxy=${https_proxy}
        export ftp_proxy=${ftp_proxy}
    fi
}


finalize() {
    # set default in case err_code is not specified
    err_code=$1
    err_message=$2
    # does not work with '${1:=0}' if $1 is not set...
    err_code=${err_code:=0}

    if [ -n "$err_message" ]; then
        echo ""
        error "[!] ${err_message}"
        echo ""
    fi

    if [ $snapshot_system -gt 0 ]; then
        if /sbin/bectl list -H -cname | grep -q "${_snap_name}"; then
            /sbin/bectl umount "${_snap_name}" || warn "[#] Could not unmount the new BE"

            if [ ${err_code} -eq 0 ]; then
                /sbin/bectl activate "${_snap_name}"
            else
                /sbin/bectl destroy -Fo "${_snap_name}"
            fi
        fi
    fi

    if [ $keep_temp_dir -eq 0 ]; then
        echo "[+] Cleaning temporary dir..."
        /bin/rm -rf "${temp_dir}"
        echo "[-] Done."
    fi

    if [ $_need_maintenance_toggle -gt 0 ]; then
        /usr/local/bin/sudo -u vlt-os /home/vlt-os/env/bin/python /home/vlt-os/vulture_os/manage.py toggle_maintenance --off 2>/dev/null || true
    fi

    has_pending_BE
    has_upgraded_kernel

    echo "[$(date +%Y-%m-%dT%H:%M:%S+00:00)] ${_action_str} finished!"
    exit $err_code
}

finalize_early() {
    finalize 1 "Stopped"
}


####################
# parse parameters #
####################
while getopts 'hDTV:cdbk:t:r:' opt; do
    case "${opt}" in
        D)  download_only=1;
            keep_temp_dir=1;
            _need_maintenance_toggle=0
            _action_str="Download"
            ;;
        T)  keep_temp_dir=1;
            ;;
        V)  system_version="${OPTARG}";
            ;;
        c)  clean_cache=1;
            ;;
        d)  use_dnssec=1;
            ;;
        b)  snapshot_system=1;
            _need_maintenance_toggle=0;
            _action_str="${_action_str} (in new Boot Environment ${_snap_name})";
            ;;
        k)  keep_previous_snap=${OPTARG};
            ;;
        t)  temp_dir="${OPTARG}";
            ;;
        r)  resolve_strategy="${OPTARG}";
            ;;
        *)  usage;
            ;;
    esac
done
shift $((OPTIND-1))
_params="$*"

# Decide what OS to upgrade (system root, specific jails, only jails or everything)
if [ "${_params}" = "all" ]; then
    upgrade_root=1
    jails="$(get_jail_list)"
    _need_maintenance_toggle=1
elif [ "${_params}" = "jails" ]; then
    upgrade_root=0
    jails="$(get_jail_list)"
    _need_maintenance_toggle=1
elif [ -n "${_params}" ]; then
    upgrade_root=0
    for param in ${_params}; do
        if ! /usr/sbin/jls -j "${param}" > /dev/null 2>&1; then
            error_and_exit "Jail ${param} not found, is it currently stopped?"
        fi
    done
    jails="${_params}"
    _need_maintenance_toggle=1
fi

if [ $clean_cache -gt 0 ] && [ $keep_temp_dir -gt 0 ] || [ $clean_cache -gt 0 ] && [ $download_only -gt 0 ]; then
    error_and_exit "[!] Cannot activate -c if -D or -T are set"
fi

if [ "${keep_previous_snap}" -ne "${keep_previous_snap}" ] || [ "${keep_previous_snap}" -lt 1 ]; then
    error_and_exit "[!] -k value should be a positive integer"
fi

initialize

download_system_update "${temp_dir}" "${use_dnssec}" "${system_version}" || finalize 1 "Failed to download system upgrades"

if [ $download_only -gt 0 ]; then
    # exit here, everything has been downloaded
    finalize
fi

if [ ${upgrade_root} -gt 0 ]; then
    /bin/echo "[+] Updating system..."
    update_system "${temp_dir}" "${snapshot_system}" "${keep_previous_snap}" "${resolve_strategy}" "${system_version}" || finalize 1 "Failed to install system upgrades"
fi
for jail in ${jails}; do
    /bin/echo "[+] Updating jail ${jail}..."
    download_system_update "${temp_dir}" "${use_dnssec}" "${system_version}" "${jail}" || finalize 1 "Failed to download jail system upgrade"
    update_jail_system "${jail}" "${temp_dir}" "${resolve_strategy}" "${system_version}" || finalize 1 "Failed to install system upgrades on jail ${jail}"
done
/bin/echo "[-] Done."

finalize
