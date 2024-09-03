#!/usr/bin/env sh

TIME_START="$(date -Iseconds)"
TIME_START_SAFE="$(date +%Y%m%d_%H%M%S)"
. /usr/local/share/vulture-utils/common.sh

###########
# options #
###########
clean_cache=0
download_only=0
targets=""

### Internal ###
_need_maintenance_toggle=1
_pkg_options=""
_vultured_was_up=0
_cron_was_up=0

#############
# functions #
#############
usage() {
    echo "USAGE upgrade-pkg OPTIONS [targets]"
    echo "OPTIONS:"
    echo "	-D	only download packages/system updates in temporary dir (implies -T)"
    echo "	-T	keep temporary directory"
    echo "	-f	Force reinstallation of package(s)"
    echo "	-c	clean pkg cache and tempdir at the end of the script (incompatible with -T and -D)"
    echo "	-t <tmpdir>	temporary directory to use (default is /tmp/vulture_update/, only available on HBSD)"
    exit 0
}

initialize() {
    if [ "$(/usr/bin/id -u)" != "0" ]; then
        /bin/echo "This script must be run as root" 1>&2
        exit 1
    fi

    has_pending_BE || exit 1
    has_upgraded_kernel || exit 1

    echo "[${TIME_START}+00:00] Beginning packages upgrade"

    trap finalize_early SIGINT

    if [ "$_need_maintenance_toggle" -gt 0 ]; then
        /usr/local/bin/sudo -u vlt-os /home/vlt-os/env/bin/python /home/vlt-os/vulture_os/manage.py toggle_maintenance --on 2>/dev/null || true

        if /usr/sbin/service vultured status > /dev/null; then
            _vultured_was_up=1
            /usr/sbin/service vultured stop
        fi

        # Disable secadm rules if on an HardenedBSD system
        if [ -f /usr/sbin/hbsd-update ] ; then
            echo "[+] Disabling root secadm rules"
            /usr/sbin/service secadm stop || echo "Could not disable secadm rules"
            echo "[-] Done."

            for jail in "mongodb" "apache" "portal"; do
                echo "[+] [${jail}] Disabling secadm rules"
                /usr/sbin/jexec $jail /usr/sbin/service secadm stop || echo "Could not disable secadm rules"
                echo "[-] Done."
            done
        fi

        # Disable harden_rtld: currently breaks many packages upgrade
        _was_rtld=$(/sbin/sysctl -n hardening.harden_rtld)
        /sbin/sysctl hardening.harden_rtld=0
        for jail in "haproxy" "mongodb" "redis" "apache" "portal" "rsyslog"; do
            eval "_was_rtld_${jail}=$(/usr/sbin/jexec $jail /sbin/sysctl -n hardening.harden_rtld)"
            /usr/sbin/jexec $jail /sbin/sysctl hardening.harden_rtld=0 > /dev/null
        done

        # Unlock Vulture packages
        echo "[+] Unlocking Vulture packages..."
        /usr/sbin/pkg unlock -y vulture-base vulture-gui vulture-haproxy vulture-mongodb vulture-redis vulture-rsyslog
        echo "[-] Done."

        if /usr/sbin/service cron status > /dev/null; then
            _cron_was_up=1
            process_match="manage.py crontab run "
            # Disable cron during upgrades
            echo "[+] Disabling cron..."
            /usr/sbin/service cron stop
            if /bin/pgrep -qf "${process_match}"; then
                echo "[*] Stopping currently running crons..."
                # send a SIGTERM to close scripts cleanly, if pwait expires after 10m, force kill all remaining scripts
                /bin/pkill -15 -f "${process_match}"
                if ! /bin/pgrep -f "${process_match}" | /usr/bin/xargs /bin/pwait -t10m; then
                    warn "[#] Some crons still running after 10 minutes, forcing remaining crons to stop!"
                    /bin/pgrep -lf "${process_match}"
                    /bin/pkill -9 -lf "${process_match}"
                fi
            fi
            echo "[-] Cron disabled"
        fi
    fi

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

    if [ "${_need_maintenance_toggle}" -gt 0 ]; then
        # Re-enable secadm rules if on an HardenedBSD system
        if [ -f /usr/sbin/hbsd-update ] ; then
            echo "[+] Enabling root secadm rules"
            /usr/sbin/service secadm start || warn "[#] Could not enable secadm rules"
            echo "[-] Done."

            for jail in "mongodb" "apache" "portal"; do
                echo "[+] [${jail}] Enabling secadm rules"
                /usr/sbin/jexec $jail /usr/sbin/service secadm start || warn "[#] Could not enable secadm rules"
                echo "[-] Done."
            done
        fi

        # Reset hardeen_rtld to its previous value
        /sbin/sysctl hardening.harden_rtld="${_was_rtld}"
        for jail in "haproxy" "mongodb" "redis" "apache" "portal" "rsyslog"; do
            eval "/usr/sbin/jexec $jail /sbin/sysctl hardening.harden_rtld=\$_was_rtld_$jail" > /dev/null
        done

        # Lock Vulture packages
        echo "[+] Lock Vulture packages..."
        /usr/sbin/pkg lock -y vulture-base vulture-gui vulture-haproxy vulture-mongodb vulture-redis vulture-rsyslog
        echo "[-] Done."

        # Be sure to restart dnsmasq: No side-effect and it deals with dnsmasq configuration changes
        /usr/sbin/service dnsmasq restart

        if [ $_cron_was_up -eq 1 ]; then
            # Restart cron after upgrade
            echo "[+] Restarting cron..."
            /usr/sbin/service cron start
            echo "[-] Cron restarted"
        fi

        /usr/local/bin/sudo -u vlt-os /home/vlt-os/env/bin/python /home/vlt-os/vulture_os/manage.py toggle_maintenance --off 2>/dev/null || true

        if [ $_vultured_was_up -eq 1 ]; then
            # Restart Vultured after upgrade
            /usr/sbin/service vultured start
        fi
    fi

    echo "[$(date +%Y-%m-%dT%H:%M:%S+00:00)] Upgrade finished!"
    exit $err_code
}

