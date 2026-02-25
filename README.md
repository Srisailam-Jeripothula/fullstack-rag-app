# fullstack-rag-app

> **Enterprise-grade RAG (Retrieval Augmented Generation) application** — upload a PDF, ask questions, get AI-powered answers grounded in your document.

## Architecture

```
┌─────────────┐     S3 PUT      ┌──────────────────┐     Pinecone
│  PDF Upload │ ──────────────► │  Ingest Lambda   │ ──────────────► Vector DB
└─────────────┘                 │  (handler.py)    │
                                └──────────────────┘

┌─────────────┐   API Gateway   ┌──────────────────┐     Pinecone
│  Frontend   │ ──────────────► │  Query Lambda    │ ──────────────► Search
│  (S3 Static)│ ◄────────────── │  (handler.py)    │ ◄────────────── OpenAI GPT
└─────────────┘                 └──────────────────┘
```

**Tech Stack:**
- **Frontend:** Vanilla HTML/CSS/JS hosted on S3 Static Website
- **Backend:** 2 AWS Lambda functions (Python 3.11)
- **PDF Storage:** AWS S3
- **Vector Database:** Pinecone
- **Embeddings:** OpenAI `text-embedding-3-small`
- **LLM:** OpenAI `gpt-4o-mini`
- **API:** AWS API Gateway (REST)

---

## Repository Structure

```
fullstack-rag-app/
├── backend/
│   ├── ingest/
│   │   ├── handler.py          # Lambda: triggered by S3 PUT, chunks PDF, embeds, upserts to Pinecone
│   │   └── requirements.txt    # pinecone, openai, pypdf, boto3
│   └── query/
│       ├── handler.py          # Lambda: receives question, searches Pinecone, calls GPT, returns answer
│       └── requirements.txt    # pinecone, openai, boto3
├── frontend/
│   ├── index.html              # Chat UI with PDF upload
│   ├── style.css               # Styles
│   └── app.js                  # API calls, file upload, chat logic
├── deploy.sh                   # One-click AWS deployment script
└── README.md
```

---

## Prerequisites

Before deploying, you need:

1. **AWS CLI** installed and configured (`aws configure`)
2. **OpenAI API Key** — https://platform.openai.com/api-keys
3. **Pinecone API Key** — https://app.pinecone.io
4. **Pinecone Index** — dimension: `1536`, metric: `cosine`

---

## Quick Deploy (One Command)

### Step 1 — Edit deploy.sh

Open `deploy.sh` and fill in your credentials at the top:

```bash
OPENAI_API_KEY="sk-your-openai-key"
PINECONE_API_KEY="your-pinecone-key"
PINECONE_INDEX="rag-pdf-index"
AWS_REGION="ap-south-1"        # change to your region
```

### Step 2 — Run from AWS CloudShell

```bash
# Clone the repo
git clone https://github.com/Srisailam-Jeripothula/fullstack-rag-app.git
cd fullstack-rag-app

# Make executable and run
chmod +x deploy.sh
./deploy.sh
```

The script will:
- Create S3 buckets (PDF storage + frontend hosting)
- Create IAM role for Lambda
- Package and deploy both Lambda functions with all dependencies
- Create API Gateway with `/query` POST endpoint and CORS enabled
- Upload frontend files with the API URL pre-configured
- Print the frontend URL when done

---

## Manual Deployment (Step by Step)

### Step 1: Create Pinecone Index

1. Go to https://app.pinecone.io
2. Create a new Index:
   - **Name:** `rag-pdf-index`
   - **Dimensions:** `1536`
   - **Metric:** `cosine`
   - **Cloud:** AWS | **Region:** us-east-1 (free tier)

### Step 2: Create S3 Bucket for PDFs

```bash
aws s3 mb s3://your-rag-pdf-bucket --region ap-south-1
```

### Step 3: Deploy Ingest Lambda

```bash
cd backend/ingest
pip install -r requirements.txt -t package/
cp handler.py package/
cd package && zip -r ../function.zip . && cd ..

aws lambda create-function \
  --function-name rag-ingest \
  --runtime python3.11 \
  --handler handler.lambda_handler \
  --role arn:aws:iam::YOUR_ACCOUNT_ID:role/rag-lambda-role \
  --zip-file fileb://function.zip \
  --timeout 300 \
  --memory-size 512 \
  --environment Variables='{"PINECONE_API_KEY":"YOUR_KEY","PINECONE_INDEX":"rag-pdf-index","OPENAI_API_KEY":"YOUR_KEY"}'
```

