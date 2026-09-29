create or replace function public.onboarding_is_preboarding_self(p_employee_id uuid)
returns boolean language sql stable security definer set search_path to '' as $$
  select p_employee_id is not null and p_employee_id = public.my_employee_id()
     and exists (select 1 from public.onboarding_instances i where i.employee_id = p_employee_id
                  and i.status in ('initiated', 'awaiting_employee', 'under_review', 'changes_required', 'blocked',
                                   'ready_for_activation', 'activated', 'day_one', 'in_progress'));
$$;
revoke all on function public.onboarding_is_preboarding_self(uuid) from public, anon;
grant execute on function public.onboarding_is_preboarding_self(uuid) to authenticated;

do $$
declare t text;
begin
  foreach t in array array['onboarding_settings', 'employee_numbering', 'onboarding_templates', 'onboarding_template_tasks',
    'onboarding_policies', 'onboarding_instances', 'onboarding_tasks', 'onboarding_task_dependencies',
    'onboarding_pending_compensation', 'employee_payment_details', 'onboarding_invitations', 'onboarding_section_submissions',
    'onboarding_reviews', 'onboarding_exceptions', 'employee_acknowledgements', 'employee_contract_acceptances',
    'employee_probation_periods', 'employee_probation_reviews'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon, authenticated', t);
    execute format('grant select on public.%I to authenticated', t);
  end loop;
end $$;

create policy onboarding_settings_select on public.onboarding_settings for select to authenticated
  using ((select public.is_active_user()) and ((select public.my_role()) = 'owner'
         or ((select public.my_role()) in ('entity_admin', 'location_manager') and entity_id = (select public.my_entity()))));

create policy employee_numbering_select on public.employee_numbering for select to authenticated
  using ((select public.is_active_user()) and ((select public.my_role()) = 'owner'
         or ((select public.my_role()) = 'entity_admin' and entity_id = (select public.my_entity()))));

create policy onboarding_templates_select on public.onboarding_templates for select to authenticated
  using ((select public.is_active_user()) and ((select public.my_role()) = 'owner'
         or ((select public.my_role()) in ('entity_admin', 'location_manager') and entity_id = (select public.my_entity()))));

create policy onboarding_template_tasks_select on public.onboarding_template_tasks for select to authenticated
  using (exists (select 1 from public.onboarding_templates t where t.id = template_id));

create policy onboarding_policies_select on public.onboarding_policies for select to authenticated
  using ((select public.is_active_user()) and ((select public.my_role()) = 'owner' or entity_id = (select public.my_entity())
         or entity_id = (select e.entity_id from public.employees e where e.id = (select public.my_employee_id()))));

create policy onboarding_instances_select on public.onboarding_instances for select to authenticated
  using ((select public.is_active_user()) and (
    (select public.my_role()) = 'owner'
    or ((select public.my_role()) = 'entity_admin' and entity_id = (select public.my_entity()))
    or ((select public.my_role()) = 'location_manager' and home_location_id = (select public.my_location()))
    or public.payroll_can(entity_id, 'approve')
    or employee_id = (select public.my_employee_id())));

create policy onboarding_tasks_select on public.onboarding_tasks for select to authenticated
  using (exists (select 1 from public.onboarding_instances i where i.id = instance_id)
         and (section not in ('payroll') or exists (select 1 from public.onboarding_instances i where i.id = instance_id
              and ((select public.my_role()) = 'owner' or ((select public.my_role()) = 'entity_admin' and i.entity_id = (select public.my_entity()))
                   or public.payroll_can(i.entity_id, 'approve')))));

create policy onboarding_task_dependencies_select on public.onboarding_task_dependencies for select to authenticated
  using (exists (select 1 from public.onboarding_tasks t where t.id = task_id));

create policy onboarding_invitations_select on public.onboarding_invitations for select to authenticated
  using (exists (select 1 from public.onboarding_instances i where i.id = instance_id
                 and ((select public.my_role()) = 'owner' or ((select public.my_role()) = 'entity_admin' and i.entity_id = (select public.my_entity()))
                      or ((select public.my_role()) = 'location_manager' and i.home_location_id = (select public.my_location())))));

create policy onboarding_section_submissions_select on public.onboarding_section_submissions for select to authenticated
  using (exists (select 1 from public.onboarding_instances i where i.id = instance_id
                 and ((select public.my_role()) = 'owner' or ((select public.my_role()) = 'entity_admin' and i.entity_id = (select public.my_entity()))
                      or i.employee_id = (select public.my_employee_id())
                      or ((select public.my_role()) = 'location_manager' and i.home_location_id = (select public.my_location())
                          and section not in ('payment', 'payroll', 'documents', 'employment')))));

create policy onboarding_reviews_select on public.onboarding_reviews for select to authenticated
  using (exists (select 1 from public.onboarding_instances i where i.id = instance_id
                 and ((select public.my_role()) = 'owner' or ((select public.my_role()) = 'entity_admin' and i.entity_id = (select public.my_entity()))
                      or (section = 'payroll' and public.payroll_can(i.entity_id, 'approve'))
                      or (section not in ('payment', 'payroll', 'documents', 'employment')
                          and ((select public.my_role()) = 'location_manager' and i.home_location_id = (select public.my_location())
                               or i.employee_id = (select public.my_employee_id()))))));

create policy onboarding_exceptions_select on public.onboarding_exceptions for select to authenticated
  using (exists (select 1 from public.onboarding_instances i where i.id = instance_id
                 and ((select public.my_role()) = 'owner' or ((select public.my_role()) = 'entity_admin' and i.entity_id = (select public.my_entity()))
                      or ((select public.my_role()) = 'location_manager' and i.home_location_id = (select public.my_location()))
                      or (owner_role = 'payroll' and public.payroll_can(i.entity_id, 'approve')))));

create policy onboarding_pending_compensation_select on public.onboarding_pending_compensation for select to authenticated
  using (exists (select 1 from public.onboarding_instances i where i.id = instance_id
                 and ((select public.my_role()) = 'owner' or ((select public.my_role()) = 'entity_admin' and i.entity_id = (select public.my_entity()))
                      or public.payroll_can(i.entity_id, 'approve'))
                 and i.employee_id is distinct from (select public.my_employee_id())));

create policy employee_payment_details_select on public.employee_payment_details for select to authenticated
  using ((select public.is_active_user()) and (
    employee_id = (select public.my_employee_id())
    or exists (select 1 from public.employees e where e.id = employee_id and public.payroll_can(e.entity_id, 'approve')
               and e.id is distinct from (select public.my_employee_id()))));

create policy employee_acknowledgements_select on public.employee_acknowledgements for select to authenticated
  using ((select public.is_active_user()) and (employee_id = (select public.my_employee_id())
    or exists (select 1 from public.employees e where e.id = employee_id
               and ((select public.my_role()) = 'owner' or ((select public.my_role()) = 'entity_admin' and e.entity_id = (select public.my_entity()))
                    or ((select public.my_role()) = 'location_manager' and e.home_location_id = (select public.my_location()))))));

create policy employee_contract_acceptances_select on public.employee_contract_acceptances for select to authenticated
  using ((select public.is_active_user()) and (employee_id = (select public.my_employee_id())
    or exists (select 1 from public.employees e where e.id = employee_id
               and ((select public.my_role()) = 'owner' or ((select public.my_role()) = 'entity_admin' and e.entity_id = (select public.my_entity()))))));

create policy employee_probation_periods_select on public.employee_probation_periods for select to authenticated
  using ((select public.is_active_user()) and (employee_id = (select public.my_employee_id())
    or exists (select 1 from public.employees e where e.id = employee_id
               and ((select public.my_role()) = 'owner' or ((select public.my_role()) = 'entity_admin' and e.entity_id = (select public.my_entity()))
                    or ((select public.my_role()) = 'location_manager' and e.home_location_id = (select public.my_location()))))));

create policy employee_probation_reviews_select on public.employee_probation_reviews for select to authenticated
  using ((select public.is_active_user()) and exists (select 1 from public.employee_probation_periods pp
           join public.employees e on e.id = pp.employee_id
          where pp.id = probation_period_id and e.id is distinct from (select public.my_employee_id())
            and ((select public.my_role()) = 'owner' or ((select public.my_role()) = 'entity_admin' and e.entity_id = (select public.my_entity()))
                 or ((select public.my_role()) = 'location_manager' and e.home_location_id = (select public.my_location())))));

create policy documents_select_preboarding_self on public.employee_documents for select to authenticated
  using (((upload_confirmed = true) or (submitted_by = (select auth.uid())))
         and public.onboarding_is_preboarding_self(employee_id));

create policy doc_bucket_write_preboarding_self on storage.objects for insert to authenticated
  with check (bucket_id = 'employee-documents'
    and (select public.my_role()) = 'staff'
    and exists (select 1 from public.employee_documents d
                 where d.storage_path = name and d.submitted_by = (select auth.uid()) and not d.upload_confirmed
                   and public.onboarding_is_preboarding_self(d.employee_id)));

create policy doc_bucket_read_preboarding_self on storage.objects for select to authenticated
  using (bucket_id = 'employee-documents'
    and exists (select 1 from public.employee_documents d
                 where d.storage_path = name and public.onboarding_is_preboarding_self(d.employee_id)));;
