include "request";

def expect($n; $ok):
  if $ok then . else error($n) end;
def text($t):
  {choices: [{message: {role: "assistant", content: $t}}]};
def calls($cs):
  {choices: [{message: {role: "assistant", content: "", tool_calls: $cs}}]};
def call($id; $name; $args):
  {id: $id, type: "function", function: {name: $name, arguments: ($args | tojson)}};

(init | on_user("hi") | drive
  | expect("hi open"; .io.op == "request"
      and must_tool
      and ([.io.body.tools[].function.name] | sort) == ["answer","create_task"]
      and (.io.body.messages[0].content | contains("Call answer"))
      and (.io.body.messages[0].content | contains("smaller task"))
      and (.io.body.messages[0].content | contains("Set agent to orchestrator"))
      and (.io.body.messages[0].content | contains("The goal is what to investigate."))
      and (.io.body.messages[0].content | contains("An example must stay an example"))
      and (.io.body.messages[0].content | contains("Do not create a task whose goal is that the work is finished"))
      and (.io.body.messages[0].content | contains("so the next step is feasible"))
      and (.io.body.messages[0].content | contains("title is a few words for the plan"))
      and (.io.body.messages[0].content | contains("the first task quotes the code"))
      and (.io.body.messages[0].content | contains("states one problem from that report"))
      and (.io.body.messages[0].content | contains("If a check fails, create a new task for what failed."))
      and (.io.body.messages[0].content | contains("If you can answer without a change, call answer."))
      and ([.io.body.tools[].function | select(.name == "create_task") | .parameters.properties.tools.description][0] | contains("The change to one known file: read, shell, and edit."))
      and ([.io.body.tools[].function | select(.name == "create_task") | .parameters.properties.tools.description][0] | contains("The check: read and shell."))
      and (.io.body.messages[0].content | contains("explore, understand, design, implement, and test") | not)
      and (.io.body.messages[0].content | contains("You have no finish tool") | not)
      and (.io.body.messages[0].content | contains("Create managers and coders only") | not)))
, (init | on_user("change the parser") | drive
  | on_resp(calls([call("1"; "create_task"; {goal: "explore the parser", agent: "orchestrator"})])) | drive
  | expect("nested forced"; .stack[-1].role == "orchestrator" and must_tool
      and [.io.body.tools[].function.name] == ["create_task"]
      and (.io.body.messages[0].content | contains("Create managers and coders only"))
      and (.io.body.messages[0].content | contains("one manager for the next part"))
      and (.io.body.messages[0].content | contains("not the full report"))
      and (.io.body.messages[0].content | contains("should help the next steps"))
      and (.io.body.messages[0].content | contains("An example must stay an example"))
      and (.io.body.messages[0].content | contains("Do not grant edit"))
      and (.io.body.messages[0].content | contains("state one problem"))
      and (.io.body.messages[0].content | contains("Grant read and shell on every part."))
      and (.io.body.messages[0].content | contains("run the user's examples"))
      and (.io.body.messages[0].content | contains("requested task and the relevant findings"))
      and (.io.body.messages[0].content | contains("phase") | not)
      and (.io.body.messages[0].content | contains("call finish"))
      and (.io.body.messages[0].content | contains("A greeting is one short reply") | not)
      and (.io.body.messages[0].content | contains("You have no finish tool") | not))
  | on_resp(calls([call("m1"; "create_task"; {title: "Quote parser", goal: "quote the parser", agent: "manager", notes: "lines"})])) | drive
  | expect("manager prompt"; .stack[-1].role == "manager"
      and (.io.body.messages[0].content | contains("quote evidence, state one problem"))
      and (.io.body.messages[0].content | contains("Grant read and shell on every outcome."))
      and (.io.body.messages[0].content | contains("Grant edit only when the outcome is a change to one known file."))))
, (init | on_user("what is 2+2") | drive
  | on_resp(calls([call("a"; "answer"; {text: "4"})])) | drive
  | expect("answer"; .io.op == "idle" and .stack[0].phase == "handoff"
      and any(.io.say[]; .k == "C" and (.t | contains("4")))))
, (init | on_user("fix it") | drive
  | on_resp(calls([call("1"; "create_task"; {goal: "Show README", agent: "coder", tools: ["read", "shell"]})])) | drive
  | expect("spawn"; (.stack | length) == 2 and .stack[1].role == "coder" and .plan.tasks[0].status == "running"
      and (.io.body.messages[0].content | contains("If the goal asks for more than one change")))
  | on_resp(calls([call("2"; "finish"; {result: "README says hi"})])) | drive
  | expect("revisor"; .stack[-1].role == "revisor"
      and (.io.body.messages[0].content | contains("Fail an edit when the goal says must not edit."))
      and (.io.body.messages[0].content | contains("Fail a check that has no command output."))
      and (.io.body.messages[0].content | contains("Fail a change that is not the problem stated in the notes.")))
  | on_resp(calls([call("3"; "review"; {status: "pass", result: "fine"})])) | drive
  | expect("kept"; .plan.tasks[0].status == "ok" and .plan.tasks[0].result == "README says hi" and (.stack | length) == 1)
  | expect("review"; .stack[0].phase == "review" and .io.op == "request"
      and any(.io.body.messages[]; (.content // "") | contains("If a check failed, the next goal is that failed example.")))
  | on_resp(text("all done")) | drive
  | expect("handoff"; .io.op == "request" and .stack[0].phase == "handoff")
  | on_resp(text("Ship it.")) | drive
  | expect("done"; .io.op == "idle"))
, (init | on_user("fix the parser") | drive
  | on_resp(calls([call("n1"; "notes"; {action: "write", content: "find the file"})])) | drive
  | expect("notes refused"; (.last | contains("not granted")) and .plan.notes == "")
  | on_resp(calls([
      call("n2"; "create_task"; {title: "Quote lines", goal: "quote the lines", agent: "coder", notes: "file a", tools: ["read", "shell"]}),
      call("n3"; "create_task"; {goal: "design the change", agent: "orchestrator", notes: "later"})
    ])) | drive
  | expect("call shown"; any(.io.say[]; .k == "C" and (.t | contains("title: Quote lines")) and (.t | contains("goal: quote the lines")) and (.t | contains("notes: file a")) and (.t | contains("agent: coder")) and (.t | contains("tools: read shell"))))
  | expect("one step"; (.plan.tasks | length) == 1 and .plan.tasks[0].notes == "file a" and .stack[-1].role == "coder"))
, (init | on_user("run something") | drive
  | on_resp(calls([call("1"; "create_task"; {goal: "List files", agent: "coder", tools: ["shell"]})])) | drive
  | on_resp(calls([call("2"; "shell"; {command: "rm -rf x"})])) | drive
  | expect("approve"; .io.op == "approve" and (.io.prompt | contains("rm"))))
