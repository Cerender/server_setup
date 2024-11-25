#!/bin/bash

# Define source certificate paths
CERT_SRC="/etc/letsencrypt/live/fvtt.home.cerender.me/fullchain.pem"
KEY_SRC="/etc/letsencrypt/live/fvtt.home.cerender.me/privkey.pem"

# Define destination directories for Foundry VTT instances
FOUNDRY1_CONFIG="/home/fvtt/foundry/foundrydata/Config"
FOUNDRY2_CONFIG="/home/fvtt/foundry_test/foundrydata/Config"

# Define the user and group for ownership
USER="fvtt"
GROUP="fvtt"

# Copy certificates to Foundry VTT 1
cp "$CERT_SRC" "$FOUNDRY1_CONFIG/fullchain.pem"
cp "$KEY_SRC" "$FOUNDRY1_CONFIG/privkey.pem"

# Set ownership for Foundry VTT 1
chown "$USER:$GROUP" "$FOUNDRY1_CONFIG/fullchain.pem"
chown "$USER:$GROUP" "$FOUNDRY1_CONFIG/privkey.pem"

# Copy certificates to Foundry VTT 2
cp "$CERT_SRC" "$FOUNDRY2_CONFIG/fullchain.pem"
cp "$KEY_SRC" "$FOUNDRY2_CONFIG/privkey.pem"

# Set ownership for Foundry VTT 2
chown "$USER:$GROUP" "$FOUNDRY2_CONFIG/fullchain.pem"
chown "$USER:$GROUP" "$FOUNDRY2_CONFIG/privkey.pem"

# Restart Foundry VTT services to apply the new certificates
systemctl restart fvtt.service
systemctl restart fvtt_test.service
