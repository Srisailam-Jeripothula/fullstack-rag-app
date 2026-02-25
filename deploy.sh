#!/bin/bash
# =======================================================
# Full-Stack RAG App - AWS Deployment Script
# Run this from the root of the repo in AWS CloudShell
# or any machine with AWS CLI configured
# =======================================================
set -e

# ===================== CONFIGURATION =====================
# FILL THESE IN BEFORE RUNNING
OPENAI_API_KEY="YOUR_OPENAI_API_KEY"
PINECONE_API_KEY="YOUR_PINECONE_API_KEY"
PINECONE_INDEX="rag-pdf-index"
AWS_REGION="ap-south-1"
S3_BUCKET="fullstack-rag-bucket-$(date +%s)"
INGEST_FUNCTION="rag-ingest"
QUERY_FUNCTION="rag-query"
FRONTEND_BUCKET="fullstack-rag-frontend-$(date +%s)"
LAMBDA_ROLE_NAME="rag-lambda-role"
# =========================================================

echo "========================================"
echo "  Full-Stack RAG App Deployment"
echo "========================================"

# Step 1: Create S3 bucket for PDFs
echo ""
echo "[1/8] Creating S3 bucket for PDFs: $S3_BUCKET"
aws s3 mb s3://$S3_BUCKET --region $AWS_REGION
echo "Done."

# Step 2: Create IAM role for Lambda
echo ""
echo "[2/8] Creating IAM role: $LAMBDA_ROLE_NAME"
TRUST_POLICY='{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Service": "lambda.amazonaws.com"},
    "Action": "sts:AssumeRole"
  }]
}'

ROLE_ARN=$(aws iam create-role \
  --role-name $LAMBDA_ROLE_NAME \
  --assume-role-policy-document "$TRUST_POLICY" \
  --query 'Role.Arn' --output text 2>/dev/null || \
  aws iam get-role --role-name $LAMBDA_ROLE_NAME --query 'Role.Arn' --output text)

