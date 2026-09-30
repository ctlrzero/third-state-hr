-- P1-7 (part 1): new role. Added on its own because Postgres needs a new enum value committed before use.
alter type public.user_role add value if not exists 'shift_supervisor';
