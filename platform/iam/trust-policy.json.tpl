{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Federated": "arn:aws:iam::${ACCOUNT_ID}:oidc-provider/${OIDC_HOST}"},
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {"StringEquals": {
      "${OIDC_HOST}:aud": "sts.amazonaws.com",
      "${OIDC_HOST}:sub": "system:serviceaccount:${SA_NAMESPACE}:${SA_NAME}"
    }}
  }]
}
