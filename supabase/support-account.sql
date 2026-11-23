-- OrdCat 客服账号：先在 Authentication → Users 建好账号，再把下面的邮箱改成那个账号的邮箱，然后运行。
do $$
declare u uuid;
begin
  select id into u from auth.users where email = 'support@ordcat.de';
  if u is null then raise exception '没找到这个邮箱的账号：先在 Authentication → Users 建好，或者改上面的邮箱'; end if;
  insert into public.app_settings (key, value) values ('support_user_id', u::text)
    on conflict (key) do update set value = excluded.value;
  insert into public.profiles (id, username, display_name) values (u, 'ordcat', 'OrdCat 客服')
    on conflict (id) do update set username = excluded.username, display_name = excluded.display_name;
end $$;
