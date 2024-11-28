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

read -e -p "Enter the domain name associated with your SSL certificate [fvtt.home.cerender.me]: " -i "fvtt.home.cerender.me" DOMAIN_NAME
DOMAIN_NAME=${DOMAIN_NAME:-fvtt.home.cerender.me}

CERT_SRC="/etc/letsencrypt/live/$DOMAIN_NAME/fullchain.pem"
KEY_SRC="/etc/letsencrypt/live/$DOMAIN_NAME/privkey.pem"

# Create User and Group if they do not exist
if ! getent group $GROUPNAME > /dev/null 2>&1; then
    sudo addgroup --gid $USER_GID $GROUPNAME
else
    echo "Group $GROUPNAME already exists."
fi

if ! id -u $USERNAME > /dev/null 2>&1; then
    sudo adduser --uid $USER_UID --gid $USER_GID $USERNAME
else
    echo "User $USERNAME already exists."
fi

# Install NFS Client Packages
sudo apt update
sudo apt install -y nfs-common

# Create Mount Point Directory
sudo mkdir -p $MOUNT_POINT
sudo chown $USERNAME:$GROUPNAME $MOUNT_POINT

# Backup fstab
sudo cp /etc/fstab /etc/fstab.bak

# Add NFS Mount to fstab if not already present
FSTAB_LINE="$TRUENAS_IP:$NFS_EXPORT $MOUNT_POINT nfs4 defaults,_netdev,bg 0 0"
if ! grep -qs "^$FSTAB_LINE" /etc/fstab; then
    echo "$FSTAB_LINE" | sudo tee -a /etc/fstab
else
    echo "NFS mount already present in /etc/fstab."
fi

# Mount NFS Share
sudo mount -a

# Verify Mount
if ! mountpoint -q $MOUNT_POINT; then
    echo "Failed to mount NFS Share."
    exit 1
fi

# Install Node.js version 20 if needed
if ! command -v node &> /dev/null; then
    echo "Node.js is not installed. Installing..."
    curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
    sudo apt-get install -y nodejs
fi

# Find Directories Starting with 'fvtt_'
INSTANCE_DIRS=($(find $MOUNT_POINT -maxdepth 1 -type d -name 'fvtt_*' -printf '%f\n'))

if [ ${#INSTANCE_DIRS[@]} -eq 0 ]; then
    echo "No Foundry VTT instances found in $MOUNT_POINT."
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
        echo "Directory $DIR_NAME does not match the expected format 'fvtt_<name>_<port>'. Skipping."
        continue
    fi

    FVTT_VTT_DIR="$INSTANCE_DIR/fvtt_vtt"
    FVTT_DATA_DIR="$INSTANCE_DIR/fvtt_data"
    CONFIG_DIR="$FVTT_DATA_DIR/Config"
    SERVICE_NAME="fvtt-${INSTANCE_NAME}.service"

    # Ensure Config directory exists
    sudo mkdir -p "$CONFIG_DIR"
    sudo chown "$USERNAME:$GROUPNAME" "$CONFIG_DIR"

    # Update options.json
    OPTIONS_JSON="$CONFIG_DIR/options.json"
    sudo bash -c "cat > $OPTIONS_JSON" <<EOL
{
  "dataPath": "$FVTT_DATA_DIR",
  "port": $PORT_NUMBER,
  "routePrefix": "/$INSTANCE_NAME",
  "hostname": "0.0.0.0",
  "proxySSL": false,
  "sslCert": "$CONFIG_DIR/fullchain.pem",
  "sslKey": "$CONFIG_DIR/privkey.pem",
  "updateChannel": "stable",
  "language": "en.core",
  "fullscreen": false,
  "upnp": false
}
EOL
    sudo chown $USERNAME:$GROUPNAME "$OPTIONS_JSON"

    # Copy Certificates
    echo "Ensuring certificates are in place for instance $INSTANCE_NAME..."
    sudo cp "$CERT_SRC" "$CONFIG_DIR/fullchain.pem"
    sudo cp "$KEY_SRC" "$CONFIG_DIR/privkey.pem"
    sudo chown "$USERNAME:$GROUPNAME" "$CONFIG_DIR/fullchain.pem" "$CONFIG_DIR/privkey.pem"

    # Create and Configure Systemd Service if it doesn't exist
    SERVICE_FILE="/etc/systemd/system/$SERVICE_NAME"

    if [ ! -f "$SERVICE_FILE" ]; then
        echo "Creating service file for instance $INSTANCE_NAME..."
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

[Install]
WantedBy=multi-user.target
EOL
        # Enable the service
        sudo systemctl enable "$SERVICE_NAME"
    else
        echo "Service file for instance $INSTANCE_NAME already exists."
    fi

    # Restart Service
    sudo systemctl daemon-reload
    sudo systemctl restart "$SERVICE_NAME"

    # Check service status
    sudo systemctl status "$SERVICE_NAME" --no-pager

    # Check if service is listening on the correct port
    echo "Waiting for service to start..."
    sleep 5
    if ss -tulwn | grep ":$PORT_NUMBER " > /dev/null; then
        echo "Instance $INSTANCE_NAME is listening on port $PORT_NUMBER."
    else
        echo "Instance $INSTANCE_NAME is not listening on port $PORT_NUMBER."
    fi

    echo "Instance $INSTANCE_NAME setup completed."
done

echo "All setups completed successfully."
