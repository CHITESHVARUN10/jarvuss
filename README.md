# JarvisMacOS

Offline-first macOS assistant in Swift & Python with:

- **Local OCR & RAG Knowledge Base**: Extract text from images, PDFs, and scans locally, indexed in ChromaDB vector store.
- **Document Upload UI**: Native UI panel for dropping/uploading PDFs, images, and text notes.
- **Voice RAG Queries**: Query your local documents using natural voice triggers like *"Jarvis, ask document [question]"*.
- **Local Ollama Integration**: Powered by `mistral:7b` for offline reasoning & answer synthesis.
- **Voice Auth & Enrollment**: Resemblyzer speaker verification and 2-layer phrase enrollment.
- **System Automation**: Open/close apps, create files/folders, and execute multi-action workflows.

---

## 🚀 Key Features

### 1. Project-Local Models (Strict Isolation)
All model weights are stored strictly inside the project tree in `./models/`:
- `./models/ocr/`: Baidu Unlimited-OCR model weights
- `./models/embeddings/`: `all-MiniLM-L6-v2` sentence-transformer model
- `./rag_documents/`: Source documents (PDFs, images, notes) dropped by the user
- `./rag_index/`: Persistent ChromaDB vector index

*Nothing is downloaded to global system locations like `~/.cache`.*

### 2. Document Upload & Ingestion UI
Upload documents directly inside the Jarvis macOS GUI:
1. Open Jarvis and scroll to **RAG DOCUMENTS** in the sidebar.
2. Click **"+ Upload Document"** to choose any PDF, Image (PNG/JPG/TIFF), or Text file.
3. Jarvis automatically copies the file to `./rag_documents/`, runs OCR on scanned pages, chunks text, and indexes vector embeddings.

### 3. Voice RAG Retrieval Triggers
Query your indexed documents directly via voice:
- *"Jarvis, ask document what is my favorite color?"*
- *"Jarvis, ask documents what are my project deadlines?"*
- *"Jarvis, search notes for server setup instructions."*
- *"Jarvis, search documents for meeting key points."*

---

## 🛠️ Installation & Setup

### 1) Prerequisites (macOS)

```zsh
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
brew install cmake ffmpeg portaudio ollama postgresql@18
```

### 2) Ollama Model Setup

```zsh
ollama pull mistral:7b
ollama serve
```

### 3) Python Backend Environment

```zsh
cd backend
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt
```

### 4) Download Project-Local Models

Run the automatic model downloader script to populate `./models/`:

```zsh
python scripts/download_models.py
```

---

## 🖥️ Launching Jarvis

### Automated Single-Script Launcher (App + Backend):

```zsh
./scripts/launch_jarvis_app.zsh
```

Or manually start backend & app:

```zsh
# Terminal 1: Backend
python3 -m uvicorn voice_auth_service:app --app-dir backend --host 127.0.0.1 --port 8000

# Terminal 2: Swift App
swift build
.build/debug/Jarvis
```

---

## 📂 API Reference

### Local Python Backend Endpoints (`http://127.0.0.1:8000`)

| Endpoint | Method | Description |
|:---|:---:|:---|
| `/health` | `GET` | Backend health check |
| `/ocr/scan` | `POST` | Perform OCR scan on a file in `./rag_documents/` |
| `/rag/ingest` | `POST` | Chunk and index file(s) into ChromaDB `./rag_index/` |
| `/rag/query` | `POST` | Vector similarity search for top-k document chunks |
| `/bonsai/generate` | `POST` | Text generation delegated to local Ollama (`mistral:7b`) |
| `/verify_voice` | `POST` | Resemblyzer speaker verification |

---

## 🎙️ Voice & Text Command Syntax

```text
# RAG Document Search
Jarvis ask document what is my favorite color?
Jarvis search notes for project deadline

# App Controls
Jarvis open brave browser
Jarvis close spotify

# File Operations
Jarvis create file test.txt
Jarvis create folder demo
Jarvis open folder downloads

# General AI Queries
Jarvis explain quantum computing
```

---

## 🔒 Permissions & Security

- **Microphone**: Require `NSMicrophoneUsageDescription` permission grant in macOS Settings.
- **Offline First**: All OCR, embedding, vector store, and LLM operations run 100% locally on your Mac.

