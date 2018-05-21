#!/bin/bash
# -x
# use !/bin/bash -x to debug command substitution and evaluation instead of echo.
# Dependencies: sshpass

. scripts/common.lib.sh # source common routines
Dependencies 'install';

WORKSHOPS=("Calm Introduction Workshop (AOS/AHV 5.6)" \
"Citrix Desktop on AHV Workshop (AOS/AHV 5.6)" \
#"Tech Summit 2018" \
"Change Cluster Input File" \
"Validate Staged Clusters" \
"Quit")
ATTEMPTS=40;
   SLEEP=60;
#CURL_OPTS="${CURL_OPTS} --verbose"

function remote_exec {
  sshpass -p ${MY_PE_PASSWORD} ssh ${SSH_OPTS} nutanix@${MY_PE_HOST} "$@"
}

function send_file {
  local ATTEMPTS=3;
        FILENAME="${1##*/}"
            LOOP=0;

  while (( LOOP++ < ${ATTEMPTS} )); do
    if (( ${LOOP} == ${ATTEMPTS} )); then
      echo "send_file: giving up after ${LOOP} tries."
      exit 11;
    fi

    SCP_TEST=$(sshpass -p ${MY_PE_PASSWORD} scp ${SSH_OPTS} $1 nutanix@${MY_PE_HOST}:)

    if (( $? == 0 )); then
      my_log "send_file: ${1}: done!"
      break;
    else
      echo "send_file ${LOOP}/${ATTEMPTS}: SCP_TEST=$?|${SCP_TEST}| SLEEPing ${SLEEP}...";
      sleep ${SLEEP};
    fi
  done
}

function acli {
	remote_exec /usr/local/nutanix/bin/acli "$@"
}

# Get list of clusters from user
function get_file {
  read -p 'Cluster Input File: ' CLUSTER_LIST

  if [ ! -f ${CLUSTER_LIST} ]; then
    echo "FILE DOES NOT EXIST!"
    get_file
  fi

  select_workshop
}

# Get workshop selection from user, set script files to send to remote clusters
function select_workshop {
  PS3='Select an option: '
  select WORKSHOP in "${WORKSHOPS[@]}"
  do
    case $WORKSHOP in
      "Calm Introduction Workshop (AOS/AHV 5.6)")
        PE_CONFIG=stage_calmhow.sh
        PC_CONFIG=stage_calmhow_pc.sh
        break
        ;;
      "Citrix Desktop on AHV Workshop (AOS/AHV 5.6)")
        PE_CONFIG=stage_citrixhow.sh
        PC_CONFIG=stage_citrixhow_pc.sh
        break
        ;;
      "Tech Summit 2018")
        PE_CONFIG=stage_ts18.sh
        PC_CONFIG=stage_ts18_pc.sh
        break
        ;;
      "Change Cluster Input File")
        get_file
        break
        ;;
      "Validate Staged Clusters")
        validate_clusters
        break
        ;;
      "Quit")
        exit
        ;;
      *) echo "Invalid entry, please try again.";;
    esac
  done

  read -p "Are you sure you want to stage ${WORKSHOP} to the clusters in ${CLUSTER_LIST}? Your only 'undo' option is running Foundation on your cluster(s) again. (Y/N)" -n 1 -r

  if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo
    stage_clusters
  else
    echo
    echo "Come back soon!"
  fi
}

# Set script files to send to remote clusters based on command line argument
function set_workshop {

  case ${WORKSHOPS[$((${WORKSHOP_NUM}-1))]} in
    "Calm Introduction Workshop (AOS/AHV 5.6)")
      PE_CONFIG=stage_calmhow.sh
      PC_CONFIG=stage_calmhow_pc.sh
      stage_clusters
      ;;
    "Citrix Desktop on AHV Workshop (AOS/AHV 5.6)")
      PE_CONFIG=stage_citrixhow.sh
      PC_CONFIG=stage_citrixhow_pc.sh
      stage_clusters
      ;;
    "Tech Summit 2018")
      PE_CONFIG=stage_ts18.sh
      PC_CONFIG=stage_ts18_pc.sh
      stage_clusters
      ;;
    "Validate Staged Clusters")
      validate_clusters
      ;;
    *) echo "No one should ever see this. Time to panic.";;
  esac
}

