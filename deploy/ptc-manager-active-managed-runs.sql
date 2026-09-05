-- Counts the agent runs a deployment must wait for, matching
-- PtcManager.Deployments.drain_blockers/0 exactly. Both guards have to agree:
-- PtcManager drains until this set is empty and only then hands over to the
-- host runner, so a run this query counts but drain_blockers/0 does not would
-- refuse every deployment the moment it is handed over.
--
-- A run the coordinator is driving always holds a deployment. A blocked or
-- unknown run holds one only while its agent action or its job is still in
-- flight: a retained agent sitting on a prompt for an open pull request does
-- not, because restarting PtcManager never touches Herdr agents.
select count(*)
from agent_runs run
left join agent_actions action on action.id = run.agent_action_id
left join jobs job on job.id = run.job_id
where run.state in ('queued', 'starting', 'working')
   or (
     run.state in ('blocked', 'unknown')
     and (
       action.state in ('queued', 'running', 'sync_pending')
       or job.state in ('starting', 'working', 'idle', 'blocked', 'reconciling')
     )
   );
