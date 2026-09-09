#!/usr/bin/env bash
set -e

echo "Restarting usbmuxd..."

sudo systemctl restart usbmuxd 2>/dev/null || {
    sudo pkill usbmuxd 2>/dev/null || true
    sudo usbmuxd -f >/tmp/usbmuxd.log 2>&1 &
    sleep 2
}

echo
echo "Waiting for iPhone..."

for i in {1..10}; do
    DEVICE="$(idevice_id -l | head -n1)"

    if [ -n "$DEVICE" ]; then
        echo "iPhone detected."
        echo
        idevicepair validate
        exit 0
    fi

    sleep 1
done

echo "iPhone was not detected."
echo "Check ChromeOS > Developers > Linux > Manage USB devices."
exit 1
