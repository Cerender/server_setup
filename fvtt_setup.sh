#!/bin/bash
set -e

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
    getent group "$1" > /dev/null 2>&1
}

# Function to check if a UID is already in use
uid_exists() {
    getent passwd | awk -F: '{print $3}' | grep -qw "$1"
}

# Function to check if a GID is already in use
gid_exists() {
    getent group | awk -F: '{print $3}' | grep -qw "$1"
}

# Function to check if a user exists by name
user_exists() {
    id -u "$1" > /dev/null 2>&1
}

# =============================================================================
# Predefined Default Values
# =============================================================================
PREDEF_USERNAME="jason"
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

# Prompt for required information
TRUENAS_IP=$(prompt_with_default "Enter TrueNAS IP Address" "$PREDEF_TRUENAS_IP")
NFS_EXPORT=$(prompt_with_default "Enter NFS Export Path" "$PREDEF_NFS_EXPORT")
MOUNT_POINT=$(prompt_with_default "Enter Mount Point" "$PREDEF_MOUNT_POINT")
USERNAME=$(prompt_with_default "Enter Username" "$PREDEF_USERNAME")
USER_UID=$(prompt_with_default "Enter User UID" "$PREDEF_USER_UID")
GROUPNAME=$(prompt_with_default "Enter Group name" "$PREDEF_GROUPNAME")
GROUP_GID=$(prompt_with_default "Enter Group GID" "$PREDEF_GROUP_GID")
DOMAIN_NAME=$(prompt_with_default "Enter the domain name associated with your SSL certificate" "$PREDEF_DOMAIN_NAME")

# Define source certificate paths based on the provided domain name
CERT_SRC="/etc/letsencrypt/live/$DOMAIN_NAME/fullchain.pem"
KEY_SRC="/etc/letsencrypt/live/$DOMAIN_NAME/privkey.pem"

# Check if certificate files exist
if [ ! -f "$CERT_SRC" ] || [ ! -f "$KEY_SRC" ]; then
    echo_error "Certificate files not found at $CERT_SRC and $KEY_SRC."
    exit 1
fi

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
    echo_success "Group '$GROUPNAME' created successfully."
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
        echo_info "User '$USERNAME' exists but is not in group '$GROUPNAME'. Changing primary group..."
        usermod -g "$GROUPNAME" "$USERNAME"
        echo_success "User '$USERNAME' primary group changed to '$GROUPNAME'."
    else
        echo_success "User '$USERNAME' already exists with UID $USER_UID and is in group '$GROUPNAME'."
    fi
else
    if uid_exists "$USER_UID"; then
        echo_error "UID $USER_UID is already in use by another user."
        exit 1
    fi

    # Define Home Directory and Shell
    DEFAULT_HOME="/nonexistent"
    DEFAULT_SHELL="/usr/sbin/nologin"

    # Create the user as a service account
    echo_info "Creating service account user '$USERNAME' with UID $USER_UID, GID $GROUP_GID..."
    useradd -u "$USER_UID" -g "$GROUPNAME" -M -d "$DEFAULT_HOME" -s "$DEFAULT_SHELL" "$USERNAME" -r
    echo_success "Service account user '$USERNAME' created successfully."
fi

echo_info "User and group setup completed successfully."

# Check if nfs-common is installed
if ! dpkg -l | grep -qw nfs-common; then
    echo_info "Installing required package 'nfs-common'..."
    apt-get update
    apt-get install -y nfs-common
else
    echo_info "'nfs-common' is already installed."
fi

# Create the mount point if it doesn't exist
if [ ! -d "$MOUNT_POINT" ]; then
    echo_info "Creating mount point at $MOUNT_POINT..."
    mkdir -p "$MOUNT_POINT"
    chown "$USERNAME":"$GROUPNAME" "$MOUNT_POINT"
else
    echo_info "Mount point $MOUNT_POINT already exists."
fi

# Backup the existing /etc/fstab
if [ ! -f /etc/fstab.bak ]; then
    echo_info "Backing up /etc/fstab to /etc/fstab.bak..."
    cp /etc/fstab /etc/fstab.bak
fi

# Add NFS share to /etc/fstab if not already present
FSTAB_ENTRY="$TRUENAS_IP:$NFS_EXPORT $MOUNT_POINT nfs defaults 0 0"
if ! grep -Fxq "$FSTAB_ENTRY" /etc/fstab; then
    echo_info "Adding NFS share to /etc/fstab..."
    echo "$FSTAB_ENTRY" >> /etc/fstab
else
    echo_info "NFS share is already present in /etc/fstab."
fi

# Mount the NFS share
echo_info "Mounting the NFS share..."
mount -a

# Verify if the mount was successful
if mount | grep -q "$MOUNT_POINT"; then
    echo_success "NFS share successfully mounted at $MOUNT_POINT."
else
    echo_error "Failed to mount NFS share at $MOUNT_POINT."
    exit 1
fi

# Install Node.js version 20 if needed
if ! command -v node &> /dev/null || [[ "$(node -v)" != v20* ]]; then
    echo_info "Node.js version 20 is not installed. Installing..."
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
    apt-get install -y nodejs
fi

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

    # Ensure Config directory exists
    mkdir -p "$CONFIG_DIR"
    chown "$USERNAME:$GROUPNAME" "$CONFIG_DIR"

    # Update options.json
    cat > "$OPTIONS_JSON" <<EOL
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
    chown "$USERNAME:$GROUPNAME" "$OPTIONS_JSON"

    # Copy Certificates if they don't exist
    if [ ! -f "$CONFIG_DIR/fullchain.pem" ] || [ ! -f "$CONFIG_DIR/privkey.pem" ]; then
        echo_info "Copying certificates for instance $INSTANCE_NAME..."
        cp "$CERT_SRC" "$CONFIG_DIR/fullchain.pem"
        cp "$KEY_SRC" "$CONFIG_DIR/privkey.pem"
        chown "$USERNAME:$GROUPNAME" "$CONFIG_DIR/fullchain.pem" "$CONFIG_DIR/privkey.pem"
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