finalize_early() {
    finalize 1 "Stopped"
}


####################
# parse parameters #
####################
while [ $# -gt 0 ]; do
    case "${1}" in
        -D) download_only=1;
            _need_maintenance_toggle=0;
            shift;
            ;;
        -c) clean_cache=1;
            shift;
            ;;
        -f) _pkg_options="${_pkg_options} -f";
            shift;
            ;;
        -h) usage;
            ;;
        -*)
            error "Unknown Option: ${1}"
            usage
            ;;
        *)  targets="${targets} ${1}";
            shift
            ;;
    esac
done

if [ $clean_cache -gt 0 ] && [ $download_only -gt 0 ]; then
    error_and_exit "[!] Cannot activate -c if -D or -T are set"
fi

initialize

IGNORE_OSVERSION="yes" /usr/sbin/pkg update -f || finalize 1 "Could not update list of packages"

if [ $download_only -gt 0 ]; then
    echo "[+] Downloading packages"
    # Fetch updated packages for root system
    IGNORE_OSVERSION="yes" /usr/sbin/pkg fetch -yu || finalize 1 "Failed to download new packages"
    # fetch updated packages for each jail
    for jail in "haproxy" "apache" "portal" "mongodb" "redis" "rsyslog" ; do
        IGNORE_OSVERSION="yes" /usr/sbin/pkg -j $jail update -f || finalize 1 "Could not update list of packages for jail ${jail}"
        IGNORE_OSVERSION="yes" /usr/sbin/pkg -j $jail fetch -yu || finalize 1 "Failed to download new packages for jail ${jail}"
    done
    # exit here, everything has been downloaded
    echo "[+] Downloading done"
    finalize
fi

# If no argument or jail asked
for jail in "haproxy" "redis" "mongodb" "rsyslog" ; do
    if [ -z "${targets}" ] || contains "$targets" "$jail" ; then

        /bin/echo "[+] Updating jail $jail packages..."
        IGNORE_OSVERSION="yes" /usr/sbin/pkg -j "$jail" update -f || finalize 1 "Could not update list of packages for jail ${jail}"
        IGNORE_OSVERSION="yes" /usr/sbin/pkg -j "$jail" upgrade ${_pkg_options} -y || finalize 1 "Could not upgrade packages for jail ${jail}"
        echo "[-] Ok."

        # Upgrade vulture-$jail AFTER, in case of "pkg -j $jail upgrade" has removed some permissions... (like redis)
        /bin/echo "[+] Updating vulture-$jail package..."
        IGNORE_OSVERSION="yes" /usr/sbin/pkg upgrade ${_pkg_options} -y "vulture-$jail" || finalize 1 "Could not upgrade vulture-${jail}"
        echo "[-] Ok."

        echo "[+] Restarting services..."
        case "$jail" in
            rsyslog)
                /usr/sbin/jexec "$jail" /usr/sbin/service rsyslogd restart
                ;;
            mongodb)
                /usr/sbin/jexec "$jail" /usr/sbin/service mongod restart
                # TODO Force disable pageexec and mprotect on the mongo executable
                # there seems to be a bug currently with secadm when rules are pre-loaded on executables in packages
                # which is the case for latest mongodb36-3.6.23
                /usr/sbin/jexec "$jail" /usr/sbin/hbsdcontrol pax disable pageexec /usr/local/bin/mongo
                /usr/sbin/jexec "$jail" /usr/sbin/hbsdcontrol pax disable mprotect /usr/local/bin/mongo
                ;;
            redis)
                /usr/sbin/jexec "$jail" /usr/sbin/service sentinel stop
                /usr/sbin/jexec "$jail" /usr/sbin/service redis restart
                /usr/sbin/jexec "$jail" /usr/sbin/service sentinel start
                ;;
            haproxy)
                if /usr/sbin/jexec "$jail" /usr/sbin/service haproxy status > /dev/null ; then
                    # Reload gracefully
                    /bin/echo "[*] reloading haproxy service..."
                    /usr/sbin/jexec "$jail" /usr/sbin/service haproxy reload
                else
                    # Start service
                    /bin/echo "[*] starting haproxy service..."
                    /usr/sbin/jexec "$jail" /usr/sbin/service haproxy start
                fi
                ;;
            *)
                /usr/sbin/jexec "$jail" /usr/sbin/service "$jail" restart
                ;;
        esac
        echo "[-] Ok."
        echo "[-] $jail updated."
    fi
