#!/bin/bash

# Strict mode
set -eou pipefail

# --------------------------------------------------------------------------------
# USER INPUTS - Regions
# --------------------------------------------------------------------------------
echo "--------------------------------------------------"
echo "Please provide the regions for the lab setup."
echo "Examples: us-central1, europe-west1, asia-east1"
echo "Ensure the regions you pick have the necessary GCE resources available."
echo "--------------------------------------------------"

# Prompt for Primary Region
read -p "Enter the primary region (e.g., us-central1): " USER_NAT_REGION_1
while [[ -z "$USER_NAT_REGION_1" ]]; do
    echo "Primary region cannot be empty."
    read -p "Enter the primary region (e.g., us-central1): " USER_NAT_REGION_1
done
export NAT_REGION_1="${USER_NAT_REGION_1}"

# Prompt for Secondary Region
read -p "Enter the secondary region (e.g., europe-west1, must be different from primary): " USER_MIG_NOTUS_REGION
while [[ -z "$USER_MIG_NOTUS_REGION" || "$USER_MIG_NOTUS_REGION" == "$NAT_REGION_1" ]]; do
    if [[ -z "$USER_MIG_NOTUS_REGION" ]]; then
        echo "Secondary region cannot be empty."
    else
        echo "Secondary region must be different from the primary region (${NAT_REGION_1})."
    fi
    read -p "Enter the secondary region (e.g., europe-west1): " USER_MIG_NOTUS_REGION
done
export MIG_NOTUS_REGION="${USER_MIG_NOTUS_REGION}"

read -p "Enter the zone for webserver (e.g., us-central1-c): " WEBSERVER_ZONE_1
while [[ -z "$WEBSERVER_ZONE_1" ]]; do
    echo "Primary zone cannot be empty."
    read -p "Enter the zone region (e.g., us-central1-c): " WEBSERVER_ZONE_1
done
export WEBSERVER_ZONE_1="${WEBSERVER_ZONE_1}" # Zone for the initial webserver VM

# Prompt for Stress Test VM Region
DEFAULT_STRESS_REGION="us-east1" # Default suggestion
if [ "$NAT_REGION_1" == "us-east1" ]; then # Avoid suggesting the same region as primary
    DEFAULT_STRESS_REGION="us-west1"
fi
read -p "Enter the stress test VM region (e.g., ${DEFAULT_STRESS_REGION}, different from primary, ideally closer to it): " USER_STRESS_TEST_REGION
while [[ -z "$USER_STRESS_TEST_REGION" ]]; do
    echo "Stress test VM region cannot be empty."
    read -p "Enter the stress test VM region (e.g., ${DEFAULT_STRESS_REGION}): " USER_STRESS_TEST_REGION
done
# Basic check, user might need to pick a truly closer one
if [ "$USER_STRESS_TEST_REGION" == "$NAT_REGION_1" ]; then
    echo "Warning: Stress test VM region is the same as the primary region. This might not accurately test geographic load balancing."
fi
export STRESS_TEST_REGION="${USER_STRESS_TEST_REGION}"


# --------------------------------------------------------------------------------
# EXPORT VARIABLES - Configure these based on your lab or preferences
# --------------------------------------------------------------------------------

# Project ID will be automatically fetched from gcloud config if not set by Qwiklabs
export PROJECT_ID="${GOOGLE_CLOUD_PROJECT:-$(gcloud config get-value project)}"

# Network
export NETWORK="default"

# Task 1: Health Check Firewall Rule
export FW_HEALTH_CHECK_NAME="fw-allow-health-checks"
export HEALTH_CHECK_TAG="allow-health-checks"
export HEALTH_CHECK_SOURCE_RANGES="130.211.0.0/22,35.191.0.0/16"

# Task 2: NAT Configuration (NAT_REGION_1 is now from user input)
export NAT_GW_NAME="nat-config"
export NAT_ROUTER_NAME="nat-router-${NAT_REGION_1}" # Derived from user input

