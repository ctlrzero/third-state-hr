-- Forward-only remediation migration (Phase C1/C2 hardening).
-- NOT part of the 99-migration recovered baseline — this is new, proposed,
-- and has NOT been applied to any remote project yet. Review before applying.
--
-- Both employee-documents and candidate-files are already private buckets
-- (public = false, confirmed live), but neither has a file size limit or an
-- allowed MIME type list configured, so uploads are currently unrestricted
-- in both dimensions. This sets reasonable HR-document limits: PDFs and
-- common image formats (scans/photos of documents), capped at 10MB.

update storage.buckets
set
  file_size_limit = 10485760, -- 10 MiB
  allowed_mime_types = array['application/pdf', 'image/jpeg', 'image/png', 'image/heic']
where id in ('employee-documents', 'candidate-files');
