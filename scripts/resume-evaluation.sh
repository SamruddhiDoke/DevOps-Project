#!/usr/bin/env bash
# Restore the environment suspended by scripts/suspend-evaluation.sh, verify it end to end and print
# the application URL. Safe to run repeatedly: every step checks the current state first.
#
#   bash scripts/resume-evaluation.sh
#
# Uses the recovery manifest docs/recovery/evaluation-manifest.json (no secrets). Does not run a
# full `terraform apply`, replace infrastructure or change database credentials. The only Terraform
# change it may make is a targeted update of the admin /32 (EKS API + Jenkins SG) when this
# machine's public IP has changed since the last run.
source "$(dirname "$0")/lib/evaluation-common.sh"

exec > >(tee -a "$LOG_DIR/resume-$(date +%Y%m%d-%H%M%S).log") 2>&1
T0=$SECONDS

preflight
[ -f "$MANIFEST" ] || die "recovery manifest $MANIFEST not found (it is written by suspend-evaluation.sh)"
TAG="$(json_get "$MANIFEST" application.lastKnownGoodTag)"
NG_DESIRED="$(json_get "$MANIFEST" eks.desiredSize)"; NG_MAX="$(json_get "$MANIFEST" eks.maxSize)"
NG_MIN_RUN=1   # minimum while running (Terraform's node_min_size is 0 only so the group can be suspended)
[ -n "$TAG" ] && [ "${NG_DESIRED:-0}" -ge 1 ] || die "manifest is incomplete (tag='$TAG', desired='$NG_DESIRED')"
for repo in order-inventory-backend order-inventory-frontend; do
  aws ecr describe-images --repository-name "$repo" --image-ids imageTag="$TAG" >/dev/null 2>&1 || die "ECR image $repo:$TAG not found"
done
ok "manifest: release $TAG, node group $NG_DESIRED node(s); both images present in ECR"

stage "1. Admin network access (EKS public API + Jenkins restricted to this machine's /32)"
MY_IP="$(curl -s --max-time 10 https://checkip.amazonaws.com | tr -d '\r\n ')"
[[ "$MY_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "could not determine this machine's public IP"
ALLOWED="$(aws eks describe-cluster --name "$CLUSTER" --query 'cluster.resourcesVpcConfig.publicAccessCidrs' --output text | tr -d '\r')"
if [[ " $(echo "$ALLOWED" | tr '\t' ' ') " == *" $MY_IP/32 "* ]]; then
  ok "current public IP is already allowed"
else
  warn "public IP changed: $MY_IP/32 is not in the allowed list; updating admin.auto.tfvars and applying a targeted change"
  TFV="$REPO_ROOT/terraform/admin.auto.tfvars"
  [ -f "$TFV" ] && cp "$TFV" "$TFV.bak"
  printf '# Local, git-ignored: your current public IP (updated by resume-evaluation.sh %s)\nadmin_cidr_blocks = ["%s/32"]\n' "$(date +%F)" "$MY_IP" > "$TFV"
  PLAN="$LOG_DIR/admin-ip.tfplan"
  terraform -chdir="$TF_DIR" plan -input=false -no-color -var-file=environments/full.tfvars -var-file=admin.auto.tfvars \
    -target=aws_eks_cluster.main -target=aws_vpc_security_group_ingress_rule.jenkins_ssh -target=aws_vpc_security_group_ingress_rule.jenkins_web \
    -out="$(win_path "$PLAN")" > "$LOG_DIR/admin-ip-plan.txt" 2>&1 || die "targeted terraform plan failed (see $LOG_DIR/admin-ip-plan.txt)"
  # Accept only: in-place update of the cluster, create/delete of the admin SG rules
  terraform -chdir="$TF_DIR" show -json "$(win_path "$PLAN")" | node -e '
    let d="";process.stdin.on("data",c=>d+=c).on("end",()=>{
      const bad=(JSON.parse(d).resource_changes||[]).filter(r=>{const a=r.change.actions.join(",");
        if(a==="no-op"||a==="read")return false;
        if(r.address==="aws_eks_cluster.main")return a!=="update";
        return !/^aws_vpc_security_group_ingress_rule\.jenkins_(ssh|web)\[/.test(r.address);});
      if(bad.length){console.error("unexpected changes: "+bad.map(r=>r.address+" "+r.change.actions).join("; "));process.exit(1)}})' \
    || die "targeted plan contains unexpected changes; not applied (see $LOG_DIR/admin-ip-plan.txt)"
  grep -E "^\s+[~+-] |Plan:" "$LOG_DIR/admin-ip-plan.txt"
  terraform -chdir="$TF_DIR" apply -input=false -no-color "$(win_path "$PLAN")" > "$LOG_DIR/admin-ip-apply.txt" 2>&1 \
    || die "targeted terraform apply failed (see $LOG_DIR/admin-ip-apply.txt)"
  ok "admin access updated to $MY_IP/32"
fi

stage "2. Start RDS, Jenkins EC2 and the EKS node group (in parallel)"
case "$(rds_status)" in
  stopped) aws rds start-db-instance --db-instance-identifier "$RDS_ID" >/dev/null && log "RDS start requested";;
  available|starting|configuring-enhanced-monitoring|backing-up|modifying) log "RDS is $(rds_status)";;
  stopping) wait_until 1200 "RDS finished stopping" rds_is stopped
            aws rds start-db-instance --db-instance-identifier "$RDS_ID" >/dev/null && log "RDS start requested";;
  *) die "unexpected RDS state: $(rds_status)";;
