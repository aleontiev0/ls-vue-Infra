#!/bin/bash

if [ -z "$S3_BUCKET_NAME" ]; then
    export S3_BUCKET_NAME=prod-ls-base-bucket-us-east-1
    echo "No value found for S3_BUCKET_NAME!! Setting it to the default: $S3_BUCKET_NAME"
fi

if [ -z "$WEBSITE_DOMAIN_NAME" ]; then
    export WEBSITE_DOMAIN_NAME=lessonscore.com
    echo "No value found for WEBSITE_DOMAIN_NAME!! Setting it to the default: $WEBSITE_DOMAIN_NAME"
fi 

# Set region, configure AWS CLI, and then run script in sequence
if [ -z "$AWS_REGION" ]; then
   export AWS_REGION=us-east-1 
fi

aws configure set aws_access_key_id "$(tail -n +2 ../AWS_secrets/ls-infra-user_accessKeys.csv | cut -d',' -f1)" && \
aws configure set aws_secret_access_key "$(tail -n +2 ../AWS_secrets/ls-infra-user_accessKeys.csv | cut -d',' -f2)" && \
aws configure set default.region $AWS_REGION && \
aws sts get-caller-identity && \
chmod u+x setup-s3-website.sh && \
./setup-s3-website.sh

