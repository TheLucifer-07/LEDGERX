SELECT count(*) AS visible_workspaces, (SELECT count(*) FROM lx.users) AS visible_users, (SELECT count(*) FROM lx.workspace_members) AS visible_members FROM lx.workspaces
