#!/bin/bash
set -e

# =============================================================================
# Function Definitions
# =============================================================================

# [Function definitions remain unchanged]

# =============================================================================
# Predefined Default Values
# =============================================================================

# [Predefined default values remain unchanged]

# =============================================================================
# Main Script Execution
# =============================================================================

# [Ensure the script is run as root]
# [Prompt for required information]
# [Define source certificate paths]
# [Check if certificate files exist]
# [Validate Group GID availability]
# [Validate User UID availability]
# [User and group setup completed successfully]
# [Check if nfs-common is installed]
# [Create the mount point]
# [Backup /etc/fstab]
# [Add NFS share to /etc/fstab]
# [Mount the NFS share]
# [Verify mount was successful]
# [Install Node.js version 20 if needed]

# Find Directories Starting with 'fvtt_'
INSTANCE_DIRS=($(find "$MOUNT_POINT" -maxdepth 1 -type d -name 'fvtt_*' -exec basename {} \;))

if [ ${#INSTANCE_DIRS[@]} -eq 0 ]; then
    echo_error "No Foundry VTT instances found in $MOUNT_POINT."
    exit 1
fi

# Setup FoundryVTT Instances and Handle Certificates
for DIR_NAME in "${INSTANCE_DIRS[@]}"
do
    INSTANCE_DIR="$MOUNT_POINT/$DIR_NAME"

    if [[ $DIR_NAME =~ ^fvtt_([a-zA-Z0-9_]+)_([0-9]+)$ ]]; then
        INSTANCE_NAME="${BASH_REMATCH[1]}"
        PORT_NUMBER="${BASH_REMATCH[2]}"
    else
        echo_error "Directory $DIR_NAME does not match the expected format 'fvtt_<name>_<port>'. Skipping."
        continue
    fi

    FVTT_VTT_DIR="$INSTANCE_DIR/fvtt_vtt"
    FVTT_DATA_DIR="$INSTANCE_DIR/fvtt_data"
    CONFIG_DIR="$FVTT_DATA_DIR/Config"
    SERVICE_NAME="fvtt-${INSTANCE_NAME}.service"
    OPTIONS_JSON="$CONFIG_DIR/options.json"

    # Ensure Config directory exists (as jason user)
    sudo -u "$USERNAME" mkdir -p "$CONFIG_DIR"

    # Update options.json (as jason user)
    sudo -u "$USERNAME" bash -c "cat > '$OPTIONS_JSON'" <<EOL
{
  "dataPath": "$FVTT_DATA_DIR",
  "port": $PORT_NUMBER,
  "routePrefix": null,
  "compressStatic": true,
  "hostname": null,
  "localHostname": null,
  "protocol": null,
  "proxyPort": null,
  "proxySSL": false,
  "sslCert": "fullchain.pem",
  "sslKey": "privkey.pem",
  "updateChannel": "stable",
  "language": "en.core",
  "upnp": false,
  "upnpLeaseDuration": null,
  "awsConfig": null,
  "compressSocket": true,
  "cssTheme": "foundry",
  "deleteNEDB": true,
  "hotReload": false,
  "passwordSalt": null,
  "serviceConfig": null,
  "telemetry": false
}
EOL

    # Copy Certificates if they don't exist (as jason user)
    if [ ! -f "$CONFIG_DIR/fullchain.pem" ] || [ ! -f "$CONFIG_DIR/privkey.pem" ]; then
        echo_info "Copying certificates for instance $INSTANCE_NAME..."
        sudo -u "$USERNAME" cp "$CERT_SRC" "$CONFIG_DIR/fullchain.pem"
        sudo -u "$USERNAME" cp "$KEY_SRC" "$CONFIG_DIR/privkey.pem"
    else
        echo_info "Certificates already exist for instance $INSTANCE_NAME."
    fi

    # Create and Configure Systemd Service if it doesn't exist
    SERVICE_FILE="/etc/systemd/system/$SERVICE_NAME"
    if [ -f "$SERVICE_FILE" ]; then
        echo_info "Service file $SERVICE_FILE already exists. Skipping creation."
    else
        cat > "$SERVICE_FILE" <<EOL
[Unit]
Description=FoundryVTT Instance $INSTANCE_NAME Service
After=network.target remote-fs.target
RequiresMountsFor=$MOUNT_POINT

[Service]
User=$USERNAME
Group=$GROUPNAME
WorkingDirectory=$FVTT_VTT_DIR
ExecStart=/usr/bin/node $FVTT_VTT_DIR/resources/app/main.js --dataPath=$FVTT_DATA_DIR
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOL
    fi

    # Enable and Restart Service
    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME"
    systemctl restart "$SERVICE_NAME"

    # Check if service is active
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        echo_success "Service $SERVICE_NAME is running."
    else
        echo_error "Service $SERVICE_NAME failed to start."
    fi

    # Check if service is listening on the correct port
    echo_info "Waiting for service to start..."
    sleep 5
    if ss -tulwn | grep ":$PORT_NUMBER " > /dev/null; then
        echo_success "Instance $INSTANCE_NAME is listening on port $PORT_NUMBER."
    else
        echo_error "Instance $INSTANCE_NAME is not listening on port $PORT_NUMBER."
    fi

    echo_info "Instance $INSTANCE_NAME setup completed."
done

echo_success "All setups completed successfully."

# =============================================================================
# End of Script
# =============================================================================
