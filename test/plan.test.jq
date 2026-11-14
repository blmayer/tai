include "plan";

def expect($n; $ok):
  if $ok then . else error($n) end;

{stack: [{role: "orchestrator", plan_path: [], depth: 0, task_notes: ""}], plan: empty_plan}
| plan_create({title: "Read me", goal: "Show the README file in full", agent: "coder", tools: ["read", "shell"]})
| expect("create"; .last == "Task 1 created." and .plan.tasks[0].title == "Read me")
| expect("panel title"; (.plan | panel_text | contains("Read me")) and ((.plan | panel_text | contains("Show the README file in full")) | not))
| plan_create({goal: "Run tests", agent: "coder", notes: "use make"})
| expect("one step"; (.last | startswith("Error: the next step already exists")) and (.plan.tasks | length) == 1)
| plan_mark(.stack[-1]; [1]; "running"; null)
| plan_update({index: "1", goal: "nope"})
| expect("no update"; (.last | startswith("Error: a task cannot be changed")) and .plan.tasks[0].goal == "Show the README file in full" and .plan.tasks[0].status == "running")
| plan_delete("1")
| expect("no delete"; (.last | startswith("Error: a task cannot be removed")) and (.plan.tasks | length) == 1 and .plan.tasks[0].status == "running")
| expect("panel"; (.plan | panel_text | contains("[RUNNING]")))
| plan_mark(.stack[-1]; [1]; "ok"; "done")
| plan_create({goal: "Run tests", agent: "coder", notes: "use make"})
| expect("next"; .last == "Task 2 created." and .plan.tasks[1].notes == "use make" and .plan.tasks[0].goal == "Show the README file in full")
| plan_delete("2")
| expect("kept"; (.last | startswith("Error: a task cannot be removed")) and (.plan.tasks | length) == 2 and .plan.tasks[1].notes == "use make")
, ({stack: [{role: "orchestrator", plan_path: [], depth: 0, task_notes: ""}], plan: empty_plan}
| plan_notes_run("write"; "nowhere")
| expect("notes refused"; (.last | startswith("Error: notes are set in create_task")) and .plan.notes == "")
| plan_create({goal: "Locate", agent: "coder", notes: "file a", tools: ["read", "shell"]})
| plan_notes_run("append"; "quote the lines")
| expect("notes stay"; .plan.tasks[0].notes == "file a" and (.last | startswith("Error: notes are set in create_task"))))