# Send configuration scripts to remote clusters and execute Prism Element script
function stage_clusters {
    MY_CURL_OPTS="--header Accept:application/json --output /dev/null -w %{http_code}"
  HTTP_BODY=$(cat <<EOM
{
"kind": "cluster"
}
EOM
  )

  for MY_LINE in `cat ${CLUSTER_LIST} | grep -v ^#`
  do
    set -f
    array=(${MY_LINE//|/ })
    MY_PE_HOST=${array[0]}
    MY_PE_PASSWORD=${array[1]}
    array=(${MY_PE_HOST//./ })
    MY_HPOC_NUMBER=${array[2]}

    #TODO: Check rx cluster foundation status, then PE API login success to proceed!
    # 12 failed SSH login attempts registered, but it took more time than successful email.

    LOOP=0;
    while ((LOOP++)); do

      PE_TEST=$(curl ${CURL_OPTS} ${MY_CURL_OPTS} \
       --user admin:${MY_PE_PASSWORD} -X POST --data "${HTTP_BODY}" \
       https://10.21.${MY_HPOC_NUMBER}.37:9440/api/nutanix/v3/clusters/list \
       | tr -d \") # wonderful addition of "" around HTTP status code by cURL
      if (( $? > 0 )); then
        echo
      fi

      if (( ${LOOP} == ${ATTEMPTS} )); then
        echo "- PE_TEST: Giving up after ${LOOP} tries."
        exit 11;
      elif (( ${PE_TEST} -ne 200 )); then
        echo "- PE_TEST ${LOOP}/${ATTEMPTS}=${PE_TEST}: sleeping ${SLEEP} seconds..."
        sleep ${SLEEP}
      fi

    done

    # rx: 20180518 21:38:52 INFO All 140 cluster services are up
    # we move from: ssh: connect to host 10.21.20.37 port 22: Operation timed out
    # lost connection
    # to: Warning: Permanently added '10.21.20.37' (ECDSA) to the list of known hosts.
    # Nutanix Controller VM
    # Permission denied, please try again.

    # Distribute configuration scripts
    echo "Sending configuration script(s) to ${MY_PE_HOST}"
    cd scripts
    if [ ! -z ${PC_CONFIG} ]; then
      send_file "common.lib.sh ${PE_CONFIG} ${PC_CONFIG}"
    else
      send_file "common.lib.sh ${PE_CONFIG}"
    fi

    # Execute that file asynchroneously remotely (script keeps running on CVM in the background)
    echo "Executing configuration script on ${MY_PE_HOST}"
    remote_exec "MY_PE_PASSWORD=${MY_PE_PASSWORD} nohup bash /home/nutanix/${PE_CONFIG} >> stage_calmhow.log 2>&1 &"
  done

  cat <<EOM
Progress of individual clusters can be monitored by:
 $ ssh nutanix@${MY_PE_HOST} 'tail -f stage_calmhow.log'"
 $ sshpass -p ${MY_PE_PASSWORD} ssh ${SSH_OPTS} nutanix@${MY_PE_HOST} 'tail -f stage_calmhow.log'
   https://${MY_PE_HOST}:9440/
 $ sshpass -p 'nutanix/4u' ssh ${SSH_OPTS} nutanix@10.21.${MY_HPOC_NUMBER}.39 'tail -f stage_calmhow_pc.log'
EOM
  exit
}

function validate_clusters {
  MY_CURL_OPTS="${CURL_OPTS} --header Accept:application/json --output /dev/null -w %{http_code}"
  HTTP_BODY=$(cat <<EOM
{
  "kind": "cluster"
}
EOM
  )

  for MY_LINE in `cat ${CLUSTER_LIST} | grep -v ^#`
  do
    set -f
    array=(${MY_LINE//|/ })
    MY_PE_HOST=${array[0]}
    MY_PE_PASSWORD=${array[1]}
    array=(${MY_PE_HOST//./ })
    MY_HPOC_NUMBER=${array[2]}

    LOOP=0;
    PC_TEST=0;
    while (( ${PC_TEST} != 200 )); do
      ((LOOP++))
      if (( ${LOOP} > ${ATTEMPTS} )); then
        echo "Giving up after ${LOOP} tries."
        exit 11;
      fi

      PC_TEST=$(curl ${MY_CURL_OPTS} \
       --user admin:${MY_PE_PASSWORD} -X POST -d "${HTTP_BODY}" \
       https://10.21.${MY_HPOC_NUMBER}.39:9440/api/nutanix/v3/clusters/list \
       | tr -d \") # wonderful addition of "" around HTTP status code by cURL

      echo -e "\n__PC_TEST ${LOOP}=${PC_TEST}: sleeping ${SLEEP} seconds...\n"
      sleep ${SLEEP};
    done
    echo "Success: I can find a cluster(s) on PC!"

  done
}

# Display script usage
function usage {
  cat << EOF

    Interactive Usage: ./stage_workshop.sh
Non-interactive Usage: ./stage_workshop.sh -f [cluster_list_file] -w [workshop_number]

Available Workshops:
1) Calm Introduction Workshop (AOS/AHV 5.6)
2) Citrix XenDesktop on Nutanix AHV (AOS/AHV 5.6)

See README.md for more information :+1:

EOF
exit
}

# Check if file passed via command line, otherwise prompt for cluster list file
while getopts ":f:w:" opt; do
  case ${opt} in
    f )
    if [ -f ${OPTARG} ]; then
      CLUSTER_LIST=${OPTARG}
    else
      echo "FILE DOES NOT EXIST!"
      usage
    fi
    ;;
    w )
#    if [ $(($OPTARG)) -gt 0 ] && [ $(($OPTARG)) -le $((${#WORKSHOPS[@]}-3)) ]; then
    if [ $(($OPTARG)) -gt 0 ] && [ $(($OPTARG)) -le $((${#WORKSHOPS[@]})) ]; then
      # do something
      WORKSHOP_NUM=${OPTARG}
    else
      echo "INVALID WORKSHOP SELECTION!"
      usage
    fi
    ;;
    \? ) usage;;
  esac
done
shift $((OPTIND -1))

if [ ! -z ${CLUSTER_LIST} ] && [ ! -z ${WORKSHOP_NUM} ]; then
  # If file and workshop selections are valid, begin staging clusters
  set_workshop
elif [ ! -z ${CLUSTER_LIST} ] || [ ! -z ${WORKSHOP_NUM} ]; then
  echo "MISSING ARGUMENTS! CLUSTER_LIST=|${CLUSTER_LIST}|, WORKSHOP_NUM=|${WORKSHOP_NUM}|"
  usage
else
  # If no command line arguments, start interactive session
  get_file
fi
