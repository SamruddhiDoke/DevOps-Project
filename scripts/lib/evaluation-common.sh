#!/usr/bin/env bash
# shellcheck disable=SC2034  # variables are used by the scripts that source this file
# Shared helpers for scripts/suspend-evaluation.sh and scripts/resume-evaluation.sh.
# Discovers real resource identifiers from Terraform outputs / AWS; never prints secret values.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export AWS_PROFILE="${AWS_PROFILE:-order-inventory}"
export AWS_REGION="${AWS_REGION:-ap-south-1}"
export AWS_DEFAULT_REGION="$AWS_REGION"
EXPECTED_ACCOUNT="038215676861"
NAMESPACE="order-inventory"
RELEASE="order-inventory"
MANIFEST="$REPO_ROOT/docs/recovery/evaluation-manifest.json"
LOG_DIR="$REPO_ROOT/.deploy/evaluation-logs"
mkdir -p "$LOG_DIR" "$(dirname "$MANIFEST")"

STAGE="init"
ts() { date +%H:%M:%S; }
log() { echo "[$(ts)] $*"; }
stage() { STAGE="$1"; echo; echo "[$(ts)] ===== $1 ====="; }
ok() { echo "[$(ts)]   OK  $*"; }
warn() { echo "[$(ts)]   WARN $*"; }
die() {
  echo
  echo "[$(ts)] FAILED in stage: $STAGE"
  echo "  reason: $*"
  echo "  diagnostics:"
  echo "    aws sts get-caller-identity --profile $AWS_PROFILE"
  echo "    aws eks describe-nodegroup --cluster-name ${CLUSTER:-<cluster>} --nodegroup-name ${NODEGROUP:-<nodegroup>} --query nodegroup.status"
  echo "    kubectl get nodes; kubectl -n $NAMESPACE get pods,ingress; kubectl -n $NAMESPACE get events --sort-by=.lastTimestamp | tail -20"
  echo "    aws rds describe-db-instances --db-instance-identifier ${RDS_ID:-<rds>} --query 'DBInstances[0].DBInstanceStatus'"
  echo "    aws ec2 describe-instances --instance-ids ${JENKINS_ID:-<jenkins>} --query 'Reservations[0].Instances[0].State.Name'"
  echo "  The scripts are idempotent: fix the cause and run the same command again."
  exit 1
}

# wait_until <timeout-seconds> <description> <command...>
wait_until() {
  local timeout="$1" desc="$2"; shift 2
  local start=$SECONDS
  until "$@" >/dev/null 2>&1; do
    [ $((SECONDS - start)) -ge "$timeout" ] && die "timed out after ${timeout}s waiting for: $desc"
    sleep 10
  done
  ok "$desc ($((SECONDS - start))s)"
}

win_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else echo "$1"; fi; }
TF_DIR="$(win_path "$REPO_ROOT/terraform")"
tfout() { terraform -chdir="$TF_DIR" output -raw "$1" 2>/dev/null | tr -d '\r'; }

json_get() { # json_get <file> <dotted.path>
  node -e 'const o=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));let v=o;for(const k of process.argv[2].split("."))v=v==null?undefined:v[k];process.stdout.write(v===undefined||v===null?"":String(v))' "$(win_path "$1")" "$2"
}

