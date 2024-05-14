#!/bin/bash

# Check if onlykey-agent is installed
if ! command -v onlykey-agent &> /dev/null
then
    echo "Onlykey command line tools must be installed"
    exit 1
fi

# Define file and directories
CONF_FILE="$HOME/.ssh/onlykey-ids.conf"
KEYS_DIR="$HOME/.ssh/onlykey-keys"
SOCKETS_DIR="$HOME/.ssh/onlykey-sockets"

# Check if ~/.ssh/onlykey-ids.conf exists and is readable
if [ ! -r "$CONF_FILE" ]; then
    echo "Error: $CONF_FILE does not exist or is not readable"
    exit 1
fi

PYTHONUNBUFFERED=1

notifyOutput() {
    echo $1;
    export PYTHONUNBUFFERED=1
    eval "$1" | while IFS="\n" read -r line
    do
        echo "Colelcting lines"
        # Collect lines for a brief period to accumulate output
        output="$line"
        for i in {1..5} # Adjust the number 5 to capture more or less lines
        do
            if IFS="\n" read -r -t 0.5 line; then # Adjust the timeout (-t 0.5) as necessary
                output+="\n$line"
            else
                break
            fi
        done
    
        echo "$output" >> /tmp/output.txt
        # Use notify-send to alert the user. Adjust the timeout as necessary.
        notify-send "OnlyKey Input Required" "$output" -t 5000 # Timeout is 10000 milliseconds (10 seconds)
    done
}


killall onlykey-agent
sleep 1
rm -rf "$SOCKETS_DIR/*.sock"

# Array to keep track of created socket files
declare -a createdSockets

# Read through the file one line at a time
while IFS=: read -r email keyType || [ -n "$email" ]; do
    # Ignore empty lines or lines that start with #
    if [[ $email = \#* ]] || [[ -z $email ]]; then
        continue
    fi

    # Check for ~/.ssh/onlykey-keys/<email>.pub
    if [ ! -f "$KEYS_DIR/$email.pub" ]; then
        # Create directory if it doesn't exist
        mkdir -p "$KEYS_DIR"
        
        # Check if keyType was specified and create .pub file accordingly
        if [[ -z $keyType ]]; then
            onlykey-agent "$email" > "$KEYS_DIR/$email.pub"
        else
            onlykey-agent -e "$keyType" "$email" > "$KEYS_DIR/$email.pub"
        fi
    fi

    # Create directory if it doesn't exist
    mkdir -p "$SOCKETS_DIR"
    chmod go-rwx "$SOCKETS_DIR"

    cmd="onlykey-agent -f --sock-path=\"$SOCKETS_DIR/$email.sock\""

    # Run the command to create the socket, omitting "-e <keyType>" if not specified
    if [[ ! -z $keyType ]]; then
        cmd+=" -e \"$keyType\""
    fi
    cmd+=" \"$email\""

    notifyOutput "$cmd" &

    # Add the socket path to the array
    createdSockets+=("$SOCKETS_DIR/$email.sock")

done < "$CONF_FILE"

# Wait a bit to ensure sockets are created
sleep 2

# Loop through the created sockets to change permissions
for socket in "${createdSockets[@]}"; do
    if [ -S "$socket" ]; then
        chmod go-rwx "$socket"
    fi
done

# Wait for all background jobs to finish
wait
