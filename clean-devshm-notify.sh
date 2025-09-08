#!/bin/bash
# Name: clean-devshm-notify.sh
# Purpose: cleans out /dev/shm and orphaned IPC shared memory segments
# Author: ORCD
# Date: 2025-09-08
# Cron line:
# 0 3 * * * /path/to/clean-devshm-notify.sh >> /var/log/clean_shm.log 2>&1

LOG_FILE="/var/log/clean_shm.log"
LOG_BACKUP="/var/log/clean_shm.$(date +%F_%H-%M-%S).log"
SHM_DIR="/dev/shm"
AGE_IN_DAYS="+1"
ACTIVE_FILES=$(lsof -F n +D "$SHM_DIR" 2>/dev/null | grep '^n' | cut -c2-)

# Function to rotate logs
rotate_logs() {
  if [ -f "$LOG_FILE" ]; then
    mv "$LOG_FILE" "$LOG_BACKUP"
    echo "Previous log rotated to $LOG_BACKUP"
  fi
  find /var/log -name "clean_shm.*.log" -mtime +14 -type f -exec rm -f {} \;
}

# Rotate logs
rotate_logs

echo "Scanning $SHM_DIR for stale files older than $AGE_IN_DAYS days..." | tee -a "$LOG_FILE"

deleted_count=0
# Find and delete stale files not in use
find "$SHM_DIR" -maxdepth 1 -mtime "$AGE_IN_DAYS" -type f -print0 2>/dev/null | while IFS= read -r -d '' file; do
  if ! echo "$ACTIVE_FILES" | grep -qxF -- "$file"; then
    owner=$(stat -c '%U:%G' "$file" 2>/dev/null)
    echo "Deleting stale file: $file (Owner: $owner)" | tee -a "$LOG_FILE"
    rm -f "$file"
    ((deleted_count++))
  fi
done

# Delete empty directories
find "$SHM_DIR" -maxdepth 1 -mtime "$AGE_IN_DAYS" -type d -empty -print0 2>/dev/null | while IFS= read -r -d '' dir; do
  owner=$(stat -c '%U:%G' "$dir" 2>/dev/null)
  echo "Deleting empty directory: $dir (Owner: $owner)" | tee -a "$LOG_FILE"
  rmdir "$dir"
done

echo "Scanning for orphaned IPC shared memory segments..." | tee -a "$LOG_FILE"

# Clean orphaned IPC shared memory segments
ipcs -m | awk '/0x/ {print $2}' | while read -r shmid; do
  owner=$(ipcs -m | awk -v id="$shmid" '$2 == id {print $3}')
  echo "Removing IPC shared memory segment ID: $shmid (Owner: $owner)" | tee -a "$LOG_FILE"
  ipcrm -m "$shmid"
done

echo "Cleanup complete. Deleted $deleted_count stale file(s)." | tee -a "$LOG_FILE"

# test

# root@spec:/home/jmurray/scripting/sysadmin# ./clean-devshm-notify.sh 
# Previous log rotated to /var/log/clean_shm.2025-09-08_16-09-56.log
# Scanning /dev/shm for stale files older than +1 days...
# Deleting stale file: /dev/shm/testfile2 (Owner: root:root)
# Deleting stale file: /dev/shm/testfile1 (Owner: root:root)
# Scanning for orphaned IPC shared memory segments...
# Removing IPC shared memory segment ID: 6 (Owner: jmurray)
# Removing IPC shared memory segment ID: 9 (Owner: jmurray)
# Removing IPC shared memory segment ID: 16 (Owner: jmurray)
# Removing IPC shared memory segment ID: 393236 (Owner: jmurray)
# Removing IPC shared memory segment ID: 196630 (Owner: jmurray)
# Removing IPC shared memory segment ID: 196633 (Owner: jmurray)
# Removing IPC shared memory segment ID: 688155 (Owner: root)
# Removing IPC shared memory segment ID: 655389 (Owner: jmurray)
# Removing IPC shared memory segment ID: 34 (Owner: jmurray)
# Removing IPC shared memory segment ID: 35 (Owner: jmurray)
# Removing IPC shared memory segment ID: 42 (Owner: jmurray)
# Removing IPC shared memory segment ID: 327728 (Owner: jmurray)
# Removing IPC shared memory segment ID: 49 (Owner: jmurray)
# Removing IPC shared memory segment ID: 98356 (Owner: jmurray)
# Removing IPC shared memory segment ID: 98362 (Owner: jmurray)
# Removing IPC shared memory segment ID: 98363 (Owner: jmurray)
# Cleanup complete. Deleted 0 stale file(s).
