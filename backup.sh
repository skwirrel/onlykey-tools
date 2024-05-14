#!/bin/bash

# CD into the directory this script lives in
cd "$(dirname "$0")"

#: <<'COMMENT'
lsblk -l > /tmp/lsblk_before
echo "Please insert the USB stick and press Enter when done."
read -r  # Waits for user to press enter
echo "Waiting for USB..."
sleep 2
lsblk -l > /tmp/lsblk_after

# Identifying the newly added device
device=$(diff /tmp/lsblk_before /tmp/lsblk_after | grep 'part' | awk '{print $2}')

if [ -z "$device" ]; then
    echo "No USB device detected. Exiting."
    exit 1
fi

# Prepending /dev/ to the device name to get the correct device path
device="/dev/$device"

# Creating a mount point if it doesn't exist
mount_point="/mnt/backupMount"
if [ ! -d "$mount_point" ]; then
    echo "Creating mount directory at $mount_point."
    mkdir -p "$mount_point"
fi

# Attempting to mount the device with udisksctl
echo "Mounting $device."
mount_output=$(udisksctl mount -b $device -t ext4 2>&1)
if [ $? -ne 0 ]; then
    echo "Failed to mount $device. Exiting."
    echo "$mount_output"
    exit 1
else
    # Extracting the actual mount point from the udisksctl output
    mount_point=$(echo $mount_output | grep -oP 'at \K(/[^ ]*)')
fi

echo "USB stick mounted on $mount_point"

# Placeholder for file copying operation. Customize this part.
# echo "Copying files to $mount_point..."
# cp /path/to/source/* "$mount_point"
baseDir=$mount_point/keybackup_$(date '+%Y%m%d')
mkdir -p $baseDir/gpg
mkdir -p $baseDir/gpg/private-keys-v1.d
mkdir -p $baseDir/gpg_onlykey

echo -e "\nBACKING UP GPG\n=================================\n"

gpg --export --armor > $baseDir/gpg/publickeys.asc
gpg --export-ownertrust > $baseDir/gpg/ownertrust.txt

gpg --homedir=~/.gnupg/onlykey --export --armor > $baseDir/gpg_onlykey/publickeys.asc
gpg --homedir=~/.gnupg/onlykey --export-ownertrust > $baseDir/gpg_onlykey/ownertrust.txt

# Export secret keys without using passphrase
for g in $(gpg --list-keys --with-keygrip --with-colons | awk -F: '$1=="grp" {print $10}'); do
    if [ -f ~/.gnupg/private-keys-v1.d/$g.key ]; then
        cp -a ~/.gnupg/private-keys-v1.d/$g.key $baseDir/gpg/private-keys-v1.d/
    fi
done

echo -e "\nBACKING UP PASSWORD STORE\n=================================\n"
current_dir_name=$(basename "$(pwd)")
# Backup this directory
tar -cvzf $baseDir/passwordStore.tgz "../$current_dir_name"

# copy all gpg or asc files in ~/secure/
# Enable nullglob to avoid issues with non-matching globs
secureDir=~/secure/
shopt -s nullglob

# Find all .gpg and .asc files in the specified directory
files=("$secureDir"*.gpg "$secureDir"*.asc)

# Check if the array contains any items
if [ ${#files[@]} -gt 0 ]; then
    echo -e "\nBACKING UP ~/secure/\n=================================\n"
    tar -cvzf "$baseDir/secure.tgz" "${files[@]}"
fi

echo -e "\nBACKING UP ONLYKEY\n=================================\n"
echo "Press and hold the 1 button on Onlykey for 5 seconds"
onlykeyBackup="$baseDir/onlykey-backup.txt"  # Define the file path on USB stick

# Capture user input into a file until 'EOF' is entered
cat > "$onlykeyBackup" <<EOF
$(while read -r line; do
    echo "$line"
    [[ $line == "-----END ONLYKEY BACKUP-----" ]] && break
done)
EOF

# Validate the start and end lines of the file
start_line=$(head -n 1 "$onlykeyBackup")
end_line=$(tail -n 1 "$onlykeyBackup")

if [[ $start_line != "-----BEGIN ONLYKEY BACKUP-----" ]] || [[ $end_line != "-----END ONLYKEY BACKUP-----" ]]; then
    echo "Error: The onlykey backup does not start with the expected header or end with the expected footer."
    exit 1
fi

echo "Onlykey backup validated."

echo -e "\nTIDYING UP GPG\n=================================\n"

# Unmounting the USB stick with udisksctl
echo "Unmounting $device."
if ! udisksctl unmount -b $device; then
    echo "Failed to unmount $device. Exiting."
    exit 1
fi

# Ejecting the USB stick with udisksctl
echo "Ejecting $device."
if ! udisksctl power-off -b $device; then
    echo "Failed to eject $device. You may need to manually eject before removal."
fi

echo "It is now safe to remove the USB stick."

