#!/usr/bin/env bash
# Packages sibling charts (common, frontend, api, database) into the umbrella chart, then lints.
set -euo pipefail
cd "$(dirname "$0")/charts"
helm dependency update threetier
helm lint threetier \
  --set irsa.roleArn=arn:aws:iam::123456789012:role/demo \
  --set secretsManager.secretName=demo/db \
  --set ingress.host=app.example.com
