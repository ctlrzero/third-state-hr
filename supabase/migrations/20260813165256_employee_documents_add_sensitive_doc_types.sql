
-- New document types needed to cover the full "sensitive" set the approval
-- matrix must recognise (bank/payment info and salary/compensation evidence
-- didn't exist as distinct doc_type values before).
alter type document_type add value if not exists 'bank_payment_document';
alter type document_type add value if not exists 'compensation_document';
