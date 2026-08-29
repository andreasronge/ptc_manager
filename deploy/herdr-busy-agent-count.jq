def agents:
  if type == "array" then .
  elif (.agents? | type) == "array" then .agents
  elif (.result? | type) == "array" then .result
  elif ((.result? | type) == "object" and (.result.agents? | type) == "array") then
    .result.agents
  else
    error("unexpected Herdr agent list response")
  end;

[
  agents[] |
  (.agent_status // .status // .state // "unknown") as $status |
  select(
    ["idle", "done", "completed", "complete", "failed", "error", "lost", "missing"] |
    index($status) |
    not
  )
] | length
