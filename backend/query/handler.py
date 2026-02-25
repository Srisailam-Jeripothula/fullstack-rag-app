import json
import os
import boto3
from pinecone import Pinecone
from openai import OpenAI

# Environment variables
PINECONE_API_KEY = os.environ['PINECONE_API_KEY']
PINECONE_INDEX = os.environ['PINECONE_INDEX']
OPENAI_API_KEY = os.environ['OPENAI_API_KEY']
EMBEDDING_MODEL = os.environ.get('EMBEDDING_MODEL', 'text-embedding-3-small')
CHAT_MODEL = os.environ.get('CHAT_MODEL', 'gpt-4o-mini')
TOP_K = int(os.environ.get('TOP_K', '5'))

# Clients
pc = Pinecone(api_key=PINECONE_API_KEY)
index = pc.Index(PINECONE_INDEX)
oai = OpenAI(api_key=OPENAI_API_KEY)

# CORS headers for all responses
CORS_HEADERS = {
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Headers': 'Content-Type,Authorization',
    'Access-Control-Allow-Methods': 'OPTIONS,POST,GET',
    'Content-Type': 'application/json'
}


def build_response(status_code, body):
    return {
        'statusCode': status_code,
        'headers': CORS_HEADERS,
        'body': json.dumps(body)
    }


def embed_question(question):
    """Embed a question using OpenAI."""
    response = oai.embeddings.create(
        model=EMBEDDING_MODEL,
        input=[question]
    )
    return response.data[0].embedding


def retrieve_context(question_embedding):
    """Search Pinecone for top-K similar chunks."""
    results = index.query(
        vector=question_embedding,
        top_k=TOP_K,
        include_metadata=True
    )
    chunks = []
    for match in results.matches:
        if match.metadata and 'text' in match.metadata:
            chunks.append({
                'text': match.metadata['text'],
                'score': round(match.score, 4),
                'source': match.metadata.get('source', 'unknown'),
                'pages': match.metadata.get('pages', [])
            })
    return chunks


def generate_answer(question, context_chunks):
    """Generate an answer using GPT with retrieved context."""
    context_text = '\n\n---\n\n'.join(
        [f"[Source: {c['source']}, Pages: {c['pages']}]\n{c['text']}" for c in context_chunks]
    )

    system_prompt = """You are an expert AI assistant. Answer questions based ONLY on the provided context.
If the context doesn't contain enough information, say so clearly.
Always cite the source and page numbers when referencing information.
Be concise, accurate, and helpful."""

    user_prompt = f"""Context from the document:
{context_text}

Question: {question}

Answer based on the context above:"""

    response = oai.chat.completions.create(
        model=CHAT_MODEL,
        messages=[
            {'role': 'system', 'content': system_prompt},
            {'role': 'user', 'content': user_prompt}
        ],
        temperature=0.3,
        max_tokens=800
    )
    return response.choices[0].message.content


def lambda_handler(event, context):
    """Main Lambda entry point called by API Gateway."""

    # Handle CORS preflight
    if event.get('httpMethod') == 'OPTIONS':
        return build_response(200, {'message': 'OK'})

    try:
        # Parse request body
        body = json.loads(event.get('body', '{}'))
        question = body.get('question', '').strip()

        if not question:
            return build_response(400, {'error': 'Question is required'})

        print(f'Question received: {question}')

        # Step 1: Embed the question
        question_embedding = embed_question(question)

        # Step 2: Retrieve relevant chunks from Pinecone
        context_chunks = retrieve_context(question_embedding)
        print(f'Retrieved {len(context_chunks)} context chunks')

        if not context_chunks:
            return build_response(200, {
                'answer': 'I could not find relevant information in the documents. Please upload a PDF first.',
                'sources': [],
                'question': question
            })

        # Step 3: Generate answer with GPT
        answer = generate_answer(question, context_chunks)
        print(f'Answer generated: {answer[:100]}...')

        return build_response(200, {
            'answer': answer,
            'question': question,
            'sources': context_chunks,
            'model': CHAT_MODEL
        })

    except Exception as e:
        print(f'Error: {str(e)}')
        return build_response(500, {'error': f'Internal server error: {str(e)}'})
