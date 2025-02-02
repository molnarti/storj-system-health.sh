#!/bin/bash
#
# v1.12.0
#
# storj-system-health.sh - storagenode health checks and notifications to discord / by email
# by dusselmann, https://github.com/dusselmann/storj-system-health.sh
# This script is licensed under GNU GPL version 3.0 or above
# 
# > requires discord.sh from https://github.com/ChaoticWeg/discord.sh
# > uses parts of storj_success_rate from https://github.com/ReneSmeekes/storj_success_rate
# 
# -------------------------------------------------------------------------

# let the script run in low performance to not block the system
renice 19 $$ 

# =============================================================================
# CHECK AND HANDLE PARAMETERS
# ------------------------------------

# default values

config_file="./storj-system-health.credo"      # config file path
settings_file=".storj-system-health"           # settings file path
declare -A settings                            # declare associative array settings

DEBUG=false                                    # debug mode flag
SENDPUSH=false                                 # sends push message, when true
SENDMAIL=false                                 # sends test mail, when true
DETAILEDSUCCESSRATES=false                     # send detailed success rates in push message
VERBOSE=false                                  # verbose mode flag
LOGMIN_OVERRIDE=0                              # LOGMIN override flag 
UNAMEOUT="$(uname -s)"                         # get OS name (darwin for mac os, linux etc.)
TODAY=$(date +"%Y-%m-%d")                      # todays date in format yyyy-mm-dd

satellite_notification=false                   # send satellite notification flag
settings_satellite_key="satping"               # settings satellite ping key
settings_satellite_timestamp=$(date +"%s")     # settings satellite ping value of now
audit_difference_repeat=false                  # help variable in case of pending audits
include_current_earnings=false                 # show current month's earnings yes/no
current_earnings_only=false                    # skip a full check and push hdd usage + earnings only

# help text

readonly help_text="Usage: $0 [OPTIONS]

Example: $0 -dv

General options:
  -h            Display this help and exit
  -c <path>     Use individual file path for properties
  -d            send discord push 
  -e            Show current month's earnings
  -E            Show only current month's earnings (skip docker logs analysis)
  -l <int>.     Override LOGMIN specified in settings, format: minutes as integer
  -m            send test mail in order to test mail server settings
  -p <path>     Provide a path to support crontab on MacOS
  -s <path>     Use individual file path for settings
  -o            Send detailed success rates in push message; do NOT trim the result
  -v            Verbose option to enable console output while execution
  -q            Debug mode with extra quality check outputs"

# parameter handling

while getopts ":hc:s:dmp:l:veEqo" flag
do
    case "${flag}" in
        c) config_file=${OPTARG};;
        s) settings_file=${OPTARG};;
        d) SENDPUSH=true;;
        m) SENDMAIL=true;;
        p) PATH=${OPTARG};;
        l) LOGMIN_OVERRIDE=${OPTARG};;
        v) VERBOSE=true;;
        e) include_current_earnings=true;;
        E) include_current_earnings=true && current_earnings_only=true;;
        q) DEBUG=true;;
        o) DETAILEDSUCCESSRATES=true;;
        h | *) echo "$help_text" && exit 0;;
    esac
done
shift $((OPTIND-1))

# get current dir of this script
DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd -P)

[[ "$VERBOSE" == "true" ]] && echo "==="
[[ "$VERBOSE" == "true" ]] && echo -e " *** timestamp [$(date +'%d.%m.%Y %H:%M')]"
[[ "$VERBOSE" == "true" ]] && [[ "$SENDPUSH" == "true" ]] && echo -e " *** discord push will be sent"
[[ "$VERBOSE" == "true" ]] && [[ "$SENDMAIL" == "true" ]] && echo -e " *** test mail will be sent"


# =============================================================================
# DEFINE FUNCTIONS
# ------------------------------------

function updateSettings() {
    k="${1}" # key passed
    v="${2}" # value passed
    
    if ! grep -R "^[#]*\s*${k}=.*" $settings_file > /dev/null; then
        echo "$k=$v" >> $settings_file
        [[ "$VERBOSE" == "true" ]] && echo " *** settings: added key '${k}', because it was not found."
    else
        sed -ir "s/^[#]*\s*${k}=.*/$k=$v/" $settings_file
        [[ "$VERBOSE" == "true" ]] && echo " *** settings: new value '${v}' for '${k}' saved."
    fi
}

function initSettings() {
    [[ "$VERBOSE" == "true" ]] && echo " *** settings: restoring file:"
    echo "$settings_satellite_key=$settings_satellite_timestamp" > $settings_file
    [[ "$VERBOSE" == "true" ]] && echo " *** settings: latest satellite ping saved [$(date +'%d.%m.%Y %H:%M')]."
    # .. other values to be appended with >> instead of > !
}