done

# No parameter, or gui
if [ -z "${targets}" ] || contains "${targets}" "gui" ; then
    echo "[+] Updating GUI..."
    /usr/sbin/jexec apache /usr/sbin/service gunicorn stop
    /usr/sbin/jexec portal /usr/sbin/service gunicorn stop

    echo "[+] Updating vulture-gui package..."
    IGNORE_OSVERSION="yes" /usr/sbin/pkg upgrade ${_pkg_options} -y vulture-gui  || finalize 1 "Failed to upgrade package vulture-gui"
    echo "[-] Ok."

    /bin/echo "[+] Reloading dnsmasq..."
    # Ensure dnsmasq is up-to-date, as it could be modified during vulture-gui upgrade
    /usr/sbin/service dnsmasq reload || /usr/sbin/service dnsmasq restart
    /bin/echo "[-] dnsmasq reloaded"

    echo "[+] Updating apache jail's packages..."
    IGNORE_OSVERSION="yes" /usr/sbin/pkg -j apache update -f || finalize 1 "Failed to update the list of packages for the apache jail"
    IGNORE_OSVERSION="yes" /usr/sbin/pkg -j apache upgrade ${_pkg_options} -y || finalize 1 "Failed to upgrade packages in the apache jail"
    echo "[-] Ok."

    echo "[+] Updating portal jail's packages..."
    IGNORE_OSVERSION="yes" /usr/sbin/pkg -j portal update -f || finalize 1 "Failed to update the list of packages for the portal jail"
    IGNORE_OSVERSION="yes" /usr/sbin/pkg -j portal upgrade ${_pkg_options} -y || finalize 1 "Failed to upgrade packages in the portal jail"
    echo "[-] Ok."

    echo "[+] Restarting services..."
    /usr/sbin/jexec apache /usr/sbin/service gunicorn restart
    /usr/sbin/jexec apache /usr/sbin/service nginx restart
    /usr/sbin/jexec portal /usr/sbin/service gunicorn restart
    echo "[-] Ok."
    echo "[-] GUI updated."
fi

if [ -z "${targets}" ] || contains "${targets}" "base" ; then
        echo "[+] Updating vulture-base ..."
        IGNORE_OSVERSION="yes" /usr/sbin/pkg upgrade ${_pkg_options} -y vulture-base || finalize 1 "Failed to upgrade vulture-base"

        /bin/echo "[+] Reloading dnsmasq..."
        # Ensure dnsmasq is up-to-date, as it could be modified during vulture-base upgrade
        /usr/sbin/service dnsmasq reload || /usr/sbin/service dnsmasq restart
        /bin/echo "[-] dnsmasq reloaded"

        echo "[-] Vulture-base updated"
fi

if [ -z "$targets" ]; then
    echo "[+] Updating all packages on system..."
    IGNORE_OSVERSION="yes" /usr/sbin/pkg upgrade ${_pkg_options} -y || finalize 1 "Error while upgrading packages"
    echo "[-] All packages updated"
else
    for package in $targets; do
        if IGNORE_OSVERSION="yes" /usr/sbin/pkg info "$package" > /dev/null 2>&1; then
            echo "[+] Upgrading package ${package}"
            IGNORE_OSVERSION="yes" /usr/sbin/pkg upgrade ${_pkg_options} -y "${package}" || warn "[!] Error while upgrading package ${package}"
            echo "[-] Package updated"
        fi
    done
fi

if [ $clean_cache -gt 0 ]; then
    echo "[+] Cleaning pkg cache..."
    /usr/sbin/pkg clean -ay
    if [ -n "${_pkg_options}" ]; then
        /usr/sbin/pkg clean -ay
    fi
    echo "[-] Done."
    for jail in "haproxy" "apache" "portal" "mongodb" "redis" "rsyslog" ; do
        echo "[+] Cleaning pkg cache in jail ${jail}..."
        /usr/sbin/pkg -j $jail clean -ay
        echo "[-] Done."
    done
fi

finalize
