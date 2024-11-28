#!/bin/bash

# Prompt for the Hostname (Domain Name), defaulting to fvtt.home.cerender.me
read -e -p "Enter the domain name associated with your SSL certificate [fvtt.home.cerender.me]: " -i "fvtt.home.cerender.me" DOMAIN_NAME
DOMAIN_NAME=${DOMAIN_NAME:-fvtt.home.cerender.me}

# Define source certificate paths based on the provided domain name
CERT_SRC="/etc/letsencrypt/archive/$DOMAIN_NAME/fullchain.pem"
KEY_SRC="/etc/letsencrypt/archive/$DOMAIN_NAME/privkey.pem"

# Prompt for Variables (ensure these match the ones used in your setup script)
read -e -p "Enter Mount Point [/mnt/foundry]: " -i "/mnt/foundry" MOUNT_POINT
MOUNT_POINT=${MOUNT_POINT:-/mnt/foundry}

read -e -p "Enter Username [jason]: " -i "jason" USERNAME
USERNAME=${USERNAME:-jason}

# Find Directories Starting with 'fvtt_'
INSTANCE_DIRS=($(find "$MOUNT_POINT" -maxdepth 1 -type d -name 'fvtt_*' -printf '%f\n'))

if [ ${#INSTANCE_DIRS[@]} -eq 0 ]; then
    echo "No Foundry VTT instances found in $MOUNT_POINT."
    exit 1
fi

# Copy certificates and restart services for each instance
for DIR_NAME in "${INSTANCE_DIRS[@]}"
do
    INSTANCE_DIR="$MOUNT_POINT/$DIR_NAME"

    # Extract instance name and port number from directory name
    # Expected format: fvtt_<instance_name>_#<port_number>
    if [[ $DIR_NAME =~ ^fvtt_([a-zA-Z0-9_]+)_#([0-9]+)$ ]]; then
        INSTANCE_NAME="${BASH_REMATCH[1]}"
        PORT_NUMBER="${BASH_REMATCH[2]}"
    else
        echo "Directory $DIR_NAME does not match the expected format. Skipping."
        continue
    fi

    FVTT_DATA_DIR="$INSTANCE_DIR/fvtt_data"
    CONFIG_DIR="$FVTT_DATA_DIR/Config"

    # Ensure the Config directory exists
    if [ ! -d "$CONFIG_DIR" ]; then
        echo "Config directory $CONFIG_DIR does not exist. Creating it."
        sudo mkdir -p "$CONFIG_DIR"
        sudo chown "$USERNAME:$USERNAME" "$CONFIG_DIR"
    fi

    # Copy certificates to the Config directory
    echo "Copying certificates to $CONFIG_DIR for instance $INSTANCE_NAME..."
    sudo cp "$CERT_SRC" "$CONFIG_DIR/fullchain.pem"
    sudo cp "$KEY_SRC" "$CONFIG_DIR/privkey.pem"

    # Set ownership
    sudo chown "$USERNAME:$USERNAME" "$CONFIG_DIR/fullchain.pem"
    sudo chown "$USERNAME:$USERNAME" "$CONFIG_DIR/privkey.pem"

    # Restart the service
    SERVICE_NAME="fvtt-${INSTANCE_NAME}.service"
    echo "Restarting service $SERVICE_NAME..."
    sudo systemctl restart "$SERVICE_NAME"

    # Check service status
    sudo systemctl status "$SERVICE_NAME" --no-pager

    echo "Certificates updated and service restarted for instance: $INSTANCE_NAME"
done

echo "All instances have been updated with the new certificates."
