from __future__ import annotations

import os
from pathlib import Path
from typing import Any

from ocr_service import extract_text_from_file

PROJECT_ROOT = Path(__file__).resolve().parent.parent
MODELS_DIR = PROJECT_ROOT / "models"
EMBEDDINGS_DIR = MODELS_DIR / "embeddings"
RAG_DOCS_DIR = PROJECT_ROOT / "rag_documents"
RAG_INDEX_DIR = PROJECT_ROOT / "rag_index"

os.environ["HF_HOME"] = str(MODELS_DIR)
os.environ["TRANSFORMERS_CACHE"] = str(MODELS_DIR)

_embedding_model: Any = None
_chroma_client: Any = None
_chroma_collection: Any = None


def get_embedding_model():
    """Lazily loads sentence-transformers all-MiniLM-L6-v2 from ./models/embeddings/."""
    global _embedding_model
    if _embedding_model is not None:
        return _embedding_model

    print(f"[RAG] Loading embeddings model from project-local path: {EMBEDDINGS_DIR} ...")
    from sentence_transformers import SentenceTransformer
    model_path = str(EMBEDDINGS_DIR) if EMBEDDINGS_DIR.exists() else "sentence-transformers/all-MiniLM-L6-v2"
    _embedding_model = SentenceTransformer(model_path)
    print("[RAG] Embeddings model loaded successfully.")
    return _embedding_model


def get_vector_store():
    """Gets persistent ChromaDB client pointing strictly to ./rag_index/."""
    global _chroma_client, _chroma_collection
    if _chroma_collection is not None:
        return _chroma_collection

    print(f"[RAG] Initializing persistent ChromaDB vector store at: {RAG_INDEX_DIR} ...")
    import chromadb
    from chromadb.config import Settings

    RAG_INDEX_DIR.mkdir(parents=True, exist_ok=True)
    _chroma_client = chromadb.PersistentClient(path=str(RAG_INDEX_DIR), settings=Settings(anonymized_telemetry=False))
    _chroma_collection = _chroma_client.get_or_create_collection(name="jarvis_rag_index")
    print("[RAG] Vector store index initialized.")
    return _chroma_collection


def chunk_text(text: str, chunk_size: int = 500, overlap: int = 50) -> list[str]:
    """Splits text into chunks of specified size with overlap."""
    if not text:
        return []
    chunks = []
    start = 0
    while start < len(text):
        end = start + chunk_size
        chunk = text[start:end]
        if chunk.strip():
            chunks.append(chunk.strip())
        start += (chunk_size - overlap)
    return chunks


def ingest_documents(filename: str | None = None) -> dict[str, Any]:
    """
    Ingests file(s) from ./rag_documents/ into the persistent vector index in ./rag_index/.
    Read-only guarantee: Only reads files from ./rag_documents/, never alters or deletes them.
    """
    RAG_DOCS_DIR.mkdir(parents=True, exist_ok=True)
    embedder = get_embedding_model()
    collection = get_vector_store()

    target_files = []
    if filename:
        p = RAG_DOCS_DIR / filename
        if p.exists():
            target_files.append(p)
        else:
            raise FileNotFoundError(f"Document '{filename}' not found in {RAG_DOCS_DIR}")
    else:
        for f in RAG_DOCS_DIR.iterdir():
            if f.is_file() and not f.name.startswith("."):
                target_files.append(f)

    if not target_files:
        return {
            "success": True,
            "files_processed": 0,
            "total_chunks_indexed": 0,
            "indexed_files": [],
            "message": f"No files found to ingest in {RAG_DOCS_DIR}"
        }

    total_chunks = 0
    processed_filenames = []

    for file_path in target_files:
        try:
            doc_data = extract_text_from_file(file_path)
            raw_text = doc_data.get("text", "")
            if not raw_text:
                continue

            chunks = chunk_text(raw_text, chunk_size=500, overlap=50)
            if not chunks:
                continue

            embeddings = embedder.encode(chunks, convert_to_numpy=True).tolist()
            ids = [f"{file_path.name}_chunk_{idx}" for idx in range(len(chunks))]
            metadatas = [
                {
                    "source_filename": file_path.name,
                    "chunk_index": idx,
                    "char_count": len(c),
                    "page_count": doc_data.get("page_count", 1)
                }
                for idx, c in enumerate(chunks)
            ]

            collection.upsert(
                documents=chunks,
                embeddings=embeddings,
                metadatas=metadatas,
                ids=ids
            )

            total_chunks += len(chunks)
            processed_filenames.append(file_path.name)
            print(f"[RAG] Ingested {len(chunks)} chunks from '{file_path.name}' into vector index.")

        except Exception as e:
            print(f"[RAG][ERROR] Failed to ingest {file_path.name}: {e}")

    return {
        "success": True,
        "files_processed": len(processed_filenames),
        "total_chunks_indexed": total_chunks,
        "indexed_files": processed_filenames
    }


def query_rag(question: str, top_k: int = 3) -> dict[str, Any]:
    """
    Embeds query, retrieves top-k relevant document chunks from ./rag_index/.
    Returns retrieval result list with metadata.
    """
    if not question.strip():
        return {"query": question, "results": []}

    embedder = get_embedding_model()
    collection = get_vector_store()

    query_embedding = embedder.encode([question], convert_to_numpy=True).tolist()

    res = collection.query(
        query_embeddings=query_embedding,
        n_results=min(top_k, max(1, collection.count())) if collection.count() > 0 else top_k,
        include=["documents", "metadatas", "distances"]
    )

    formatted_results = []
    if res and res.get("documents") and res["documents"][0]:
        docs = res["documents"][0]
        metas = res.get("metadatas", [[]])[0]
        dists = res.get("distances", [[]])[0]

        for doc, meta, dist in zip(docs, metas, dists):
            formatted_results.append({
                "text": doc,
                "metadata": meta,
                "distance": float(dist)
            })

    return {
        "query": question,
        "results_count": len(formatted_results),
        "results": formatted_results
    }
