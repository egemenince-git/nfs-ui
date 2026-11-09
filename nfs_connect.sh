#!/bin/bash
# nfs_connect.sh - 192.168.3.6:/nfs_server NFS baglanti ayari
# Kullanim:
#   ./nfs_connect.sh -c   baglan
#   ./nfs_connect.sh -d   baglantiyi kes

MOUNTPOINT="/Users/ince/nfs_server"
EXPORT="192.168.3.6:/nfs_server"

SUDO="sudo"

is_mounted() {
  mount | grep -q " $MOUNTPOINT "
}

case "$1" in
  -c)
    if is_mounted; then
      echo "Zaten bagli: $MOUNTPOINT"
      exit 0
    fi
    mkdir -p "$MOUNTPOINT"
    if $SUDO mount -t nfs -o vers=3,resvport "$EXPORT" "$MOUNTPOINT"; then
      echo "Baglandi: $MOUNTPOINT  <-  $EXPORT"
    else
      echo "Baglanti basarisiz (sunucuya erisilemiyor olabilir)"
      exit 1
    fi
    ;;
  -d)
    if is_mounted; then
      $SUDO umount "$MOUNTPOINT" 2>/dev/null || $SUDO umount -f "$MOUNTPOINT"
      echo "Baglanti kapatildi: $MOUNTPOINT"
    else
      echo "Bagli degil: $MOUNTPOINT"
    fi
    ;;
  *)
    echo "Kullanim: $0 -c (connect) | -d (disconnect)"
    exit 1
    ;;
esac
