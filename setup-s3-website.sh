#!/bin/bash

# S3 Static Website Infrastructure Setup Script
# Usage: ./setup-s3-website.sh
# Requires: AWS CLI configured with appropriate permissions
#    IMPORTANT NOTES:
#  The script requires permissions for S3, CloudFront, ACM, and Route 53
#  SSL certificate validation requires manual DNS record creation
#  CloudFront deployment takes 15-20 minutes
#  The certificate must be requested in us-east-1 region for CloudFront
#  You'll need to validate the SSL certificate through DNS records in the ACM console

#set -e  # Exit on any error

set -euo pipefail

ensure_static_website_bucket() {
  local bucket_name="$1"
  local region="$2"

  echo "==> Ensuring S3 static website bucket: ${bucket_name} (region: ${region})"

  # 1) Create bucket if missing
  if aws s3api head-bucket --bucket "${bucket_name}" 2>/dev/null; then
    echo "    Bucket ${bucket_name} already exists"
  else
    if [[ "${region}" == "us-east-1" ]]; then
      aws s3api create-bucket --bucket "${bucket_name}"
    else
      aws s3api create-bucket \
        --bucket "${bucket_name}" \
        --region "${region}" \
        --create-bucket-configuration LocationConstraint="${region}"
    fi
    echo "    Bucket ${bucket_name} created successfully"
  fi

  # 1.1) Allow public policies/ACLs temporarily (per your original step)
  aws s3api put-public-access-block \
    --bucket "${bucket_name}" \
    --public-access-block-configuration \
    BlockPublicAcls=false,IgnorePublicAcls=false,BlockPublicPolicy=false,RestrictPublicBuckets=false

  # 2) Website hosting
  aws s3 website "s3://${bucket_name}/" \
    --index-document index.html \
    --error-document error.html

  # 3) Bucket policy
  local policy_file
  policy_file="$(mktemp -t bucket-policy.XXXXXX.json)"
  cat > "${policy_file}" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "PublicReadGetObject",
      "Effect": "Allow",
      "Principal": "*",
      "Action": "s3:GetObject",
      "Resource": "arn:aws:s3:::${bucket_name}/*"
    }
  ]
}
EOF

  aws s3api put-bucket-policy --bucket "${bucket_name}" --policy "file://${policy_file}"
  rm -f "${policy_file}"

  # 4) Final public access block settings (allow bucket policy)
  aws s3api put-public-access-block \
    --bucket "${bucket_name}" \
    --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=false,RestrictPublicBuckets=false
}


# AWS Service Constants (as documented by AWS)
readonly AWS_CLOUDFRONT_HOSTED_ZONE_ID="Z2FDTNDATAQYW2"
#readonly AWS_S3_WEBSITE_HOSTED_ZONE_IDS=(
#    ["us-east-1"]="Z3AQBSTGFYJSTF"
#    ["us-west-2"]="Z3BJ6K6RIION7M"
#    # Add other regions as needed
#)

# Get parameters from environment variables or prompt for input
REGION=${AWS_REGION:-$(aws configure get region)}
BUCKET_NAME=${S3_BUCKET_NAME}
DOMAIN_NAME=${WEBSITE_DOMAIN_NAME}

# Validate required parameters
if [ -z "$BUCKET_NAME" ]; then
    echo "Error: S3_BUCKET_NAME environment variable is required"
    echo "Example: export S3_BUCKET_NAME=my-website-bucket"
    exit 1
fi

if [ -z "$DOMAIN_NAME" ]; then
    echo "Error: WEBSITE_DOMAIN_NAME environment variable is required"
    echo "Example: export WEBSITE_DOMAIN_NAME=example.com"
    exit 1
fi

if [ -z "$REGION" ]; then
    echo "Error: AWS_REGION not set and no default region configured"
    echo "Example: export AWS_REGION=us-east-1"
    exit 1
fi

# New variables for app - using $BUCKET_NAME.app
APP_SUBDOMAIN="app.$DOMAIN_NAME"
APP_BUCKET_NAME="$BUCKET_NAME.app"  # This will be for the PWA doing the actual app of lessonscore

echo "Setting up S3 static website infrastructure..."
echo "Region: $REGION"
echo "Bucket: $BUCKET_NAME"
echo "App Bucket: $APP_BUCKET_NAME"
echo "Domain: $DOMAIN_NAME"
echo ""


