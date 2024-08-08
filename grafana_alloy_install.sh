#!/bin/bash

prometheus_pass="<%=customOptions.prom_password%>"
# RabbitMQ
rabbit_nodes="<%=customOptions.rabbit_nodes%>" # Update this with actual RabbitMQ node IPs

# Elasticsearch
elasticsearch_nodes="<%=customOptions.elastic_nodes%>" # Update this with actual Elasticsearch node IPs
elasticsearch_port="<%=customOptions.elastic_port%>"

# MySQL
mysql_nodes="<%=customOptions.mysql_nodes%>" # Update this with actual MySQL node IPs

mysql_username="<%=customOptions.mysql_user%>"
mysql_password="<%=customOptions.mysql_pass%>"
mysql_port="<%=customOptions.mysql_port%>"

# Exit on any error
set -e

# Function to install a package if it is not already installed
#install_if_not_present() {
#    if ! command -v "$1" &> /dev/null; then
#        if command -v apt &> /dev/null; then
#            export DEBIAN_FRONTEND=noninteractive
#            sudo apt install -y "$1"
#        elif command -v yum &> /dev/null; then
#            sudo yum install -y "$1"
#        fi
#    fi
#}

# Install dependencies
if command -v apt &> /dev/null; then 
    export DEBIAN_FRONTEND=noninteractive
    sudo -E apt install -qq -y gpg > /dev/null 2>&1
fi
    

# Import GPG key and add Grafana Repo
if command -v apt &> /dev/null; then
    sudo mkdir -p /etc/apt/keyrings/
    wget -q -O - https://apt.grafana.com/gpg.key | gpg --dearmor | sudo tee /etc/apt/keyrings/grafana.gpg > /dev/null
    echo "deb [signed-by=/etc/apt/keyrings/grafana.gpg] https://apt.grafana.com stable main" | sudo tee /etc/apt/sources.list.d/grafana.list > /dev/null 2>&1
    # Update repos
    sudo -E apt-get update > /dev/null 2>&1
    # Install Alloy
    sudo -E apt-get install -y alloy > /dev/null 2>&1
elif command -v yum &> /dev/null; then
    wget -q -O gpg.key https://rpm.grafana.com/gpg.key > /dev/null
    sudo rpm --import gpg.key
    echo -e '[grafana]\nname=grafana\nbaseurl=https://rpm.grafana.com\nrepo_gpgcheck=1\nenabled=1\ngpgcheck=1\ngpgkey=https://rpm.grafana.com/gpg.key\nsslverify=1\nsslcacert=/etc/pki/tls/certs/ca-bundle.crt' | sudo tee /etc/yum.repos.d/grafana.repo
    # Install Alloy
    sudo yum install -y alloy
else
    echo "Unsupported package manager. Please install gpg and Grafana manually."
    exit 1
fi



# Convert the comma-separated values into arrays
#IFS=',' read -r -a rabbit_nodes <<< "$rabbit_nodes"
IFS=',' read -r -a elasticsearch_nodes <<< "$elasticsearch_nodes"
IFS=',' read -r -a mysql_nodes <<< "$mysql_nodes"

# Update the Alloy config file
config_file="/etc/alloy/config.alloy"

# Create the config file with initial content
#sudo tee "$CONFIG_FILE" > /dev/null <<EOL
#EOL

# Loop through the array of RabbitMQ nodes and create entries
#for index in "${!rabbit_nodes[@]}"; do
#    node_ip="${rabbit_nodes[$index]}"
#    node_number=$((index + 1))
#
#    cat <<EOL | sudo tee -a "$config_file" > /dev/null
#discovery.relabel "metrics_integrations_rabbitmq_node$node_number" {
#    targets = [{
#        __address__ = "$node_ip:15692",
#    }]
#    rule {
#        target_label = "instance"
#        replacement  = "rabbitmq-node$node_number"
#    }
#}
#EOL
#done

# Loop through the array of Elasticsearch nodes and create entries
for index in "${!elasticsearch_nodes[@]}"; do
    node_ip="${elasticsearch_nodes[$index]}"
    node_number=$((index + 1))

    cat <<EOL | sudo tee -a "$config_file" > /dev/null
prometheus.exporter.elasticsearch "elastic$node_number" {
  address = "http://$node_ip:$elasticsearch_port"
}
EOL
done

# Loop through the array of MySQL nodes and create entries
for index in "${!mysql_nodes[@]}"; do
    node_ip="${mysql_nodes[$index]}"
    node_number=$((index + 1))

    cat <<EOL | sudo tee -a "$config_file" > /dev/null
prometheus.exporter.mysql "mysql$node_number" {
  data_source_name  = "$mysql_username:$mysql_password@($node_ip:$mysql_port)/"
  enable_collectors = ["heartbeat", "mysql.user", "perf_schema.replication_group_members"]
}
EOL
done

# Add the Prometheus scrape configuration for RabbitMQ
#cat <<EOL | sudo tee -a "$config_file" > /dev/null
#prometheus.scrape "metrics_integrations_rabbitmq" {
#    targets    = concat(
#EOL

# Add the RabbitMQ target entries
#for index in "${!rabbit_nodes[@]}"; do
#    echo "        discovery.relabel.metrics_integrations_rabbitmq_node$((index + 1)).output," | sudo tee -a "$config_file" > /dev/null
#done

# Close the Prometheus scrape configuration for RabbitMQ
cat <<EOL | sudo tee -a "$config_file" > /dev/null
prometheus.exporter.unix "node" { }

prometheus.scrape "node" {
  targets    = prometheus.exporter.unix.node.targets
  forward_to = [prometheus.remote_write.prometheus.receiver]
  scrape_interval = "30s"
}
EOL

# Add scraping for Elasticsearch
for index in "${!elasticsearch_nodes[@]}"; do
    cat <<EOL | sudo tee -a "$config_file" > /dev/null
prometheus.scrape "elastic$((index + 1))" {
  targets    = prometheus.exporter.elasticsearch.elastic$((index + 1)).targets
  forward_to = [prometheus.remote_write.prometheus.receiver]
}
EOL
done

# Add scraping for MySQL
for index in "${!mysql_nodes[@]}"; do
    cat <<EOL | sudo tee -a "$config_file" > /dev/null
prometheus.scrape "mysql$((index + 1))" {
  targets    = prometheus.exporter.mysql.mysql$((index + 1)).targets
  forward_to = [prometheus.remote_write.prometheus.receiver]
}
EOL
done

# Add the Prometheus remote write configuration
cat <<EOL | sudo tee -a "$config_file" > /dev/null
prometheus.remote_write "prometheus" {
  endpoint {
    url = "https://localhost:9090/api/v1/write"
    
    basic_auth {
      username = "admin"
      password = "$prometheus_pass"
    }
    tls_config {
      insecure_skip_verify = true
    }
  }
}
EOL

systemctl enable alloy > /dev/null 2>&1
systemctl restart alloy > /dev/null 2>&1