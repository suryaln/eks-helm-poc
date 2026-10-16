# Secure 3-Tier Helm POC on AWS (EKS)

```
charts/
  common/      library chart  -> naming, labels, Deployment + Service templates
  frontend/    nginx-unprivileged (React stand-in)
  api/         node:alpine (Node API stand-in), DB config from Helm-injected env
  database/    postgres:16-alpine, StatefulSet + PVC (EBS gp3)
  threetier/   PARENT: dependencies, values.schema.json, ingress, NetworkPolicies,
               SecretProviderClass (AWS Secrets Manager), ServiceAccount (IRSA),
               pre-install/pre-upgrade migration hook
platform/
  eksctl-cluster.yaml          EKS + OIDC + VPC CNI network policy + EBS CSI
  storageclass-gp3.yaml
  clusterissuers.yaml          Let's Encrypt staging + prod, DNS-01 on Route 53
  iam/*.tpl                    IAM trust + permission policy templates
docs/RUNBOOK.md                end-to-end commands, demo script, rationale, Q&A
build.sh                       helm dependency update + lint
```
Start with docs/RUNBOOK.md.
