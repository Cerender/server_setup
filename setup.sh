#!/bin/bash

# Function to log messages
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1"
}

# Function to prompt for input with confirmation
prompt_with_confirmation() {
    local prompt_message=$1
    local input_variable_name=$2
    local input_value
    local confirmation

    while true; do
        read -p "$prompt_message: " input_value
        echo "You entered: $input_value"
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

# Reverse the server name
REVERSED_SERVER_NAME=$(echo "$SERVER_NAME" | awk -F. '{ for(i=NF;i>0;i--) printf "%s%s", $i, (i==1?"\n":".") }')

# Start the setup
log "=== Starting Setup ==="

# Set the timezone
log "Setting timezone to America/New_York..."
sudo timedatectl set-timezone America/New_York

# Update package lists
log "Updating package lists..."
sudo apt update

# Install Cockpit
log "Installing Cockpit..."
sudo apt -y install cockpit

# Create necessary directories
log "Creating necessary directories..."
sudo mkdir -p /usr/lib/x86_64-linux-gnu/udisks2/modules

# Modify NetworkManager configuration
log "Configuring NetworkManager..."
echo -e "[keyfile]\nunmanaged-devices=none" | sudo tee /etc/NetworkManager/conf.d/10-globally-managed-devices.conf

# Restart NetworkManager to apply changes
log "Restarting NetworkManager..."
sudo systemctl restart NetworkManager

# Add dummy network interface
log "Adding dummy network interface..."
sudo nmcli con add type dummy con-name fake ifname fake0 ip4 1.2.3.4/24 gw4 1.2.3.1

# Setup 45Drives repository
log "Setting up 45Drives repository..."
curl -sSL https://repo.45drives.com/setup -o setup-repo.sh
sudo bash setup-repo.sh

# Install additional Cockpit packages
log "Installing additional Cockpit packages..."
sudo apt install -y cockpit-navigator cockpit-file-sharing cockpit-identities

# Remove existing certbot if installed
log "Removing existing certbot..."
sudo apt-get remove -y certbot

# Install snapd if not already installed
log "Installing snapd..."
sudo apt install -y snapd

# Install certbot using snap
log "Installing certbot..."
sudo snap install --classic certbot
sudo ln -sf /snap/bin/certbot /usr/bin/certbot
sudo snap set certbot trust-plugin-with-root=ok

# Install certbot-dns-cloudflare plugin
log "Installing certbot-dns-cloudflare plugin..."
sudo snap install certbot-dns-cloudflare

# Create Let's Encrypt directory
sudo mkdir -p /etc/letsencrypt

# Configure CloudFlare DNS credentials
log "Configuring CloudFlare DNS credentials..."
echo "dns_cloudflare_api_token = $CLOUDFLARE_API_TOKEN" | sudo tee /etc/letsencrypt/dnscloudflare.ini > /dev/null
sudo chmod 0600 /etc/letsencrypt/dnscloudflare.ini

# Obtain SSL certificate
log "Requesting SSL certificate..."
sudo certbot certonly -d "$SERVER_NAME" --dns-cloudflare --dns-cloudflare-credentials /etc/letsencrypt/dnscloudflare.ini --non-interactive --agree-tos --email "$EMAIL_ADDRESS"

# Check if certificate was obtained successfully
if [ ! -d "/etc/letsencrypt/live/$SERVER_NAME" ]; then
    log "Error: SSL certificate was not obtained. Please check your CloudFlare API token and domain settings."
    exit 1
fi

# Link certificates to Cockpit
log "Linking certificates to Cockpit..."
sudo mkdir -p /etc/cockpit/ws-certs.d
sudo ln -sf /etc/letsencrypt/live/"$SERVER_NAME"/fullchain.pem /etc/cockpit/ws-certs.d/"$REVERSED_SERVER_NAME".cert
sudo ln -sf /etc/letsencrypt/live/"$SERVER_NAME"/privkey.pem /etc/cockpit/ws-certs.d/"$REVERSED_SERVER_NAME".key

# Ensure Cockpit recognizes the new certificates
log "Configuring Cockpit to use the new certificates..."
sudo /usr/lib/cockpit/cockpit-certificate-ensure --check

# Restart Cockpit service to apply changes
log "Restarting Cockpit service..."
sudo systemctl restart cockpit.service

# Install NGINX
log "Installing NGINX..."
sudo apt install -y nginx

# Configure Cockpit
log "Configuring Cockpit..."
sudo tee /etc/cockpit/cockpit.conf > /dev/null <<EOL
[WebService]
Origins = https://$SERVER_NAME wss://$SERVER_NAME
ProtocolHeader = X-Forwarded-Proto
UrlRoot=/cockpit
EOL

# Configure NGINX reverse proxy
log "Configuring NGINX reverse proxy..."
sudo tee /etc/nginx/sites-available/custom_sites.conf > /dev/null <<EOL
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
    ssl_certificate /etc/letsencrypt/live/$SERVER_NAME/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$SERVER_NAME/privkey.pem;
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
sudo ln -sf /etc/nginx/sites-available/custom_sites.conf /etc/nginx/sites-enabled/

# Test NGINX configuration
log "Testing NGINX configuration..."
sudo nginx -t

# Reload NGINX to apply changes
log "Reloading NGINX..."
sudo systemctl reload nginx

# Final message
log "Setup completed successfully!"
