include "plan";

def cfg: $cfg[0];
def known:
  ["read","shell","send_image","edit","write","notes","plan","create_task","update_task","delete_task","review","finish","answer","skill","mcp"];

def say_at($d; $k; $t):
  .io.say += [{d: $d, k: $k, t: $t}];
def say($k; $t):
  say_at((.stack[-1].depth // 0); $k; $t);

def top: (.stack | length) <= 1;
def iterates:
  (.stack[-1].role == "coder")
  or ((.stack[-1].role == "orchestrator" or .stack[-1].role == "manager") and .stack[-1].isolated == true);
def review_turn:
  (.stack[-1].role == "orchestrator" or .stack[-1].role == "manager") and .stack[-1].phase == "review";

def weak($s):
  if $s == null or ($s | type) != "string" then true
  else ($s | ascii_downcase | trim) as $t
    | $t == "" or $t == "no" or $t == "ok" or $t == "yes" or $t == "leaf"
      or ($t | test("^no[,.]")) or ($t | test("^ok[,.]"))
      or ($t | test("^it is a leaf")) or ($t | test("^this is a leaf"))
      or ($t | test("^looks good")) or ($t | test("^do not update"))
      or ($t | test("^no update")) or ($t | test("^plan is fine"))
  end;

def said_leaf($s):
  if ($s | type) != "string" then false
  else ($s | ascii_downcase) as $t
    | ($t | test("^leaf")) or ($t | contains("it is a leaf")) or ($t | contains("this is a leaf"))
      or ($t | contains("already one action")) or ($t | contains("single action"))
  end;

def tools_for($role; $list):
  if $role == "revisor" then ["review"]
  elif $role == "orchestrator" or $role == "manager" then
    ["create_task","finish"]
  else
    [($list // [])[] | select(. as $n | known | index($n))] as $out
    | if ($out | length) == 0 then ["read","shell","edit","finish"]
      else
        $out
        | if (index("read") or index("shell") or index("edit") or index("write"))
            then (if index("read") then . else ["read"] + . end | if index("shell") then . else . + ["shell"] end)
          else . end
        | if index("finish") then . else . + ["finish"] end
      end
  end;

def open_reply:
  top
  and .stack[-1].role == "orchestrator"
  and .stack[-1].phase == "decompose"
  and ((frame_tasks(.stack[-1].plan_path) | length) == 0);

def request_tools:
  (.stack[-1]) as $fr
  | if ($fr.role == "orchestrator" or $fr.role == "manager") and $fr.phase == "decompose"
       and ((frame_tasks($fr.plan_path) | length) == 0) and (open_reply | not) then ["create_task"]
    else ($fr.tools // []) end;

def blurb($n):
  {"notes": "read/write this task's notes",
   "review": "verdict pass or fail, plus result and notes",
   "plan": "action=write|update|status",
   "answer": "answer the user. Otherwise create one smaller task",
   "create_task": "add one smaller task. title is a few words for the plan",
   "update_task": "refused. A task cannot be changed",
   "delete_task": "refused. A task cannot be removed",
   "finish": "store the answer on this task",
   "read": "open a file or line range, not a directory",
   "shell": "run a command in the project root",
   "edit": "replace text in a file",
   "write": "create a file",
   "send_image": "show an image to the model",
   "skill": "list, load, or unload a skill",
   "mcp": "status, connect, or call an MCP tool"}[$n] // "";

def catalog:
  . as $s
  | if (($s.skill_catalog // []) | length) == 0 then ""
    else
      "## Available Skills\n\nUse the skill tool with action load when one of these fits.\n\n"
      + ([$s.skill_catalog[]
          | "- \(.name): \(.desc)"
            + (if $s.skill_bodies[.name] != null then " [loaded]" else "" end)] | join("\n"))
    end;

def prompt_for($role):
  if $role == "coder" then ($pcoder | gsub("@ROOT@"; $root)) + "\n" + $pguide
  elif $role == "revisor" then ($prev | gsub("@ROOT@"; $root))
  elif $role == "manager" then ($pman | gsub("@ROOT@"; $root))
  elif top | not then ($pnest | gsub("@ROOT@"; $root))
  else
    (if (cfg.system_prompt | type) == "string" and cfg.system_prompt != "" then cfg.system_prompt
     else ($porch | gsub("@ROOT@"; $root)) end)
    + (if (cfg.custom_prompt | type) == "string" and cfg.custom_prompt != "" then "\n" + cfg.custom_prompt else "" end)
    + (catalog | if . == "" then "" else "\n\n" + . end)
  end;

def indented($text):
  if ($text | type) != "string" or $text == "" then ""
  else $text | split("\n") | map("   " + .) | join("\n") end;

def siblings($fr):
  ($fr.plan_path // []) as $path
  | if ($path | length) == 0 then ""
    else
      frame_tasks($path[:-1]) as $tasks
      | ($path[-1]) as $my
      | [range(0; $my - 1) as $i | $tasks[$i]
          | "\($i + 1). \(.goal) [\(.status | ascii_upcase)]"
            + (if (.result // "") == "" then "" else "\n" + indented(.result) end)] as $lines
      | if ($lines | length) == 0 then ""
        else "Previous tasks on this branch (use these; do not repeat the search):\n" + ($lines | join("\n"))
        end
    end;

def progress($fr):
  ($fr.steps // []) as $steps
  | if ($steps | length) == 0 then ""
    else
      "Previous steps at this level:\n"
      + ([range(0; $steps | length) as $i | $steps[$i]
          | "\($i + 1). \(.text // "")" + (if .status == "blocked" then " [blocked]" else "" end)
            + (if (.response // "") == "" then "" else "\n" + indented(.response) end)] | join("\n"))
      + (if $fr.role == "orchestrator" then
          "\n\n" + (if $steps[-1].status == "blocked"
            then "Last task failed. That task stays. Create the next step from what it reported."
            else "Last task was recorded. Create the next step from this report. Do not change a task that exists." end)
        else "" end)
    end;

def loaded_text:
  . as $s
  | [$s.skill_bodies // {} | to_entries[] | "### Skill: \(.key)\n\n\(.value)"]
  | if length == 0 then "" else "Loaded skills:\n" + join("\n\n---\n\n") end;

def live($fr):
  [siblings($fr), progress($fr), loaded_text] | map(select(. != ""))
  | if length == 0 then ""
    else "========== LIVE CONTEXT ==========\n\n" + join("\n\n") end;

def task_block($fr):
  ((.plan | node_at($fr.plan_path).notes) // $fr.task_notes // "") as $n
  | if ($n | trim) == "" then ""
    else "========== TASK NOTES ==========\n\n" + $n end;

def plan_block($fr):
  if $fr.role != "orchestrator" and $fr.role != "manager" then ""
  else
    visible_text($fr.plan_path) as $body
    | if $body == "" then ""
      else "========== PLAN ==========\n\n\($body)\n\n========== END PLAN ==========" end
  end;

def handoff_line($fr):
  if ($fr.role != "orchestrator" and $fr.role != "manager") or $fr.phase != "handoff" then ""
  elif $fr.isolated then "Nothing is pending. Call finish. Set result to the conclusion. Include short discoveries from the reports."
  else
    (progress($fr) | if . == "" then "" else . + "\n" end)
    + "Nothing is pending. Call answer with the conclusion for the user, or create one smaller task if you still need one."
  end;

def system_text:
  (.stack[-1]) as $fr
  | [prompt_for($fr.role),
     (request_tools as $names
       | if ($names | length) == 0 then ""
         else "You may call only:\n" + ([$names[] | "- " + . + (blurb(.) | if . == "" then "" else ": " + . end)] | join("\n")) end),
     (if $fr.role == "coder" then task_block($fr) else "" end),
     plan_block($fr),
     handoff_line($fr),
     (if $fr.isolated and $fr.role != "coder" and (review_turn | not) then live($fr) else "" end),
     (if ($mcptext // "") == "" then "" else "========== MCP ==========\n" + $mcptext end)]
  | map(select(. != null and . != "")) | join("\n\n");

def review_packet:
  (.stack[-1].last_review // {}) as $r
  | "A task just finished.\nGoal: \($r.goal // "")\n\nCoder result:\n\($r.coder_result // "(no output)")\n\nReviewer: \($r.status // "fail")"
    + (if ($r.result // "") == "" then "" else "\n" + $r.result end)
    + (if ($r.notes // "") == "" then "" else "\n\nReviewer notes:\n" + $r.notes end)
    + "\n\nCheck the goal, the plan, and the result. Create the next step from the important parts of the result. Each next step must contribute to fulfilling the goal. Do not repeat work the result already finished, and do not add a step the goal did not ask for. If the reviewer failed, that goal is not done. If the result shows the problem was wrong, the next goal restates the problem and says must not edit. If a check failed, the next goal is that failed example. Do not create a task whose goal is that the work is finished. Do not replace an example with a different claim. "
    + ((.stack[-1]) as $fr
       | if $fr.role == "orchestrator" and $fr.isolated then
           "This result should help the next steps. Create that part only if this goal still needs it. Put only the important parts of this result in its notes, not the full result. If this goal is covered, call finish."
         elif top then
           "If this is enough to answer the user, call answer. Otherwise create one smaller task that helps you answer, and put this report in its notes."
         else
           "This result is the report the next step needs. Create only the next part or outcome, and put this report in its notes. Do not give the next agent the whole task."
         end)
    + " Call create_task for that next step only. A task cannot be changed after it is created.";

def messages:
  (.stack[-1]) as $fr
  | (if review_turn then []
     elif $fr.isolated and (iterates | not) then
       (if ($fr.goal // "") == "" then [] else [{role: "user", content: $fr.goal}] end)
     else ($fr.history // []) end) as $hist
  | ([{role: "system", content: system_text}] + $hist
     + (if review_turn then [{role: "user", content: review_packet}] else [] end))
  | if (.[-1].role == "assistant") then . + [{role: "user", content: "Continue."}] else . end;

def tool_defs($names):
  if cfg.use_tools == false then []
  else [ $names[] | $tools[0][.] | select(. != null) ] end;

def with_options($body):
  reduce (cfg.options // {} | to_entries[]) as $e ($body; .[$e.key] = $e.value);

def must_tool: true;

def chat_body:
  request_tools as $names
  | tool_defs($names) as $defs
  | with_options({
      model: cfg.model,
      messages: messages
    } + (if ($defs | length) > 0 then {tools: $defs} else {} end)
      + (if cfg.provider == "llama_cpp" and must_tool and ($defs | length) > 0 then {tool_choice: "required"} else {} end)
      + (if cfg.think != null then {reasoning_effort: cfg.think} else {} end)
      + (if cfg.stream == true then {stream: true} else {} end));

def to_input($msg):
  if $msg.role == "system" or $msg.role == "user" then
    [{role: $msg.role, content: [{type: "input_text", text: ($msg.content // "")}]}]
  elif $msg.role == "assistant" then
    [{role: "assistant", content: [{type: "output_text", text: ($msg.content // "")}]}]
    + [($msg.tool_calls // [])[] | {type: "function_call", name: .function.name, call_id: .id, arguments: (.function.arguments // "{}")}]
  elif $msg.role == "tool" then
    [{type: "function_call_output", call_id: $msg.tool_call_id, output: (if ($msg.content | type) == "string" then $msg.content else ($msg.content | tojson) end)}]
  else [] end;

def responses_body:
  request_tools as $names
  | with_options({
      model: cfg.model,
      input: [messages[] | to_input(.)[]],
      store: false,
      tools: [tool_defs($names)[] | .function + {type: "function", strict: true}]
    });

def at_limit:
  .stack[-1].role == "coder" and ((.stack[-1].turns // 0) >= 32);

def build:
  if at_limit then
    say("M"; "ERROR [turn limit]: coder turn limit")
    | .stack[-1].skip_review = true
    | .fs = "error"
    | .ft = "ERROR [turn limit]: coder turn limit"
    | .go = "finish"
  else
    .stack[-1].turns = ((.stack[-1].turns // 0) + 1)
    | .io.op = "request"
    | .io.status = "waiting"
    | .io.label = .stack[-1].role
    | .io.ctx = (.last_ctx // 0)
    | .io.body = (if cfg.provider == "openai_responses" then responses_body else chat_body end)
    | .go = null
  end;

def push_child($step; $item):
  (.stack[-1]) as $parent
  | (if ($item.agent // "coder") == "coder" and (($item.tasks // []) | length) > 0 then "manager" else ($item.agent // "coder") end) as $role
  | tools_for($role; $item.tools) as $tools
  | (if (($item.title // "") | trim) != "" then $item.title else ($item.goal // "") end) as $shown
  | say_at($parent.depth; "M"; (($role | ascii_upcase) + " " + $shown + " [" + step_str($step) + "]"))
  | (if ($tools | length) > 0 then say_at($parent.depth + 1; "T"; "tools: " + ($tools | join(", "))) else . end)
  | .stack += [{
      role: $role,
      phase: (if $role == "orchestrator" or $role == "manager" then "decompose" else null end),
      goal: ($item.goal // ""),
      depth: ($parent.depth + 1),
      isolated: true,
      turns: 0,
      history: (if ($item.goal // "") == "" then [] else [{role: "user", content: $item.goal}] end),
      plan_path: ($parent.plan_path + $step),
      plan_step: $step,
      tools: $tools,
      task_notes: ($item.notes // ""),
      finish_result: null,
      steps: [],
      label: $role,
      tool_outputs: []
    }];

def start_next:
  (.stack[-1]) as $fr
  | find_pending(frame_tasks($fr.plan_path)) as $hit
  | if $hit == null then .started = false
    elif (.stack | length) >= 8 then
      plan_mark($fr; $hit.path; "error"; "max depth reached") | .started = false
    else
      plan_mark($fr; $hit.path; "running"; null)
      | push_child($hit.path; $hit.item)
      | .started = true
    end;

def outcome_of($fr; $text):
  if ($fr.finish_result | type) == "string" and ($fr.finish_result | trim) != "" then $fr.finish_result
  elif ($text | type) == "string" and (weak($text) | not) then $text
  elif (($fr.tool_outputs // []) | length) > 0 then ($fr.tool_outputs | join("\n\n"))
  elif ($text | type) == "string" and $text != "" then $text
  else "(no output)" end;

def transcript_of($fr; $outcome):
  "Result:\n" + $outcome
  + (if (($fr.tool_outputs // []) | length) > 0 then "\n\nCommand output:\n" + ($fr.tool_outputs | join("\n\n")) else "" end);

def revisor_goal($goal; $tr):
  "Goal:\n\($goal // "")\n\nTranscript:\n\($tr)\n\nCall the review tool once.\npass: the plan item keeps the coder's result. Do not replace it.\nfail: result is stored on the plan item. Keep it short: what was done and what is missing.\npass: the Goal was done.\nfail: do not retry.";

def push_revisor($child; $conclusion; $tr):
  (.stack[-1]) as $parent
  | (revisor_goal($child.goal; $tr)) as $goal
  | say_at($parent.depth; "M"; "REVISOR " + ($child.goal // ""))
  | .stack += [{
      role: "revisor",
      phase: null,
      goal: $goal,
      depth: ($parent.depth + 1),
      isolated: true,
      turns: 0,
      history: [],
      plan_path: $parent.plan_path,
      tools: ["review"],
      review_step: $child.plan_step,
      review_fallback: $conclusion,
      finish_result: null,
      steps: [],
      label: "revisor",
      tool_outputs: []
    }];

def finish_up($status; $text):
  if top then .io.op = "idle" | .io.status = "idle" | .go = null
  else
    (.stack[-1]) as $fr
    | outcome_of($fr; $text) as $outcome
    | transcript_of($fr; $outcome) as $tr
    | (if $status == "error" or ($outcome | startswith("ERROR ")) then "error" else "ok" end) as $st
    | (if $st == "error" then (if $outcome == "" then "error" else $outcome end)
       elif $outcome != "" and $outcome != "(no output)" then $outcome else "done" end) as $conclusion
    | ("status: " + $st + "\nstep: " + ($fr.goal // "") + "\n" + (if $st == "ok" then "report:\n" else $st + ": " end) + $outcome) as $report
    | .stack = .stack[:-1]
    | .stack[-1].steps += [{text: ($fr.goal // ""), response: $report, status: $st}]
    | .stack[-1].last_child_goal = $fr.goal
    | .stack[-1].last_finish_result = $fr.finish_result
    | .stack[-1].last_child_step = $fr.plan_step
    | .stop = false
    | if $fr.skip_review then
        (if ($fr.plan_step | type) == "array" then plan_mark(.stack[-1]; $fr.plan_step; "blocked"; $conclusion) else . end)
        | .stack[-1].phase = "review"
        | .stack[-1].last_review = {status: "fail", result: $conclusion, notes: "", coder_result: $conclusion, goal: $fr.goal}
        | .go = "build"
      elif .stack[-1].role == "orchestrator" or .stack[-1].role == "manager" then
        push_revisor($fr; $conclusion; $tr) | .go = "build"
      else
        (if ($fr.plan_step | type) == "array" then plan_mark(.stack[-1]; $fr.plan_step; (if $st == "ok" then "ok" else "error" end); $conclusion) else . end)
        | .io.op = "idle" | .io.status = "idle" | .go = null
      end
  end;

def finish_revisor:
  (.stack[-1]) as $rev
  | ($rev.review // {}) as $rv
  | (if $rv.status == "pass" then "pass" else "fail" end) as $verdict
  | .stack = .stack[:-1]
  | (.stack[-1].last_finish_result // $rev.review_fallback // "") as $agent
  | (if $verdict == "pass" then $agent
     elif ($rv.result // "") != "" then $rv.result
     else $agent end) as $result
  | (if ($rev.review_step | type) == "array" then
      plan_mark(.stack[-1]; $rev.review_step; (if $verdict == "pass" then "ok" else "blocked" end); $result)
      | if ($rv.notes // "") != "" then plan_notes(.stack[-1].plan_path + $rev.review_step; $rv.notes) else . end
    else . end)
  | .stack[-1].last_review = {
      status: $verdict, result: $result, notes: ($rv.notes // ""),
      coder_result: ($rev.review_fallback // ""), goal: .stack[-1].last_child_goal
    }
  | .stack[-1].phase = "review"
  | say("M"; "review " + $verdict)
  | .go = "build";

def decompose($text):
  if said_leaf($text) then
    (if (frame_tasks(.stack[-1].plan_path) | length) == 0 then
      plan_create({goal: (.stack[-1].goal // $text), agent: "coder", notes: (.stack[-1].task_notes // ""), tools: ["read","shell","edit","finish"]})
    else . end)
    | start_next
    | if .started then .go = "build" else .io.op = "idle" | .io.status = "idle" | .go = null end
  elif .stack[-1].continue_after_tools or (top | not) then .go = "build"
  else .io.op = "idle" | .io.status = "idle" | .go = null end;

def after_orch($text):
  if .stack[-1].phase == "review" then
    start_next
    | if .started then .go = "build"
      else
        .stack[-1].phase = "handoff"
        | if (top | not) and ($text | type) == "string" and (weak($text) | not) then finish_up("ok"; $text)
          else .go = "build" end
      end
  else
    start_next
    | if .started then .go = "build"
      elif .stack[-1].phase == "decompose" then decompose($text)
      elif (top | not) and .stack[-1].phase != "run" and .stack[-1].phase != "handoff" then
        if ($text | type) == "string" and (weak($text) | not) and $text != "" then finish_up("ok"; $text)
        else .stack[-1].phase = "handoff" | .go = "build" end
      elif .stack[-1].phase == "run" or .stack[-1].phase == "handoff" then
        .stack[-1].phase = "handoff" | .go = "build"
      else .io.op = "idle" | .io.status = "idle" | .go = null end
  end;

def after_tools:
  (.stack[-1]) as $fr
  | if top and (($fr.answer_text // "") | trim) != "" then
      .io.op = "idle" | .io.status = "idle" | .go = null
    elif ($fr.finish_result | type) == "string" and $fr.finish_result != ""
       and ($fr.role == "coder" or $fr.role == "orchestrator" or $fr.role == "manager") then
      finish_up("ok"; $fr.finish_result)
    elif ($fr.role == "orchestrator" or $fr.role == "manager")
         and ($fr.phase == "decompose" or $fr.phase == "review" or $fr.phase == "handoff") then
      after_orch($fr.last_assistant // "")
    elif $fr.role == "revisor" then finish_revisor
    elif (top | not) and ($fr.continue_after_tools | not) and ($fr.role != "coder")
         and ((($fr.role == "orchestrator" or $fr.role == "manager") and $fr.isolated) | not) then
      finish_up("ok"; $fr.last_assistant // "")
    else
      (if $fr.isolated and ($fr.role != "coder")
          and ($fr.role != "orchestrator" and $fr.role != "manager") then
        .stack[-1].history = (if ($fr.goal // "") == "" then [] else [{role: "user", content: $fr.goal}] end)
       else . end)
      | .go = "build"
    end;

def args_of($call):
  ($call.function.arguments // "{}") | if type == "object" then . else (try fromjson catch {}) end;

def record($call; $content):
  .stack[-1].history += [{role: "tool", name: $call.function.name, tool_call_id: $call.id, content: $content}]
  | if ($content | type) == "string" then .stack[-1].tool_outputs += [$content] else . end;

def call_line($name; $a):
  if $name == "notes" then
    "notes " + ($a.action // "") + "\n" + ($a.content // "")
  elif $name == "create_task" then
    "create_task"
    + "\ntitle: " + ($a.title // "")
    + "\nagent: " + ($a.agent // "coder")
    + "\ngoal: " + ($a.goal // "")
    + "\nnotes: " + ($a.notes // "")
    + "\ntools: " + (if (($a.tools // []) | length) == 0 then "" else ($a.tools | join(" ")) end)
  elif $name == "answer" then
    "answer\n" + ($a.text // "")
  elif $name == "update_task" then
    "update_task " + (($a.index // "") | tostring)
    + (if ($a.goal // "") == "" then "" else "\n" + $a.goal end)
    + (if $a.notes == null then "" else "\n" + $a.notes end)
    + (if $a.agent == null then "" else "\nagent: " + ($a.agent | tostring) end)
    + (if (($a.tools // []) | length) == 0 then "" else "\ntools: " + ($a.tools | join(" ")) end)
  elif $name == "delete_task" then
    "delete_task " + (($a.index // "") | tostring)
  elif $name == "finish" then
    "finish\n" + ($a.result // "")
  elif $name == "review" then
    "review " + ($a.status // "")
    + "\n" + ($a.result // "")
    + (if ($a.notes // "") == "" then "" else "\n" + $a.notes end)
  elif $name == "plan" then
    "plan " + ($a.action // "")
    + (if ($a.goal // "") == "" then "" else "\n" + $a.goal end)
    + (if ($a.notes // "") == "" then "" else "\n" + $a.notes end)
  else $name end;

def show_call($name; $a):
  say("C"; call_line($name; $a))
  | if (.last | type) == "string" and (.last | startswith("Error")) then say("M"; .last) else . end;

def apply_pure($call):
  args_of($call) as $a
  | ($call.function.name) as $name
  | if $name == "finish" then
      if ($a.result | type) != "string" or ($a.result | trim) == "" then
        .last = "Error: result is empty" | .stack[-1].continue_after_tools = true | show_call($name; $a)
      else
        .stack[-1].finish_result = ($a.result | trim)
        | .last = "Finished."
        | show_call($name; $a)
      end
    elif $name == "review" then
      if $a.status != "pass" and $a.status != "fail" then .last = "Error: status must be pass or fail" | show_call($name; $a)
      elif ($a.result | type) != "string" or $a.result == "" then .last = "Error: result is required" | show_call($name; $a)
      else
        .stack[-1].review = {status: $a.status, result: $a.result, notes: (if ($a.notes | type) == "string" then $a.notes else "" end)}
        | .last = "Review recorded (\($a.status))."
        | show_call($name; $a)
      end
    elif $name == "notes" then
      plan_notes_run($a.action; $a.content)
      | .stack[-1].continue_after_tools = true
      | show_call($name; $a)
    elif $name == "answer" then
      if (top | not) then
        .last = "Error: answer is only for the top orchestrator. Call finish."
        | .stack[-1].continue_after_tools = true
        | show_call($name; $a)
      elif (frame_tasks(.stack[-1].plan_path) | any(.status == "pending" or .status == "running")) then
        .last = "Error: a task is still open. Wait for its report, then call answer."
        | .stack[-1].continue_after_tools = true
        | show_call($name; $a)
      elif ($a.text | type) != "string" or ($a.text | trim) == "" then
        .last = "Error: answer text is empty"
        | .stack[-1].continue_after_tools = true
        | show_call($name; $a)
      elif ((.stack[-1].answer_text // "") | trim) != "" then
        .last = "Error: already answered."
        | show_call($name; $a)
      else
        .stack[-1].answer_text = ($a.text | trim)
        | .stack[-1].phase = "handoff"
        | .last = "Answered."
        | say("A"; .stack[-1].answer_text)
      end
    elif $name == "create_task" then
      if ((.stack[-1].answer_text // "") | trim) != "" then
        .last = "Error: already answered."
        | show_call($name; $a)
      else
        plan_create($a) | .stack[-1].continue_after_tools = true | show_call($name; $a)
      end
    elif $name == "update_task" then
      plan_update($a) | .stack[-1].continue_after_tools = true | show_call($name; $a)
    elif $name == "delete_task" then
      plan_delete($a.index) | .stack[-1].continue_after_tools = true | show_call($name; $a)
    elif $name == "plan" then
      (if $a.action == "write" then plan_write($a)
       elif $a.action == "update" then plan_update($a)
       elif $a.action == "status" then .last = (visible_text(.stack[-1].plan_path) | if . == "" then "No plan." else . end)
       else .last = "Error: unknown action '\($a.action // "")'" end)
      | .stack[-1].continue_after_tools = true
      | show_call($name; $a)
    else .last = "Error: unknown tool \($name)" end
  | record($call; .last);

def allow:
  if cfg.allowed_commands == null then
    ["cat","grep","ag","rg","ls","head","tail","wc","diff","sort","uniq","find","file","stat","date","echo","tree","pwd","which","type"]
  elif (cfg.allowed_commands | type) == "object" then cfg.allowed_commands | keys
  elif (cfg.allowed_commands | type) == "array" then cfg.allowed_commands
  else [] end;

def shell_base($cmd):
  [$cmd | trim | splits("\\s+")] as $w
  | ($w[0] // "" | split("/")[-1]) as $b
  | if ($b | contains("=")) then ($w[1] // "" | split("/")[-1]) else $b end;

def shell_block($cmd):
  if ($cmd | type) != "string" or ($cmd | trim) == "" then "missing"
  elif $cmd | test("[><]") then "redirect"
  elif (allow | index(shell_base($cmd))) then null
  else "denied" end;

def drain_go:
  if (.queue | length) == 0 then after_tools
  else
    .queue[0] as $call
    | .queue = .queue[1:]
    | .ran = $call
    | if ((.stack[-1].tools // []) | index($call.function.name)) == null then
        .last = "Tool `\($call.function.name)` is not granted."
        | say("T"; .last) | record($call; .last) | drain_go
      elif (["notes","create_task","update_task","delete_task","plan","finish","review","answer"] | index($call.function.name)) != null then
        apply_pure($call) | drain_go
      elif $call.function.name == "shell" then
        (args_of($call).command // "") as $cmd
        | shell_block($cmd) as $why
        | if $why == "missing" then
            .last = "missing command field" | say("T"; .last) | record($call; .last) | drain_go
          elif $why == null or cfg.auto_approve == true then
            .io.op = "tool" | .io.tool = $call | .io.status = "tools" | .io.label = .stack[-1].role | .go = null
          else
            .await = {command: $cmd}
            | .io.op = "approve" | .io.prompt = $cmd | .io.status = "tools" | .io.tool = $call | .go = null
          end
      else
        .io.op = "tool" | .io.tool = $call | .io.status = "tools" | .io.label = .stack[-1].role | .go = null
      end
  end;

def as_text($c):
  if $c == null then ""
  elif ($c | type) == "string" then $c
  elif ($c | type) == "array" then [$c[]? | .text // empty] | join("")
  else ($c | tostring) end;

def norm_call($c; $i):
  {id: ($c.id // $c.call_id // "call_\($i)"),
   type: "function",
   function: {
     name: ($c.function.name // $c.name // ""),
     arguments: (
       if ($c.function.arguments | type) == "string" then $c.function.arguments
       elif $c.function.arguments != null then ($c.function.arguments | tojson)
       elif ($c.arguments | type) == "string" then $c.arguments
       elif $c.arguments != null then ($c.arguments | tojson)
       else "{}" end)}};

def parse_resp($r):
  if $r == null then {error: "ERROR [provider]: empty provider response"}
  elif ($r.error | type) == "string" then {error: $r.error}
  elif $r.error != null then
    {error: ("ERROR [provider]: " + (if ($r.error | type) == "object" then ($r.error.message // ($r.error | tostring)) else ($r.error | tostring) end))}
  elif ($r.choices | type) == "array" then
    ($r.choices[0].message // {}) as $m
    | {content: as_text($m.content),
       reasoning: as_text($m.reasoning_content // $m.reasoning // ""),
       calls: [($m.tool_calls // []) | to_entries[] | norm_call(.value; .key)],
       usage: ($r.usage.total_tokens // null)}
  elif ($r.output | type) == "array" then
    {content: ([$r.output[] | select(.type == "message") | .content[]? | .text // empty] | join("")),
     reasoning: "",
     calls: [$r.output | to_entries[] | select(.value.type == "function_call") | norm_call(.value; .key)],
     usage: ($r.usage.total_tokens // null)}
  else {error: "ERROR [provider]: empty provider response"} end;

def on_text($text):
  (.stack[-1]) as $fr
  | if ($fr.role == "orchestrator" or $fr.role == "manager")
       and ($fr.phase == "decompose" or $fr.phase == "review") then after_orch($text)
    elif top | not then
      finish_up(if ($text | type) == "string" and ($text | startswith("ERROR ")) then "error" else "ok" end; $text)
    else .io.op = "idle" | .io.status = "idle" | .io.label = $fr.role | .go = null end;

def on_resp($r):
  parse_resp($r) as $p
  | if $p.error != null then
      say("M"; $p.error)
      | .stack[-1].history += [{role: "assistant", content: $p.error}]
      | if top | not then finish_up("error"; $p.error)
        else .io.op = "idle" | .io.status = "idle" | .go = null end
    else
      (if $p.usage != null then .last_ctx = $p.usage | .io.ctx = $p.usage else . end)
      | .stack[-1].last_assistant = $p.content
      | (if $p.reasoning != "" then say("T"; $p.reasoning) else . end)
      | (if $p.content != "" then say("A"; $p.content) else . end)
      | (if (review_turn | not) or ($p.calls | length) > 0 then
          .stack[-1].history += [{role: "assistant", content: $p.content, tool_calls: $p.calls}]
        else . end)
      | if ($p.calls | length) == 0 then on_text($p.content)
        else .queue = $p.calls | .stack[-1].continue_after_tools = false | drain_go end
    end;

def on_tool($out):
  (.ran) as $call
  | if ($image // "") != "" then
      .stack[-1].history += [{role: "tool", name: $call.function.name, tool_call_id: $call.id, content: ($image | fromjson)}]
      | .stack[-1].tool_outputs += ["image sent"]
    else record($call; $out) end
  | .ran = null
  | drain_go;

def on_approve($ans):
  ($ans | trim | ascii_downcase) as $a
  | (.ran) as $call
  | if $a == "y" or $a == "yes" then
      .io.op = "tool" | .io.tool = $call | .io.status = "tools" | .await = null | .go = null
    elif $a == "s" or $a == "stop" then
      .last = "User stopped execution."
      | say("T"; .last) | record($call; .last) | .ran = null | .queue = []
      | if top | not then .stack[-1].skip_review = true | finish_up("error"; "ERROR [stopped]: Stopped by user")
        else .io.op = "idle" | .io.status = "idle" | .go = null end
    else
      .last = "User declined running this command: " + $ans
      | say("T"; .last) | record($call; .last) | .ran = null | .await = null | drain_go
    end;

def on_stop:
  say("M"; "[tai] Stopped by user")
  | .queue = []
  | if top | not then .stack[-1].skip_review = true | finish_up("error"; "ERROR [stopped]: Stopped by user")
    else .io.op = "idle" | .io.status = "idle" | .go = null end;

def main_tools: ["answer","create_task"];

def init:
  {stack: [{
      role: "orchestrator", phase: "decompose", goal: "", depth: 0, isolated: false,
      turns: 0, history: [], plan_path: [], tools: main_tools, finish_result: null,
      steps: [], task_notes: "", label: "orchestrator", tool_outputs: []
    }],
   plan: empty_plan, skill_bodies: {}, skill_catalog: [], last_ctx: 0, queue: [],
   stop: false, ran: null, go: null,
   io: {op: "idle", status: "idle", label: "orchestrator", say: [], ctx: 0}};

def on_user($text):
  say("U"; $text)
  | .stack[0].history += [{role: "user", content: $text}]
  | .stack[0].goal = $text
  | .stack[0].finish_result = null
  | .stop = false
  | if .stack[0].phase == null or .stack[0].phase == "handoff" or ((.plan.tasks // []) | length) == 0 then
      .stack[0].phase = "decompose"
    else . end
  | .go = "build";

def blank_io:
  .go = null
  | .io = {say: [], op: "idle", status: (.io.status // "idle"),
         label: (.stack[-1].role // "orchestrator"), ctx: (.last_ctx // 0)};

def fold_sse:
  reduce .[] as $e (
    {content: "", reasoning: "", calls: []};
    ($e.choices[0].delta // $e.delta // {}) as $d
    | .content += ($d.content // "")
    | .reasoning += ($d.reasoning_content // $d.reasoning // "")
    | if ($d.tool_calls | type) == "array" then
        reduce $d.tool_calls[] as $c (.;
          ($c.index // 0) as $i
          | .calls[$i].id = ((.calls[$i].id // "") + ($c.id // ""))
          | .calls[$i].type = "function"
          | .calls[$i].function.name = ((.calls[$i].function.name // "") + ($c.function.name // ""))
          | .calls[$i].function.arguments = ((.calls[$i].function.arguments // "") + ($c.function.arguments // "")))
      else . end
    | if ($e.usage.total_tokens // null) != null then .usage = $e.usage.total_tokens else . end
  )
  | {choices: [{message: {
      role: "assistant", content: .content, reasoning_content: .reasoning,
      tool_calls: [.calls[] | select(type == "object" and ((.function.name // "") != ""))]
    }}], usage: (if .usage then {total_tokens: .usage} else null end)};

def drive:
  if .go == null then .
  elif .go == "build" then .go = null | build | drive
  elif .go == "finish" then .go = null | finish_up(.fs; .ft) | drive
  else error("bad go " + (.go | tostring)) end;

def dispatch:
  if $op == "init" then init
  else
    blank_io
    | if $op == "user" then on_user($text)
      elif $op == "resp" then on_resp($resp[0])
      elif $op == "tool" then on_tool($result)
      elif $op == "approve" then on_approve($text)
      elif $op == "stop" then on_stop
      elif $op == "skills" then .skill_catalog = ($skills[0] // [])
      else error("bad op") end
    | drive
  end;
