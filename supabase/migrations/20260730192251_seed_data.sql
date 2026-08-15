with e1 as (
  insert into entities (name, emirate, default_currency)
  values ('Third State Cafe', 'Dubai', 'AED')
  returning id
),
e2 as (
  insert into entities (name, emirate, default_currency)
  values ('Ateej Tea Brew', 'Sharjah', 'AED')
  returning id
),
l1 as (
  insert into locations (entity_id, name)
  select id, 'Expo City CRC Concession' from e1
  returning id, entity_id
),
l2 as (
  insert into locations (entity_id, name)
  select id, 'Corporate Concession' from e1
  returning id, entity_id
),
l3 as (
  insert into locations (entity_id, name)
  select id, 'Sharjah Retail' from e2
  returning id, entity_id
)
insert into positions (entity_id, title, department)
select entity_id, title, department
from (
  select id as entity_id, 'Barista' as title, 'Front of House' as department from e1
  union all
  select id, 'Senior Barista', 'Front of House' from e1
  union all
  select id, 'Shift Lead', 'Front of House' from e1
  union all
  select id, 'Tea Specialist', 'Front of House' from e2
  union all
  select id, 'Senior Barista', 'Front of House' from e2
) positions_seed;