echo "Steps 1 to 4 For S3 bucket for $BUCKET_NAME: "
ensure_static_website_bucket "$BUCKET_NAME" "$REGION"

echo "Steps 1 to 4 For S3 bucket for $BUCKET_NAME: "
ensure_static_website_bucket "$APP_BUCKET_NAME" "$REGION"


# Step 5: Request SSL certificate (for HTTPS) or check if one exists already:
# Check if certificate already exists
echo "5. Checking if there is already the SSL certificate..."

EXISTING_CERT=$(aws acm list-certificates --region us-east-1 --query "CertificateSummaryList[?DomainName=='$DOMAIN_NAME'].CertificateArn" --output text)

if [ -n "$EXISTING_CERT" ]; then
    echo "Using existing certificate: $EXISTING_CERT"
    CERT_ARN=$EXISTING_CERT
else
    echo "Creating new certificate..."
    CERT_ARN=$(aws acm request-certificate \
    --domain-name "$DOMAIN_NAME" \
    --subject-alternative-names "www.$DOMAIN_NAME" "$APP_SUBDOMAIN" \
    --validation-method DNS \
    --region us-east-1 \
    --query 'CertificateArn' \
    --output text)
echo "   Certificate requested: $CERT_ARN"
echo "   Note: You need to validate the certificate via DNS records"
fi

# Step 6: Create CloudFront distribution
echo "6. Creating CloudFront distribution..."
WEBSITE_ENDPOINT="$BUCKET_NAME.s3-website-$REGION.amazonaws.com"

# Check if distribution already exists
EXISTING_DISTRIBUTION=$(aws cloudfront list-distributions \
  --query "DistributionList.Items[?Comment=='CloudFront distribution for $DOMAIN_NAME'].Id" \
  --output text)

if [ ! -z "$EXISTING_DISTRIBUTION" ]; then
  echo "Distribution already exists: $EXISTING_DISTRIBUTION"
  DISTRIBUTION_ID=$EXISTING_DISTRIBUTION
else
  # Create new distribution only if none exists

  cat > /tmp/cloudfront-config.json << EOF
{
    "CallerReference": "$(date +%s)",
    "Comment": "CloudFront distribution for $DOMAIN_NAME",
    "DefaultCacheBehavior": {
        "TargetOriginId": "S3-$BUCKET_NAME",
        "ViewerProtocolPolicy": "redirect-to-https",
        "TrustedSigners": {
            "Enabled": false,
            "Quantity": 0
        },
        "ForwardedValues": {
            "QueryString": false,
            "Cookies": {
                "Forward": "none"
            }
        },
        "MinTTL": 0,
        "Compress": true
    },
    "Origins": {
        "Quantity": 1,
        "Items": [
            {
                "Id": "S3-$BUCKET_NAME",
                "DomainName": "$WEBSITE_ENDPOINT",
                "CustomOriginConfig": {
                    "HTTPPort": 80,
                    "HTTPSPort": 443,
                    "OriginProtocolPolicy": "http-only"
                }
            }
        ]
    },
    "Enabled": true,
    "Aliases": {
        "Quantity": 2,
        "Items": ["$DOMAIN_NAME", "www.$DOMAIN_NAME"]
    },
    "DefaultRootObject": "index.html",
    "ViewerCertificate": {
        "ACMCertificateArn": "$CERT_ARN",
        "SSLSupportMethod": "sni-only",
        "MinimumProtocolVersion": "TLSv1.2_2021"
    }
}
EOF

  DISTRIBUTION_ID=$(aws cloudfront create-distribution \
    --distribution-config file:///tmp/cloudfront-config.json \
    --query 'Distribution.Id' \
    --output text)

  rm /tmp/cloudfront-config.json
  echo "   CloudFront distribution created: $DISTRIBUTION_ID"

fi


# Step 7: Get CloudFront domain name
CLOUDFRONT_DOMAIN=$(aws cloudfront get-distribution \
    --id "$DISTRIBUTION_ID" \
    --query 'Distribution.DomainName' \
    --output text)

echo "   CloudFront domain: $CLOUDFRONT_DOMAIN"

########### Now the cloudfront work for the app sub-domain:

echo "6. Creating CloudFront distribution..."
APP_WEBSITE_ENDPOINT="$BUCKET_NAME.s3-website-$REGION.amazonaws.com"