esac
case "$(ec2_state)" in
  stopped) aws ec2 start-instances --instance-ids "$JENKINS_ID" >/dev/null && log "Jenkins EC2 start requested";;
  running|pending) log "Jenkins EC2 is $(ec2_state)";;
  stopping) wait_until 600 "Jenkins EC2 finished stopping" ec2_is stopped
            aws ec2 start-instances --instance-ids "$JENKINS_ID" >/dev/null && log "Jenkins EC2 start requested";;
  *) die "unexpected Jenkins EC2 state: $(ec2_state)";;
esac
if [ "$(ng_field scalingConfig.desiredSize)" -lt "$NG_DESIRED" ]; then
  wait_until 900 "node group ready for an update" ng_active
  aws eks update-nodegroup-config --cluster-name "$CLUSTER" --nodegroup-name "$NODEGROUP" \
    --scaling-config "minSize=$NG_MIN_RUN,maxSize=$NG_MAX,desiredSize=$NG_DESIRED" >/dev/null || die "update-nodegroup-config failed"
  log "node group scale-up to $NG_DESIRED requested"
else
  log "node group desired size already $(ng_field scalingConfig.desiredSize)"
fi

stage "3. Kubernetes nodes and cluster add-ons"
ensure_kube_access
nodes_ready() { [ "$(kubectl get nodes --no-headers 2>/dev/null | awk '$2=="Ready"' | wc -l)" -ge "$NG_DESIRED" ]; }
wait_until 1200 "$NG_DESIRED node(s) Ready" nodes_ready
kubectl get nodes -o wide | sed 's/^/    /'
for r in deploy/coredns deploy/aws-load-balancer-controller ds/aws-node ds/kube-proxy; do
  kubectl -n kube-system rollout status "$r" --timeout=600s >/dev/null 2>&1 || die "kube-system $r not ready"
  ok "kube-system $r ready"
done
kubectl -n "$NAMESPACE" get secret mysql-secret >/dev/null 2>&1 || die "Kubernetes secret mysql-secret missing (run scripts/create-db-secret.sh)"
ok "namespace $NAMESPACE and mysql-secret present"

stage "4. Database"
wait_until 1500 "RDS available" rds_is available

