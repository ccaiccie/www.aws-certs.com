#!/bin/bash
# complete_cross_account_setup.sh - Full implementation script

set -euo pipefail

# Configuration
TRUSTING_ACCOUNT="111122223333"
TRUSTED_ACCOUNT="444455556666"
ROLE_NAME="CrossAccountDeveloperRole"
USER_NAME="DevUser"
EXTERNAL_ID="$(openssl rand -hex 16)"  # Generate random ExternalId
SESSION_DURATION="3600"

echo "🚀 Starting cross-account setup between accounts $TRUSTED_ACCOUNT → $TRUSTING_ACCOUNT"
echo "📝 Generated ExternalId: $EXTERNAL_ID (save this securely!)"

# Phase 1: Create trust policy
cat > trust-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "AWS": "arn:aws:iam::$TRUSTED_ACCOUNT:user/$USER_NAME"
      },
      "Action": "sts:AssumeRole",
      "Condition": {
        "StringEquals": {
          "sts:ExternalId": "$EXTERNAL_ID"
        },
        "Bool": {
          "aws:MultiFactorAuthPresent": "true"
        },
        "NumericLessThan": {
          "aws:MultiFactorAuthAge": "3600"
        }
      }
    }
  ]
}
EOF

# Phase 2: Create role in trusting account
echo "📋 Creating role in trusting account..."
aws iam create-role \
    --role-name "$ROLE_NAME" \
    --assume-role-policy-document file://trust-policy.json \
    --description "Cross-account role for $TRUSTED_ACCOUNT" \
    --max-session-duration "$SESSION_DURATION"

# Phase 3: Attach permissions
echo "🔑 Attaching permissions..."
aws iam attach-role-policy \
    --role-name "$ROLE_NAME" \
    --policy-arn arn:aws:iam::aws:policy/ReadOnlyAccess

# Phase 4: Create assume role policy for trusted account
cat > assume-role-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": "sts:AssumeRole",
      "Resource": "arn:aws:iam::$TRUSTING_ACCOUNT:role/$ROLE_NAME",
      "Condition": {
        "StringEquals": {
          "sts:ExternalId": "$EXTERNAL_ID"
        }
      }
    }
  ]
}
EOF

echo "✅ Setup complete!"
echo "📋 Next steps:"
echo "   1. Switch to account $TRUSTED_ACCOUNT"
echo "   2. Create user '$USER_NAME' if not exists"
echo "   3. Attach the assume-role-policy.json to the user"
echo "   4. Test with:AWSsts assume-role --role-arn arn:aws:iam::$TRUSTING_ACCOUNT:role/$ROLE_NAME --role-session-name TestSession --external-id $EXTERNAL_ID"

# Cleanup
rm -f trust-policy.json assume-role-policy.json
                
