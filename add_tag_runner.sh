#!/bin/bash

# AWS EC2 Tag Management Script
# Usage: ./add_ec2_tags.sh <profile_name> <instance_id> <ssh_key_path>

# Check if required parameters are provided
if [ $# -ne 2 ]; then
    echo "Error: Missing required parameters"
    echo "Usage: $0 <profile_name> <instance_id>"
    echo "Example: $0 my-aws-profile i-1234567890abcdef0"
    exit 1
fi

# Input parameters
PROFILE_NAME=$1
INSTANCE_ID=$2
SSH_KEY_PATH="/home/daniel/.ssh/itop.pem"
SSH_USER="ubuntu"

# Verify SSH key exists
if [ ! -f "$SSH_KEY_PATH" ]; then
    echo "Error: SSH key file not found: $SSH_KEY_PATH"
    exit 1
fi

# Define tags as variables (add or modify as needed)
TAG1_KEY="ansible-runner"
TAG1_VALUE="yes"

TAG2_KEY="cno-patch-weekly"
TAG2_VALUE="sun"

TAG3_KEY="ansible-managed"
TAG3_VALUE="yes"

TAG4_KEY="BackupSchema"
TAG4_VALUE="local-nonprod"

# Optional: Add more tags here
# TAG5_KEY="Backup"
# TAG5_VALUE="Daily"

echo "======================================"
echo "AWS EC2 Tag Management Script"
echo "======================================"
echo "Profile: $PROFILE_NAME"
echo "Instance ID: $INSTANCE_ID"
echo "SSH Key: $SSH_KEY_PATH"
echo "======================================"

# Verify AWS CLI is installed
if ! command -v aws &> /dev/null; then
    echo "Error: AWS CLI is not installed"
    exit 1
fi

# Verify the instance exists and get details
echo "Verifying instance exists..."
INSTANCE_INFO=$(aws ec2 describe-instances \
    --profile "$PROFILE_NAME" \
    --instance-ids "$INSTANCE_ID" \
    --output json 2>/dev/null)

if [ $? -ne 0 ]; then
    echo "Error: Instance $INSTANCE_ID not found or access denied"
    exit 1
fi

echo "Instance verified successfully"

# Get the Name tag value
NAME_TAG=$(echo "$INSTANCE_INFO" | jq -r '.Reservations[0].Instances[0].Tags[] | select(.Key=="Name") | .Value')

if [ -z "$NAME_TAG" ] || [ "$NAME_TAG" == "null" ]; then
    echo "Warning: No Name tag found on instance"
    NAME_TAG=""
else
    echo "Found Name tag: $NAME_TAG"
fi

# Get instance IP address
INSTANCE_IP=$(echo "$INSTANCE_INFO" | jq -r '.Reservations[0].Instances[0].PublicIpAddress')

if [ -z "$INSTANCE_IP" ] || [ "$INSTANCE_IP" == "null" ]; then
    # Try private IP if no public IP
    INSTANCE_IP=$(echo "$INSTANCE_INFO" | jq -r '.Reservations[0].Instances[0].PrivateIpAddress')
fi

if [ -z "$INSTANCE_IP" ] || [ "$INSTANCE_IP" == "null" ]; then
    echo "Error: Could not determine instance IP address"
    exit 1
fi

echo "Instance IP: $INSTANCE_IP"
echo "======================================"

# Add tags to the instance
echo "Adding tags to instance $INSTANCE_ID..."

aws ec2 create-tags \
    --profile "$PROFILE_NAME" \
    --resources "$INSTANCE_ID" \
    --tags \
        Key="$TAG1_KEY",Value="$TAG1_VALUE" \
        Key="$TAG2_KEY",Value="$TAG2_VALUE" \
        Key="$TAG3_KEY",Value="$TAG3_VALUE" \
        Key="$TAG4_KEY",Value="$TAG4_VALUE"

# Optional: Add more tags by extending the command above
# Key="$TAG5_KEY",Value="$TAG5_VALUE"

if [ $? -eq 0 ]; then
    echo "======================================"
    echo "Tags added successfully!"
    echo "======================================"
    echo "Added tags:"
    echo "  - $TAG1_KEY: $TAG1_VALUE"
    echo "  - $TAG2_KEY: $TAG2_VALUE"
    echo "  - $TAG3_KEY: $TAG3_VALUE"
    echo "  - $TAG4_KEY: $TAG4_VALUE"
    echo "======================================"
    
    # Display current tags on the instance
    echo "Current tags on instance:"
    aws ec2 describe-tags \
        --profile "$PROFILE_NAME" \
        --filters "Name=resource-id,Values=$INSTANCE_ID" \
        --output table
else
    echo "Error: Failed to add tags"
    exit 1
fi

# Enable termination protection
echo "======================================"
echo "Enabling termination protection..."

aws ec2 modify-instance-attribute \
    --profile "$PROFILE_NAME" \
    --instance-id "$INSTANCE_ID" \
    --disable-api-termination

if [ $? -eq 0 ]; then
    echo "Termination protection enabled successfully!"
    echo "======================================"
    
    # Verify termination protection status
    echo "Verifying termination protection status:"
    aws ec2 describe-instance-attribute \
        --profile "$PROFILE_NAME" \
        --instance-id "$INSTANCE_ID" \
        --attribute disableApiTermination \
        --output table
else
    echo "Error: Failed to enable termination protection"
    exit 1
fi

# Update hostname on the instance if Name tag exists
if [ -n "$NAME_TAG" ]; then
    echo "======================================"
    echo "Updating hostname to: $NAME_TAG"
    echo "======================================"
    
    # Test SSH connectivity first
    echo "Testing SSH connectivity..."
    if ! ssh -i "$SSH_KEY_PATH" \
            -o StrictHostKeyChecking=no \
            -o ConnectTimeout=10 \
            -o BatchMode=yes \
            "${SSH_USER}@${INSTANCE_IP}" \
            "echo 'SSH connection successful'" 2>/dev/null; then
        echo "Warning: Could not connect via SSH to update hostname"
        echo "Please verify:"
        echo "  - Security group allows SSH access"
        echo "  - SSH key is correct"
        echo "  - Instance is running"
    else
        # Update hostname
        echo "Updating /etc/hostname..."
        ssh -i "$SSH_KEY_PATH" \
            -o StrictHostKeyChecking=no \
            "${SSH_USER}@${INSTANCE_IP}" \
            "sudo bash -c 'echo \"$NAME_TAG\" > /etc/hostname && sudo hostnamectl set-hostname \"$NAME_TAG\"'"
        
        if [ $? -eq 0 ]; then
            echo "Hostname updated successfully!"
            
            # Verify the change
            echo "Verifying hostname change..."
            CURRENT_HOSTNAME=$(ssh -i "$SSH_KEY_PATH" \
                -o StrictHostKeyChecking=no \
                "${SSH_USER}@${INSTANCE_IP}" \
                "hostname" 2>/dev/null)
            
            echo "Current hostname on instance: $CURRENT_HOSTNAME"
        else
            echo "Error: Failed to update hostname"
        fi
    fi
else
    echo "======================================"
    echo "Skipping hostname update (no Name tag)"
    echo "======================================"
fi

echo "======================================"
echo "Script completed successfully!"
echo "======================================"
