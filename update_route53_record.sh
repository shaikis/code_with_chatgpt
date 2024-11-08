#!/bin/bash

# Install AWS CLI if not already installed
if ! command -v aws &> /dev/null
then
    echo "Installing AWS CLI..."
    yum update -y
    yum install -y aws-cli
fi

# Variables
HOSTED_ZONE_ID="Z3EXAMPLE1234"  # Replace with your Route 53 Hosted Zone ID
RECORD_TYPE="A"
TTL=300

# Retrieve the public IP of the instance
INSTANCE_IP=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4)

# Retrieve the instance's hostname to use as the DNS record name
RECORD_NAME=$(curl -s http://169.254.169.254/latest/meta-data/hostname)

# Validate that both the hostname and public IP were retrieved
if [ -z "$INSTANCE_IP" ] || [ -z "$RECORD_NAME" ]; then
    echo "Failed to retrieve instance IP or hostname."
    exit 1
fi

# Check if a Route 53 record with the hostname and IP already exists
EXISTING_IP=$(aws route53 list-resource-record-sets     --hosted-zone-id $HOSTED_ZONE_ID     --query "ResourceRecordSets[?Name == '${RECORD_NAME}.'].ResourceRecords[0].Value"     --output text)

# Check if any other record has the same IP assigned in the hosted zone
OTHER_RECORD_NAME=$(aws route53 list-resource-record-sets     --hosted-zone-id $HOSTED_ZONE_ID     --query "ResourceRecordSets[?ResourceRecords[?Value == '${INSTANCE_IP}'] && Name != '${RECORD_NAME}.'].Name"     --output text)

# If an exact match is found with this name and IP, no update is needed
if [ "$EXISTING_IP" == "$INSTANCE_IP" ]; then
    echo "Route 53 record for $RECORD_NAME already exists with IP $INSTANCE_IP. No update needed."
    exit 0
fi

# If another record uses the same IP, update it to use the current hostname
if [ -n "$OTHER_RECORD_NAME" ]; then
    echo "Found another record ($OTHER_RECORD_NAME) using IP $INSTANCE_IP. Updating to $RECORD_NAME."

    # Define Route 53 JSON payload to delete the old record and create the new one
    CHANGE_BATCH=$(cat <<EOF
{
  "Comment": "Update record name due to IP conflict",
  "Changes": [
    {
      "Action": "DELETE",
      "ResourceRecordSet": {
        "Name": "$OTHER_RECORD_NAME",
        "Type": "$RECORD_TYPE",
        "TTL": $TTL,
        "ResourceRecords": [
          {
            "Value": "$INSTANCE_IP"
          }
        ]
      }
    },
    {
      "Action": "CREATE",
      "ResourceRecordSet": {
        "Name": "$RECORD_NAME",
        "Type": "$RECORD_TYPE",
        "TTL": $TTL,
        "ResourceRecords": [
          {
            "Value": "$INSTANCE_IP"
          }
        ]
      }
    }
  ]
}
EOF
    )

    # Apply the DNS record update
    aws route53 change-resource-record-sets --hosted-zone-id $HOSTED_ZONE_ID --change-batch "$CHANGE_BATCH"

    # Check if the record was successfully updated
    if [ $? -eq 0 ]; then
        echo "Route 53 record for $OTHER_RECORD_NAME successfully updated to $RECORD_NAME with IP $INSTANCE_IP."
    else
        echo "Failed to update Route 53 record."
    fi

    exit 0
fi

# If no other record has the IP, create a new one
echo "Creating new Route 53 record for $RECORD_NAME with IP $INSTANCE_IP..."

# Define Route 53 JSON payload for creating the DNS record
CHANGE_BATCH=$(cat <<EOF
{
  "Comment": "Auto-updated by EC2 instance on startup",
  "Changes": [
    {
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "$RECORD_NAME",
        "Type": "$RECORD_TYPE",
        "TTL": $TTL,
        "ResourceRecords": [
          {
            "Value": "$INSTANCE_IP"
          }
        ]
      }
    }
  ]
}
EOF
)

# Apply the DNS record creation
aws route53 change-resource-record-sets --hosted-zone-id $HOSTED_ZONE_ID --change-batch "$CHANGE_BATCH"

# Check if the record was successfully created
if [ $? -eq 0 ]; then
    echo "Route 53 record for $RECORD_NAME successfully created with IP $INSTANCE_IP."
else
    echo "Failed to create Route 53 record."
fi