stage "5. Application release $TAG (Helm, chart defaults: 2+2 replicas, Ingress enabled)"
CUR="$(kubectl -n "$NAMESPACE" get deploy backend -o jsonpath='{.spec.replicas} {.spec.template.spec.containers[0].image}' 2>/dev/null || true)"
ING="$(kubectl -n "$NAMESPACE" get ingress order-inventory-ingress -o name 2>/dev/null || true)"
if [ "$CUR" = "2 $REGISTRY/order-inventory-backend:$TAG" ] && [ -n "$ING" ] \
   && [ "$(kubectl -n "$NAMESPACE" get deploy backend frontend -o jsonpath='{.items[*].status.readyReplicas}')" = "2 2" ]; then
  ok "release already running $TAG with Ingress"
else
  ROLLOUT_TIMEOUT=10m "$REPO_ROOT/scripts/deploy-k8s.sh" "$REGISTRY" "$TAG" || die "Helm deployment of $TAG failed (deploy-k8s.sh rolled back if possible)"
fi

stage "6. Application Load Balancer"
alb_hostname() { kubectl -n "$NAMESPACE" get ingress order-inventory-ingress -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null; }
has_alb_hostname() { [ -n "$(alb_hostname)" ]; }
wait_until 600 "Ingress has an ALB hostname" has_alb_hostname
ALB="$(alb_hostname)"
URL="http://$ALB"
alb_active() { aws elbv2 describe-load-balancers --query "LoadBalancers[?DNSName=='$ALB'].State.Code" --output text 2>/dev/null | grep -q '^active'; }
wait_until 600 "ALB active" alb_active
tgs_healthy() {
  local arn bad=0 n=0
  for arn in $(aws elbv2 describe-target-groups --query "TargetGroups[?starts_with(TargetGroupName,'k8s-orderinv')].TargetGroupArn" --output text | tr -d '\r'); do
    n=$((n + 1))
    bad=$((bad + $(aws elbv2 describe-target-health --target-group-arn "$arn" --query "length(TargetHealthDescriptions[?TargetHealth.State!='healthy'])" --output text | tr -d '\r')))
    [ "$(aws elbv2 describe-target-health --target-group-arn "$arn" --query 'length(TargetHealthDescriptions)' --output text | tr -d '\r')" -ge 2 ] || bad=$((bad + 1))
  done
  [ "$n" -ge 2 ] && [ "$bad" = 0 ]
}

wait_until 900 "both ALB target groups have >=2 healthy targets" tgs_healthy
wait_until 600 "$URL/api/health returns 200 (DNS propagation)" http_200 "$URL/api/health"

stage "7. Database connectivity, migrations and smoke tests"
for p in /api/health /api/health/ready /; do
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$URL$p")"
  [ "$code" = 200 ] && ok "GET $p -> 200" || die "GET $URL$p returned $code"
