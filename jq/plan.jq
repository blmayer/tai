# Plan tree. Input is the whole state unless a def says otherwise.

def trim:
  if type == "string" then gsub("^\\s+|\\s+$"; "") else "" end;

def statuses:
  ["pending", "running", "ok", "blocked", "error", "skipped"];

def terminal($s):
  $s == "ok" or $s == "blocked" or $s == "error" or $s == "skipped";

def empty_plan:
  {agent:"orchestrator", status:"pending", goal:"", title:"", notes:"", result:"", tools:[], tasks:[]};

def normalize:
  . as $raw
  | ($raw.goal // $raw.text // "") | trim as $g
  | if $g == "" then null
    else
      [($raw.tasks // $raw.children // $raw.items // [])[] | normalize | select(. != null)] as $tasks
      | ($raw.agent // $raw.role // "" | tostring | ascii_downcase | trim) as $a0
      | (if $a0 == "coder" or $a0 == "manager" or $a0 == "orchestrator" then $a0
         elif ($tasks | length) > 0 then "orchestrator" else "coder" end) as $agent
      | ($raw.status // "pending" | tostring | ascii_downcase) as $st0
      | {
          agent: $agent,
          status: (if (statuses | index($st0)) then $st0 else "pending" end),
          goal: $g,
          title: (if ($raw.title | type) == "string" then ($raw.title | trim) else "" end),
          notes: (if ($raw.notes | type) == "string" then $raw.notes else "" end),
          result: (if ($raw.result | type) == "string" then $raw.result else "" end),
          tools: [($raw.tools // [])[] | select(type == "string" and . != "")],
          tasks: $tasks
        }
    end;

def parse_index($index):
  if ($index | type) == "number" then
    if $index < 1 then null else [$index] end
  elif ($index | type) == "string" then
    [$index | split(".")[] | try tonumber catch null]
    | if length == 0 or any(. == null or . < 1) then null else . end
  elif ($index | type) == "array" then
    if length == 0 or any(type != "number" or . < 1) then null else . end
  else null end;

def node_at($path):
  if $path == null or ($path | length) == 0 then .
  else .tasks[$path[0] - 1] // null | if . == null then null else node_at($path[1:]) end
  end;

def put_in($path; $node):
  if ($path | length) == 0 then $node
  elif ($path | length) == 1 then .tasks[$path[0] - 1] = $node
  else .tasks[$path[0] - 1] |= put_in($path[1:]; $node)
  end;

def append_task($path; $node):
  if ($path | length) == 0 then .tasks += [$node]
  else .tasks[$path[0] - 1] |= append_task($path[1:]; $node)
  end;

def patch_in($path; f):
  if ($path | length) == 0 then f
  else .tasks[$path[0] - 1] |= patch_in($path[1:]; f)
  end;

def settle_node:
  if ((.tasks // []) | length) == 0 then .
  elif terminal(.status) then .
  elif (.tasks | all(terminal(.status)) | not) then .
  elif (.tasks | any(.status == "blocked" or .status == "error")) then .status = "blocked"
  else .status = "ok" end;

def settle_from($path):
  if ($path | length) == 0 then settle_node
  else .tasks[$path[0] - 1] |= settle_from($path[1:]) | settle_node end;

def find_from($tasks; $pre; $i):
  if $tasks == null or $i >= ($tasks | length) then null
  else
    ($tasks[$i]) as $item
    | ($pre + [$i + 1]) as $p
    | (if (($item.tasks // []) | length) > 0 then find_from($item.tasks; $p; 0)
       elif $item.status == "pending" then {path: $p, item: $item}
       else null end) as $hit
    | if $hit then $hit else find_from($tasks; $pre; $i + 1) end
  end;

def find_pending($tasks):
  find_from($tasks; []; 0);

def frame_tasks($path):
  (.plan | node_at($path) | .tasks) // [];

def step_str($p):
  $p | map(tostring) | join(".");

def field_lines($pad; $label; $text):
  if ($text | type) != "string" or ($text | trim) == "" then []
  else
    ($text | split("\n")) as $ls
    | [range(0; $ls | length) as $i
        | if $i == 0 then "\($pad)\($label)\($ls[$i])"
          else "\($pad)\(" " * ($label | length))\($ls[$i])" end]
  end;

def tool_line($item):
  if ($item.tools | length) > 0 then ($item.tools | join(" "))
  elif $item.agent == "orchestrator" or $item.agent == "manager" then
    "create_task finish"
  else "read shell edit" end;

def task_heading($item; $panel):
  if $panel and (($item.title // "") | trim) != "" then $item.title else $item.goal end;

def render_list($list; $prefix; $depth; $panel):
  if ($list | type) != "array" then []
  else
    reduce range(0; $list | length) as $i ([];
      ($list[$i]) as $item
      | (" " * ($depth * 3)) as $pad
      | (if $prefix == "" then "\($i + 1)" else "\($prefix).\($i + 1)" end) as $label
      | . + ["\($pad)\($label). \(task_heading($item; $panel))"]
        + ["\($pad)   [\($item.status | ascii_upcase)] (\($item.agent) - \(tool_line($item)))"]
        + field_lines("\($pad)   "; "notes: "; $item.notes)
        + field_lines("\($pad)   "; "result: "; $item.result)
        + (if (($item.tasks // []) | length) > 0 then render_list($item.tasks; $label; $depth + 1; $panel) else [] end))
  end;

def panel_lines:
  if ((.goal // "") | trim) != "" then render_list([.]; ""; 0; true)
  else render_list(.tasks // []; ""; 0; true) end;

def panel_text:
  panel_lines | join("\n");

def visible_text($path):
  render_list(frame_tasks($path); ""; 0; false) | join("\n");

def can_create($frame; $agent):
  if $frame.role == "manager" and $agent != "coder" then "A manager can only create coders."
  elif $frame.role == "orchestrator" and (($frame.plan_path // []) | length) > 0 and $agent == "orchestrator" then
    "Only the top orchestrator can create an orchestrator. Use manager or coder."
  else null end;

def plan_create($fields):
  . as $s
  | ($s.stack[-1]) as $fr
  | ($fields | normalize) as $item
  | if $item == null then .last = "Error: create_task needs a goal"
    else
      can_create($fr; $item.agent) as $why
      | if $why then .last = "Error: \($why)"
        elif (frame_tasks($fr.plan_path) | any(.status == "pending" or .status == "running")) then
          .last = "Error: the next step already exists. Wait for its report, then create the next one."
        else
          .plan |= append_task($fr.plan_path; $item)
          | .last = "Task \(frame_tasks($fr.plan_path) | length) created."
        end
    end;

def plan_write($fields):
  .last = "Error: create the next step with create_task. Do not replace the plan.";

def plan_update($fields):
  .last = "Error: a task cannot be changed. Create the next step.";

def plan_delete($index):
  .last = "Error: a task cannot be removed. Create the next step.";

def plan_mark($frame; $rel; $status; $result):
  ($frame.plan_path + $rel) as $abs
  | .plan |= patch_in($abs; (.status = $status | if $result == null then . else .result = $result end))
  | .plan |= settle_from($abs);

def plan_notes($abs; $notes):
  .plan |= patch_in($abs; .notes = $notes);

def plan_notes_run($action; $content):
  .last = "Error: notes are set in create_task. A task is not updated.";
