#!/bin/bash

# setup-infra-user-account.sh
# Script to prepare account-level settings and create ls-infra-user for S3 website hosting

set -e  # Exit on any error

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
print_status() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if AWS_REGION environment variable is set
if [ -z "$AWS_REGION" ]; then
    print_error "AWS_REGION environment variable is not set. Please set it before running this script."
    print_error "Example: export AWS_REGION=us-east-1"
    exit 1
fi

print_status "Using AWS region: $AWS_REGION"

# Check if AWS CLI is installed and configured
if ! command -v aws &> /dev/null; then
    print_error "AWS CLI is not installed. Please install it first."
    exit 1
fi

# Test AWS CLI configuration
if ! aws sts get-caller-identity &> /dev/null; then
    print_error "AWS CLI is not properly configured or you don't have valid credentials."
    exit 1
fi

CURRENT_USER=$(aws sts get-caller-identity --query 'Arn' --output text)
print_status "Running as: $CURRENT_USER"

# Define the IAM user name
IAM_USER="ls-infra-user"

print_status "Starting account-level configuration and IAM user setup..."

# Step 1: Disable Block Public Access at account level
print_status "Disabling S3 Block Public Access at account level..."
aws s3control put-public-access-block \
    --account-id $(aws sts get-caller-identity --query Account --output text) \
    --public-access-block-configuration \
    BlockPublicAcls=false,IgnorePublicAcls=false,BlockPublicPolicy=false,RestrictPublicBuckets=false \
    --region $AWS_REGION

print_success "S3 Block Public Access disabled at account level"

# Step 2: Create IAM policy for ls-infra-user
print_status "Creating IAM policy for $IAM_USER..."

POLICY_NAME="ls-infra-user-policy"
POLICY_DOCUMENT='{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "S3WebsiteHostingPermissions",
            "Effect": "Allow",
            "Action": [
                "s3:CreateBucket",
                "s3:DeleteBucket",
                "s3:GetBucketLocation",
                "s3:GetBucketWebsite",
                "s3:PutBucketWebsite",
                "s3:DeleteBucketWebsite",
                "s3:GetBucketPolicy",
                "s3:PutBucketPolicy",
                "s3:DeleteBucketPolicy",
                "s3:GetBucketPublicAccessBlock",
                "s3:PutBucketPublicAccessBlock",
                "s3:GetBucketAcl",
                "s3:PutBucketAcl",
                "s3:ListBucket",
                "s3:GetObject",
                "s3:PutObject",
                "s3:DeleteObject",
                "s3:GetObjectAcl",
                "s3:PutObjectAcl"
            ],
            "Resource": [
                "arn:aws:s3:::*",
                "arn:aws:s3:::*/*"
            ]
        },
        {
            "Sid": "CloudFrontPermissions",
            "Effect": "Allow",
            "Action": [
                "cloudfront:CreateDistribution",
                "cloudfront:GetDistribution",
                "cloudfront:GetDistributionConfig",
                "cloudfront:UpdateDistribution",
                "cloudfront:DeleteDistribution",
                "cloudfront:ListDistributions",
                "cloudfront:CreateOriginAccessControl",
                "cloudfront:GetOriginAccessControl",
                "cloudfront:UpdateOriginAccessControl",
                "cloudfront:DeleteOriginAccessControl",
                "cloudfront:ListOriginAccessControls",
                "cloudfront:CreateInvalidation",
                "cloudfront:GetInvalidation",
                "cloudfront:ListInvalidations"
            ],
            "Resource": "*"
        },
        {
            "Sid": "CertificateManagerPermissions",
            "Effect": "Allow",
            "Action": [
                "acm:RequestCertificate",
                "acm:DescribeCertificate",
                "acm:ListCertificates",
                "acm:GetCertificate",
                "acm:DeleteCertificate",
                "acm:ResendValidationEmail"
            ],
            "Resource": "*"
        },
        {
            "Sid": "Route53Permissions",
            "Effect": "Allow",
            "Action": [
                "route53:GetHostedZone",
                "route53:ListHostedZones",
                "route53:ListHostedZonesByName",
                "route53:ChangeResourceRecordSets",
                "route53:GetChange",
                "route53:ListResourceRecordSets",
                "route53:CreateHostedZone"
            ],
            "Resource": "*"
        },
        {
            "Sid": "IAMPermissionsForOAC",
            "Effect": "Allow",
            "Action": [
                "iam:CreateServiceLinkedRole"
            ],
            "Resource": "arn:aws:iam::*:role/aws-service-role/cloudfront.amazonaws.com/AWSServiceRoleForCloudFront*",
            "Condition": {
                "StringEquals": {
                    "iam:AWSServiceName": "cloudfront.amazonaws.com"
                }
            }
        }
    ]
}'

