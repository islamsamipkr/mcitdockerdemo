#!/usr/bin/env bash
# Deploys a tiny public IPv4 ECS Fargate service into the account's default VPC.
# Prerequisites: AWS CloudShell, AWS permissions for IAM/ECR/ECS/EC2/CloudWatch Logs.
set -euo pipefail
export AWS_PAGER=""
REGION="${AWS_REGION:-us-east-1}"
export AWS_DEFAULT_REGION="$REGION"
NAME="fargate-mini-demo"
CLUSTER="$NAME-cluster"
SERVICE="$NAME-service"
FAMILY="$NAME-task"
LOG_GROUP="/ecs/$NAME"
CAPACITY_PROVIDER="${CAPACITY_PROVIDER:-FARGATE}"  # FARGATE or FARGATE_SPOT
SKIP_BUILD_PUSH="${SKIP_BUILD_PUSH:-0}"  # 1 = reuse an image already in ECR
if [[ "$CAPACITY_PROVIDER" != "FARGATE" && "$CAPACITY_PROVIDER" != "FARGATE_SPOT" ]]; then
  echo "CAPACITY_PROVIDER must be FARGATE or FARGATE_SPOT" >&2; exit 1
fi
for cmd in aws docker; do
  command -v "$cmd" >/dev/null || { echo "Missing required command: $cmd" >&2; exit 1; }
done
if [[ "$SKIP_BUILD_PUSH" != "1" ]]; then
  docker info >/dev/null 2>&1 || { echo "Docker is unavailable. Use standard AWS CloudShell in a supported commercial Region." >&2; exit 1; }
fi
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
ROLE_NAME="$NAME-execution-$ACCOUNT_ID"
IMAGE_URI="$ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com/$NAME:demo"
VPC_ID="$(aws ec2 describe-vpcs --filters 'Name=isDefault,Values=true' --query 'Vpcs[0].VpcId' --output text)"
[[ "$VPC_ID" != "None" && -n "$VPC_ID" ]] || { echo "No default VPC exists in $REGION. Create one or adapt the script for an existing VPC." >&2; exit 1; }
SUBNET_ID="$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" --query 'Subnets[?MapPublicIpOnLaunch==`true`].SubnetId | [0]' --output text)"
[[ "$SUBNET_ID" != "None" && -n "$SUBNET_ID" ]] || { echo "No auto-assign-public-IP subnet in the default VPC. A public subnet is required." >&2; exit 1; }
# CloudShell outbound IPv4 is not the viewer's browser IPv4.
# Require the viewer's address, to avoid accidentally allowing the wrong source.
if [[ -z "${MY_IP_CIDR:-}" ]]; then
  echo "Set MY_IP_CIDR to YOUR BROWSER'S public IPv4/32 (not the CloudShell public IP)." >&2
  echo "Open https://checkip.amazonaws.com in your browser, then run:" >&2
  echo "  export MY_IP_CIDR=YOUR.IP.ADDRESS/32" >&2
  exit 1
fi
IP_CIDR="$MY_IP_CIDR"
[[ "$IP_CIDR" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/(3[0-2]|[12]?[0-9])$ ]] || { echo "Invalid CIDR: $IP_CIDR" >&2; exit 1; }
echo "Deploying in $REGION with access restricted to $IP_CIDR"

# AWS ECS needs an account-level service-linked role to manage task networking.
# This is DIFFERENT from the app's task execution role created below.
# ECS may try to auto-create it, but explicit setup gives clearer permission errors.
ROLE_RESULT="$(aws iam get-role --role-name AWSServiceRoleForECS 2>&1)" && ROLE_PRESENT=1 || ROLE_PRESENT=0
if [[ "$ROLE_PRESENT" == "1" ]]; then
  echo "ECS service-linked role is present (do not recreate it)."
elif [[ "$ROLE_RESULT" == *"NoSuchEntity"* ]]; then
  echo "ECS service-linked role not found; creating it..."
  if ! aws iam create-service-linked-role --aws-service-name ecs.amazonaws.com >/dev/null; then
    echo "ERROR: Unable to create AWSServiceRoleForECS. Ask an administrator to allow iam:CreateServiceLinkedRole for ecs.amazonaws.com." >&2
    exit 1
  fi
  echo "AWSServiceRoleForECS created; IAM changes may need propagation time."
