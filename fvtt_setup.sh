#!/bin/bash

# Prompt for Variables
read -e -p "Enter TrueNAS IP Address [192.168.42.240]: " -i "192.168.42.240" TRUENAS_IP
TRUENAS_IP=${TRUENAS_IP:-192.168.42.240}

read -e -p "Enter NFS Export Path [/mnt/TrueNAS/Foundry]: " -i "/mnt/TrueNAS/Foundry" NFS_EXPORT
NFS_EXPORT=${NFS_EXPORT:-/mnt/TrueNAS/Foundry}

read -e -p "Enter Mount Point [/mnt/foundry]: " -i "/mnt/foundry" MOUNT_POINT
MOUNT_POINT=${MOUNT_POINT:-/mnt/foundry}

read -e -p "Enter Username [jason]: " -i "jason" USERNAME
USERNAME=${USERNAME:-jason}

read -e -p "Enter Group name [jason]: " -i "jason" GROUPNAME
GROUPNAME=${GROUPNAME:-jason}

read -e -p "Enter User UID [3001]: " -i "3001" USER_UID
USER_UID=${USER_UID:-3001}

read -e -p "Enter User GID [3001]: " -i "3001" USER_GID
USER_GID=${USER_GID:-3001}

# Create User and Group
sudo addgroup --gid $USER_GID $USERNAME
sudo adduser --uid $USER_UID --gid $USER_GID $USERNAME

# Install NFS Client Packages
sudo apt update
sudo apt install -y nfs-common

# Create Mount Point Directory
sudo mkdir -p $MOUNT_POINT
sudo chown $USERNAME:$USERNAME $MOUNT_POINT

# Backup fstab
sudo cp /etc/fstab /etc/fstab.bak

# Add NFS Mount to fstab
echo "$TRUENAS_IP:$NFS_EXPORT $MOUNT_POINT nfs4 defaults,_netdev,bg 0 0" | sudo tee -a /etc/fstab

# Mount NFS Share
sudo mount -a

# Verify Mount
if mountpoint -q $MOUNT_POINT; then
    echo "NFS Share mounted successfully at $MOUNT_POINT"
else
    echo "Failed to mount NFS Share."
    exit 1
fi

# Find Directories Starting with 'fvtt_'
INSTANCE_DIRS=($(find $MOUNT_POINT -maxdepth 1 -type d -name 'fvtt_*' -printf '%f\n'))

if [ ${#INSTANCE_DIRS[@]} -eq 0 ]; then
    echo "No FoundryVTT instances found in $MOUNT_POINT."
    exit 1
fi

# Initialize Nginx Config Blocks
NGINX_CONFIG=""

# Setup FoundryVTT Instances
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

    SERVICE_NAME="fvtt-${INSTANCE_NAME}.service"
    SERVICE_FILE="/etc/systemd/system/$SERVICE_NAME"

    FVTT_VTT_DIR="$INSTANCE_DIR/fvtt_vtt"
    FVTT_DATA_DIR="$INSTANCE_DIR/fvtt_data"

    # Check if fvtt_vtt and fvtt_data directories exist
    if [ -d "$FVTT_VTT_DIR" ] && [ -d "$FVTT_DATA_DIR" ]; then
        echo "Setting up service for instance: $INSTANCE_NAME on port $PORT_NUMBER"

        # Update options.json file
        OPTIONS_JSON="$FVTT_DATA_DIR/Config/options.json"

        sudo mkdir -p "$(dirname "$OPTIONS_JSON")"

        # Create or update options.json
        sudo bash -c "cat > $OPTIONS_JSON" <<EOL
{
  "dataPath": "$FVTT_DATA_DIR",
  "port": $PORT_NUMBER,
  "routePrefix": "/$INSTANCE_NAME",
  "hostname": "127.0.0.1",
  "proxySSL": false,
  "sslCert": "",
  "sslKey": "",
  "updateChannel": "stable",
  "language": "en.core",
  "fullscreen": false,
  "upnp": false,
  "awtConfig": null,
  "awsConfig": null,
  "serviceConfig": null,
  "xframeOptions": null,
  "noUpdate": false,
  "adminKey": null,
  "proxyPort": null,
  "proxyBypass": false
}
EOL

        sudo chown $USERNAME:$USERNAME "$OPTIONS_JSON"

        # Create systemd service file
        sudo bash -c "cat > $SERVICE_FILE" <<EOL
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
Environment=NODE_ENV=$INSTANCE_NAME

#StandardOutput=syslog
#StandardError=syslog
SyslogIdentifier=fvtt_$INSTANCE_NAME

[Install]
WantedBy=multi-user.target
EOL

        # Enable and start the service
        sudo systemctl daemon-reload
        sudo systemctl enable $SERVICE_NAME
        sudo systemctl start $SERVICE_NAME

        # Check service status
        sudo systemctl status $SERVICE_NAME --no-pager

        # Append to Nginx configuration
        NGINX_CONFIG+="
# $INSTANCE_NAME reverse proxy
location /$INSTANCE_NAME/ {
    proxy_pass http://127.0.0.1:$PORT_NUMBER/$INSTANCE_NAME/;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;

    # Handle WebSocket connections
    proxy_http_version 1.1;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection \"upgrade\";

    gzip off;
}
"
    else
        echo "Skipping $DIR_NAME: Required directories not found."
    fi
done

echo "Setup completed successfully."

# Output Nginx configuration
echo -e "\nGenerated Nginx configuration blocks:"
echo "$NGINX_CONFIG"

echo -e "\nPlease add the above Nginx configuration blocks to your Nginx server configuration file."
