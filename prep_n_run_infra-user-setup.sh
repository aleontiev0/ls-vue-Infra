# Set region, configure AWS CLI, and run script in sequence
export AWS_REGION=us-east-1 && \
aws configure set aws_access_key_id "$(tail -n +2 ../AWS_secrets/leo.t13v_accessKeys.csv | cut -d',' -f1)" && \
aws configure set aws_secret_access_key "$(tail -n +2 ../AWS_secrets/leo.t13v_accessKeys.csv | cut -d',' -f2)" && \
aws configure set default.region $AWS_REGION && \
aws sts get-caller-identity && \
chmod u+x setup-infra-user-account.sh && \
./setup-infra-user-account.sh