# Check if policy already exists
if aws iam get-policy --policy-arn "arn:aws:iam::$(aws sts get-caller-identity --query Account --output text):policy/$POLICY_NAME" &> /dev/null; then
    print_warning "Policy $POLICY_NAME already exists. Updating it..."
    aws iam create-policy-version \
        --policy-arn "arn:aws:iam::$(aws sts get-caller-identity --query Account --output text):policy/$POLICY_NAME" \
        --policy-document "$POLICY_DOCUMENT" \
        --set-as-default
    print_success "Policy $POLICY_NAME updated"
else
    aws iam create-policy \
        --policy-name "$POLICY_NAME" \
        --policy-document "$POLICY_DOCUMENT" \
        --description "Policy for ls-infra-user to manage S3 website hosting infrastructure"
    print_success "Policy $POLICY_NAME created"
fi

# Step 3: Create IAM user
print_status "Creating IAM user: $IAM_USER..."

if aws iam get-user --user-name "$IAM_USER" &> /dev/null; then
    print_warning "User $IAM_USER already exists"
else
    aws iam create-user --user-name "$IAM_USER"
    print_success "User $IAM_USER created"
fi

# Step 4: Attach policy to user
print_status "Attaching policy to user..."
aws iam attach-user-policy \
    --user-name "$IAM_USER" \
    --policy-arn "arn:aws:iam::$(aws sts get-caller-identity --query Account --output text):policy/$POLICY_NAME"
print_success "Policy attached to user $IAM_USER"

# Step 5: Check for existing access keys
print_status "Checking for existing access keys for user $IAM_USER..."
ACCESS_KEYS=$(aws iam list-access-keys --user-name "$IAM_USER" --query 'AccessKeyMetadata[].AccessKeyId' --output text)

if [ -z "$ACCESS_KEYS" ]; then
    print_warning "No access keys found for user $IAM_USER"
    echo ""
    print_status "NEXT STEPS:"
    echo "1. Go to the AWS IAM Console"
    echo "2. Navigate to Users > $IAM_USER > Security credentials"
    echo "3. Click 'Create access key'"
    echo "4. Choose 'Command Line Interface (CLI)' as the use case"
    echo "5. Download and securely store the access key and secret"
    echo "6. Configure these credentials for your infrastructure deployment scripts"
else
    print_success "Found existing access key(s) for user $IAM_USER:"
    for key in $ACCESS_KEYS; do
        KEY_STATUS=$(aws iam get-access-key-last-used --access-key-id "$key" --query 'AccessKeyLastUsed.LastUsedDate' --output text 2>/dev/null || echo "Never used")
        echo "  - Access Key ID: $key (Last used: $KEY_STATUS)"
    done
    echo ""
    print_status "RECOMMENDATION:"
    echo "You can use one of the existing access keys listed above, or create a new one if needed."
    echo "To create a new access key:"
    echo "1. Go to the AWS IAM Console"
    echo "2. Navigate to Users > $IAM_USER > Security credentials"
    echo "3. Click 'Create access key' (if you have less than 2 keys)"
fi

echo ""
print_success "Account setup completed successfully!"
echo ""
print_status "SUMMARY OF CHANGES:"
echo "✓ S3 Block Public Access disabled at account level"
echo "✓ IAM policy '$POLICY_NAME' created/updated with necessary permissions"
echo "✓ IAM user '$IAM_USER' created with required permissions for:"
echo "  - S3 bucket creation and management"
echo "  - S3 website hosting configuration"
echo "  - S3 bucket policy management"
echo "  - CloudFront distribution management"
echo "  - SSL certificate management (ACM)"
echo "  - Route 53 DNS record management"
echo "  - Content upload and management"
echo ""
print_status "The user '$IAM_USER' is now ready to deploy and manage S3-based website infrastructure."

