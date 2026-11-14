include "fs";

def expect($n):
  if . == false or . == null then error($n) else . end;

("a\nb\nc\n" | read_range("2:3") == "2: b\n3: c") | expect("range")
| ("alpha  beta\ngamma\n" | edit("alpha beta"; "delta"; false) | .ok and (.text | startswith("delta"))) | expect("edit")
| ("keep\n" | edit("missing"; "x"; false) | (.ok | not) and (.err | contains("Call read on this file"))) | expect("miss")
| ("one\none\n" | edit("one"; "two"; true) | .text == "two\ntwo\n") | expect("multi")
