create index if not exists employee_change_requests_decided_by_idx on public.employee_change_requests(decided_by);
create index if not exists job_requisitions_opened_by_idx on public.job_requisitions(opened_by);
