#!/bin/bash

# =============================================================================
# Function Definitions
# =============================================================================

# Function to display informational messages
echo_info() {
    echo -e "\e[34m[INFO]\e[0m $1"
}

# Function to display success messages
echo_success() {
    echo -e "\e[32m[SUCCESS]\e[0m $1"
}

# Function to display error messages
echo_error() {
    echo -e "\e[31m[ERROR]\e[0m $1"
}

# Function to prompt for input with a default value
prompt_with_default() {
    local prompt_message="$1"
    local default_value="$2"
    local user_input

    read -e -p "$prompt_message [$default_value]: " -i "$default_value" user_input
    echo "${user_input:-$default_value}"
}

# Function to check if a group exists by name
group_exists() {
    local grp="$1"
    getent group "$grp" > /dev/null 2>&1
}

# Function to check if a group exists by GID
group_exists_gid() {
    local gid="$1"
    getent group | awk -F: '{print $3}' | grep -qw "$gid"
}

# Function to check if a user exists by name
user_exists() {
    local usr="$1"
    getent passwd "$usr" > /dev/null 2>&1
}

# Function to check if a UID is already in use
uid_exists() {
    local uid="$1"
    getent passwd | awk -F: '{print $3}' | grep -qw "$uid"
}

# Function to check if a GID is already in use
gid_exists() {
    local gid="$1"
    getent group | awk -F: '{print $3}' | grep -qw "$gid"
}

# =============================================================================
# Predefined Default Values
# =============================================================================
PREDEF_USERNAME="fvtt"
PREDEF_GROUPNAME="fvtt_nfs"
PREDEF_USER_UID=3000
PREDEF_GROUP_GID=3003
PREDEF_DOMAIN_NAME="$(hostname).home.cerender.me"
PREDEF_TRUENAS_IP="192.168.42.240"
PREDEF_NFS_EXPORT="/mnt/TrueNAS/Foundry"
PREDEF_MOUNT_POINT="/mnt/foundry"

# =============================================================================
# Main Script Execution
# =============================================================================

# Ensure the script is run with administrative privileges
if [[ $EUID -ne 0 ]]; then
   echo_error "This script must be run as root. Use sudo."
   exit 1
fi

echo_info "Starting script..."

# Prompt for TrueNAS IP
TRUENAS_IP=$(prompt_with_default "Enter TrueNAS IP Address" "$PREDEF_TRUENAS_IP")

# Prompt for TrueNAS NFS export path
NFS_EXPORT=$(prompt_with_default "Enter NFS Export Path" "$PREDEF_NFS_EXPORT")

# Prompt for Ubuntu server mount point
MOUNT_POINT=$(prompt_with_default "Enter Mount Point" "$PREDEF_MOUNT_POINT")

# Prompt for Username
USERNAME=$(prompt_with_default "Enter Username" "$PREDEF_USERNAME")

# Prompt for User UID
USER_UID=$(prompt_with_default "Enter User UID" "$PREDEF_USER_UID")

# Prompt for Group Name
GROUPNAME=$(prompt_with_default "Enter Group name" "$PREDEF_GROUPNAME")

# Prompt for Group GID
GROUP_GID=$(prompt_with_default "Enter Group GID" "$PREDEF_GROUP_GID")

# Prompt for Domain Name (FQDN)
DOMAIN_NAME=$(prompt_with_default "Enter the domain name associated with your SSL certificate" "$PREDEF_DOMAIN_NAME")


# Define source certificate paths based on the provided domain name
CERT_SRC="/etc/letsencrypt/archive/$DOMAIN_NAME/fullchain.pem"
KEY_SRC="/etc/letsencrypt/archive/$DOMAIN_NAME/privkey.pem"

# Validate Group GID availability
if group_exists "$GROUPNAME"; then
    EXISTING_GID=$(getent group "$GROUPNAME" | cut -d: -f3)
    if [ "$EXISTING_GID" -ne "$GROUP_GID" ]; then
        echo_error "Group '$GROUPNAME' already exists with GID $EXISTING_GID, expected GID $GROUP_GID."
        exit 1
    else
        echo_success "Group '$GROUPNAME' already exists with GID $GROUP_GID."
    fi
else
    if gid_exists "$GROUP_GID"; then
        echo_error "GID $GROUP_GID is already in use by another group."
        exit 1
    fi

    # Create the group
    echo_info "Creating group '$GROUPNAME' with GID $GROUP_GID..."
    groupadd -g "$GROUP_GID" "$GROUPNAME"
    if [ $? -eq 0 ]; then
        echo_success "Group '$GROUPNAME' created successfully."
    else
        echo_error "Failed to create group '$GROUPNAME'."
        exit 1
    fi
fi

# Validate User UID availability
if user_exists "$USERNAME"; then
    EXISTING_UID=$(id -u "$USERNAME")
    EXISTING_GID=$(id -g "$USERNAME")
    if [ "$EXISTING_UID" -ne "$USER_UID" ]; then
        echo_error "User '$USERNAME' already exists with UID $EXISTING_UID, expected UID $USER_UID."
        exit 1
    fi

    if [ "$EXISTING_GID" -ne "$GROUP_GID" ]; then
        echo_info "User '$USERNAME' exists but is not in group '$GROUPNAME'. Adding to group..."
        usermod -g "$GROUPNAME" "$USERNAME"
        if [ $? -eq 0 ]; then
            echo_success "User '$USERNAME' added to group '$GROUPNAME'."
        else
            echo_error "Failed to add user '$USERNAME' to group '$GROUPNAME'."
            exit 1
        fi
    else
        echo_success "User '$USERNAME' already exists with UID $USER_UID and is in group '$GROUPNAME'."
    fi