# Task 3: Custom Image
export WEBSERVER_VM_NAME="webserver"
export CUSTOM_IMAGE_NAME="mywebserver"
export WEBSERVER_MACHINE_TYPE="e2-micro"

# Task 4: Instance Template and Instance Groups
export INSTANCE_TEMPLATE_NAME="mywebserver-template"
export MIG_HEALTH_CHECK_NAME="http-health-check" # TCP health check for MIGs
export MIG_US_NAME="us-1-mig" # Name kept generic as per lab
export MIG_US_REGION="${NAT_REGION_1}" # Assigned from user input for primary region
export MIG_NOTUS_NAME="notus-1-mig" # Name kept generic
# MIG_NOTUS_REGION is from user input

# Task 5: Application Load Balancer
export LB_NAME="http-lb"
export BACKEND_SERVICE_NAME="http-backend"

# Task 6: Stress Test (STRESS_TEST_REGION is from user input)
export STRESS_TEST_VM_NAME="stress-test"
export STRESS_TEST_ZONE="${STRESS_TEST_REGION}-b" # Derived from user input (assumes '-b' is valid)
export STRESS_TEST_MACHINE_TYPE="e2-micro"

# --------------------------------------------------------------------------------
# SCRIPT LOGIC - DO NOT MODIFY BELOW THIS LINE UNLESS YOU KNOW WHAT YOU ARE DOING
# --------------------------------------------------------------------------------

echo "--------------------------------------------------"
echo "Starting Lab: Configure an Application Load Balancer with Autoscaling"
echo "Project ID: ${PROJECT_ID}"
echo "Primary Region (NAT, MIG1): ${NAT_REGION_1}"
echo "Secondary Region (MIG2): ${MIG_NOTUS_REGION}"
echo "Stress Test VM Region: ${STRESS_TEST_REGION}"
echo "--------------------------------------------------"

# Set project if not already set by Qwiklabs environment
if [[ -z "${GOOGLE_CLOUD_PROJECT:-}" ]]; then
  gcloud config set project "${PROJECT_ID}"
fi

echo "TASK 1: Configure a health check firewall rule"
gcloud compute firewall-rules create "${FW_HEALTH_CHECK_NAME}" \
    --project="${PROJECT_ID}" \
    --network="${NETWORK}" \
    --action=ALLOW \
    --direction=INGRESS \
    --rules=tcp:80 \
    --source-ranges="${HEALTH_CHECK_SOURCE_RANGES}" \
    --target-tags="${HEALTH_CHECK_TAG}" \
    --quiet || echo "Firewall rule ${FW_HEALTH_CHECK_NAME} might already exist or failed to create."
echo "Firewall rule ${FW_HEALTH_CHECK_NAME} configuration attempted."
echo "--------------------------------------------------"

echo "TASK 2: Create a NAT configuration using Cloud Router"
echo "Creating Cloud Router ${NAT_ROUTER_NAME} in ${NAT_REGION_1}..."
gcloud compute routers create "${NAT_ROUTER_NAME}" \
    --project="${PROJECT_ID}" \
    --network="${NETWORK}" \
    --region="${NAT_REGION_1}" \
    --quiet || echo "Router ${NAT_ROUTER_NAME} might already exist or failed to create."

echo "Creating NAT Gateway ${NAT_GW_NAME} on ${NAT_ROUTER_NAME} in ${NAT_REGION_1}..."
gcloud compute routers nats create "${NAT_GW_NAME}" \
    --project="${PROJECT_ID}" \
    --router="${NAT_ROUTER_NAME}" \
    --region="${NAT_REGION_1}" \
    --nat-all-subnet-ip-ranges \
    --auto-allocate-nat-external-ips \
    --quiet || echo "NAT Gateway ${NAT_GW_NAME} might already exist or failed to create."
echo "NAT Gateway ${NAT_GW_NAME} configuration attempted. Waiting for it to become RUNNING..."

