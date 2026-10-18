#!/usr/bin/env bash
# Suspend the AWS environment to minimise cost while keeping everything restorable with
# scripts/resume-evaluation.sh. Nothing is destroyed: cluster, node group definition, RDS data and
# backups, Jenkins disk, ECR images, secrets, KMS key, network and Terraform state are all retained.
#
#   bash scripts/suspend-evaluation.sh            # suspend
#   bash scripts/suspend-evaluation.sh --plan     # show what would be done, change nothing
#
# Order matters: the ALB is removed while the AWS Load Balancer Controller still has nodes to run on.
source "$(dirname "$0")/lib/evaluation-common.sh"

PLAN_ONLY=false; [ "${1:-}" = "--plan" ] && PLAN_ONLY=true
exec > >(tee -a "$LOG_DIR/suspend-$(date +%Y%m%d-%H%M%S).log") 2>&1

preflight

stage "Current state"
NG_DESIRED="$(ng_field scalingConfig.desiredSize)"; NG_MIN="$(ng_field scalingConfig.minSize)"; NG_MAX="$(ng_field scalingConfig.maxSize)"
log "node group: desired=$NG_DESIRED min=$NG_MIN max=$NG_MAX, instances=$(asg_instances)"
log "RDS: $(rds_status)   Jenkins EC2: $(ec2_state)   application ALBs: $(app_albs)"

KUBE_OK=false
if [ "$NG_DESIRED" != 0 ] || [ "$(asg_instances)" != 0 ]; then ensure_kube_access; KUBE_OK=true; fi

if $PLAN_ONLY; then
  stage "Plan (no changes made)"
  [ "$(app_albs)" != 0 ] && log "would disable the Ingress via Helm and wait for the ALB to be deleted; delete ALB alarms"
  $KUBE_OK && log "would scale backend/frontend and Elasticsearch/Kibana to 0 replicas"
  [ "$NG_DESIRED" != 0 ] && log "would scale node group $NODEGROUP from $NG_DESIRED to 0 (min 0, max $NG_MAX)"
  [ "$(ec2_state)" = running ] && log "would stop Jenkins EC2 $JENKINS_ID (EBS root volume retained)"
  [ "$(rds_status)" = available ] && log "would stop RDS $RDS_ID (storage + backups retained; AWS restarts it after 7 days)"
  print_cost_summary
  exit 0
fi

