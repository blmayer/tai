# File edit / read helpers. Input is the file text.

def normline:
  gsub("\\s+"; " ") | gsub("^\\s+|\\s+$"; "");

def lines:
  if . == "" then [""] else split("\n") end;

def numbered($from; $to):
  lines as $ls
  | [range($from; $to + 1) | "\(.)" + ": " + $ls[. - 1]]
  | join("\n");

def read_range($range):
  lines as $ls
  | ($ls | length) as $n
  | if $range == null or $range == "" then numbered(1; $n)
    else
      (if $range == "$" then {a: (-1), b: (-1)}
       elif $range | test("^-\\d+:\\$$") then {a: ($range | sub(":\\$$"; "") | tonumber), b: (-1)}
       elif $range | test("^\\d+:\\$$") then {a: (($range | sub(":\\$$"; "") | tonumber) - 1), b: (-1)}
       elif $range | test("^\\d+:\\d+$") then
         ($range | split(":")) as $p | {a: (($p[0] | tonumber) - 1), b: (($p[1] | tonumber) - 1)}
       elif $range | test("^\\d+$") then
         ($range | tonumber) as $k | if $k == 0 then {a: 0, b: 0} else {a: ($k - 1), b: ($k - 1)} end
       else null end) as $r
      | if $r == null then "Error: Invalid range \($range)"
        else
          (if $r.a < 0 then $n + $r.a else $r.a end) as $a0
          | (if $r.b < 0 then $n + $r.b else $r.b end) as $b0
          | ($a0 + 1) as $a1
          | (if ($b0 + 1) > $n then $n else $b0 + 1 end) as $b1
          | if $a1 < 1 or $b1 < 0 or $a1 > $n or $a1 > $b1 then "Error: Invalid range \($range)"
            else numbered($a1; $b1) end
        end
    end;

def find_starts($old):
  lines as $buf
  | ($old | lines) as $oldl
  | ([$buf[] | normline]) as $nb
  | ([$oldl[] | normline]) as $no
  | if ($no | length) == 0 then []
    else
      [range(0; ($nb | length) - ($no | length) + 1) as $i
        | select(all(range(0; $no | length); . as $k | $nb[$i + $k] == $no[$k]))
        | $i]
    end;

def splice($start; $count; $newlines):
  lines as $ls
  | ($ls[:$start] + $newlines + $ls[$start + $count:]) | join("\n");

def edit($old; $new; $multi):
  . as $src
  | ($new | if . == null then "" else . end | lines) as $nl
  | if $old == null or $old == "" then
      {ok: true, text: ($nl + ($src | lines) | join("\n"))}
    else
      find_starts($old) as $hits
      | if ($hits | length) == 0 then
          (lines | map(normline)) as $nb
          | ($old | lines | map(normline)) as $no
          | (reduce $nb[] as $line (0;
              if . >= ($no | length) then .
              elif $line == $no[.] then . + 1 else . end)) as $best
          | {ok: false, err: "Error: old_text was not found. Call read on this file, then edit again. Best partial match: \($best)/\($no | length) lines."}
        else
          (if $multi then $hits | reverse else [$hits[0]] end) as $starts
          | reduce $starts[] as $s ($src; splice($s; ($old | lines | length); $nl))
          | {ok: true, text: .}
        end
    end;