Add S3 trigger:
```bash
aws s3api put-bucket-notification-configuration \
  --bucket your-rag-pdf-bucket \
  --notification-configuration '{"LambdaFunctionConfigurations":[{"LambdaFunctionArn":"YOUR_LAMBDA_ARN","Events":["s3:ObjectCreated:*"],"Filter":{"Key":{"FilterRules":[{"Name":"suffix","Value":".pdf"}]}}}]}'
```

### Step 4: Deploy Query Lambda

```bash
cd backend/query
pip install -r requirements.txt -t package/
cp handler.py package/
cd package && zip -r ../function.zip . && cd ..

aws lambda create-function \
  --function-name rag-query \
  --runtime python3.11 \
  --handler handler.lambda_handler \
  --role arn:aws:iam::YOUR_ACCOUNT_ID:role/rag-lambda-role \
  --zip-file fileb://function.zip \
  --timeout 30 \
  --memory-size 256 \
  --environment Variables='{"PINECONE_API_KEY":"YOUR_KEY","PINECONE_INDEX":"rag-pdf-index","OPENAI_API_KEY":"YOUR_KEY"}'
```

### Step 5: Create API Gateway

```bash
# Create REST API
aws apigateway create-rest-api --name rag-api --region ap-south-1

# Get root resource ID, create /query resource, POST method
# Enable Lambda proxy integration
# Deploy to 'prod' stage
# Note the Invoke URL: https://xxxxx.execute-api.ap-south-1.amazonaws.com/prod
```

### Step 6: Deploy Frontend

```bash
# Create frontend S3 bucket
aws s3 mb s3://your-rag-frontend-bucket --region ap-south-1
aws s3 website s3://your-rag-frontend-bucket --index-document index.html

# Update API URL in app.js
sed -i 's|YOUR_API_GATEWAY_URL_HERE|https://xxxxx.execute-api.ap-south-1.amazonaws.com/prod|g' frontend/app.js

# Upload files
aws s3 cp frontend/index.html s3://your-rag-frontend-bucket/ --content-type text/html
aws s3 cp frontend/style.css s3://your-rag-frontend-bucket/ --content-type text/css
aws s3 cp frontend/app.js s3://your-rag-frontend-bucket/ --content-type application/javascript

# Make bucket public
aws s3api put-bucket-policy --bucket your-rag-frontend-bucket --policy '{
  "Version": "2012-10-17",
  "Statement": [{"Sid": "PublicRead", "Effect": "Allow", "Principal": "*",
    "Action": "s3:GetObject", "Resource": "arn:aws:s3:::your-rag-frontend-bucket/*"}]
}'
```

---

## Usage

1. **Upload a PDF** to your S3 bucket:
   ```bash
   aws s3 cp your-document.pdf s3://your-rag-pdf-bucket/
   ```
   Wait ~30 seconds for automatic ingestion (Lambda processes it and stores in Pinecone).

2. **Open the frontend** URL in your browser:
   ```
   http://your-rag-frontend-bucket.s3-website.ap-south-1.amazonaws.com
   ```

3. **Ask questions** about your document in the chat interface.

---

## Environment Variables

| Variable | Description | Required |
|---|---|---|
| `OPENAI_API_KEY` | OpenAI API key | Yes |
| `PINECONE_API_KEY` | Pinecone API key | Yes |
| `PINECONE_INDEX` | Pinecone index name | Yes |
| `EMBEDDING_MODEL` | Embedding model | No (default: `text-embedding-3-small`) |
| `CHAT_MODEL` | LLM model | No (default: `gpt-4o-mini`) |
| `CHUNK_SIZE` | Characters per chunk | No (default: `1000`) |
| `TOP_K` | Results to retrieve | No (default: `5`) |

---

## Cost Estimate (Monthly)

| Service | Usage | Cost |
|---|---|---|
| AWS Lambda | 1000 invocations | ~$0 (free tier) |
| API Gateway | 1000 requests | ~$0.01 |
| S3 | 1GB storage | ~$0.02 |
| OpenAI Embeddings | 100 PDFs | ~$0.50 |
| OpenAI GPT-4o-mini | 1000 queries | ~$0.30 |
| Pinecone | Starter plan | Free |
| **Total** | | **~$1/month** |

---

## Troubleshooting

**Lambda timeout** — Increase timeout to 5 minutes for large PDFs.

**CORS errors** — The query Lambda includes CORS headers. Ensure API Gateway has CORS enabled on the resource.

**Pinecone 404** — Make sure the index name in Lambda env vars matches exactly.

**Empty answers** — Verify the PDF was ingested: check CloudWatch logs for the ingest Lambda after uploading.

**Ingest Lambda not triggered** — Confirm the S3 event notification is configured and Lambda has `s3:GetObject` permission.

---

## License

MIT
