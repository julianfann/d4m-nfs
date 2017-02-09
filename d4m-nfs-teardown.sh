#!/bin/bash

# see if sudo is needed
if ! $(sudo -n cat /dev/null > /dev/null 2>&1); then
  # get sudo first so the focus for the password is kept in the term, instead of Docker.app
  echo -e "[d4m-nfs] You will need to provide your Mac password in order to teardown NFS mounts."
  sudo cat /dev/null
fi

## TODO: remove entries from /etc/exports

