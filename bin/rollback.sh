#!/usr/bin/env bash

set -e

if [[ $EUID -ne 0 ]]; then
  echo "This script must be run as root"
  exit 1
fi

ALL_MANIFESTS=/etc/kubernetes/manifests/*
ASSET_DIR=./assets
BACKUP_DIR=/etc/kubernetes/manifests-stopped
SNAPSHOT_FILE=$ASSET_DIR/rollback/snapshot.db
ETCD_VERSION=v3.3.10
ETCD_MANIFEST=etcd-member.yaml
ETCDCTL=$ASSET_DIR/bin/etcdctl
ETCD_DATA_DIR=/var/lib/etcd/
MANIFEST_DIR=/etc/kubernetes/manifests
MANIFEST=/etc/kubernetes/manifests/${ETCD_MANIFEST}

if [ "$1" != "" ]; then
  SNAPSHOT_FILE="$1"
fi

init() {
  ASSET_BIN=${ASSET_DIR}/bin
  if [ ! -d "$ASSET_BIN" ]; then
    echo "Creating asset directory ${ASSET_DIR}"
    for dir in {bin,tmp,shared,backup,restore}
    do
      /usr/bin/mkdir -p ${ASSET_DIR}/${dir}
    done
  fi
  dl_etcdctl $ETCD_VERSION
}

# download and test etcdctl from upstream release assets
dl_etcdctl() {
  ETCD_VER=$1
  GOOGLE_URL=https://storage.googleapis.com/etcd
  DOWNLOAD_URL=${GOOGLE_URL}

  echo "Downloading etcdctl binary.."
  curl -s -L ${DOWNLOAD_URL}/${ETCD_VER}/etcd-${ETCD_VER}-linux-amd64.tar.gz -o $ASSET_DIR/tmp/etcd-${ETCD_VER}-linux-amd64.tar.gz \
    && tar -xzf $ASSET_DIR/tmp/etcd-${ETCD_VER}-linux-amd64.tar.gz -C $ASSET_DIR/shared --strip-components=1 \
    && mv $ASSET_DIR/shared/etcdctl $ASSET_DIR/bin \
    && rm $ASSET_DIR/shared/etcd \
    && ETCDCTL_API=3 $ASSET_DIR/bin/etcdctl version
}

# backup current etcd-member pod manifest
backup_manifest() {
  echo "Backing up ${BACKUP_DIR}/${ETCD_MANIFEST} to ${ASSET_DIR}/backup/"
  cp ${BACKUP_DIR}/${ETCD_MANIFEST} ${ASSET_DIR}/backup/
}

# stop etcd by moving the manifest out of /etcd/kubernetes/manifests
# we wait for all etcd containers to die.
stop_static_pods() {
  echo "Stopping etcd.."

  if [ ! -d "$BACKUP_DIR" ]; then
    mkdir $BACKUP_DIR
  fi

  if [ -e "$MANIFEST" ]; then
    mv $ALL_MANIFESTS $BACKUP_DIR
  fi

  for name in {etcd-member,etcd-metric}
  do
    while [ "$(crictl pods -name $name | wc -l)" -gt 1  ]; do
      echo "Waiting for $name to stop"
      sleep 10
    done
  done
}

verify_snapshot() {
  if [ -f "$SNAPSHOT_FILE" ]; then
    echo "etcd snapshot found $SNAPSHOT_FILE"
  else
    echo "Snapshot file not found: $SNAPSHOT_FILE."
  fi
}

stop_kubelet() {
  echo "Stopping kubelet..."
  systemctl stop kubelet.service
}

stop_all_containers() {
  echo "Stopping all containers..."
  crictl ps -q | xargs -r crictl stop
}

restore_snapshot() {
  HOSTNAME=$(hostname)
  HOSTDOMAIN=$(hostname -d)
  ETCD_NAME=etcd-member-${HOSTNAME}.${HOSTDOMAIN}

  source /run/etcd/environment

  sleep 2

  echo "Restoring etcd member $ETCD_NAME from snapshot.."

  env ETCDCTL_API=3 ${ETCDCTL} snapshot restore $SNAPSHOT_FILE \
    --name $ETCD_NAME \
    --initial-cluster ${ETCD_NAME}=https://${ETCD_DNS_NAME}:2380 \
    --initial-cluster-token etcd-cluster-1 \
    --skip-hash-check=true \
    --initial-advertise-peer-urls https://${ETCD_IPV4_ADDRESS}:2380 \
    --data-dir $ETCD_DATA_DIR 
  }

start_etcd() {
  echo "Starting etcd.."
  mv /etc/kubernetes/manifests-stopped/${ETCD_MANIFEST} $MANIFEST
}

init
verify_snapshot
stop_static_pods
backup_manifest
stop_kubelet
stop_all_containers
restore_snapshot
start_etcd


