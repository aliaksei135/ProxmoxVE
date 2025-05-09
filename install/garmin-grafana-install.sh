#!/usr/bin/env bash

# Copyright (c) 2021-2025 community-scripts ORG
# Author: aliaksei135
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://github.com/arpanghosh8453/garmin-grafana

# Import Functions und Setup
source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"
color
verb_ip6
catch_errors
setting_up_container
network_check
update_os

# Installing Dependencies
msg_info "Installing Dependencies"
# Grafana dependencies
$STD apt-get install -y gnupg
$STD apt-get install -y apt-transport-https
$STD apt-get install -y software-properties-common
# Influx dependencies
$STD apt-get install -y lsb-base
$STD apt-get install -y lsb-release
$STD apt-get install -y gnupg2
# garmin-grafana dependencies
$STD apt-get install -y python3
$STD apt-get install -y python3-requests
$STD apt-get install -y python3-dotenv
setup_uv
msg_ok "Installed Dependencies"

msg_info "Setting up InfluxDB Repository"
curl -fsSL "https://repos.influxdata.com/influxdata-archive_compat.key" | gpg --dearmor >/etc/apt/trusted.gpg.d/influxdata-archive_compat.gpg
echo "deb [signed-by=/etc/apt/trusted.gpg.d/influxdata-archive_compat.gpg] https://repos.influxdata.com/debian stable main" >/etc/apt/sources.list.d/influxdata.list
msg_ok "Set up InfluxDB Repository"

# garmin-grafana recommends influxdb v1
# this install chronograf, which is the UI for influxdb. this might be overkill?
msg_info "Installing InfluxDB"
$STD apt-get update
$STD apt-get install -y influxdb
curl -fsSL "https://dl.influxdata.com/chronograf/releases/chronograf_1.10.7_amd64.deb" -o "$(basename "https://dl.influxdata.com/chronograf/releases/chronograf_1.10.7_amd64.deb")"
$STD dpkg -i chronograf_1.10.7_amd64.deb
msg_ok "Installed InfluxDB"

msg_info "Setting up InfluxDB"
# Patch the config file to use the tsi1 index
$STD sed -i 's/# index-version = "inmem"/index-version = "tsi1"/' /etc/influxdb/influxdb.conf

# Create InfluxDB user and database
INFLUXDB_USER="garmin_grafana_user"
INFLUXDB_PASSWORD=$(openssl rand -base64 18 | tr -dc 'a-zA-Z0-9' | cut -c1-13)
INFLUXDB_NAME="GarminStats"
$STD influx -execute "CREATE DATABASE ${INFLUXDB_NAME}"
$STD influx -execute "CREATE USER ${INFLUXDB_USER} WITH PASSWORD '${INFLUXDB_PASSWORD}'"
$STD influx -execute "GRANT ALL ON ${INFLUXDB_NAME} TO ${INFLUXDB_USER}"
# Start the service
$STD systemctl enable --now influxdb
msg_ok "Set up InfluxDB"

msg_info "Setting up Grafana Repository"
curl -fsSL "https://apt.grafana.com/gpg.key" -o "/usr/share/keyrings/grafana.key"
sh -c 'echo "deb [signed-by=/usr/share/keyrings/grafana.key] https://apt.grafana.com stable main" > /etc/apt/sources.list.d/grafana.list'
msg_ok "Set up Grafana Repository"

msg_info "Installing Grafana"
$STD apt-get update
$STD apt-get install -y grafana
systemctl start grafana-server
systemctl daemon-reload
systemctl enable --now -q grafana-server.service
sleep 10
msg_ok "Installed Grafana"

msg_info "Setting up Grafana"
GRAFANA_USER="admin"
GRAFANA_PASS=$(openssl rand -base64 18 | tr -dc 'a-zA-Z0-9' | cut -c1-13)
# Create Grafana user
$STD grafana-cli admin reset-admin-password "${GRAFANA_PASS}"
# # Install plugins
$STD grafana-cli plugins install marcusolsson-hourly-heatmap-panel
$STD systemctl restart grafana-server
# Output credentials to file
{
  echo "Grafana Credentials"
  echo "Grafana User: ${GRAFANA_USER}"
  echo "Grafana Password: ${GRAFANA_PASS}"
} >>~/.garmin-grafana.creds
msg_ok "Setup Grafana"