NAT_STATUS=""
TIMEOUT_SECONDS=120 # 2 minutes
ELAPSED_SECONDS=0
while [ "$NAT_STATUS" != "RUNNING" ] && [ "$ELAPSED_SECONDS" -lt "$TIMEOUT_SECONDS" ]; do
    echo "Waiting for NAT Gateway ${NAT_GW_NAME} to be RUNNING... (${ELAPSED_SECONDS}s / ${TIMEOUT_SECONDS}s)"
    NAT_STATUS=$(gcloud compute routers nats describe "${NAT_GW_NAME}" --router="${NAT_ROUTER_NAME}" --region="${NAT_REGION_1}" --project "${PROJECT_ID}" --format='value(status)' 2>/dev/null || echo "PENDING")
    sleep 10
    ELAPSED_SECONDS=$((ELAPSED_SECONDS + 10))
done

if [ "$NAT_STATUS" == "RUNNING" ]; then
    echo "NAT Gateway ${NAT_GW_NAME} is RUNNING."
else
    echo "NAT Gateway ${NAT_GW_NAME} did not reach RUNNING state within timeout. Current status: ${NAT_STATUS}. Proceeding, but issues may occur."
fi
echo "--------------------------------------------------"

echo "TASK 3: Create a custom image for a web server"
echo "Creating VM instance ${WEBSERVER_VM_NAME} in ${WEBSERVER_ZONE_1}..."
# Check if zone is valid, very basic check
if ! gcloud compute zones list --filter="name=${WEBSERVER_ZONE_1}" --format="value(name)" | grep -q "${WEBSERVER_ZONE_1}"; then
    echo "Error: Zone ${WEBSERVER_ZONE_1} does not seem valid for region ${NAT_REGION_1}. Please check and restart."
    echo "You can list zones with: gcloud compute zones list --filter=\"region~${NAT_REGION_1}\""
    exit 1
fi

gcloud compute instances create "${WEBSERVER_VM_NAME}" \
    --project="${PROJECT_ID}" \
    --zone="${WEBSERVER_ZONE_1}" \
    --machine-type="${WEBSERVER_MACHINE_TYPE}" \
    --network-interface=network="${NETWORK}",no-address \
    --maintenance-policy=MIGRATE \
    --scopes=https://www.googleapis.com/auth/devstorage.read_only,https://www.googleapis.com/auth/logging.write,https://www.googleapis.com/auth/monitoring.write,https://www.googleapis.com/auth/servicecontrol,https://www.googleapis.com/auth/service.management.readonly,https://www.googleapis.com/auth/trace.append \
    --tags="${HEALTH_CHECK_TAG}" \
    --create-disk=auto-delete=no,boot=yes,device-name="${WEBSERVER_VM_NAME}",image=projects/debian-cloud/global/images/debian-11-bullseye-v20231115,mode=rw,size=10,type=projects/"${PROJECT_ID}"/zones/"${WEBSERVER_ZONE_1}"/diskTypes/pd-standard \
    --no-shielded-secure-boot \
    --shielded-vtpm \
    --shielded-integrity-monitoring \
    --labels=goog-ec-src=vm_add-gcloud \
    --reservation-affinity=any \
    --quiet || echo "VM ${WEBSERVER_VM_NAME} might already exist or failed to create."

echo "Waiting for ${WEBSERVER_VM_NAME} to be ready for SSH (approx 30-60s)..."
sleep 60 # Increased wait time

echo "Installing Apache on ${WEBSERVER_VM_NAME}..."
gcloud compute ssh "${WEBSERVER_VM_NAME}" --zone "${WEBSERVER_ZONE_1}" --project "${PROJECT_ID}" --command="
    sudo apt-get update -y
    sudo apt-get install -y apache2
    sudo systemctl start apache2
    sudo systemctl enable apache2
    echo '<!doctype html><html><body><h1>Hello from $(hostname) in ${WEBSERVER_ZONE_1}</h1></body></html>' | sudo tee /var/www/html/index.html
" --quiet || echo "SSH or Apache setup on ${WEBSERVER_VM_NAME} failed."
echo "Apache installed and enabled."