stage "1. Recovery manifest (no secrets)"
if $KUBE_OK && kubectl -n "$NAMESPACE" get deploy backend >/dev/null 2>&1; then
  BACKEND_IMAGE="$(kubectl -n "$NAMESPACE" get deploy backend -o jsonpath='{.spec.template.spec.containers[0].image}')"
  FRONTEND_IMAGE="$(kubectl -n "$NAMESPACE" get deploy frontend -o jsonpath='{.spec.template.spec.containers[0].image}')"
  BACKEND_TAG="${BACKEND_IMAGE##*:}"; FRONTEND_TAG="${FRONTEND_IMAGE##*:}"
  [ "$BACKEND_TAG" = "$FRONTEND_TAG" ] || die "backend ($BACKEND_TAG) and frontend ($FRONTEND_TAG) run different tags; deploy one known-good release first"
  READY="$(kubectl -n "$NAMESPACE" get deploy backend frontend -o jsonpath='{range .items[*]}{.status.readyReplicas}{" "}{end}')"
  case "$READY" in "2 2 "|"2 2") ;; *) warn "deployments not fully ready ($READY); recording the running tag anyway";; esac
  for repo in order-inventory-backend order-inventory-frontend; do
    aws ecr describe-images --repository-name "$repo" --image-ids imageTag="$BACKEND_TAG" >/dev/null 2>&1 \
      || die "image $repo:$BACKEND_TAG not found in ECR; cannot guarantee restore"
  done
  ok "last known-good release: $BACKEND_TAG (both images present in ECR)"
  HELM_REV="$(helm -n "$NAMESPACE" history "$RELEASE" --max 1 -o json | node -e 'let d="";process.stdin.on("data",c=>d+=c).on("end",()=>console.log(JSON.parse(d).pop().revision))')"
  ALB_HOST="$(kubectl -n "$NAMESPACE" get ingress order-inventory-ingress -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
  node -e '
    const [file, ...a] = process.argv.slice(1);
    const [account, region, profile, cluster, nodegroup, desired, min, max, rds, jenkins, registry, tag, helmRev, alb, bucket] = a;
    const m = {
      purpose: "Recovery manifest for scripts/resume-evaluation.sh. Contains no secrets.",
      awsAccount: account, awsRegion: region, awsProfile: profile,
      terraformBackend: { bucket, key: "order-inventory/terraform.tfstate", lock: "S3 native lockfile" },
      eks: { cluster, nodegroup, desiredSize: Number(desired), minSize: Number(min), maxSize: Number(max) },
      rds: { identifier: rds, secret: "order-inventory/rds-master" },
      jenkins: { instanceId: jenkins, adminSecret: "order-inventory/jenkins-admin", repo: "https://github.com/SamruddhiDoke/DevOps-Project.git" },
      application: {
        namespace: "order-inventory", helmRelease: "order-inventory", helmChart: "helm/order-inventory",
        helmRevisionAtSuspend: Number(helmRev), registry,
        repositories: ["order-inventory-backend", "order-inventory-frontend"],
        lastKnownGoodTag: tag, replicas: { backend: 2, frontend: 2 },
        ingress: { name: "order-inventory-ingress", className: "alb", recreatedBy: "helm (ingress.enabled=true, chart default)" },
        albHostnameAtSuspend: alb || null
      },
      logging: { namespace: "logging", manifest: "k8s/logging/elk.yaml", replicas: { elasticsearch: 1, kibana: 1 } },
      suspendedAt: new Date().toISOString(),
      rdsAutoRestartAfter: new Date(Date.now() + 7 * 864e5).toISOString()
    };
    require("fs").writeFileSync(file, JSON.stringify(m, null, 2) + "\n");
  ' "$(win_path "$MANIFEST")" "$EXPECTED_ACCOUNT" "$AWS_REGION" "$AWS_PROFILE" "$CLUSTER" "$NODEGROUP" \
    "$NG_DESIRED" "$NG_MIN" "$NG_MAX" "$RDS_ID" "$JENKINS_ID" "$REGISTRY" "$BACKEND_TAG" "$HELM_REV" "$ALB_HOST" "$STATE_BUCKET"
  ok "manifest written: docs/recovery/evaluation-manifest.json (tag $BACKEND_TAG, Helm revision $HELM_REV)"
elif [ -f "$MANIFEST" ]; then
  ok "application already scaled down; keeping existing manifest (tag $(json_get "$MANIFEST" application.lastKnownGoodTag))"
else
  die "no running application and no existing manifest: nothing safe to record"
fi

stage "2. Remove the application ALB (Ingress disabled through Helm; chart and values unchanged)"
if [ "$(app_albs)" != 0 ]; then
  $KUBE_OK || die "an application ALB exists but the cluster has no nodes to run the controller; resume first"
  helm upgrade "$RELEASE" "$REPO_ROOT/helm/order-inventory" -n "$NAMESPACE" --reuse-values --set ingress.enabled=false --wait --timeout 5m >/dev/null \
    || die "helm upgrade (ingress.enabled=false) failed"
  ok "Ingress removed from the release"
  wait_until 600 "ALB deleted by the AWS Load Balancer Controller" no_app_albs
  wait_until 300 "ALB target groups deleted" no_app_tgs
else
  ok "no application ALB present"
fi
ALARMS="$(aws cloudwatch describe-alarms --alarm-name-prefix order-inventory-alb --query 'MetricAlarms[].AlarmName' --output text | tr -d '\r')"
if [ -n "$ALARMS" ]; then
  # shellcheck disable=SC2086
  aws cloudwatch delete-alarms --alarm-names $ALARMS && ok "deleted ALB alarms (recreated by resume for the new ALB)"
fi

