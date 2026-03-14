# TODO

[X] make tool output into a separate message
[X] fix patch tool's poor performance
    [ ] test a bit more
[X] add folding for displaying patches
[ ] only fold the new added message, leave others unchanged, users like to open some
[X] implement a hard stop command:
    - map it to a key
    - it sets a global variable
    - add checks in some places like, before running tool calls and before sending a request