echo "Resetting ${WEBSERVER_VM_NAME} to test service auto-start..."
gcloud compute instances reset "${WEBSERVER_VM_NAME}" --zone "${WEBSERVER_ZONE_1}" --project "${PROJECT_ID}" --quiet
echo "Waiting for ${WEBSERVER_VM_NAME} to restart (approx 45-75s)..."
sleep 75 # Increased wait time

echo "Checking Apache status on ${WEBSERVER_VM_NAME} after reset..."
gcloud compute ssh "${WEBSERVER_VM_NAME}" --zone "${WEBSERVER_ZONE_1}" --project "${PROJECT_ID}" --command="sudo systemctl is-active apache2" --quiet || echo "Apache status check failed after reset."

echo "Deleting VM ${WEBSERVER_VM_NAME} (keeping boot disk)..."
gcloud compute instances delete "${WEBSERVER_VM_NAME}" --zone "${WEBSERVER_ZONE_1}" --project "${PROJECT_ID}" --keep-disks=boot --quiet

echo "Creating custom image ${CUSTOM_IMAGE_NAME} from disk ${WEBSERVER_VM_NAME}..."
gcloud compute images create "${CUSTOM_IMAGE_NAME}" \
    --project="${PROJECT_ID}" \
    --source-disk="${WEBSERVER_VM_NAME}" \
    --source-disk-zone="${WEBSERVER_ZONE_1}" \
    --family=webserver-family \
    --quiet || echo "Custom image ${CUSTOM_IMAGE_NAME} might already exist or failed to create."
echo "Custom image ${CUSTOM_IMAGE_NAME} creation attempted."
# Optional: Delete the source disk now
# gcloud compute disks delete "${WEBSERVER_VM_NAME}" --zone "${WEBSERVER_ZONE_1}" --project "${PROJECT_ID}" --quiet
echo "--------------------------------------------------"

echo "TASK 4: Configure an instance template and create instance groups"
echo "Creating instance template ${INSTANCE_TEMPLATE_NAME}..."
gcloud compute instance-templates create "${INSTANCE_TEMPLATE_NAME}" \
    --project="${PROJECT_ID}" \
    --machine-type="${WEBSERVER_MACHINE_TYPE}" \
    --network-interface=network="${NETWORK}",no-address \
    --maintenance-policy=MIGRATE \
    --scopes=https://www.googleapis.com/auth/devstorage.read_only,https://www.googleapis.com/auth/logging.write,https://www.googleapis.com/auth/monitoring.write,https://www.googleapis.com/auth/servicecontrol,https://www.googleapis.com/auth/service.management.readonly,https://www.googleapis.com/auth/trace.append \
    --tags="${HEALTH_CHECK_TAG}" \
    --image="projects/${PROJECT_ID}/global/images/${CUSTOM_IMAGE_NAME}" \
    --boot-disk-size=10GB \
    --boot-disk-type=pd-standard \
    --boot-disk-device-name="${INSTANCE_TEMPLATE_NAME}" \
    --no-shielded-secure-boot \
    --shielded-vtpm \
    --shielded-integrity-monitoring \
    --labels=goog-ec-src=vm_add-gcloud \
    --description="Instance template for web servers" \
    --quiet || echo "Instance template ${INSTANCE_TEMPLATE_NAME} might already exist or failed to create."
echo "Instance template ${INSTANCE_TEMPLATE_NAME} creation attempted."

echo "Creating TCP health check ${MIG_HEALTH_CHECK_NAME}..."
gcloud compute health-checks create tcp "${MIG_HEALTH_CHECK_NAME}" \
    --project="${PROJECT_ID}" \
    --port=80 \
    --global \
    --quiet || echo "Health check ${MIG_HEALTH_CHECK_NAME} might already exist or failed to create." # Add global for consistency
echo "Health check ${MIG_HEALTH_CHECK_NAME} creation attempted."

