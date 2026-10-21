# AWS (EKS) Runbook, Demo Script and Rationale

Tools: awscli v2, eksctl, kubectl, helm 3, envsubst (gettext), openssl.

## 0. Variables
```bash
export REGION=us-east-1 CLUSTER=helm-poc
export DOMAIN=example.com HOST=app.example.com
export NS=threetier REL=threetier
export EMAIL=you@example.com
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
```

## 1. EKS cluster
```bash
# edit region/version in platform/eksctl-cluster.yaml first
eksctl create cluster -f platform/eksctl-cluster.yaml     #check physical machine before running (need to give values threetier/values.yaml)
kubectl apply -f platform/storageclass-gp3.yaml 
export OIDC_HOST=$(aws eks describe-cluster --name $CLUSTER --region $REGION \
  --query cluster.identity.oidc.issuer --output text | sed 's#https://##')
```
Why: `withOIDC` enables IRSA; `enableNetworkPolicy` makes the VPC CNI enforce NetworkPolicy (otherwise policies are accepted but ignored); the EBS CSI addon is required for PVCs on current EKS versions.

## 2. Secrets Manager + IAM role for the app (IRSA)
```bash
# one secret, JSON, no special URL characters in the password (it ends up inside DATABASE_URL)
SECRET_ARN=$(aws secretsmanager create-secret --name helm-poc/db --region $REGION \
  --secret-string "{\"username\":\"appuser\",\"password\":\"$(openssl rand -hex 16)\"}" \
  --query ARN --output text)
export SECRET_ARN

export SA_NAMESPACE=$NS SA_NAME=$REL-workload     # must match the Helm-created ServiceAccount
envsubst < platform/iam/trust-policy.json.tpl > /tmp/trust-app.json
envsubst < platform/iam/app-secrets-policy.json.tpl > /tmp/app-policy.json

aws iam create-role --role-name helm-poc-app --assume-role-policy-document file:///tmp/trust-app.json
POLICY_ARN=$(aws iam create-policy --policy-name helm-poc-app-secrets \
  --policy-document file:///tmp/app-policy.json --query Policy.Arn --output text)
aws iam attach-role-policy --role-name helm-poc-app --policy-arn $POLICY_ARN
export APP_ROLE_ARN=arn:aws:iam::$ACCOUNT_ID:role/helm-poc-app
```

/* "Federated": "arn:aws:iam::123456789012:oidc-provider/oidc.eks.ap-south-1.amazonaws.com/id/EXAMPLED5E1802C54D21A3170100FF51"

This means only the Pods running in the threetier namespace using the 
threetier-workload ServiceAccount (specifically, your API and CSI pods) are allowed to assume the role 
*/

The trust policy pins the role to ONE ServiceAccount (`system:serviceaccount:<ns>:<name>`) and audience `sts.amazonaws.com`; the permission policy allows reading ONE secret (least privilege).

## 3. Secrets Store CSI driver + AWS provider
```bash
helm repo add secrets-store-csi-driver https://kubernetes-sigs.github.io/secrets-store-csi-driver/charts

# The Secrets Store CSI Driver is a vendor-neutral Kubernetes SIG project that manages the lifecycle of
# pod volume mounts and native secret synchronization (syncSecret.enabled=true). It delegates the actual
# cloud authentication and retrieval logic to provider plugins via gRPC.

helm repo add aws-secrets-manager https://aws.github.io/secrets-store-csi-driver-provider-aws

# aws-secrets-manager provider is the AWS-specific plugin required to speak to AWS STS and AWS Secrets
# Manager using IRSA. Without both components running as DaemonSets on the node, the CSI driver cannot fetch secrets from AWS

helm repo update
helm install csi-secrets-store secrets-store-csi-driver/secrets-store-csi-driver -n kube-system \
  --set syncSecret.enabled=true --set enableSecretRotation=true
helm install secrets-provider-aws aws-secrets-manager/secrets-store-csi-driver-provider-aws -n kube-system
```
`syncSecret.enabled=true` is mandatory: it is what lets `secretObjects` create the Kubernetes Secret that the env vars reference.

