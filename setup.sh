#!/bin/bash

# Function to add crontab entry if not already present
add_cron_job() {
    sudo crontab -l 2>/dev/null | grep -q "@reboot /root/continue_script.sh"
    if [ $? -ne 0 ]; then
        (sudo crontab -l 2>/dev/null; echo "@reboot /root/continue_script.sh") | sudo crontab -
    fi
}

# Function to remove crontab entry
remove_cron_job() {
    sudo crontab -l | grep -v '/root/continue_script.sh' | sudo crontab -
}

if [ ! -f /var/tmp/script_stage ]; then
    # Stage 0: Initial setup before reboot
    echo "=== Initial Setup ==="
    read -p "Enter your CloudFlare API Token: " CLOUDFLARE_API_TOKEN
    read -p "Enter your Server Name (e.g., vtt.home.cerender.me): " SERVER_NAME
    read -p "Enter your Email Address: " EMAIL_ADDRESS

    # Reverse the server name
    REVERSED_SERVER_NAME=$(echo "$SERVER_NAME" | awk -F. '{ for(i=NF;i>0;i--) printf "%s%s", $i, (i==1?"\n":".") }')

    # Save variables to a file
    sudo tee /var/tmp/script_vars > /dev/null <<EOL
CLOUDFLARE_API_TOKEN="$CLOUDFLARE_API_TOKEN"
SERVER_NAME="$SERVER_NAME"
EMAIL_ADDRESS="$EMAIL_ADDRESS"
REVERSED_SERVER_NAME="$REVERSED_SERVER_NAME"
EOL

    # Run initial commands
    echo "Setting timezone to America/New_York..."
    sudo timedatectl set-timezone America/New_York

    echo "Installing Cockpit..."
    sudo apt update
    sudo apt -y install cockpit

    sudo mkdir -p /usr/lib/x86_64-linux-gnu/udisks2/modules

    . /etc/os-release

    # Modify 10-globally-managed-devices.conf
    echo "Configuring NetworkManager..."
    echo -e "[keyfile]\nunmanaged-devices=none" | sudo tee /etc/NetworkManager/conf.d/10-globally-managed-devices.conf

    # Add dummy network interface
    echo "Adding dummy network interface..."
    sudo nmcli con add type dummy con-name fake ifname fake0 ip4 1.2.3.4/24 gw4 1.2.3.1

    # Install 45Drives repository and setup
    echo "Setting up 45Drives repository..."
    curl -sSL https://repo.45drives.com/setup -o setup-repo.sh
    sudo bash setup-repo.sh

    # Install additional Cockpit packages
    echo "Installing additional Cockpit packages..."
    sudo apt install -y cockpit-navigator cockpit-file-sharing cockpit-identities

    # Schedule script to run after reboot
    echo "Scheduling script to continue after reboot..."
    sudo cp "$0" /root/continue_script.sh
    sudo chmod +x /root/continue_script.sh
    add_cron_job

    # Mark the stage
    echo "stage1" | sudo tee /var/tmp/script_stage

    echo "Rebooting the system..."
    sudo reboot
    exit 0
else
    STAGE=$(cat /var/tmp/script_stage)
    if [ "$STAGE" = "stage1" ]; then
        # Stage 1: Continue setup after reboot
        echo "=== Continuing Setup After Reboot ==="
        source /var/tmp/script_vars

        echo "Removing existing certbot..."
        sudo apt-get remove -y certbot

        echo "Installing certbot..."
        sudo snap install --classic certbot
        sudo ln -sf /snap/bin/certbot /usr/bin/certbot
        sudo snap set certbot trust-plugin-with-root=ok

        echo "Installing certbot-dns-cloudflare plugin..."
        sudo snap install certbot-dns-cloudflare

        sudo mkdir -p /etc/letsencrypt

        echo "Configuring CloudFlare DNS credentials..."
        echo "dns_cloudflare_api_token = $CLOUDFLARE_API_TOKEN" | sudo tee /etc/letsencrypt/dnscloudflare.ini > /dev/null
        sudo chmod 0600 /etc/letsencrypt/dnscloudflare.ini

        echo "Requesting SSL certificate..."
        sudo certbot certonly -d "$SERVER_NAME" --dns-cloudflare --dns-cloudflare-credentials /etc/letsencrypt/dnscloudflare.ini --non-interactive --agree-tos --email "$EMAIL_ADDRESS"

        echo "Linking certificates to Cockpit..."
        sudo mkdir -p /etc/cockpit/ws-certs.d
        sudo ln -sf /etc/letsencrypt/live/"$SERVER_NAME"/fullchain.pem /etc/cockpit/ws-certs.d/"$REVERSED_SERVER_NAME".cert
        sudo ln -sf /etc/letsencrypt/live/"$SERVER_NAME"/privkey.pem /etc/cockpit/ws-certs.d/"$REVERSED_SERVER_NAME".key

        sudo /usr/lib/cockpit/cockpit-certificate-ensure --check

        echo "Installing NGINX..."
        sudo apt install -y nginx

        echo "Configuring Cockpit..."
        sudo tee /etc/cockpit/cockpit.conf > /dev/null <<EOL
[WebService]
Origins = https://$SERVER_NAME wss://$SERVER_NAME
ProtocolHeader = X-Forwarded-Proto
UrlRoot=/cockpit
EOL

        echo "Configuring NGINX..."
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

        sudo ln -sf /etc/nginx/sites-available/custom_sites.conf /etc/nginx/sites-enabled/

        echo "Testing NGINX configuration..."
        sudo nginx -t

        echo "Reloading NGINX..."
        sudo systemctl reload nginx

        # Clean up
        echo "Cleaning up..."
        sudo rm /var/tmp/script_stage
        remove_cron_job
        sudo rm /root/continue_script.sh
        sudo rm /var/tmp/script_vars

        echo "Setup completed successfully!"
        exit 0
    else
        echo "Unknown stage. Exiting."
        exit 1
    fi
fi
