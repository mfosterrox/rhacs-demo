#!/bin/bash
# Simple loop to trigger FIM violation every ~60 seconds
# Run as root in chroot /host from oc debug node
# Alternates ownership changes on /etc/passwd and /etc/sudoers to trigger FIM alerts

COUNT=0
while true; do
    COUNT=$((COUNT + 1))
    TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

    # Alternate between /etc/passwd and /etc/sudoers; chown to bin then back to root
    # This triggers FIM violations (ownership change) while restoring immediately
    if [ $((COUNT % 2)) -eq 1 ]; then
        chown bin:root /etc/passwd
        chown root:root /etc/passwd
        echo "[$TIMESTAMP] Triggered chown on /etc/passwd (#$COUNT) - check ACS for alert"
    else
        chown bin:root /etc/sudoers
        chown root:root /etc/sudoers
        echo "[$TIMESTAMP] Triggered chown on /etc/sudoers (#$COUNT) - check ACS for alert"
    fi

    sleep 60  # Adjust to 30 or 120 if you want faster/slower
done