## 4. NGINX ingress controller on an NLB
```bash
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx && helm repo update
helm install ingress-nginx ingress-nginx/ingress-nginx -n ingress-nginx --create-namespace \
  --set controller.service.annotations."service\.beta\.kubernetes\.io/aws-load-balancer-type"=nlb \
  --set controller.service.annotations."service\.beta\.kubernetes\.io/aws-load-balancer-cross-zone-load-balancing-enabled"=true
kubectl get svc -n ingress-nginx ingress-nginx-controller -w     # wait for EXTERNAL-IP (NLB DNS name)
```
(If you install the AWS Load Balancer Controller, use `aws-load-balancer-type=external` and `aws-load-balancer-nlb-target-type=ip` instead.)

## 5. Route 53 zone and alias record
```bash
HZ_ID=$(aws route53 create-hosted-zone --name $DOMAIN --caller-reference $(date +%s) \
  --query HostedZone.Id --output text | sed 's#/hostedzone/##'); export HOSTED_ZONE_ID=$HZ_ID
aws route53 get-hosted-zone --id $HZ_ID --query DelegationSet.NameServers   # set these NS at your registrar

NLB_DNS=$(kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
NLB_ZONE=$(aws elbv2 describe-load-balancers --region $REGION \
  --query "LoadBalancers[?DNSName=='$NLB_DNS'].CanonicalHostedZoneId" --output text)
cat > /tmp/record.json <<JSON
{"Changes":[{"Action":"UPSERT","ResourceRecordSet":{"Name":"$HOST","Type":"A",
 "AliasTarget":{"HostedZoneId":"$NLB_ZONE","DNSName":"$NLB_DNS","EvaluateTargetHealth":false}}}]}
JSON
aws route53 change-resource-record-sets --hosted-zone-id $HZ_ID --change-batch file:///tmp/record.json
```
Public delegation: the NS records at your registrar must point to the Route 53 name servers, otherwise Let's Encrypt cannot validate. (If the domain was bought in Route 53, this is automatic only for the auto-created zone; check.) An Alias record is used because an NLB has a DNS name, not a fixed IP.

## 6. cert-manager with Route 53 (IRSA)
```bash
export SA_NAMESPACE=cert-manager SA_NAME=cert-manager
envsubst < platform/iam/trust-policy.json.tpl > /tmp/trust-cm.json
envsubst < platform/iam/certmanager-route53-policy.json.tpl > /tmp/cm-policy.json
aws iam create-role --role-name helm-poc-certmanager --assume-role-policy-document file:///tmp/trust-cm.json
CM_POLICY_ARN=$(aws iam create-policy --policy-name helm-poc-certmanager-route53 \
  --policy-document file:///tmp/cm-policy.json --query Policy.Arn --output text)
aws iam attach-role-policy --role-name helm-poc-certmanager --policy-arn $CM_POLICY_ARN
CM_ROLE_ARN=arn:aws:iam::$ACCOUNT_ID:role/helm-poc-certmanager

helm repo add jetstack https://charts.jetstack.io && helm repo update
helm install cert-manager jetstack/cert-manager -n cert-manager --create-namespace \
  --set crds.enabled=true --set securityContext.fsGroup=1001 \
  --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"=$CM_ROLE_ARN

# put your email + $HOSTED_ZONE_ID into platform/clusterissuers.yaml, then:
kubectl apply -f platform/clusterissuers.yaml
kubectl get clusterissuer
```
`fsGroup=1001` lets the non-root cert-manager process read the projected IRSA token.

