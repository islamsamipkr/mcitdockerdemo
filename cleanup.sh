#!/usr/bin/env bash
# Removes demo compute and related resources. Doesn't touch unrelated resources.
set -euo pipefail
export AWS_PAGER=""
REGION="${AWS_REGION:-us-east-1}"
export AWS_DEFAULT_REGION="$REGION"
NAME="fargate-mini-demo"
CLUSTER="$NAME-cluster"
SERVICE="$NAME-service"
FAMILY="$NAME-task"
LOG_GROUP="/ecs/$NAME"
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
ROLE_NAME="$NAME-execution-$ACCOUNT_ID"
SG_NAME="$NAME-sg-$ACCOUNT_ID"
VPC_ID="$(aws ec2 describe-vpcs --filters 'Name=isDefault,Values=true' --query 'Vpcs[0].VpcId' --output text)"

if aws ecs describe-clusters --clusters "$CLUSTER" --query 'clusters[0].status' --output text | grep -Fqx ACTIVE; then
  if [[ "$(aws ecs describe-services --cluster "$CLUSTER" --services "$SERVICE" --query "services[?status=='ACTIVE'].serviceName | [0]" --output text)" == "$SERVICE" ]]; then
    aws ecs update-service --cluster "$CLUSTER" --service "$SERVICE" --desired-count 0 >/dev/null
    aws ecs delete-service --cluster "$CLUSTER" --service "$SERVICE" --force >/dev/null
    aws ecs wait services-inactive --cluster "$CLUSTER" --services "$SERVICE"
  fi
  aws ecs delete-cluster --cluster "$CLUSTER" >/dev/null
fi
TASK_ARNS="$(aws ecs list-task-definitions --family-prefix "$FAMILY" --status ACTIVE --query taskDefinitionArns --output text)"
for arn in $TASK_ARNS; do
  aws ecs deregister-task-definition --task-definition "$arn" >/dev/null
done
aws ecr describe-repositories --repository-names "$NAME" >/dev/null 2>&1 && \
  aws ecr delete-repository --repository-name "$NAME" --force >/dev/null || true
aws logs delete-log-group --log-group-name "$LOG_GROUP" >/dev/null 2>&1 || true
if [[ -n "$VPC_ID" && "$VPC_ID" != "None" ]]; then
  SG_ID="$(aws ec2 describe-security-groups --filters "Name=group-name,Values=$SG_NAME" "Name=vpc-id,Values=$VPC_ID" --query 'SecurityGroups[0].GroupId' --output text)"
  if [[ -n "$SG_ID" && "$SG_ID" != "None" ]]; then
    # AWS may keep the ECS task ENI for a short time after service deletion.
    DELETED=0
    for attempt in {1..18}; do
      if aws ec2 delete-security-group --group-id "$SG_ID" >/dev/null 2>&1; then DELETED=1; break; fi
      sleep 5
    done
    [[ "$DELETED" == 1 ]] || echo "Note: Security group $SG_ID is still attached. Delete it manually after its ENI detaches."
  fi
fi
if aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
  aws iam detach-role-policy --role-name "$ROLE_NAME" \
    --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy
  aws iam delete-role --role-name "$ROLE_NAME"
fi
printf '\n✅ Demo teardown complete (inspect any warnings above).\n'
