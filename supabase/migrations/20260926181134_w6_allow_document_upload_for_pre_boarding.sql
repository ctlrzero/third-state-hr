-- Fix: admins/managers could not upload documents for pre-boarding employees
-- ("Cannot upload documents for an inactive employee"), which made the
-- w5 key-documents activation rule impossible to satisfy. Only employees
-- whose status is 'inactive' are now refused; candidate / pre_boarding /
-- active are allowed. Staff self-service uploads are unchanged (still gated
-- by is_active_employee in RLS). Function bodies are otherwise untouched;
-- CREATE OR REPLACE keeps existing owner and grants.
do $mig$
declare
  fn regprocedure;
  def text;
  new_def text;
  old_check constant text := $c$if v_emp.employment_status <> 'active' then raise exception 'Cannot upload documents for an inactive employee'; end if;$c$;
  new_check constant text := $c$if v_emp.employment_status = 'inactive' then raise exception 'Cannot upload documents for an inactive employee'; end if;$c$;
begin
  foreach fn in array array[
    'public.stage_document_upload(uuid, public.document_type, text, date, text)'::regprocedure,
    'public.create_document_upload(uuid, public.document_type, text, date, text)'::regprocedure
  ] loop
    def := pg_get_functiondef(fn);
    if position(old_check in def) = 0 then
      raise exception 'Expected status check not found in %', fn;
    end if;
    new_def := replace(def, old_check, new_check);
    execute new_def;
  end loop;
end
$mig$;