preflight() {
  stage "Preflight: tools, identity, Terraform backend"
  for t in aws terraform kubectl helm node curl; do
    command -v "$t" >/dev/null 2>&1 || die "required tool not found: $t"
  done
  ok "tools: aws terraform kubectl helm node curl"

  local arn account
  arn="$(aws sts get-caller-identity --query Arn --output text 2>/dev/null | tr -d '\r')" || true
  account="$(aws sts get-caller-identity --query Account --output text 2>/dev/null | tr -d '\r')" || true
  [ -n "$arn" ] || die "AWS CLI profile '$AWS_PROFILE' is not usable (aws configure --profile $AWS_PROFILE)"
  [ "$account" = "$EXPECTED_ACCOUNT" ] || die "wrong AWS account ($account), expected $EXPECTED_ACCOUNT"
  case "$arn" in *":root") die "refusing to run as the root user; use the order-inventory deployer profile";; esac
  ok "identity $arn, region $AWS_REGION"

  terraform -chdir="$TF_DIR" init -input=false >/dev/null 2>&1 || die "terraform init failed (S3 backend reachable?)"
  CLUSTER="$(tfout eks_cluster_name)"; RDS_ID="$(tfout rds_endpoint | cut -d. -f1)"; JENKINS_ID="$(tfout jenkins_instance_id)"
  REGISTRY="$(tfout aws_account_id).dkr.ecr.${AWS_REGION}.amazonaws.com"
  NODEGROUP="$(aws eks list-nodegroups --cluster-name "$CLUSTER" --query 'nodegroups[0]' --output text 2>/dev/null | tr -d '\r')"
  STATE_BUCKET="$(grep -E '^\s*bucket' "$REPO_ROOT/terraform/backend.tf" | sed -E 's/.*"([^"]+)".*/\1/')"
  [ -n "$CLUSTER" ] && [ -n "$JENKINS_ID" ] && [ -n "$NODEGROUP" ] && [ "$NODEGROUP" != None ] \
    || die "could not read resource identifiers from Terraform outputs / EKS"
  aws s3api head-bucket --bucket "$STATE_BUCKET" >/dev/null 2>&1 || die "Terraform state bucket $STATE_BUCKET not reachable"
  ok "cluster=$CLUSTER nodegroup=$NODEGROUP rds=$RDS_ID jenkins=$JENKINS_ID state=s3://$STATE_BUCKET"

  local cstatus
  cstatus="$(aws eks describe-cluster --name "$CLUSTER" --query cluster.status --output text | tr -d '\r')"
  [ "$cstatus" = ACTIVE ] || die "EKS cluster $CLUSTER is $cstatus (expected ACTIVE)"
  ok "EKS cluster ACTIVE"
}

# kubectl access requires this machine's public IP to be allowed on the EKS public endpoint
ensure_kube_access() {
  aws eks update-kubeconfig --name "$CLUSTER" --alias "$CLUSTER" >/dev/null 2>&1 || die "aws eks update-kubeconfig failed"
  kubectl config use-context "$CLUSTER" >/dev/null 2>&1
  kubectl version --request-timeout=15s >/dev/null 2>&1 \
    || die "cannot reach the Kubernetes API from this machine (is your public IP allowed? run resume-evaluation.sh, which updates the allowed CIDR)"
  ok "kubectl context $CLUSTER reachable"
}

rds_status() { aws rds describe-db-instances --db-instance-identifier "$RDS_ID" --query 'DBInstances[0].DBInstanceStatus' --output text 2>/dev/null | tr -d '\r'; }
ec2_state() { aws ec2 describe-instances --instance-ids "$JENKINS_ID" --query 'Reservations[0].Instances[0].State.Name' --output text 2>/dev/null | tr -d '\r'; }
ng_field() { aws eks describe-nodegroup --cluster-name "$CLUSTER" --nodegroup-name "$NODEGROUP" --query "nodegroup.$1" --output text 2>/dev/null | tr -d '\r'; }
asg_instances() {
  local asg; asg="$(ng_field 'resources.autoScalingGroups[0].name')"
  aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$asg" --query 'length(AutoScalingGroups[0].Instances)' --output text 2>/dev/null | tr -d '\r'
}
app_albs() { aws elbv2 describe-load-balancers --query "length(LoadBalancers[?starts_with(LoadBalancerName,'k8s-orderinv')])" --output text 2>/dev/null | tr -d '\r'; }

print_cost_summary() {
  stage "Cost-bearing resources right now"
  local nodes ec2 rds albs nat
  nodes="$(asg_instances)"; ec2="$(ec2_state)"; rds="$(rds_status)"; albs="$(app_albs)"
  nat="$(aws ec2 describe-nat-gateways --filter Name=tag:Project,Values=order-inventory Name=state,Values=available --query 'length(NatGateways)' --output text | tr -d '\r')"
  printf '  %-28s %s\n' "EKS control plane" "running (always billed: \$0.10/h)" \
    "EKS worker nodes" "$nodes instance(s)" "Jenkins EC2" "$ec2" "RDS" "$rds" \
    "Application ALBs" "$albs" "NAT gateways" "$nat (billed \$0.056/h while present)"
}

# Predicates for wait_until (shell functions run in this shell, so no nested quoting is needed)
rds_is() { [ "$(rds_status)" = "$1" ]; }
ec2_is() { [ "$(ec2_state)" = "$1" ]; }
ng_active() { [ "$(ng_field status)" = ACTIVE ]; }
no_asg_instances() { [ "$(asg_instances)" = 0 ]; }
no_app_albs() { [ "$(app_albs)" = 0 ]; }
no_app_tgs() { [ "$(aws elbv2 describe-target-groups --query "length(TargetGroups[?starts_with(TargetGroupName,'k8s-orderinv')])" --output text 2>/dev/null | tr -d '\r')" = 0 ]; }
http_200() { [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$1")" = 200 ]; }