echo "Creating Managed Instance Group ${MIG_US_NAME} in ${MIG_US_REGION}..."
gcloud compute instance-groups managed create "${MIG_US_NAME}" \
    --project="${PROJECT_ID}" \
    --base-instance-name="${MIG_US_NAME}" \
    --template="${INSTANCE_TEMPLATE_NAME}" \
    --size=1 \
    --region="${MIG_US_REGION}" \
    --health-check="${MIG_HEALTH_CHECK_NAME}" \
    --initial-delay=60 \
    --quiet || echo "MIG ${MIG_US_NAME} might already exist or failed to create."

echo "Configuring autoscaling for ${MIG_US_NAME}..."
gcloud compute instance-groups managed set-autoscaling "${MIG_US_NAME}" \
    --project="${PROJECT_ID}" \
    --region="${MIG_US_REGION}" \
    --max-num-replicas=2 \
    --min-num-replicas=1 \
    --target-load-balancing-utilization=0.80 \
    --cool-down-period=60 \
    --quiet || echo "Autoscaling for ${MIG_US_NAME} failed to configure."
echo "Autoscaling for ${MIG_US_NAME} configuration attempted."

echo "Creating Managed Instance Group ${MIG_NOTUS_NAME} in ${MIG_NOTUS_REGION}..."
gcloud compute instance-groups managed create "${MIG_NOTUS_NAME}" \
    --project="${PROJECT_ID}" \
    --base-instance-name="${MIG_NOTUS_NAME}" \
    --template="${INSTANCE_TEMPLATE_NAME}" \
    --size=1 \
    --region="${MIG_NOTUS_REGION}" \
    --health-check="${MIG_HEALTH_CHECK_NAME}" \
    --initial-delay=60 \
    --quiet || echo "MIG ${MIG_NOTUS_NAME} might already exist or failed to create."

echo "Configuring autoscaling for ${MIG_NOTUS_NAME}..."
gcloud compute instance-groups managed set-autoscaling "${MIG_NOTUS_NAME}" \
    --project="${PROJECT_ID}" \
    --region="${MIG_NOTUS_REGION}" \
    --max-num-replicas=2 \
    --min-num-replicas=1 \
    --target-load-balancing-utilization=0.80 \
    --cool-down-period=60 \
    --quiet || echo "Autoscaling for ${MIG_NOTUS_NAME} failed to configure."
echo "Autoscaling for ${MIG_NOTUS_NAME} configuration attempted."
echo "Waiting for MIGs to stabilize (approx 2-3 minutes)..."
sleep 180
echo "--------------------------------------------------"

echo "TASK 5: Configure the Application Load Balancer (HTTP)"
echo "Creating backend service ${BACKEND_SERVICE_NAME}..."
gcloud compute backend-services create "${BACKEND_SERVICE_NAME}" \
    --project="${PROJECT_ID}" \
    --protocol=HTTP \
    --health-checks="${MIG_HEALTH_CHECK_NAME}" \
    --health-checks-global \
    --enable-logging \
    --logging-sample-rate=1 \
    --global \
    --quiet || echo "Backend service ${BACKEND_SERVICE_NAME} might already exist or failed to create."
echo "Backend service ${BACKEND_SERVICE_NAME} creation attempted."

echo "Adding ${MIG_US_NAME} backend to ${BACKEND_SERVICE_NAME}..."
gcloud compute backend-services add-backend "${BACKEND_SERVICE_NAME}" \
    --project="${PROJECT_ID}" \
    --instance-group="${MIG_US_NAME}" \
    --instance-group-region="${MIG_US_REGION}" \
    --balancing-mode=RATE \
    --max-rate-per-instance=50 \
    --capacity-scaler=1 \
    --global \
    --quiet || echo "Failed to add backend ${MIG_US_NAME}."

echo "Adding ${MIG_NOTUS_NAME} backend to ${BACKEND_SERVICE_NAME}..."
gcloud compute backend-services add-backend "${BACKEND_SERVICE_NAME}" \
    --project="${PROJECT_ID}" \
    --instance-group="${MIG_NOTUS_NAME}" \
    --instance-group-region="${MIG_NOTUS_REGION}" \
    --balancing-mode=UTILIZATION \
    --max-utilization=0.8 \
    --capacity-scaler=1 \
    --global \
    --quiet || echo "Failed to add backend ${MIG_NOTUS_NAME}."
