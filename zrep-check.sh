#!/bin/bash

set -euo pipefail

limit_daily=""
limit_weekly=""
noop_mode=""
debug_mode=""
generate_debug_txt=""

export PATH="/root/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# shellcheck disable=SC1091
#. /etc/zabbix/userparams/config

export slack_url_post='https://slack.com/api/chat.postMessage'
# https://api.slack.com/authentication/oauth-v2
#slack_token='<Bot User OAuth Token>'
#slack_channel='<channel>'
# shellcheck disable=SC1091
# Notification configuration is loaded only when a message is sent.

f_check_switch_param(){
  if echo x"$1" |grep -q ^x$;
   then
     echo "Missing argument!"
     exit 1
  fi
}


f_usage(){
  echo "Usage:"
  echo " $0 -d <days> -w <days> [ --debug ] [ --noop ]"
  echo " $0 --generate-debug-txt"
  echo " $0 -h|--help"
  echo
  echo "-d|--daily <days>      set the alert limit for the last daily snapshot"
  echo "-w|--weekly <days>     set the alert limit for the last weekly snapshot"
  echo "--generate-debug-txt   generate /root/zrep-check-debug.txt for speed up debugging"
  exit 1
}

# Exit if no arguments!
(( $# )) || f_usage

while [ "$#" -gt "0" ]; do
  case "$1" in
    -d|--daily)
      PARAM=${2:-}
      f_check_switch_param "$PARAM"
      [[ "$PARAM" =~ ^[0-9]{1,6}$ ]] || f_usage
      limit_daily=$((10#$PARAM))
      shift 2
    ;;

    -w|--weekly)
      PARAM="${2:-}"
      f_check_switch_param "$PARAM"
      [[ "$PARAM" =~ ^[0-9]{1,6}$ ]] || f_usage
      limit_weekly=$((10#$PARAM))
      shift 2
    ;;

    --noop)
      noop_mode=1
      shift 1
    ;;

    --debug)
      debug_mode=1
      shift 1
    ;;

    --generate-debug-txt)
      generate_debug_txt=1
      shift 1
    ;;

    *)
      f_usage
    ;;

   esac
done

date_today=$(date "+%Y-%m-%d")


f_slack_post() {
  local slack_text="$1"
  # shellcheck disable=SC1091
  . /etc/slack-notification.conf
  # shellcheck disable=SC2154
  curl --fail --data-urlencode "text=$slack_text" --data-urlencode "channel=$slack_channel" --data-urlencode "token=$slack_token" -s -X POST "$slack_url_post" > /dev/null
}

f_date_to_epoch () {
  date --utc --date "$1" +%s
}

f_date_diff (){
  case "$1" in
    -s)   sec=1;      shift;;
    -m)   sec=60;     shift;;
    -h)   sec=3600;   shift;;
    -d)   sec=86400;  shift;;
    *)    sec=86400;;
  esac
  dte1=$(f_date_to_epoch "$1")
  dte2=$(f_date_to_epoch "$2")
  diffSec=$((dte2-dte1))
  echo $((diffSec/sec))
}


if [ -n "$generate_debug_txt" ];
  then
    echo -n "Generating /root/zrep-check-debug.txt for debugging purposes... "
    zfs list -t all -r tank/zrep -o name -H -s name > /root/zrep-check-debug.txt
    echo "done."
    exit 0
fi

if [ -z "$debug_mode" ];
  then
    snap_list_file=$(mktemp /tmp/snap_list_file.XXXX)
    trap 'rm -f -- "$snap_list_file"' EXIT
    zfs list -t all -r tank/zrep -o name -H -s name > "$snap_list_file"
  else
    snap_list_file='/root/zrep-check-debug.txt'
fi

# Ignore organizational parents (root, extended host, and VM wrapper datasets).
dataset_list=$(awk '!/@/ { names[$0]=1 } END {
  for (name in names) {
    parent=0
    for (other in names) if (index(other, name "/")==1) parent=1
    if (!parent && name!="tank/zrep") print name
  }
}' "$snap_list_file")

f_check_late(){
  dataset="$1"
  freq="$2"
  days_limit="$3"

  snap_last_item=$(awk -v prefix="${dataset}@" -v freq="$freq" '
    index($0,prefix)==1 {
      name=substr($0,length(prefix)+1)
      sub(/^snapshot-/,"",name)
      if (index(name,"zas-" freq "-")==1) print name
    }' "$snap_list_file" | sort | tail -1)
  if [ "$snap_last_item" = "" ];
    then
      msg="DEBUG: !!! WARNING !!!: *${dataset}* has *NO VALID '${freq}' SNAPSHOT*!"
      if [ -z "$debug_mode" ];
        then
          echo "$msg"
          if [[ -z "$noop_mode" ]]; then f_slack_post "$msg"; fi
        else
          echo "DEBUG: $msg"
          if [[ -z "$noop_mode" ]]; then f_slack_post "DEBUG: $msg"; fi
      fi
      return 0
 fi
  date_last_snap=$(echo "$snap_last_item" | grep -o "[0-9]\{4\}-[0-9][0-9]-[0-9][0-9]")
  days_diff=$(f_date_diff -d "$date_last_snap" "$date_today")

  if (( "$days_diff" > "$days_limit" ));
    then
      msg="Time spent since the last *${freq}* backup of *${dataset}*: *${days_diff} days*"
      if [ -z "$debug_mode" ];
        then
          echo "$msg"
          if [[ -z "$noop_mode" ]]; then f_slack_post "$msg"; fi
        else
          echo "DEBUG: $msg"
          if [[ -z "$noop_mode" ]]; then f_slack_post "DEBUG: $msg"; fi
      fi
  fi
}

if [ "$limit_daily" ];
  then
    for d in $dataset_list;do
      f_check_late "$d" daily "$limit_daily";
    done
fi

if [ "$limit_weekly" ];
  then
    for d in $dataset_list;do
      f_check_late "$d" weekly "$limit_weekly";
    done
fi

exit 0