else
  echo "Unable to inspect AWSServiceRoleForECS: $ROLE_RESULT" >&2
  exit 1
fi
# A newly created service-linked role must also have the ECS-managed policy.
if POLICIES="$(aws iam list-attached-role-policies --role-name AWSServiceRoleForECS --query 'AttachedPolicies[].PolicyName' --output text 2>&1)"; then
  if [[ "$POLICIES" != *"AmazonECSServiceRolePolicy"* ]]; then
    echo "WARNING: AmazonECSServiceRolePolicy is not yet visible. IAM may still be propagating." >&2
    echo "Check: aws iam list-attached-role-policies --role-name AWSServiceRoleForECS" >&2
  fi
else
  echo "WARNING: Could not list ECS service-linked role policies: $POLICIES" >&2
fi

# Set up the Docker registry.
aws ecr describe-repositories --repository-names "$NAME" >/dev/null 2>&1 || \
  aws ecr create-repository --repository-name "$NAME" --image-scanning-configuration scanOnPush=true >/dev/null
if [[ "$SKIP_BUILD_PUSH" == "1" ]]; then
  aws ecr describe-images --repository-name "$NAME" --image-ids imageTag=demo >/dev/null || { echo "No existing ECR image tagged demo. Run without SKIP_BUILD_PUSH=1." >&2; exit 1; }
  echo "Reusing existing ECR image (skipping Docker build and ECR push)."
else
  aws ecr get-login-password | docker login --username AWS --password-stdin "$ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com" >/dev/null
  docker build --platform linux/amd64 -t "$IMAGE_URI" .
  docker push "$IMAGE_URI"
fi

# Give Fargate only image-pull and log-push permissions.
if ! aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
  TRUST_FILE="$(mktemp)"
  cat > "$TRUST_FILE" <<'JSON'
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ecs-tasks.amazonaws.com"},"Action":"sts:AssumeRole"}]}
JSON
  aws iam create-role --role-name "$ROLE_NAME" --assume-role-policy-document "file://$TRUST_FILE" >/dev/null
  rm -f "$TRUST_FILE"
fi
aws iam attach-role-policy --role-name "$ROLE_NAME" \
  --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy
ROLE_ARN="$(aws iam get-role --role-name "$ROLE_NAME" --query Role.Arn --output text)"

# A small, short-retention log group.
aws logs describe-log-groups --log-group-name-prefix "$LOG_GROUP" --query "logGroups[?logGroupName=='$LOG_GROUP'].logGroupName" --output text | grep -Fqx "$LOG_GROUP" || \
  aws logs create-log-group --log-group-name "$LOG_GROUP"
aws logs put-retention-policy --log-group-name "$LOG_GROUP" --retention-in-days 1

# One dedicated security group: access to port 8080 ONLY from the specified browser IP.
SG_NAME="$NAME-sg-$ACCOUNT_ID"
SG_ID="$(aws ec2 describe-security-groups --filters "Name=group-name,Values=$SG_NAME" "Name=vpc-id,Values=$VPC_ID" --query 'SecurityGroups[0].GroupId' --output text)"
if [[ "$SG_ID" == "None" || -z "$SG_ID" ]]; then
  SG_ID="$(aws ec2 create-security-group --group-name "$SG_NAME" --description "Restricted Fargate learning demo" --vpc-id "$VPC_ID" --query GroupId --output text)"
fi
# Replace outdated inbound rules for this demo port on subsequent deploys.
OLD_RULES="$(aws ec2 describe-security-group-rules --filters "Name=group-id,Values=$SG_ID" \
  --query 'SecurityGroupRules[?IsEgress==`false` && FromPort==`8080`].SecurityGroupRuleId' --output text)"
if [[ -n "$OLD_RULES" && "$OLD_RULES" != "None" ]]; then
  # shellcheck disable=SC2086
  aws ec2 revoke-security-group-ingress --group-id "$SG_ID" --security-group-rule-ids $OLD_RULES >/dev/null
fi
aws ec2 authorize-security-group-ingress --group-id "$SG_ID" --protocol tcp --port 8080 --cidr "$IP_CIDR" >/dev/null

aws ecs describe-clusters --clusters "$CLUSTER" --query 'clusters[0].status' --output text | grep -Fqx ACTIVE || \
  aws ecs create-cluster --cluster-name "$CLUSTER" >/dev/null