# Setup App
msg_info "Installing garmin-grafana"
RELEASE=$(curl -fsSL https://api.github.com/repos/arpanghosh8453/garmin-grafana/releases/latest | grep "tag_name" | awk '{print substr($2, 2, length($2)-3) }')
curl -fsSL -o "${RELEASE}.zip" "https://github.com/arpanghosh8453/garmin-grafana/archive/refs/tags/${RELEASE}.zip"
unzip -q "${RELEASE}.zip"
# Remove the v prefix to RELEASE if it exists
if [[ "${RELEASE}" == v* ]]; then
  RELEASE="${RELEASE:1}"
fi
mv "garmin-grafana-${RELEASE}/" "/opt/garmin-grafana"
# Create dir for garmin tokens
mkdir -p /opt/garmin-grafana/.garminconnect
# Install python dependencies with uv
# Set uv options to use system sitepackages
$STD uv sync --locked --no-build-isolation --project /opt/garmin-grafana/
# Copy across grafana data
cp -r /opt/garmin-grafana/Grafana_Datasource /etc/grafana/provisioning/datasources
cp -r /opt/garmin-grafana/Grafana_Dashboard /etc/grafana/provisioning/dashboards
echo "${RELEASE}" >"/opt/garmin-grafana_version.txt"
msg_ok "Installed garmin-grafana"

msg_info "Setting up garmin-grafana"
# Check if using Chinese garmin servers
read -rp "Are you using Garmin in mainland China? (y/N): " prompt
if [[ "${prompt,,}" =~ ^(y|yes|Y)$ ]]; then
  GARMIN_CN="True"
else
  GARMIN_CN="False"
fi

# Setup environment variables
cat <<EOF >/opt/garmin-grafana/.env
INFLUXDB_HOST=localhost
INFLUXDB_PORT=8086
INFLUXDB_ENDPOINT_IS_HTTP=True
INFLUXDB_USERNAME=${INFLUXDB_USER}
INFLUXDB_PASSWORD=${INFLUXDB_PASSWORD}
INFLUXDB_DATABASE=${INFLUXDB_NAME}
GARMIN_IS_CN=${GARMIN_CN}
TOKEN_DIR=/opt/garmin-grafana/.garminconnect
EOF

# garmin-grafana usually prompts the user for email and password (and MFA) on first run,
# then stores a refreshable token. We try to avoid storing user credentials in the env vars
if [ -z "$(ls -A /opt/garmin-grafana/.garminconnect)" ]; then
  # Run the script once to prompt for credential
  msg_info "Creating Garmin credentials, this will timeout in 60 seconds"
  timeout 60s uv run --env-file /opt/garmin-grafana/.env /opt/garmin-grafana/src/garmin_grafana/garmin_fetch.py
  # Check if there is anything in the token dir now
  if [ -z "$(ls -A /opt/garmin-grafana/.garminconnect)" ]; then
    msg_error "Failed to create a token"
    exit
  fi
fi

# Restart Grafana to pick up the provisioned data sources and dashboards
$STD systemctl restart grafana-server
msg_ok "Setup garmin-grafana"

# Creating Service (if needed)
msg_info "Creating Service"
cat <<EOF >/etc/systemd/system/garmin-grafana.service
[Unit]
Description=garmin-grafana Service
After=network.target

[Service]
ExecStart=uv run /opt/garmin-grafana/src/garmin_grafana/garmin_fetch.py
Restart=always
EnvironmentFile=/opt/garmin-grafana/.env

[Install]
WantedBy=multi-user.target
EOF
systemctl enable -q --now garmin-grafana
msg_ok "Created Service"

motd_ssh
customize

# Cleanup
msg_info "Cleaning up"
rm -f "${RELEASE}".zip
$STD apt-get -y autoremove
$STD apt-get -y autoclean
msg_ok "Cleaned"