# Check if distribution already exists
APP_EXISTING_DISTRIBUTION=$(aws cloudfront list-distributions \
  --query "DistributionList.Items[?Comment=='CloudFront distribution for $APP_SUBDOMAIN'].Id" \
  --output text)

if [ ! -z "$APP_EXISTING_DISTRIBUTION" ]; then
  echo "Distribution already exists: $APP_EXISTING_DISTRIBUTION"
  APP_DISTRIBUTION_ID=$APP_EXISTING_DISTRIBUTION
else
  # Create new distribution only if none exists

# Create app distribution configuration
cat > /tmp/app-distribution-config.json << EOF
{
    "CallerReference": "$(date +%s)-app",
    "Comment": "CloudFront distribution for $APP_SUBDOMAIN",
    "Aliases": {
        "Quantity": 1,
        "Items": ["$APP_SUBDOMAIN"]
    },
    "DefaultRootObject": "index.html",
    "Origins": {
        "Quantity": 1,
        "Items": [
            {
                "Id": "$APP_BUCKET_NAME",
                "DomainName": "$APP_BUCKET_NAME.s3-website-us-east-1.amazonaws.com",
                "CustomOriginConfig": {
                    "HTTPPort": 80,
                    "HTTPSPort": 443,
                    "OriginProtocolPolicy": "http-only"
                }
            }
        ]
    },
    "DefaultCacheBehavior": {
        "TargetOriginId": "$APP_BUCKET_NAME",
        "ViewerProtocolPolicy": "redirect-to-https",
        "TrustedSigners": {
            "Enabled": false,
            "Quantity": 0
        },
        "ForwardedValues": {
            "QueryString": false,
            "Cookies": {"Forward": "none"}
        },
        "MinTTL": 0
    },
    "Comment": "CloudFront distribution for $APP_SUBDOMAIN",
    "Enabled": true,
    "ViewerCertificate": {
        "ACMCertificateArn": "$CERT_ARN",
        "SSLSupportMethod": "sni-only",
        "MinimumProtocolVersion": "TLSv1.2_2021"
    }
}
EOF

# Create the app distribution
APP_DISTRIBUTION_ID=$(aws cloudfront create-distribution \
    --distribution-config file:///tmp/app-distribution-config.json \
    --query 'Distribution.Id' \
    --output text)

echo "Created app CloudFront distribution: $APP_DISTRIBUTION_ID"
fi

# Get app CloudFront domain
APP_CLOUDFRONT_DOMAIN=$(aws cloudfront get-distribution \
    --id "$APP_DISTRIBUTION_ID" \
    --query 'Distribution.DomainName' \
    --output text)

###########end the cloudfront work for the app sub-domain


# Step 8: Create Route 53 records (if hosted zone exists)
echo "7. Setting up Route 53 DNS records..."
HOSTED_ZONE_ID=$(aws route53 list-hosted-zones-by-name \
    --dns-name "$DOMAIN_NAME" \
    --query "HostedZones[?Name=='$DOMAIN_NAME.'].Id" \
    --output text | cut -d'/' -f3)

if [ -z "$HOSTED_ZONE_ID" ]; then
    echo "No hosted zone found for $DOMAIN_NAME. Creating new hosted zone..."
    
    # Create the hosted zone
    CREATE_RESPONSE=$(aws route53 create-hosted-zone \
        --name "$DOMAIN_NAME" \
        --caller-reference "$(date +%s)-$DOMAIN_NAME" \
        --hosted-zone-config Comment="Auto-created for static website" \
        --query 'HostedZone.Id' \
        --output text | cut -d'/' -f3)
    
    # Extract the hosted zone ID from the response
    HOSTED_ZONE_ID=$CREATE_RESPONSE
    
    # Get the nameservers for the new hosted zone
    NAMESERVERS=$(aws route53 get-hosted-zone \
        --id "$HOSTED_ZONE_ID" \
        --query 'DelegationSet.NameServers' \
        --output table)
    
    echo "Created hosted zone: $HOSTED_ZONE_ID"
    echo "IMPORTANT: Update your domain registrar (ex.: Namecheap) to use these nameservers:"
    echo "$NAMESERVERS"
    echo ""
    echo "You must update the nameservers at your domain registrar before DNS will work!"
    echo "1. Log into your domain registrar"
    echo "2. Go to Domain List → Manage → $DOMAIN_NAME → Nameservers"
    echo "3. Select 'Custom DNS' and enter the nameservers shown above"
    echo ""
