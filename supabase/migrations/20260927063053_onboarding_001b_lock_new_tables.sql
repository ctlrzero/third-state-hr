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
  end loop;
end $$;;