echo "Backends configuration attempted for ${BACKEND_SERVICE_NAME}."

echo "Creating URL map ${LB_NAME}-map..."
gcloud compute url-maps create "${LB_NAME}-map" \
    --project="${PROJECT_ID}" \
    --default-service "${BACKEND_SERVICE_NAME}" \
    --quiet || echo "URL map ${LB_NAME}-map might already exist or failed to create."

echo "Creating target HTTP proxy ${LB_NAME}-proxy..."
gcloud compute target-http-proxies create "${LB_NAME}-proxy" \
    --project="${PROJECT_ID}" \
    --url-map="${LB_NAME}-map" \
    --quiet || echo "Target proxy ${LB_NAME}-proxy might already exist or failed to create."

echo "Creating Global Forwarding Rule (IPv4) ${LB_NAME}-fw-ipv4..."
gcloud compute forwarding-rules create "${LB_NAME}-fw-ipv4" \
    --project="${PROJECT_ID}" \
    --ip-version=IPV4 \
    --target-http-proxy="${LB_NAME}-proxy" \
    --ports=80 \
    --global \
    --quiet || echo "Forwarding rule ${LB_NAME}-fw-ipv4 might already exist or failed to create."

echo "Creating Global Forwarding Rule (IPv6) ${LB_NAME}-fw-ipv6..."
gcloud compute forwarding-rules create "${LB_NAME}-fw-ipv6" \
    --project="${PROJECT_ID}" \
    --ip-version=IPV6 \
    --target-http-proxy="${LB_NAME}-proxy" \
    --ports=80 \
    --global \
    --quiet || echo "Forwarding rule ${LB_NAME}-fw-ipv6 might already exist or failed to create."


echo "Application Load Balancer ${LB_NAME} configuration attempted. It may take several minutes to become fully active."
echo "--------------------------------------------------"
echo "TASK 6: Stress test the Application Load Balancer (HTTP)"
echo "Fetching Load Balancer IPv4 address..."
export LB_IP_v4=""
TIMEOUT_SECONDS_LB_IP=300
ELAPSED_SECONDS_LB_IP=0
while [ -z "$LB_IP_v4" ] && [ "$ELAPSED_SECONDS_LB_IP" -lt "$TIMEOUT_SECONDS_LB_IP" ]; do
    echo "Waiting for Load Balancer IPv4 address... (${ELAPSED_SECONDS_LB_IP}s / ${TIMEOUT_SECONDS_LB_IP}s)"
    LB_IP_v4=$(gcloud compute forwarding-rules describe "${LB_NAME}-fw-ipv4" --global --project "${PROJECT_ID}" --format="value(IPAddress)" 2>/dev/null || echo "")
    sleep 10
    ELAPSED_SECONDS_LB_IP=$((ELAPSED_SECONDS_LB_IP + 10))
done

if [ -z "$LB_IP_v4" ]; then
    echo "Failed to retrieve Load Balancer IPv4 address after ${TIMEOUT_SECONDS_LB_IP} seconds. Exiting stress test part."
    echo "Lab script steps mostly completed. Please check LB configuration manually."
    exit 1
fi
echo "Load Balancer IPv4: ${LB_IP_v4}"

echo "Waiting for Load Balancer to respond (this might take a few minutes)..."
RESULT=""
TIMEOUT_SECONDS_LB_RESP=600 # 10 minutes for LB to fully provision and respond
ELAPSED_SECONDS_LB_RESP=0
while [ -z "$RESULT" ] && [ "$ELAPSED_SECONDS_LB_RESP" -lt "$TIMEOUT_SECONDS_LB_RESP" ] ; do
    echo "Checking Load Balancer at http://${LB_IP_v4}... (${ELAPSED_SECONDS_LB_RESP}s / ${TIMEOUT_SECONDS_LB_RESP}s)"
    RESULT=$(curl --connect-timeout 5 -m 10 -s "http://${LB_IP_v4}" | grep -E "Hello from|Apache") # Check for known content
    sleep 15 # Increased sleep as LB provisioning can take time
    ELAPSED_SECONDS_LB_RESP=$((ELAPSED_SECONDS_LB_RESP + 15))
