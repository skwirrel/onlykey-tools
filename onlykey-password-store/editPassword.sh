#!/bin/bash

if [ "$#" -lt 1 ]; then
    echo "Error: No file name supplied."
    echo "Usage: $0 <filename>"
    echo "The script will create <filename>.gpg and <filename>.txt if they don't exist"
    echo "If they do exist then it will open them one after another in vi"
    exit 1
fi

# If you want to sign passwords with additional keys as a backup in case you lose your Onlykey
# then simply add the public keys to the onlykey gpg keyring - this script will encrypt
# the password file with ALL the public keys in this keyring. You can do this with the following
# command:
#   gpg --homedir=~/.gnupg/onlykey/ --import
#   then paste the new public key followed by Ctrl-D
#   or
#   cat new.key | gpg --homedir=~/.gnupg/onlykey/ --import

gpgHome=~/.gnupg/onlykey/

# Initialize an empty string for the gpg options
gpg_options="--homedir=$gpgHome -ae"

file="$1"

if [ ! -f "$file.gpg" ]; then
    # Extract email addresses for each key and append to gpg_options
    while IFS= read -r line; do
        email=$(echo "$line" | grep '^uid' | cut -d':' -f10)
        if [ ! -z "$email" ]; then
            gpg_options+=" -r '$email'"
        fi
    done < <(gpg --homedir=$gpgHome --list-keys --with-colons)

    echo -e "username: \npassword: \ntotp: \n" | eval gpg $gpg_options > $file.gpg
fi

if [ ! -f "$file.txt" ]; then
    echo -e "url:\nscript: plain_2page|totp_2page|totp_3page\n" > $file.txt
fi
GNUPGHOME="$gpgHome" vi "$file.gpg"
vi "$file.txt"
