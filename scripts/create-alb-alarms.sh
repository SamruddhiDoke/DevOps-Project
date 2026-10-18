#!/usr/bin/env bash
# Create CloudWatch alarms for the application ALB. The ALB is created by the AWS Load Balancer
# Controller from k8s/ingress.yaml (not by Terraform), so run this once after the first deployment
# (and again if the Ingress is ever recreated). Alarms notify the Terraform-managed SNS topic.
#
#   ./scripts/create-alb-alarms.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NAMESPACE="${K8S_NAMESPACE:-order-inventory}"
REGION="${AWS_REGION:-ap-south-1}"
TOPIC_ARN="$(terraform -chdir="$REPO_ROOT/terraform" output -raw alerts_sns_topic_arn)"

ALB_DNS="$(kubectl -n "$NAMESPACE" get ingress order-inventory-ingress -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')"
[ -n "$ALB_DNS" ] || { echo "Ingress has no ALB hostname yet" >&2; exit 1; }

ALB_ARN="$(aws elbv2 describe-load-balancers --region "$REGION" \
  --query "LoadBalancers[?DNSName=='${ALB_DNS}'].LoadBalancerArn" --output text)"
# CloudWatch dimension format: app/<name>/<id>
ALB_DIM="${ALB_ARN#*:loadbalancer/}"

aws cloudwatch put-metric-alarm --region "$REGION" \
  --alarm-name order-inventory-alb-5xx \
  --alarm-description "ALB returned >10 HTTP 5xx responses in 5 minutes" \
  --namespace AWS/ApplicationELB --metric-name HTTPCode_ELB_5XX_Count \
  --dimensions Name=LoadBalancer,Value="$ALB_DIM" \
  --statistic Sum --period 300 --evaluation-periods 1 --threshold 10 \
  --comparison-operator GreaterThanThreshold --treat-missing-data notBreaching \
  --alarm-actions "$TOPIC_ARN" --ok-actions "$TOPIC_ARN"

aws cloudwatch put-metric-alarm --region "$REGION" \
  --alarm-name order-inventory-alb-target-5xx \
  --alarm-description "Application targets returned >10 HTTP 5xx responses in 5 minutes" \
  --namespace AWS/ApplicationELB --metric-name HTTPCode_Target_5XX_Count \
  --dimensions Name=LoadBalancer,Value="$ALB_DIM" \
  --statistic Sum --period 300 --evaluation-periods 1 --threshold 10 \
  --comparison-operator GreaterThanThreshold --treat-missing-data notBreaching \
  --alarm-actions "$TOPIC_ARN" --ok-actions "$TOPIC_ARN"

# Downtime detection: any target group of this ALB with unhealthy targets for 3 minutes
for TG_ARN in $(aws elbv2 describe-target-groups --region "$REGION" --load-balancer-arn "$ALB_ARN" \
                  --query 'TargetGroups[].TargetGroupArn' --output text); do
  TG_DIM="${TG_ARN#*:}"; TG_DIM="targetgroup/${TG_DIM#*:targetgroup/}"
  TG_NAME="$(echo "$TG_DIM" | cut -d/ -f2)"
  aws cloudwatch put-metric-alarm --region "$REGION" \
    --alarm-name "order-inventory-alb-unhealthy-hosts-${TG_NAME}" \
    --alarm-description "Unhealthy targets behind the ALB (${TG_NAME}) for 3 minutes" \
    --namespace AWS/ApplicationELB --metric-name UnHealthyHostCount \
    --dimensions Name=LoadBalancer,Value="$ALB_DIM" Name=TargetGroup,Value="$TG_DIM" \
    --statistic Maximum --period 60 --evaluation-periods 3 --threshold 0 \
    --comparison-operator GreaterThanThreshold --treat-missing-data notBreaching \
    --alarm-actions "$TOPIC_ARN" --ok-actions "$TOPIC_ARN"
done

echo "ALB alarms created for $ALB_DIM -> $TOPIC_ARN"
echo "Delete them during teardown:"
echo "  aws cloudwatch describe-alarms --alarm-name-prefix order-inventory-alb --query 'MetricAlarms[].AlarmName' --output text | xargs aws cloudwatch delete-alarms --alarm-names"