function vercomp () {
    if [[ $1 == $2 ]]
    then
        [[ "$VERBOSE" == "true" ]] && [[ "$DEBUG" == "true" ]] && echo "... storj versions equal"
        return 0
    fi
    [[ "$VERBOSE" == "true" ]] && [[ "$DEBUG" == "true" ]] && echo "... storj versions unequal"
    local IFS=.
    local i ver1=($1) ver2=($2)
    # fill empty fields in ver1 with zeros
    for ((i=${#ver1[@]}; i<${#ver2[@]}; i++))
    do
        ver1[i]=0
    done
    for ((i=0; i<${#ver1[@]}; i++))
    do
        if [[ -z ${ver2[i]} ]]
        then
            # fill empty fields in ver2 with zeros
            ver2[i]=0
        fi
        if ((10#${ver1[i]} > 10#${ver2[i]}))
        then
            [[ "$VERBOSE" == "true" ]] && [[ "$DEBUG" == "true" ]] && echo "... storj versions: current larger"
            return 1
        fi
        if ((10#${ver1[i]} < 10#${ver2[i]}))
        then
            [[ "$VERBOSE" == "true" ]] && [[ "$DEBUG" == "true" ]] && echo "... storj versions: current smaller"
            return 2
        fi
    done
    return 0
}

# =============================================================================
# DEFINE VARIABLES AND CONSTANTS
# ------------------------------------

if [[ "$DISCORDON" == "true" ]]
then 
    # check, if discord.sh script exists and is executable
    if [ ! -x "$DIR/discord.sh" ]
    then
        echo "fatal: discord.sh does not exist or is not executable:$DIR/discord.sh"
        exit 2
    fi
fi


# check, if config file exists and is readable
if [ ! -r "$config_file" ]
then
    echo "fatal: config file $config_file not found / readable."
    exit 2
else 
    # loads config data into variables 
    { while IFS== read var values ; do IFS=, read -a $var <<< "$values";  done < "$config_file"; } 2>/dev/null


    [[ -z "$DISCORDON" ]] && echo "fatal: DISCORDON not specified in .credo" && exit 2
    if [[ "$DISCORDON" == "true" ]]
    then 
        [[ -z "$DISCORDURL" ]] && echo "fatal: DISCORDURL not specified in .credo" && exit 2
    fi
    
    
    [[ -z "$MAILON" ]] && echo "fatal: MAILON not specified in .credo" && exit 2
    if [[ "$MAILON" == "true" ]]
    then 
        [[ -z "$MAILFROM" ]] && echo "fatal: MAILFROM not specified in .credo" && exit 2
        [[ -z "$MAILTO" ]] && echo "fatal: MAILTO not specified in .credo" && exit 2
        [[ -z "$MAILSERVER" ]] && echo "fatal: MAILSERVER not specified in .credo" && exit 2
        [[ -z "$MAILUSER" ]] && echo "fatal: MAILUSER not specified in .credo" && exit 2
        [[ -z "$MAILPASS" ]] && echo "fatal: MAILPASS not specified in .credo" && exit 2
    fi
    
    [[ -z "$NODES" ]] && echo "failure: NODES not specified in .credo" && exit 2
    [[ -z "$MOUNTPOINTS" ]] && echo "failure: MOUNTPOINTS not specified in .credo" && exit 2
    [[ -z "$NODEURLS" ]] && echo "failure: NODEURLS not specified in .credo" && exit 2


    if [[ -z "$LOGMIN" ]]; then
        echo "LOGMIN=60" >> $config_file
        echo "warning: LOGMIN was not specified in .credo, but was added now."
        echo "         You need to restart the script to make it work."
        echo "         Script has been stopped."
        exit 2
    fi

    if [[ -z "$LOGMAX" ]]; then
        echo "LOGMAX=1440" >> $config_file
        echo "warning: LOGMAX was not specified in .credo, but was added now."
        echo "         You need to restart the script to make it work."
        echo "         Script has been stopped."
        exit 2
    fi


    if [[ -z "$SATPINGFREQ" ]]; then
        echo "SATPINGFREQ=10800" >> $config_file
        echo "warning: SATPINGFREQ was not specified in .credo, but was added now."
        echo "         You need to restart the script to make it work."
        echo "         Script has been stopped."
        exit 2
    fi
    
    
    if [[ -z "$NODELOGPATHS" ]]; then
        tmp_commas=
        for (( i=0; i<${#NODES[@]}; i++ ))
        do
            tmp_commas="$(echo $tmp_commas/)"
            if [[ $i -lt ${#NODES[@]}-1 ]]; then
                tmp_commas="$(echo $tmp_commas,)"
            fi
        done
        echo "NODELOGPATHS=$tmp_commas" >> $config_file
        echo "warning: NODELOGPATHS was not specified in .credo, but was added now."
        echo "         --> If you've redirected your logs, you need to modify .credo."
        echo "         You need to restart the script to make it work."
        echo "         Script has been stopped."
        exit 2
    fi




    # quality checks
    [[ ${#MOUNTPOINTS[@]} -ne ${#NODES[@]} ]] && echo "failure: number of NODES and MOUNTPOINTS do not match in .credo" && exit 2
    [[ ${#NODEURLS[@]} -ne ${#NODES[@]} ]] && echo "failure: number of NODES and NODEURLS do not match in .credo" && exit 2
    [[ ${#NODELOGPATHS[@]} -ne ${#NODES[@]} ]] && echo "failure: number of NODES and NODELOGPATHS do not match in .credo" && exit 2

    [[ "$VERBOSE" == "true" ]] && echo " *** config file loaded: $config_file"
fi

[[ "$VERBOSE" == "true" ]] && echo " *** settings file path: $settings_file"
[[ "$VERBOSE" == "true" ]] && [[ $LOGMIN_OVERRIDE -gt 0 ]] && echo " *** settings: logs from the last $LOGMIN_OVERRIDE minutes will be selected."


# =============================================================================
# LOAD AND SET SETTINGS FILE FOR SATPING
# ------------------------------------


# loads settings file into variables
if [ ! -r "$settings_file" ]; then
    # if not existing or readable, create a new file
    initSettings
else
    # if existing and readable, read its content
    while IFS== read var values; do
        IFS=, read -a $var <<< "$values"
    done < "$settings_file"
    
    # ** satping - check availability of satping variable
    if [[ -z "$satping" ]]; then
        [[ "$VERBOSE" == "true" ]] && echo "warning: settings: satping not found."
        satellite_notification=true  # do perform the satellite notification
        updateSettings "${settings_satellite_key}" "${settings_satellite_timestamp}" # set current date
    fi
fi 


# =============================================================================
# CHECK DEPENDENCIES AND LIBRARIES
# ------------------------------------

# check for jq
jq --version >/dev/null 2>&1
readonly jq_ok=$?
[[ "$jq_ok" -eq 127 ]] && echo "fatal: jq not installed" && exit 2
[[ "$jq_ok" -ne 0 ]] && echo "fatal: unknown error in jq" && exit 2
# jq exists and runs ok

# verify jq version minimum 1.6 
jqversion="$(echo \"$(jq --version)\" | grep -o '[0-9]*[\.][0-9]*')" 
[[ $(echo $jqversion '<' 1.6 | bc -l) -eq 1 ]] && echo "fatal: jq version 1.6 required (installed: $jqversion)" && exit 2

# check for curl
curl --version >/dev/null 2>&1
readonly curl_ok=$?
[[ "$curl_ok" -eq 127 ]] && echo "fatal: curl not installed" && exit 2
# curl exists and runs ok

# check for swaks
if [[ "$MAILON" == "true" ]]
then 
    swaks --version >/dev/null 2>&1
    readonly swaks_ok=$?
    [[ "$swaks_ok" -eq 127 ]] && echo "fatal: swaks not installed" && exit 2
    # swaks exists and runs ok
fi


# Set swaks paremeters for mail sending

if [[ "$MAILON" == "true" ]]
then 
    SWAKSCMD="swaks --from $MAILFROM --to $MAILTO --server $MAILSERVER --auth LOGIN --auth-user $MAILUSER --auth-password $MAILPASS "

    # Append mail encryption parameters if set
    if [ ! -z "$MAILENCRYPT" ]; then
        case "$MAILENCRYPT" in
        "TLS")
            SWAKSCMD+="-tls "
            ;;
        "TLS-optional")
            SWAKSCMD+="-tlso "
            ;;
        "TLS-optional-strict")
            SWAKSCMD+="-tlsos "
            ;;
        "TLS-on-connect")
            SWAKSCMD+="--tlsc "
            ;;
        *)
            echo "fatal: invalid MAILENCRYPT value. Valid values are TLS, TLS-optional, TLS-optional-strict, TLS-on-connect" && exit 2
            ;;
        esac
    fi

    # Append mail port parameters if set
    if [ ! -z "$MAILPORT" ]; then
        SWAKSCMD+="--port $MAILPORT "
    fi
    
    # Echo mail command for troubleshooting
    if [[ "$VERBOSE" == "true" ]]; then
        echo " *** Sending mail using command: $SWAKSCMD"
    fi
fi

# =============================================================================
# START SCRIPT PROCESSING
# ------------------------------------


# check docker containers
readonly DOCKERPS="$(docker ps)"

## go through the list of storagenodes
for (( i=0; i<${#NODES[@]}; i++ )); do
NODE=${NODES[$i]}
node_url=${NODEURLS[$i]}

[[ "$VERBOSE" == "true" ]] && echo "==="
[[ "$VERBOSE" == "true" ]] && echo "running the script for node \"$NODE\" (${MOUNTPOINTS[$i]}) .."

## check if node is running in docker
RUNNING="$(echo "$DOCKERPS" 2>&1 | grep "$NODE" -c)"
[[ "$VERBOSE" == "true" ]] && echo " *** node is running        : $RUNNING"


### > check if storagenode is runnning; if not, cancel analysis and push / email alert
if [[ $RUNNING -eq 1 ]]; then
# (if statement is closed at the end of this script)


# grab (real) disk usage

# old: tmp_disk_usage="$(df ${MOUNTPOINTS[$i]} | grep / | awk '{ print $5}' | sed 's/%//g')%"
space_used=$(echo -E $(curl -s "$node_url/api/sno/" | jq '.diskSpace.used'))
space_total=$(echo -E $(curl -s "$node_url/api/sno/" | jq '.diskSpace.available'))
space_trash=$(echo -E $(curl -s "$node_url/api/sno/" | jq '.diskSpace.trash'))
space_overused=$(echo -E $(curl -s "$node_url/api/sno/" | jq '.diskSpace.overused'))
tmp_disk_usage="$(((space_used*100)/(space_total))).$(((space_used*10000)/(space_total)-(((space_used*100)/(space_total))*100)))%"
tmp_disk_gross="$((((space_used+space_trash)*100)/(space_total))).$((((space_used+space_trash)*10000)/(space_total)-((((space_used+space_trash)*100)/(space_total))*100)))%"

tmp_disk_full=false
if [[ $(((($space_used+$space_trash)*100)/($space_total))) -ge 99 ]]; then
    tmp_disk_full=true
fi

[[ "$VERBOSE" == "true" ]] && echo " *** disk usage             : $tmp_disk_usage (incl. trash: $tmp_disk_gross)"
tmp_overused_warning=false
if [[ $space_overused -gt 0 ]]; then 
    if [[ "$VERBOSE" == "true" ]]; then 
        echo "warning: space overused is greater than zero!"
    fi
    tmp_overused_warning=true
fi


# CHECK SATELLITE SCORES
# ------------------------------------

# check availability of api/sno/satellites
satellite_info_fulltext=$(echo -E $(curl -s "$node_url/api/sno/satellites"))
satellite_scores=$(echo -E $(curl -s "$node_url/api/sno/satellites" |
jq -r \
        --argjson auditScore 0.98 \
        --argjson suspensionScore 0.95 \
        --argjson onlineScore 0.85 \
        '.audits[] as $a | ($a.satelliteName | sub(":.*";"")) as $name |
        reduce ($ARGS.named|keys[]) as $key (
                [];
                if $a[$key] < $ARGS.named[$key] then (
                        . + ["\($key) \(100*$a[$key]|floor)% @ \($name) ... "]
                ) else . end
                ) | .[]'))
[ ! -z "$satellite_info_fulltext" ] && [[ "$VERBOSE" == "true" ]] && echo " *** satellite scores url   : $node_url/api/sno/satellites (OK)"
if [ -z "$satellite_info_fulltext" ] && [[ "$VERBOSE" == "true" ]]
then 
    echo " *** satellite scores url   : $node_url/api/sno/satellites -> not OK"
    echo "warning : satellite scores not available, please verify access."
fi
[[ "$DEBUG" == "true" ]] && echo "... satellite scores: $satellite_scores"

# compare, if dates are equal or not
# if unequal, perform satellite notification, else not
difference=$(($settings_satellite_timestamp-$satping))
[[ "$DEBUG" == "true" ]] && echo "... satping difference: $difference ($settings_satellite_timestamp - $satping) / freq: $SATPINGFREQ"
# only reset satping value in case satping has 
if [[ $difference -gt $SATPINGFREQ ]] && [ ! -z "$satellite_scores" ]
then
    satellite_notification=true  # do perform the satellite notification
    updateSettings "${settings_satellite_key}" "${settings_satellite_timestamp}" # replace old date with current date
fi
[[ "$VERBOSE" == "true" ]] && echo " *** settings: satellite pings will be sent: $satellite_notification"



# CHECK STORJ VERSION
# ------------------------------------

# process, if api info is available, else skip
storj_newer_version=false
storj_version_current=""
storj_version_latest=""
storj_version_date=""

RELEASEDATE=
RELEASEDIFF=

if [ ! -z "$satellite_info_fulltext" ]
then 
    # grab latest version from github
    storj_version_latest=$(curl --silent "https://api.github.com/repos/storj/storj/releases/latest" | jq -r '.tag_name' | cut -c 2-)
    storj_version_date=$(curl --silent "https://api.github.com/repos/storj/storj/releases/latest" | jq -r '.published_at')
    
    RELEASEDATE=$(cut -c1-10 <<< $storj_version_date)
    
    case "${UNAMEOUT}" in
        Linux*)     RELEASEDIFF=$(((`date -d "$TODAY" +%s` - `date -d "$RELEASEDATE" +%s`)/86400));;
        Darwin*)    RELEASEDIFF=$(((`date -jf "%Y-%m-%d" "$TODAY" +%s` - `date -jf "%Y-%m-%d" "$RELEASEDATE" +%s`)/86400));;
        *)          RELEASEDIFF=0
    esac
    
    # grab current version on this node
    storj_version_current=$(echo -E $(curl -s "$node_url/api/sno/" | jq -r '.version'))
    [[ "$VERBOSE" == "true" ]] && echo " *** storj node api url     : $node_url/api/sno (OK)"
    [[ "$VERBOSE" == "true" ]] && echo " *** storj version current  : installed $storj_version_current"
    [[ "$VERBOSE" == "true" ]] && echo " *** storj version latest   : github $storj_version_latest [$RELEASEDATE]"
    if [[ $RELEASEDIFF -gt 10 ]]
    then 
        if [[ "$storj_version_current" != "$storj_version_latest" ]]
        then
            vercomp $storj_version_current $storj_version_latest
            case $? in
                0) op=0;;
                1) op=1;;
                2) op=2;;
            esac
            if [[ $op -eq 2 ]]
            then
                echo "warning : there is a newer version of storj available."
            fi
        fi
    fi
else
    echo " *** node api url           : $node_url/api/sno -> not OK"
    echo "warning : storj version not available, please verify access."
fi



# // skip docker logs analysis in case -E param was provided (to speed things up)
if [[ "$current_earnings_only" == "false" ]]; then


LOG1D=""
LOG1H=""
NODELOGPATH=${NODELOGPATHS[$i]}
[[ $LOGMIN_OVERRIDE -gt 0 ]] && LOGMIN=$LOGMIN_OVERRIDE
if [[ "$NODELOGPATH" == "/" ]]
then 
    # docker log selection from the last 24 hours and 1 hour
    tmp_logmax="$LOGMAX"
    tmp_logmax+="m"
    LOG1D="$(docker logs $NODE --since $tmp_logmax 2>&1)"
    [[ "$VERBOSE" == "true" ]] && tmp_count="$(echo "$LOG1D" 2>&1 | grep '' -c)"
    [[ "$VERBOSE" == "true" ]] && echo " *** docker log $tmp_logmax selected : #$tmp_count"
    
    tmp_logmin="$LOGMIN"
    tmp_logmin+="m"
    LOG1H="$(docker logs $NODE --since $tmp_logmin 2>&1)"
    [[ "$VERBOSE" == "true" ]] && tmp_count="$(echo "$LOG1H" $NODE 2>&1 | grep '' -c)"
    [[ "$VERBOSE" == "true" ]] && echo " *** docker log $tmp_logmin selected : #$tmp_count"
else
    # log file selection, in case log is stored in a file
    
    tmp_logpath=""
    if [ -r "${NODELOGPATHS[$i]}" ]; then
        tmp_logpath="${NODELOGPATHS[$i]}"
    elif [ -r "${MOUNTPOINTS[$i]}${NODELOGPATHS[$i]}" ]; then
        tmp_logpath="${MOUNTPOINTS[$i]}${NODELOGPATHS[$i]}"
    else 
        echo "warning : redirected log file does not exist or is not readable:"
        echo "          ${MOUNTPOINTS[$i]}${NODELOGPATHS[$i]}"
        echo "     nor  ${NODELOGPATHS[$i]}"
    fi
    
    if [[ "$UNAMEOUT" == "Darwin" ]] ; then
        # select with macos specific date formula
        # cat $tmp_logpath | awk -v date=`TZ=UTC date -v-$tmp_logmax +'%Y-%m-%dT%H:%M:%S.000Z'` '$1 > date' 
        tmp_logmax="$LOGMAX"
        tmp_logmax+="M"
        tmp_logmin="$LOGMIN"
        tmp_logmin+="M"
        LOG1D="$(cat $tmp_logpath | awk -v date=`TZ=UTC date -v-$tmp_logmax +'%Y-%m-%dT%H:%M:%S.000Z'` '$1 > date' )"
            [[ "$VERBOSE" == "true" ]] && tmp_count="$(echo "$LOG1D" 2>&1 | grep '' -c)"
            [[ "$VERBOSE" == "true" ]] && echo " *** log file loaded $LOGMAX minutes : #$tmp_count"
        LOG1H="$(cat $tmp_logpath | awk -v date=`TZ=UTC date -v-$tmp_logmin +'%Y-%m-%dT%H:%M:%S.000Z'` '$1 > date' )"
            [[ "$VERBOSE" == "true" ]] && tmp_count="$(echo "$LOG1H" 2>&1 | grep '' -c)"
            [[ "$VERBOSE" == "true" ]] && echo " *** log file loaded $LOGMIN minutes : #$tmp_count"
    else
        # select with linux specific date formula
        LOGMAXDATE=$(TZ=UTC date --date="$LOGMAX minutes ago" +'%Y-%m-%dT%H:%M:%S.000Z')
        LOG1D="$(cat $tmp_logpath | awk -v date="$LOGMAXDATE" '$1 > date')"
            [[ "$VERBOSE" == "true" ]] && tmp_count="$(echo "$LOG1D" 2>&1 | grep '' -c)"
            [[ "$VERBOSE" == "true" ]] && echo " *** log file loaded $LOGMAX minutes : #$tmp_count"
        LOGMINDATE=$(TZ=UTC date --date="$LOGMIN minutes ago" +'%Y-%m-%dT%H:%M:%S.000Z')
        LOG1H="$(cat $tmp_logpath | awk -v date="$LOGMINDATE" '$1 > date')"
            [[ "$VERBOSE" == "true" ]] && tmp_count="$(echo "$LOG1H" 2>&1 | grep '' -c)"
            [[ "$VERBOSE" == "true" ]] && echo " *** log file loaded $LOGMIN minutes : #$tmp_count"
    fi
fi



# =============================================================================
# SELECT USAGE, ERROR COUNTERS AND ERROR MESSAGES
# ------------------------------------


# define audit variables, which are not used, in case there is no audit failure
audit_success=0
audit_failed_warn=0
audit_failed_warn_text=""
audit_failed_crit=0
audit_failed_crit_text=""
audit_recfailrate=0.00%
audit_failrate=0.00%
audit_successrate=100%
audit_difference=0


# select error messages in detail (partially extracted text log)
[[ "$VERBOSE" == "true" ]] && INFO="$(echo "$LOG1H" 2>&1 | grep '[[:blank:]]*INFO')"
AUDS="$(echo "$LOG1H" 2>&1 \
    | grep -E 'GET_AUDIT' \
    | grep 'failed' \
    | grep -v -e 'connection timed out' -e 'connection reset by peer' -e 'use of closed network connection' -e 'broken pipe')"

FATS="$(echo "$LOG1H" 2>&1 \
    | grep '[[:blank:]]*FATAL' \
    | grep -v -e '[[:blank:]]*INFO' -e '[[:blank:]]*WARN')"

ERRS="$(echo "$LOG1H" 2>&1 \
    | grep '[[:blank:]]*ERROR' \
    | grep -v -e '[[:blank:]]*INFO' -e '[[:blank:]]*WARN' -e '[[:blank:]]*FATAL' -e 'collector' -e 'piecestore' -e 'pieces error: filestore error: context canceled' -e 'piecedeleter' -e 'emptying trash failed' -e 'service ping satellite failed' -e 'timeout: no recent network activity' -e 'connection reset by peer' -e 'context canceled' -e 'tcp connector failed' -e 'node rate limited by id' -e 'manager closed: read tcp' -e 'connection timed out' -e 'connection reset by peer' -e 'use of closed network connection' -e 'broken pipe')"

DREPS="$(echo "$LOG1H" 2>&1 \
    | grep -E 'GET_REPAIR' \
    | grep 'failed' \
    | grep -v -e 'connection timed out' -e 'connection reset by peer' -e 'use of closed network connection' -e 'broken pipe')"
    

# added "severe" errors in order to recognize e.g. docker issues, connectivity issues etc.
SEVERE="$(echo "$LOG1H" 2>&1 \
    | grep -i -e 'error:' -e 'fatal:' -e 'unexpected shutdown' -e 'fatal error' -e 'transport endpoint is not connected' -e 'Unable to read the disk' -e 'software caused connection abort' \
    | grep -v -e 'emptying trash failed' -e '[[:blank:]]*INFO' -e '[[:blank:]]*WARN' -e '[[:blank:]]*FATAL' -e 'collector' -e 'piecestore' -e 'pieces error: filestore error: context canceled' -e 'piecedeleter' -e 'emptying trash failed' -e 'service ping satellite failed' -e 'timeout: no recent network activity' -e 'failed to settle orders for satellite' -e 'rpc client' -e 'manager closed: read tcp' -e 'connection timed out')"

# if selected errors are equal between ERRS / SEVERE, keep just one of them
[[ "$SEVERE" == "$ERRS" ]] && SEVERE=""

# count errors 
[[ "$VERBOSE" == "true" ]] && tmp_info="$(echo "$INFO" 2>&1 | grep '[[:blank:]]*INFO' -c)"
tmp_fatal_errors="$(echo "$FATS" 2>&1 | grep '[[:blank:]]*FATAL' -c)"
tmp_audits_failed="$(echo "$AUDS" 2>&1 | grep -E 'GET_AUDIT' | grep 'failed' -c)"
tmp_reps_failed="$(echo "$DREPS" 2>&1 | grep 'failed' -c)"
tmp_rest_of_errors="$(echo "$ERRS" 2>&1 | grep '[[:blank:]]*ERROR' -c)" 
tmp_io_errors="$(echo "$ERRS" 2>&1 | grep '[[:blank:]]*ERROR' | grep -e 'timeout' -e 'connection reset' -e 'tcp connector failed' -e 'node rate limited by id' -c)"
temp_severe_errors="$(echo "$SEVERE" 2>&1 | grep -i -e 'error:' -e 'fatal:' -e 'unexpected shutdown' -e 'fatal error' -e 'transport endpoint is not connected' -e 'Unable to read the disk' -e 'software caused connection abort' -c)"

[[ "$VERBOSE" == "true" ]] && echo " *** info count             : #$tmp_info"
[[ "$VERBOSE" == "true" ]] && echo " *** audit error count      : #$tmp_audits_failed"
[[ "$VERBOSE" == "true" ]] && echo " *** repair failures count  : #$tmp_reps_failed"
[[ "$VERBOSE" == "true" ]] && echo " *** fatal error count      : #$tmp_fatal_errors"
[[ "$VERBOSE" == "true" ]] && echo " *** severe count           : #$temp_severe_errors"
[[ "$VERBOSE" == "true" ]] && echo " *** other error count      : #$tmp_rest_of_errors"
[[ "$VERBOSE" == "true" ]] && echo " *** i/o timouts count      : #$tmp_io_errors"


## in case of audit issues, select and share details (recoverable or critical)
# ------------------------------------

#count of started audits
audit_started=$(echo "$LOG1D" 2>&1 | grep -E 'GET_AUDIT' | grep started -c)
#count of successful audits
audit_success=$(echo "$LOG1D" 2>&1 | grep -E 'GET_AUDIT' | grep downloaded -c)
#count of recoverable failed audits
audit_failed_warn=$(echo "$LOG1D" 2>&1 | grep -E 'GET_AUDIT' | grep failed | grep -v exist -c)
audit_failed_warn_text=$(echo "$LOG1H" 2>&1 | grep -E 'GET_AUDIT' | grep failed | grep -v exist)
#count of unrecoverable failed audits
audit_failed_crit=$(echo "$LOG1D" 2>&1 | grep -E 'GET_AUDIT' | grep failed | grep exist -c)
audit_failed_crit_text=$(echo "$LOG1H" 2>&1 | grep -E 'GET_AUDIT' | grep failed | grep exist)
if [ $(($audit_success+$audit_failed_crit+$audit_failed_warn)) -ge 1 ]
then
	audit_recfailrate=$(printf '%.2f\n' $(echo -e "$audit_failed_warn $audit_success $audit_failed_crit" | awk '{print ( $1 / ( $1 + $2 + $3 )) * 100 }'))%
fi
if [ $(($audit_success+$audit_failed_crit+$audit_failed_warn)) -ge 1 ]
then
	audit_failrate=$(printf '%.2f\n' $(echo -e "$audit_failed_crit $audit_failed_warn $audit_success" | awk '{print ( $1 / ( $1 + $2 + $3 )) * 100 }'))%
fi
if [ $(($audit_success+$audit_failed_crit+$audit_failed_warn)) -ge 1 ]
then
    audit_successrate=$(printf '%.0f\n' $(echo -e "$audit_success $audit_failed_crit $audit_failed_warn" | awk '{print ( $1 / ( $1 + $2 + $3 )) * 100 }'))%
else
    audit_successrate=0.000%
fi
#check difference started - success - failed
if [[ $audit_started -gt 0 ]]
then 
    # there are audits, which have been started, but are not finished
    # more than 2 pending audits = warning alert to be sent
    audit_difference=$(($audit_started-$audit_success-$audit_failed_crit-$audit_failed_warn))
    # run the script for that node again once
    if [[ $audit_difference -gt 0 ]] && [[ "$audit_difference_repeat" == "false" ]]; then
        audit_difference_repeat=true
    else 
        audit_difference_repeat=false
    fi
fi

[[ "$VERBOSE" == "true" ]] && echo " *** audits                 : w: $audit_recfailrate, c: $audit_failrate, s: $audit_successrate"
if [[ "$VERBOSE" == "true" ]] && [[ $audit_difference -gt 0 ]]; then
                              echo "warning:                      -> there are audits pending and not finished ($audit_difference)"
fi

## download stats
# ------------------------------------

#count of successful downloads
dl_success=$(echo "$LOG1D" 2>&1 | grep '"GET"' | grep 'downloaded' -c)
#canceled Downloads from your node
dl_canceled=$(echo "$LOG1D" 2>&1 | grep '"GET"' | grep 'download canceled' -c)
#Failed Downloads from your node
dl_failed=$(echo "$LOG1D" 2>&1 | grep '"GET"' | grep 'download failed' | grep -v 'noiseconn' -c)
#Ratio of canceled Downloads
if [ $(($dl_success+$dl_failed+$dl_canceled)) -ge 1 ]
then
	dl_canratio=$(printf '%.2f\n' $(echo -e "$dl_canceled $dl_success $dl_failed" | awk '{print ( $1 / ( $1 + $2 + $3 )) * 100 }'))%
else
	dl_canratio=0.000%
fi
#Ratio of Failed Downloads
if [ $(($dl_success+$dl_failed+$dl_canceled)) -ge 1 ]
then
	dl_failratio=$(printf '%.2f\n' $(echo -e "$dl_failed $dl_success $dl_canceled" | awk '{print ( $1 / ( $1 + $2 + $3 )) * 100 }'))%
else
	dl_failratio=0.000%
fi
#Ratio of Successful Downloads
get_ratio_int=0
if [ $(($dl_success+$dl_failed+$dl_canceled)) -ge 1 ]
then
	get_ratio_int=$(printf '%.0f\n' $(echo -e "$dl_success $dl_failed $dl_canceled" | awk '{print ( $1 / ( $1 + $2 + $3 )) * 100 }'))
fi
[[ "$VERBOSE" == "true" ]] && echo " *** downloads              : c: $dl_canratio, f: $dl_failratio, s: $get_ratio_int%"


## upload stats
# ------------------------------------

#count of successful uploads to your node
put_success=$(echo "$LOG1D" 2>&1 | grep '"PUT"' | grep uploaded -c)
#count of rejected uploads to your node
put_rejected=$(echo "$LOG1D" 2>&1 | grep 'upload rejected' -c)
#count of canceled uploads to your node
put_canceled=$(echo "$LOG1D" 2>&1 | grep '"PUT"' | grep 'upload canceled' -c)
#count of failed uploads to your node
put_failed=$(echo "$LOG1D" 2>&1 | grep '"PUT"' | grep 'upload failed' -c)
#Ratio of Rejections
if [ $(($put_success+$put_rejected+$put_canceled+$put_failed)) -ge 1 ]
then
	put_accept_ratio=$(printf '%.2f\n' $(echo -e "$put_rejected $put_success $put_canceled $put_failed" | awk '{print ( ($2 + $3 + $4) / ( $1 + $2 + $3 + $4 )) * 100 }'))%
else
	put_accept_ratio=0.000%
fi
#Ratio of Failed
if [ $(($put_success+$put_rejected+$put_canceled+$put_failed)) -ge 1 ]
then
	put_fail_ratio=$(printf '%.2f\n' $(echo -e "$put_failed $put_success $put_canceled" | awk '{print ( $1 / ( $1 + $2 + $3 )) * 100 }'))%
else
	put_fail_ratio=0.000%
fi
#Ratio of canceled
if [ $(($put_success+$put_rejected+$put_canceled+$put_failed)) -ge 1 ]
then
	put_cancel_ratio=$(printf '%.2f\n' $(echo -e "$put_canceled $put_failed $put_success" | awk '{print ( $1 / ( $1 + $2 + $3 )) * 100 }'))%
else
	put_cancel_ratio=0.000%
fi
#Ratio of Success
put_ratio_int=0
if [ $(($put_success+$put_canceled+$put_failed)) -ge 1 ]
then
	put_ratio_int=$(printf '%.0f\n' $(echo -e "$put_success $put_failed $put_canceled" | awk '{print ( $1 / ( $1 + $2 + $3 )) * 100 }'))
fi
[[ "$VERBOSE" == "true" ]] && echo " *** uploads                : c: $put_cancel_ratio, f: $put_fail_ratio, s: $put_ratio_int%"


## repair download & upload stats
# ------------------------------------

#count of started downloads of pieces for repair process
get_repair_started=$(echo "$LOG1D" 2>&1 | grep GET_REPAIR | grep "download started" -c)
#count of successful downloads of pieces for repair process
get_repair_success=$(echo "$LOG1D" 2>&1 | grep GET_REPAIR | grep downloaded -c)
#count of failed downloads of pieces for repair process
get_repair_failed=$(echo "$LOG1D" 2>&1 | grep GET_REPAIR | grep 'download failed' -c)
# get_repair_failed_text=$(echo "$LOG1H" 2>&1 | grep GET_REPAIR | grep 'download failed')
#count of canceled downloads of pieces for repair process
get_repair_canceled=$(echo "$LOG1D" 2>&1 | grep GET_REPAIR | grep 'download canceled' -c)
#Ratio of Fail GET_REPAIR
if [ $(($get_repair_success+$get_repair_failed+$get_repair_canceled)) -ge 1 ]
then
	get_repair_failratio=$(printf '%.2f\n' $(echo -e "$get_repair_failed $get_repair_success $get_repair_canceled" | awk '{print ( $1 / ( $1 + $2 + $3 )) * 100 }'))%
else
	get_repair_failratio=0.000%
fi
#Ratio of Cancel GET_REPAIR
if [ $(($get_repair_success+$get_repair_failed+$get_repair_canceled)) -ge 1 ]
then
	get_repair_canratio=$(printf '%.2f\n' $(echo -e "$get_repair_canceled $get_repair_success $get_repair_failed" | awk '{print ( $1 / ( $1 + $2 + $3 )) * 100 }'))%
else
	get_repair_canratio=0.000%
fi
#Ratio of Success GET_REPAIR
get_repair_ratio_int=0
if [ $(($get_repair_success+$get_repair_failed+$get_repair_canceled)) -ge 1 ]
then
	get_repair_ratio_int=$(printf '%.0f\n' $(echo -e "$get_repair_success $get_repair_failed $get_repair_canceled" | awk '{print ( $1 / ( $1 + $2 + $3 )) * 100 }'))
fi
[[ "$VERBOSE" == "true" ]] && echo " *** repair downloads       : c: $get_repair_canratio, f: $get_repair_failratio, s: $get_repair_ratio_int%"

#count of started uploads of repaired pieces
put_repair_started=$(echo "$LOG1D" 2>&1 | grep PUT_REPAIR | grep "upload started" -c)
#count of successful uploads of repaired pieces
put_repair_success=$(echo "$LOG1D" 2>&1 | grep PUT_REPAIR | grep uploaded -c)
#count of canceled uploads repaired pieces
put_repair_canceled=$(echo "$LOG1D" 2>&1 | grep PUT_REPAIR | grep 'upload canceled' -c)
#count of failed uploads repaired pieces
put_repair_failed=$(echo "$LOG1D" 2>&1 | grep PUT_REPAIR | grep 'upload failed' -c)
put_repair_failed_text=$(echo "$LOG1H" 2>&1 | grep PUT_REPAIR | grep 'upload failed')
#Ratio of Fail PUT_REPAIR
if [ $(($put_repair_success+$put_repair_failed+$put_repair_canceled)) -ge 1 ]
then
	put_repair_failratio=$(printf '%.2f\n' $(echo -e "$put_repair_failed $put_repair_success $put_repair_canceled" | awk '{print ( $1 / ( $1 + $2 + $3 )) * 100 }'))%
else
	put_repair_failratio=0.000%
fi
#Ratio of Cancel PUT_REPAIR
if [ $(($put_repair_success+$put_repair_failed+$put_repair_canceled)) -ge 1 ]
then
	put_repair_canratio=$(printf '%.2f\n' $(echo -e "$put_repair_canceled $put_repair_success $put_repair_failed" | awk '{print ( $1 / ( $1 + $2 + $3 )) * 100 }'))%
else
	put_repair_canratio=0.000%
fi
#Ratio of Success PUT_REPAIR
put_repair_ratio_int=0
if [ $(($put_repair_success+$put_repair_failed+$put_repair_canceled)) -ge 1 ]
then
	put_repair_ratio_int=$(printf '%.0f\n' $(echo -e "$put_repair_success $put_repair_failed $put_repair_canceled" | awk '{print ( $1 / ( $1 + $2 + $3 )) * 100 }'))
fi
[[ "$VERBOSE" == "true" ]] && echo " *** repair uploads         : c: $put_repair_canratio, f: $put_repair_failratio, s: $put_repair_ratio_int%"


## count upload and download activity last hour
# ------------------------------------

gets_recent_hour=$(echo "$LOG1H" 2>&1 | grep '"GET"' -c)
puts_recent_hour=$(echo "$LOG1H" 2>&1 | grep '"PUT"' -c)
tmp_no_getput_1h=false
[[ $gets_recent_hour -eq 0 ]] && tmp_no_getput_1h=true
[[ $puts_recent_hour -eq 0 ]] && [[ "$tmp_disk_full" == "false" ]] && tmp_no_getput_1h=true
tmp_no_getput_ok="OK"
[[ "$tmp_no_getput_1h" == "true" ]] && tmp_no_getput_ok="NOK"
[[ "$VERBOSE" == "true" ]] && echo " *** $LOGMIN m activity : down: $gets_recent_hour / up: $puts_recent_hour > $tmp_no_getput_ok"


# ignore i/o timeouts (satellite service pings + single satellite connects), if audit success rate is 100% and there are no other errors as well
ignore_rest_of_errors=false
if [[ $tmp_io_errors -ne 0 ]]; then
	if [[ $tmp_rest_of_errors -eq $tmp_io_errors ]]; then
		ignore_rest_of_errors=true
	else
		ignore_rest_of_errors=false
	fi
else
	ignore_rest_of_errors=false
fi
# never ignore in case of audit issues
if [[ $tmp_audits_failed -ne 0 ]]; then
	ignore_rest_of_errors=false
fi
[[ "$VERBOSE" == "true" ]] && echo " *** i/o timouts ignored    : $ignore_rest_of_errors"



# =============================================================================
# CHECKS THE LOG1H PART OF THE LOGS, IF THERE IS A TIME LAG BETWEEN GET_AUDITs 
# LARGER THAN 3 MINUTES, WHICH WILL LEAD TO ALMOST IMMEDIATE DISCQUALIFICATION, 
# IF THE ROOT CAUSE IS NOT IDENTIFIED NOR FIXED. 
# details: https://forum.storj.io/t/auditscore-on-tardigrade-decreased-without-errors/19097/6
# referencing github issue for the storj project: https://github.com/storj/storj/issues/4995
# ------------------------------------ 

tmp_auditTimeLags=$(echo -E $(echo "$LOG1H" |
jq -Rn '
    reduce (
        inputs / "\t" |
        try ( .[4] |= fromjson ) catch empty |
        select(.[4].Action == "GET_AUDIT") |
        [
            ( .[0] | sub("\\.\\d+Z$"; "Z") | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime ),
            .[3],
            .[4]."Satellite ID",
            .[4]."Piece ID"
        ]
    ) as [ $time, $event, $satelliteID, $pieceID ] (
        [{},{}];
        if $event == "download started"
        then
            .[1][$pieceID] = $time
        else
            if (.[1] | has($pieceID) | not) or ($time - .[1][$pieceID]) / 60 > 3
            then
                .[0][$satelliteID] += 1
            else
                .
            end
        end
    ) |
    if .[0] != {} then .[0] else empty end
'))

# help variable to test, if content is null or not
[ -n "$tmp_auditTimeLags" ] && tmp_auditTimeLagsFilled=true || tmp_auditTimeLagsFilled=false

[[ "$DEBUG" == "true" ]] && echo "... audit time lags selection: $tmp_auditTimeLags"



fi # // end of if clause for skipping docker logs analysis



# =============================================================================
# LOAD AND UPDATE SETTINGS FILE WITH ESTIMATED PAYOUTS PER STORJ NODE (SN)
# ------------------------------------

    if [[ "$UNAMEOUT" == "Darwin" ]] ; then
        tmp_timestamp=$(date -ju +"%s"); 
        tmp_todayDay=$(date -ju +"%-d"); 
        tmp_todayHour=$(date -ju +"%-H"); 
        tmp_todayMinutes=$(date -ju +"%-M"); 
    else
        tmp_timestamp=$(date --utc +"%s");
        tmp_todayDay=$(date --utc +"%-d");
        tmp_todayHour=$(date --utc +"%-H"); 
        tmp_todayMinutes=$(date --utc +"%-M" ); 
    fi


    if [ ! -r "$settings_file" ]; then
        [[ "$VERBOSE" == "true" ]] && echo "warning: settings file could not be read; skipping payout estimation."
        include_current_earnings=false;
    else
        while IFS='=' read -d $'\n' -r k v; do
          # Skip lines starting with sharp or lines containing only space or empty lines
          [[ "$k" =~ ^([[:space:]]*|[[:space:]]*#.*)$ ]] && continue
          settings[$k]="$v"
        done < "$settings_file"
        
        [[ "$DEBUG" == "true" ]] && echo "... settings read: ($(typeset -p settings))."
                
        # initiate local variables 
        tmp_payComplete=false
        tmp_payValid=false
        tmp_payDiff=0        
        
        [[ "$DEBUG" == "true" ]] && echo "... settings : tmp_todayDay=$tmp_todayDay";
        [[ "$DEBUG" == "true" ]] && echo "... settings : tmp_todayHour=$tmp_todayHour";
        [[ "$DEBUG" == "true" ]] && echo "... settings : tmp_todayMinutes=$tmp_todayMinutes";
    
        # check availability of $NODE_payTimestamp variable
        if [[ ${settings["${NODE}_payTimestamp"]+Y} ]]; then
            if [[ ${settings["${NODE}_payTimestamp"]} ]]; then
                # ... not empty, great!
                [[ "$DEBUG" == "true" ]] && echo "... settings : ${NODE}_payTimestamp found."
            else
                [[ "$DEBUG" == "true" ]] && echo "... settings : ${NODE}_payTimestamp found, but empty."
                updateSettings "${NODE}_payTimestamp" "${tmp_timestamp}";
                settings["${NODE}_payTimestamp"]=$tmp_timestamp;
            fi
        else 
            [[ "$DEBUG" == "true" ]] && echo "warning: settings: ${!NODE}_payTimestamp not found."
            updateSettings "${NODE}_payTimestamp" "${tmp_timestamp}";
            settings["${NODE}_payTimestamp"]=$tmp_timestamp;
        fi
    
        # check availability of $NODE_payValue variable
        if [[ ${settings["${NODE}_payValue"]+Y} ]]; then
            if [[ ${settings["${NODE}_payValue"]} ]]; then
                # ... not empty, great!
                [[ "$DEBUG" == "true" ]] && echo "... settings : ${NODE}_payValue found."
                :
            else
                [[ "$DEBUG" == "true" ]] && echo "... settings : ${NODE}_payValue found, but empty."
                updateSettings "${NODE}_payValue" "0";
                settings["${NODE}_payValue"]=0;
            fi
        else 
            [[ "$DEBUG" == "true" ]] && echo "warning: settings: ${!NODE}_payValue not found."
            updateSettings "${NODE}_payValue" "0";
            settings["${NODE}_payValue"]=0;
        fi
        
        [[ "$DEBUG" == "true" ]] && echo "... settings : ${NODE}_payTimestamp=${settings[${NODE}_payTimestamp]}"
        [[ "$DEBUG" == "true" ]] && echo "... settings : ${NODE}_payValue=${settings[${NODE}_payValue]}"
        
        # if today = 1st of a month; then payValue = 0;
        [[ $tmp_todayDay -eq 1 ]] && settings["${NODE}_payValue"]=0;
        
        tmp_payTimestamp="${settings[${NODE}_payTimestamp]}"
        [[ "$DEBUG" == "true" ]] && echo "... settings : tmp_payTimestamp=$tmp_payTimestamp";
                    
        if [[ "$UNAMEOUT" == "Darwin" ]] ; then
            tmp_payDateDay=$(date -juf "%s" $tmp_payTimestamp +"%-d");
            tmp_payDateHour=$(date -juf "%s" $tmp_payTimestamp +"%-H");
            tmp_payDateMinutes=$(date -juf "%s" $tmp_payTimestamp +"%-M");
        else
            tmp_payDateDay=$(date --utc -d @"${settings[${NODE}_payTimestamp]}" +"%-d");
            tmp_payDateHour=$(date --utc -d @"${settings[${NODE}_payTimestamp]}" +"%-H" ); 
            tmp_payDateMinutes=$(date --utc -d @"${settings[${NODE}_payTimestamp]}" +"%-M" ); 
        fi

        [[ "$DEBUG" == "true" ]] && echo "... settings : tmp_payDateDay=$tmp_payDateDay"
        [[ "$DEBUG" == "true" ]] && echo "... settings : tmp_payDateHour=$tmp_payDateHour"
        [[ "$DEBUG" == "true" ]] && echo "... settings : tmp_payDateMinutes=$tmp_payDateMinutes"
        
        # if payDate  = yesterday (or different than today); then payValid = true; else payValid = false;
        if [[ $tmp_payDateDay -ne $tmp_todayDay ]]; then 
            tmp_payValid=true;
            [[ "$DEBUG" == "true" ]] && echo "... settings : tmp_payValid=$tmp_payValid"
            # if payDate timestamp between 23:50:00 and 23:59:59 (hh:mm:ss); then payComplete = true; else payComplete = false;
            [[ $tmp_payDateHour -eq 23 ]] && [[ $tmp_payDateMinutes -ge 50 ]] && [[ $tmp_payDateMinutes -le 59 ]] && tmp_payComplete=true;
            [[ "$DEBUG" == "true" ]] && echo "... settings : tmp_payComplete=$tmp_payComplete"
        fi
        
        # select payout data with jq from storage node API
        tmp_estimated_payout_curl=$(curl -s "$node_url/api/sno/estimated-payout")
        tmp_egressBandwidthPayout=$(echo -E $(echo -E "$tmp_estimated_payout_curl" | jq '.currentMonth.egressBandwidthPayout'));
        [[ "$DEBUG" == "true" ]] && echo "... settings : tmp_egressBandwidthPayout=$tmp_egressBandwidthPayout"
        tmp_egressRepairAuditPayout=$(echo -E $(echo -E "$tmp_estimated_payout_curl" | jq '.currentMonth.egressRepairAuditPayout'));
        [[ "$DEBUG" == "true" ]] && echo "... settings : tmp_egressRepairAuditPayout=$tmp_egressRepairAuditPayout"
        tmp_diskSpacePayout=$(echo -E $(echo -E "$tmp_estimated_payout_curl" | jq '.currentMonth.diskSpacePayout'));
        [[ "$DEBUG" == "true" ]] && echo "... settings : tmp_diskSpacePayout=$tmp_diskSpacePayout"
        tmp_currentMonthExpectations=$(echo -E $(echo -E "$tmp_estimated_payout_curl" | jq '.currentMonthExpectations'));
        [[ "$DEBUG" == "true" ]] && echo "... settings : tmp_currentMonthExpectations=$tmp_currentMonthExpectations"
        # sum up estimatedPayoutTotal for the current month in dollar-cents
        tmp_estimatedPayoutTotal=$(echo "$tmp_egressBandwidthPayout + $tmp_egressRepairAuditPayout + $tmp_diskSpacePayout" | bc);
        [[ "$DEBUG" == "true" ]] && echo "... settings : tmp_estimatedPayoutTotal calculated: $tmp_estimatedPayoutTotal"
        # ... calculate payDiff (=earnings for today) from estimatedPayoutTotal <minus> settings["${NODE}_payValue"]
        tmp_payDiff=$(echo "$tmp_estimatedPayoutTotal - ${settings[${NODE}_payValue]}" | bc);
        [[ "$DEBUG" == "true" ]] && echo "... settings : tmp_payDiff=$tmp_payDiff"
        
        # pay data and last timestamp valid and current timestamp at the end of the current day, then store new values
        if [[ $tmp_todayHour -eq 23 && $tmp_todayMinutes -ge 50 && $tmp_todayMinutes -le 59 ]]; then
            if [[ "$tmp_payValid" == "true" &&  "$tmp_payComplete" == "true" ]]; then
                # set payValue = estimatedPayoutTotal --> persistent storage !!
                updateSettings "${NODE}_payValue" "$tmp_estimatedPayoutTotal";
                # set payDate  = timestamp            --> persistent storage !!
                updateSettings "${NODE}_payTimestamp" "$tmp_timestamp";
            elif [[ "$tmp_payValid" == "true" &&  "$tmp_payComplete" == "false" && settings["${NODE}_payValue"] == "0" ]]; then
                # in case of new nodes added to the settings with initial setup during the day, 
                # the timestamp update will fix the 'complete' checks and calculations on the first evening.
                # note: this is not a full solution, but values will be correct from the second day onwards.
                updateSettings "${NODE}_payTimestamp" "$tmp_timestamp";
            fi # // end of store new values if clause
            
        fi # // end of payout estimation if clause
    fi # // end of $settings_file readable if clause
    


# =============================================================================
# CONCATENATE THE PUSH MESSAGE
# ------------------------------------

#reset DLOG
DLOG=""

# only send disk usage and current earnings yes/no
if [[ "$current_earnings_only" == "false" ]]; then

if [[ $tmp_fatal_errors -eq 0 ]] && [[ $tmp_io_errors -eq $tmp_rest_of_errors ]] && [[ $tmp_audits_failed -eq 0 ]] && [[ $temp_severe_errors -eq 0 ]] && [[ $tmp_reps_failed -eq 0 ]] && [[ "$tmp_auditTimeLagsFilled" == "false" ]]; then 
	DLOG="$DLOG [$NODE] : hdd $tmp_disk_gross"
    if [[ "$include_current_earnings" == "true" ]] ; then
        tmp_estimatedPayoutTotalString=$(printf '%.2f\n' $(echo -e "$tmp_payDiff" | awk '{print ( $1 * 1 ) / 100}'))\$
        tmp_estimatedPayoutTodayString=$(printf '%.2f\n' $(echo -e "$tmp_estimatedPayoutTotal" | awk '{print ( $1 * 1 ) / 100}'))\$
        DLOG="$DLOG | d: $tmp_estimatedPayoutTotalString | m: $tmp_estimatedPayoutTodayString";
        [[ "$tmp_payComplete" == "false" ]] && DLOG="$DLOG (!)";
    fi
else
	DLOG="**warning** [$NODE] : "
fi

if [[ "$tmp_auditTimeLagsFilled" == "true" ]]; then
	DLOG="$DLOG audit issues: download started/finished time lags"
fi

if [[ $tmp_audits_failed -ne 0 ]]; then
	DLOG="$DLOG audit issues: $tmp_audits_failed // $audit_failed_warn recoverable + $audit_failed_crit critical"
fi

if [[ $tmp_reps_failed -ne 0 ]]; then
	DLOG="$DLOG repair issues ($tmp_reps_failed) "
fi

# if [[ $audit_difference -gt 1 ]]; then
#	 DLOG="$DLOG audit warning (pending: $audit_difference)"
# fi

if [[ $temp_severe_errors -ne 0 ]]; then
	DLOG="$DLOG severe issues ($temp_severe_errors) "
fi

if [[ $tmp_fatal_errors -ne 0 ]]; then
	DLOG="$DLOG fatal issues ($tmp_fatal_errors) "
fi

if [[ $tmp_rest_of_errors -ne 0 ]]; then
	if [[ $tmp_io_errors -ne $tmp_rest_of_errors ]]; then
		DLOG="$DLOG other issues ($tmp_rest_of_errors)"
	else
		DLOG="$DLOG (skipped io)"
	fi
fi

if [[ "$tmp_overused_warning" == "true" ]] ; then
    DLOG="$DLOG \n.. space warning : overused"
fi


if [ $get_repair_started -ne 0 -a $get_repair_ratio_int -lt 95 ]; then
	DLOG="$DLOG \n.. warning !! rep ↓ $get_repair_ratio_int\n-> risk of getting disqualified"
fi

if [[ $gets_recent_hour -eq 0 ]] && [[ $puts_recent_hour -eq 0 ]]; then
	DLOG="$DLOG \n.. warning !! no get/put in last $LOGMINm"
fi

if [ $get_ratio_int -lt 60 -o \( $put_ratio_int -lt 60 -a "$tmp_disk_full" == "false" \) ]; then
	DLOG="$DLOG \n.. warning !! ↓ $get_ratio_int / ↑ $put_ratio_int low"
fi

if [[ "$storj_newer_version" == "true" ]] ; then
    DLOG="$DLOG \n.. new version : $storj_version_current > $storj_version_latest" #  [$storj_version_date]
fi

else 

    # only send disk usage and current earnings
    DLOG="$DLOG [$NODE] : hdd $tmp_disk_gross"
    if [[ "$include_current_earnings" == "true" ]] ; then
        tmp_estimatedPayoutTotalString=$(printf '%.2f\n' $(echo -e "$tmp_payDiff" | awk '{print ( $1 * 1 ) / 100}'))\$
        tmp_estimatedPayoutTodayString=$(printf '%.2f\n' $(echo -e "$tmp_estimatedPayoutTotal" | awk '{print ( $1 * 1 ) / 100}'))\$
        DLOG="$DLOG | d: $tmp_estimatedPayoutTotalString | m: $tmp_estimatedPayoutTodayString";
        [[ "$tmp_payComplete" == "false" ]] && DLOG="$DLOG (!)";
    fi

fi


# =============================================================================
# SEND THE PUSH MESSAGE TO DISCORD
# ------------------------------------

cd $DIR

if [[ "$DISCORDON" == "true" ]]; then
[[ "$VERBOSE" == "true" ]] && echo " *** discord summary push to be sent: $SENDPUSH"
# send discord push

    # only send disk usage and current earnings yes/no
    if [[ "$current_earnings_only" == "false" ]]; then

        if [ $tmp_fatal_errors -ne 0 -o $tmp_io_errors -ne $tmp_rest_of_errors -o \
            $tmp_audits_failed -ne 0 -o $temp_severe_errors -ne 0 -o \
            \( $get_repair_started -ne 0 -a $get_repair_ratio_int -lt 95 \) -o \
            $tmp_reps_failed -ne 0 -o $get_ratio_int -lt 60 -o \
            \( $put_ratio_int -lt 60 -a "$tmp_disk_full" == "false" \) -o \
            "$tmp_no_getput_1h" == "true" -o "$SENDPUSH" == "true" -o "$tmp_auditTimeLagsFilled" == "true" ]; then

                { ./discord.sh --webhook-url="$DISCORDURL" --username "health check" --text "$DLOG"; } 2>/dev/null
                [[ "$VERBOSE" == "true" ]] && echo " *** discord summary push sent : $DLOG"
        fi

        # separated satellites push from errors, occured last $LOGMIN - as scores last "longer"
        # and push frequency limited by $satellite_notification anyway
        if [ ! -z "$satellite_scores" ] && [[ "$satellite_notification" == "true" ]]; then
            { ./discord.sh --webhook-url="$DISCORDURL" --username "satellites warning" --text "[$NODE]: $satellite_scores"; } 2>/dev/null
            [[ "$VERBOSE" == "true" ]] && echo " *** discord satellite push sent: $DLOG"
        fi

        # in case of discord debug mode is on, also send success statistics
        # in case discord is configured and it is "end of the day", send push anyway as a summary
        [[ "$DEBUG" == "true" ]] && echo "... push message sending: sendpush: $SENDPUSH, discordon: $DISCORDON, hour: $tmp_todayHour, minutes: $tmp_todayMinutes, details: $DETAILEDSUCCESSRATES";


        if [[ "$DETAILEDSUCCESSRATES" == "false" ]]; then
            tmp_audits="";
            tmp_downloads="";
            tmp_uploads="";
            tmp_downReps="";
            tmp_upReps="";
            tmp_count=0;
        
            [[ "$audit_successrate" != "100%" ]] && tmp_audits="\n.. audits (r: $audit_recfailrate, c: $audit_failrate, s: $audit_successrate)" && ((tmp_count=tmp_count+1));
            [[ $get_ratio_int -lt 98 ]] && tmp_downloads="\n.. downloads (c: $dl_canratio, f: $dl_failratio, s: $get_ratio_int%)" && ((tmp_count=tmp_count+1));
            [[ $put_ratio_int -lt 98 ]] && tmp_uploads="\n.. uploads (c: $put_cancel_ratio, f: $put_fail_ratio, s: $put_ratio_int%)" && ((tmp_count=tmp_count+1));
            [[ $get_repair_ratio_int -lt 100 ]] && tmp_downReps="\n.. rep down (c: $get_repair_canratio, f: $get_repair_failratio, s: $get_repair_ratio_int%)" && ((tmp_count=tmp_count+1));
            [[ $put_repair_ratio_int -lt 100 ]] && tmp_putReps="\n.. rep up (c: $put_repair_canratio, f: $put_repair_failratio, s: $put_repair_ratio_int%)" && ((tmp_count=tmp_count+1));
        
            # only send push message, in case some scores are below 98%
            if [[ $tmp_count -gt 0 ]]; then
                tmp_fullString="[$NODE]";
                [[ "$tmp_audits" != "" ]] && tmp_fullString="$tmp_fullString $tmp_audits";
                [[ "$tmp_downloads" != "" ]] && tmp_fullString="$tmp_fullString $tmp_downloads";
                [[ "$tmp_uploads" != "" ]] && tmp_fullString="$tmp_fullString $tmp_uploads";
                [[ "$tmp_downReps" != "" ]] && tmp_fullString="$tmp_fullString $tmp_downReps";
                [[ "$tmp_upReps" != "" ]] && tmp_fullString="$tmp_fullString $tmp_upReps";
                if [[ "$SENDPUSH" == "true" ]]; then
                    { ./discord.sh --webhook-url="$DISCORDURL" --username "one-day stats" --text "$tmp_fullString"; } 2>/dev/null
                    [[ "$VERBOSE" == "true" ]] && echo " *** discord success rates push sent."
                fi
            else
                [[ "$VERBOSE" == "true" ]] && echo " *** no discord success rates to be sent."
            fi
        
        elif [[ "$SENDPUSH" == "true" ]]; then
            { ./discord.sh --webhook-url="$DISCORDURL" --username "one-day stats" --text "[$NODE]\n.. audits (r: $audit_recfailrate, c: $audit_failrate, s: $audit_successrate)\n.. downloads (c: $dl_canratio, f: $dl_failratio, s: $get_ratio_int%)\n.. uploads (c: $put_cancel_ratio, f: $put_fail_ratio, s: $put_ratio_int%)\n.. rep down (c: $get_repair_canratio, f: $get_repair_failratio, s: $get_repair_ratio_int%)\n.. rep up (c: $put_repair_canratio, f: $put_repair_failratio, s: $put_repair_ratio_int%)"; } 2>/dev/null
            [[ "$VERBOSE" == "true" ]] && echo " *** discord success rates push sent."
        fi
  

    elif [[ "$SENDPUSH" == "true" ]]; then
        # only send disk usage and estimated earnings
        { ./discord.sh --webhook-url="$DISCORDURL" --username "current earnings" --text "$DLOG"; } 2>/dev/null
        [[ "$VERBOSE" == "true" ]] && echo " *** discord summary push sent (earnings) : $DLOG"
    fi
fi


# =============================================================================
# SEND EMAIL ALERTS WITH ERROR DETAILS (and debug mail to verify mail works)
# ------------------------------------


# send email alerts
if [[ "$MAILON" == "true" ]] && [[ "$current_earnings_only" == "false" ]]; then

if [ ! -z "$satellite_scores" ] && [[ "$satellite_notification" == "true" ]]; then
    $SWAKSCMD --h-Subject "$NODE : SATELLITE SCORES BELOW THRESHOLD" --body "$satellite_scores" --silent "1"
	[[ "$VERBOSE" == "true" ]] && echo " *** satellite warning mail sent."
fi

if [[ "$tmp_auditTimeLagsFilled" == "true" ]]; then 
	$SWAKSCMD --h-Subject "$NODE : AUDIT TIME LAGS FOUND > risk of being disqualified" --body "risk of being disqualified!! \n\n$tmp_auditTimeLags" --silent "1"
	[[ "$VERBOSE" == "true" ]] && echo " *** audit time lag warning mail sent."
fi
if [[ $tmp_fatal_errors -ne 0 ]]; then 
	echo "$FATS" > tmp.txt && zip tmp.zip tmp.txt 
	$SWAKSCMD --h-Subject "$NODE : FATAL ERRORS FOUND" --body "see attachment" --attach ./tmp.zip --silent "1"
	[[ "$VERBOSE" == "true" ]] && echo " *** fatal error mail sent."
fi
if [[ $temp_severe_errors -ne 0 ]]; then 
    echo "$SEVERE" > tmp.txt && zip tmp.zip tmp.txt 
	$SWAKSCMD --h-Subject "$NODE : SEVERE ERRORS FOUND" --body "see attachment" --attach ./tmp.zip --silent "1"
	[[ "$VERBOSE" == "true" ]] && echo " *** severe error mail sent."
fi
if [[ $tmp_rest_of_errors -ne 0 ]]; then
    echo "$ERRS" > tmp.txt && zip tmp.zip tmp.txt 
	if [[ "$ignore_rest_of_errors" == "true" ]]; then
		if [[ "$SENDPUSH" == "true" ]]; then
			$SWAKSCMD --h-Subject "$NODE : OTHER ERRORS FOUND" --body "see attachment" --attach ./tmp.zip --silent "1"
			[[ "$VERBOSE" == "true" ]] && echo " *** general error mail sent (ignore case: $ignore_rest_of_errors)."
		fi
	else 
		$SWAKSCMD --h-Subject "$NODE : OTHER ERRORS FOUND" --body "see attachment" --attach ./tmp.zip --silent "1"
		[[ "$VERBOSE" == "true" ]] && echo " *** general error mail sent (ignore case: $ignore_rest_of_errors)."
	fi
fi
if [[ $tmp_audits_failed -ne 0 ]]; then 
	$SWAKSCMD --h-Subject "$NODE : AUDIT ERRORS FOUND" --body "Recoverable: $audit_failed_warn / $audit_recfailrate \n\n$audit_failed_warn_text \n\nCritical: $audit_failed_crit / $audit_failrate \n\n$audit_failed_crit_text" --silent "1"
	[[ "$VERBOSE" == "true" ]] && echo " *** audit error mail sent."
fi
# if [[ "$audit_difference_repeat" == "false" ]]; then
    # only alert when there is a) just one or b) the first run done of the "audit pending loop"
#     if [[ $audit_difference -gt 0 ]]; then 
# 	    $SWAKSCMD --h-Subject "$NODE : AUDIT WARNING - pending audits" --body "Warning: there are $audit_difference pending audits, which have not yet been finished." --silent "1"
# 	    [[ "$VERBOSE" == "true" ]] && echo " *** pending audit warning mail sent."
# 	fi
# fi
if [[ $tmp_reps_failed -ne 0 ]]; then 
    echo "$DREPS" > tmp.txt && zip tmp.zip tmp.txt  
	$SWAKSCMD --h-Subject "$NODE : REPAIR FAILURES FOUND" --body "see attachment" --attach ./tmp.zip --silent "1"
	[[ "$VERBOSE" == "true" ]] && echo " *** repair failures mail sent."
fi

# send debug mail 
if [[ "$SENDMAIL" == "true" ]]; then
	$SWAKSCMD --h-Subject "$NODE : DEBUG TEST MAIL" --body "blobb." --silent "1"
	[[ "$VERBOSE" == "true" ]] && echo " *** debug mail sent."
fi

fi


### > check if storagenode is runnning; if not, cancel analysis and push alert
###   email alert comes automatically through uptimerobot-ping alert. 
###   if relevant for you, enable the mail alert below.
else
	[[ "$VERBOSE" == "true" ]] && echo "warning: $NODE not running."
	if [[ "$DISCORDON" == "true" ]]; then
	    cd $DIR
	    { ./discord.sh --webhook-url="$DISCORDURL" --username "storj stats" --text "**warning :** $NODE not running!"; } 2>/dev/null
	fi
	#$SWAKSCMD --h-Subject "$NODE : NOT RUNNING" --body "warning: storage node is not running." --silent "1"
fi


# if there are pending audits, run the script for the specific node a second time after 5 mins
# if [[ $audit_difference -gt 0 ]] && [[ "$audit_difference_repeat" == "true" ]]; then
    # i=$((i-1))                           # repeat the loop with current i value
    # [[ "$VERBOSE" == "true" ]] && echo " *** due to pending audits, running the script in 5m automatically again."
    # sleep 5m                             # sleep for 5mins to allow audits to be finalized
# fi

done # end of storagenodes FOR loop
