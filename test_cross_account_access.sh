# Test script - run in trusted account
#!/bin/bash
test_cross_account_access() {
    local ROLE_ARN="arn:aws:iam::111122223333:role/CrossAccountDeveloperRole"
    local EXTERNAL_ID="your-external-id-here"
    
    echo "🧪 Testing cross-account access..."
    
    # Test 1: Verify current identity
    echo "Current identity:"
   AWSsts get-caller-identity
    
    # Test 2: Attempt role assumption
    echo "Attempting role assumption..."
    RESPONSE=$(aws sts assume-role \
        --role-arn "$ROLE_ARN" \
        --role-session-name "TestSession-$(date +%s)" \
        --external-id "$EXTERNAL_ID" \
        --duration-seconds 900 \
        2>&1) || {
        echo "❌ Role assumption failed: $RESPONSE"
        return 1
    }
    
    echo "✅ Role assumption successful!"
    
    # Test 3: Extract and test credentials
    ACCESS_KEY=$(echo "$RESPONSE" | jq -r '.Credentials.AccessKeyId')
    SECRET_KEY=$(echo "$RESPONSE" | jq -r '.Credentials.SecretAccessKey')
    SESSION_TOKEN=$(echo "$RESPONSE" | jq -r '.Credentials.SessionToken')
    
    # Test 4: Verify assumed role identity
    AWS_ACCESS_KEY_ID="$ACCESS_KEY" \
    AWS_SECRET_ACCESS_KEY="$SECRET_KEY" \
    AWS_SESSION_TOKEN="$SESSION_TOKEN" \
   AWSsts get-caller-identity
    
    echo "✅ All tests passed!"
}

test_cross_account_access
