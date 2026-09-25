
-- UAT-only synthetic fixtures for the cross-interviewer feedback secrecy test.
-- Reuses UAT Employee A and UAT Employee B (plain 'employee' role, no Owner /
-- Entity Admin / Location Manager role) as the two interviewers, avoiding the
-- need to mint any new auth.users accounts/credentials. Both already exist,
-- both are in Entity A (different branches), and neither holds a management
-- role -- exactly the "interviewer-only" persona requested.
--
-- Round 1 ("UAT Candidate Privacy Test"): 2 interviews on the existing
-- "UAT Phone Screen" stage of the "UAT Barista" requisition, one per
-- interviewer, no feedback submitted yet -- for the live cross-interviewer
-- secrecy walkthrough (both interviewers sign in and submit through the UI).
--
-- Round 2 ("UAT Candidate Admin Close Test"): same shape, but Employee A's
-- feedback is pre-seeded as already submitted (synthetic content) and
-- Employee B's is left unsubmitted, simulating a straggler -- for the
-- authorised admin-close test.
--
-- Two candidate_files rows on round 1's candidate: one marked
-- visible_to_interviewers = true (interview pack) and one false (resume) --
-- for the data-minimisation check. storage_path points at a placeholder
-- object; no bytes are uploaded since only row-level/RPC visibility is being
-- tested, not file download.

do $$
declare
  v_entity_id uuid := 'a0000000-0000-4000-8000-000000000001';
  v_location_id uuid := 'a0000000-0000-4000-8000-000000000011';
  v_requisition_id uuid := 'a0000000-0000-4000-8000-000000000081';
  v_stage_id uuid := 'a0000000-0000-4000-8000-000000000084';
  v_emp_a_auth uuid := '5f353b67-2e93-4cea-bd44-9ad2d6b4bfd9';
  v_emp_b_auth uuid := '99a456ae-bdf5-40ca-b0fb-fc741a525cd5';

  v_candidate1_id uuid;
  v_application1_id uuid;
  v_interview1a_id uuid;
  v_interview1b_id uuid;
  v_file_visible_id uuid;
  v_file_hidden_id uuid;

  v_candidate2_id uuid;
  v_application2_id uuid;
  v_interview2a_id uuid;
  v_interview2b_id uuid;
begin
  -- Round 1: privacy / cross-interviewer secrecy test
  insert into public.candidates (entity_id, location_id, full_name, contact_email, contact_phone, source, status)
  values (v_entity_id, v_location_id, 'UAT Candidate Privacy Test', 'uat.candidate.privacytest@example.com', '+971500000001', 'other', 'interviewing')
  returning id into v_candidate1_id;

  insert into public.job_applications (requisition_id, candidate_id, stage)
  values (v_requisition_id, v_candidate1_id, 'interviewing')
  returning id into v_application1_id;

  insert into public.interviews (application_id, stage_id, scheduled_at, interviewer_id, format, meeting_location)
  values (v_application1_id, v_stage_id, now() - interval '2 hours', v_emp_a_auth, 'video', 'UAT synthetic video link A')
  returning id into v_interview1a_id;

  insert into public.interviews (application_id, stage_id, scheduled_at, interviewer_id, format, meeting_location)
  values (v_application1_id, v_stage_id, now() - interval '2 hours', v_emp_b_auth, 'video', 'UAT synthetic video link B')
  returning id into v_interview1b_id;

  insert into public.candidate_files (candidate_id, entity_id, file_type, storage_path, visible_to_interviewers)
  values (v_candidate1_id, v_entity_id, 'interview_pack',
          v_entity_id::text || '/' || v_candidate1_id::text || '/' || gen_random_uuid()::text || '/uat-privacy-test-interview-pack.txt',
          true)
  returning id into v_file_visible_id;

  insert into public.candidate_files (candidate_id, entity_id, file_type, storage_path, visible_to_interviewers)
  values (v_candidate1_id, v_entity_id, 'resume',
          v_entity_id::text || '/' || v_candidate1_id::text || '/' || gen_random_uuid()::text || '/uat-privacy-test-resume.txt',
          false)
  returning id into v_file_hidden_id;

  -- Round 2: admin-close (straggler) test
  insert into public.candidates (entity_id, location_id, full_name, contact_email, contact_phone, source, status)
  values (v_entity_id, v_location_id, 'UAT Candidate Admin Close Test', 'uat.candidate.adminclosetest@example.com', '+971500000002', 'other', 'interviewing')
  returning id into v_candidate2_id;

  insert into public.job_applications (requisition_id, candidate_id, stage)
  values (v_requisition_id, v_candidate2_id, 'interviewing')
  returning id into v_application2_id;

  insert into public.interviews (application_id, stage_id, scheduled_at, interviewer_id, format, meeting_location)
  values (v_application2_id, v_stage_id, now() - interval '3 hours', v_emp_a_auth, 'video', 'UAT synthetic video link A')
  returning id into v_interview2a_id;

  insert into public.interviews (application_id, stage_id, scheduled_at, interviewer_id, format, meeting_location)
  values (v_application2_id, v_stage_id, now() - interval '3 hours', v_emp_b_auth, 'video', 'UAT synthetic video link B')
  returning id into v_interview2b_id;

  insert into public.interview_feedback (interview_id, submitted_by, status, recommendation, competency_ratings, strengths, concerns, notes, submitted_at)
  values (
    v_interview2a_id, v_emp_a_auth, 'submitted', 'yes', '{}'::jsonb,
    'Synthetic UAT strength note (admin-close fixture)',
    'Synthetic UAT concern note (admin-close fixture)',
    'Synthetic UAT feedback seeded for admin-close test',
    now() - interval '1 hour'
  );
  -- interview2b intentionally left with no feedback row: the straggler.

  raise notice 'candidate1=%, application1=%, interview1a=%, interview1b=%, candidate2=%, application2=%, interview2a=%, interview2b=%',
    v_candidate1_id, v_application1_id, v_interview1a_id, v_interview1b_id,
    v_candidate2_id, v_application2_id, v_interview2a_id, v_interview2b_id;
end $$;