else
    if uid_exists "$USER_UID"; then
        echo_error "UID $USER_UID is already in use by another user."
        exit 1
    fi

    # Define Home Directory and Shell
    DEFAULT_HOME="/home/$USERNAME"
    DEFAULT_SHELL="/bin/bash"

    # Prompt for Home Directory
    HOME_DIR=$(prompt_with_default "Enter Home Directory" "$DEFAULT_HOME")

    # Prompt for Default Shell
    USER_SHELL=$(prompt_with_default "Enter Default Shell" "$DEFAULT_SHELL")

    # Create the user
    echo_info "Creating user '$USERNAME' with UID $USER_UID, GID $GROUP_GID..."
    useradd -u "$USER_UID" -g "$GROUPNAME" -m -d "$HOME_DIR" -s "$USER_SHELL" "$USERNAME"
    if [ $? -eq 0 ]; then
        echo_success "User '$USERNAME' created successfully."
    else
        echo_error "Failed to create user '$USERNAME'."
        exit 1
    fi

    # Set password for the user
    echo_info "Setting password for user '$USERNAME'..."
    passwd "$USERNAME"
    if [ $? -eq 0 ]; then
        echo_success "Password set successfully for user '$USERNAME'."
    else
        echo_error "Failed to set password for user '$USERNAME'."
        exit 1
    fi
fi

echo_info "User and group setup completed successfully."


# Check if nfs-common is installed
if ! dpkg -l | grep -qw nfs-common; then
    echo "Installing required package 'nfs-common'..."
    sudo apt-get update
    sudo apt-get install -y nfs-common
else
    echo "'nfs-common' is already installed."
fi

# Create the mount point if it doesn't exist
if [ ! -d "$MOUNT_POINT" ]; then
    echo "Creating mount point at $MOUNT_POINT..."
    sudo mkdir -p "$MOUNT_POINT"
    sudo chown "$USERNAME":"$GROUPNAME" "$MOUNT_POINT"
else
    echo "Mount point $MOUNT_POINT already exists."
fi

# Backup the existing /etc/fstab
echo "Backing up /etc/fstab to /etc/fstab.bak..."
sudo cp /etc/fstab /etc/fstab.bak

# Add NFS share to /etc/fstab if not already present
FSTAB_ENTRY="$TRUENAS_IP:$NFS_EXPORT $MOUNT_POINT nfs defaults 0 0"
if ! grep -Fxq "$FSTAB_ENTRY" /etc/fstab; then
    echo "Adding NFS share to /etc/fstab..."
    echo "$FSTAB_ENTRY" | sudo tee -a /etc/fstab
else
    echo "NFS share is already present in /etc/fstab."
fi

# Mount the NFS share
echo "Mounting the NFS share..."
sudo mount -a

# Verify if the mount was successful
if mount | grep -q "$MOUNT_POINT"; then
    echo "NFS share successfully mounted at $MOUNT_POINT."
else
    echo "Failed to mount NFS share at $MOUNT_POINT."
fi


# Install Node.js version 20 if needed
if ! command -v node &> /dev/null; then
    echo "Node.js is not installed. Installing..."
    curl -fsSL https://deb.nodesource.com/setup_20.x -o nodesource_setup.sh
    sudo -E bash nodesource_setup.sh
    sudo apt-get install -y nodejs
    rm nodesource_setup.sh
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
    sudo bash -c "cat > $OPTIONS_JSON" <<EOL
{
  "dataPath": "$FVTT_DATA_DIR",
  "port": $PORT_NUMBER,
  "routePrefix": null,
  "compressStatic": true,
  "fullscreen": false,
  "hostname": null,
  "localHostname": null,
  "protocol": null,
  "proxyPort": null,
  "proxySSL": false,
  "sslCert": "fullchain.pem",
  "sslKey": "privkey.pem",
  "updateChannel": "stable",
  "language": "en.core",
  "fullscreen": false,
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
    
    sudo chown $USERNAME:$GROUPNAME "$OPTIONS_JSON"

    # Copy Certificates if they don't exist
    if [ ! -f "$CONFIG_DIR/fullchain.pem" ] || [ ! -f "$CONFIG_DIR/privkey.pem" ]; then
        echo "Copying certificates for instance $INSTANCE_NAME..."
        sudo cp "$CERT_SRC" "$CONFIG_DIR/fullchain.pem"
        sudo cp "$KEY_SRC" "$CONFIG_DIR/privkey.pem"
        sudo chown "$USERNAME:$GROUPNAME" "$CONFIG_DIR/fullchain.pem" "$CONFIG_DIR/privkey.pem"
    else
        echo "Certificates already exist for instance $INSTANCE_NAME."
    fi

    # Create and Configure Systemd Service if it doesn't exist
    SERVICE_FILE="/etc/systemd/system/$SERVICE_NAME"
    if [ -f "$SERVICE_FILE" ]; then
        echo "Service file $SERVICE_FILE already exists. Skipping creation."
    else
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
    fi

    # Enable and Restart Service
    sudo systemctl daemon-reload
    sudo systemctl enable "$SERVICE_NAME"
    sudo systemctl restart "$SERVICE_NAME"
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

# =============================================================================
# End of Script
# =============================================================================
