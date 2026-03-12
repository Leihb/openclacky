---
name: pdf-reader
description: 'Read and analyze PDF files. Use this skill when the user has attached a PDF or mentions a PDF file path and wants to understand, summarize, extract, or ask questions about its content. Trigger on: "read this PDF", "analyze the PDF", "what does this PDF say", "what is in this file", "里面有什么", "帮我看看这个PDF", "总结一下", "这份文件说了什么" — or when a message contains a PDF attachment reference even without an explicit question. Also trigger when the user asks vague questions like "what is this?", "summarize", "tell me about this" if a PDF is attached.'
disable-model-invocation: false
user-invocable: true
---

# PDF Reading Skill

## Your Goal
Extract text content from the PDF file and answer the user's question based on that content. If the user's question is vague or absent, default to providing a clear structured summary of the document.

## Step 1 — Extract text from the PDF

Use `pdftotext` (preferred, fastest) or Python `pdfplumber` as fallback.

### Option A: pdftotext (use this first)
```bash
pdftotext -layout -enc UTF-8 "/path/to/file.pdf" -
```
- `-enc UTF-8` ensures correct encoding for Chinese, Japanese, and other non-Latin text
- `-layout` preserves column layout for tables
- The `-` at the end prints to stdout (no temp file needed)

**Install if missing:**
- macOS: `brew install poppler`
- Ubuntu/Debian: `apt install poppler-utils`
- CentOS/Fedora: `yum install poppler-utils`

### Option B: Python pdfplumber (fallback if pdftotext not available)
```python
import pdfplumber

with pdfplumber.open("/path/to/file.pdf") as pdf:
    for i, page in enumerate(pdf.pages, 1):
        text = page.extract_text()
        if text:
            print(f"--- Page {i} ---")
            print(text)
```

### Option C: pypdf (last resort)
```python
from pypdf import PdfReader

reader = PdfReader("/path/to/file.pdf")
for i, page in enumerate(reader.pages, 1):
    print(f"--- Page {i} ---")
    print(page.extract_text())
```

## Step 2 — Handle large files

If the extracted text is truncated or very long (>200 lines):
- For a **summary request**: read the full output file instead of relying on stdout — save to a temp file first:
  ```bash
  pdftotext -layout -enc UTF-8 "/path/to/file.pdf" /tmp/pdf_extracted.txt
  cat /tmp/pdf_extracted.txt
  ```
- For a **specific question**: use `grep` to locate relevant sections before reading the full content:
  ```bash
  grep -n "keyword" /tmp/pdf_extracted.txt | head -30
  ```
- Extract once, answer from memory — do NOT re-read the file multiple times.

## Step 3 — Answer the user's question

### Output format guidelines

Adapt the response format to the document type:

| Document type | Recommended format |
|---|---|
| Business plan / Report | Structured summary with ## headers per section |
| Contract / Legal | Key clauses in bullet points, highlight dates and parties |
| Academic paper | Abstract → Key findings → Methodology → Conclusions |
| Invoice / Receipt | Table: item, amount, total |
| General / Unknown | Brief overview paragraph + key points as bullets |

**General rules:**
- Use Markdown formatting (headers, bullets, tables) for clarity
- Match the user's language — if they asked in Chinese, answer in Chinese
- Lead with the most important information first
- If the user asked a specific question, answer it directly before summarizing

## Rules
- Always use the **actual file path** from the `[PDF attached: ...]` message
- If text extraction returns empty (scanned/image PDF), inform the user and suggest: `brew install tesseract` + `tesseract file.pdf output txt`
- Do NOT re-read the file multiple times — extract once, answer from memory
- If the user's question is vague (e.g. "里面有什么", "what is this?"), default to a full structured summary
