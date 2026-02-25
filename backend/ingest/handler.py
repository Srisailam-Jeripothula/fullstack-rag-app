import json
import os
import uuid
import boto3
from io import BytesIO
from pinecone import Pinecone
from openai import OpenAI
from pypdf import PdfReader

# Environment variables
PINECONE_API_KEY = os.environ['PINECONE_API_KEY']
PINECONE_INDEX = os.environ['PINECONE_INDEX']
OPENAI_API_KEY = os.environ['OPENAI_API_KEY']
EMBEDDING_MODEL = os.environ.get('EMBEDDING_MODEL', 'text-embedding-3-small')
CHUNK_SIZE = int(os.environ.get('CHUNK_SIZE', '1000'))

# Clients (initialized once per container)
pc = Pinecone(api_key=PINECONE_API_KEY)
index = pc.Index(PINECONE_INDEX)
oai = OpenAI(api_key=OPENAI_API_KEY)
s3 = boto3.client('s3')


def clean_text(text):
    """Remove surrogate characters that break UTF-8 encoding."""
    if not text:
        return ''
    return text.encode('utf-8', 'ignore').decode('utf-8')


def extract_chunks(bucket, key):
    """Download PDF from S3 and split into text chunks."""
    obj = s3.get_object(Bucket=bucket, Key=key)
    pdf = PdfReader(BytesIO(obj['Body'].read()))
    chunks = []
    current = ''
    current_pages = []

    for page_num, page in enumerate(pdf.pages):
        text = clean_text(page.extract_text() or '')
        for char in text:
            current += char
            if page_num not in current_pages:
                current_pages.append(page_num)
            if len(current) >= CHUNK_SIZE:
                chunks.append({'text': current, 'pages': list(current_pages)})
                current = current[-200:]  # 200-char overlap
                current_pages = [page_num]

    if current.strip():
        chunks.append({'text': current, 'pages': list(current_pages)})

    return chunks


def embed_and_upsert(chunks, source_key):
    """Embed chunks with OpenAI and upsert into Pinecone."""
    batch_size = 50
    total_upserted = 0

    for i in range(0, len(chunks), batch_size):
        batch = chunks[i:i + batch_size]
        texts = [c['text'] for c in batch]

        # Get embeddings from OpenAI
        response = oai.embeddings.create(
            model=EMBEDDING_MODEL,
            input=texts
        )

        # Build Pinecone vectors
        vectors = []
        for j, (chunk, emb) in enumerate(zip(batch, response.data)):
            vectors.append({
                'id': f"{source_key}_{i + j}",
                'values': emb.embedding,
                'metadata': {
                    'source': source_key,
                    'pages': chunk['pages'],
                    'text': chunk['text'][:1000]
                }
            })

        index.upsert(vectors=vectors)
        total_upserted += len(vectors)
        print(f'Upserted batch {i} - {i + len(batch)} ({total_upserted} total)')

    print(f'Ingestion complete. Total vectors upserted: {total_upserted}')
    return total_upserted


def lambda_handler(event, context):
    """Main Lambda entry point triggered by S3 PUT events."""
    results = []

    for record in event['Records']:
        bucket = record['s3']['bucket']['name']
        key = record['s3']['object']['key']
        print(f'Processing: s3://{bucket}/{key}')

        chunks = extract_chunks(bucket, key)
        print(f'Extracted {len(chunks)} chunks from {key}')

        count = embed_and_upsert(chunks, key)
        results.append({'file': key, 'chunks': count})

    return {
        'statusCode': 200,
        'body': json.dumps({'message': 'Ingestion complete', 'results': results})
    }
