
-- Bug fix: candidate_files_bucket_interviewer_read on storage.objects was
-- accidentally simplified in fix_interviewer_rls_cross_table_join_gap to only
-- check cf.visible_to_interviewers = true, dropping the interviewer-assignment,
-- entity, cancelled, active-employee, and visibility-window checks that the
-- original candidate_files_storage_rls migration had, and that the table-level
-- candidate_files_interviewer_select policy still correctly enforces via the
-- interviewer_can_access_candidate_file() SECURITY DEFINER helper (added in
-- that same fix migration, for exactly this purpose). This let any
-- authenticated user fetch any candidate file marked visible_to_interviewers,
-- regardless of interviewer assignment or entity. Restore parity with the
-- table policy by reusing the same helper.

drop policy if exists candidate_files_bucket_interviewer_read on storage.objects;

create policy candidate_files_bucket_interviewer_read on storage.objects
  for select
  to authenticated
  using (
    bucket_id = 'candidate-files'
    and exists (
      select 1 from public.candidate_files cf
      where cf.storage_path = objects.name
        and cf.visible_to_interviewers = true
        and public.interviewer_can_access_candidate_file(cf.candidate_id)
    )
  );
