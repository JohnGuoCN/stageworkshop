#!/usr/bin/env bash
# -x

#__main()__________

# Source Nutanix environment (PATH + aliases), then common routines + global variables
. /etc/profile.d/nutanix_env.sh
. lib.common.sh
. global.vars.sh
begin

args_required 'PE_PASSWORD'

case ${1} in
  PE | pe )
    . lib.pe.sh

    args_required 'PE_HOST PC_LAUNCH'

    dependencies 'install' 'sshpass' && dependencies 'install' 'jq' \
    files_install & # parallel, optional. Versus: $0 'files' &
    log "PE = https://${PE_HOST}:9440"
    finish
  ;;
esac
