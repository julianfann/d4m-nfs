#!/bin/bash

# env var to specify whether we want our home bound to /mnt
AUTO_MOUNT_HOME=${AUTO_MOUNT_HOME:-true}

# see if sudo is needed
if ! $(sudo -n cat /dev/null > /dev/null 2>&1); then
  # get sudo first so the focus for the password is kept in the term, instead of Docker.app
  echo -e "[d4m-nfs] You will need to provide your Mac password in order to setup NFS."
  sudo cat /dev/null
fi

# check if nfs conf line needs to be added
NFSCNF="nfs.server.mount.require_resv_port = 0"
if ! $(grep "$NFSCNF" /etc/nfs.conf > /dev/null 2>&1); then
  echo "[d4m-nfs] Set the NFS nfs.server.mount.require_resv_port value."
  echo -e "\nnfs.server.mount.require_resv_port = 0\n" | sudo tee -a /etc/nfs.conf
fi

SDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")"&&pwd)"
EXPORTS="# d4m-nfs exports\n"
NFSUID=$(id -u)
NFSGID=$(id -g)

LIBDIR=/opt/d4m-nfs
sudo mkdir -p $LIBDIR
sudo chown $USER $LIBDIR
chmod 755 $LIBDIR

# iterate through the mounts in etc/d4m-nfs-mounts.txt to add exports
if [ -e "${SDIR}/etc/d4m-nfs-mounts.txt" ]; then
  while read MOUNT; do
    if ! [[ "$MOUNT" = "#"* ]]; then
      if [[ "$(echo "$MOUNT" | cut -d: -f3)" != "" ]]; then
        NFSUID=$(echo "$MOUNT" | cut -d: -f3)
      fi

      if [[ "$(echo "$MOUNT" | cut -d: -f4)" != "" ]]; then
        NFSGID=$(echo "$MOUNT" | cut -d: -f4)
      fi

      NFSEXP="\"$(echo "$MOUNT" | cut -d: -f1)\" -alldirs -mapall=${NFSUID}:${NFSGID} localhost"

      if ! $(grep "$NFSEXP" /etc/exports > /dev/null 2>&1); then
        EXPORTS="$EXPORTS\n$NFSEXP"
      fi
    fi
  done < "${SDIR}/etc/d4m-nfs-mounts.txt"

  egrep -v '^#' "${SDIR}/etc/d4m-nfs-mounts.txt" > ${LIBDIR}/d4m-nfs-mounts.txt
fi

# if /Users is not in etc/d4m-nfs-mounts.txt then add /Users/$USER
if [[ ! "$EXPORTS" == *'"/Users"'* && ! "$EXPORTS" == *"\"/Users/$USER"* ]]; then
  # make sure /Users is not in /etc/exports
  if ! $(egrep '^"/Users"' /etc/exports > /dev/null 2>&1); then
    NFSEXP="\"/Users/$USER\" -alldirs -mapall=$(id -u):$(id -g) localhost"

    if ! $(grep "/Users/$USER" /etc/exports > /dev/null 2>&1); then
      EXPORTS="$EXPORTS\n$NFSEXP"
    fi
  fi
fi

# only add if we have something to do
if [ "$EXPORTS" != "# d4m-nfs exports\n" ]; then
  echo -e "$EXPORTS\n" | sudo tee -a /etc/exports
fi

# make sure /etc/exports is ok
if ! $(nfsd checkexports); then
  echo "[d4m-nfs] Something is wrong with your /etc/exports file, please check it." >&2
  exit 1
else
  echo "[d4m-nfs] Create the script for Moby VM."
  # make the script for the d4m side
  echo "#!/bin/sh
ln -nsf ${LIBDIR}/d4m-apk-cache /etc/apk/cache
apk update
apk add nfs-utils sntpc
rpcbind -s > /dev/null 2>&1

DEFGW=\$(ip route|awk '/default/{print \$3}')
FSTAB=\"\\n\\n# d4m-nfs mounts\n\"

if $AUTO_MOUNT_HOME && ! \$(grep ':/mnt' ${LIBDIR}/d4m-nfs-mounts.txt > /dev/null 2>&1); then
  mkdir -p /mnt

  FSTAB=\"\${FSTAB}\${DEFGW}:/Users/${USER} /mnt nfs nolock,local_lock=all 0 0\"
fi

if [ -e ${LIBDIR}/d4m-nfs-mounts.txt ]; then
  while read MOUNT; do
    DSTDIR=\$(echo \"\$MOUNT\" | cut -d: -f2)
    mkdir -p \${DSTDIR}
    FSTAB=\"\${FSTAB}\\n\${DEFGW}:\$(echo \"\$MOUNT\" | cut -d: -f1) \${DSTDIR} nfs nolock,local_lock=all 0 0\"
  done < ${LIBDIR}/d4m-nfs-mounts.txt
fi

if ! \$(grep \"d4m-nfs mounts\" /etc/fstab > /dev/null 2>&1); then
    echo "adding d4m nfs config to /etc/fstab:"
    echo -e \$FSTAB | tee /etc/fstab
else
    echo "d4m nfs mounts already exist in /etc/fstab"
fi

sntpc -i 10 \${DEFGW} &

sleep .5
mount -a
touch ${LIBDIR}/d4m-done
" > ${LIBDIR}/d4m-mount-nfs.sh
  chmod +x ${LIBDIR}/d4m-mount-nfs.sh

  echo -e "[d4m-nfs] Start and restop nfsd, for some reason restart is not as kind."
  sudo killall -9 nfsd ; sudo nfsd start

  echo -n "[d4m-nfs] Wait until NFS is setup."
  while ! rpcinfo -u localhost nfs > /dev/null 2>&1; do
    echo -n "."
    sleep .25
  done
fi

cp ${SDIR}/bin/d4m-nfs-start.sh ${LIBDIR}/

cat > ~/Library/LaunchAgents/com.ifsight.d4m-nfs.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
  <dict>
    <key>Label</key>
    <string>com.ifsight.d4m-nfs</string>
    <key>RunAtLoad</key>
    <true/>
    <key>WatchPaths</key>
    <array>
      <string>${HOME}/Library/Containers/com.docker.docker/Data/com.docker.driver.amd64-linux/tty</string>
    </array>
    <key>StandardOutPath</key>
    <string>${LIBDIR}/launchd.log</string>
    <key>Program</key>
    <string>${LIBDIR}/d4m-nfs-start.sh</string>
    <key>EnvironmentVariables</key>
    <dict>
      <key>PATH</key>
      <string>/bin:/usr/bin:/usr/local/bin</string>
    </dict>
  </dict>
</plist>
EOF

launchctl load -w ~/Library/LaunchAgents/com.ifsight.d4m-nfs.plist
