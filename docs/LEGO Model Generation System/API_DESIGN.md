# API Design

This document defines the REST API for job creation, status tracking, and result retrieval for the LEGO model generation system.

---

## 1. Overview

The API exposes an asynchronous job workflow:

1. Client uploads an image and configuration.
2. Server creates a job and returns a job ID.
3. Client polls for job status.
4. When complete, client retrieves:
   - LDraw file
   - Instructions PDF
   - Parts list JSON

---

## 2. Endpoints

### POST /jobs

Creates a new job.

Request fields (multipart/form-data):

- image  
- width  
- height  
- palette  
- background_removal  

Response example:

job_id: "abc123"  
status: "queued"

---

### GET /jobs/{id}

Returns job status.

Queued:

job_id: "abc123"  
status: "queued"

Processing:

job_id: "abc123"  
status: "processing"  
progress: 42

Done:

job_id: "abc123"  
status: "done"

Error:

job_id: "abc123"  
status: "error"  
message: "Segmentation failed"

---

### GET /jobs/{id}/result

Returns URLs for generated artifacts.

ldr_url: https://cdn.example.com/jobs/abc123/model.ldr  
pdf_url: https://cdn.example.com/jobs/abc123/instructions.pdf  
parts_url: https://cdn.example.com/jobs/abc123/parts.json  
thumbnail_url: https://cdn.example.com/jobs/abc123/thumbnail.png

---

## 3. Status Values

- queued  
- processing  
- done  
- error  

---

## 4. Error Handling

Standard error response:

error: "Invalid image format"  
code: 400

Common errors:

- Invalid file type  
- Missing parameters  
- Job not found  
- Internal failure  

---

## 5. Authentication

Production:

- JWT or OAuth2  
- Rate limiting  
- Auth required for all endpoints  

MVP:

- Anonymous allowed  
- Basic rate limiting  

---

## 6. Request Size Limits

- Max upload: 10–20 MB  
- Reject oversized images early  
- Recommend client‑side resizing  

---

## 7. Performance Considerations

- Job creation O(1)  
- Poll every 1–2 seconds  
- Use CDN for artifacts  
- Store artifacts in S3‑compatible storage  

---

## 8. Future Enhancements

- WebSocket updates  
- Batch jobs  
- Webhooks  
- User accounts  

---

## 9. Summary

The API provides a clean, asynchronous workflow for generating LEGO models: create job, poll status, retrieve artifacts.
