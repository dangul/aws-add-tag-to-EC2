#!/bin/bash

# AWS EC2 Tag Management Script
# Usage: ./add_ec2_tags.sh <profile_name> <instance_id> <iam_role_name>

# Check if required parameters are provided
if [ $# -ne 3 ]; then
    echo ""
    echo "Error: Missing required parameters"
    echo "Usage: $0 <profile_name> <iam_role_name> <instance_id>"
    echo ""
    echo "Example: $0 network RunnerRole i-1234567890abcdef0"
    echo ""
    exit 1
fi

# Input parameters
PROFILE_NAME=$1
IAM_ROLE_NAME=$2
INSTANCE_ID=$3
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
echo "IAM Role: $IAM_ROLE_NAME"
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

# Verify IAM role exists
echo "Verifying IAM role exists..."
ROLE_CHECK=$(aws iam get-role \
    --profile "$PROFILE_NAME" \
    --role-name "$IAM_ROLE_NAME" \
    --output json 2>/dev/null)

if [ $? -ne 0 ]; then
    echo "Error: IAM role '$IAM_ROLE_NAME' not found or access denied"
    exit 1
fi

echo "IAM role verified successfully"
echo "======================================"

# Check if instance profile exists, if not create it
echo "Checking for instance profile..."
INSTANCE_PROFILE_CHECK=$(aws iam get-instance-profile \
    --profile "$PROFILE_NAME" \
    --instance-profile-name "$IAM_ROLE_NAME" 2>/dev/null)

if [ $? -ne 0 ]; then
    echo "Instance profile not found. Creating instance profile..."
    aws iam create-instance-profile \
        --profile "$PROFILE_NAME" \
        --instance-profile-name "$IAM_ROLE_NAME"
    
    if [ $? -eq 0 ]; then
        echo "Instance profile created successfully"
        
        # Add role to instance profile
        echo "Adding role to instance profile..."
        aws iam add-role-to-instance-profile \
            --profile "$PROFILE_NAME" \
            --instance-profile-name "$IAM_ROLE_NAME" \
            --role-name "$IAM_ROLE_NAME"
        
        if [ $? -eq 0 ]; then
            echo "Role added to instance profile successfully"
            # Wait a moment for AWS to propagate the changes
            echo "Waiting for AWS to propagate changes..."
            sleep 5
        else
            echo "Error: Failed to add role to instance profile"
            exit 1
        fi
    else
        echo "Error: Failed to create instance profile"
        exit 1
    fi
else
    echo "Instance profile already exists"
fi

echo "======================================"

# Attach IAM role to EC2 instance
echo "Attaching IAM role to EC2 instance..."

# Check if instance already has an IAM role
CURRENT_PROFILE=$(echo "$INSTANCE_INFO" | jq -r '.Reservations[0].Instances[0].IamInstanceProfile.Arn // empty')

if [ -n "$CURRENT_PROFILE" ]; then
    echo "Warning: Instance already has an IAM instance profile attached"
    echo "Current profile: $CURRENT_PROFILE"
    read -p "Do you want to replace it? (yes/no): " REPLACE_PROFILE
    
    if [ "$REPLACE_PROFILE" != "yes" ]; then
        echo "Skipping IAM role attachment"
    else
        # First, disassociate the current profile
        echo "Disassociating current IAM instance profile..."
        ASSOCIATION_ID=$(aws ec2 describe-iam-instance-profile-associations \
            --profile "$PROFILE_NAME" \
            --filters "Name=instance-id,Values=$INSTANCE_ID" \
            --query 'IamInstanceProfileAssociations[0].AssociationId' \
            --output text)
        
        if [ -n "$ASSOCIATION_ID" ] && [ "$ASSOCIATION_ID" != "None" ]; then
            aws ec2 disassociate-iam-instance-profile \
                --profile "$PROFILE_NAME" \
                --association-id "$ASSOCIATION_ID"
            
            if [ $? -eq 0 ]; then
                echo "Current profile disassociated successfully"
                sleep 3
            else
                echo "Error: Failed to disassociate current profile"
                exit 1
            fi
        fi
        
        # Attach new profile
        echo "Attaching new IAM instance profile..."
        aws ec2 associate-iam-instance-profile \
            --profile "$PROFILE_NAME" \
            --instance-id "$INSTANCE_ID" \
            --iam-instance-profile Name="$IAM_ROLE_NAME"
        
        if [ $? -eq 0 ]; then
            echo "IAM role attached successfully!"
        else
            echo "Error: Failed to attach IAM role"
            exit 1
        fi
    fi
else
    # No current profile, directly attach
    aws ec2 associate-iam-instance-profile \
        --profile "$PROFILE_NAME" \
        --instance-id "$INSTANCE_ID" \
        --iam-instance-profile Name="$IAM_ROLE_NAME"
    
    if [ $? -eq 0 ]; then
        echo "IAM role attached successfully!"
    else
        echo "Error: Failed to attach IAM role"
        exit 1
    fi
fi

echo "======================================"

# Verify IAM role attachment
echo "Verifying IAM role attachment..."
ATTACHED_PROFILE=$(aws ec2 describe-instances \
    --profile "$PROFILE_NAME" \
    --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].IamInstanceProfile.Arn' \
    --output text)

if [ -n "$ATTACHED_PROFILE" ] && [ "$ATTACHED_PROFILE" != "None" ]; then
    echo "Current IAM Instance Profile: $ATTACHED_PROFILE"
else
    echo "Warning: Could not verify IAM role attachment"
fi

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
HOSTNAME_UPDATED=false

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
            HOSTNAME_UPDATED=true
            
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

# Reboot instance if hostname was updated
if [ "$HOSTNAME_UPDATED" = true ]; then
    echo "======================================"
    echo "Rebooting instance to apply hostname changes..."
    echo "======================================"
    
    # Ask for confirmation before rebooting
    read -p "Do you want to reboot the instance now? (yes/no): " CONFIRM_REBOOT
    
    if [ "$CONFIRM_REBOOT" = "yes" ]; then
        echo "Initiating reboot..."
        
        # Reboot via AWS API (more reliable)
        aws ec2 reboot-instances \
            --profile "$PROFILE_NAME" \
            --instance-ids "$INSTANCE_ID"
        
        if [ $? -eq 0 ]; then
            echo "Reboot initiated successfully!"
            echo "The instance is now rebooting..."
            echo ""
            echo "Monitoring instance state..."
            
            # Wait for instance to start rebooting
            sleep 5
            
            # Monitor instance state
            REBOOT_TIMEOUT=300  # 5 minutes timeout
            ELAPSED=0
            
            while [ $ELAPSED -lt $REBOOT_TIMEOUT ]; do
                INSTANCE_STATE=$(aws ec2 describe-instances \
                    --profile "$PROFILE_NAME" \
                    --instance-ids "$INSTANCE_ID" \
                    --query 'Reservations[0].Instances[0].State.Name' \
                    --output text)
                
                echo "Current state: $INSTANCE_STATE (${ELAPSED}s elapsed)"
                
                if [ "$INSTANCE_STATE" = "running" ] && [ $ELAPSED -gt 30 ]; then
                    echo "Instance is running again!"
                    
                    # Wait a bit more for SSH to be available
                    echo "Waiting for SSH to become available..."
                    sleep 20
                    
                    # Verify hostname after reboot
                    echo "Verifying hostname after reboot..."
                    FINAL_HOSTNAME=$(ssh -i "$SSH_KEY_PATH" \
                        -o StrictHostKeyChecking=no \
                        -o ConnectTimeout=10 \
                        "${SSH_USER}@${INSTANCE_IP}" \
                        "hostname" 2>/dev/null)
                    
                    if [ -n "$FINAL_HOSTNAME" ]; then
                        echo "Hostname after reboot: $FINAL_HOSTNAME"
                        if [ "$FINAL_HOSTNAME" = "$NAME_TAG" ]; then
                            echo "✓ Hostname successfully applied!"
                        else
                            echo "⚠ Warning: Hostname mismatch (expected: $NAME_TAG, got: $FINAL_HOSTNAME)"
                        fi
                    else
                        echo "Could not verify hostname (SSH not yet available)"
                    fi
                    
                    break
                fi
                
                sleep 10
                ELAPSED=$((ELAPSED + 10))
            done
            
            if [ $ELAPSED -ge $REBOOT_TIMEOUT ]; then
                echo "Warning: Reboot monitoring timed out"
                echo "Please check instance state manually"
            fi
        else
            echo "Error: Failed to initiate reboot via AWS API"
            echo "You may need to reboot manually for hostname changes to take full effect"
        fi
    else
        echo "Reboot skipped. Note: A reboot is recommended for hostname changes to take full effect."
        echo "You can manually reboot the instance later using:"
        echo "  aws ec2 reboot-instances --profile $PROFILE_NAME --instance-ids $INSTANCE_ID"
    fi
fi

echo "======================================"
echo "Script completed successfully!"
echo "======================================"
echo "Summary:"
echo "  - IAM Role: $IAM_ROLE_NAME attached"
echo "  - Tags added: 4"
echo "  - Termination protection: Enabled"
if [ -n "$NAME_TAG" ]; then
    echo "  - Hostname: $NAME_TAG"
    if [ "$HOSTNAME_UPDATED" = true ]; then
        echo "  - Instance rebooted: $([ "$CONFIRM_REBOOT" = "yes" ] && echo "Yes" || echo "Skipped")"
    fi
fi
echo "======================================"