done

if [ -z "$RESULT" ]; then
    echo "Load Balancer did not respond as expected after ${TIMEOUT_SECONDS_LB_RESP} seconds. Exiting stress test part."
    echo "Access the load balancer manually at: http://${LB_IP_v4}"
    echo "Lab script steps mostly completed. Please check LB configuration manually."
    exit 1
fi
echo "Load Balancer is responding!"
echo "Access the load balancer at: http://${LB_IP_v4}"

echo "Creating stress test VM ${STRESS_TEST_VM_NAME} in ${STRESS_TEST_ZONE}..."
# Check if stress test zone is valid
if ! gcloud compute zones list --filter="name=${STRESS_TEST_ZONE}" --format="value(name)" | grep -q "${STRESS_TEST_ZONE}"; then
    echo "Error: Stress Test Zone ${STRESS_TEST_ZONE} does not seem valid for region ${STRESS_TEST_REGION}. Please check and restart."
    echo "You can list zones with: gcloud compute zones list --filter=\"region~${STRESS_TEST_REGION}\""
    exit 1
fi

gcloud compute instances create "${STRESS_TEST_VM_NAME}" \
    --project="${PROJECT_ID}" \
    --zone="${STRESS_TEST_ZONE}" \
    --machine-type="${STRESS_TEST_MACHINE_TYPE}" \
    --network-interface=network="${NETWORK}" \
    --maintenance-policy=MIGRATE \
    --scopes=https://www.googleapis.com/auth/devstorage.read_only,https://www.googleapis.com/auth/logging.write,https://www.googleapis.com/auth/monitoring.write,https://www.googleapis.com/auth/servicecontrol,https://www.googleapis.com/auth/service.management.readonly,https://www.googleapis.com/auth/trace.append \
    --image="projects/${PROJECT_ID}/global/images/${CUSTOM_IMAGE_NAME}" \
    --boot-disk-size=10GB \
    --boot-disk-type=pd-standard \
    --boot-disk-device-name="${STRESS_TEST_VM_NAME}" \
    --no-shielded-secure-boot \
    --shielded-vtpm \
    --shielded-integrity-monitoring \
    --labels=goog-ec-src=vm_add-gcloud \
    --reservation-affinity=any \
    --quiet || echo "Stress test VM ${STRESS_TEST_VM_NAME} might already exist or failed to create."
echo "Stress test VM ${STRESS_TEST_VM_NAME} creation attempted."
echo "Waiting for ${STRESS_TEST_VM_NAME} to be ready for SSH (approx 30-60s)..."
sleep 60 # Increased wait

echo "Starting stress test from ${STRESS_TEST_VM_NAME} to http://${LB_IP_v4}/ ..."
echo "This will run for a while. You can monitor the load balancer and instance groups in the console."
gcloud compute ssh "${STRESS_TEST_VM_NAME}" --zone "${STRESS_TEST_ZONE}" --project "${PROJECT_ID}" --command="
    sudo apt-get update -y
    sudo apt-get install -y apache2-utils
    echo 'Stressing http://${LB_IP_v4}/'
    ab -n 500000 -c 1000 http://${LB_IP_v4}/
" --quiet & # Run ab in the background

echo "Stress test initiated. Monitor Load Balancing and Instance Groups in the Cloud Console."
echo "--------------------------------------------------"

echo "Lab script steps completed."
echo "Remember to monitor the LB Monitoring page and Instance Group Monitoring pages in the console."
echo "Access the load balancer at: http://${LB_IP_v4}"
echo "--------------------------------------------------"

