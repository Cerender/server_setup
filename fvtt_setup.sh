#!/bin/bash
set -euo pipefail

# Color-coded logging functions
echo_info() { echo -e "\e[34m[INFO]\e[0m $1"; }
echo_success() { echo -e "\e[32m[SUCCESS]\e[0m $1"; }
echo_error() { echo -e "\e[31m[ERROR]\e[0m $1" >&2; exit 1; }

# Validate input parameters
validate_input() {
    local value="$1"
    local type="$2"
    case "$type" in
        ip)
            if [[ ! "$value" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                echo_error "Invalid IP address: $value"
            fi
            ;;
        path)
            if [[ ! -d "$value" ]] && [[ "$value" != /* ]]; then
                echo_error "Invalid path: $value"
            fi
            ;;
        uid|gid)
            if [[ ! "$value" =~ ^[0-9]+$ ]] || ((value < 1000 || value > 60000)); then
                echo_error "Invalid $type: $value (must be between 1000-60000)"
            fi
            ;;
    esac
}

# Ensure root privileges
[[ $EUID -ne 0 ]] && echo_error "This script must be run as root. Use sudo."

# Predefined defaults
DEFAULTS=(
    "TRUENAS_IP:192.168.42.240"
    "NFS_EXPORT:/mnt/TrueNAS/Foundry"
    "MOUNT_POINT:/mnt/foundry"
    "USERNAME:jason"
    "USER_UID:3000"
    "GROUPNAME:fvtt_nfs"
    "GROUP_GID:3003"
    "DOMAIN_NAME:$(hostname).home.cerender.me"
)

# Prompt with defaults and validation
prompt_with_validation() {
    local prompt_key="$1"
    local default_value=""
    
    for item in "${DEFAULTS[@]}"; do
        if [[ "$item" == "$prompt_key:"* ]]; then
            default_value="${item#*:}"
            break
        fi
    done
    
    while true; do
        read -e -p "$prompt_key [$default_value]: " user_input
        user_input="${user_input:-$default_value}"
        
        case "$prompt_key" in
            "TRUENAS_IP") validate_input "$user_input" ip ;;
            "NFS_EXPORT"|"MOUNT_POINT") validate_input "$user_input" path ;;
            "USER_UID") validate_input "$user_input" uid ;;
            "GROUP_GID") validate_input "$user_input" gid ;;
            *) break ;;
        esac
    done
    
    echo "$user_input"
}

# Capture user inputs
TRUENAS_IP=$(prompt_with_validation "TRUENAS_IP")
NFS_EXPORT=$(prompt_with_validation "NFS_EXPORT")
MOUNT_POINT=$(prompt_with_validation "MOUNT_POINT")
USERNAME=$(prompt_with_validation "USERNAME")
USER_UID=$(prompt_with_validation "USER_UID")
GROUPNAME=$(prompt_with_validation "GROUPNAME")
GROUP_GID=$(prompt_with_validation "GROUP_GID")
DOMAIN_NAME=$(prompt_with_validation "DOMAIN_NAME")

# SSL Certificate paths
CERT_SRC="/etc/letsencrypt/live/$DOMAIN_NAME/fullchain.pem"
KEY_SRC="/etc/letsencrypt/live/$DOMAIN_NAME/privkey.pem"

# Validate certificates
[[ ! -f "$CERT_SRC" ]] && echo_error "Certificate not found: $CERT_SRC"
[[ ! -f "$KEY_SRC" ]] && echo_error "Key not found: $KEY_SRC"

# Ensure dependencies
DEPENDENCIES=("nfs-common" "curl" "nodejs")
for dep in "${DEPENDENCIES[@]}"; do
    dpkg -l | grep -qw "$dep" || apt-get install -y "$dep"
done

# Node.js version check
[[ "$(node -v)" != v20* ]] && {
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
    apt-get install -y nodejs
}

# Group and user management
create_group_if_not_exists() {
    local groupname="$1"
    local gid="$2"
    
    if ! getent group "$groupname" > /dev/null; then
        groupadd -g "$gid" "$groupname"
        echo_success "Group '$groupname' created with GID $gid"
    fi
}

create_user_if_not_exists() {
    local username="$1"
    local uid="$2"
    local groupname="$3"
    
    if ! id "$username" &>/dev/null; then
        useradd -u "$uid" -g "$groupname" -M -d /nonexistent -s /usr/sbin/nologin "$username" -r
        echo_success "Service user '$username' created"
    fi
}

create_group_if_not_exists "$GROUPNAME" "$GROUP_GID"
create_user_if_not_exists "$USERNAME" "$USER_UID" "$GROUPNAME"

# Prepare mount point
mkdir -p "$MOUNT_POINT"
chown "$USERNAME:$GROUPNAME" "$MOUNT_POINT"

# NFS mounting
FSTAB_ENTRY="$TRUENAS_IP:$NFS_EXPORT $MOUNT_POINT nfs defaults,x-systemd.automount,_netdev,noatime 0 0"
grep -qxF "$FSTAB_ENTRY" /etc/fstab || echo "$FSTAB_ENTRY" >> /etc/fstab
mount -a

# Find and process Foundry instances
process_foundry_instances() {
    local mount_dir="$1"
    local username="$2"
    local groupname="$3"
    local cert_src="$4"
    local key_src="$5"

    # Find Foundry instances
    mapfile -t INSTANCE_DIRS < <(find "$mount_dir" -maxdepth 1 -type d -name 'fvtt_*_*' -printf '%f\n')
    
    [[ ${#INSTANCE_DIRS[@]} -eq 0 ]] && echo_error "No Foundry instances found"

    for DIR_NAME in "${INSTANCE_DIRS[@]}"; do
        if [[ $DIR_NAME =~ ^fvtt_([a-zA-Z0-9_]+)_([0-9]+)$ ]]; then
            local instance_name="${BASH_REMATCH[1]}"
            local port_number="${BASH_REMATCH[2]}"
            local instance_dir="$mount_dir/$DIR_NAME"
            local vtt_dir="$instance_dir/fvtt_vtt"
            local data_dir="$instance_dir/fvtt_data"
            local config_dir="$data_dir/Config"
            local service_name="fvtt-${instance_name}.service"

            # Prepare directories
            mkdir -p "$config_dir"
            chown -R "$username:$groupname" "$config_dir"

            # Create options.json
            cat > "$config_dir/options.json" <<EOL
{
  "dataPath": "$data_dir",
  "port": $port_number,
  "sslCert": "fullchain.pem",
  "sslKey": "privkey.pem"
}
EOL

            # Copy certificates
            cp "$cert_src" "$config_dir/fullchain.pem"
            cp "$key_src" "$config_dir/privkey.pem"
            chmod 640 "$config_dir"/*.pem
            chown "$username:$groupname" "$config_dir"/*.pem

            # Create systemd service
            cat > "/etc/systemd/system/$service_name" <<EOL
[Unit]
Description=FoundryVTT Instance $instance_name
After=network.target

[Service]
User=$username
Group=$groupname
WorkingDirectory=$vtt_dir
ExecStart=/usr/bin/node $vtt_dir/resources/app/main.js
Restart=always

[Install]
WantedBy=multi-user.target
EOL

            # Enable and start service
            systemctl daemon-reload
            systemctl enable "$service_name"
            systemctl restart "$service_name"

            echo_success "Foundry instance $instance_name setup complete on port $port_number"
        fi
    done
}

# Execute instance processing
process_foundry_instances "$MOUNT_POINT" "$USERNAME" "$GROUPNAME" "$CERT_SRC" "$KEY_SRC"

echo_success "FoundryVTT Multi-Instance Setup Completed Successfully!"