done
# Backend logs are JSON (ECS); print only the Flyway messages
FLYWAY="$(kubectl -n "$NAMESPACE" logs deploy/backend --tail=-1 2>/dev/null | grep 'org.flywaydb' | sed -nE 's/.*"message":"([^"]*)".*/\1/p' | tail -3)"
[ -n "$FLYWAY" ] && { ok "Flyway:"; echo "$FLYWAY" | sed 's/^/      /'; } || warn "no Flyway lines in the current backend log (readiness already confirms DB access)"
"$REPO_ROOT/scripts/smoke-test.sh" "$URL" || die "read/write smoke test failed against $URL"

stage "8. ALB alarms (recreated for the new ALB)"
if "$REPO_ROOT/scripts/create-alb-alarms.sh" >/dev/null 2>&1; then
  ok "ALB alarms: $(aws cloudwatch describe-alarms --alarm-name-prefix order-inventory-alb --query 'length(MetricAlarms)' --output text | tr -d '\r') present"
else
  warn "create-alb-alarms.sh failed; run it manually (the application itself is healthy)"
fi

stage "9. Logging (ELK, private: access via kubectl port-forward only)"
if kubectl get ns logging >/dev/null 2>&1; then
  kubectl -n logging scale deploy elasticsearch kibana --replicas=1 >/dev/null
  kubectl -n logging rollout status deploy/elasticsearch --timeout=600s >/dev/null 2>&1 || die "Elasticsearch not ready"
  kubectl -n logging rollout status deploy/kibana --timeout=600s >/dev/null 2>&1 || die "Kibana not ready"
  kubectl -n logging rollout status ds/filebeat --timeout=300s >/dev/null 2>&1 || die "Filebeat not ready"
  ok "Elasticsearch, Kibana and Filebeat ready"
  kubectl -n logging port-forward svc/kibana 15601:5601 >/dev/null 2>&1 &
  PF=$!
  KIBANA=""
  for _ in $(seq 1 18); do
    KIBANA="$(curl -s --max-time 5 http://127.0.0.1:15601/api/status | node -e 'let d="";process.stdin.on("data",c=>d+=c).on("end",()=>{try{console.log(JSON.parse(d).status.overall.level)}catch{}})' 2>/dev/null)"
    [ "$KIBANA" = available ] && break; sleep 10
  done
  kill "$PF" 2>/dev/null; wait "$PF" 2>/dev/null
  [ "$KIBANA" = available ] && ok "Kibana /api/status: available (via port-forward)" || die "Kibana status is '${KIBANA:-unreachable}'"
else
  warn "namespace logging not present; ELK not deployed (kubectl apply -f k8s/logging/elk.yaml)"
fi

stage "10. Jenkins (restricted to the admin /32)"
wait_until 600 "Jenkins EC2 running" ec2_is running
JIP="$(aws ec2 describe-instances --instance-ids "$JENKINS_ID" --query 'Reservations[0].Instances[0].PublicIpAddress' --output text | tr -d '\r')"
wait_until 600 "Jenkins http://$JIP:8080/login returns 200" http_200 "http://$JIP:8080/login"
OPEN="$(aws ec2 describe-security-groups --group-ids "$(aws ec2 describe-instances --instance-ids "$JENKINS_ID" --query 'Reservations[0].Instances[0].SecurityGroups[0].GroupId' --output text | tr -d '\r')" \
  --query "length(SecurityGroups[0].IpPermissions[].IpRanges[?CidrIp=='0.0.0.0/0'][])" --output text | tr -d '\r')"
[ "$OPEN" = 0 ] && ok "Jenkins security group has no 0.0.0.0/0 ingress" || die "Jenkins security group is open to the internet"

stage "11. Update recovery manifest"
node -e '
  const fs=require("fs"),[f,url,jip]=process.argv.slice(1);const m=JSON.parse(fs.readFileSync(f,"utf8"));
  m.resumedAt=new Date().toISOString();m.application.currentUrl=url;m.jenkins.publicIpAtResume=jip;delete m.rdsAutoRestartAfter;
  fs.writeFileSync(f,JSON.stringify(m,null,2)+"\n");' "$(win_path "$MANIFEST")" "$URL" "$JIP"
ok "manifest updated"

ELAPSED=$((SECONDS - T0))
cat <<EOF

=====================================================================
 ENVIRONMENT RESTORED AND VERIFIED in $((ELAPSED / 60))m $((ELAPSED % 60))s
   Application : $URL
   Release     : $TAG (Helm release $RELEASE, namespace $NAMESPACE)
   Checks      : nodes Ready, add-ons ready, RDS available, 2/2 backend + 2/2 frontend,
                 ALB targets healthy, health/readiness 200, read/write smoke test passed,
                 ELK ready, Jenkins /login 200
   Jenkins     : http://$JIP:8080   (admin /32 only; password: Secrets Manager order-inventory/jenkins-admin)
   Kibana      : kubectl -n logging port-forward svc/kibana 5601:5601  ->  http://localhost:5601
   Note        : the ALB hostname and Jenkins IP can differ from the previous run.
   Suspend     : bash scripts/suspend-evaluation.sh
=====================================================================
EOF
