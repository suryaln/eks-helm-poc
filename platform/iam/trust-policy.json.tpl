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

/* "Federated": "arn:aws:iam::123456789012:oidc-provider/oidc.eks.ap-south-1.amazonaws.com/id/EXAMPLED5E1802C54D21A3170100FF51"

This means only the Pods running in the threetier namespace using the 
threetier-workload ServiceAccount (specifically, your API and CSI pods) are allowed to assume the role 
*/
