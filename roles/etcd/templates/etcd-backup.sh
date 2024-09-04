#!/usr/bin/env bash

### Created by cluster-etcd-operator. DO NOT edit.

set -o errexit
set -o pipefail
set -o errtrace

# example
# cluster-backup.sh $path-to-snapshot

if [[ $EUID -ne 0 ]]; then
  echo "This script must be run as root"
  exit 1
fi

function usage {
  echo 'Path to backup dir required: ./cluster-backup.sh [--force] <path-to-backup-dir>'
  exit 1
}

IS_DIRTY=""
if [ "$1" == "--force" ]; then
  IS_DIRTY="__POSSIBLY_DIRTY__"
  shift
fi

# If the first argument is missing, or it is an existing file, then print usage and exit
if [ -z "$1" ] || [ -f "$1" ]; then
  usage
fi

if [ ! -d "$1" ]; then
  mkdir -p "$1"
fi

#function check_if_operator_is_progressing {
#   local operator="$1"
#
#   if [ ! -f "${KUBECONFIG}" ]; then
#      echo "Valid kubeconfig is not found in kube-apiserver-certs. Exiting!"
#      exit 1
#   fi
#
#   progressing=$(oc get co "${operator}" -o jsonpath='{.status.conditions[?(@.type=="Progressing")].status}') || true
#   if [ "$progressing" == "" ]; then
#      echo "Could not find the status of the $operator. Check if the API server is running. Pass the --force flag to skip checks."
#      exit 1
#   elif [ "$progressing" != "False" ]; then
#      echo "Currently the $operator operator is progressing. A reliable backup requires that a rollout is not in progress.  Aborting!"
#      exit 1
#   fi
#}

# backup latest static pod resources
function backup_latest_kube_static_resources {
  local backup_tar_file="$1"
  local CONFIG_FILE_DIR="/etc/kubernetes/manifests"

  # tar latest resources with the path relative to CONFIG_FILE_DIR
  tar -cpzf "$backup_tar_file" "${CONFIG_FILE_DIR}"
  chmod 600 "$backup_tar_file"
}

function source_required_dependency {
  local src_path="$1"
  if [ ! -f "${src_path}" ]; then
    echo "required dependencies not found, please ensure this script is run on a node with a functional etcd static pod"
    exit 1
  fi
  # shellcheck disable=SC1090
  source "${src_path}"
}

BACKUP_DIR="$1"
DATESTRING=$(date "+%F_%H%M%S")
BACKUP_TAR_FILE=${BACKUP_DIR}/static_kuberesources_${DATESTRING}${IS_DIRTY}.tar.gz
SNAPSHOT_FILE="${BACKUP_DIR}/snapshot_${DATESTRING}${IS_DIRTY}.db"

trap 'rm -f ${BACKUP_TAR_FILE} ${SNAPSHOT_FILE}' ERR

source_required_dependency /usr/local/bin/etcd.env
source_required_dependency /usr/local/bin/etcd-common-tools

# replacing the value of variables sourced form etcd.env to use the local node folders if the script is not running into the cluster-backup pod
if [ ! -f "${ETCDCTL_CACERT}" ]; then
  echo "Certificate ${ETCDCTL_CACERT} is missing. Checking in different directory"
  export ETCDCTL_CACERT=$(echo ${ETCDCTL_CACERT} | sed -e "s|static-pod-certs|static-pod-resources/etcd-certs|")
  export ETCDCTL_CERT=$(echo ${ETCDCTL_CERT} | sed -e "s|static-pod-certs|static-pod-resources/etcd-certs|")
  export ETCDCTL_KEY=$(echo ${ETCDCTL_KEY} | sed -e "s|static-pod-certs|static-pod-resources/etcd-certs|")
  if [ ! -f "${ETCDCTL_CACERT}" ]; then
    echo "Certificate ${ETCDCTL_CACERT} is also missing in the second directory. Exiting!"
    exit 1
  else
    echo "Certificate ${ETCDCTL_CACERT} found!"
  fi
fi

backup_latest_kube_static_resources "${BACKUP_TAR_FILE}"

# Download etcdctl and get the etcd snapshot
#dl_etcdctl

# snapshot save will continue to stay in etcdctl
ETCDCTL_ENDPOINTS="https://localhost:2379" etcdctl snapshot save "${SNAPSHOT_FILE}"

# Check the integrity of the snapshot
check_snapshot_status "${SNAPSHOT_FILE}"
snapshot_failed=$?

# If check_snapshot_status returned 1 it failed, so exit with code 1
if [[ $snapshot_failed -eq 1 ]]; then
  echo "snapshot failed with exit code ${snapshot_failed}"
  exit 1
fi

echo "snapshot db and kube resources are successfully saved to ${BACKUP_DIR}"
