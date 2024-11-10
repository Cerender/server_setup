#!/bin/bash

# Ensure the script is run as root
if [ "$EUID" -ne 0 ]; then
    echo "Please run this script as root or with sudo."
    exit 1
fi

# Function to log messages with timestamps
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1"
}

# Function to prompt for input with confirmation and trimming
prompt_with_confirmation() {
    local prompt_message=$1
    local input_variable_name=$2
    local input_value
    local confirmation

    while true; do
        read -p "$prompt_message: " input_value
        # Trim leading/trailing whitespace
        input_value=$(echo "$input_value" | xargs)
        echo "You entered: '$input_value'"
        read -p "Is this correct? [Y/n]: " confirmation
        confirmation=${confirmation:-Y}
        if [[ "$confirmation" =~ ^[Yy]$ ]]; then
            eval $input_variable_name="'$input_value'"
            break
        else
            echo "Let's try again."
        fi
    done
}

# Prompt for user input with confirmation
prompt_with_confirmation "Enter your CloudFlare API Token" CLOUDFLARE_API_TOKEN
prompt_with_confirmation "Enter your Server Name (e.g., vtt.home.cerender.me)" SERVER_NAME
prompt_with_confirmation "Enter your Email Address" EMAIL_ADDRESS

# Debugging: Show the values of the variables
log "Debug: SERVER_NAME is '$SERVER_NAME'"
log "Debug: CLOUDFLARE_API_TOKEN is '$CLOUDFLARE_API_TOKEN'"
log "Debug: EMAIL_ADDRESS is '$EMAIL_ADDRESS'"

# Reverse the server name
REVERSED_SERVER_NAME=$(echo "$SERVER_NAME" | awk -F. '{ for(i=NF;i>0;i--) printf "%s%s", $i, (i==1?"\n":".") }')

# Start the setup
log "=== Starting Setup ==="

# Set the timezone
log "Setting timezone to America/New_York..."
timedatectl set-timezone America/New_York

# Update package lists
log "Updating package lists..."
apt update

# Install Cockpit
log "Installing Cockpit..."
apt -y install cockpit

# Create necessary directories
log "Creating necessary directories..."
mkdir -p /usr/lib/x86_64-linux-gnu/udisks2/modules

# Modify NetworkManager configuration
log "Configuring NetworkManager..."
echo -e "[keyfile]\nunmanaged-devices=none" > /etc/NetworkManager/conf.d/10-globally-managed-devices.conf

# Restart NetworkManager to apply changes
log "Restarting NetworkManager..."
systemctl restart NetworkManager

# Add dummy network interface
log "Adding dummy network interface..."
nmcli con add type dummy con-name fake ifname fake0 ip4 1.2.3.4/24 gw4 1.2.3.1

# Setup 45Drives repository
log "Setting up 45Drives repository..."
curl -sSL https://repo.45drives.com/setup -o setup-repo.sh
bash setup-repo.sh

# Install additional Cockpit packages
log "Installing additional Cockpit packages..."
apt install -y cockpit-navigator cockpit-file-sharing cockpit-identities

# Remove existing certbot if installed
log "Removing existing certbot..."
apt-get remove -y certbot

# Install snapd if not already installed
log "Installing snapd..."
apt install -y snapd

# Install certbot using snap
log "Installing certbot..."
snap install --classic certbot
ln -sf /snap/bin/certbot /usr/bin/certbot
snap set certbot trust-plugin-with-root=ok

# Install certbot-dns-cloudflare plugin
log "Installing certbot-dns-cloudflare plugin..."
snap install certbot-dns-cloudflare

# Create Let's Encrypt directory
mkdir -p /etc/letsencrypt

# Configure CloudFlare DNS credentials
log "Configuring CloudFlare DNS credentials..."
echo "dns_cloudflare_api_token = $CLOUDFLARE_API_TOKEN" > /etc/letsencrypt/dnscloudflare.ini
chmod 0600 /etc/letsencrypt/dnscloudflare.ini

# Obtain SSL certificate
log "Requesting SSL certificate..."
certbot certonly -d "$SERVER_NAME" --dns-cloudflare --dns-cloudflare-credentials /etc/letsencrypt/dnscloudflare.ini --non-interactive --agree-tos --email "$EMAIL_ADDRESS"

# Find the certificate directory
CERT_DIR=$(ls /etc/letsencrypt/live/ | grep "^$SERVER_NAME")
if [ -z "$CERT_DIR" ]; then
    log "Error: SSL certificate was not obtained. Please check your CloudFlare API token and domain settings."
    exit 1
fi

# Use the detected certificate directory
CERT_FILE="/etc/letsencrypt/live/$CERT_DIR/fullchain.pem"

# Check if certificate was obtained successfully
if [ -f "$CERT_FILE" ]; then
    log "SSL certificate obtained successfully."
else
    log "Error: SSL certificate file not found. Please check Certbot output for details."
    exit 1
fi

# Link certificates to Cockpit
log "Linking certificates to Cockpit..."
mkdir -p /etc/cockpit/ws-certs.d
ln -sf "/etc/letsencrypt/live/$CERT_DIR/fullchain.pem" "/etc/cockpit/ws-certs.d/${REVERSED_SERVER_NAME}.cert"
ln -sf "/etc/letsencrypt/live/$CERT_DIR/privkey.pem" "/etc/cockpit/ws-certs.d/${REVERSED_SERVER_NAME}.key"

# Ensure Cockpit recognizes the new certificates
log "Configuring Cockpit to use the new certificates..."
/usr/lib/cockpit/cockpit-certificate-ensure --check

# Restart Cockpit service to apply changes
log "Restarting Cockpit service..."
systemctl restart cockpit.service

# Install NGINX
log "Installing NGINX..."
apt install -y nginx

# Configure Cockpit
log "Configuring Cockpit..."
cat > /etc/cockpit/cockpit.conf <<EOL
[WebService]
Origins = https://$SERVER_NAME wss://$SERVER_NAME
ProtocolHeader = X-Forwarded-Proto
UrlRoot=/cockpit
EOL

# Configure NGINX reverse proxy
log "Configuring NGINX reverse proxy..."
cat > /etc/nginx/sites-available/custom_sites.conf <<EOL
server {
    listen 80;
    server_name $SERVER_NAME;

    # Redirect HTTP to HTTPS
    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl;
    server_name $SERVER_NAME;

    # SSL configuration
    ssl_certificate /etc/letsencrypt/live/$CERT_DIR/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$CERT_DIR/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;

    # Cockpit reverse proxy
    location /cockpit/ {
        proxy_pass http://127.0.0.1:9090/cockpit/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        # Handle WebSocket connections
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";

        gzip off;
    }

    # Ensure NGINX buffers large requests properly
    client_max_body_size 10M;
}
EOL

# Enable the NGINX site configuration
log "Enabling NGINX site configuration..."
ln -sf /etc/nginx/sites-available/custom_sites.conf /etc/nginx/sites-enabled/

# Test NGINX configuration
log "Testing NGINX configuration..."
nginx -t

# Reload NGINX to apply changes
log "Reloading NGINX..."
systemctl reload nginx

# Final message
log "Setup completed successfully!"