aws iam attach-role-policy --role-name $LAMBDA_ROLE_NAME \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
aws iam put-role-policy --role-name $LAMBDA_ROLE_NAME \
  --policy-name s3-access \
  --policy-document "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":[\"s3:GetObject\",\"s3:PutObject\",\"s3:ListBucket\"],\"Resource\":[\"arn:aws:s3:::$S3_BUCKET\",\"arn:aws:s3:::$S3_BUCKET/*\"]}]}"
echo "Role ARN: $ROLE_ARN"
sleep 10  # Wait for IAM propagation

# Step 3: Build and deploy Ingest Lambda
echo ""
echo "[3/8] Building Ingest Lambda package"
mkdir -p /tmp/ingest_build
cp backend/ingest/handler.py /tmp/ingest_build/
pip install -r backend/ingest/requirements.txt \
  --target /tmp/ingest_build \
  --platform manylinux2014_x86_64 \
  --python-version 3.12 \
  --only-binary=:all: -q
cd /tmp/ingest_build && zip -r /tmp/ingest.zip . -q && cd -

echo "Deploying Ingest Lambda: $INGEST_FUNCTION"
aws lambda create-function \
  --function-name $INGEST_FUNCTION \
  --runtime python3.12 \
  --role $ROLE_ARN \
  --handler handler.lambda_handler \
  --zip-file fileb:///tmp/ingest.zip \
  --timeout 300 \
  --memory-size 512 \
  --region $AWS_REGION \
  --environment "Variables={OPENAI_API_KEY=$OPENAI_API_KEY,PINECONE_API_KEY=$PINECONE_API_KEY,PINECONE_INDEX=$PINECONE_INDEX,EMBEDDING_MODEL=text-embedding-3-small,CHUNK_SIZE=1000}" 2>/dev/null || \
aws lambda update-function-code \
  --function-name $INGEST_FUNCTION \
  --zip-file fileb:///tmp/ingest.zip \
  --region $AWS_REGION

# Step 4: Add S3 trigger to Ingest Lambda
echo ""
echo "[4/8] Adding S3 trigger to Ingest Lambda"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
aws lambda add-permission \
  --function-name $INGEST_FUNCTION \
  --statement-id s3-trigger \
  --action lambda:InvokeFunction \
  --principal s3.amazonaws.com \
  --source-arn arn:aws:s3:::$S3_BUCKET \
  --region $AWS_REGION 2>/dev/null || true

aws s3api put-bucket-notification-configuration \
  --bucket $S3_BUCKET \
  --notification-configuration "{\"LambdaFunctionConfigurations\":[{\"LambdaFunctionArn\":\"arn:aws:lambda:$AWS_REGION:$ACCOUNT_ID:function:$INGEST_FUNCTION\",\"Events\":[\"s3:ObjectCreated:*\"],\"Filter\":{\"Key\":{\"FilterRules\":[{\"Name\":\"suffix\",\"Value\":\".pdf\"}]}}}]}"

# Step 5: Build and deploy Query Lambda
echo ""
echo "[5/8] Building Query Lambda package"
mkdir -p /tmp/query_build
cp backend/query/handler.py /tmp/query_build/
pip install -r backend/query/requirements.txt \
  --target /tmp/query_build \
  --platform manylinux2014_x86_64 \
  --python-version 3.12 \
  --only-binary=:all: -q
cd /tmp/query_build && zip -r /tmp/query.zip . -q && cd -

echo "Deploying Query Lambda: $QUERY_FUNCTION"
aws lambda create-function \
  --function-name $QUERY_FUNCTION \
  --runtime python3.12 \
  --role $ROLE_ARN \
  --handler handler.lambda_handler \
  --zip-file fileb:///tmp/query.zip \
  --timeout 60 \
  --memory-size 256 \
  --region $AWS_REGION \
  --environment "Variables={OPENAI_API_KEY=$OPENAI_API_KEY,PINECONE_API_KEY=$PINECONE_API_KEY,PINECONE_INDEX=$PINECONE_INDEX,EMBEDDING_MODEL=text-embedding-3-small,CHAT_MODEL=gpt-4o-mini,TOP_K=5}" 2>/dev/null || \
aws lambda update-function-code \
  --function-name $QUERY_FUNCTION \
  --zip-file fileb:///tmp/query.zip \
  --region $AWS_REGION

# Step 6: Create API Gateway
echo ""
echo "[6/8] Creating API Gateway"
API_ID=$(aws apigatewayv2 create-api \
  --name rag-api \
  --protocol-type HTTP \
  --cors-configuration AllowOrigins='*',AllowMethods='GET,POST,OPTIONS',AllowHeaders='Content-Type,Authorization' \
  --region $AWS_REGION \
  --query 'ApiId' --output text)

INTEGRATION_ID=$(aws apigatewayv2 create-integration \
  --api-id $API_ID \
  --integration-type AWS_PROXY \
  --integration-uri arn:aws:lambda:$AWS_REGION:$ACCOUNT_ID:function:$QUERY_FUNCTION \
  --payload-format-version 2.0 \
  --region $AWS_REGION \
  --query 'IntegrationId' --output text)

aws apigatewayv2 create-route \
  --api-id $API_ID \
  --route-key 'POST /query' \
  --target integrations/$INTEGRATION_ID \
  --region $AWS_REGION > /dev/null

aws apigatewayv2 create-stage \
  --api-id $API_ID \
  --stage-name prod \
  --auto-deploy \
  --region $AWS_REGION > /dev/null

aws lambda add-permission \
  --function-name $QUERY_FUNCTION \
  --statement-id api-gateway-invoke \
  --action lambda:InvokeFunction \
  --principal apigateway.amazonaws.com \
  --source-arn "arn:aws:execute-api:$AWS_REGION:$ACCOUNT_ID:$API_ID/*/*/query" \
  --region $AWS_REGION > /dev/null

API_URL="https://$API_ID.execute-api.$AWS_REGION.amazonaws.com/prod"
echo "API Gateway URL: $API_URL"

# Step 7: Deploy frontend to S3 static website
echo ""
echo "[7/8] Deploying frontend to S3: $FRONTEND_BUCKET"
aws s3 mb s3://$FRONTEND_BUCKET --region $AWS_REGION
aws s3 website s3://$FRONTEND_BUCKET --index-document index.html

# Update app.js with API URL
sed "s|YOUR_API_GATEWAY_URL_HERE|$API_URL|g" frontend/app.js > /tmp/app.js

aws s3 cp /tmp/app.js s3://$FRONTEND_BUCKET/app.js --content-type application/javascript
aws s3 cp frontend/index.html s3://$FRONTEND_BUCKET/index.html --content-type text/html
aws s3 cp frontend/style.css s3://$FRONTEND_BUCKET/style.css --content-type text/css

aws s3api put-bucket-policy --bucket $FRONTEND_BUCKET --policy "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Sid\":\"PublicRead\",\"Effect\":\"Allow\",\"Principal\":\"*\",\"Action\":\"s3:GetObject\",\"Resource\":\"arn:aws:s3:::$FRONTEND_BUCKET/*\"}]}"

FRONTEND_URL="http://$FRONTEND_BUCKET.s3-website.$AWS_REGION.amazonaws.com"

# Step 8: Print summary
echo ""
echo "========================================"
echo "  DEPLOYMENT COMPLETE!"
echo "========================================"
echo ""
echo "PDF Bucket:      s3://$S3_BUCKET"
echo "API Gateway URL: $API_URL"
echo "Frontend URL:    $FRONTEND_URL"
echo ""
echo "NEXT STEPS:"
echo "1. Upload a PDF: aws s3 cp yourfile.pdf s3://$S3_BUCKET/"
echo "2. Wait ~30 seconds for indexing"
echo "3. Open frontend: $FRONTEND_URL"
echo "4. Start asking questions!"
echo ""