else
    echo "Found existing hosted zone: $HOSTED_ZONE_ID"
fi

# Verify we have a hosted zone ID before proceeding
if [ -z "$HOSTED_ZONE_ID" ]; then
    echo "Error: Could not create or find hosted zone for $DOMAIN_NAME"
    echo "   Warning: You'll need to manually create DNS records pointing to: $CLOUDFRONT_DOMAIN"
    exit 1
fi

    
    # Create A record for apex domain
    cat > /tmp/route53-change.json << EOF
{
    "Changes": [
        {
            "Action": "UPSERT",
            "ResourceRecordSet": {
                "Name": "$DOMAIN_NAME",
                "Type": "A",
                "AliasTarget": {
                    "DNSName": "$CLOUDFRONT_DOMAIN",
                    "EvaluateTargetHealth": false,
                    "HostedZoneId": "$AWS_CLOUDFRONT_HOSTED_ZONE_ID"
                }
            }
        },
        {
            "Action": "UPSERT",
            "ResourceRecordSet": {
                "Name": "www.$DOMAIN_NAME",
                "Type": "A",
                "AliasTarget": {
                    "DNSName": "$CLOUDFRONT_DOMAIN",
                    "EvaluateTargetHealth": false,
                    "HostedZoneId": "$AWS_CLOUDFRONT_HOSTED_ZONE_ID"
                }
            }
        },
        {
            "Action": "UPSERT",
            "ResourceRecordSet": {
                "Name": "$APP_SUBDOMAIN",
                "Type": "A",
                "AliasTarget": {
                    "DNSName": "$APP_CLOUDFRONT_DOMAIN",
                    "EvaluateTargetHealth": false,
                    "HostedZoneId": "$AWS_CLOUDFRONT_HOSTED_ZONE_ID"
                }
            }
        }
    ]
}
EOF


    aws route53 change-resource-record-sets \
        --hosted-zone-id "$HOSTED_ZONE_ID" \
        --change-batch file:///tmp/route53-change.json

    rm /tmp/route53-change.json
    echo "   DNS records created successfully"


# Step 9: Create sample index.html if it doesn't exist
echo "8. Creating sample website files..."
if ! aws s3api head-object --bucket "$BUCKET_NAME" --key "index.html" 2>/dev/null; then
    cat > /tmp/index.html << EOF
<!DOCTYPE html>
<html>
<head>
    <title>Welcome to $DOMAIN_NAME</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 40px; }
        h1 { color: #333; }
    </style>
</head>
<body>
    <h1>Welcome to $DOMAIN_NAME</h1>
    <p>Your S3 static website is now live!</p>
    <p>This is a sample page. Replace this content with your own.</p>
</body>
</html>
EOF

    cat > /tmp/error.html << EOF
<!DOCTYPE html>
<html>
<head>
    <title>Page Not Found</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 40px; }
        h1 { color: #d32f2f; }
    </style>
</head>
<body>
    <h1>404 - Page Not Found</h1>
    <p>The page you're looking for doesn't exist.</p>
</body>
</html>
EOF

    aws s3 cp /tmp/index.html "s3://$BUCKET_NAME/"
    aws s3 cp /tmp/error.html "s3://$BUCKET_NAME/"
    
    rm /tmp/index.html /tmp/error.html
    echo "   Sample files uploaded"
fi

echo ""
echo "Setup completed successfully!"
echo ""
echo "Next steps:"
echo "1. Validate your SSL certificate by adding the DNS records shown in ACM console"
echo "2. Wait for CloudFront distribution to deploy (15-20 minutes)"
echo "3. Upload your website files to: s3://$BUCKET_NAME/"
echo "4. Your website will be available at: https://$DOMAIN_NAME"
echo ""
echo "Resources created:"
echo "- S3 Bucket: $BUCKET_NAME"
echo "- CloudFront Distribution: $DISTRIBUTION_ID"
echo "- SSL Certificate: $CERT_ARN"
echo "- Website URL: https://$DOMAIN_NAME"
echo "-    --- app-specific for the PWA: ---"
echo "- S3 Bucket for app: $APP_BUCKET_NAME"
echo "- CloudFront Distribution for app: $APP_DISTRIBUTION_ID"
echo "- SSL Certificate: $CERT_ARN"
echo "- Website URL for PWA app: https://$APP_SUBDOMAIN"

