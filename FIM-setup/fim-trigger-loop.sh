#!/bin/bash
# Simple loop to trigger FIM violation every ~60 seconds
# Run as root in chroot /host from oc debug node

COUNT=0
while true; do
    COUNT=$((COUNT + 1))
    TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

    # Create a test file that matches your policy path/operation (CREATE + optional write)
    echo "# Test FIM trigger $COUNT at $TIMESTAMP" > /etc/sudoers.test
    echo "testuser ALL=(ALL) NOPASSWD:ALL  # simulated" >> /etc/sudoers.test

    echo "[$TIMESTAMP] Triggered CREATE/WRITE on /etc/sudoers.test (#$COUNT) - check ACS for alert"

    # Optional: Immediately remove to simulate quick attack + cleanup (still triggers CREATE)
    # rm -f /etc/sudoers.test

    sleep 60  # Adjust to 30 or 120 if you want faster/slower
done