## 7. Deploy the application
```bash
./build.sh
kubectl create ns $NS
helm upgrade --install $REL charts/threetier -n $NS --wait --timeout 5m \
  --set irsa.roleArn=$APP_ROLE_ARN \
  --set secretsManager.secretName=helm-poc/db --set secretsManager.region=$REGION \
  --set ingress.host=$HOST \
  --set ingress.tls.clusterIssuer=letsencrypt-staging      # switch to letsencrypt-prod once Ready
```
Verify
```bash
kubectl get pods,svc,pvc,ingress,certificate -n $NS
kubectl logs job/$REL-db-migrate -n $NS
curl -I http://$HOST                      # 308 -> https
curl -k https://$HOST/                    # nginx page (-k only for staging cert)
curl -k https://$HOST/api/health          # JSON from the Node stand-in
kubectl exec -n $NS deploy/$REL-api -- sh -c 'echo $DATABASE_URL | sed "s/:.*@/:***@/"'
kubectl get secret $REL-db-credentials -n $NS      # synced from Secrets Manager
```
Go prod: `helm upgrade ... --set ingress.tls.clusterIssuer=letsencrypt-prod` then `kubectl delete secret threetier-tls -n $NS` to force re-issue.

## 8. Demo script (about 50 min)
1. (5m) Architecture: Internet -> Route 53 alias -> NLB -> NGINX (TLS) -> `/` frontend, `/api` api -> postgres (EBS PVC). Side flows: Secrets Manager -> CSI -> K8s Secret; cert-manager -> Route 53 TXT -> Let's Encrypt.
2. (8m) Chart tour: library chart, parent dependencies + conditions, `_helpers.tpl`, `helm template`.
3. (5m) Schema negative tests (below).
4. (5m) Hook: `helm upgrade` while running `kubectl get jobs -w`; job logs complete before API pods roll.
5. (7m) Security: IRSA (SA annotation, trust policy sub condition, no keys in repo), SecretProviderClass, pod securityContext.
6. (5m) NetworkPolicy proof.
7. (7m) TLS: `kubectl describe certificate`, padlock, redirect, renewal (cert-manager renews about 30 days before the 90-day expiry; show `spec.renewBefore` / `status.renewalTime`).
8. (8m) Q&A + runtime changes.

### Negative tests (each must fail)
```bash
BASE="--set irsa.roleArn=arn:aws:iam::123456789012:role/x --set secretsManager.secretName=x/y --set ingress.host=app.example.com"
helm template t charts/threetier $BASE --set api.resources.limits=null         # missing limits
helm template t charts/threetier $BASE --set api.replicaCount=abc              # wrong type
helm template t charts/threetier $BASE --set api.resources.limits.memory=lots  # invalid quantity
helm template t charts/threetier $BASE --set database.replicaCount=3           # max 1
helm template t charts/threetier $BASE --set ingress.host=                     # host required
helm template t charts/threetier $BASE --set irsa.roleArn=not-an-arn           # arn pattern
```
### Toggle tests
```bash
helm template t charts/threetier $BASE --set frontend.enabled=false | grep -ci frontend
helm upgrade $REL charts/threetier -n $NS --reuse-values --set database.enabled=false \
  --set api.dbHost=mydb.xxxx.us-east-1.rds.amazonaws.com
```
### NetworkPolicy proof
```bash
kubectl run tmp -n $NS --rm -it --image=postgres:16-alpine --restart=Never -- pg_isready -h $REL-database -t 3   # blocked
kubectl exec -n $NS deploy/$REL-api -- nc -zv $REL-database 5432                                                # allowed
```

## 9. Design rationale
| Choice | Why |
|---|---|
| EKS + managed node group | AWS-managed control plane and node lifecycle; fastest path to a real cluster |
| Umbrella + library chart | One release/values file, tier toggles, no copy-paste; satisfies "no unlinked charts" |
| values.schema.json | Fails at render time; guarantees limits/requests on every enabled tier |
| Pre-install/upgrade hook | Migrations finish before new API code serves traffic |
| Secrets Manager + CSI (ASCP) | Secrets stay in AWS (KMS-encrypted, auditable in CloudTrail, rotatable); nothing in git or values |
| IRSA | Short-lived STS credentials via OIDC; role bound to a single namespace/ServiceAccount; no access keys |
| Synced K8s Secret | Lets the API use plain `secretKeyRef` env vars |
| Default-deny + allow-list NetworkPolicy | Zero-trust inside the cluster; DB reachable only from API |
| ingress-nginx on NLB | L4 NLB preserves client IP and scales; NGINX does path routing and TLS termination |
| Route 53 + Alias | Managed DNS, alias to NLB works at apex and is free of query charges for alias to AWS resources |
| cert-manager DNS-01 | Auto issue/renew, no inbound port-80 dependency, supports wildcards; IRSA means no DNS credentials |
| Staging issuer first | Avoids Let's Encrypt prod rate limits |
| EBS gp3 PVC (StatefulSet) | Encrypted block storage, cheaper/faster baseline than gp2; WaitForFirstConsumer binds in the pod's AZ |
| Non-root, drop ALL caps, seccomp | Pod Security `restricted` alignment |