stage "3. Release worker capacity (workloads scaled to 0; no persistent volumes are used)"
if $KUBE_OK; then
  kubectl -n "$NAMESPACE" scale deploy backend frontend --replicas=0 >/dev/null && ok "backend/frontend scaled to 0 (Helm restores 2 on resume)"
  if kubectl get ns logging >/dev/null 2>&1; then
    kubectl -n logging scale deploy elasticsearch kibana --replicas=0 >/dev/null && ok "Elasticsearch/Kibana scaled to 0 (demo logs on emptyDir are discarded)"
  fi
  [ "$(kubectl get pv --no-headers 2>/dev/null | wc -l)" = 0 ] && ok "no PersistentVolumes in the cluster (nothing to preserve on worker storage)"
fi

stage "4. Scale the EKS managed node group to 0"
if [ "$(ng_field scalingConfig.desiredSize)" != 0 ]; then
  wait_until 900 "node group ready for an update" ng_active
  aws eks update-nodegroup-config --cluster-name "$CLUSTER" --nodegroup-name "$NODEGROUP" \
    --scaling-config "minSize=0,maxSize=$NG_MAX,desiredSize=0" >/dev/null || die "update-nodegroup-config failed"
  ok "requested desired=0"
fi
wait_until 1500 "all worker instances terminated" no_asg_instances

stage "5. Stop Jenkins EC2 (root EBS volume with Jenkins home, plugins and builds is retained)"
STATE="$(ec2_state)"
VOL="$(aws ec2 describe-instances --instance-ids "$JENKINS_ID" --query 'Reservations[0].Instances[0].BlockDeviceMappings[0].Ebs.VolumeId' --output text | tr -d '\r')"
ok "Jenkins data volume $VOL ($(aws ec2 describe-volumes --volume-ids "$VOL" --query 'Volumes[0].[Size,VolumeType,Encrypted]' --output text | tr -d '\r' | tr '\t' ' '))"
case "$STATE" in
  running|pending) aws ec2 stop-instances --instance-ids "$JENKINS_ID" >/dev/null && log "stop requested";;
  stopped|stopping) ;;
  *) die "unexpected Jenkins EC2 state: $STATE";;
esac
wait_until 600 "Jenkins EC2 stopped" ec2_is stopped

stage "6. Stop RDS (storage and automated backups retained)"
STATE="$(rds_status)"
case "$STATE" in
  available) aws rds stop-db-instance --db-instance-identifier "$RDS_ID" >/dev/null && log "stop requested";;
  stopped|stopping) ;;
  *) die "RDS is '$STATE'; it can only be stopped from 'available' — re-run when it settles";;
esac
wait_until 1200 "RDS stopped" rds_is stopped
warn "AWS automatically starts a stopped RDS instance after 7 days (around $(json_get "$MANIFEST" rdsAutoRestartAfter | cut -c1-10)); re-run this script then to stop it again"

stage "7. Verify preserved resources"
[ "$(aws eks describe-cluster --name "$CLUSTER" --query cluster.status --output text | tr -d '\r')" = ACTIVE ] && ok "EKS cluster ACTIVE (node group definition kept: $(ng_field status))"
TAG="$(json_get "$MANIFEST" application.lastKnownGoodTag)"
for repo in order-inventory-backend order-inventory-frontend; do
  aws ecr describe-images --repository-name "$repo" --image-ids imageTag="$TAG" --query 'imageDetails[0].imageDigest' --output text >/dev/null 2>&1 && ok "ECR $repo:$TAG present" || die "ECR image $repo:$TAG missing"
done
for s in rds-master jenkins-admin sonarqube-admin; do
  aws secretsmanager describe-secret --secret-id "order-inventory/$s" --query Name --output text >/dev/null 2>&1 && ok "secret order-inventory/$s present" || die "secret order-inventory/$s missing"
done
aws s3api head-object --bucket "$STATE_BUCKET" --key order-inventory/terraform.tfstate >/dev/null 2>&1 && ok "Terraform state present in s3://$STATE_BUCKET"
LATEST_BACKUP="$(aws rds describe-db-instances --db-instance-identifier "$RDS_ID" --query 'DBInstances[0].LatestRestorableTime' --output text | tr -d '\r')"
ok "RDS point-in-time recovery available up to $LATEST_BACKUP"
[ "$(app_albs)" = 0 ] && ok "no application ALB remains" || die "an application ALB still exists"

print_cost_summary
echo
log "SUSPENDED. Restore with:  bash scripts/resume-evaluation.sh"
