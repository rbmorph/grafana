domain="<%=customOptions.graf_domain%>"
fqdn="<%=customOptions.fqdn%>"
prometheus_pass="<%=customOptions.prom_password%>"
grafana_pass="<%=customOptions.graf_password%>"

if command -v apt >/dev/null 2>&1; then
    # Install prerequisites
    export DEBIAN_FRONTEND=noninteractive
    sudo -E apt-get install -qq -y apt-transport-https software-properties-common wget > /dev/null 2>&1
    echo "apt-transport-https, software-properties-common and wget installed or confirmed installed"
elif command -v yum &> /dev/null; then
    :
else
    echo "Package Manager apt or yum not available. Prerequisites failed to install."
    exit
fi

# Install Grafana
if command -v apt >/dev/null 2>&1; then
    sudo mkdir -p /etc/apt/keyrings/
    wget -q -O - https://apt.grafana.com/gpg.key | gpg --dearmor | sudo tee /etc/apt/keyrings/grafana.gpg > /dev/null

    # Add Repo
    echo "deb [signed-by=/etc/apt/keyrings/grafana.gpg] https://apt.grafana.com stable main" | sudo tee -a /etc/apt/sources.list.d/grafana.list > /dev/null
    echo "Grafana Repo Added"
    # Update package list
    sudo -E apt-get -qq -y update > /dev/null

    # Install Grafana
    sudo -E apt-get -qq install -y grafana > /dev/null
    echo "Grafana Install completed"
elif command -v yum &> /dev/null; then
    wget -q -O gpg.key https://rpm.grafana.com/gpg.key > /dev/null
    sudo rpm --import gpg.key > /dev/null
    echo -e '[grafana]\nname=grafana\nbaseurl=https://rpm.grafana.com\nrepo_gpgcheck=1\nenabled=1\ngpgcheck=1\ngpgkey=https://rpm.grafana.com/gpg.key\nsslverify=1\nsslcacert=/etc/pki/tls/certs/ca-bundle.crt' | sudo tee /etc/yum.repos.d/grafana.repo > /dev/null
    echo "Grafana Repo Added"
    
    # Install Grafana
    sudo yum install -y grafana > /dev/null
    echo "Grafana Install completed"
else
    echo "Package Manager apt or yum not available. GPG Key Failed to install ."
    exit
fi

sudo systemctl enable grafana-server > /dev/null 2>&1
sudo systemctl start grafana-server > /dev/null
echo "Grafana service enabled and started"

# Create directory for Grafana certificates if it doesn't exist
sudo mkdir -p /etc/grafana
echo "/etc/grafana directory created"

# Generate private key
sudo openssl genrsa -out /etc/grafana/grafana.key 2048 > /dev/null

# Generate CSR (Certificate Signing Request) with auto-filled information
sudo openssl req -new -key /etc/grafana/grafana.key -out /etc/grafana/grafana.csr -subj "/C=US/ST=State/L=City/O=Organization/OU=Unit/CN=$cert_url" > /dev/null 2>&1

# Self-sign the certificate with the private key
sudo openssl x509 -req -days 1825 -in /etc/grafana/grafana.csr -signkey /etc/grafana/grafana.key -out /etc/grafana/grafana.crt > /dev/null 2>&1

# Set permissions on the files
sudo chown grafana:grafana /etc/grafana/grafana.crt
sudo chown grafana:grafana /etc/grafana/grafana.key
sudo chmod 400 /etc/grafana/grafana.key /etc/grafana/grafana.crt

echo "Certificates Created and added to /etc/grafana"

# Update grafana.ini with the specified settings
cat <<EOF | sudo tee /etc/grafana/grafana.ini > /dev/null
[server]
http_addr =
http_port = 3000
domain = $domain
root_url = https://$fqdn:3000
cert_key = /etc/grafana/grafana.key
cert_file = /etc/grafana/grafana.crt
enforce_domain = False
protocol = https
EOF

sleep 10

echo "grafana.ini config updated to support tls"

cat <<EOF | sudo tee /etc/grafana/provisioning/datasources/datasources.yaml > /dev/null
apiVersion: 1

datasources:
  - name: Prometheus
    type: prometheus
    url: https://localhost:9090
    access: proxy
    basicAuth: true
    basicAuthUser: "admin"     # Replace with your actual username
    uid: "cdsumkryioyrkc"
    secureJsonData:
      basicAuthPassword: "$prometheus_pass"
    jsonData:
      timeField: time
      tlsSkipVerify: true
EOF

echo "Grafana /etc/grafana/provisioning/datasources/datasources.yaml created for Prometheus datasource"

sudo grafana-cli admin reset-admin-password "$grafana_pass" > /dev/null 2>&1

echo "admin passowrd set to supplied password"

# create dashboards directory
mkdir /var/lib/grafana/dashboards  > /dev/null
chown -R grafana:grafana /var/lib/grafana/dashboards > /dev/null

# copy dashboards from github
wget -q -O /var/lib/grafana/dashboards/mysql_innodb_cluster.json https://raw.githubusercontent.com/rbmorph/grafanadash/main/mysql_innodb_cluster.json
wget -q -O /var/lib/grafana/dashboards/elasticsearch.json https://raw.githubusercontent.com/rbmorph/grafanadash/main/elasticsearch.json
wget -q -O /var/lib/grafana/dashboards/node_exporter.json https://raw.githubusercontent.com/rbmorph/grafanadash/main/node_exporter.json
wget -q -O /var/lib/grafana/dashboards/rabbitmq.json https://raw.githubusercontent.com/rbmorph/grafanadash/main/rabbitmq.json


# Set the dashboards yaml config
cat <<EOF | sudo tee /etc/grafana/provisioning/dashboards/dashboards.yaml > /dev/null
apiVersion: 1

providers:
 - name: 'default'
   orgId: 1
   folder: ''
   folderUid: ''
   type: file
   options:
     path: /var/lib/grafana/dashboards
EOF
echo "Dashboards have been downloaded and setup"

# Restart Grafana to apply changes
sudo systemctl restart grafana-server > /dev/null
echo "grafana-server service restarted"