## 10. Honest caveats
- **Hook ordering:** `pre-install` hooks run before any release resource exists (no DB, SA, SPC). Here the Job only simulates migrations and needs neither. For real migrations: `post-install` for first install plus `pre-upgrade`, or ordered hook resources, or an external RDS (then pre-install works).
- **Postgres in a container** is POC-only; production would use Amazon RDS/Aurora PostgreSQL (`database.enabled=false` + `api.dbHost`).
- **EBS volumes are AZ-bound** (RWO): the pod can only reschedule in the same AZ.
- **TLS ends at NGINX**; the in-cluster hop is HTTP. Full east-west encryption needs a service mesh with mTLS or HTTPS backends.
- **Only ingress policies** are defined; add egress rules for stricter posture.
- **Secret rotation:** rotation updates the mounted file, but env vars need a rollout restart.
- **Pod Identity** (`aws eks create-pod-identity-association`) is the newer alternative to IRSA; the ASCP provider supports it, check the provider docs for the exact parameter.
- Real images: build and push to **ECR**; node role already has ECR pull permissions.

## 11. Likely runtime-change requests
| Request | Change |
|---|---|
| Scale API | `helm upgrade --reuse-values --set api.replicaCount=4` |
| New route | add an item to `ingress.paths` in values |
| Disable frontend | `--set frontend.enabled=false` |
| Tighten limits | edit `api.resources`; schema rejects invalid quantities |
| Force cert renewal | `cmctl renew <cert> -n $NS` or delete `threetier-tls` secret |
| Rotate DB password | `aws secretsmanager put-secret-value ...` then `kubectl rollout restart` (also update the DB role password) |
| Rollback | `helm history $REL -n $NS`, `helm rollback $REL 1 -n $NS` |
| Per-env config | `-f values-dev.yaml` / `values-prod.yaml` |
| HPA/PDB | new template in `common` + toggle |

## 12. Troubleshooting
- Pod `ContainerCreating` with SecretProviderClass errors / `AccessDenied` / `WebIdentityErr`: check the role trust `sub` equals `system:serviceaccount:<ns>:<release>-workload`, SA annotation, OIDC provider exists (`eksctl utils associate-iam-oidc-provider --cluster $CLUSTER --approve`), and the CSI driver has `syncSecret.enabled=true`.
- PVC `Pending`: EBS CSI addon missing or StorageClass `gp3` not applied; `kubectl describe pvc`.
- Certificate not Ready: `kubectl describe certificate,certificaterequest,order,challenge -n $NS`; check NS delegation, hosted zone ID, cert-manager role policy and logs.
- 503 from ingress: `kubectl get endpoints -n $NS`; verify the ingress namespace label matches `networkPolicy.ingressControllerNamespace`.
- NetworkPolicy not enforced: confirm `kubectl get ds aws-node -n kube-system` shows network policy agent, and vpc-cni addon config has `enableNetworkPolicy: "true"`.

## 13. Cleanup (avoid charges)
```bash
helm uninstall $REL -n $NS && helm uninstall ingress-nginx -n ingress-nginx   # deletes the NLB
aws route53 change-resource-record-sets ...   # delete the alias record, then: aws route53 delete-hosted-zone --id $HZ_ID
aws secretsmanager delete-secret --secret-id helm-poc/db --force-delete-without-recovery
eksctl delete cluster -f platform/eksctl-cluster.yaml
# delete IAM roles/policies created above
```