TASK_JSON="$(mktemp)"
cat > "$TASK_JSON" <<JSON
{
  "family":"$FAMILY",
  "networkMode":"awsvpc",
  "requiresCompatibilities":["FARGATE"],
  "cpu":"256",
  "memory":"512",
  "executionRoleArn":"$ROLE_ARN",
  "runtimePlatform":{"cpuArchitecture":"X86_64","operatingSystemFamily":"LINUX"},
  "containerDefinitions":[{
    "name":"web","image":"$IMAGE_URI","essential":true,
    "portMappings":[{"containerPort":8080,"protocol":"tcp"}],
    "healthCheck":{"command":["CMD-SHELL","python -c 'from urllib.request import urlopen; urlopen(\"http://127.0.0.1:8080/health\", timeout=2)'"],"interval":30,"timeout":5,"retries":3,"startPeriod":15},
    "logConfiguration":{"logDriver":"awslogs","options":{"awslogs-group":"$LOG_GROUP","awslogs-region":"$REGION","awslogs-stream-prefix":"web"}}
  }]
}
JSON
aws ecs register-task-definition --cli-input-json "file://$TASK_JSON" >/dev/null
rm -f "$TASK_JSON"
EXISTING_SERVICE="$(aws ecs describe-services --cluster "$CLUSTER" --services "$SERVICE" --query "services[?status=='ACTIVE'].serviceName | [0]" --output text)"
if [[ "$EXISTING_SERVICE" == "$SERVICE" ]]; then
  aws ecs update-service --cluster "$CLUSTER" --service "$SERVICE" \
    --task-definition "$FAMILY" --desired-count 1 --force-new-deployment \
    --capacity-provider-strategy "capacityProvider=$CAPACITY_PROVIDER,weight=1" >/dev/null
else
  # AWS IAM can be eventually consistent after a new service-linked role is created.
  # Retry only the known transient IAM-assumption failure.
  CREATE_OK=0
  for attempt in 1 2 3 4 5 6 7 8; do
    CREATE_OUTPUT="$(aws ecs create-service --cluster "$CLUSTER" --service-name "$SERVICE" \
      --task-definition "$FAMILY" --desired-count 1 \
      --capacity-provider-strategy "capacityProvider=$CAPACITY_PROVIDER,weight=1" \
      --network-configuration "awsvpcConfiguration={subnets=[$SUBNET_ID],securityGroups=[$SG_ID],assignPublicIp=ENABLED}" 2>&1)" && CREATE_OK=1 && break
    if [[ "$CREATE_OUTPUT" == *"Unable to assume the service linked role"* && "$attempt" -lt 8 ]]; then
      echo "ECS role not ready yet (attempt $attempt/8); retrying service creation..." >&2
      sleep 10
    else
      echo "$CREATE_OUTPUT" >&2
      break
    fi
  done
  if [[ "$CREATE_OK" != "1" ]]; then
    echo "CreateService failed. If AWSServiceRoleForECS and AmazonECSServiceRolePolicy are correct, check AWS Organizations SCPs and ECS event details." >&2
    exit 1
  fi
fi
printf '\nChecking ECS service deployment status...\n'
aws ecs wait services-stable --cluster "$CLUSTER" --services "$SERVICE"
TASK_ARN="$(aws ecs list-tasks --cluster "$CLUSTER" --service-name "$SERVICE" --desired-status RUNNING --query 'taskArns[0]' --output text)"
[[ "$TASK_ARN" != "None" && -n "$TASK_ARN" ]] || { echo "No running task. Inspect ECS events and CloudWatch Logs." >&2; exit 1; }
ENI_ID="$(aws ecs describe-tasks --cluster "$CLUSTER" --tasks "$TASK_ARN" \
  --query "tasks[0].attachments[0].details[?name=='networkInterfaceId'].value | [0]" --output text)"
PUBLIC_IP="$(aws ec2 describe-network-interfaces --network-interface-ids "$ENI_ID" --query 'NetworkInterfaces[0].Association.PublicIp' --output text)"
echo ""
echo "✅ Website: http://$PUBLIC_IP:8080"
echo "✅ JSON API: http://$PUBLIC_IP:8080/api/hello"
echo "✅ Health:  http://$PUBLIC_IP:8080/health"
echo "Access allowed only from $IP_CIDR"
echo "When finished run: ./cleanup.sh"
