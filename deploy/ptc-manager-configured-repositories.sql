-- Every repository PtcManager is configured for, enabled or not, with the
-- checkout path onboarding derived for it. A repository is registered disabled
-- and only becomes useful once its checkout exists and both services can write
-- it, so provisioning must cover the disabled ones too: that is the state a
-- maintainer is in between adding a repository and enabling it.
select github_owner || '|' || github_name || '|' || local_path
from repositories
where coalesce(local_path, '') != ''
order by id;
